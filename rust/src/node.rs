//! Erupt cloud node runtime: registers with the server, then answers the requests it forwards. The wire
//! contract is erupt-cloud/PROTOCOL.md (Level 0, references and row operations).
use std::cell::RefCell;
use std::collections::HashMap;
use std::net::{TcpListener, ToSocketAddrs, UdpSocket};
use std::str::FromStr;
use std::sync::atomic::{AtomicUsize, Ordering};
use std::sync::{Arc, Mutex};
use std::time::{Duration, Instant, SystemTime, UNIX_EPOCH};

use serde_json::{json, Map, Value};

use crate::http::{self, base64_decode, decode, encode, Request, Response};
use crate::model::{json_value, Field, Model, OpContext};
use crate::repo::{Cond, Filter, Query, Repository};
use crate::signature;
use crate::types::{QueryExpression, RowOperationMode};
use crate::values::{as_f64, text};
use crate::{Error, Record, Result};

pub const VERSION: &str = "0.1.0";

/// Features whose endpoints this SDK does not serve yet: hidden from the UI instead of failing there.
const UNSUPPORTED_POWER: [&str; 2] = ["print", "ai"];
/// Rights the server decides per user; the node ANDs them onto the declared power.
const SERVER_POWER: [&str; 6] = [
    "add",
    "edit",
    "delete",
    "viewDetails",
    "export",
    "importable",
];
const MAX_PAGE_SIZE: u64 = 1000;
const POWER_TTL: Duration = Duration::from_secs(5);

thread_local! {
    static USER: RefCell<Option<Value>> = const { RefCell::new(None) };
    // the session token of the request on this thread
    static TOKEN: RefCell<Option<String>> = const { RefCell::new(None) };
    // what the server checked (a signed `Erupt-Enforced`, e.g. `power`, `query`) for the request on this thread
    static ENFORCED: RefCell<Vec<String>> = const { RefCell::new(Vec::new()) };
}

fn enforced(what: &str) -> bool {
    ENFORCED.with(|e| e.borrow().iter().any(|v| v == what))
}

/// The acting user of the request being served on this thread: `{"uid", "account", "name", "tenantId"}`.
pub fn current_user() -> Option<Value> {
    USER.with(|u| u.borrow().clone())
}

/// How a request ends besides a value.
enum Reply {
    Status(u16),
    Fail(String),
    Other(String),
}

impl From<Error> for Reply {
    fn from(e: Error) -> Self {
        match e {
            Error::Fail(m) => Reply::Fail(m),
            Error::Declaration(m) | Error::Other(m) => Reply::Other(m),
        }
    }
}

type Out = std::result::Result<Value, Reply>;
/// (session token, erupt) -> when the entry expires, the computed power
type PowerCache = HashMap<(String, String), (Instant, Map<String, Value>)>;
type PowerSource = Box<dyn Fn(&str, &str) -> Result<Map<String, Value>> + Send + Sync>;

fn r_ok() -> Value {
    json!({"success": true, "status": "SUCCESS", "message": null, "data": null, "promptWay": "MESSAGE"})
}

fn fail<T>(message: impl Into<String>) -> std::result::Result<T, Reply> {
    Err(Reply::Fail(message.into()))
}

/// A node: models with their repositories, served to the erupt server.
pub struct Node {
    name: String,
    access_token: String,
    require_signature: bool,
    servers: Vec<String>,
    address: Option<String>,
    heartbeat: Duration,
    models: Vec<(Arc<Model>, Box<dyn Repository>)>,
    power_cache: Mutex<PowerCache>,
    power_source: Option<PowerSource>,
    next_server: AtomicUsize,
    instance_id: String,
}

impl Node {
    pub fn new<S: Into<String>>(
        name: &str,
        access_token: &str,
        servers: impl IntoIterator<Item = S>,
    ) -> Self {
        let seed = SystemTime::now()
            .duration_since(UNIX_EPOCH)
            .map(|d| d.subsec_nanos())
            .unwrap_or(0)
            ^ std::process::id();
        Node {
            name: name.to_string(),
            access_token: access_token.to_string(),
            require_signature: false,
            servers: servers
                .into_iter()
                .map(|s| s.into().trim_end_matches('/').to_string())
                .collect(),
            address: None,
            heartbeat: Duration::from_secs(15),
            models: Vec::new(),
            power_cache: Mutex::new(HashMap::new()),
            power_source: None,
            next_server: AtomicUsize::new(0),
            instance_id: format!("{:06x}", seed & 0xff_ffff),
        }
    }

