# erupt-sdk (Swift)

Serve Swift models as an erupt admin UI. Swift 5.9+, macOS 13+ and Linux; the `EruptSDK` library depends on
nothing but Foundation (its own HTTP server, JSON and HMAC-SHA256), `EruptSQLite` adds the system libsqlite3.

```swift
// Package.swift
.package(url: "https://github.com/erupt-io/erupt-sdk-swift", from: "0.1.0"),
.target(name: "App", dependencies: [.product(name: "EruptSDK", package: "erupt-sdk-swift")]),
```

```swift
import EruptSDK

let article = try Model("Article", orderBy: "id desc") {
    Field("id", pk: true)
    Field("title", "Title", search: true, notNull: true, sortable: true)
    Field("status", "Status", search: true, choices: ["draft": "Draft", "published": "Published"])
    Field("publish_date", "Publish Date", .date, search: true)
    Field("body", "Body", type: .textarea, table: false)
}

let node = try Node(name: "blog", accessToken: ProcessInfo.processInfo.environment["ERUPT_ACCESS_TOKEN"]!,
                    servers: ["http://erupt-server:8080"])
try node.register(article, MemoryRepository())
try node.serve(port: 9090)
```

1. On the erupt server create node `blog` (Node Config) and copy its access token.
2. Add a menu of type `table` with value `blog.Article`.
3. Run the node. The server must be able to reach it on `http://<node ip>:9090`; pass `address:` otherwise.

`Field(name, title, kind)` infers the edit type from `kind`: `.string` (default) INPUT, `.number` NUMBER, `.bool`
BOOLEAN, `.date` DATE, `.dateTime` DATE with a time picker, `choices:` CHOICE; `type:` overrides it. `view:` /
`edit:` on a field and `erupt:` on a model take the typed annotation attributes generated from the erupt schema
(`Edit(inputType: InputType(length: 64))`, `Erupt(layout: Layout(pageSize: 30))`), and every value an enum
(`.textarea`, `.multiChoice`, `.single`); what they produce is checked against the schema when the model is
declared.

Records are `[String: JSON]` (`row["title"]`); `JSON` takes literals (`["status": "published", "views": 3]`).
Dates travel as text: a DATE as `2026-01-05`, a DATE_TIME as `2026-01-05T10:30:00.000`.

## Inside Vapor or Hummingbird

`Node.handle(_:)` answers one `NodeRequest`; `serve` only wraps it in the built-in HTTP/1.1 server. To share the
application's port instead, route the node's paths to it and call `start(port:)` / `stop()`:

```swift
// Vapor
for method in [HTTPMethod.GET, .POST] {
    app.on(method, "erupt-api", "**", body: .collect(maxSize: "32mb")) { req in try nodeResponse(req) }
}
app.get("node-health") { req in try nodeResponse(req) }
node.start(port: 8080)                       // registers http://<ip>:8080 with the erupt server

func nodeResponse(_ req: Request) throws -> Response {
    var headers: [String: String] = [:]
    req.headers.forEach { headers[$0.name] = $0.value }
    let body = req.body.data.map { Array($0.readableBytesView) } ?? []
    let r = node.handle(NodeRequest(method: req.method.rawValue, target: req.url.string, headers: headers, body: body))
    return Response(status: .init(statusCode: r.status), headers: ["Content-Type": r.contentType], body: .init(data: Data(r.body)))
}
```

The path a node is handed is the raw one the server signed (`/erupt-api/...`): mount it at the root, or strip the
mount point before building the `NodeRequest`.

## References

Pass another model (declared before, registered on the same node). The repository stores the referenced primary
key; the UI shows `label` (default `name`).

```swift
let category = try Model("Category") {
    Field("id", pk: true)
    Field("name", "Name", search: true)
    Field("parent", "Parent Id", .number)
}

let article = try Model("Article") {
    // ...
    Field("category", "Category", .ref(category), search: true)          // table picker
    Field("topic", "Topic", .tree(category, pid: "parent"))               // tree picker over Category.parent
}
```

## Row operations

```swift
let publishForm = try Model("PublishForm", title: "Publish Options") {   // a form model needs no primary key
    Field("publish_date", "Publish Date", .date, notNull: true)
}

let article = try Model("Article") {
    // ...
    RowAction("publish", "Publish", form: publishForm, ifExpr: "item.status !== 'published'") { op in
        for row in op.rows {
            try op.repo.update(row["id"]!, ["status": "published", "publish_date": op.param!["publish_date"]!])
        }
        return nil                                                        // op.rows, op.param, op.repo, op.user
    }
}
```

`mode:` `.single` / `.multi` (default) / `.multiOnly` / `.button`. `confirm: false` skips the dialog, a string
replaces its text. `show: { user in ... }` hides the operation and refuses to run it. Throw `EruptFailure("...")`
to show a message; a returned string is executed as JavaScript in the browser, so return only code you wrote.
`User.current` is the acting user anywhere a request is served, repositories included.

## DataProxy

Hooks around a model's reads and writes, as erupt's Java `DataProxy`. Implement what you need (the rest default to
no-ops); throw `EruptFailure` to refuse with a message the user sees.

