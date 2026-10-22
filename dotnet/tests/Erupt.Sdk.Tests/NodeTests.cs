using System.Net;
using System.Text;
using System.Text.Json.Nodes;
using Microsoft.AspNetCore.Http;
using Microsoft.Data.Sqlite;

namespace Erupt.Tests;

public class NodeTests
{
    private const string Token = "node-secret";

    private sealed class PowerServer(Func<HttpRequestMessage, HttpResponseMessage> answer) : HttpMessageHandler
    {
        protected override Task<HttpResponseMessage> SendAsync(HttpRequestMessage request, CancellationToken ct) => Task.FromResult(answer(request));
    }

    private static EruptNode Node(bool serverUp = true, EruptModel? article = null)
    {
        var node = new EruptNode(new NodeOptions { Name = "blog", AccessToken = Token, Servers = ["http://server"] });
        node.Http = new HttpClient(new PowerServer(_ => serverUp
            ? new HttpResponseMessage(HttpStatusCode.OK)
            {
                Content = new StringContent("""{"add":true,"edit":true,"delete":true,"viewDetails":true,"export":true,"importable":true}"""),
            }
            : new HttpResponseMessage(HttpStatusCode.InternalServerError)));
        node.Register<Category>(new MemoryRepository(new Record { ["name"] = "Tech" }, new Record { ["name"] = "Python", ["parent"] = 1 }));
        node.Register(article ?? EruptModel.Of<Article>(), new MemoryRepository());
        return node;
    }

    private static async Task<(int Status, JsonNode? Body)> Call(EruptNode node, string method, string path, object? body = null,
        string? erupt = "Article", Action<HttpRequest>? tweak = null, string account = "admin")
    {
        var context = new DefaultHttpContext();
        context.Request.Method = method;
        context.Request.Path = path;
        context.Request.Headers["Access-Token"] = Token;
        context.Request.Headers["token"] = "t1";
        context.Request.Headers["user"] = Convert.ToBase64String(Encoding.UTF8.GetBytes($$"""{"uid":1,"account":"{{account}}"}"""));
        if (erupt is not null) context.Request.Headers["erupt"] = erupt;
        context.Request.Body = new MemoryStream(body is null ? [] : Encoding.UTF8.GetBytes(body as string ?? System.Text.Json.JsonSerializer.Serialize(body)));
        tweak?.Invoke(context.Request);
        context.Response.Body = new MemoryStream();
        await node.HandleAsync(context);
        var text = Encoding.UTF8.GetString(((MemoryStream)context.Response.Body).ToArray());
        return (context.Response.StatusCode, text.StartsWith('{') || text.StartsWith('[') ? JsonNode.Parse(text) : JsonValue.Create(text));
    }

    [Fact]
    public async Task Guards()
    {
        var node = Node();
        Assert.Equal(403, (await Call(node, "GET", "/erupt-api/build/Article", tweak: r => r.Headers.Origin = "http://evil")).Status);
        Assert.Equal(403, (await Call(node, "GET", "/erupt-api/build/Article", tweak: r => r.Headers["Access-Token"] = "bad")).Status);
        Assert.Equal(404, (await Call(node, "GET", "/erupt-api/build/Article", erupt: "Category")).Status);
        Assert.Equal(404, (await Call(node, "GET", "/erupt-api/build/Article", tweak: r => r.Headers["eruptParent"] = "blog.Category")).Status);
        Assert.Equal(200, (await Call(node, "GET", "/erupt-api/build/Article", tweak: r => r.Headers["eruptParent"] = "blog.Article")).Status);
        Assert.Equal("blog", (await Call(node, "GET", "/node-health", erupt: null)).Body!.GetValue<string>());
    }