    /// The URL the server reaches this node at; detected from the network otherwise.
    pub fn address(mut self, url: &str) -> Self {
        self.address = Some(url.trim_end_matches('/').to_string());
        self
    }

    /// Refuse server calls without a valid `Erupt-Signature`, so the plain access token alone no longer
    /// passes (servers sign since erupt 2.3.x).
    pub fn require_signature(mut self, required: bool) -> Self {
        self.require_signature = required;
        self
    }

    pub fn heartbeat_interval(mut self, interval: Duration) -> Self {
        self.heartbeat = interval;
        self
    }

    /// Where per-user rights come from (`token`, `erupt name`): the server's erupt-power by default. For
    /// tests and custom hosting; an error denies every right.
    pub fn power_source(
        mut self,
        source: impl Fn(&str, &str) -> Result<Map<String, Value>> + Send + Sync + 'static,
    ) -> Self {
        self.power_source = Some(Box::new(source));
        self
    }

    pub fn register(
        &mut self,
        model: &Arc<Model>,
        mut repository: impl Repository + 'static,
    ) -> Result<()> {
        if model.pk().is_none() {
            return Err(Error::Declaration(format!(
                "{} has no Field::pk(); only an operation form may omit it",
                model.name()
            )));
        }
        if self.models.iter().any(|(m, _)| m.name() == model.name()) {
            return Err(Error::Declaration(format!(
                "erupt '{}' registered twice",
                model.name()
            )));
        }
        repository.bind(model.clone())?;
        self.models.push((model.clone(), Box::new(repository)));
        Ok(())
    }

    fn entry(&self, name: &str) -> Option<&(Arc<Model>, Box<dyn Repository>)> {
        self.models.iter().find(|(m, _)| m.name() == name)
    }

    // ------------------------------------------------------------------ requests

    /// Answer one forwarded request; mount this in any HTTP server.
    pub fn handle(&self, request: &Request) -> Response {
        let result = self.dispatch(request);
        USER.with(|u| *u.borrow_mut() = None);
        TOKEN.with(|t| *t.borrow_mut() = None);
        ENFORCED.with(|e| e.borrow_mut().clear());
        match result {
            Ok(Value::String(text)) => Response::text(200, &text),
            Ok(value) => Response::json(200, &value),
            Err(Reply::Status(status)) => Response::text(status, ""),
            Err(Reply::Fail(message)) => Response::json(
                200,
                &json!({"success": false, "status": "ERROR", "message": message, "data": null, "promptWay": "MESSAGE"}),
            ),
            Err(Reply::Other(message)) => {
                // never leak internals beyond the message: the stack stays here
                eprintln!("erupt node error on {}: {message}", request.path);
                Response::json(
                    500,
                    &json!({"path": request.path, "status": 500, "error": "erupt exception", "message": message}),
                )
            }
        }
    }

