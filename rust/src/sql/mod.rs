//! SQL repositories over a two-method executor. Identifiers are the model's field names, whitelisted when the
//! model was declared and quoted here; every value is a bound parameter. Driver adapters live behind cargo
//! features (`sqlite`, `postgres`, `mysql`) so the default build pulls no driver.
use std::sync::Arc;

use serde_json::Value;

use crate::model::Model;
use crate::repo::{Query, Repository};
use crate::types::QueryExpression;
use crate::values::{as_f64, number, parse_date_time};
use crate::{Error, Record, Result};

#[cfg(feature = "mysql")]
mod mysql;
#[cfg(feature = "postgres")]
mod postgres;
#[cfg(feature = "sqlite")]
mod sqlite;

#[cfg(feature = "mysql")]
pub use self::mysql::MysqlExecutor;
#[cfg(feature = "postgres")]
pub use self::postgres::PostgresExecutor;
#[cfg(feature = "sqlite")]
pub use self::sqlite::SqliteExecutor;

/// What a [`SqlRepository`] needs from a driver. Parameters are JSON scalars; dates arrive as the SDK's
/// wall-clock strings and rows may return them in any format the repository can parse.
pub trait SqlExecutor: Send + Sync {
    /// Rows keyed by column name.
    fn query(&self, sql: &str, params: &[Value]) -> Result<Vec<Record>>;
    fn execute(&self, sql: &str, params: &[Value]) -> Result<()>;
}

/// Decides placeholders, identifier quotes and paging.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Dialect {
    /// `?`, `"x"`, LIMIT / OFFSET
    Sqlite,
    /// `$1`, `"x"`, LIMIT / OFFSET
    Postgres,
    /// `?`, `` `x` ``, LIMIT / OFFSET
    Mysql,
    /// `@p0`, `[x]`, OFFSET .. FETCH (SQL Server 2012+)
    Mssql,
}

const SQL_OPS: [(QueryExpression, &str); 6] = [
    (QueryExpression::Eq, "="),
    (QueryExpression::Neq, "<>"),
    (QueryExpression::Gt, ">"),
    (QueryExpression::Gte, ">="),
    (QueryExpression::Lt, "<"),
    (QueryExpression::Lte, "<="),
];

/// Builds one statement: SQL text plus its bound values.
pub(crate) struct Sql {
    dialect: Dialect,
    pub(crate) params: Vec<Value>,
}

impl Sql {
    pub(crate) fn new(dialect: Dialect) -> Self {
        Sql {
            dialect,
            params: Vec::new(),
        }
    }

    pub(crate) fn p(&mut self, value: Value) -> String {
        self.params.push(value);
        match self.dialect {
            Dialect::Postgres => format!("${}", self.params.len()),
            Dialect::Mssql => format!("@p{}", self.params.len() - 1),
            Dialect::Sqlite | Dialect::Mysql => "?".to_string(),
        }
    }
}

/// A table behind any [`SqlExecutor`]. Create production tables yourself, with columns named like the
/// fields; `auto_create` only applies to SQLite.
pub struct SqlRepository {
    executor: Box<dyn SqlExecutor>,
    table: String,
    dialect: Dialect,
    auto_create: bool,
    model: Option<Arc<Model>>,
}

impl SqlRepository {
    pub fn new(executor: impl SqlExecutor + 'static, table: &str, dialect: Dialect) -> Self {
        SqlRepository {
            executor: Box::new(executor),
            table: table.to_string(),
            dialect,
            auto_create: false,
            model: None,
        }
    }

    /// Create the table when missing (SQLite only).
    pub fn auto_create(mut self) -> Self {
        self.auto_create = true;
        self
    }

    fn model(&self) -> &Model {
        self.model.as_deref().expect("bound repository")
    }

    fn pk(&self) -> &str {
        self.model().pk().unwrap_or("id")
    }

    pub(crate) fn q(&self, identifier: &str) -> String {
        let (open, close) = match self.dialect {
            Dialect::Mysql => ('`', '`'),
            Dialect::Mssql => ('[', ']'),
            Dialect::Sqlite | Dialect::Postgres => ('"', '"'),
        };
        let escaped = identifier.replace(close, &format!("{close}{close}"));
        format!("{open}{escaped}{close}")
    }

