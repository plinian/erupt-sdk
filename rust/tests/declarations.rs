use std::path::Path;

use erupt::types::{Edit, InputType, RowOperationMode};
use erupt::{schema, Error, Field, Model, Operation};
use serde_json::json;

#[path = "../tools/generate.rs"]
mod generate;

fn declaration_error(builder: erupt::ModelBuilder) -> String {
    match builder.build() {
        Err(Error::Declaration(m)) => m,
        Err(e) => panic!("expected a declaration error, got {e}"),
        Ok(_) => panic!("expected a declaration error"),
    }
}

fn base() -> erupt::ModelBuilder {
    Model::new("Bad", "Bad").field("id", Field::pk())
}

#[test]
fn rejects_unknown_annotation_values() {
    let cases = [
        (
            base().field(
                "t",
                Field::input("T").edit(json!({"inputTyp": {"length": 9}})),
            ),
            "Edit has no attribute 'inputTyp'",
        ),
        (
            base().field("t", Field::input("T").view(json!({"sortable": "yes"}))),
            "expected boolean",
        ),
        (
            base().field(
                "t",
                Field::input("T").edit(json!({"search": {"operator": "ABOUT"}})),
            ),
            "is not a QueryExpression",
        ),
        (
            base().raw(json!({"orderBy": "id"})),
            "Erupt has no attribute 'orderBy'",
        ),
        (
            base().raw(json!({"layout": {"pageSize": "10"}})),
            "expected integer",
        ),
        (base().order_by("missing desc"), "illegal order_by"),
        (
            base().raw(json!({"vis": [{"title": "V", "orderBy": "missing"}]})),
            "illegal order_by",
        ),
        (
            base().raw(json!({"vis": [{"title": "V", "filter": 1}]})),
            "a vis filter must be SQL text",
        ),
        (base().power(json!({"remove": false})), "illegal power"),
        (base().field("id2", Field::pk()), "at most one"),
        (
            base()
                .field("t", Field::input("T"))
                .field("t", Field::input("T")),
            "unique",
        ),
        (
            base().operation(
                Operation::new("go", "Go")
                    .raw(json!({"colour": "red"}))
                    .handler(|_| Ok(None)),
            ),
            "RowOperation has no attribute 'colour'",
        ),
        (
            base().operation(Operation::new("go", "Go")),
            "without a handler",
        ),
        (Model::new("not a name", "X"), "identifier"),
    ];
    for (builder, message) in cases {
        let error = declaration_error(builder);
        assert!(
            error.contains(message),
            "{error} does not contain {message}"
        );
    }
}

#[test]
fn references_are_checked() {
    let target = Model::new("Cat", "Cat")
        .field("id", Field::pk())
        .field("name", Field::input("Name"))
        .build()
        .unwrap();
    let form = Model::new("Form", "Form")
        .field("x", Field::input("X"))
        .build()
        .unwrap();
    assert!(
        declaration_error(base().field("c", Field::reference(&target, "C").label("title")))
            .contains("has no field 'title'")
    );
    assert!(
        declaration_error(base().field("c", Field::reference(&target, "C").tree("parent")))
            .contains("has no field 'parent'")
    );
    assert!(
        declaration_error(base().field("c", Field::reference(&form, "C")))
            .contains("has no primary key")
    );
}

#[test]
fn typed_and_raw_overrides_pass_through() {
    let typed = Edit {
        input_type: Some(InputType {
            length: Some(9),
            ..Default::default()
        }),
        ..Default::default()
    };
    let model = Model::new("Ok", "Ok")
        .raw(json!({"layout": {"pageSize": 30}}))
        .field("id", Field::pk())
        .field("t", Field::input("T").edit(typed))
        .operation(
            Operation::new("go", "Go")
                .mode(RowOperationMode::Button)
                .handler(|_| Ok(None)),
        )
        .build()
        .unwrap();
    assert_eq!("Ok", model.name());
    assert_eq!(Some("id"), model.pk());
}

#[test]
fn bundled_defaults_match_the_schema() {
    let defaults: serde_json::Value =
        serde_json::from_str(include_str!("../erupt-node-defaults.json")).unwrap();
    schema::check(
        "RowOperation",
        &defaults["rowOperation"],
        "rowOperation",
        false,
    )
    .unwrap();
    for (name, field) in defaults["fields"].as_object().unwrap() {
        schema::check("EruptField", &field["eruptFieldJson"], name, false).unwrap();
    }
}

#[test]
fn generated_types_are_current() {
    let dir = Path::new(env!("CARGO_MANIFEST_DIR"));
    let schema: serde_json::Value = serde_json::from_str(
        &std::fs::read_to_string(dir.join("erupt-annotations.schema.json")).unwrap(),
    )
    .unwrap();
    assert_eq!(
        generate::generate(&schema),
        std::fs::read_to_string(dir.join("src/types.rs")).unwrap(),
        "run cargo run --bin gen-types -- ../schema"
    );
}