    fn dispatch(&self, req: &Request) -> Out {
        if req.path == "/node-health" {
            return Ok(Value::String(self.name.clone()));
        }
        let Some(rest) = req.path.strip_prefix("/erupt-api/") else {
            return Err(Reply::Status(404));
        };
        // server-to-server only: an Origin header means a browser reached the node directly
        if req.get_header("origin").is_some() {
            return Err(Reply::Status(403));
        }
        self.authenticate(req)?;
        let segments: Vec<&str> = rest.split('/').collect();
        let m = req.method.as_str();
        let route = match (m, segments.as_slice()) {
            ("GET", ["build", e]) => Some((*e, Route::Build)),
            ("POST", ["data", "table", e]) => Some((*e, Route::Table)),
            ("GET", ["data", "init-value", e]) => Some((*e, Route::InitValue)),
            ("GET", ["data", e, id]) => Some((*e, Route::Get(decode(id)))),
            ("POST", ["data", "modify", e]) => Some((*e, Route::Add)),
            ("POST", ["data", "modify", e, "update"]) => Some((*e, Route::Update)),
            ("POST", ["data", "modify", e, "delete"]) => Some((*e, Route::Delete)),
            ("POST", ["invoke", e, kind, f]) => Some((*e, Route::Invoke(decode(kind), decode(f)))),
            _ => None,
        };
        let Some((erupt, route)) = route else {
            return Err(Reply::Status(404));
        };
        let name = decode(erupt);
        let Some((model, repo)) = self
            .entry(&name)
            .filter(|_| req.get_header("erupt") == Some(name.as_str()))
        else {
            return Err(Reply::Status(404));
        };
        let parent = req
            .get_header("eruptparent")
            .map(str::to_string)
            .or_else(|| req.query_param("_eruptParent"));
        // nesting is not supported yet, so a parent can only vouch for itself
        if let Some(parent) = parent.filter(|p| !p.is_empty()) {
            if parent.rsplit('.').next() != Some(name.as_str()) {
                return Err(Reply::Status(404));
            }
        }
        let user = req
            .get_header("user")
            .and_then(base64_decode)
            .and_then(|bytes| serde_json::from_slice::<Value>(&bytes).ok());
        USER.with(|u| *u.borrow_mut() = user);
        TOKEN.with(|t| *t.borrow_mut() = req.get_header("token").map(str::to_string));
        let (model, repo) = (model.as_ref(), repo.as_ref());
        match route {
            Route::Build => Ok(model.build_model(&self.power(model, req), current_user().as_ref())),
            Route::Table => {
                self.require(model, req, "query")?;
                self.page(model, repo, &body_object(req)?, req)
            }
            Route::InitValue => {
                self.require(model, req, "add")?;
                let mut record: Record = model
                    .stored()
                    .map(|f| (f.name.clone(), Value::Null))
                    .collect();
                model.hook(|p| p.add_behavior(&mut record))?;
                Ok(Value::Object(self.rows(model, vec![record]).remove(0)))
            }
            Route::Get(id) => {
                let power = self.power(model, req);
                if !(power["edit"] == json!(true) || power["viewDetails"] == json!(true)) {
                    return Err(Reply::Status(403));
                }
                let pk = primary_key(model, &Value::String(id))?;
                let mut record = repo
                    .get(&pk)?
                    .ok_or(Reply::Fail("record not found".into()))?;
                model.hook(|p| p.edit_behavior(&mut record))?;
                Ok(Value::Object(self.rows(model, vec![record]).remove(0)))
            }
            Route::Add => {
                self.require(model, req, "add")?;
                let mut record = record(model, &body_object(req)?)?;
                model.hook(|p| p.validate(&record))?;
                model.hook(|p| p.before_add(&mut record))?;
                repo.add(record.clone())?;
                model.hook(|p| p.after_add(&record))?;
                Ok(r_ok())
            }
            Route::Update => {
                self.require(model, req, "edit")?;
                let body = body_object(req)?;
                let pk = primary_key(
                    model,
                    body.get(model.pk().unwrap_or("id")).unwrap_or(&Value::Null),
                )?;
                if repo.get(&pk)?.is_none() {
                    return fail("record not found");
                }
                let mut record = record(model, &body)?;
                model.hook(|p| p.validate(&record))?;
                model.hook(|p| p.before_update(&mut record))?;
                repo.update(&pk, record.clone())?;
                model.hook(|p| p.after_update(&record))?;
                Ok(r_ok())
            }
            Route::Delete => {
                self.require(model, req, "delete")?;
                let Some(Value::Array(ids)) = read_json(req)? else {
                    return fail("a list of ids is required");
                };
                let pks = ids
                    .iter()
                    .map(|id| primary_key(model, id))
                    .collect::<std::result::Result<Vec<_>, _>>()?;
                // the hooks see each record as it was; reading them costs nothing without a proxy
                let mut records = Vec::new();
                if !model.proxies.is_empty() {
                    for pk in &pks {
                        records.extend(repo.get(pk)?);
                    }
                }
                for record in &records {
                    model.hook(|p| p.before_delete(record))?;
                }
                repo.delete(&pks)?;
                for record in &records {
                    model.hook(|p| p.after_delete(record))?;
                }
                Ok(r_ok())
            }
            // a row operation and its form's opening values under the operation code (erupt-cloud/PROTOCOL.md §5.5)
            Route::Invoke(kind, code) if kind == "operation" => {
                self.operation(model, repo, req, &code)
            }
            Route::Invoke(kind, code) if kind == "operation-form" => {
                // none without a form: the server answers the browser a 404, and it opens an empty one
                let mut r = r_ok();
                r["data"] = operation_of(model, &code)?
                    .form
                    .as_ref()
                    .map_or(Value::Null, |form| {
                        form.fields
                            .iter()
                            .map(|f| (f.name.clone(), Value::Null))
                            .collect()
                    });
                Ok(r)
            }
            Route::Invoke(kind, field) => {
                // a field's own code, with the form's values
                let body = body_object(req)?;
                let form = body.get("form").and_then(Value::as_object);
                let answer = model
                    .field(&field)
                    .and_then(|f| {
                        f.invoke(
                            &kind,
                            form.unwrap_or(&Map::new()),
                            body.get("value").unwrap_or(&Value::Null),
                        )
                    })
                    .ok_or(Reply::Status(404))??;
                let mut r = r_ok();
                r["data"] = answer;
                Ok(r)
            }
        }
    }

