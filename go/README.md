# erupt-sdk (Go)

Serve Go models as an erupt admin UI through an erupt cloud server. Standard library only at runtime,
Go 1.21+.

```bash
go get github.com/erupt-io/erupt-sdk/go
```

```go
import erupt "github.com/erupt-io/erupt-sdk/go"

type Article struct {
	ID          int64     `json:"id" erupt:"pk"`
	Title       string    `json:"title" erupt:"title=Title;search;notNull;sortable"`
	Status      string    `json:"status" erupt:"title=Status;choices=draft:Draft,published:Published;search"`
	PublishDate time.Time `json:"publish_date" erupt:"title=Publish Date;type=DATE;search"`
	Body        string    `json:"body" erupt:"title=Body;type=TEXTAREA;hideTable"`
}

article, err := erupt.NewModel(Article{}, "Article", erupt.WithOrderBy("id desc"))
node, err := erupt.NewNode(erupt.Config{Name: "blog", AccessToken: os.Getenv("ERUPT_ACCESS_TOKEN"),
	Servers: []string{"http://erupt-server:8080"}})
err = node.Register(article, erupt.NewMemoryRepository())
err = node.ListenAndServe(":9090")
```

1. On the erupt server create node `blog` (Node Config) and copy its access token.
2. Add a menu of type `table` with value `blog.Article`.
3. Run the node. The server must reach it on `http://<node ip>:9090`; set `Config.Address` otherwise.

## Declaring a model

The struct only describes the model; records travel as `erupt.Record` (`map[string]any`) keyed by field
name, which is the `json` tag name (else the Go field name). Only fields with an `erupt` tag take part.

| Tag | Meaning |
|-----|---------|
| `pk` | primary key |
| `title=Title` | column and form label |
| `search`, `notNull`, `sortable` | |
| `hideTable`, `hideForm` | leave out of the table / the form |
| `type=TEXTAREA` | an `EditType`; otherwise inferred: string INPUT, numbers NUMBER, bool BOOLEAN, `time.Time` DATE_TIME (`type=DATE` for a date) |
| `choices=a:A,b:B` | a CHOICE field (a MULTI_CHOICE on a slice) |
| `ref=Category` | references a record of model `Category` (registered first); `label=name` (default), `tree=parent` for a tree picker |

Options: `WithName`, `WithPower(map[string]bool{"delete": false})`, `WithOrderBy("views desc, id")`,
`WithRaw(...)` (raw `@Erupt` attributes), `WithFieldEdit` / `WithFieldView` (raw `@Edit` / `@View`), and
`WithOperations(...)`. Raw attributes are an `erupt.M` or a generated type
(`erupt.Edit{InputType: &erupt.InputType{Length: erupt.Ptr[int64](64)}}`); they are checked against the
erupt annotation schema in `NewModel`, so a misspelt key or enum value is an error there, not a silent
no-op in the browser.

## Row operations

```go
erupt.WithOperations(erupt.Operation{
	Code: "publish", Title: "Publish", Form: publishForm, // a model without pk, not registered
	IfExpr: "item.status !== 'published'",
	Handler: func(op *erupt.OpContext) (string, error) { // op.Rows, op.Param, op.Repo, op.User
		for _, row := range op.Rows {
			if err := op.Repo.Update(op.Context, row["id"], erupt.Record{"status": "published"}); err != nil {
				return "", err
			}
		}
		return "", nil
	},
})
```

`Mode`: `RowOperationModeSingle` / `Multi` (default) / `MultiOnly` / `Button`. `NoConfirm` skips the dialog,
`Confirm` replaces its text, `Show(user)` hides the operation and refuses to run it. A returned string is
executed as JavaScript in the browser, so return only code you wrote. Return `erupt.Fail("...")` from a
handler or a repository to show the user a message; any other error answers 500.

## DataProxy

Hooks around a model's reads and writes, as erupt's Java `DataProxy`. Embed `erupt.BaseDataProxy` and
override what you need; return `erupt.Fail("...")` to refuse with a message the user sees.

