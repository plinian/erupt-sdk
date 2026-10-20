# erupt node SDK for .NET

Serve .NET models as erupt admin pages. The erupt server renders the UI, logs users in and checks menus; this
package answers the requests it forwards. Library targets **net8.0** (runs on any newer runtime); the only
dependency is the ASP.NET Core shared framework.

```bash
dotnet add package Erupt.Sdk
```

## Declare

Models are plain classes with attributes. The wire name of a field is the snake_case property name
(`PublishDate` → `publish_date`) unless `[Field(Name = ...)]` / `[Pk(Name = ...)]` sets it. The edit type
follows the property type: `string` INPUT, numbers NUMBER, `bool` BOOLEAN, `DateOnly` DATE, `DateTime`
DATE_TIME, another `[EruptModel]` class a reference, `[Choice]`s a CHOICE; `Type = EditType.TEXTAREA` sets it.

```csharp
using Erupt;

[EruptModel("Category")]
class Category
{
    [Pk] public long Id { get; set; }
    [Field("Name", Search = true)] public string? Name { get; set; }
    [Field("Parent Id")] public long? Parent { get; set; }
}

[EruptModel("Publish Options")]
class PublishForm                                    // an operation form needs no [Pk]
{
    [Field("Publish Date", NotNull = true)] public DateOnly? PublishDate { get; set; }
}

[EruptModel("Article", OrderBy = "id desc")]
class Article
{
    [Pk] public long Id { get; set; }
    [Field("Title", Search = true, NotNull = true, Sortable = true)] public string? Title { get; set; }
    [Field("Status", Search = true), Choice("draft", "Draft"), Choice("published", "Published")] public string? Status { get; set; }
    [Field("Category", Search = true)] public Category? Category { get; set; }       // table picker
    [Field("Topic", Tree = "parent")] public Category? Topic { get; set; }            // tree picker over Category.parent
    [Field("Body", Type = EditType.TEXTAREA, Table = false)] public string? Body { get; set; }
}
```

The classes only declare: records travel as `Record` (field name → value; a reference holds the referenced
primary key). Raw annotation attributes and row operations go on the model builder; the raw objects are the
generated `Edit`, `View`, `EruptOptions` (`@Erupt`) and `RowOperation` types and are checked against the erupt
schema when declared:

```csharp
var article = EruptModel.Of<Article>()
    .Edit(a => a.Title, new Edit { InputType = new InputType { Length = 64 } })
    .Options(new EruptOptions { Layout = new Layout { PageSize = 30 } })
    .Operation("publish", new OperationOptions
    {
        Title = "Publish", Form = EruptModel.Of<PublishForm>(), IfExpr = "item.status !== 'published'",
    }, async op =>
    {
        foreach (var row in op.Rows)
            await op.Repo.UpdateAsync(row["id"]!, new Record { ["status"] = "published", ["publish_date"] = op.Param!["publish_date"] });
    });
```

`Mode`: `SINGLE` / `MULTI` (default) / `MULTI_ONLY` / `BUTTON`. `Confirm = false` skips the dialog,
`ConfirmText` replaces its text, `Show = user => ...` hides the operation and refuses to run it. A handler
returning a non-empty string has it run as JavaScript in the browser, so return only code you wrote; throw
`EruptFailure` to show the user a message. `EruptNode.CurrentUser` is the acting user anywhere in a request.

## DataProxy

Hooks around a model's reads and writes, as erupt's Java `DataProxy`. Implement only the methods you need
(the others default to no-ops); throw `EruptFailure` to refuse with a message the user sees.

```csharp
class ArticleProxy : IDataProxy
{
    public void AddBehavior(Record record) => record["status"] = "draft";        // the new form's values

    public void Validate(Record record)                                           // before every add and update
    {
        if ((record["title"] as string ?? "").Contains("spam")) throw new EruptFailure("no spam");
    }

    public SqlFilter? BeforeFetch(IReadOnlyList<Cond> conditions) =>             // SQL ANDed to the table's WHERE, values bound
        new("owner = ?", EruptNode.CurrentUser?.Uid);

    public void AfterFetch(IReadOnlyList<JsonObject> rows)                       // a table page, before it is sent
    {
        foreach (var row in rows) row["title"] = row["title"]?.GetValue<string>().Trim();
    }
}

[EruptModel("Article", DataProxy = [typeof(ArticleProxy)])]                     // one or more, run in this order
class Article { ... }
```

