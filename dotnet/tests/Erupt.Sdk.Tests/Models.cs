using System.Text.Json.Nodes;

namespace Erupt.Tests;

[EruptModel("Category")]
public sealed class Category
{
    [Pk] public long Id { get; set; }
    [Field("Name", Search = true)] public string? Name { get; set; }
    [Field("Parent")] public long? Parent { get; set; }
}

[EruptModel("Publish Options")]
public sealed class PublishForm
{
    [Field("Note", NotNull = true)] public string? Note { get; set; }
}

[EruptModel("Article", OrderBy = "id desc")]
public sealed class Article
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

[EruptModel("Doc")]
public sealed class Doc
{
    [Pk] public long Id { get; set; }
    [Field("Title")] public string? Title { get; set; }
    [Field("Topic", Tree = "parent")] public Category? Topic { get; set; }
}

[EruptModel("Order")]
public sealed class Order
{
    [Pk] public long Id { get; set; }
    [Field("Status", Type = EditType.CHOICE)] public string? Status { get; set; }
    [Field("Tags", Type = EditType.TAGS)] public string? Tags { get; set; }
    [Field("Qty")] public long? Qty { get; set; }
    [Field("Note")] public string? Note { get; set; }
    [Field("City", Type = EditType.AUTO_COMPLETE)] public string? City { get; set; }
    [Field("Body", Type = EditType.MARKDOWN)] public string? Body { get; set; }
    [Field("Files", Type = EditType.ATTACHMENT)] public string? Files { get; set; }
    [Field("Categories", Type = EditType.CHECKBOX, Ref = typeof(Category))] public List<long>? Cats { get; set; }
    [Field("Sections", Type = EditType.TAB_TREE, Ref = typeof(Category))] public List<long>? Sections { get; set; }
    [Field("Colors"), Choice("red", "Red"), Choice("blue", "Blue")] public List<string>? Colors { get; set; }
    [Field("Calc", Type = EditType.BUTTON)] public object? Calc { get; set; }
    [Field("Stop", Type = EditType.BUTTON)] public object? Stop { get; set; }
}

[EruptModel("Memo", DataProxy = [typeof(MemoProxy)])]
public sealed class Memo
{
    [Pk] public long Id { get; set; }
    [Field("Text")] public string? Text { get; set; }
}

public sealed class MemoProxy : IDataProxy
{
    public static readonly List<(string Hook, object? Text)> Calls = [];

    public void SearchCondition(Record condition) => condition["text"] = "hi";

    public void AfterFetch(IReadOnlyList<JsonObject> rows)
    {
        foreach (var row in rows) row["text"] = row["text"]!.GetValue<string>().ToUpperInvariant();
    }

    public void AddBehavior(Record record) => record["text"] = "new";

    public void EditBehavior(Record record) => record["text"] += "?";

    public void Validate(Record record)
    {
        if (record["text"] as string == "forbidden") throw new EruptFailure("forbidden text");
    }

    // the write hooks only record that they ran, with the text they saw
    public void BeforeAdd(Record record) => Calls.Add(("BeforeAdd", record["text"]));

    public void AfterAdd(Record record) => Calls.Add(("AfterAdd", record["text"]));

    public void BeforeUpdate(Record record) => Calls.Add(("BeforeUpdate", record["text"]));

    public void AfterUpdate(Record record) => Calls.Add(("AfterUpdate", record["text"]));

    public void BeforeDelete(Record record) => Calls.Add(("BeforeDelete", record["text"]));

    public void AfterDelete(Record record) => Calls.Add(("AfterDelete", record["text"]));
}

[EruptModel("Task", Name = "Task", DataProxy = [typeof(TaskProxy), typeof(OpenProxy)])]
public sealed class TaskItem
{
    [Pk] public long Id { get; set; }
    [Field("Title", Search = true)] public string? Title { get; set; }
    [Field("Owner")] public string? Owner { get; set; }
    [Field("Done")] public bool Done { get; set; }
}

public sealed class TaskProxy : IDataProxy
{
    public SqlFilter BeforeFetch(IReadOnlyList<Cond> conditions) => new("owner = ?", EruptNode.CurrentUser!.Account);
}

public sealed class OpenProxy : IDataProxy
{
    public SqlFilter BeforeFetch(IReadOnlyList<Cond> conditions) => "done = 0";
}

[EruptModel("Bad")]
public sealed class TwoPks
{
    [Pk] public long Id { get; set; }
    [Pk(Name = "other")] public long Other { get; set; }
}

[EruptModel("Bad")]
public sealed class UnsupportedType
{
    [Pk] public long Id { get; set; }
    [Field("Map", Type = EditType.MAP)] public string? Map { get; set; }
}

[EruptModel("Bad")]
public sealed class MissingLabel
{
    [Pk] public long Id { get; set; }
    [Field("Category", Label = "title")] public Category? Category { get; set; }
}

[EruptModel("Bad", OrderBy = "missing desc")]
public sealed class BadOrder
{
    [Pk] public long Id { get; set; }
}

[EruptModel("Bad", Name = "Bad-Name")]
public sealed class BadName
{
    [Pk] public long Id { get; set; }
}

public sealed class NotAModel
{
    [Pk] public long Id { get; set; }
}