    pub(crate) fn where_clause(&self, query: &Query, sql: &mut Sql) -> Result<String> {
        let mut clauses = Vec::new();
        for f in &query.filters {
            // the developer's own SQL, as written; with params, each '?' is one of them, bound like every other value
            let pieces: Vec<&str> = if f.params.is_empty() {
                vec![&f.sql]
            } else {
                f.sql.split('?').collect()
            };
            if pieces.len() - 1 != f.params.len() {
                return Err(Error::Other(format!(
                    "filter: {} '?' for {} params in {:?}",
                    pieces.len() - 1,
                    f.params.len(),
                    f.sql
                )));
            }
            let mut text = pieces[0].to_string();
            for (v, piece) in f.params.iter().zip(&pieces[1..]) {
                text += &sql.p(v.clone());
                text += piece;
            }
            clauses.push(format!("({text})"));
        }
        for c in &query.conditions {
            let col = self.q(&c.field);
            let list = c.value.as_array().cloned().unwrap_or_default();
            let not = |negated: bool| if negated { "NOT " } else { "" };
            if let Some((_, op)) = SQL_OPS.iter().find(|(e, _)| *e == c.op) {
                clauses.push(format!("{col} {op} {}", sql.p(c.value.clone())));
                continue;
            }
            match c.op {
                QueryExpression::Like | QueryExpression::NotLike => {
                    // '!' rather than a backslash: MySQL reads a backslash inside a string literal as an escape itself
                    let mut escaped = crate::values::text(&c.value)
                        .replace('!', "!!")
                        .replace('%', "!%")
                        .replace('_', "!_");
                    if self.dialect == Dialect::Mssql {
                        escaped = escaped.replace('[', "![");
                    }
                    let mark = sql.p(Value::String(format!("%{escaped}%")));
                    clauses.push(format!(
                        "{col} {}LIKE {mark} ESCAPE '!'",
                        not(c.op == QueryExpression::NotLike)
                    ));
                }
                QueryExpression::Range if list.len() == 2 => {
                    let (a, b) = (sql.p(list[0].clone()), sql.p(list[1].clone()));
                    clauses.push(format!("{col} BETWEEN {a} AND {b}"));
                }
                QueryExpression::In | QueryExpression::NotIn => {
                    let negated = c.op == QueryExpression::NotIn;
                    if list.is_empty() {
                        clauses.push(if negated { "1=1" } else { "1=0" }.to_string());
                    } else {
                        let marks: Vec<String> = list.into_iter().map(|v| sql.p(v)).collect();
                        clauses.push(format!("{col} {}IN ({})", not(negated), marks.join(", ")));
                    }
                }
                QueryExpression::Null => clauses.push(format!("{col} IS NULL")),
                QueryExpression::NotNull => clauses.push(format!("{col} IS NOT NULL")),
                _ => clauses.push("1=0".to_string()),
            }
        }
        Ok(if clauses.is_empty() {
            String::new()
        } else {
            format!(" WHERE {}", clauses.join(" AND "))
        })
    }

    /// The SELECT of one page, exposed for tests of the generated SQL.
    pub(crate) fn page_sql(&self, query: &Query) -> Result<(String, Vec<Value>)> {
        let mut sql = Sql::new(self.dialect);
        let where_clause = self.where_clause(query, &mut sql)?;
        let order = if query.sort.is_empty() {
            format!("{} ASC", self.q(self.pk()))
        } else {
            query
                .sort
                .iter()
                .map(|(n, d)| format!("{} {}", self.q(n), if *d { "DESC" } else { "ASC" }))
                .collect::<Vec<_>>()
                .join(", ")
        };
        let paging = match self.dialect {
            Dialect::Mssql => {
                let (o, l) = (
                    sql.p(Value::from(query.offset)),
                    sql.p(Value::from(query.limit)),
                );
                format!("OFFSET {o} ROWS FETCH NEXT {l} ROWS ONLY")
            }
            _ => {
                let (l, o) = (
                    sql.p(Value::from(query.limit)),
                    sql.p(Value::from(query.offset)),
                );
                format!("LIMIT {l} OFFSET {o}")
            }
        };
        Ok((
            format!(
                "SELECT * FROM {}{where_clause} ORDER BY {order} {paging}",
                self.q(&self.table)
            ),
            sql.params,
        ))
    }

    /// Values read back, normalized by field type: drivers disagree on booleans, integer widths and dates.
    fn record(&self, row: Record) -> Record {
        let model = self.model();
        let mut record = Record::new();
        for (column, value) in row {
            let Some(f) = model
                .stored()
                .find(|f| f.name.eq_ignore_ascii_case(&column))
            else {
                record.insert(column, value);
                continue;
            };
            let value = match (&value, f.kind.as_str()) {
                (Value::Null, _) => Value::Null,
                (Value::String(s), _) if f.json => serde_json::from_str(s).unwrap_or(value),
                (_, "BOOLEAN") => Value::Bool(match &value {
                    Value::Bool(b) => *b,
                    Value::String(s) => s == "1" || s.eq_ignore_ascii_case("true"),
                    other => as_f64(other).map(|n| n != 0.0).unwrap_or(false),
                }),
                (_, "DATE") | (_, "DATE_TIME") => match value.as_str().and_then(parse_date_time) {
                    Some(d) if f.kind == "DATE" => Value::String(d.date_string()),
                    Some(d) => Value::String(d.date_time_string()),
                    None => value,
                },
                (_, kind) if kind == "NUMBER" || f.is_pk() || f.is_reference() => {
                    as_f64(&value).map(number).unwrap_or(value)
                }
                _ => value,
            };
            record.insert(f.name.clone(), value);
        }
        record
    }