| Hook | Runs |
|------|------|
| `SearchCondition(condition)` | building the model: default values of the search bar |
| `BeforeFetch(conditions)` | before a table page is read: SQL ANDed to its WHERE as written, `"sql"` or `new SqlFilter("sql with ?", values)` (with values, each `?` is one of them); SQL repositories only, `MemoryRepository` refuses it |
| `AfterFetch(rows)` | after a table page is read |
| `AddBehavior(record)` | for the new record form (`init-value`) |
| `EditBehavior(record)` | after a record is read by its key (edit form, detail view) |
| `Validate(record)` | before an add or an update |
| `BeforeAdd` / `AfterAdd(record)` | around `AddAsync` |
| `BeforeUpdate` / `AfterUpdate(record)` | around `UpdateAsync`, with the submitted values |
| `BeforeDelete` / `AfterDelete(record)` | around `DeleteAsync`, once per record as stored |

## Views

`Vis(...)` on the builder declares one extra view of `@Erupt(vis = ...)`. Its `filter` (SQL strings, each ANDed
as written) and `orderBy` (as `OrderBy`) are applied by the node when the table is read for that view, and kept
out of the build, as Java keeps them `@Transient`; they are SDK-only arguments, not properties of the generated
`Vis`. A view without a `Code` is addressed by its title. Like `BeforeFetch`, a filter needs a SQL repository.
`EruptOptions.Vis` declares views without them, and replaces the views declared so far.

```csharp
EruptModel.Of<TaskItem>()
    .Vis(new Vis { Title = "Board", Type = VisType.BOARD, BoardView = new BoardView { GroupField = "status" } }, filter: "archived = 0")
    .Vis(new Vis { Title = "Recent", Type = VisType.TABLE }, orderBy: "created desc");
```

Dragging on a board, calendar or gantt view is saved by the erupt server through the node's `get` and `update`.

## Trees

`Options(new EruptOptions { Tree = new Tree { Id = "id", Label = "name", Pid = "parent" } })` shows the model as a
tree, and `LinkTree = new LinkTree { Field = "category" }` puts the tree of a reference field beside the table: the
erupt server builds both trees from the node's table, and the node keeps the rows under the picked tree node
(`DependNode = true` shows none until one is picked). `LinkTree.Field` must be a reference field.

## Field types and field code

Besides the inferred types, `Type =` takes `TAGS`, `AUTO_COMPLETE`, `ATTACHMENT` (the erupt server stores the
upload, the node keeps its path), `HTML_EDITOR`, `MARKDOWN`, `CODE_EDITOR`, `COLOR`, `ICON`, `SIGNATURE`, `MAP`,
`HIDDEN` (all text), `RATE`, `SLIDER` (numbers), `BUTTON` (form only), and `CHECKBOX` / `TAB_TREE` / `TRANSFER`
with `Ref =`: the picked records, stored as the JSON list of their keys. A collection property with `[Choice]`s
is a `MULTI_CHOICE`.

A reference table depending on another field takes `[Field("Shelf", DependColumn = "province")]` plus
`.Edit(x => x.Shelf, new Edit { ReferenceTableType = new ReferenceTableType { DependField = "province" } })`: the
erupt server keeps the picked model's rows whose `DependColumn` holds the depend field's value.

A field can run its own code; the erupt server calls it through the node's `invoke` endpoint with the form's
values. Attributes cannot hold code, so the model builder registers it by property:

```csharp
[EruptModel("Order")]
public sealed class Order
{
    [Pk] public long Id { get; set; }
    [Field("Status", Type = EditType.CHOICE)] public string? Status { get; set; }
    [Field("Qty")] public long? Qty { get; set; }
    [Field("City", Type = EditType.AUTO_COMPLETE)] public string? City { get; set; }
    [Field("Total")] public double? Total { get; set; }
    [Field("Recalc", Type = EditType.BUTTON)] public object? Recalc { get; set; }
    [Field("Tags", Type = EditType.CHECKBOX, Ref = typeof(Tag))] public List<long>? Tags { get; set; }
}

node.Register(EruptModel.Of<Order>()
    .Fetch(o => o.Status, form => [("new", "New"), ("paid", "Paid")])          // TAGS: form => ["a", "b"]
    .OnChange(o => o.Qty, form => new FieldUpdate { FormData = new Record { ["total"] = (long)form["qty"]! * 9 } })
    .Complete(o => o.City, async (form, typed) => await LookupAsync(typed))
    .Click(o => o.Recalc, form => new FieldUpdate { Eval = "alert('done')" }), repository);
```

