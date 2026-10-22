# erupt-sdk (Ruby)

Serve Ruby models as an erupt admin UI. Zero gem dependencies, Ruby 3.1+.

```bash
gem install erupt-sdk      # or in a Gemfile: gem "erupt-sdk"
```

```ruby
require "erupt"

class Article
  extend Erupt::Model
  erupt "Article", order_by: "id desc"
  field :id, pk: true
  field :title, "Title", search: true, not_null: true, sortable: true
  field :status, "Status", choices: { draft: "Draft", published: "Published" }, search: true
  field :publish_date, "Publish Date", Date, search: true
  field :body, "Body", type: Erupt::EditType::TEXTAREA, table: false
end

node = Erupt::Node.new("blog", ENV.fetch("ERUPT_ACCESS_TOKEN"), "http://erupt-server:8080")
node.register(Article, Erupt::MemoryRepository.new)
node.serve(port: 9090)
```

1. On the erupt server create node `blog` (Node Config) and copy its access token.
2. Add a menu of type `table` with value `blog.Article`.
3. Run the node. The server must be able to reach it on `http://<node ip>:9090`; pass `address:` otherwise.

`field name, title, kind` infers the edit type from `kind`: `String` (or nothing) INPUT, `Integer` / `Float`
NUMBER, `:boolean` BOOLEAN, `Date` DATE, `Time` DATE_TIME, `choices:` CHOICE; `type:` overrides it.
`view: {...}` / `edit: {...}` on a field and extra keywords on `erupt` pass raw annotation attributes through.
Enum values have constants (`Erupt::EditType::TEXTAREA`, `Erupt::RowOperationMode::SINGLE`, ...).

Records are hashes keyed by field name (`row["title"]`); hashes handed to a repository may use symbols.

## Rack

A node is a Rack application, so it can live inside an existing app instead of on its own port. `start`
registers it (with the port the server reaches it on) and `stop` deregisters it:

```ruby
# config/routes.rb (Rails): mount at the root, the server calls /erupt-api/... and /node-health
mount ERUPT_NODE, at: "/"

# config/initializers/erupt.rb
ERUPT_NODE = Erupt::Node.new("blog", ENV.fetch("ERUPT_ACCESS_TOKEN"), ENV.fetch("ERUPT_SERVER"), logger: Rails.logger)
ERUPT_NODE.register(Article, repo)
ERUPT_NODE.start(port: 3000)
at_exit { ERUPT_NODE.stop }
```

`serve` runs a small built-in threaded HTTP/1.1 server (keep-alive, chunked bodies) for the standalone case.

## References

Pass another model class (declared earlier, registered on the same node) as the kind. The repository stores
the referenced primary key; the UI shows `label:` (default `name`).

```ruby
class Category
  extend Erupt::Model
  erupt "Category"
  field :id, pk: true
  field :name, "Name", search: true
  field :parent, "Parent Id", Integer
end

class Article
  # ...
  field :category, "Category", Category, search: true   # table picker
  field :topic, "Topic", Category, tree: :parent         # tree picker over Category.parent
end
```

## Row operations

```ruby
class PublishForm                        # a form model needs no primary key
  extend Erupt::Model
  erupt "Publish Options"
  field :publish_date, "Publish Date", Date, not_null: true
end

class Article
  # ...
  operation :publish, "Publish", form: PublishForm, if_expr: "item.status !== 'published'" do |op|
    op.rows.each { |row| op.repo.update(row["id"], status: "published", publish_date: op.param["publish_date"]) }
  end                                    # op.rows, op.param, op.repo, op.user
end
```

`mode:` `SINGLE` / `MULTI` (default) / `MULTI_ONLY` / `BUTTON`. `confirm: false` skips the dialog, a string
replaces its text. `show: ->(user) { ... }` hides the operation and refuses to run it. A returned string is
executed as JavaScript in the browser, so return only code you wrote.

## DataProxy

Hooks around a model's reads and writes, as erupt's Java `DataProxy`. Override what you need; raise
`Erupt::Fail` to refuse with a message the user sees.

