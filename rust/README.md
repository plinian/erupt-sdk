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

## DataProxy

Hooks around a model's reads and writes, as erupt's Java `DataProxy`. Implement what you need; return
`Err(Error::fail(msg))` to refuse with a message the user sees.

```rust
use erupt::{current_user, Cond, DataProxy, Error, Filter, Record};
use serde_json::json;

struct ArticleProxy;

impl DataProxy for ArticleProxy {
    fn add_behavior(&self, record: &mut Record) -> erupt::Result<()> {   // the new form's values
        record.insert("status".into(), json!("draft"));
        Ok(())
    }

    fn validate(&self, record: &Record) -> erupt::Result<()> {          // before every add and update
        match record.get("title").and_then(|t| t.as_str()) {
            Some(t) if t.contains("spam") => Err(Error::fail("no spam")),
            _ => Ok(()),
        }
    }

    fn before_fetch(&self, conditions: &[Cond]) -> erupt::Result<Option<Filter>> {  // SQL ANDed to the table's WHERE, values bound
        let uid = current_user().map(|u| u["uid"].clone()).unwrap_or_default();
        Ok(Some(Filter::new("owner = ?", vec![uid])))
    }
}

let article = Model::new("Article", "Article")
    .data_proxy(ArticleProxy)   // call again to add more; they run in that order
    // .field(...)
    .build()?;
```

| Hook | Runs |
|------|------|
| `search_condition(condition)` | building the model: default values of the search bar |
| `before_fetch(conditions)` | before a table page is read: SQL ANDed to its WHERE as written, `"sql".into()` or `Filter::new("sql with ?", values)` (with values, each `?` is one of them); SQL repositories only, `MemoryRepository` refuses it |
| `after_fetch(rows)` | after a table page is read |
| `add_behavior(record)` | for the new record form (`init-value`) |
| `edit_behavior(record)` | after a record is read by its key (edit form, detail view) |
| `validate(record)` | before an add or an update |
| `before_add` / `after_add(record)` | around `repository.add` |
| `before_update` / `after_update(record)` | around `repository.update`, with the submitted values |
| `before_delete` / `after_delete(record)` | around `repository.delete`, once per record as stored |

## Views

`vis` in `.raw(...)` declares the extra views of `@Erupt(vis = ...)`. A view's `filter` (one SQL string or a
list, ANDed as written) and `orderBy` (as `.order_by`) are applied by the node when the table is read for that
view, and kept out of the build, as Java keeps them `@Transient`; they are SDK-only keys, so give them with
`json!` (the generated `types::Vis` has no such fields). A view without a `code` is addressed by its title.
Like `before_fetch`, a filter needs a SQL repository.

```rust
let task = Model::new("Task", "Task")
    .raw(json!({"vis": [
        {"title": "Board", "type": "BOARD", "boardView": {"groupField": "status"}, "filter": "archived = 0"},
        {"title": "Recent", "type": "TABLE", "orderBy": "created desc"},
    ]}))
    // .field(...)
    .build()?;
```

Dragging on a board, calendar or gantt view is saved by the erupt server through the node's `get` and `update`.

## Trees

`.raw(json!({"tree": {"id": "id", "label": "name", "pid": "parent"}}))` shows the model as a tree, and
`.raw(json!({"linkTree": {"field": "category"}}))` puts the tree of a reference field beside the table: the
erupt server builds both trees from the node's table, and the node keeps the rows under the picked tree node
(`"dependNode": true` shows none until one is picked). `linkTree.field` must be a reference field.

## Field types and field code

Besides the constructors above, `Field::of(EditType::…)` takes `Tags`, `AutoComplete`, `Attachment` (the erupt
server stores the upload, the node keeps its path), `HtmlEditor`, `Markdown`, `CodeEditor` (all text) and
`Button` (form only); `Field::multi_choice` is a `MULTI_CHOICE`, and `Field::checkbox` / `Field::tab_tree`
take another model: the picked records, stored as the JSON list of their keys.

A field can run its own code; the erupt server calls it through the node's `invoke` endpoint with the form's
values:

```rust
let order = Model::new("Order", "Order")
    .field("id", Field::pk())
    .field("status", Field::choice("Status", &[])            // options, fetched when the form opens
        .fetch(|form| Ok(vec![("new".into(), "New".into()), ("paid".into(), "Paid".into())])))
    .field("qty", Field::number("Qty")
        .onchange(|form| Ok(json!({"formData": {"total": as_f64(&form["qty"]).unwrap_or(0.0) * 9.0}, "editExpr": {}}))))
    .field("city", Field::of(EditType::AutoComplete, "City").complete(|form, typed| lookup(typed)))
    .field("total", Field::number("Total"))
    .field("recalc", Field::of(EditType::Button, "Recalc")
        .click(|form| Ok(json!({"eval": "alert('done')", "formData": {}}))))
    .field("tags", Field::checkbox(&tag, "Tags"))
    .build()?;
```

`fetch` belongs to `CHOICE` / `MULTI_CHOICE`, `fetch_tags` (a `Vec<String>`) to `TAGS`, `complete` to
`AUTO_COMPLETE`, `click` to `BUTTON`, `onchange` to any field; another type fails at `build()`. Return
`Err(Error::fail(msg))` to refuse with a message.

Also: `Color`, `Icon`, `Signature`, `Map`, `Hidden` (text), `Rate`, `Slider` (numbers), and `Field::transfer`
(like `Field::checkbox`). A reference table depending on another field takes
`.edit(json!({"referenceTableType": {"dependField": "province", "dependColumn": "province"}}))`: the erupt server
keeps the picked model's rows whose `dependColumn` holds the depend field's value.

## Drills

```rust
Model::new("Author", "Author")
    .raw(json!({"drills": [{"title": "Books", "link": {"linkErupt": "Book", "joinColumn": "author"}}]}))
```

opens `Book` filtered to the rows whose `author` holds the author's `id` (`link.column`, `id` by default);
`link.linkCondition` adds SQL as written. Both models must be on the node.

## Server config and user info

`node.config()` and `node.group_config()` return the config text set for the node and its group on the erupt
server; `node.user_info()` the acting user's full info (roles, org, post), on the thread serving a request.

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
