use erupt::http::{Request, Response};
use std::sync::{Arc, Mutex};

use erupt::{
    current_user, Cond, DataProxy, Error, Field, Filter, MemoryRepository, Model, Node, Operation,
    Record,
};
use serde_json::{json, Map, Value};

const TOKEN: &str = "node-secret";

fn node() -> Node {
    let post = Model::new("Post", "Post")
        .field("id", Field::pk())
        .field("title", Field::input("Title").search().not_null())
        .operation(
            Operation::new("ping", "Ping")
                .handler(|op| Ok(Some(format!("alert({})", op.rows.len())))),
        )
        .build()
        .unwrap();
    let mut node =
        Node::new("n", TOKEN, ["http://127.0.0.1:1"]).power_source(|token, _| match token {
            "t1" => Ok(
                json!({"add": true, "edit": true, "delete": true, "viewDetails": true})
                    .as_object()
                    .cloned()
                    .unwrap(),
            ),
            _ => Err(Error::Other("server down".into())),
        });
    node.register(&post, MemoryRepository::new()).unwrap();
    node
}

fn call(
    node: &Node,
    method: &str,
    path: &str,
    body: Option<Value>,
    headers: &[(&str, &str)],
) -> (u16, Value) {
    let mut request = Request::new(method, path)
        .header("Access-Token", TOKEN)
        .header("token", "t1")
        .header("erupt", "Post");
    for (name, value) in headers {
        request = request.header(name, value);
    }
    if let Some(body) = body {
        request = request.body(body.to_string());
    }
    let Response { status, body, .. } = node.handle(&request);
    (
        status,
        serde_json::from_slice(&body)
            .unwrap_or_else(|_| Value::String(String::from_utf8_lossy(&body).into_owned())),
    )
}

#[test]
fn guards() {
    let n = node();
    assert_eq!(
        403,
        call(
            &n,
            "GET",
            "/erupt-api/build/Post",
            None,
            &[("Origin", "http://evil")]
        )
        .0
    );
    assert_eq!(
        403,
        call(
            &n,
            "GET",
            "/erupt-api/build/Post",
            None,
            &[("Access-Token", "bad")]
        )
        .0
    );
    assert_eq!(
        404,
        call(
            &n,
            "GET",
            "/erupt-api/build/Post",
            None,
            &[("erupt", "Other")]
        )
        .0
    );
    assert_eq!(
        404,
        call(
            &n,
            "GET",
            "/erupt-api/build/Post",
            None,
            &[("eruptParent", "n.Other")]
        )
        .0
    );
    assert_eq!(
        200,
        call(
            &n,
            "GET",
            "/erupt-api/build/Post",
            None,
            &[("eruptParent", "n.Post")]
        )
        .0
    );
    assert_eq!(404, call(&n, "GET", "/erupt-api/nothing", None, &[]).0);
    assert_eq!(
        (200, json!("n")),
        call(&n, "GET", "/node-health", None, &[("Access-Token", "")])
    );
}

#[test]
fn crud_and_operations() {
    let n = node();
    let (_, r) = call(
        &n,
        "POST",
        "/erupt-api/data/modify/Post",
        Some(json!({"title": "a"})),
        &[],
    );
    assert_eq!(json!(true), r["success"]);
    let (_, r) = call(
        &n,
        "POST",
        "/erupt-api/data/modify/Post",
        Some(json!({})),
        &[],
    );
    assert_eq!(json!("Title cannot be empty"), r["message"]);
    let (_, page) = call(
        &n,
        "POST",
        "/erupt-api/data/table/Post",
        Some(json!({"pageIndex": 1, "pageSize": 10})),
        &[],
    );
    assert_eq!(json!([{"id": 1, "title": "a"}]), page["list"]);
    let (_, r) = call(
        &n,
        "POST",
        "/erupt-api/data/Post/operator/ping",
        Some(json!({"ids": [1], "param": null})),
        &[],
    );
    assert_eq!(json!("alert(1)"), r["data"]);
    let (_, r) = call(
        &n,
        "POST",
        "/erupt-api/data/table/Post",
        Some(json!({"condition": [{"key": "title\" OR 1=1", "value": 1}]})),
        &[],
    );
    assert_eq!(json!(false), r["success"]);
    let raw = Request::new("POST", "/erupt-api/data/modify/Post")
        .header("Access-Token", TOKEN)
        .header("token", "t1")
        .header("erupt", "Post")
        .body("{not json");
    let r: Value = serde_json::from_slice(&n.handle(&raw).body).unwrap();
    assert_eq!(
        (json!(false), json!("malformed JSON body")),
        (r["success"].clone(), r["message"].clone())
    );
}