    fn page(
        &self,
        model: &Model,
        repo: &dyn Repository,
        body: &Map<String, Value>,
        req: &Request,
    ) -> Out {
        let int = |key: &str| {
            body.get(key)
                .and_then(as_f64)
                .map(|f| f as i64)
                .filter(|n| *n != 0)
        };
        let page_index = int("pageIndex").unwrap_or(1).max(1) as u64;
        let page_size = int("pageSize").unwrap_or(10).clamp(1, MAX_PAGE_SIZE as i64) as u64;
        // under a signed `query` the server checked the browser's conditions and may add its own (a dependent picker)
        let trusted = enforced("query");
        let mut query = Query {
            conditions: Vec::new(),
            sort: Vec::new(),
            filters: Vec::new(),
            offset: (page_index - 1) * page_size,
            limit: page_size,
        };
        for c in body
            .get("condition")
            .and_then(Value::as_array)
            .into_iter()
            .flatten()
        {
            query.conditions.push(condition(model, c, trusted)?);
        }
        let drill = self.drill(model, req, &mut query)?;
        for s in body
            .get("sort")
            .and_then(Value::as_array)
            .into_iter()
            .flatten()
        {
            let name = s.get("field").map(text).unwrap_or_default();
            let Some(f) = model.field(&name).filter(|f| f.sortable || f.is_pk()) else {
                return fail(format!("illegal sort field '{name}'"));
            };
            let desc = s
                .get("direction")
                .map(|d| text(d).eq_ignore_ascii_case("DESC"))
                .unwrap_or(false);
            query.sort.push((f.name.clone(), desc));
        }
        // a @LinkTree table shows the rows under the picked tree keys; with dependNode, none until one is picked
        let picked = body.get("linkTreeVal").filter(|v| !v.is_null());
        if let (Some((name, _)), Some(keys)) = (&model.link_tree, picked) {
            let f = model.field(name).expect("linkTree field");
            query
                .conditions
                .push(field_condition(f, "IN", keys.clone())?);
        }
        // a @Vis view's own filter and order, then the DataProxy's
        let (filters, sort) = body
            .get("vis")
            .and_then(Value::as_str)
            .and_then(|code| model.vis.get(code))
            .cloned()
            .unwrap_or_default();
        if query.sort.is_empty() {
            query.sort = if sort.is_empty() {
                model.order_by.clone()
            } else {
                sort
            };
        }
        query.filters = drill;
        query.filters.extend(filters);
        query.filters.extend(model.filters(&query.conditions)?);
        let (total, records) = match &model.link_tree {
            Some((_, true)) if picked.is_none() => (0, Vec::new()),
            _ => repo.page(&query)?,
        };
        let mut rows = self.rows(model, records);
        model.hook(|p| p.after_fetch(&mut rows))?;
        Ok(json!({
            "pageIndex": page_index, "pageSize": page_size, "total": total, "totalPage": total.div_ceil(page_size),
            "list": rows, "sort": null, "alert": null, "extraContent": null,
        }))
    }

    /// A drill into this table from a row of another model (erupt-cloud/PROTOCOL.md §7.2): the rows whose
    /// `joinColumn` holds the source row's `column`; its `linkCondition` is returned as a filter.
    fn drill(
        &self,
        model: &Model,
        req: &Request,
        query: &mut Query,
    ) -> std::result::Result<Vec<Filter>, Reply> {
        let Some(code) = req.get_header("drill") else {
            return Ok(Vec::new());
        };
        let source = req
            .get_header("drillsourceerupt")
            .and_then(|s| self.entry(s));
        let Some((source, source_repo, link)) =
            source.and_then(|(m, r)| Some((m, r, m.drills.get(code)?)))
        else {
            return Err(Reply::Status(403));
        };
        let Some(join) = model
            .field(&link.join)
            .filter(|_| link.erupt == model.name())
        else {
            return fail(format!("illegal erupt from drill '{code}'"));
        };
        let key = Value::String(req.get_header("drillvalue").unwrap_or("").to_string());
        let row = source_repo
            .get(&primary_key(source, &key)?)?
            .ok_or(Reply::Fail("record not found".into()))?;
        let value = json_value(row.get(&link.column));
        query.conditions.push(field_condition(join, "EQ", value)?);
        Ok(if link.condition.is_empty() {
            Vec::new()
        } else {
            vec![link.condition.as_str().into()]
        })
    }

    /// Records to browser rows. A reference stays its key: the server resolves its label, the flattened
    /// `<field>_<label>` column and the tree (erupt-cloud/PROTOCOL.md §7.3).
    fn rows(&self, model: &Model, records: Vec<Record>) -> Vec<Record> {
        records
            .into_iter()
            .map(|record| {
                model
                    .stored()
                    .map(|f| (f.name.clone(), json_value(record.get(&f.name))))
                    .collect()
            })
            .collect()
    }

