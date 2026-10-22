# erupt-sdk (TypeScript / Node.js)

Serve Node.js models as an erupt admin UI. Node 22+, zero runtime dependencies.

```bash
npm install erupt-sdk
```

```ts
import { field, model, Node, SqliteRepository } from "erupt-sdk";

const Article = model("Article", {
  id: field.pk(),
  title: field.input("Title", { search: true, notNull: true, sortable: true }),
  status: field.choice("Status", { draft: "Draft", published: "Published" }, { search: true }),
  publish_date: field.date("Publish Date", { search: true }),
  body: field.textarea("Body", { table: false }),
}, { orderBy: "id desc" });

const node = new Node("blog", process.env.ERUPT_ACCESS_TOKEN!, "http://erupt-server:8080");
node.register(Article, new SqliteRepository("blog.db", "article"));
await node.serve(9090);
```

1. On the erupt server create node `blog` (Node Config) and copy its access token.
2. Add a menu of type `table` with value `blog.Article`.
3. Run the node. The server must reach it on `http://<node ip>:9090`; pass `{ address }` otherwise.

`node.listener` is a plain `(req, res)` handler for any `node:http` server; then call `node.startHeartbeat()`
once it listens and `node.deregister()` on shutdown. `serve()` does all three (deregisters on SIGINT / SIGTERM).

## Fields

`field.pk()`, `field.input`, `field.textarea`, `field.number`, `field.boolean`, `field.date`, `field.dateTime`,
`field.choice(title, { value: label })`, `field.ref(target, title)` and `field.of(editType, title)`.
Options: `search`, `notNull`, `sortable`, `table` (column, default true), `form` (default true), and raw
`view` / `edit` attributes. Model options: `power` (`{ delete: false }`), `orderBy` (`"views desc, id"`,
applied by the node), raw `erupt` attributes (`{ layout: { pageSize: 30 } }`), `operations`, `dataProxy`.

Raw attributes are typed with the generated `View`, `Edit`, `Erupt`, `RowOperation` interfaces and checked
against the erupt annotation schema when the model is declared, so a misspelt key or enum value throws
at startup instead of silently doing nothing in the browser.

Dates are stored as wall-clock strings: DATE `2026-01-05`, DATE_TIME `2026-01-05T10:30:00.000`.

## References

```ts
const Category = model("Category", { id: field.pk(), name: field.input("Name", { search: true }), parent: field.number("Parent Id") });

const Article = model("Article", {
  id: field.pk(),
  category: field.ref(Category, "Category", { search: true }),    // table picker
  topic: field.ref(Category, "Topic", { tree: "parent" }),        // tree picker over Category.parent
});
```

The repository stores the referenced primary key; the UI shows `label` (default `name`). Register the
referenced model on the same node.

## Row operations

```ts
const PublishForm = model("PublishForm", { publish_date: field.date("Publish Date", { notNull: true }) });

model("Article", { /* ... */ }, {
  operations: {
    publish: operation("Publish", { form: PublishForm, ifExpr: "item.status !== 'published'" }, async (op) => {
      for (const row of op.rows) await op.repo.update(row.id, { status: "published", publish_date: op.param!.publish_date });
    }),
  },
});
```

The key is the operation code. `mode`: `SINGLE` / `MULTI` (default) / `MULTI_ONLY` / `BUTTON`. `confirm: false`
skips the dialog, a string replaces its text. `show: (user) => ...` hides the operation and refuses to run it.
A returned string is executed as JavaScript in the browser, so return only code you wrote.

## DataProxy

Hooks around a model's reads and writes, as erupt's Java `DataProxy`. Implement what you need (each may be
async); throw `Fail` to refuse with a message the user sees.

```ts
import { currentUser, type DataProxy, Fail } from "erupt-sdk";

const articleProxy: DataProxy = {
  addBehavior(record) {           // the new form's values
    record.status = "draft";
  },
  validate(record) {              // before every add and update
    if (String(record.title ?? "").includes("spam")) throw new Fail("no spam");
  },
  beforeFetch(conditions) {       // SQL ANDed to the table's WHERE, values bound
    return ["owner = ?", [currentUser()!.uid]];
  },
  afterFetch(rows) {              // a table page, before it is sent
    for (const row of rows) row.title = String(row.title).trim();
  },
};

model("Article", { /* ... */ }, { dataProxy: articleProxy });   // one proxy or an array
```

