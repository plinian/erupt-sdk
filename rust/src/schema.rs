//! Checks annotation JSON against erupt-annotations.schema.json (the schema `types.rs` is generated from), so
//! a misspelt attribute or an unknown enum value fails when a model is declared instead of silently doing
//! nothing in the browser.
use std::sync::OnceLock;

use serde_json::Value;

static SCHEMA: OnceLock<Value> = OnceLock::new();
static DEFAULTS: OnceLock<Value> = OnceLock::new();

pub(crate) fn defaults() -> &'static Value {
    DEFAULTS.get_or_init(|| {
        serde_json::from_str(include_str!("../erupt-node-defaults.json")).expect("bundled defaults")
    })
}

/// The declared defaults of an annotation, as Java fills an attribute left out.
pub(crate) fn annotation_defaults(name: &str) -> serde_json::Map<String, Value> {
    defs()[name]["properties"]
        .as_object()
        .into_iter()
        .flatten()
        .filter_map(|(k, v)| Some((k.clone(), v.get("default")?.clone())))
        .collect()
}

fn defs() -> &'static serde_json::Map<String, Value> {
    SCHEMA.get_or_init(|| {
        serde_json::from_str(include_str!("../erupt-annotations.schema.json"))
            .expect("bundled schema")
    })["$defs"]
        .as_object()
        .expect("$defs")
}

/// Err unless `value` fits definition `name`. `partial` (an override) lets every attribute be omitted;
/// otherwise the attributes the Java side always emits must be present.
pub fn check(name: &str, value: &Value, path: &str, partial: bool) -> Result<(), String> {
    check_ref(name, value, path, partial)
}

fn check_ref(name: &str, value: &Value, path: &str, partial: bool) -> Result<(), String> {
    let def = &defs()[name];
    if let Some(values) = def.get("enum").and_then(Value::as_array) {
        return if values.contains(value) {
            Ok(())
        } else {
            let names: Vec<&str> = values.iter().filter_map(Value::as_str).collect();
            Err(format!(
                "{path}: '{}' is not a {name}, expected one of {}",
                show(value),
                names.join(", ")
            ))
        };
    }
    let Some(object) = value.as_object() else {
        return Err(format!("{path}: expected an object ({name})"));
    };
    let props = def["properties"].as_object().expect("properties");
    for (key, item) in object {
        let Some(schema) = props.get(key) else {
            return Err(format!("{path}: {name} has no attribute '{key}'"));
        };
        check_schema(schema, item, &format!("{path}.{key}"), partial)?;
    }
    if !partial {
        let missing: Vec<&str> = def
            .get("required")
            .and_then(Value::as_array)
            .map(|r| {
                r.iter()
                    .filter_map(Value::as_str)
                    .filter(|k| !object.contains_key(*k))
                    .collect()
            })
            .unwrap_or_default();
        if !missing.is_empty() {
            return Err(format!("{path}: missing {}", missing.join(", ")));
        }
    }
    Ok(())
}

fn check_schema(schema: &Value, value: &Value, path: &str, partial: bool) -> Result<(), String> {
    if let Some(r) = schema.get("$ref").and_then(Value::as_str) {
        return check_ref(r.rsplit('/').next().unwrap_or(r), value, path, partial);
    }
    match schema["type"].as_str().unwrap_or("") {
        "array" => {
            let items = value
                .as_array()
                .ok_or_else(|| format!("{path}: expected an array"))?;
            for (i, item) in items.iter().enumerate() {
                check_schema(&schema["items"], item, &format!("{path}[{i}]"), partial)?;
            }
            Ok(())
        }
        "object" => {
            let object = value
                .as_object()
                .ok_or_else(|| format!("{path}: expected an object"))?;
            if let Some(item_schema) = schema.get("additionalProperties") {
                for (key, item) in object {
                    check_schema(item_schema, item, &format!("{path}.{key}"), partial)?;
                }
            }
            Ok(())
        }
        kind => {
            let ok = match kind {
                "string" => value.is_string(),
                "integer" => value.is_i64() || value.is_u64(),
                "number" => value.is_number(),
                "boolean" => value.is_boolean(),
                _ => false,
            };
            if ok {
                Ok(())
            } else {
                Err(format!("{path}: expected {kind}, got {value}"))
            }
        }
    }
}

fn show(value: &Value) -> String {
    value
        .as_str()
        .map(str::to_string)
        .unwrap_or_else(|| value.to_string())
}