```ruby
class ArticleProxy < Erupt::DataProxy
  def add_behavior(record)               # the new form's values
    record["status"] = "draft"
  end

  def validate(record)                   # before every add and update
    raise Erupt::Fail, "no spam" if record["title"].to_s.include?("spam")
  end

  def before_fetch(conditions)           # SQL ANDed to the table's WHERE, values bound
    ["owner = ?", [Erupt.current_user["uid"]]]
  end

  def after_fetch(rows)                  # a table page, before it is sent
    rows.each { |row| row["title"] = row["title"].strip }
  end
end

class Article
  extend Erupt::Model
  erupt "Article", data_proxy: ArticleProxy   # one proxy or an array, classes or instances
end
```

| Hook | Runs |
|------|------|
| `search_condition(condition)` | building the model: default values of the search bar |
| `before_fetch(conditions)` | before a table page is read: SQL ANDed to its WHERE as written, `"sql"` or `["sql with ?", [values]]` (with values, each `?` is one of them); SQL repositories only, `MemoryRepository` refuses it |
| `after_fetch(rows)` | after a table page is read |
| `add_behavior(record)` | for the new record form (`init-value`) |
| `edit_behavior(record)` | after a record is read by its key (edit form, detail view) |
| `validate(record)` | before an add or an update |
| `before_add` / `after_add(record)` | around `repository.add` |
| `before_update` / `after_update(record)` | around `repository.update`, with the submitted values |
| `before_delete` / `after_delete(record)` | around `repository.delete`, once per record as stored |

## Views

`vis:` declares the extra views of `@Erupt(vis = ...)`. A view's `filter` (one SQL string or an array, ANDed as
written) and `orderBy` (as `order_by`) are applied by the node when the table is read for that view, and kept
out of the build, as Java keeps them `@Transient`. A view without a `code` is addressed by its title. Like
`before_fetch`, a filter needs a SQL repository.

```ruby
class Task
  extend Erupt::Model
  erupt "Task", vis: [
    { title: "Board", type: "BOARD", boardView: { groupField: "status" }, filter: "archived = 0" },
    { title: "Recent", type: "TABLE", orderBy: "created desc" }
  ]
end
```

Dragging on a board, calendar or gantt view is saved by the erupt server through the node's `get` and `update`.

## Trees

`tree: { id: "id", label: "name", pid: "parent" }` shows the model as a tree, and
`linkTree: { field: "category" }` puts the tree of a reference field beside the table: the erupt server builds
both trees from the node's table, and the node keeps the rows under the picked tree node (`dependNode: true`
shows none until one is picked). `linkTree.field` must be a reference field.

## Field types and field code

Besides the inferred types, `type:` takes `TAGS`, `AUTO_COMPLETE`, `ATTACHMENT` (the erupt server stores the
upload, the node keeps its path), `HTML_EDITOR`, `MARKDOWN`, `CODE_EDITOR` (all text), `BUTTON` (form only),
and `CHECKBOX` / `TAB_TREE` with `ref:`: the picked records, stored as the JSON list of their keys. An `Array`
field with `choices:` is a `MULTI_CHOICE`.

A field can run its own code; the erupt server calls it through the node's `invoke` endpoint with the form's
values:

```ruby
class Order
  extend Erupt::Model
  erupt "Order"
  field :id, pk: true
  field :status, "Status", fetch: ->(form) { { new: "New", paid: "Paid" } }   # options, also TAGS: [...]
  field :qty, "Qty", Integer, onchange: ->(form) { { formData: { total: form["qty"] * 9 }, editExpr: {} } }
  field :city, "City", type: Erupt::EditType::AUTO_COMPLETE, complete: ->(form, typed) { lookup(typed) }
  field :total, "Total", Float
  field :recalc, "Recalc", type: Erupt::EditType::BUTTON, click: ->(form) { { eval: "alert('done')", formData: {} } }
  field :tags, "Tags", Array, type: Erupt::EditType::CHECKBOX, ref: Tag
end
```

`fetch` belongs to `CHOICE` / `MULTI_CHOICE` (`{ value => label }` or pairs) and `TAGS` (an array), `complete`
to `AUTO_COMPLETE`, `click` to `BUTTON`; `onchange` to any field. Raise `Erupt::Fail` to refuse with a message.

Also: `COLOR`, `ICON`, `SIGNATURE`, `MAP`, `HIDDEN` (text), `RATE`, `SLIDER` (numbers) and `TRANSFER` (like
`CHECKBOX`). A reference table depending on another field takes
`edit: { referenceTableType: { dependField: "province", dependColumn: "province" } }`: the erupt server keeps the
picked model's rows whose `dependColumn` holds the depend field's value.