    fn operation(&self, model: &Model, repo: &dyn Repository, req: &Request, code: &str) -> Out {
        let op = operation_of(model, code)?;
        let body = body_object(req)?;
        let param = match &op.form {
            Some(form) => Some(record(
                form,
                body.get("param")
                    .and_then(Value::as_object)
                    .unwrap_or(&Map::new()),
            )?),
            None => None,
        };
        let mut rows = Vec::new();
        if op.mode != RowOperationMode::Button {
            let ids = body
                .get("ids")
                .and_then(Value::as_array)
                .filter(|ids| !ids.is_empty());
            let Some(ids) = ids else {
                return fail("select at least one row");
            };
            if op.mode == RowOperationMode::Single && ids.len() != 1 {
                return fail("select exactly one row");
            }
            for id in ids {
                let pk = primary_key(model, id)?;
                match repo.get(&pk)? {
                    Some(record) => rows.push(record),
                    None => return fail(format!("record '{}' not found", text(id))),
                }
            }
        }
        let handler = op
            .handler
            .as_ref()
            .expect("checked when the model was built");
        let context = OpContext {
            rows,
            param,
            repo,
            model,
            user: current_user(),
        };
        match handler(&context)? {
            Some(script) if !script.is_empty() => Ok(
                json!({"success": true, "status": "SUCCESS", "message": null, "data": script, "promptWay": "MESSAGE"}),
            ),
            _ => Ok(
                json!({"success": true, "status": "SUCCESS", "message": "Executed successfully", "data": null, "promptWay": "MESSAGE"}),
            ),
        }
    }

    // ------------------------------------------------------------------ authentication (PROTOCOL.md §4.3)

    /// A signed call must verify, and then stands for the token; its `Erupt-Enforced` is trusted only then.
    fn authenticate(&self, req: &Request) -> std::result::Result<(), Reply> {
        let Some(given) = req.get_header(signature::HEADER_SIGNATURE) else {
            let token_ok = constant_time_eq(
                req.get_header("access-token").unwrap_or("").as_bytes(),
                self.access_token.as_bytes(),
            );
            return if self.require_signature || !token_ok {
                Err(Reply::Status(403))
            } else {
                Ok(())
            };
        };
        let multipart = req
            .get_header("content-type")
            .is_some_and(|t| t.contains("multipart/form-data"));
        let path_and_query = if req.query.is_empty() {
            req.path.clone()
        } else {
            format!("{}?{}", req.path, req.query)
        };
        let now = SystemTime::now()
            .duration_since(UNIX_EPOCH)
            .map(|d| d.as_secs() as i64)
            .unwrap_or(0);
        let enforced = req.get_header(signature::HEADER_ENFORCED);
        if !signature::verify(
            &self.access_token,
            &req.method,
            &path_and_query,
            req.get_header(signature::HEADER_TIMESTAMP),
            enforced,
            req.get_header("user"),
            if multipart { None } else { Some(&req.body) },
            given,
            now,
        ) {
            return Err(Reply::Status(403));
        }
        let checked = enforced.into_iter().flat_map(|e| e.split(','));
        ENFORCED.with(|e| *e.borrow_mut() = checked.map(|v| v.trim().to_string()).collect());
        Ok(())
    }

    // ------------------------------------------------------------------ permissions (PROTOCOL.md §6.1)

    fn require(&self, model: &Model, req: &Request, right: &str) -> std::result::Result<(), Reply> {
        if self.power(model, req).get(right) == Some(&Value::Bool(true)) {
            Ok(())
        } else {
            Err(Reply::Status(403))
        }
    }

    fn power(&self, model: &Model, req: &Request) -> Map<String, Value> {
        if enforced("power") {
            // the server checked the user's rights and restricts the build's power itself: the model's own
            // declaration is all that is left to apply here
            let mut power = model.power.clone();
            for right in UNSUPPORTED_POWER {
                power.insert(right.to_string(), Value::Bool(false));
            }
            return power;
        }
        let token = req.get_header("token").unwrap_or("").to_string();
        let key = (token.clone(), model.name().to_string());
        if let Some((expires, power)) = self.power_cache.lock().expect("power cache").get(&key) {
            if *expires > Instant::now() {
                return power.clone();
            }
        }
        let mut power = model.power.clone();
        for right in UNSUPPORTED_POWER {
            power.insert(right.to_string(), Value::Bool(false));
        }
        let remote = match &self.power_source {
            Some(source) => source(&token, model.name()),
            None => self.server_power(&token, model.name()),
        };
        // fail closed: without the server's verdict nothing is writable
        let remote = remote.unwrap_or_else(|e| {
            eprintln!("erupt-power unavailable: {e}");
            Map::new()
        });
        for right in SERVER_POWER {
            let allowed = power.get(right) == Some(&Value::Bool(true))
                && remote.get(right) == Some(&Value::Bool(true));
            power.insert(right.to_string(), Value::Bool(allowed));
        }
        let mut cache = self.power_cache.lock().expect("power cache");
        if cache.len() > 10_000 {
            cache.clear();
        }
        cache.insert(key, (Instant::now() + POWER_TTL, power.clone()));
        power
    }