```go
type ArticleProxy struct{ erupt.BaseDataProxy }

func (ArticleProxy) AddBehavior(ctx context.Context, record erupt.Record) error { // the new form's values
	record["status"] = "draft"
	return nil
}

func (ArticleProxy) Validate(ctx context.Context, record erupt.Record) error { // before every add and update
	if title, _ := record["title"].(string); strings.Contains(title, "spam") {
		return erupt.Fail("no spam")
	}
	return nil
}

// SQL ANDed to the table's WHERE, values bound
func (ArticleProxy) BeforeFetch(ctx context.Context, conditions []erupt.Cond) (erupt.Filter, error) {
	return erupt.Filter{SQL: "owner = ?", Params: []any{erupt.UserFrom(ctx).Account}}, nil
}

article, err := erupt.NewModel(Article{}, "Article", erupt.WithDataProxy(ArticleProxy{})) // one or several
```

| Hook | Runs |
|------|------|
| `SearchCondition(ctx, condition)` | building the model: default values of the search bar |
| `BeforeFetch(ctx, conditions)` | before a table page is read: `Filter{SQL, Params}` ANDed to its WHERE as written (with `Params`, each `?` is one of them); SQL repositories only, `MemoryRepository` refuses it |
| `AfterFetch(ctx, rows)` | after a table page is read |
| `AddBehavior(ctx, record)` | for the new record form (`init-value`) |
| `EditBehavior(ctx, record)` | after a record is read by its key (edit form, detail view) |
| `Validate(ctx, record)` | before an add or an update |
| `BeforeAdd` / `AfterAdd(ctx, record)` | around `Repository.Add` |
| `BeforeUpdate` / `AfterUpdate(ctx, record)` | around `Repository.Update`, with the submitted values |
| `BeforeDelete` / `AfterDelete(ctx, record)` | around `Repository.Delete`, once per record as stored |

## Views

`vis` declares the extra views of `@Erupt(vis = ...)`. A view's `filter` (one SQL string or a list, ANDed as
written) and `orderBy` (as `WithOrderBy`) are applied by the node when the table is read for that view, and
kept out of the build, as Java keeps them `@Transient`. They are not in the generated `Vis`: give them in an
`M`, or wrap a `Vis` in `erupt.NodeVis`. A view without a `code` is addressed by its title. Like
`BeforeFetch`, a filter needs a SQL repository.

```go
erupt.WithRaw(erupt.M{"vis": []any{
	erupt.M{"title": "Board", "type": "BOARD", "boardView": erupt.M{"groupField": "status"}, "filter": "archived = 0"},
	erupt.NodeVis{Vis: erupt.Vis{Title: erupt.Ptr("Recent"), Type: erupt.VisTypeTable}, OrderBy: "created desc"},
}})
```

Dragging on a board, calendar or gantt view is saved by the erupt server through the node's `Get` and `Update`.

## Trees

`WithRaw(erupt.M{"tree": erupt.M{"id": "id", "label": "name", "pid": "parent"}})` shows the model as a tree, and
`WithRaw(erupt.M{"linkTree": erupt.M{"field": "category"}})` puts the tree of a reference field beside the table:
the erupt server builds both trees from the node's table, and the node keeps the rows under the picked tree node
(`"dependNode": true` shows none until one is picked). `linkTree.field` must be a reference field.

## Field types and field code

Besides the inferred types, `type=` takes `TAGS`, `AUTO_COMPLETE`, `ATTACHMENT` (the erupt server stores the
upload, the node keeps its path), `HTML_EDITOR`, `MARKDOWN`, `CODE_EDITOR` (all text), `BUTTON` (form only),
and `CHECKBOX` / `TAB_TREE` with `ref=`: the picked records, stored as the JSON list of their keys. A slice
field with `choices` is a `MULTI_CHOICE`.

A field can run its own code; the erupt server calls it through the node's `invoke` endpoint with the form's
values:

