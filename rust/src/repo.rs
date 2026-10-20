//! Storage. A repository only sees field names the node has already checked against the model, so it may
//! use them as identifiers; values always travel as parameters. Without a sort, every repository returns
//! rows by primary key ascending.
use std::cmp::Ordering;
use std::collections::BTreeMap;
use std::sync::{Arc, Mutex};

use serde_json::Value;

use crate::model::Model;
use crate::types::QueryExpression;
use crate::values::{compare, same, text};
use crate::{Error, Record, Result};

#[derive(Clone, Debug, PartialEq)]
pub struct Cond {
    pub field: String,
    pub op: QueryExpression,
    /// a scalar; two values for RANGE, a list for IN / NOT_IN; ignored for NULL / NOT_NULL
    pub value: Value,
}

impl Cond {
    pub fn new(field: &str, op: QueryExpression, value: Value) -> Self {
        Cond {
            field: field.to_string(),
            op,
            value,
        }
    }
}

/// SQL ANDed to a table page's WHERE, as written, from a `vis` view's `filter` or a
/// [`DataProxy::before_fetch`](crate::DataProxy::before_fetch). With `params`, each `?` in it is one of them,
/// bound like every other value; `"done = 0".into()` for SQL alone, taken as is.
#[derive(Clone, Debug, PartialEq)]
pub struct Filter {
    pub sql: String,
    pub params: Vec<Value>,
}

impl Filter {
    pub fn new(sql: &str, params: Vec<Value>) -> Self {
        Filter {
            sql: sql.to_string(),
            params,
        }
    }
}

impl From<&str> for Filter {
    fn from(sql: &str) -> Self {
        Filter::new(sql, Vec::new())
    }
}

#[derive(Clone, Debug, PartialEq)]
pub struct Query {
    pub conditions: Vec<Cond>,
    /// `(field, descending)`
    pub sort: Vec<(String, bool)>,
    /// From a `vis` view and the model's `DataProxy::before_fetch`: a repository must apply every one or refuse
    /// the query.
    pub filters: Vec<Filter>,
    pub offset: u64,
    pub limit: u64,
}

impl Default for Query {
    fn default() -> Self {
        Query {
            conditions: Vec::new(),
            sort: Vec::new(),
            filters: Vec::new(),
            offset: 0,
            limit: 10,
        }
    }
}

/// Implement these to put a model on any storage. Calls block; mount the node with spawn_blocking under an
/// async runtime. `page` must apply [`Query::filters`] or refuse a query that has them, never ignore them.
pub trait Repository: Send + Sync {
    /// Called once by `Node::register` with the model this repository stores.
    fn bind(&mut self, model: Arc<Model>) -> Result<()>;
    /// `(total, records)`; a record is keyed by field name.
    fn page(&self, query: &Query) -> Result<(u64, Vec<Record>)>;
    fn get(&self, pk: &Value) -> Result<Option<Record>>;
    fn add(&self, record: Record) -> Result<()>;
    fn update(&self, pk: &Value, record: Record) -> Result<()>;
    fn delete(&self, pks: &[Value]) -> Result<()>;
}

pub(crate) fn matches(value: &Value, cond: &Cond) -> bool {
    use QueryExpression::*;
    let expect = &cond.value;
    match cond.op {
        Null => return value.is_null(),
        NotNull => return !value.is_null(),
        _ if value.is_null() => return false,
        _ => {}
    }
    let list = || expect.as_array().cloned().unwrap_or_default();
    let ord = || compare(value, expect);
    match cond.op {
        Eq => same(value, expect),
        Neq => !same(value, expect),
        Like => text(value)
            .to_lowercase()
            .contains(&text(expect).to_lowercase()),
        NotLike => !text(value)
            .to_lowercase()
            .contains(&text(expect).to_lowercase()),
        In => list().iter().any(|v| same(value, v)),
        NotIn => !list().iter().any(|v| same(value, v)),
        Range => {
            let bounds = list();
            bounds.len() == 2
                && matches!(
                    compare(&bounds[0], value),
                    Some(Ordering::Less | Ordering::Equal)
                )
                && matches!(
                    compare(value, &bounds[1]),
                    Some(Ordering::Less | Ordering::Equal)
                )
        }
        Gt => ord() == Some(Ordering::Greater),
        Gte => matches!(ord(), Some(Ordering::Greater | Ordering::Equal)),
        Lt => ord() == Some(Ordering::Less),
        Lte => matches!(ord(), Some(Ordering::Less | Ordering::Equal)),
        Auto | Null | NotNull => false,
    }
}

