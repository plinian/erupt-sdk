# erupt-sdk (Rust)

Serve Rust models as erupt admin pages through an erupt cloud server. The default build depends on `serde`,
`serde_json` and `ctrlc` only; database drivers are opt-in features.

```toml
[dependencies]
erupt-sdk = { version = "0.1", features = ["sqlite"] }   # or "postgres", "mysql"
```

```rust
use erupt::types::RowOperationMode;
use erupt::{Dialect, Field, Model, Node, Operation, SqlRepository, SqliteExecutor};
use serde_json::json;

let category = Model::new("Category", "Category")
    .field("id", Field::pk())
    .field("name", Field::input("Name").search())
    .field("parent", Field::number("Parent Id"))
    .build()?;
let article = Model::new("Article", "Article")
    .order_by("id desc")
    .field("id", Field::pk())
    .field("title", Field::input("Title").search().not_null().sortable().edit(json!({"inputType": {"length": 64}})))
    .field("status", Field::choice("Status", &[("draft", "Draft"), ("published", "Published")]).search())
    .field("category", Field::reference(&category, "Category").search())     // table picker
    .field("topic", Field::reference(&category, "Topic").tree("parent"))     // tree picker
    .operation(Operation::new("feature", "Feature").mode(RowOperationMode::Single).handler(|op| {
        op.repo.update(&op.rows[0]["id"], json!({"featured": true}).as_object().cloned().unwrap())?;
        Ok(None)
    }))
    .build()?;

let mut node = Node::new("blog", &std::env::var("ERUPT_ACCESS_TOKEN")?, ["http://erupt-server:8080"]);
node.register(&category, SqlRepository::new(SqliteExecutor::open("blog.db")?, "category", Dialect::Sqlite).auto_create())?;
node.register(&article, SqlRepository::new(SqliteExecutor::open("blog.db")?, "article", Dialect::Sqlite).auto_create())?;
node.serve("0.0.0.0", 9090)?;   // blocks; SIGINT / SIGTERM deregister and exit
```

1. On the erupt server create node `blog` (Node Config) and copy its access token.
2. Add menus of type `table` with values `blog.Article`, `blog.Category`.
3. Run the node. The server must reach it at the detected address (IPv4 preferred); otherwise set
   `.address("http://10.0.0.12:9090")`.

`examples/blog.rs` is the full blog (`cargo run --features sqlite --example blog`).

## Declaring models

- Fields: `Field::pk()`, `input`, `textarea`, `number`, `boolean`, `date`, `date_time`, `choice`,
  `reference(&model, title)` (+ `.tree(pid)` for a tree picker, `.label(field)`), or `Field::of(EditType, title)`.
  Flags: `.search()`, `.not_null()`, `.sortable()`, `.hide_table()`, `.hide_form()`.
- Raw annotation attributes: `.edit(...)`, `.view(...)` on fields, `.raw(...)` on models and operations take
  `json!` or the generated types in `erupt::types` (`Edit`, `View`, `Erupt`, `RowOperation`, …). They are
  validated against the erupt annotation schema when `build()` runs: a misspelt key or enum value is a
  `Error::Declaration`, not a silent no-op in the browser.
- Operations: `Operation::new(code, title)` with `.mode(RowOperationMode::…)`, `.form(&model)` (a model without
  a primary key), `.no_confirm()` / `.confirm(text)`, `.show(|user| …)`, `.if_expr(js)`, `.handler(|op| …)`.
  A handler gets `op.rows`, `op.param`, `op.repo`, `op.user`; `Ok(Some(script))` is run as JavaScript in the
  browser, so return only code you wrote; `Err(Error::fail(msg))` shows `msg` to the user.
- Records are `serde_json::Map` (`erupt::Record`); dates are wall-clock strings `YYYY-MM-DD` and
  `YYYY-MM-DDTHH:MM:SS.mmm`.

## Storage

`Repository` (`bind`, `page`, `get`, `add`, `update`, `delete`) puts a model on anything; without a sort it
returns rows by primary key ascending. Shipped: `MemoryRepository` (tests, demos) and `SqlRepository` over a
two-method `SqlExecutor`, with a `Dialect` that decides placeholders, quoting and paging. Identifiers are the
field names, quoted; values are always bound; LIKE escapes with `ESCAPE '!'`.

| Database | Feature | Executor | Dialect |
|----------|---------|----------|---------|
| SQLite | `sqlite` (rusqlite, bundled) | `SqliteExecutor::open(path)` | `Dialect::Sqlite`, `.auto_create()` |
| PostgreSQL | `postgres` (sync `postgres` crate) | `PostgresExecutor::connect("host=… user=… dbname=…")` | `Dialect::Postgres` |
| MySQL | `mysql` | `MysqlExecutor::connect("mysql://user@host:3306/db")` | `Dialect::Mysql` |
| SQL Server, others | — | implement `SqlExecutor` (two methods) | `Dialect::Mssql` |

Create production tables yourself, with columns named like the fields. The PostgreSQL executor converts
parameters to the types the server reports (PostgreSQL refuses text for date or integer columns).

## Mounting in another server

`Node::handle(&Request) -> Response` is framework neutral and blocking. With axum, for example:

```rust
let node = Arc::new(node.address("http://10.0.0.12:9090"));
node.start_heartbeat();                  // and call node.deregister() on shutdown
let app = Router::new().fallback(move |method: Method, uri: Uri, headers: HeaderMap, body: Bytes| {
    let node = node.clone();
    async move {
        let mut request = erupt::http::Request::new(method.as_str(), &uri.to_string()).body(body.to_vec());
        for (name, value) in &headers {
            request = request.header(name.as_str(), value.to_str().unwrap_or(""));
        }
        let response = tokio::task::spawn_blocking(move || node.handle(&request)).await.unwrap();
        (StatusCode::from_u16(response.status).unwrap(), [("content-type", response.content_type)], response.body)
    }
});
```

The built-in server (`Node::serve`) is HTTP/1.1 on std::net with a thread pool, one request per
connection, 64 KiB header and 16 MiB body limits and 30 s timeouts. Calls back to the erupt server
(registration, per-user power) are plain `http://`; put a TLS-terminating proxy in front of an https server.

## Without a registry

From the repository, without crates.io (Cargo finds the crate inside the repository):

```toml
erupt-sdk = { git = "https://github.com/erupt-io/erupt-sdk", tag = "rust/v0.1.0", features = ["sqlite"] }
```

Or copy `rust/` (`Cargo.toml`, `src/` and the two `.json` files, which are compiled in) into your workspace and
use `erupt-sdk = { path = "third_party/erupt-sdk", features = ["sqlite"] }`. A copy does not update itself: when erupt changes the protocol or the annotation schema, replace the whole directory with the next release instead of merging by hand, and leave `VERSION` in `node.rs` untouched so the server shows which release the node runs.

## Generated code

`src/types.rs` is generated from the erupt annotation JSON Schema; the schema and the field templates are
bundled from `erupt-annotations.schema.json` and `erupt-node-defaults.json`.

```bash
cargo run --bin gen-types -- ../schema          # sync schemas, regenerate src/types.rs
cargo run --bin gen-types -- ../schema --check  # CI: fail when stale
```

## Differences from Python

- Field types are explicit constructors (no type annotations to infer from).
- Operation codes are explicit; models need `build()` (where every declaration error surfaces).
- The API is synchronous; under an async runtime call `handle` through `spawn_blocking`.
- A request body that is not a JSON object counts as empty (Python answers 500).

Tests: `cargo test --all-features` (real databases: see `tests/databases.rs`).