    [Fact]
    public async Task CrudAndReferences()
    {
        var node = Node();
        var (status, r) = await Call(node, "POST", "/erupt-api/data/modify/Article",
            new { title = "Hello", views = "7", review_at = "2026-01-05 10:30:00", category = new { id = "2", name = "Python" } });
        Assert.Equal(200, status);
        Assert.True(r!["success"]!.GetValue<bool>());
        var (_, page) = await Call(node, "POST", "/erupt-api/data/table/Article", new { pageIndex = 1, pageSize = 10 });
        var row = page!["list"]![0]!;
        Assert.Equal(7, row["views"]!.GetValue<long>());
        Assert.Equal("2026-01-05T10:30:00.000", row["review_at"]!.GetValue<string>());
        // a reference travels as its key; the server resolves labels and flattened columns
        Assert.Equal(2, row["category"]!.GetValue<long>());
        Assert.False(row.AsObject().ContainsKey("category_name"));
        var (_, fail) = await Call(node, "POST", "/erupt-api/data/modify/Article", new { status = "draft" });
        Assert.Equal("Title cannot be empty", fail!["message"]!.GetValue<string>());
        var (treeStatus, _) = await Call(node, "GET", "/erupt-api/data/Article/reference-tree/topic");
        Assert.Equal(404, treeStatus); // the server builds reference trees
        // the picker is the server's too: it reads the referenced model's own table
        Assert.Equal(404, (await Call(node, "POST", "/erupt-api/data/Article/reference-table/category", new { })).Status);
    }

    [Fact]
    public async Task Operations()
    {
        var node = Node(article: EruptModel.Of<Article>()
            .Operation("publish", new OperationOptions { Title = "Publish", Form = EruptModel.Of<PublishForm>() }, _ => Task.CompletedTask)
            .Operation("feature", new OperationOptions { Title = "Feature" }, _ => Task.FromResult<string?>("alert('featured')"))
            .Operation("hidden", new OperationOptions { Title = "Hidden", Show = _ => false }, _ => Task.CompletedTask));
        await Call(node, "POST", "/erupt-api/data/modify/Article", new { title = "A" });
        var ids = new[] { 1 };
        const string path = "/erupt-api/invoke/Article/operation/";
        Assert.False((await Call(node, "POST", path + "publish", new { ids, param = new { } })).Body!["success"]!.GetValue<bool>());
        var (_, r) = await Call(node, "POST", path + "publish", new { ids, param = new { note = "go" } });
        Assert.Equal("Executed successfully", r!["message"]!.GetValue<string>());
        Assert.Equal("alert('featured')", (await Call(node, "POST", path + "feature", new { ids })).Body!["data"]!.GetValue<string>());
        Assert.Equal(403, (await Call(node, "POST", path + "hidden", new { ids })).Status);
        Assert.Equal(404, (await Call(node, "POST", path + "missing", new { })).Status);
        const string form = "/erupt-api/invoke/Article/operation-form/";
        Assert.Equal("""{"note":null}""", (await Call(node, "POST", form + "publish", new { })).Body!["data"]!.ToJsonString());
        Assert.Null((await Call(node, "POST", form + "feature", new { })).Body!["data"]); // an operation without a form
        Assert.Equal(404, (await Call(node, "POST", "/erupt-api/data/Article/operator/publish", new { ids })).Status);
    }

    [Fact]
    public async Task DataProxy()
    {
        var node = Node();
        node.Register<Memo>(new MemoryRepository());
        MemoProxy.Calls.Clear();
        var (_, build) = await Call(node, "GET", "/erupt-api/build/Memo", erupt: "Memo");
        Assert.Equal("""{"text":"hi"}""", build!["eruptModel"]!["searchCondition"]!.ToJsonString());
        Assert.Equal("new", (await Call(node, "GET", "/erupt-api/data/init-value/Memo", erupt: "Memo")).Body!["text"]!.GetValue<string>());
        var (_, fail) = await Call(node, "POST", "/erupt-api/data/modify/Memo", new { text = "forbidden" }, "Memo");
        Assert.Equal((false, "forbidden text"), (fail!["success"]!.GetValue<bool>(), fail["message"]!.GetValue<string>()));
        Assert.True((await Call(node, "POST", "/erupt-api/data/modify/Memo", new { text = "a" }, "Memo")).Body!["success"]!.GetValue<bool>());
        var (_, page) = await Call(node, "POST", "/erupt-api/data/table/Memo", new { }, "Memo");
        Assert.Equal("A", page!["list"]![0]!["text"]!.GetValue<string>());
        var pk = page["list"]![0]!["id"]!.GetValue<long>();
        Assert.Equal("a?", (await Call(node, "GET", $"/erupt-api/data/Memo/{pk}", erupt: "Memo")).Body!["text"]!.GetValue<string>());
        Assert.True((await Call(node, "POST", "/erupt-api/data/modify/Memo/update", new { id = pk, text = "b" }, "Memo")).Body!["success"]!.GetValue<bool>());
        Assert.True((await Call(node, "POST", "/erupt-api/data/modify/Memo/delete", new[] { pk }, "Memo")).Body!["success"]!.GetValue<bool>());
        Assert.Equal([("BeforeAdd", (object?)"a"), ("AfterAdd", "a"), ("BeforeUpdate", "b"), ("AfterUpdate", "b"), ("BeforeDelete", "b"), ("AfterDelete", "b")],
            MemoProxy.Calls);
    }