| Hook | Runs |
|------|------|
| `searchCondition(condition)` | building the model: default values of the search bar |
| `beforeFetch(conditions)` | before a table page is read: SQL ANDed to its WHERE as written, `"sql"` or `["sql with ?", [values]]` (with values, each `?` is one of them); SQL repositories only, `MemoryRepository` refuses it |
| `afterFetch(rows)` | after a table page is read |
| `addBehavior(record)` | for the new record form (`init-value`) |
| `editBehavior(record)` | after a record is read by its key (edit form, detail view) |
| `validate(record)` | before an add or an update |
| `beforeAdd` / `afterAdd(record)` | around `repository.add` |
| `beforeUpdate` / `afterUpdate(record)` | around `repository.update`, with the submitted values |
| `beforeDelete` / `afterDelete(record)` | around `repository.delete`, once per record as stored |

## Views

`erupt.vis` declares the extra views of `@Erupt(vis = ...)`. A view's `filter` (one SQL string or an array, ANDed
as written) and `orderBy` (as the model's) are SDK-only properties (`ModelVis`): the node applies them when the
table is read for that view, and keeps them out of the build, as Java keeps them `@Transient`. A view without a
`code` is addressed by its title. Like `beforeFetch`, a filter needs a SQL repository.

```ts
model("Task", { /* ... */ }, {
  erupt: { vis: [
    { title: "Board", type: "BOARD", boardView: { groupField: "status" }, filter: "archived = 0" },
    { title: "Recent", type: "TABLE", orderBy: "created desc" },
  ] },
});
```

Dragging on a board, calendar or gantt view is saved by the erupt server through the node's `get` and `update`.

## Trees

`erupt.tree` (`{ id: "id", label: "name", pid: "parent" }`) shows the model as a tree, and
`erupt.linkTree` (`{ field: "category" }`) puts the tree of a reference field beside the table: the erupt server
builds both trees from the node's table, and the node keeps the rows under the picked tree node
(`dependNode: true` shows none until one is picked). `linkTree.field` must be a reference field.

## Field types and field code

Besides the named factories, `field.of` takes `TAGS`, `AUTO_COMPLETE`, `ATTACHMENT` (the erupt server stores
the upload, the node keeps its path), `HTML_EDITOR`, `MARKDOWN`, `CODE_EDITOR` (all text). `field.button(title,
click)` is a form-only BUTTON, and `field.checkbox(target, title)` / `field.tabTree(target, title)` hold the
picked records of `target`, stored as the JSON list of their keys. `field.json` with `choices` (or `fetch`) is a
`MULTI_CHOICE`.

A field can run its own code (sync or async); the erupt server calls it through the node's `invoke` endpoint
with the form's values:

```ts
const Order = model("Order", {
  id: field.pk(),
  status: field.choice("Status", {}, { fetch: (form) => ({ new: "New", paid: "Paid" }) }), // options, also TAGS: [...]
  qty: field.number("Qty", { onchange: (form) => ({ formData: { total: form.qty * 9 }, editExpr: {} }) }),
  city: field.of("AUTO_COMPLETE", "City", { complete: async (form, typed) => lookup(typed) }),
  total: field.number("Total"),
  recalc: field.button("Recalc", (form) => ({ eval: "alert('done')", formData: {} })),
  tags: field.checkbox(Tag, "Tags"),
});
```

`fetch` belongs to `CHOICE` / `MULTI_CHOICE` (`{ value: label }` or pairs) and `TAGS` (a list), `complete` to
`AUTO_COMPLETE`, `click` to `BUTTON`; `onchange` to any field. Throw `Fail` to refuse with a message.

Also: `field.of` with `COLOR`, `ICON`, `SIGNATURE`, `MAP`, `HIDDEN` (text), `RATE`, `SLIDER` (numbers), and
`field.transfer(target, title)` (like `checkbox`). A reference table depending on another field takes
`edit: { referenceTableType: { dependField: "province", dependColumn: "province" } }`: the erupt server keeps the
picked model's rows whose `dependColumn` holds the depend field's value.

## Drills

```ts
const Author = model("Author", { ... }, {
  erupt: { drills: [{ title: "Books", link: { linkErupt: "Book", joinColumn: "author" } }] },
});
```

opens `Book` filtered to the rows whose `author` holds the author's `id` (`link.column`, `id` by default);
`link.linkCondition` adds SQL as written. Both models must be on the node.

## Server config and user info

`node.config()` and `node.groupConfig()` return the config text set for the node and its group on the erupt
server; `node.userInfo()` the acting user's full info (roles, org, post), while a request is served.

## Storage

A `Repository` implements `bind`, `page`, `get`, `add`, `update`, `delete` (sync or async). `page` must apply
`query.filters` (the SQL of a view filter and `beforeFetch`) or throw, never ignore them.
`currentUser()` returns the acting user inside a repository or operation call. Shipped:

- `MemoryRepository(seed?)`: in process, for tests and demos.
- `SqliteRepository(path, table)`: node:sqlite (Node 22.5+), creates the table when missing.
- `SqlRepository(executor, table, { dialect })`: any SQL database. The SDK has no driver dependency; wrap the
  driver you already use in an executor. `dialect` (`sqlite` | `postgres` | `mysql` | `mssql`) picks the
  placeholders, identifier quotes and paging; values are always bound, LIKE escapes with `!`, PostgreSQL
  searches with `ILIKE` so every database matches case-insensitively. The table must exist (`autoCreate`
  is SQLite only); column names are the model's field names.

```ts
import pg from "pg";                               // node-postgres
const pool = new pg.Pool({ connectionString: process.env.DATABASE_URL });
node.register(Article, new SqlRepository(pgExecutor(pool), "article", { dialect: "postgres" }));

import mysql from "mysql2/promise";
const db = mysql.createPool({ uri: process.env.DATABASE_URL, dateStrings: true });
node.register(Article, new SqlRepository(mysqlExecutor(db), "article", { dialect: "mysql" }));

import sql from "mssql";
const mssqlPool = await sql.connect(process.env.DATABASE_URL!);
node.register(Article, new SqlRepository(mssqlExecutor(mssqlPool), "article", { dialect: "mssql" }));
```

Any other driver works through a two-method object: `{ query(sql, params) => rows, execute(sql, params) }`.

Without a sort, every repository returns rows by primary key ascending.

**Dates.** The SDK keeps DATE / DATE_TIME as wall-clock strings (`2026-01-05`, `2026-01-05T10:30:00.000`)
and binds them as such, so store them in columns without a time zone (`date`, `timestamp`, `datetime`).
Prefer drivers that return those columns as strings — mysql2 `dateStrings: true`; node-postgres
`pg.types.setTypeParser(1082, String)` and `(1114, String)`. A `Date` the driver does return is read with
its local fields, which is how pg and mysql2 build it from a column without a time zone; for mssql set
`options: { useUTC: false }`, since it builds them in UTC by default. Numbers that drivers return as text or bigint (pg
`bigint` / `numeric`) come back as numbers when they are exact.

Not yet: sub-tables (TAB_TABLE_*), TPL operations, i18n of messages. Trees, file
upload and Excel are done by the erupt server.

## Without a registry

npm cannot install a subdirectory of a git repository, so build a tarball from the repository:

```bash
git clone --depth 1 -b ts/v0.1.0 https://github.com/erupt-io/erupt-sdk && cd erupt-sdk/ts
npm ci && npm pack                       # erupt-sdk-0.1.0.tgz
npm install /path/to/erupt-sdk-0.1.0.tgz # in your project
```

Or copy `ts/src/` into your project and compile it with your own sources: it needs Node 22+, TypeScript 5.3+,
`"module": "nodenext"` and `"resolveJsonModule": true`, and keeps `schema.json` and `defaults.json` next to the
code. A copy does not update itself: when erupt changes the protocol or the annotation schema, replace the whole directory with the next release instead of merging by hand, and leave `VERSION` in `node.ts` untouched so the server shows which release the node runs.

## Development

```bash
npm install
npm test                                   # build + unit tests
npm run conformance                        # the shared protocol suite (conformance/)
node tools/gen-types.mjs <erupt>/schema    # sync schemas, regenerate src/types.ts (--check for CI)
```
