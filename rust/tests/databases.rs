//! SqlRepository against real PostgreSQL and MySQL. Runs only when ERUPT_TEST_DATABASES is set (the databases
//! workflow starts both as service containers); connection settings come from the standard PG* variables and
//! MYSQL_HOST / MYSQL_PORT / MYSQL_USER / MYSQL_DATABASE (empty passwords). Needs the postgres and mysql features.
use erupt::types::QueryExpression::{self, *};
use erupt::{
    Cond, Dialect, Field, Model, MysqlExecutor, PostgresExecutor, Query, Record, Repository,
    SqlExecutor, SqlRepository,
};
use serde_json::{json, Value};

fn enabled() -> bool {
    std::env::var("ERUPT_TEST_DATABASES")
        .map(|v| !v.is_empty())
        .unwrap_or(false)
}

fn env(name: &str, fallback: &str) -> String {
    std::env::var(name)
        .ok()
        .filter(|v| !v.is_empty())
        .unwrap_or_else(|| fallback.to_string())
}

fn record(value: Value) -> Record {
    value.as_object().cloned().unwrap()
}

fn scenario(executor: impl SqlExecutor + 'static, dialect: Dialect, ddl: &[&str]) {
    for sql in ddl {
        executor.execute(sql, &[]).unwrap();
    }
    let model = Model::new("DbPost", "Post")
        .field("id", Field::pk())
        .field("title", Field::input("Title").search())
        .field("views", Field::number("Views"))
        .field("live", Field::boolean("Live"))
        .field("day", Field::date("Day"))
        .field("at", Field::date_time("At"))
        .build()
        .unwrap();
    let mut repo = SqlRepository::new(executor, "db_post", dialect);
    repo.bind(model).unwrap();
    repo.add(record(json!({"title": "100% pure", "views": 3, "live": true, "day": "2026-01-05", "at": "2026-01-05T10:30:00.123"}))).unwrap();
    repo.add(record(
        json!({"title": "wow!", "views": 1, "live": false, "day": "2026-03-01", "at": null}),
    ))
    .unwrap();
    repo.add(record(
        json!({"title": "a_b", "views": null, "live": false, "day": null, "at": null}),
    ))
    .unwrap();
    let titles =
        |conds: Vec<(&str, QueryExpression, Value)>, sort: Vec<(String, bool)>| -> Vec<String> {
            let conditions = conds
                .into_iter()
                .map(|(f, op, v)| Cond::new(f, op, v))
                .collect();
            let (_, rows) = repo
                .page(&Query {
                    conditions,
                    sort,
                    filters: vec![],
                    offset: 0,
                    limit: 10,
                })
                .unwrap();
            rows.iter()
                .map(|r| r["title"].as_str().unwrap().to_string())
                .collect()
        };
    let by_title = || vec![("title".to_string(), false)];
    assert_eq!(
        vec!["100% pure", "wow!", "a_b"],
        titles(vec![], vec![]),
        "default order is primary key ascending"
    );
    assert_eq!(
        vec!["100% pure"],
        titles(vec![("title", Like, json!("%"))], by_title()),
        "LIKE escapes %"
    );
    assert_eq!(
        vec!["wow!"],
        titles(vec![("title", Like, json!("!"))], by_title()),
        "LIKE escapes !"
    );
    assert_eq!(
        vec!["a_b"],
        titles(vec![("title", Like, json!("_"))], by_title()),
        "LIKE escapes _"
    );
    assert_eq!(
        vec!["a_b", "wow!"],
        titles(vec![("title", NotLike, json!("pure"))], by_title()),
        "NOT_LIKE"
    );
    assert_eq!(
        vec!["100% pure", "wow!"],
        titles(vec![("views", In, json!([1, 3]))], by_title()),
        "IN"
    );
    assert!(
        titles(vec![("views", In, json!([]))], by_title()).is_empty(),
        "empty IN"
    );
    assert_eq!(
        vec!["wow!"],
        titles(
            vec![("day", Range, json!(["2026-02-01", "2026-12-31"]))],
            by_title()
        ),
        "RANGE"
    );
    assert_eq!(
        vec!["100% pure"],
        titles(vec![("live", Eq, json!(true))], by_title()),
        "boolean"
    );
    assert_eq!(
        vec!["100% pure"],
        titles(vec![("views", Gt, json!(2))], by_title()),
        "GT"
    );
    assert_eq!(
        vec!["a_b"],
        titles(vec![("views", Null, Value::Null)], by_title()),
        "NULL"
    );
    let (total, page) = repo
        .page(&Query {
            conditions: vec![],
            sort: vec![("views".into(), true)],
            filters: vec![],
            offset: 1,
            limit: 1,
        })
        .unwrap();
    assert_eq!((3, 1), (total, page.len()), "total and page size");
    let row = repo.get(&json!(1)).unwrap().unwrap();
    assert_eq!(
        json!({"id": 1, "title": "100% pure", "views": 3, "live": true, "day": "2026-01-05", "at": "2026-01-05T10:30:00.123"}),
        Value::Object(row),
        "round trip"
    );
    repo.update(
        &json!(1),
        record(json!({"title": "renamed", "live": false})),
    )
    .unwrap();
    let row = repo.get(&json!(1)).unwrap().unwrap();
    assert_eq!(
        (json!("renamed"), json!(false)),
        (row["title"].clone(), row["live"].clone()),
        "update"
    );
    repo.delete(&[json!(1), json!(2)]).unwrap();
    assert_eq!(vec!["a_b"], titles(vec![], by_title()), "delete");
    assert!(repo.get(&json!(1)).unwrap().is_none(), "deleted");
}

#[test]
fn postgres() {
    if !enabled() {
        return;
    }
    let params = format!(
        "host={} port={} user={} dbname={}",
        env("PGHOST", "127.0.0.1"),
        env("PGPORT", "5432"),
        env("PGUSER", "postgres"),
        env("PGDATABASE", "erupt")
    );
    scenario(
        PostgresExecutor::connect(&params).unwrap(),
        Dialect::Postgres,
        &[
            r#"DROP TABLE IF EXISTS "db_post""#,
            r#"CREATE TABLE "db_post" ("id" SERIAL PRIMARY KEY, "title" VARCHAR(255), "views" INTEGER, "live" BOOLEAN, "day" DATE, "at" TIMESTAMP(3))"#,
        ],
    );
}

#[test]
fn mysql() {
    if !enabled() {
        return;
    }
    let url = format!(
        "mysql://{}@{}:{}/{}",
        env("MYSQL_USER", "root"),
        env("MYSQL_HOST", "127.0.0.1"),
        env("MYSQL_PORT", "3306"),
        env("MYSQL_DATABASE", "erupt")
    );
    scenario(
        MysqlExecutor::connect(&url).unwrap(),
        Dialect::Mysql,
        &[
            "DROP TABLE IF EXISTS `db_post`",
            "CREATE TABLE `db_post` (`id` INT AUTO_INCREMENT PRIMARY KEY, `title` VARCHAR(255), `views` INT, `live` BOOLEAN, `day` DATE, `at` DATETIME(3))",
        ],
    );
}