    [Fact]
    public async Task BeforeFetch()
    {
        using var keep = new SqliteConnection("Data Source=task;Mode=Memory;Cache=Shared");
        keep.Open(); // the shared in-memory database lives while one connection is open
        var node = Node();
        var task = EruptModel.Of<TaskItem>()
            .Vis(new Vis { Code = "q", Title = "Question", Type = VisType.TABLE }, filter: "title = 'a?'")
            .Vis(new Vis { Title = "Reversed", Type = VisType.TABLE }, "title desc", "1 = 1", "2 = 2");
        node.Register(task, new DbRepository(() => new SqliteConnection("Data Source=task;Mode=Memory;Cache=Shared"), "task") { AutoCreateSqlite = true });
        foreach (var (title, owner, done) in new[] { ("a", "admin", false), ("b", "admin", true), ("c", "root", false), ("a?", "admin", false) })
            await Call(node, "POST", "/erupt-api/data/modify/Task", new { title, owner, done }, "Task");
        var (_, page) = await Call(node, "POST", "/erupt-api/data/table/Task", new { }, "Task");
        Assert.Equal(["a", "a?"], page!["list"]!.AsArray().Select(r => r!["title"]!.GetValue<string>()));
        Assert.Equal(2, page["total"]!.GetValue<long>());
        (_, page) = await Call(node, "POST", "/erupt-api/data/table/Task",
            new { condition = new[] { new { key = "title", expression = "EQ", value = "a" } } }, "Task", account: "root");
        Assert.Empty(page!["list"]!.AsArray());
        // a view's own filter and order run on the node, and stay out of the build
        (_, page) = await Call(node, "POST", "/erupt-api/data/table/Task", new { vis = "q" }, "Task");
        Assert.Equal(["a?"], page!["list"]!.AsArray().Select(r => r!["title"]!.GetValue<string>()));
        (_, page) = await Call(node, "POST", "/erupt-api/data/table/Task", new { vis = "Reversed" }, "Task");
        Assert.Equal(["a?", "a"], page!["list"]!.AsArray().Select(r => r!["title"]!.GetValue<string>()));
        var (_, build) = await Call(node, "GET", "/erupt-api/build/Task", null, "Task");
        var vis = build!["eruptModel"]!["eruptJson"]!["vis"]!.AsArray().Select(v => v!.AsObject()).ToList();
        Assert.Equal(["q", "Reversed"], vis.Select(v => v["code"]!.GetValue<string>()));
        Assert.DoesNotContain(vis, v => v.ContainsKey("filter") || v.ContainsKey("orderBy"));
    }

    [Fact]
    public async Task LinkTree()
    {
        var node = Node();
        node.Register(EruptModel.Of<Doc>().Options(new EruptOptions { LinkTree = new LinkTree { Field = "topic", DependNode = true } }),
            new MemoryRepository(new Record { ["title"] = "a", ["topic"] = 1 }, new Record { ["title"] = "b", ["topic"] = 2 }, new Record { ["title"] = "c", ["topic"] = 3 }));
        async Task<IEnumerable<string>> Titles(object body) =>
            (await Call(node, "POST", "/erupt-api/data/table/Doc", body, "Doc")).Body!["list"]!.AsArray().Select(r => r!["title"]!.GetValue<string>());
        Assert.Empty(await Titles(new { })); // DependNode: nothing until a tree node is picked
        Assert.Equal(["b"], await Titles(new { linkTreeVal = new[] { 2 } }));
        Assert.Equal(["a", "b"], await Titles(new { linkTreeVal = new[] { "1", "2" } }));
        Assert.Contains("must be a reference field", Assert.Throws<ArgumentException>(() =>
            EruptModel.Of<Doc>().Options(new EruptOptions { LinkTree = new LinkTree { Field = "title" } })).Message);
    }