    // ------------------------------------------------------------------ server calls

    fn server(&self) -> &str {
        let i = self.next_server.fetch_add(1, Ordering::Relaxed);
        self.servers
            .get(i % self.servers.len().max(1))
            .map(String::as_str)
            .unwrap_or("")
    }

    fn server_power(&self, token: &str, erupt: &str) -> Result<Map<String, Value>> {
        let url = format!(
            "{}/erupt-cloud-api/erupt-power?nodeName={}&eruptName={}",
            self.server(),
            encode(&self.name),
            encode(erupt)
        );
        let (status, body) = http::fetch(
            "GET",
            &url,
            &[("token", token)],
            None,
            Duration::from_secs(5),
        )?;
        if status != 200 {
            return Err(Error::Other(format!("erupt-power answered {status}")));
        }
        match serde_json::from_slice(&body) {
            Ok(Value::Object(power)) => Ok(power),
            _ => Err(Error::Other("erupt-power answered no object".into())),
        }
    }

    /// The config text set for this node on the erupt server (Node Config).
    pub fn config(&self) -> Result<String> {
        self.server_text("node-config", &[])
    }

    /// The config text of this node's group on the erupt server.
    pub fn group_config(&self) -> Result<String> {
        self.server_text("node-group-config", &[])
    }

    /// The acting user's full info from the erupt server (roles, org, post...), for the request being served
    /// on this thread; None when the server answers nothing.
    pub fn user_info(&self) -> Result<Option<Value>> {
        let token = TOKEN.with(|t| t.borrow().clone()).unwrap_or_default();
        let text = self.server_text("userinfo", &[("token", &token)])?;
        if text.is_empty() {
            return Ok(None);
        }
        serde_json::from_str(&text)
            .map(Some)
            .map_err(|e| Error::Other(format!("userinfo answered no JSON: {e}")))
    }

    /// `GET /erupt-cloud-api/{api}/{nodeName}` with the access token, as text.
    fn server_text(&self, api: &str, headers: &[(&str, &str)]) -> Result<String> {
        let url = format!(
            "{}/erupt-cloud-api/{api}/{}",
            self.server(),
            encode(&self.name)
        );
        let mut all = vec![("Access-Token", self.access_token.as_str())];
        all.extend_from_slice(headers);
        let (status, body) = http::fetch("GET", &url, &all, None, Duration::from_secs(5))?;
        if status != 200 {
            return Err(Error::Other(format!("{api} answered {status}")));
        }
        Ok(String::from_utf8_lossy(&body).into_owned())
    }

    fn node_info(&self) -> Value {
        json!({
            "instanceId": self.instance_id, "nodeName": self.name, "accessToken": self.access_token,
            "version": format!("rust-{VERSION}"), "nodeAddress": [self.address], "eruptModules": [],
            "erupts": self.models.iter().map(|(m, _)| m.name()).collect::<Vec<_>>(), "resources": {},
            "capabilities": ["invoke"],
        })
    }

    /// Register once with the next server.
    pub fn register_once(&self) -> Result<()> {
        if self.address.is_none() {
            return Err(Error::Declaration("the node address is not set".into()));
        }
        let url = format!("{}/erupt-cloud-api/register-node", self.server());
        let body = self.node_info().to_string();
        let (status, _) = http::fetch(
            "POST",
            &url,
            &[("Content-Type", "application/json")],
            Some(body.as_bytes()),
            Duration::from_secs(10),
        )?;
        if (200..300).contains(&status) {
            Ok(())
        } else {
            Err(Error::Other(format!("register-node answered {status}")))
        }
    }

