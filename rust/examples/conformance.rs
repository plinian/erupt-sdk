//! The conformance fixture (conformance/README.md) in Rust.
use erupt::types::RowOperationMode;
use erupt::{DataProxy, Error, Field, MemoryRepository, Model, Node, Operation, Record};
use serde_json::{json, Value};

fn record(value: Value) -> Record {
    value.as_object().cloned().unwrap_or_default()
}

struct NoteProxy;

impl DataProxy for NoteProxy {
    fn add_behavior(&self, record: &mut Record) -> erupt::Result<()> {
        record.insert("text".into(), json!("new"));
        Ok(())
    }

    fn validate(&self, record: &Record) -> erupt::Result<()> {
        if record.get("text") == Some(&json!("forbidden")) {
            return Err(Error::fail("forbidden text"));
        }
        Ok(())
    }
}

fn main() -> erupt::Result<()> {
    let category = Model::new("Category", "Category")
        .field("id", Field::pk())
        .field("name", Field::input("Name").search())
        .field("parent", Field::number("Parent"))
        .build()?;
    let publish_form = Model::new("PublishForm", "Publish Options")
        .field("note", Field::input("Note").not_null())
        .build()?;
    let article = Model::new("Article", "Article")
        .order_by("id desc")
        .field("id", Field::pk())
        .field(
            "title",
            Field::input("Title")
                .search()
                .not_null()
                .sortable()
                .edit(json!({"inputType": {"length": 64}})),
        )
        .field(
            "status",
            Field::choice("Status", &[("draft", "Draft"), ("published", "Published")]).search(),
        )
        .field("views", Field::number("Views").sortable())
        .field("featured", Field::boolean("Featured").search())
        .field("publish_date", Field::date("Publish Date").search())
        .field("review_at", Field::date_time("Review At"))
        .field("body", Field::textarea("Body").hide_table())
        .field("category", Field::reference(&category, "Category").search())
        .field("topic", Field::reference(&category, "Topic").tree("parent"))
        .operation(
            Operation::new("publish", "Publish")
                .icon("fa fa-paper-plane")
                .form(&publish_form)
                .if_expr("item.status !== 'published'")
                .handler(|op| {
                    for row in &op.rows {
                        op.repo
                            .update(&row["id"], record(json!({"status": "published"})))?;
                    }
                    Ok(None)
                }),
        )
        .operation(
            Operation::new("feature", "Feature")
                .mode(RowOperationMode::Single)
                .no_confirm()
                .handler(|_| Ok(Some("alert('featured')".to_string()))),
        )
        .operation(
            Operation::new("rebuild", "Rebuild")
                .mode(RowOperationMode::Button)
                .show(|user| {
                    user.and_then(|u| u.get("account")).and_then(Value::as_str) == Some("root")
                })
                .handler(|_| Ok(None)),
        )
        .build()?;
    let note = Model::new("Note", "Note")
        .power(json!({"delete": false}))
        .data_proxy(NoteProxy)
        .field("id", Field::pk())
        .field("text", Field::input("Text"))
        .build()?;

    let env = |name: &str| std::env::var(name).unwrap_or_default();
    let port: u16 = env("PORT").parse().expect("PORT");
    let mut node = Node::new(
        "conformance",
        &env("ERUPT_ACCESS_TOKEN"),
        [env("ERUPT_SERVER")],
    )
    .address(&format!("http://127.0.0.1:{port}"));
    node.register(
        &category,
        MemoryRepository::seeded(vec![
            record(json!({"name": "Tech", "parent": null})),
            record(json!({"name": "Python", "parent": 1})),
            record(json!({"name": "Life", "parent": null})),
        ]),
    )?;
    node.register(&article, MemoryRepository::new())?;
    node.register(&note, MemoryRepository::new())?;
    node.serve("127.0.0.1", port)
}