## Drills

```ruby
erupt "Author", drills: [{ title: "Books", link: { linkErupt: "Book", joinColumn: "author" } }]
```

opens `Book` filtered to the rows whose `author` holds the author's `id` (`link.column`, `id` by default);
`link.linkCondition` adds SQL as written. Both models must be on the node.

## Server config and user info

`node.config` and `node.group_config` return the config text set for the node and its group on the erupt
server; `node.user_info` the acting user's full info (roles, org, post), while a request is served.

## Storage

Storage is any `Erupt::Repository` (`page`, `get`, `add`, `update`, `delete`). Shipped:

- `MemoryRepository` for tests and demos;
- `SqlRepository.new(executor, table, auto_create: false)` on PostgreSQL, MySQL or SQLite. The SDK depends on
  no driver: an `Erupt::SqlExecutor` runs each statement with bound values on the driver you hand it. Create
  the tables yourself, with columns named like the fields (`auto_create:` creates SQLite tables).

```ruby
require "pg"                                  # PostgreSQL (pg gem)
repo = Erupt::SqlRepository.new(Erupt::SqlExecutor.pg(PG.connect(ENV.fetch("DATABASE_URL"))), "article")

require "mysql2"                              # MySQL (mysql2 gem; statements are prepared)
repo = Erupt::SqlRepository.new(Erupt::SqlExecutor.mysql2(Mysql2::Client.new(**MYSQL)), "article")

require "sqlite3"                             # SQLite (sqlite3 gem)
repo = Erupt::SqlRepository.new(Erupt::SqlExecutor.sqlite3(SQLite3::Database.new("blog.db")), "article", auto_create: true)

require "connection_pool"                     # pooled: anything with `with` lends a connection per statement
repo = Erupt::SqlRepository.new(Erupt::SqlExecutor.pg(ConnectionPool.new(size: 5) { PG.connect(DSN) }), "article")

# any other library: a block that runs (sql, params) and returns rows as hashes keyed by column name
executor = Erupt::SqlExecutor.new(:postgres) do |sql, params|
  ActiveRecord::Base.connection_pool.with_connection { |c| c.raw_connection.exec_params(sql, params).to_a }
end
```

A single connection is used by one thread at a time. Without a sort, every repository returns rows by primary
key ascending. `Erupt.current_user` returns the acting user inside a repository call.

Not yet: sub-tables (TAB_TABLE_*), TPL operations, i18n of messages. Trees, file
upload and Excel are done by the erupt server.

## Without a registry

From the repository, without RubyGems (Bundler):

```ruby
gem "erupt-sdk", git: "https://github.com/erupt-io/erupt-sdk", tag: "ruby/v0.1.0", glob: "ruby/*.gemspec"
```

Or copy `ruby/lib/` (`erupt.rb` and `erupt/`, including its `.json` files) onto your load path and
`require "erupt"`. A copy does not update itself: when erupt changes the protocol or the annotation schema, replace the whole directory with the next release instead of merging by hand, and leave `Erupt::VERSION` untouched so the server shows which release the node runs.

## Generated code

`lib/erupt/types.rb` (a constant for every annotation enum value) and `sig/erupt/types.rbs` (RBS records for
every annotation attribute: `edit`, `view`, `erupt`, `row_operation`, ...) are generated from the erupt
annotation JSON Schema. Raw `view:` / `edit:` / `erupt` / `operation` attributes are checked against the same
schema when a model is declared, so a misspelt key or enum value fails at load instead of silently doing
nothing in the browser.

After an annotation change in erupt (regenerate there with `mvn -pl erupt-test -Pnode-schema test`):

```bash
ruby tools/gen_types.rb ../schema          # sync schemas, regenerate types.rb / types.rbs
ruby tools/gen_types.rb ../schema --check  # CI: fail when stale
```

Tests: `ruby -Ilib -e 'Dir["./test/test_*.rb"].each { |f| require f }'` (SQLite-backed cases run where the
`sqlite3` gem is installed; `ERUPT_TEST_DATABASES=1` with the `pg` and `mysql2` gems runs `test_databases.rb`).
