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
| `choices=a:A,b:B` | a CHOICE field |
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

Not yet: sub-tables, TPL operations, depend fields of references, tree models, file upload, Excel.

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