`Fetch` belongs to `CHOICE` / `MULTI_CHOICE` (value / label pairs) and `TAGS` (strings), `Complete` to
`AUTO_COMPLETE`, `Click` to `BUTTON`, `OnChange` to any field; anything else throws at declaration. Each takes
a plain or an async function; throw `EruptFailure` to refuse with a message.

## Drills

```csharp
node.Register(EruptModel.Of<Author>()
    .Drill(new Drill { Title = "Books", Link = new Link { LinkErupt = "Book" } }, joinColumn: "author"), repository);
```

opens `Book` filtered to the rows whose `author` holds the author's `id` (`column:`, `id` by default);
`Link.LinkCondition` adds SQL as written. Both models must be on the node.

## Server config and user info

`node.ConfigAsync()` and `node.GroupConfigAsync()` return the config text set for the node and its group on the
erupt server; `node.UserInfoAsync()` the acting user's full info (roles, org, post), while a request is served.

## Run

```csharp
var node = new EruptNode(new NodeOptions
{
    Name = "blog",                                            // the node created on the server
    AccessToken = Environment.GetEnvironmentVariable("ERUPT_ACCESS_TOKEN")!,
    Servers = ["http://erupt-server:8080"],
    // Address = "http://10.0.0.12:9090",                     // only when auto-detection picks the wrong one
});
node.Register<Category>(new MemoryRepository());              // register referenced models first
node.Register(article, new DbRepository(() => new SqliteConnection("Data Source=blog.db"), "article") { AutoCreateSqlite = true });

await node.RunAsync(9090);                                    // standalone; deregisters on Ctrl+C / SIGTERM
```

Or inside an existing ASP.NET Core app:

```csharp
builder.Services.AddEruptNode(node);   // heartbeat once the app listens, deregistration on shutdown
app.MapEruptNode();                    // /node-health and /erupt-api/**
```

Then on the server add menus of type `table` with values `blog.Article` and `blog.Category`.

## Storage

`IRepository` (`PageAsync`, `GetAsync`, `AddAsync`, `UpdateAsync`, `DeleteAsync`) puts a model on anything.
Shipped: `MemoryRepository` and `DbRepository` over any ADO.NET provider: identifiers quoted (`Quote` for
MySQL / SQL Server), values parameterized as `@pN`, LIKE escaped with `ESCAPE '!'`, dates as ISO text;
`AutoCreateSqlite` creates a missing SQLite table. Without a sort, rows come back by primary key ascending.

| Database | Settings |
|----------|----------|
| SQLite, PostgreSQL | defaults |
| MySQL | `Quote = ("`", "`")` |
| SQL Server 2012+ | `Quote = ("[", "]"), Paging = Paging.OffsetFetch` |
| Oracle 12c+ | `ParameterPrefix = ":", Paging = Paging.OffsetFetch` |

## Without a registry

NuGet has no git source. Without nuget.org, copy `dotnet/src/Erupt.Sdk/` (the `.csproj`, the sources and
`Resources/`, which the project embeds) into your solution and reference it:

```bash
dotnet add reference third_party/Erupt.Sdk/Erupt.Sdk.csproj
```

Or `dotnet pack dotnet/src/Erupt.Sdk -o ./packages` and add `./packages` as a local package source.
A copy does not update itself: when erupt changes the protocol or the annotation schema, replace the whole directory with the next release instead of merging by hand, and leave `Node.Version` untouched so the server shows which release the node runs.

## Generated code

`src/Erupt.Sdk/Types.g.cs` and the embedded `Resources/*.json` come from the erupt schema:

```bash
dotnet run --project tools/GenTypes -- ../schema          # sync schemas, regenerate types
dotnet run --project tools/GenTypes -- ../schema --check  # CI: fail when stale
```

The `@Erupt` attributes are generated as `EruptOptions`, since a type named `Erupt` would collide with the namespace.

## Tests

```bash
dotnet test tests/Erupt.Sdk.Tests
dotnet build examples/Conformance -c Release
python3 ../conformance/run.py -- dotnet examples/Conformance/bin/Release/net8.0/Conformance.dll   # from dotnet/
```

## Differences from Python

- Field names default to snake_case of the property; operations need an explicit code.
- A request body that is not a JSON object answers a failed R (`a JSON object is required`) instead of a 500.
- `DbRepository` stores dates as ISO text and pages with `LIMIT/OFFSET` unless told otherwise.
