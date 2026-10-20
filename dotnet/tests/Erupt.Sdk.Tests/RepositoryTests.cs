using Microsoft.Data.Sqlite;

namespace Erupt.Tests;

public sealed class RepositoryTests : IDisposable
{
    private readonly string _db = Path.Combine(Path.GetTempPath(), $"erupt-{Guid.NewGuid():N}.db");

    public void Dispose()
    {
        SqliteConnection.ClearAllPools();
        File.Delete(_db);
    }

    public static TheoryData<string> Kinds => new() { "memory", "sqlite" };

    private IRepository Create(string kind)
    {
        IRepository repo = kind == "memory"
            ? new MemoryRepository()
            : new DbRepository(() => new SqliteConnection($"Data Source={_db}"), "article") { AutoCreateSqlite = true };
        repo.Bind(EruptModel.Of<Article>());
        return repo;
    }

    private static async Task<List<string?>> Titles(IRepository repo, params Cond[] conditions)
    {
        var (_, records) = await repo.PageAsync(new Query { Conditions = [.. conditions], Sort = [("title", false)], Limit = 100 });
        return records.Select(r => r["title"] as string).ToList();
    }

    [Theory]
    [MemberData(nameof(Kinds))]
    public async Task Operators(string kind)
    {
        var repo = Create(kind);
        await repo.AddAsync(new Record { ["title"] = "100% pure", ["views"] = 10L, ["featured"] = true, ["publish_date"] = new DateOnly(2026, 1, 5), ["review_at"] = new DateTime(2026, 1, 5, 10, 30, 0) });
        await repo.AddAsync(new Record { ["title"] = "100 points", ["views"] = 3L, ["featured"] = false, ["publish_date"] = new DateOnly(2026, 3, 1) });
        await repo.AddAsync(new Record { ["title"] = "under_score" });

        Assert.Equal(["100% pure"], await Titles(repo, new Cond("title", "LIKE", "100%")));
        Assert.Equal(["under_score"], await Titles(repo, new Cond("title", "LIKE", "R_S")));
        await repo.AddAsync(new Record { ["title"] = "wow!" });
        Assert.Equal(["wow!"], await Titles(repo, new Cond("title", "LIKE", "w!")));
        var (_, unsorted) = await repo.PageAsync(new Query { Limit = 100 });
        Assert.Equal(["100% pure", "100 points", "under_score", "wow!"], unsorted.Select(r => r["title"] as string));
        await repo.DeleteAsync([unsorted[3]["id"]!]);
        Assert.Equal(["100 points", "under_score"], await Titles(repo, new Cond("title", "NOT_LIKE", "pure")));
        Assert.Equal(["100% pure"], await Titles(repo, new Cond("views", "GT", 5L)));
        Assert.Equal(["100 points"], await Titles(repo, new Cond("featured", "EQ", false)));
        Assert.Equal(["100 points"], await Titles(repo, new Cond("publish_date", "RANGE", new List<object?> { new DateOnly(2026, 2, 1), new DateOnly(2026, 12, 31) })));
        Assert.Equal(["100 points", "100% pure"], await Titles(repo, new Cond("views", "IN", new List<object?> { 3L, 10L })));
        Assert.Empty(await Titles(repo, new Cond("views", "IN", new List<object?>())));
        Assert.Equal(["under_score"], await Titles(repo, new Cond("views", "NULL")));
        Assert.Equal(2, (await Titles(repo, new Cond("views", "NOT_NULL"))).Count);

        var (total, page) = await repo.PageAsync(new Query { Sort = [("views", true)], Offset = 0, Limit = 2 });
        Assert.Equal(3, total);
        Assert.Equal(2, page.Count);

        var first = (await repo.PageAsync(new Query { Conditions = [new Cond("title", "EQ", "100% pure")] })).Records[0];
        Assert.Equal(new DateTime(2026, 1, 5, 10, 30, 0), first["review_at"]);
        Assert.Equal(new DateOnly(2026, 1, 5), first["publish_date"]);
        Assert.Equal(true, first["featured"]);
        Assert.Equal(10L, first["views"]);

        await repo.UpdateAsync(first["id"]!, new Record { ["title"] = "renamed" });
        Assert.Equal("renamed", (await repo.GetAsync(first["id"]!))!["title"]);
        await repo.DeleteAsync([first["id"]!]);
        Assert.Null(await repo.GetAsync(first["id"]!));
    }

    [Fact]
    public void SqlQuotesIdentifiersAndParameterizesValues()
    {
        var repo = new DbRepository(() => throw new InvalidOperationException(), "t");
        var parameters = new List<object?>();
        var where = repo.Where([new Cond("title", "LIKE", "a%' OR 1=1 --"), new Cond("views", "IN", new List<object?> { 1L, 2L })], parameters);
        Assert.Equal(" WHERE \"title\" LIKE @p0 ESCAPE '!' AND \"views\" IN (@p1, @p2)", where);
        Assert.Equal(["%a!%' OR 1=1 --%", 1L, 2L], parameters);
        Assert.Equal("\"we\"\"ird\"", repo.Q("we\"ird"));
    }

    [Fact]
    public void OracleUsesColonParameters()
    {
        var repo = new DbRepository(() => throw new InvalidOperationException(), "t") { ParameterPrefix = ":", Paging = Paging.OffsetFetch };
        var parameters = new List<object?>();
        Assert.Equal(" WHERE \"title\" = :p0 AND \"views\" LIKE :p1 ESCAPE '!'",
            repo.Where([new Cond("title", "EQ", "a"), new Cond("views", "LIKE", "1!_")], parameters));
        Assert.Equal(["a", "%1!!!_%"], parameters);
    }

    [Fact]
    public void FiltersAreAndedAsWrittenWithBoundParams()
    {
        var repo = new DbRepository(() => throw new InvalidOperationException(), "t") { ParameterPrefix = ":" };
        var parameters = new List<object?>();
        Assert.Equal(" WHERE (owner = :p0 OR shared = :p1) AND (done = 0) AND \"title\" = :p2",
            repo.Where([new Cond("title", "EQ", "a")], parameters, [new SqlFilter("owner = ? OR shared = ?", "admin", true), "done = 0"]));
        Assert.Equal(["admin", true, "a"], parameters);
        Assert.Equal(" WHERE (title = 'a?')", repo.Where([], [], ["title = 'a?'"])); // without params, '?' is plain text
        Assert.Throws<ArgumentException>(() => repo.Where([], [], [new SqlFilter("owner = ?", "a", "b")]));
    }
}