    fn writable(&self, record: Record) -> Vec<(String, Value)> {
        let pk = self.pk().to_string();
        self.model()
            .stored()
            .filter(|f| f.name != pk)
            .filter_map(|f| {
                record.get(&f.name).map(|v| {
                    let v = match v {
                        // JSON text: a parameter is a scalar in every dialect
                        Value::Array(_) | Value::Object(_) if f.json => {
                            Value::String(v.to_string())
                        }
                        _ => v.clone(),
                    };
                    (f.name.clone(), v)
                })
            })
            .collect()
    }
}

impl Repository for SqlRepository {
    fn bind(&mut self, model: Arc<Model>) -> Result<()> {
        let valid = {
            let mut chars = self.table.chars();
            matches!(chars.next(), Some(c) if c.is_ascii_alphabetic() || c == '_')
                && chars.all(|c| c.is_ascii_alphanumeric() || c == '_')
        };
        if !valid {
            return Err(Error::Declaration(format!(
                "illegal table name '{}'",
                self.table
            )));
        }
        if model.pk().is_none() {
            return Err(Error::Declaration(format!(
                "{} has no primary key",
                model.name()
            )));
        }
        self.model = Some(model);
        if self.auto_create && self.dialect == Dialect::Sqlite {
            let columns: Vec<String> = self
                .model()
                .stored()
                .map(|f| {
                    let kind = match f.kind.as_str() {
                        _ if f.is_pk() => "INTEGER PRIMARY KEY AUTOINCREMENT",
                        "NUMBER" => "NUMERIC",
                        "BOOLEAN" | "REFERENCE_TABLE" | "REFERENCE_TREE" => "INTEGER",
                        "DATE" => "DATE",
                        "DATE_TIME" => "TIMESTAMP",
                        _ => "TEXT",
                    };
                    format!("{} {kind}", self.q(&f.name))
                })
                .collect();
            self.executor.execute(
                &format!(
                    "CREATE TABLE IF NOT EXISTS {} ({})",
                    self.q(&self.table),
                    columns.join(", ")
                ),
                &[],
            )?;
        }
        Ok(())
    }

    fn page(&self, query: &Query) -> Result<(u64, Vec<Record>)> {
        let mut sql = Sql::new(self.dialect);
        let where_clause = self.where_clause(query, &mut sql)?;
        let count = self.executor.query(
            &format!(
                "SELECT COUNT(*) AS n FROM {}{where_clause}",
                self.q(&self.table)
            ),
            &sql.params,
        )?;
        let total = count
            .first()
            .and_then(|r| r.values().next())
            .and_then(as_f64)
            .unwrap_or(0.0) as u64;
        let (text, params) = self.page_sql(query)?;
        let rows = self.executor.query(&text, &params)?;
        Ok((total, rows.into_iter().map(|r| self.record(r)).collect()))
    }

    fn get(&self, pk: &Value) -> Result<Option<Record>> {
        let mut sql = Sql::new(self.dialect);
        let text = format!(
            "SELECT * FROM {} WHERE {} = {}",
            self.q(&self.table),
            self.q(self.pk()),
            sql.p(pk.clone())
        );
        Ok(self
            .executor
            .query(&text, &sql.params)?
            .into_iter()
            .next()
            .map(|r| self.record(r)))
    }

    fn add(&self, record: Record) -> Result<()> {
        let mut sql = Sql::new(self.dialect);
        let columns = self.writable(record);
        let names: Vec<String> = columns.iter().map(|(n, _)| self.q(n)).collect();
        let marks: Vec<String> = columns.into_iter().map(|(_, v)| sql.p(v)).collect();
        let text = format!(
            "INSERT INTO {} ({}) VALUES ({})",
            self.q(&self.table),
            names.join(", "),
            marks.join(", ")
        );
        self.executor.execute(&text, &sql.params)
    }

    fn update(&self, pk: &Value, record: Record) -> Result<()> {
        let columns = self.writable(record);
        if columns.is_empty() {
            return Ok(());
        }
        let mut sql = Sql::new(self.dialect);
        let sets: Vec<String> = columns
            .into_iter()
            .map(|(n, v)| format!("{} = {}", self.q(&n), sql.p(v)))
            .collect();
        let text = format!(
            "UPDATE {} SET {} WHERE {} = {}",
            self.q(&self.table),
            sets.join(", "),
            self.q(self.pk()),
            sql.p(pk.clone())
        );
        self.executor.execute(&text, &sql.params)
    }