#[test]
fn power_fails_closed() {
    let n = node();
    assert_eq!(
        403,
        call(
            &n,
            "POST",
            "/erupt-api/data/modify/Post",
            Some(json!({"title": "a"})),
            &[("token", "t-down")]
        )
        .0
    );
    let (_, build) = call(
        &n,
        "GET",
        "/erupt-api/build/Post",
        None,
        &[("token", "t-down")],
    );
    let power: &Map<String, Value> = build["power"].as_object().unwrap();
    assert_eq!(Some(&json!(false)), power.get("add"));
    assert_eq!(Some(&json!(false)), power.get("export"));
    assert_eq!(Some(&json!(true)), power.get("cellEdit")); // the server edits the cell
}

/// Every hook; the write hooks only record that they ran, with the text they saw.
struct MemoProxy(Arc<Mutex<Vec<(&'static str, String)>>>);

impl MemoProxy {
    fn log(&self, hook: &'static str, record: &Record) -> erupt::Result<()> {
        let text = record["text"].as_str().unwrap_or_default().to_string();
        self.0.lock().unwrap().push((hook, text));
        Ok(())
    }
}

impl DataProxy for MemoProxy {
    fn search_condition(&self, condition: &mut Record) {
        condition.insert("text".into(), json!("hi"));
    }
    fn after_fetch(&self, rows: &mut [Record]) -> erupt::Result<()> {
        for row in rows {
            let upper = row["text"].as_str().unwrap_or_default().to_uppercase();
            row.insert("text".into(), json!(upper));
        }
        Ok(())
    }
    fn add_behavior(&self, record: &mut Record) -> erupt::Result<()> {
        record.insert("text".into(), json!("new"));
        Ok(())
    }
    fn edit_behavior(&self, record: &mut Record) -> erupt::Result<()> {
        let text = format!("{}?", record["text"].as_str().unwrap_or_default());
        record.insert("text".into(), json!(text));
        Ok(())
    }
    fn validate(&self, record: &Record) -> erupt::Result<()> {
        if record["text"] == json!("forbidden") {
            return Err(Error::fail("forbidden text"));
        }
        Ok(())
    }
    fn before_add(&self, record: &mut Record) -> erupt::Result<()> {
        self.log("before_add", record)
    }
    fn after_add(&self, record: &Record) -> erupt::Result<()> {
        self.log("after_add", record)
    }
    fn before_update(&self, record: &mut Record) -> erupt::Result<()> {
        self.log("before_update", record)
    }
    fn after_update(&self, record: &Record) -> erupt::Result<()> {
        self.log("after_update", record)
    }
    fn before_delete(&self, record: &Record) -> erupt::Result<()> {
        self.log("before_delete", record)
    }
    fn after_delete(&self, record: &Record) -> erupt::Result<()> {
        self.log("after_delete", record)
    }
}

#[test]
fn data_proxy() {
    let calls = Arc::new(Mutex::new(Vec::new()));
    let memo = Model::new("Memo", "Memo")
        .data_proxy(MemoProxy(calls.clone()))
        .field("id", Field::pk())
        .field("text", Field::input("Text"))
        .build()
        .unwrap();
    let mut n = node();
    n.register(&memo, MemoryRepository::new()).unwrap();
    let memo_call = |method: &str, path: &str, body: Option<Value>| {
        call(&n, method, path, body, &[("erupt", "Memo")]).1
    };
    let build = memo_call("GET", "/erupt-api/build/Memo", None);
    assert_eq!(
        json!({"text": "hi"}),
        build["eruptModel"]["searchCondition"]
    );
    let init = memo_call("GET", "/erupt-api/data/init-value/Memo", None);
    assert_eq!(json!("new"), init["text"]);
    let r = memo_call(
        "POST",
        "/erupt-api/data/modify/Memo",
        Some(json!({"text": "forbidden"})),
    );
    assert_eq!(
        (json!(false), json!("forbidden text")),
        (r["success"].clone(), r["message"].clone())
    );
    let r = memo_call(
        "POST",
        "/erupt-api/data/modify/Memo",
        Some(json!({"text": "a"})),
    );
    assert_eq!(json!(true), r["success"]);
    let page = memo_call("POST", "/erupt-api/data/table/Memo", Some(json!({})));
    assert_eq!(json!([{"id": 1, "text": "A"}]), page["list"]);
    let r = memo_call("GET", "/erupt-api/data/Memo/1", None);
    assert_eq!(json!("a?"), r["text"]);
    let r = memo_call(
        "POST",
        "/erupt-api/data/modify/Memo/update",
        Some(json!({"id": 1, "text": "b"})),
    );
    assert_eq!(json!(true), r["success"]);
    let r = memo_call(
        "POST",
        "/erupt-api/data/modify/Memo/delete",
        Some(json!([1])),
    );
    assert_eq!(json!(true), r["success"]);
    let expected: Vec<(&str, String)> = [
        ("before_add", "a"),
        ("after_add", "a"),
        ("before_update", "b"),
        ("after_update", "b"),
        ("before_delete", "b"),
        ("after_delete", "b"),
    ]
    .iter()
    .map(|(h, t)| (*h, t.to_string()))
    .collect();
    assert_eq!(expected, *calls.lock().unwrap());
}

struct TaskProxy;

impl DataProxy for TaskProxy {
    fn before_fetch(&self, _: &[Cond]) -> erupt::Result<Option<Filter>> {
        let account = current_user().map(|u| u["account"].clone());
        Ok(Some(Filter::new(
            "owner = ?",
            vec![account.unwrap_or_default()],
        )))
    }
}

struct OpenProxy;

impl DataProxy for OpenProxy {
    fn before_fetch(&self, _: &[Cond]) -> erupt::Result<Option<Filter>> {
        Ok(Some("done = 0".into()))
    }
}

fn task() -> Arc<Model> {
    Model::new("Task", "Task")
        .data_proxy(TaskProxy)
        .data_proxy(OpenProxy)
        .field("id", Field::pk())
        .field("title", Field::input("Title").search())
        .field("owner", Field::input("Owner"))
        .field("done", Field::boolean("Done"))
        .raw(json!({"vis": [
            {"code": "q", "title": "Question", "type": "TABLE", "filter": "title = 'a?'"},
            {"title": "Reversed", "type": "TABLE", "filter": ["1 = 1", "2 = 2"], "orderBy": "title desc"},
        ]}))
        .build()
        .unwrap()
}

// the user header, {"uid":1,"account":"admin"}
const ADMIN: &str = "eyJ1aWQiOjEsImFjY291bnQiOiJhZG1pbiJ9";

#[cfg(feature = "sqlite")]
#[test]
fn before_fetch() {
    use erupt::{Dialect, SqlRepository, SqliteExecutor};
    const ROOT: &str = "eyJ1aWQiOjEsImFjY291bnQiOiJyb290In0="; // {"uid":1,"account":"root"}
    let mut n = node();
    let repo = SqlRepository::new(
        SqliteExecutor::open(":memory:").unwrap(),
        "task",
        Dialect::Sqlite,
    )
    .auto_create();
    n.register(&task(), repo).unwrap();
    let task_call = |path: &str, body: Value, user: &str| {
        call(
            &n,
            "POST",
            path,
            Some(body),
            &[("erupt", "Task"), ("user", user)],
        )
        .1
    };
    for (title, owner, done) in [
        ("a", "admin", false),
        ("b", "admin", true),
        ("c", "root", false),
        ("a?", "admin", false),
    ] {
        let record = json!({"title": title, "owner": owner, "done": done});
        assert_eq!(
            json!(true),
            task_call("/erupt-api/data/modify/Task", record, ADMIN)["success"]
        );
    }
    let page = task_call("/erupt-api/data/table/Task", json!({}), ADMIN);
    let titles: Vec<&Value> = page["list"]
        .as_array()
        .unwrap()
        .iter()
        .map(|r| &r["title"])
        .collect();
    assert_eq!(vec![&json!("a"), &json!("a?")], titles);
    assert_eq!(json!(2), page["total"]);
    let search = json!({"condition": [{"key": "title", "expression": "EQ", "value": "a"}]});
    let page = task_call("/erupt-api/data/table/Task", search, ROOT);
    assert_eq!(json!([]), page["list"]);
    // a view's own filter and order run on the node, and stay out of the build
    let titles = |vis: &str| {
        let page = task_call("/erupt-api/data/table/Task", json!({"vis": vis}), ADMIN);
        page["list"]
            .as_array()
            .unwrap()
            .iter()
            .map(|r| r["title"].clone())
            .collect::<Vec<_>>()
    };
    assert_eq!(vec![json!("a?")], titles("q"));
    assert_eq!(vec![json!("a?"), json!("a")], titles("Reversed"));
    let (_, build) = call(
        &n,
        "GET",
        "/erupt-api/build/Task",
        None,
        &[("erupt", "Task"), ("user", ADMIN)],
    );
    let vis = build["eruptModel"]["eruptJson"]["vis"].as_array().unwrap();
    let codes: Vec<&Value> = vis.iter().map(|v| &v["code"]).collect();
    assert_eq!(vec![&json!("q"), &json!("Reversed")], codes);
    assert!(vis
        .iter()
        .all(|v| v.get("filter").is_none() && v.get("orderBy").is_none()));
}

#[test]
fn before_fetch_needs_sql() {
    let mut n = node();
    n.register(&task(), MemoryRepository::new()).unwrap();
    let (status, _) = call(
        &n,
        "POST",
        "/erupt-api/data/table/Task",
        Some(json!({})),
        &[("erupt", "Task"), ("user", ADMIN)],
    );
    assert_eq!(500, status);
}