```go
type Order struct {
	ID     int64   `json:"id" erupt:"pk"`
	Status string  `json:"status" erupt:"title=Status"`
	Qty    int64   `json:"qty" erupt:"title=Qty"`
	City   string  `json:"city" erupt:"title=City;type=AUTO_COMPLETE"`
	Total  float64 `json:"total" erupt:"title=Total"`
	Recalc any     `json:"recalc" erupt:"title=Recalc;type=BUTTON"`
	Tags   []int64 `json:"tags" erupt:"title=Tags;type=CHECKBOX;ref=Tag"`
}

erupt.NewModel(Order{}, "Order",
	erupt.WithFieldCode("status", erupt.FieldCode{Fetch: func(ctx context.Context, form erupt.M) ([]erupt.Option, error) {
		return []erupt.Option{{Value: "new", Label: "New"}, {Value: "paid", Label: "Paid"}}, nil
	}}),
	erupt.WithFieldCode("qty", erupt.FieldCode{Onchange: func(ctx context.Context, form erupt.M) (erupt.Change, error) {
		qty, _ := form["qty"].(float64)
		return erupt.Change{FormData: erupt.M{"total": qty * 9}}, nil
	}}),
	erupt.WithFieldCode("city", erupt.FieldCode{Complete: lookup}), // func(ctx, form, typed string) ([]string, error)
	erupt.WithFieldCode("recalc", erupt.FieldCode{Click: func(ctx context.Context, form erupt.M) (erupt.Click, error) {
		return erupt.Click{Eval: "alert('done')"}, nil
	}}))
```

`Fetch` belongs to `CHOICE` / `MULTI_CHOICE`, `Tags` to `TAGS`, `Complete` to `AUTO_COMPLETE`, `Click` to
`BUTTON`; `Onchange` to any field. A field with `Fetch` and no `type` is a `CHOICE` (a `MULTI_CHOICE` for a
slice). Return `erupt.Fail(...)` to refuse with a message.

## Storage

Any `erupt.Repository` (`Page`, `Get`, `Add`, `Update`, `Delete`, each with a `context.Context`; the
acting user is `erupt.UserFrom(ctx)`). `NewMemoryRepository(seed...)` and `SQLRepository` over
`database/sql` ship with it:

```go
&erupt.SQLRepository{DB: db, Table: "article", Dollar: true /* PostgreSQL */, AutoCreate: false}
```

Identifiers are field names checked at declaration and quoted (`Quote`, default `"`); every value is a
bound parameter; dates are stored as ISO text. `AutoCreate` creates the table with SQLite types.

`Node` is an `http.Handler`: mount it in your own server and run `node.Heartbeat(ctx)` (set
`Config.Address`) and `node.Deregister()` yourself, or let `ListenAndServe` do all three.

Not yet: sub-tables, TPL operations, depend fields of reference tables. Trees, file upload and Excel are done by
the erupt server.

## Without a registry

Go modules come straight from GitHub, so no registry is involved: a `go/vX.Y.Z` tag is the release, and
`GOPROXY=direct` skips the module proxy too.

To vendor it instead, copy `go/` without the tests (`go.mod`, the `.go` files and the two `.json` files, which
are embedded) into your repository and redirect the import path:

```bash
go mod edit -replace github.com/erupt-io/erupt-sdk/go=./third_party/erupt
```

A copy does not update itself: when erupt changes the protocol or the annotation schema, replace the whole directory with the next release instead of merging by hand, and leave `Version` in `node.go` untouched so the server shows which release the node runs.

## Generated code

`types.go` (a struct per annotation, a string type with constants and `…Values` per enum) is generated from
the erupt schema, which is also embedded for validation:

```bash
go run ./cmd/gentypes ../schema          # sync schemas, regenerate types.go
go run ./cmd/gentypes -check ../schema   # CI: fail when stale
```

Tests: `go test ./...` (the SQLite driver `modernc.org/sqlite` is a test-only dependency). Conformance,
from the repository root: `(cd go && go build -o /tmp/erupt-go-conformance ./examples/conformance) &&
python3 conformance/run.py -- /tmp/erupt-go-conformance`.