    [Fact]
    public async Task FieldTypesAndInvoke()
    {
        static FieldUpdate Refuse(Record _) => throw new EruptFailure("not now");
        var node = Node();
        node.Register(EruptModel.Of<Order>()
            .Fetch(o => o.Status, form => [("new", "New"), (form.GetValueOrDefault("note") as string ?? "x", "From form")])
            .Fetch(o => o.Tags, _ => ["red", "blue"])
            .OnChange(o => o.Qty, form => new FieldUpdate { FormData = new Record { ["note"] = $"{form["qty"]} items" } })
            .Complete(o => o.City, async (_, typed) =>
            {
                await Task.Yield();
                return new[] { "Paris", "Tokyo" }.Where(c => c.Contains(typed, StringComparison.OrdinalIgnoreCase));
            })
            .Click(o => o.Calc, _ => new FieldUpdate { Eval = "alert(1)", FormData = new Record { ["qty"] = 2 } })
            .Click(o => o.Stop, Refuse), new MemoryRepository());
        var (_, build) = await Call(node, "GET", "/erupt-api/build/Order", erupt: "Order");
        var fields = build!["eruptModel"]!["eruptFieldModels"]!.AsArray().ToDictionary(f => f!["fieldName"]!.GetValue<string>(), f => f!);
        JsonNode Edit(string name) => fields[name]["eruptFieldJson"]!["edit"]!;
        Assert.Equal("""["invoke"]""", Edit("status")["choiceType"]!["fetchHandler"]!.ToJsonString());
        Assert.Equal("""["invoke"]""", Edit("tags")["tagsType"]!["fetchHandler"]!.ToJsonString());
        Assert.Equal("invoke", Edit("qty")["onchange"]!.GetValue<string>());
        Assert.Equal(["MARKDOWN", "ATTACHMENT", "BUTTON", "MULTI_CHOICE"], new[] { "body", "files", "calc", "colors" }.Select(n => Edit(n)["type"]!.GetValue<string>()));
        Assert.Equal(["Category", "Category"], new[] { "cats", "sections" }.Select(n => fields[n]["fieldReturnName"]!.GetValue<string>()));
        Assert.Empty(fields["calc"]["eruptFieldJson"]!["views"]!.AsArray());

        Task<(int Status, JsonNode? Body)> Invoke(string kind, string field, object? form = null, string? value = null) =>
            Call(node, "POST", $"/erupt-api/invoke/Order/{kind}/{field}", new { form = form ?? new { }, value }, "Order");
        Assert.Equal("""[{"value":"new","label":"New"},{"value":"n","label":"From form"}]""",
            (await Invoke("options", "status", new { note = "n" })).Body!["data"]!.ToJsonString());
        Assert.Equal("""["red","blue"]""", (await Invoke("options", "tags")).Body!["data"]!.ToJsonString());
        Assert.Equal("""{"formData":{"note":"3 items"},"editExpr":{}}""", (await Invoke("onchange", "qty", new { qty = 3 })).Body!["data"]!.ToJsonString());
        Assert.Equal("""["Paris"]""", (await Invoke("autocomplete", "city", value: "pa")).Body!["data"]!.ToJsonString());
        Assert.Equal("alert(1)", (await Invoke("button", "calc")).Body!["data"]!["eval"]!.GetValue<string>());
        var stop = (await Invoke("button", "stop")).Body!;
        Assert.Equal((false, "not now"), (stop["success"]!.GetValue<bool>(), stop["message"]!.GetValue<string>()));
        Assert.Equal(404, (await Invoke("button", "qty")).Status); // a field without that code
        Assert.Equal(404, (await Invoke("options", "missing")).Status);

        // picked records arrive as [{id: key}] and are stored as their keys
        var (_, r) = await Call(node, "POST", "/erupt-api/data/modify/Order",
            new { cats = new object[] { new { id = 1 }, new { id = "2" } }, sections = new[] { new { id = 3 } }, tags = "[\"red\"]", colors = new[] { "red" } }, "Order");
        Assert.True(r!["success"]!.GetValue<bool>());
        var row = (await Call(node, "POST", "/erupt-api/data/table/Order", new { }, "Order")).Body!["list"]![0]!.AsObject();
        Assert.Equal(("[1,2]", "[3]", """["red"]"""), (row["cats"]!.ToJsonString(), row["sections"]!.ToJsonString(), row["colors"]!.ToJsonString()));
        Assert.False(row.ContainsKey("calc"));
        Assert.Equal("invoke", node.NodeInfo()["capabilities"]![0]!.GetValue<string>());

        // field code belongs to its type
        Assert.Contains("belongs to AUTO_COMPLETE", Assert.Throws<ArgumentException>(() => EruptModel.Of<Order>().Complete(o => o.Note, (_, _) => [])).Message);
        Assert.Contains("belongs to BUTTON", Assert.Throws<ArgumentException>(() => EruptModel.Of<Order>().Click(o => o.Qty, _ => new FieldUpdate())).Message);
        Assert.Contains("belongs to TAGS", Assert.Throws<ArgumentException>(() => EruptModel.Of<Order>().Fetch(o => o.Status, _ => ["a"])).Message);
        Assert.Contains("belongs to CHOICE", Assert.Throws<ArgumentException>(() => EruptModel.Of<Order>().Fetch(o => o.Note, _ => [("a", "A")])).Message);
    }