    /// Register now and then every heartbeat interval on a background thread.
    pub fn start_heartbeat(self: &Arc<Self>) {
        let node = self.clone();
        std::thread::spawn(move || {
            let mut failing = false;
            loop {
                match node.register_once() {
                    Ok(()) => {
                        if failing {
                            eprintln!("erupt node '{}': connection success", node.name);
                        }
                        failing = false;
                        std::thread::sleep(node.heartbeat);
                    }
                    Err(e) => {
                        failing = true;
                        eprintln!("erupt node '{}': register failed: {e}", node.name);
                        std::thread::sleep(node.heartbeat / 2);
                    }
                }
            }
        });
    }

    /// Tell the server this instance is gone, so it stops routing here at once.
    pub fn deregister(&self) {
        let form = format!(
            "nodeName={}&accessToken={}&locations={}",
            encode(&self.name),
            encode(&self.access_token),
            encode(self.address.as_deref().unwrap_or(""))
        );
        let url = format!("{}/erupt-cloud-api/remove-instance-node", self.server());
        let headers = [("Content-Type", "application/x-www-form-urlencoded")];
        if let Err(e) = http::fetch(
            "POST",
            &url,
            &headers,
            Some(form.as_bytes()),
            Duration::from_secs(5),
        ) {
            eprintln!("erupt node '{}': deregister failed: {e}", self.name);
        }
    }

    /// The URL this node would register at port `port`: the local interface the first server is reached
    /// through, preferring IPv4.
    pub fn auto_address(&self, port: u16) -> String {
        node_address(
            &local_ip(self.servers.first().map(String::as_str).unwrap_or("")),
            port,
        )
    }

    /// Serve forever: HTTP first (the server probes /node-health while registering), then heartbeat;
    /// SIGINT / SIGTERM deregister and exit.
    pub fn serve(mut self, host: &str, port: u16) -> Result<()> {
        let address = self
            .address
            .clone()
            .unwrap_or_else(|| self.auto_address(port));
        self.address = Some(address.clone());
        let listener = TcpListener::bind((host, port))?;
        let node = Arc::new(self);
        eprintln!(
            "erupt node '{}' at {} -> {}",
            node.name,
            address,
            node.servers.join(", ")
        );
        node.start_heartbeat();
        let on_signal = node.clone();
        ctrlc::set_handler(move || {
            on_signal.deregister();
            std::process::exit(0);
        })
        .map_err(|e| Error::Other(format!("cannot install the signal handler: {e}")))?;
        let handler = node.clone();
        http::serve_listener(
            listener,
            16,
            Arc::new(move |req: &Request| handler.handle(req)),
        )?;
        Ok(())
    }
}

enum Route {
    Build,
    Table,
    InitValue,
    Get(String),
    Add,
    Update,
    Delete,
    /// kind, field or operation code
    Invoke(String, String),
}

fn constant_time_eq(a: &[u8], b: &[u8]) -> bool {
    a.len() == b.len() && a.iter().zip(b).fold(0u8, |acc, (x, y)| acc | (x ^ y)) == 0
}

fn operation_of<'a>(
    model: &'a Model,
    code: &str,
) -> std::result::Result<&'a crate::model::Operation, Reply> {
    let op = model
        .operations
        .iter()
        .find(|o| o.code == code)
        .ok_or(Reply::Status(404))?;
    // a hidden operation does not exist for this user, exactly like the Java proxy filters it out
    if op.visible(current_user().as_ref()) {
        Ok(op)
    } else {
        Err(Reply::Status(403))
    }
}

fn read_json(req: &Request) -> std::result::Result<Option<Value>, Reply> {
    if req.body.is_empty() {
        return Ok(None);
    }
    serde_json::from_slice(&req.body)
        .map(Some)
        .map_err(|_| Reply::Fail("malformed JSON body".into()))
}

/// The body as an object; anything else counts as empty.
fn body_object(req: &Request) -> std::result::Result<Map<String, Value>, Reply> {
    Ok(match read_json(req)? {
        Some(Value::Object(o)) => o,
        _ => Map::new(),
    })
}

fn primary_key(model: &Model, value: &Value) -> std::result::Result<Value, Reply> {
    let pk = model.field(model.pk().unwrap_or("id")).expect("pk field");
    pk.coerce(value)
        .map_err(|_| Reply::Fail(format!("illegal id '{}'", text(value))))
}

/// A condition the browser sent; `trusted` (checked by the server) takes any stored field.
fn condition(model: &Model, c: &Value, trusted: bool) -> std::result::Result<Cond, Reply> {
    let key = c.get("key").map(text).unwrap_or_default();
    let allowed = |f: &&Field| !f.transient && (trusted || (!f.is_pk() && f.search));
    let Some(f) = model.field(&key).filter(allowed) else {
        return fail(format!("illegal search field '{key}'"));
    };
    let name = c
        .get("expression")
        .map(text)
        .filter(|e| !e.is_empty() && e != "None")
        .unwrap_or_else(|| "EQ".into());
    field_condition(f, &name, c.get("value").cloned().unwrap_or(Value::Null))
}

