namespace Erupt;

/// <summary>One search condition. <see cref="Op"/>: EQ NEQ GT GTE LT LTE LIKE NOT_LIKE RANGE IN NOT_IN NULL NOT_NULL.</summary>
public sealed record Cond(string Field, string Op, object? Value = null);

/// <summary>
/// SQL ANDed to a query's WHERE as written; with <see cref="Params"/>, each <c>?</c> in <see cref="Sql"/> is one of
/// them, bound. Without, <see cref="Sql"/> is taken whole (<c>title = 'a?'</c> holds no parameter).
/// </summary>
public sealed record SqlFilter(string Sql, params object?[] Params)
{
    public static implicit operator SqlFilter(string sql) => new(sql);
}

/// <summary>
/// What a repository is asked for. Field names are already checked against the model. <see cref="Filters"/> come
/// from a <c>@Vis</c> view and <see cref="IDataProxy.BeforeFetch"/>: a repository must apply them or refuse the
/// query, never ignore them.
/// </summary>
public sealed class Query
{
    public List<Cond> Conditions { get; init; } = [];

    /// <summary>The SQL of a <c>@Vis</c> view and every DataProxy's <see cref="IDataProxy.BeforeFetch"/>, ANDed to the conditions.</summary>
    public List<SqlFilter> Filters { get; init; } = [];

    /// <summary>(field, descending), most significant first.</summary>
    public List<(string Field, bool Desc)> Sort { get; set; } = [];

    public int Offset { get; init; }

    public int Limit { get; init; } = 10;
}

/// <summary>
/// Storage of one model. Implement these methods to put an erupt model on any storage. A repository only sees
/// field names the node has already checked against the model, so it may use them as identifiers; values must
/// always travel as parameters. A repository that cannot apply <see cref="Query.Filters"/> must throw rather than
/// ignore them.
/// </summary>
public interface IRepository
{
    /// <summary>Called once when the model is registered.</summary>
    void Bind(EruptModel model);

    /// <summary>The total matching <paramref name="query"/> and one page of records.</summary>
    Task<(long Total, IReadOnlyList<Record> Records)> PageAsync(Query query, CancellationToken ct = default);

    Task<Record?> GetAsync(object pk, CancellationToken ct = default);

    Task AddAsync(Record record, CancellationToken ct = default);

    /// <summary>Changes only the fields present in <paramref name="record"/>.</summary>
    Task UpdateAsync(object pk, Record record, CancellationToken ct = default);

    Task DeleteAsync(IReadOnlyList<object> pks, CancellationToken ct = default);
}

/// <summary>Records kept in process memory; the primary key is a sequence starting at 1. Refuses <see cref="Query.Filters"/>.</summary>
public sealed class MemoryRepository(params Record[] seed) : IRepository
{
    private readonly object _lock = new();
    private readonly Dictionary<long, Record> _rows = [];
    private long _seq;
    private string _pk = "id";

    public void Bind(EruptModel model)
    {
        _pk = model.Pk ?? "id";
        foreach (var record in seed) Add(record);
    }

    public Task<(long Total, IReadOnlyList<Record> Records)> PageAsync(Query query, CancellationToken ct = default)
    {
        if (query.Filters.Count > 0) throw new NotSupportedException("MemoryRepository cannot apply SQL filters (a view filter, BeforeFetch)");
        List<Record> rows;
        lock (_lock) rows = _rows.Values.Where(r => query.Conditions.All(c => Match(r.GetValueOrDefault(c.Field), c))).Select(Copy).ToList();
        IEnumerable<Record> sorted = rows;
        IOrderedEnumerable<Record>? ordered = null;
        foreach (var (field, desc) in query.Sort)
        {
            var comparer = new NullsLast(desc);
            ordered = ordered is null ? sorted.OrderBy(r => r.GetValueOrDefault(field), comparer) : ordered.ThenBy(r => r.GetValueOrDefault(field), comparer);
        }
        var page = (ordered ?? sorted).Skip(query.Offset).Take(query.Limit).ToList();
        return Task.FromResult<(long, IReadOnlyList<Record>)>((rows.Count, page));
    }

    public Task<Record?> GetAsync(object pk, CancellationToken ct = default)
    {
        lock (_lock) return Task.FromResult(Key(pk) is { } key && _rows.TryGetValue(key, out var row) ? Copy(row) : null);
    }

    public Task AddAsync(Record record, CancellationToken ct = default)
    {
        Add(record);
        return Task.CompletedTask;
    }

    public Task UpdateAsync(object pk, Record record, CancellationToken ct = default)
    {
        lock (_lock)
        {
            if (Key(pk) is { } key && _rows.TryGetValue(key, out var row))
                foreach (var (field, value) in record) row[field] = Values.Normalize(value);
        }
        return Task.CompletedTask;
    }

    public Task DeleteAsync(IReadOnlyList<object> pks, CancellationToken ct = default)
    {
        lock (_lock)
        {
            foreach (var pk in pks)
                if (Key(pk) is { } key) _rows.Remove(key);
        }
        return Task.CompletedTask;
    }

    private void Add(Record record)
    {
        lock (_lock)
        {
            var row = new Record(record.ToDictionary(e => e.Key, e => Values.Normalize(e.Value))) { [_pk] = ++_seq };
            _rows[_seq] = row;
        }
    }

    private static long? Key(object pk) => Values.Normalize(pk) is long l ? l : null;

    private static Record Copy(Record row) => new(row);

    private static bool Match(object? value, Cond c)
    {
        if (c.Op == "NULL") return value is null;
        if (c.Op == "NOT_NULL") return value is not null;
        if (value is null) return false;
        var list = c.Value as IEnumerable<object?>;
        return c.Op switch
        {
            "EQ" => Values.Same(value, c.Value),
            "NEQ" => !Values.Same(value, c.Value),
            "LIKE" => Values.Str(value).Contains(Values.Str(c.Value), StringComparison.OrdinalIgnoreCase),
            "NOT_LIKE" => !Values.Str(value).Contains(Values.Str(c.Value), StringComparison.OrdinalIgnoreCase),
            "IN" => list!.Any(v => Values.Same(value, v)),
            "NOT_IN" => !list!.Any(v => Values.Same(value, v)),
            "RANGE" => Values.Compare(list!.ElementAt(0)!, value) <= 0 && Values.Compare(value, list!.ElementAt(1)!) <= 0,
            "GT" => Values.Compare(value, c.Value!) > 0,
            "GTE" => Values.Compare(value, c.Value!) >= 0,
            "LT" => Values.Compare(value, c.Value!) < 0,
            "LTE" => Values.Compare(value, c.Value!) <= 0,
            _ => throw new ArgumentException($"illegal operator '{c.Op}'"),
        };
    }

    /// <summary>Ascending puts nulls last; descending reverses the whole order, nulls first.</summary>
    private sealed class NullsLast(bool desc) : IComparer<object?>
    {
        public int Compare(object? x, object? y)
        {
            var result = x is null || y is null ? (x is null ? 1 : 0) - (y is null ? 1 : 0) : Values.Compare(x, y);
            return desc ? -result : result;
        }
    }
}
