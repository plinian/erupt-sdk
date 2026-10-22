// The conformance fixture (conformance/README.md) in C#.
using Erupt;

var port = int.Parse(Environment.GetEnvironmentVariable("PORT")!);
var node = new EruptNode(new NodeOptions
{
    Name = "conformance",
    AccessToken = Environment.GetEnvironmentVariable("ERUPT_ACCESS_TOKEN")!,
    Servers = [Environment.GetEnvironmentVariable("ERUPT_SERVER")!],
    Address = $"http://127.0.0.1:{port}",
});

node.Register(EruptModel.Of<Category>().Drill(new Drill { Title = "Articles", Link = new Link { LinkErupt = "Article" } }, joinColumn: "category"), new MemoryRepository(
    new Record { ["name"] = "Tech", ["parent"] = null },
    new Record { ["name"] = "Python", ["parent"] = 1 },
    new Record { ["name"] = "Life", ["parent"] = null }));

node.Register(EruptModel.Of<Article>()
    .Edit(a => a.Title, new Edit { InputType = new InputType { Length = 64 } })
    .Operation("publish", new OperationOptions
    {
        Title = "Publish", Icon = "fa fa-paper-plane", Form = EruptModel.Of<PublishForm>(), IfExpr = "item.status !== 'published'",
    }, async op =>
    {
        foreach (var row in op.Rows) await op.Repo.UpdateAsync(row["id"]!, new Record { ["status"] = "published" });
    })
    .Operation("feature", new OperationOptions { Title = "Feature", Mode = RowOperationMode.SINGLE, Confirm = false },
        _ => Task.FromResult<string?>("alert('featured')"))
    .Operation("rebuild", new OperationOptions { Title = "Rebuild", Mode = RowOperationMode.BUTTON, Show = user => user?.Account == "root" },
        _ => Task.CompletedTask), new MemoryRepository());

node.Register(EruptModel.Of<Note>().Power(new Power { Delete = false })
    .Click(n => n.Ping, form => new FieldUpdate { Eval = $"pong:{form.GetValueOrDefault("text")}" }), new MemoryRepository());

await node.RunAsync(port, "127.0.0.1");

[EruptModel("Category")]
internal sealed class Category
{
    [Pk] public long Id { get; set; }
    [Field("Name", Search = true)] public string? Name { get; set; }
    [Field("Parent")] public long? Parent { get; set; }
}

[EruptModel("Publish Options")]
internal sealed class PublishForm
{
    [Field("Note", NotNull = true)] public string? Note { get; set; }
}

[EruptModel("Article", OrderBy = "id desc")]
internal sealed class Article
{
    [Pk] public long Id { get; set; }
    [Field("Title", Search = true, NotNull = true, Sortable = true)] public string? Title { get; set; }
    [Field("Status", Search = true), Choice("draft", "Draft"), Choice("published", "Published")] public string? Status { get; set; }
    [Field("Views", Sortable = true)] public long? Views { get; set; }
    [Field("Featured", Search = true)] public bool? Featured { get; set; }
    [Field("Publish Date", Search = true)] public DateOnly? PublishDate { get; set; }
    [Field("Review At")] public DateTime? ReviewAt { get; set; }
    [Field("Body", Type = EditType.TEXTAREA, Table = false)] public string? Body { get; set; }
    [Field("Category", Search = true)] public Category? Category { get; set; }
    [Field("Topic", Tree = "parent")] public Category? Topic { get; set; }
}

[EruptModel("Note", DataProxy = [typeof(NoteProxy)])]
internal sealed class Note
{
    [Pk] public long Id { get; set; }
    [Field("Text")] public string? Text { get; set; }
    [Field("Ping", Type = EditType.BUTTON)] public object? Ping { get; set; }
}

internal sealed class NoteProxy : IDataProxy
{
    public void AddBehavior(Record record) => record["text"] = "new";

    public void Validate(Record record)
    {
        if (record["text"] as string == "forbidden") throw new EruptFailure("forbidden text");
    }
}