/// A condition on a field, its value coerced to the field.
fn field_condition(f: &Field, name: &str, value: Value) -> std::result::Result<Cond, Reply> {
    let op = match QueryExpression::from_str(name) {
        Ok(op) if op != QueryExpression::Auto => op,
        _ => return fail(format!("illegal operator '{name}'")),
    };
    use QueryExpression::*;
    if matches!(op, Null | NotNull) {
        return Ok(Cond::new(&f.name, op, Value::Null));
    }
    if f.is_reference() && !matches!(op, Eq | Neq | In | NotIn) {
        return fail(format!("illegal operator '{name}' for a reference"));
    }
    if matches!(op, Like | NotLike) {
        return Ok(Cond::new(&f.name, op, Value::String(text(&value))));
    }
    let coerce = |v: &Value| f.coerce(v).map_err(Reply::Fail);
    let value = match op {
        Range => match value.as_array() {
            Some(bounds) if bounds.len() == 2 => {
                Value::Array(vec![coerce(&bounds[0])?, coerce(&bounds[1])?])
            }
            _ => return fail("range needs two values"),
        },
        In | NotIn => {
            let items = value
                .as_array()
                .cloned()
                .unwrap_or_else(|| vec![value.clone()]);
            Value::Array(
                items
                    .iter()
                    .map(coerce)
                    .collect::<std::result::Result<_, _>>()?,
            )
        }
        _ => coerce(&value)?,
    };
    Ok(Cond::new(&f.name, op, value))
}

/// A write body to a record: every form field coerced, required ones present.
fn record(model: &Model, body: &Map<String, Value>) -> std::result::Result<Record, Reply> {
    let mut record = Record::new();
    for f in model.stored().filter(|f| !f.is_pk() && f.form) {
        let value = f
            .coerce(body.get(&f.name).unwrap_or(&Value::Null))
            .map_err(|e| Reply::Fail(format!("{}: {e}", f.title)))?;
        if f.not_null && value.is_null() {
            return fail(format!("{} cannot be empty", f.title));
        }
        record.insert(f.name.clone(), value);
    }
    Ok(record)
}

/// The interface address the server would see us on, preferring IPv4.
fn local_ip(server: &str) -> String {
    let rest = server.split_once("://").map(|(_, r)| r).unwrap_or(server);
    let authority = rest.split('/').next().unwrap_or("");
    let host = if let Some(stripped) = authority.strip_prefix('[') {
        stripped.split(']').next().unwrap_or("")
    } else {
        authority
            .rsplit_once(':')
            .filter(|(_, p)| p.parse::<u16>().is_ok())
            .map(|(h, _)| h)
            .unwrap_or(authority)
    };
    let host = if host.is_empty() { "127.0.0.1" } else { host };
    let addrs: Vec<_> = (host, 80)
        .to_socket_addrs()
        .map(|a| a.collect())
        .unwrap_or_default();
    let probe = |bind: &str, target: &std::net::SocketAddr| -> Option<String> {
        let socket = UdpSocket::bind(bind).ok()?;
        socket.connect(target).ok()?;
        Some(socket.local_addr().ok()?.ip().to_string())
    };
    addrs
        .iter()
        .find(|a| a.is_ipv4())
        .and_then(|a| probe("0.0.0.0:0", a))
        .or_else(|| {
            addrs
                .iter()
                .find(|a| a.is_ipv6())
                .and_then(|a| probe("[::]:0", a))
        })
        .unwrap_or_else(|| "127.0.0.1".to_string())
}

/// `http://host:port`, bracketing an IPv6 host as a URL requires.
pub(crate) fn node_address(ip: &str, port: u16) -> String {
    if ip.contains(':') {
        format!("http://[{ip}]:{port}")
    } else {
        format!("http://{ip}:{port}")
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn addresses() {
        assert_eq!("http://[::1]:9090", node_address("::1", 9090));
        let ip = local_ip("http://localhost:18080");
        assert!(
            ip.parse::<std::net::Ipv4Addr>().is_ok(),
            "localhost resolved to {ip}"
        );
        let node = Node::new("n", "t", ["http://localhost:18080"]);
        assert_eq!(format!("http://{ip}:9090"), node.auto_address(9090));
    }

    #[test]
    fn constant_time() {
        assert!(constant_time_eq(b"abc", b"abc"));
        assert!(!constant_time_eq(b"abc", b"abd"));
        assert!(!constant_time_eq(b"", b"a"));
    }
}