    fn delete(&self, pks: &[Value]) -> Result<()> {
        if pks.is_empty() {
            return Ok(());
        }
        let mut sql = Sql::new(self.dialect);
        let marks: Vec<String> = pks.iter().map(|pk| sql.p(pk.clone())).collect();
        let text = format!(
            "DELETE FROM {} WHERE {} IN ({})",
            self.q(&self.table),
            self.q(self.pk()),
            marks.join(", ")
        );
        self.executor.execute(&text, &sql.params)
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::repo::Cond;
    use crate::{Field, Model};
    use serde_json::json;

    fn repo(dialect: Dialect) -> SqlRepository {
        struct Never;
        impl SqlExecutor for Never {
            fn query(&self, _: &str, _: &[Value]) -> Result<Vec<Record>> {
                Ok(Vec::new())
            }
            fn execute(&self, _: &str, _: &[Value]) -> Result<()> {
                Ok(())
            }
        }
        let model = Model::new("Post", "Post")
            .field("id", Field::pk())
            .field("title", Field::input("Title").search())
            .field("views", Field::number("Views"))
            .build()
            .unwrap();
        let mut r = SqlRepository::new(Never, "post", dialect);
        r.bind(model).unwrap();
        r
    }

    #[test]
    fn dialects() {
        let query = Query {
            conditions: vec![
                Cond::new("title", QueryExpression::Like, json!("a%!_[")),
                Cond::new("views", QueryExpression::In, json!([1, 2])),
            ],
            sort: vec![],
            filters: vec![],
            offset: 0,
            limit: 10,
        };
        let cases = [
            (Dialect::Sqlite, "SELECT * FROM \"post\" WHERE \"title\" LIKE ? ESCAPE '!' AND \"views\" IN (?, ?) ORDER BY \"id\" ASC LIMIT ? OFFSET ?", "%a!%!!!_[%"),
            (Dialect::Postgres, "SELECT * FROM \"post\" WHERE \"title\" LIKE $1 ESCAPE '!' AND \"views\" IN ($2, $3) ORDER BY \"id\" ASC LIMIT $4 OFFSET $5", "%a!%!!!_[%"),
            (Dialect::Mysql, "SELECT * FROM `post` WHERE `title` LIKE ? ESCAPE '!' AND `views` IN (?, ?) ORDER BY `id` ASC LIMIT ? OFFSET ?", "%a!%!!!_[%"),
            (Dialect::Mssql, "SELECT * FROM [post] WHERE [title] LIKE @p0 ESCAPE '!' AND [views] IN (@p1, @p2) ORDER BY [id] ASC OFFSET @p3 ROWS FETCH NEXT @p4 ROWS ONLY", "%a!%!!!_![%"),
        ];
        for (dialect, text, pattern) in cases {
            let (sql, params) = repo(dialect).page_sql(&query).unwrap();
            assert_eq!(text, sql, "{dialect:?}");
            assert_eq!(json!(pattern), params[0], "{dialect:?}");
        }
        assert_eq!("`we``ird`", repo(Dialect::Mysql).q("we`ird"));
        assert_eq!("[we]]ird]", repo(Dialect::Mssql).q("we]ird"));
    }

    #[test]
    fn filters() {
        let query = Query {
            conditions: vec![Cond::new("views", QueryExpression::Gt, json!(1))],
            filters: vec![
                "views < 9".into(),
                crate::Filter::new("title = ? OR title = ?", vec![json!("a"), json!("b")]),
            ],
            ..Query::default()
        };
        let (sql, params) = repo(Dialect::Postgres).page_sql(&query).unwrap();
        assert_eq!("SELECT * FROM \"post\" WHERE (views < 9) AND (title = $1 OR title = $2) AND \"views\" > $3 ORDER BY \"id\" ASC LIMIT $4 OFFSET $5", sql);
        assert_eq!(
            vec![json!("a"), json!("b"), json!(1), json!(10), json!(0)],
            params
        );
        let query = Query {
            filters: vec!["title = 'a?'".into()],
            ..Query::default()
        };
        let (sql, _) = repo(Dialect::Sqlite).page_sql(&query).unwrap();
        assert!(sql.contains("WHERE (title = 'a?')"), "{sql}");
        let query = Query {
            filters: vec![crate::Filter::new(
                "title = ?",
                vec![json!("a"), json!("b")],
            )],
            ..Query::default()
        };
        assert!(repo(Dialect::Sqlite).page_sql(&query).is_err());
    }
}
