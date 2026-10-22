using System.Text.Json.Nodes;
using Erupt.GenTypes;

namespace Erupt.Tests;

public class DeclarationTests
{
    [Fact]
    public void BuildsFieldsFromTemplates()
    {
        var model = EruptModel.Of<Article>().Edit(a => a.Title, new Edit { InputType = new InputType { Length = 64 } });
        var json = model.BuildErupt();
        var fields = json["eruptFieldModels"]!.AsArray().ToDictionary(f => f!["fieldName"]!.GetValue<string>(), f => f!);
        Assert.Equal(["id", "title", "status", "views", "featured", "publish_date", "review_at", "body", "category", "topic"], fields.Keys);
        Assert.Equal("DATE_TIME", fields["review_at"]["eruptFieldJson"]!["edit"]!["dateType"]!["type"]!.GetValue<string>());
        Assert.Equal("DATE", fields["publish_date"]["eruptFieldJson"]!["views"]![0]!["type"]!.GetValue<string>());
        Assert.Equal(64, fields["title"]["eruptFieldJson"]!["edit"]!["inputType"]!["length"]!.GetValue<long>());
        Assert.Equal("Category", fields["category"]["fieldReturnName"]!.GetValue<string>());
        Assert.Equal("parent", fields["topic"]["eruptFieldJson"]!["edit"]!["referenceTreeType"]!["pid"]!.GetValue<string>());
        Assert.Empty(fields["body"]["eruptFieldJson"]!["views"]!.AsArray());
        Assert.Equal(2, fields["status"]["componentValue"]!.AsArray().Count);
        Assert.Equal("id", json["eruptJson"]!["primaryKeyCol"]!.GetValue<string>());
        Assert.Null(json["eruptJson"]!["orderBy"]);
    }

    [Fact]
    public void BuildMatchesSchema()
    {
        var model = EruptModel.Of<Article>()
            .Options(new EruptOptions { Layout = new Layout { PageSize = 30 } })
            .Operation("publish", new OperationOptions { Title = "Publish", Form = EruptModel.Of<PublishForm>() }, _ => Task.CompletedTask);
        var built = model.BuildModel(new JsonObject(), null);
        var erupt = built["eruptModel"]!;
        Schema.Check("Erupt", erupt["eruptJson"], "Article", partial: false);
        Assert.Equal(30, erupt["eruptJson"]!["layout"]!["pageSize"]!.GetValue<long>());
        foreach (var op in erupt["eruptJson"]!["rowOperation"]!.AsArray()) Schema.Check("RowOperation", op, "op", partial: false);
        foreach (var f in erupt["eruptFieldModels"]!.AsArray()) Schema.Check("EruptField", f!["eruptFieldJson"], "field", partial: false);
        Assert.Equal("PublishForm", built["operationErupts"]!["publish"]!["eruptName"]!.GetValue<string>());
    }

    [Theory]
    [InlineData(typeof(TwoPks), "at most one [Pk]")]
    [InlineData(typeof(UnsupportedType), "edit type TPL is not supported yet")]
    [InlineData(typeof(MissingLabel), "has no field 'title'")]
    [InlineData(typeof(BadOrder), "illegal OrderBy 'missing desc'")]
    [InlineData(typeof(BadName), "must be an identifier")]
    [InlineData(typeof(NotAModel), "is not marked with [EruptModel]")]
    public void RejectsIllegalDeclarations(Type type, string message)
    {
        var of = typeof(EruptModel).GetMethod(nameof(EruptModel.Of))!.MakeGenericMethod(type);
        var e = Assert.Throws<System.Reflection.TargetInvocationException>(() => of.Invoke(null, null));
        Assert.Contains(message, Assert.IsType<ArgumentException>(e.InnerException).Message);
    }

    [Fact]
    public void RejectsIllegalOperations()
    {
        var model = EruptModel.Of<Article>().Operation("go", new OperationOptions { Title = "Go" }, _ => Task.CompletedTask);
        Assert.Contains("declared twice", Assert.Throws<ArgumentException>(() =>
            model.Operation("go", new OperationOptions { Title = "Again" }, _ => Task.CompletedTask)).Message);
        Assert.Contains("RowOperationMode", Assert.Throws<ArgumentException>(() =>
            model.Operation("odd", new OperationOptions { Title = "Odd", Mode = (RowOperationMode)42 }, _ => Task.CompletedTask)).Message);
    }

    [Fact]
    public void SchemaRejectsUnknownAttributesAndValues()
    {
        Assert.Contains("Edit has no attribute 'inputTyp'",
            Assert.Throws<ArgumentException>(() => Schema.Check("Edit", new JsonObject { ["inputTyp"] = new JsonObject() }, "edit")).Message);
        Assert.Contains("is not a QueryExpression",
            Assert.Throws<ArgumentException>(() => Schema.Check("Edit", new JsonObject { ["search"] = new JsonObject { ["operator"] = "ABOUT" } }, "edit")).Message);
        Assert.Contains("expected integer",
            Assert.Throws<ArgumentException>(() => Schema.Check("Layout", new JsonObject { ["pageSize"] = 1.5 }, "layout")).Message);
    }

    [Fact]
    public void GeneratedTypesAreCurrent()
    {
        var library = Path.Combine(Root(), "src", "Erupt.Sdk");
        var schema = File.ReadAllText(Path.Combine(library, "Resources", "erupt-annotations.schema.json"));
        Assert.Equal(Generator.Generate(schema), File.ReadAllText(Path.Combine(library, "Types.g.cs")));
    }

    [Fact]
    public void CoercesLikePython()
    {
        var model = EruptModel.Of<Article>();
        object? Coerce(string field, object? value) => model.FieldMap[field].Coerce(value);
        Assert.Equal(3L, Coerce("views", "3"));
        Assert.Equal(2.5, Coerce("views", 2.5));
        Assert.Throws<FormatException>(() => Coerce("views", "many"));
        Assert.Equal(new DateOnly(2026, 1, 5), Coerce("publish_date", "2026-01-05 10:30"));
        Assert.Equal(new DateTime(2026, 1, 5, 10, 30, 0), Coerce("review_at", "2026-01-05T10:30:00.000Z"));
        Assert.Equal(DateTimeKind.Unspecified, ((DateTime)Coerce("review_at", "2026-01-05 10:30:00")!).Kind);
        Assert.Throws<FormatException>(() => Coerce("publish_date", "someday"));
        Assert.Equal(true, Coerce("featured", "1"));
        Assert.Throws<FormatException>(() => Coerce("status", "deleted"));
        Assert.Equal(2L, Coerce("category", new Dictionary<string, object?> { ["id"] = "2", ["name"] = "Python" }));
        Assert.Null(Coerce("title", ""));
    }

    internal static string Root()
    {
        var dir = new DirectoryInfo(AppContext.BaseDirectory);
        while (dir is not null && !Directory.Exists(Path.Combine(dir.FullName, "src", "Erupt.Sdk"))) dir = dir.Parent;
        return dir?.FullName ?? throw new InvalidOperationException("dotnet/ not found");
    }
}