    private static EruptNode BookNode()
    {
        var node = Node();
        node.Register(EruptModel.Of<Author>().Drill(new Drill { Title = "Books", Link = new Link { LinkErupt = "Book" } }, joinColumn: "author.id"),
            new MemoryRepository(new Record { ["name"] = "Ann" }, new Record { ["name"] = "Bob" }));
        node.Register(EruptModel.Of<Book>().Edit(b => b.Shelf, new Edit { ReferenceTableType = new ReferenceTableType { DependField = "author" } }),
            new MemoryRepository(new Record { ["title"] = "a", ["author"] = 1 }, new Record { ["title"] = "b", ["author"] = 2 }, new Record { ["title"] = "c", ["author"] = 1 }));
        return node;
    }

    [Fact]
    public async Task Drill()
    {
        var node = BookNode();
        void Drill(HttpRequest r, string code)
        {
            r.Headers["Drill"] = code;
            r.Headers["DrillSourceErupt"] = "Author";
            r.Headers["DrillValue"] = "1";
        }
        var (_, page) = await Call(node, "POST", "/erupt-api/data/table/Book", new { }, "Book", r => Drill(r, "Books"));
        Assert.Equal(["a", "c"], page!["list"]!.AsArray().Select(r => r!["title"]!.GetValue<string>()));
        Assert.Equal(403, (await Call(node, "POST", "/erupt-api/data/table/Book", new { }, "Book", r => Drill(r, "x"))).Status);
        var (_, build) = await Call(node, "GET", "/erupt-api/build/Author", erupt: "Author");
        var drill = build!["eruptModel"]!["eruptJson"]!["drills"]![0]!.AsObject();
        Assert.Equal(("Books", "Books", "Book"), (drill["code"]!.GetValue<string>(), drill["title"]!.GetValue<string>(), drill["link"]!["linkErupt"]!.GetValue<string>()));
        Assert.False(drill["link"]!.AsObject().ContainsKey("joinColumn"));
    }