```swift
struct ArticleProxy: DataProxy {
    func addBehavior(_ record: inout Record) {             // the new form's values
        record["status"] = "draft"
    }

    func validate(_ record: Record) throws {               // before every add and update
        if record["title"]?.text.contains("spam") == true { throw EruptFailure("no spam") }
    }

    func beforeFetch(_ conditions: [Cond]) -> SQLFilter? {  // SQL ANDed to the table's WHERE, values bound
        SQLFilter("owner = ?", [.string(User.current?.account ?? "")])
    }

    func afterFetch(_ rows: inout [Record]) {              // a table page, before it is sent
        for i in rows.indices { rows[i]["title"] = .string(rows[i]["title"]!.text.trimmingCharacters(in: .whitespaces)) }
    }
}

let article = try Model("Article", dataProxy: [ArticleProxy()]) { ... }   // run in order
```

| Hook | Runs |
|------|------|
| `searchCondition(&condition)` | building the model: default values of the search bar |
| `beforeFetch(conditions)` | before a table page is read: SQL ANDed to its WHERE as written, `"sql"` or `SQLFilter("sql with ?", [values])` (with values, each `?` is one of them); SQL repositories only, `MemoryRepository` refuses it |
| `afterFetch(&rows)` | after a table page is read |
| `addBehavior(&record)` | for the new record form (`init-value`) |
| `editBehavior(&record)` | after a record is read by its key (edit form, detail view) |
| `validate(record)` | before an add or an update |
| `beforeAdd(&record)` / `afterAdd(record)` | around `repository.add` |
| `beforeUpdate(&record)` / `afterUpdate(record)` | around `repository.update`, with the submitted values |
| `beforeDelete` / `afterDelete(record)` | around `repository.delete`, once per record as stored |

## Views

`Erupt(vis: [...])` declares the extra views of `@Erupt(vis = ...)`. A view's `filter` (one SQL string or a list,
ANDed as written) and `orderBy` are not `Vis` attributes, as Java keeps them `@Transient`: give them as
`visQuery`, keyed by the view's code, and the node applies them when the table is read for that view. A view
without a `code` is addressed by its title. Like `beforeFetch`, a filter needs a SQL repository.

```swift
let task = try Model(
    "Task",
    erupt: Erupt(vis: [
        Vis(boardView: BoardView(groupField: "status"), title: "Board", type: .board),
        Vis(title: "Recent", type: .table),
    ]),
    visQuery: ["Board": VisQuery(filter: "archived = 0"), "Recent": VisQuery(orderBy: "created desc")]
) { ... }
```

Dragging on a board, calendar or gantt view is saved by the erupt server through the node's `get` and `update`.

## Storage

Storage is any `Repository` (`page`, `get`, `add`, `update`, `delete`). Shipped:

- `MemoryRepository` for tests and demos;
- `SQLRepository(executor, table:, autoCreate:)` on PostgreSQL, MySQL or SQLite. The SDK depends on no driver: a
  `SQLExecutor` runs each statement with bound values. Create the tables yourself, with columns named like the
  fields (`autoCreate:` creates SQLite tables).

```swift
import EruptSQLite                                    // SQLite, through the system libsqlite3
let repo = try SQLRepository(try SQLiteExecutor(path: "blog.db"), table: "article", autoCreate: true)

// any other driver: a closure that runs (sql, params) and returns rows keyed by column name
let postgres = SQLClosureExecutor(.postgres) { sql, params in try runOnPostgres(sql, params) }
let articles = try SQLRepository(postgres, table: "article")
```

Every value is a bound parameter; identifiers are the model's checked field names, quoted; LIKE escapes with
`ESCAPE '!'`. On Linux, `EruptSQLite` needs `libsqlite3-dev` (`apt install libsqlite3-dev`).

## Without a registry

SwiftPM reads git repositories directly, so the package above needs no registry. It is the read-only split
of `swift/` in https://github.com/erupt-io/erupt-sdk; SwiftPM cannot use that subdirectory itself, since it needs `Package.swift` at the root.

To vendor it instead, copy `swift/Sources/EruptSDK/` into your package as a target with no dependencies (add
`EruptSQLite` and `CSQLite` the same way for SQLite). A copy does not update itself: when erupt changes the protocol or the annotation schema, replace the whole directory with the next release instead of merging by hand, and leave `version` in `Node.swift` untouched so the server shows which release the node runs.

## Development

```bash
swift build
swift test                                            # Swift 6 toolchain (swift-testing)
swift run erupt-gen-types ../schema --check           # Types.swift / Embedded.swift match ../schema
swift build -c release --product Conformance && python3 ../conformance/run.py -- .build/release/Conformance
ERUPT_ACCESS_TOKEN=... ERUPT_SERVER=http://localhost:8080 swift run Blog   # the SHOWCASE.md blog
```

With only the Command Line Tools (no Xcode) on macOS, point `swift test` at their Testing framework:

```bash
F=/Library/Developer/CommandLineTools/Library/Developer/Frameworks
swift test -Xswiftc -F -Xswiftc $F -Xlinker -F -Xlinker $F -Xlinker -rpath -Xlinker $F \
  -Xlinker -rpath -Xlinker /Library/Developer/CommandLineTools/Library/Developer/usr/lib
```

`Sources/EruptSDK/Types.swift` and `Embedded.swift` are generated from `../schema` by `erupt-gen-types`; do not
edit them.