/// Records in memory, for tests, demos and long-running servers. Primary keys are assigned 1, 2, 3...
pub struct MemoryRepository {
    seed: Vec<Record>,
    state: Mutex<(i64, BTreeMap<i64, Record>)>,
    pk: String,
}

impl MemoryRepository {
    pub fn new() -> Self {
        MemoryRepository::seeded(Vec::new())
    }

    /// Start with these records, added in order when the repository is bound.
    pub fn seeded(records: Vec<Record>) -> Self {
        MemoryRepository {
            seed: records,
            state: Mutex::new((0, BTreeMap::new())),
            pk: "id".to_string(),
        }
    }

    fn key(pk: &Value) -> Option<i64> {
        pk.as_i64()
            .or_else(|| pk.as_f64().filter(|f| f.fract() == 0.0).map(|f| f as i64))
    }
}

impl Default for MemoryRepository {
    fn default() -> Self {
        MemoryRepository::new()
    }
}

impl Repository for MemoryRepository {
    fn bind(&mut self, model: Arc<Model>) -> Result<()> {
        self.pk = model
            .pk()
            .ok_or_else(|| Error::Declaration(format!("{} has no primary key", model.name())))?
            .to_string();
        for record in std::mem::take(&mut self.seed) {
            self.add(record)?;
        }
        Ok(())
    }

    fn page(&self, query: &Query) -> Result<(u64, Vec<Record>)> {
        if !query.filters.is_empty() {
            return Err(Error::Other(
                "MemoryRepository cannot apply SQL filters (a view filter, before_fetch)".into(),
            ));
        }
        let state = self.state.lock().expect("memory repository lock");
        let mut rows: Vec<&Record> = state
            .1
            .values()
            .filter(|r| {
                query
                    .conditions
                    .iter()
                    .all(|c| matches(r.get(&c.field).unwrap_or(&Value::Null), c))
            })
            .collect();
        for (name, desc) in query.sort.iter().rev() {
            // stable sort, nulls last ascending (and first descending), like the python SDK
            rows.sort_by(|a, b| {
                let (x, y) = (
                    a.get(name).unwrap_or(&Value::Null),
                    b.get(name).unwrap_or(&Value::Null),
                );
                let order = match (x.is_null(), y.is_null()) {
                    (true, true) => Ordering::Equal,
                    (true, false) => Ordering::Greater,
                    (false, true) => Ordering::Less,
                    _ => compare(x, y).unwrap_or(Ordering::Equal),
                };
                if *desc {
                    order.reverse()
                } else {
                    order
                }
            });
        }
        let total = rows.len() as u64;
        let page = rows
            .into_iter()
            .skip(query.offset as usize)
            .take(query.limit as usize)
            .cloned()
            .collect();
        Ok((total, page))
    }

    fn get(&self, pk: &Value) -> Result<Option<Record>> {
        let state = self.state.lock().expect("memory repository lock");
        Ok(Self::key(pk).and_then(|k| state.1.get(&k).cloned()))
    }

    fn add(&self, mut record: Record) -> Result<()> {
        let mut state = self.state.lock().expect("memory repository lock");
        state.0 += 1;
        let id = state.0;
        record.insert(self.pk.clone(), Value::from(id));
        state.1.insert(id, record);
        Ok(())
    }

    fn update(&self, pk: &Value, record: Record) -> Result<()> {
        let mut state = self.state.lock().expect("memory repository lock");
        if let Some(existing) = Self::key(pk).and_then(|k| state.1.get_mut(&k)) {
            for (key, value) in record {
                if key != self.pk {
                    existing.insert(key, value);
                }
            }
        }
        Ok(())
    }

    fn delete(&self, pks: &[Value]) -> Result<()> {
        let mut state = self.state.lock().expect("memory repository lock");
        for pk in pks {
            if let Some(k) = Self::key(pk) {
                state.1.remove(&k);
            }
        }
        Ok(())
    }
}