    [Fact]
    public async Task SimpleTypesAndDependColumn()
    {
        var node = BookNode();
        var (_, build) = await Call(node, "GET", "/erupt-api/build/Book", erupt: "Book");
        var edit = build!["eruptModel"]!["eruptFieldModels"]!.AsArray().ToDictionary(f => f!["fieldName"]!.GetValue<string>(), f => f!["eruptFieldJson"]!["edit"]!);
        Assert.Equal(["COLOR", "RATE", "HIDDEN", "TRANSFER"], new[] { "colour", "stars", "secret", "readers" }.Select(n => edit[n]["type"]!.GetValue<string>()));
        Assert.Equal("parent", edit["shelf"]["referenceTableType"]!["dependColumn"]!.GetValue<string>()); // the server reads it off the build
        Assert.True((await Call(node, "POST", "/erupt-api/data/modify/Book", new { title = "d", stars = "4", readers = new[] { new { id = 2 } } }, "Book")).Body!["success"]!.GetValue<bool>());
        var row = (await Call(node, "POST", "/erupt-api/data/table/Book", new { }, "Book")).Body!["list"]!.AsArray()[^1]!;
        Assert.Equal((4, "[2]"), (row["stars"]!.GetValue<long>(), row["readers"]!.ToJsonString()));
    }

    [Fact]
    public async Task NodeConfigAndUserInfo()
    {
        var node = Node();
        var seen = new List<(string Path, string? Token)>();
        node.Http = new HttpClient(new PowerServer(request =>
        {
            var path = request.RequestUri!.AbsolutePath;
            seen.Add((path, request.Headers.TryGetValues("token", out var token) ? token.Single() : null));
            return new HttpResponseMessage(HttpStatusCode.OK)
            {
                Content = new StringContent(path.Contains("userinfo") ? """{"account":"admin","roles":["r"]}""" : "cfg"),
            };
        }));
        Assert.Equal("cfg", await node.ConfigAsync());
        Assert.Equal("cfg", await node.GroupConfigAsync());
        Assert.Equal("""{"account":"admin","roles":["r"]}""", (await node.UserInfoAsync())!.ToJsonString());
        Assert.Equal(["/erupt-cloud-api/node-config/blog", "/erupt-cloud-api/node-group-config/blog", "/erupt-cloud-api/userinfo/blog"], seen.Select(s => s.Path));
    }

    [Fact]
    public async Task BeforeFetchNeedsSql()
    {
        var node = Node();
        node.Register<TaskItem>(new MemoryRepository());
        Assert.Equal(500, (await Call(node, "POST", "/erupt-api/data/table/Task", new { }, "Task")).Status);
    }

    [Fact]
    public async Task FailsClosedWithoutTheServer()
    {
        var node = Node(serverUp: false);
        Assert.Equal(403, (await Call(node, "POST", "/erupt-api/data/modify/Article", new { title = "x" })).Status);
    }

    [Fact]
    public void RegisterNeedsReferencedModelsFirst()
    {
        var node = new EruptNode(new NodeOptions { Name = "blog", AccessToken = Token, Servers = ["http://server"] });
        Assert.Contains("register Category before", Assert.Throws<ArgumentException>(() => node.Register(EruptModel.Of<Article>(), new MemoryRepository())).Message);
        Assert.Contains("only an operation form", Assert.Throws<ArgumentException>(() => node.Register<PublishForm>(new MemoryRepository())).Message);
    }

    [Fact]
    public void AddressFromLocalhostIsIPv4AndValid()
    {
        Assert.Equal(IPAddress.Loopback, EruptNode.LocalIp("http://localhost:8080"));
        var node = new EruptNode(new NodeOptions { Name = "blog", AccessToken = Token, Servers = ["http://localhost:8080"] });
        node.ResolveAddress(9090);
        Assert.Equal("http://127.0.0.1:9090", node.Options.Address);
        Assert.True(Uri.TryCreate(node.Options.Address, UriKind.Absolute, out _));
    }

    [Fact]
    public void IPv6AddressIsBracketed()
    {
        Assert.Equal("[::1]:9090", EruptNode.HostPort(IPAddress.IPv6Loopback, 9090));
        var node = new EruptNode(new NodeOptions { Name = "blog", AccessToken = Token, Servers = ["http://[::1]:8080"] });
        node.ResolveAddress(9090);
        Assert.Equal("http://[::1]:9090", node.Options.Address);
        Assert.Equal("::1", new Uri(node.Options.Address!).Host.Trim('[', ']'));
    }
}
