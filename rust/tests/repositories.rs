use std::sync::Arc;

use erupt::types::QueryExpression::{self, *};
use erupt::{Cond, Field, MemoryRepository, Model, Query, Record, Repository};
use serde_json::{json, Value};

fn model() -> Arc<Model> {
    Model::new("Post", "Post")
        .field("id", Field::pk())
        .field("title", Field::input("Title").search())
        .field("views", Field::number("Views"))
        .field("live", Field::boolean("Live"))
        .field("day", Field::date("Day"))
        .field("at", Field::date_time("At"))
        .build()
        .unwrap()
}

fn record(value: Value) -> Record {
    value.as_object().cloned().unwrap()
}

fn scenario(kind: &str, mut repo: Box<dyn Repository>) {
    repo.bind(model()).unwrap();
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
        "{kind}: default order is primary key ascending"
    );
    assert_eq!(
        vec!["100% pure"],
        titles(vec![("title", Like, json!("%"))], by_title()),
        "{kind}: LIKE %"
    );
    assert_eq!(
        vec!["wow!"],
        titles(vec![("title", Like, json!("!"))], by_title()),
        "{kind}: LIKE !"
    );
    assert_eq!(
        vec!["a_b"],
        titles(vec![("title", Like, json!("_"))], by_title()),
        "{kind}: LIKE _"
    );
    assert_eq!(
        vec!["a_b", "wow!"],
        titles(vec![("title", NotLike, json!("pure"))], by_title()),
        "{kind}: NOT_LIKE"
    );
    assert_eq!(
        vec!["100% pure", "wow!"],
        titles(vec![("views", In, json!([1, 3]))], by_title()),
        "{kind}: IN"
    );
    assert!(
        titles(vec![("views", In, json!([]))], by_title()).is_empty(),
        "{kind}: empty IN"
    );
    assert_eq!(
        vec!["wow!"],
        titles(
            vec![("day", Range, json!(["2026-02-01", "2026-12-31"]))],
            by_title()
        ),
        "{kind}: RANGE"
    );
    assert_eq!(
        vec!["100% pure"],
        titles(vec![("live", Eq, json!(true))], by_title()),
        "{kind}: boolean"
    );
    assert_eq!(
        vec!["100% pure"],
        titles(vec![("views", Gt, json!(2))], by_title()),
        "{kind}: GT"
    );
    assert_eq!(
        vec!["a_b"],
        titles(vec![("views", Null, Value::Null)], by_title()),
        "{kind}: NULL"
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
    assert_eq!((3, 1), (total, page.len()), "{kind}: total and page size");
    let row = repo.get(&json!(1)).unwrap().unwrap();
    assert_eq!(
        json!({"id": 1, "title": "100% pure", "views": 3, "live": true, "day": "2026-01-05", "at": "2026-01-05T10:30:00.123"}),
        Value::Object(row),
        "{kind}: round trip"
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
        "{kind}: update"
    );
    repo.delete(&[json!(1), json!(2)]).unwrap();
    assert_eq!(vec!["a_b"], titles(vec![], by_title()), "{kind}: delete");
    assert!(repo.get(&json!(1)).unwrap().is_none(), "{kind}: deleted");
}

#[test]
fn memory() {
    scenario("memory", Box::new(MemoryRepository::new()));
}

#[cfg(feature = "sqlite")]
#[test]
fn sqlite() {
    use erupt::{Dialect, SqlRepository, SqliteExecutor};
    scenario(
        "sqlite",
        Box::new(
            SqlRepository::new(
                SqliteExecutor::open(":memory:").unwrap(),
                "post",
                Dialect::Sqlite,
            )
            .auto_create(),
        ),
    );
}
