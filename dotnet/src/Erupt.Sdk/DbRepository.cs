using System.Data.Common;
using System.Globalization;

namespace Erupt;

/// <summary>How a database pages results.</summary>
public enum Paging
{
    /// <summary><c>LIMIT n OFFSET m</c>: SQLite, PostgreSQL, MySQL.</summary>
    LimitOffset,

    /// <summary><c>OFFSET m ROWS FETCH NEXT n ROWS ONLY</c>: SQL Server 2012+, Oracle 12c+.</summary>
    OffsetFetch,
}

/// <summary>
/// A table over any ADO.NET provider. Identifiers come from the model (checked when it was declared) and are
/// quoted; every value is a parameter (<c>@p0</c> for SQLite, SQL Server, PostgreSQL and MySQL providers,
/// <c>:p0</c> for Oracle via <see cref="ParameterPrefix"/>). Dates are bound as <c>DateOnly</c> / <c>DateTime</c>
/// for the provider to map (ISO text on SQLite). <see cref="Query.Filters"/> are ANDed in parentheses, their
/// <c>?</c> bound the same way. Without a sort, rows come back by primary key ascending.
/// </summary>
public sealed class DbRepository(Func<DbConnection> connect, string table) : IRepository
{
    private EruptModel _model = null!;

    /// <summary>Opening and closing quote of identifiers (<c>"</c> by default; <c>`</c> for MySQL, <c>[</c> <c>]</c> for SQL Server).</summary>
    public (string Open, string Close) Quote { get; init; } = ("\"", "\"");

    public Paging Paging { get; init; } = Paging.LimitOffset;

    /// <summary>Marker of a named parameter in SQL text: <c>@</c> by default, <c>:</c> for Oracle.</summary>
    public string ParameterPrefix { get; init; } = "@";

    /// <summary>Create the table when missing, with SQLite column types. Leave off for any other database.</summary>
    public bool AutoCreateSqlite { get; init; }

    public void Bind(EruptModel model)
    {
        _model = model;
        if (!AutoCreateSqlite) return;
        var columns = model.Stored.Select(f => f.IsPk
            ? $"{Q(f.Name)} INTEGER PRIMARY KEY AUTOINCREMENT"
            : $"{Q(f.Name)} {(f.IsNumber ? "NUMERIC" : f.Type is "BOOLEAN" || f.IsReference ? "INTEGER" : "TEXT")}");
        using var conn = Open();
        Execute(conn, $"CREATE TABLE IF NOT EXISTS {Q(table)} ({string.Join(", ", columns)})", []);
    }

    public async Task<(long Total, IReadOnlyList<Record> Records)> PageAsync(Query query, CancellationToken ct = default)
    {
        var parameters = new List<object?>();
        var where = Where(query.Conditions, parameters, query.Filters);
        await using var conn = Open();
        var total = Convert.ToInt64(await Command(conn, $"SELECT COUNT(*) FROM {Q(table)}{where}", parameters).ExecuteScalarAsync(ct), CultureInfo.InvariantCulture);
        var order = query.Sort.Count > 0
            ? string.Join(", ", query.Sort.Select(s => $"{Q(s.Field)} {(s.Desc ? "DESC" : "ASC")}"))
            : $"{Q(_model.Pk!)} ASC";
        var limit = P(parameters, query.Limit);
        var offset = P(parameters, query.Offset);
        var paging = Paging == Paging.LimitOffset ? $"LIMIT {limit} OFFSET {offset}" : $"OFFSET {offset} ROWS FETCH NEXT {limit} ROWS ONLY";
        return (total, await Read(conn, $"SELECT * FROM {Q(table)}{where} ORDER BY {order} {paging}", parameters, ct));
    }

    public async Task<Record?> GetAsync(object pk, CancellationToken ct = default)
    {
        var parameters = new List<object?>();
        await using var conn = Open();
        var rows = await Read(conn, $"SELECT * FROM {Q(table)} WHERE {Q(_model.Pk!)} = {P(parameters, pk)}", parameters, ct);
        return rows.FirstOrDefault();
    }

    public async Task AddAsync(Record record, CancellationToken ct = default)
    {
        var values = record.Where(e => e.Key != _model.Pk).Select(Column).ToList();
        var parameters = new List<object?>();
        var placeholders = values.Select(e => P(parameters, e.Value)).ToList();
        await using var conn = Open();
        await Command(conn, $"INSERT INTO {Q(table)} ({string.Join(", ", values.Select(e => Q(e.Key)))}) VALUES ({string.Join(", ", placeholders)})", parameters).ExecuteNonQueryAsync(ct);
    }

    public async Task UpdateAsync(object pk, Record record, CancellationToken ct = default)
    {
        var values = record.Where(e => e.Key != _model.Pk).Select(Column).ToList();
        if (values.Count == 0) return;
        var parameters = new List<object?>();
        var sets = string.Join(", ", values.Select(e => $"{Q(e.Key)} = {P(parameters, e.Value)}"));
        await using var conn = Open();
        await Command(conn, $"UPDATE {Q(table)} SET {sets} WHERE {Q(_model.Pk!)} = {P(parameters, pk)}", parameters).ExecuteNonQueryAsync(ct);
    }

    public async Task DeleteAsync(IReadOnlyList<object> pks, CancellationToken ct = default)
    {
        if (pks.Count == 0) return;
        var parameters = new List<object?>();
        var list = string.Join(", ", pks.Select(pk => P(parameters, pk)));
        await using var conn = Open();
        await Command(conn, $"DELETE FROM {Q(table)} WHERE {Q(_model.Pk!)} IN ({list})", parameters).ExecuteNonQueryAsync(ct);
    }

    /// <summary>The WHERE clause of <paramref name="conditions"/> and <paramref name="filters"/>, values appended to <paramref name="parameters"/>.</summary>
    internal string Where(IEnumerable<Cond> conditions, List<object?> parameters, IEnumerable<SqlFilter>? filters = null)
    {
        var clauses = new List<string>();
        foreach (var f in filters ?? [])
        {
            // the developer's own SQL, as written; with params, each '?' is one of them, bound like every other value
            var pieces = f.Params.Length > 0 ? f.Sql.Split('?') : [f.Sql];
            if (pieces.Length - 1 != f.Params.Length)
                throw new ArgumentException($"filter: {pieces.Length - 1} '?' for {f.Params.Length} params in \"{f.Sql}\"");
            clauses.Add("(" + pieces[0] + string.Concat(f.Params.Select((v, i) => P(parameters, v) + pieces[i + 1])) + ")");
        }
        foreach (var c in conditions)
        {
            var col = Q(c.Field);
            var list = (c.Value as IEnumerable<object?>)?.ToList();
            clauses.Add(c.Op switch
            {
                "EQ" => $"{col} = {P(parameters, c.Value)}",
                "NEQ" => $"{col} <> {P(parameters, c.Value)}",
                "GT" => $"{col} > {P(parameters, c.Value)}",
                "GTE" => $"{col} >= {P(parameters, c.Value)}",
                "LT" => $"{col} < {P(parameters, c.Value)}",
                "LTE" => $"{col} <= {P(parameters, c.Value)}",
                "LIKE" or "NOT_LIKE" => $"{col} {(c.Op == "NOT_LIKE" ? "NOT " : "")}LIKE {P(parameters, "%" + Escape(Values.Str(c.Value)) + "%")} ESCAPE '!'",
                "RANGE" => $"{col} BETWEEN {P(parameters, list![0])} AND {P(parameters, list[1])}",
                "IN" or "NOT_IN" when list!.Count == 0 => c.Op == "IN" ? "1=0" : "1=1",
                "IN" or "NOT_IN" => $"{col} {(c.Op == "NOT_IN" ? "NOT " : "")}IN ({string.Join(", ", list!.Select(v => P(parameters, v)))})",
                "NULL" => $"{col} IS NULL",
                "NOT_NULL" => $"{col} IS NOT NULL",
                _ => throw new ArgumentException($"illegal operator '{c.Op}'"),
            });
        }
        return clauses.Count > 0 ? " WHERE " + string.Join(" AND ", clauses) : "";
    }

    internal string Q(string identifier) => Quote.Open + identifier.Replace(Quote.Close, Quote.Close + Quote.Close) + Quote.Close;

    // '!' rather than a backslash: MySQL reads a backslash inside a string literal as an escape itself
    private static string Escape(string text) => text.Replace("!", "!!").Replace("%", "!%").Replace("_", "!_");

    private string P(List<object?> parameters, object? value)
    {
        parameters.Add(value);
        return ParameterPrefix + "p" + (parameters.Count - 1).ToString(CultureInfo.InvariantCulture);
    }

    private DbConnection Open()
    {
        var conn = connect();
        if (conn.State != System.Data.ConnectionState.Open) conn.Open();
        return conn;
    }

    private DbCommand Command(DbConnection conn, string sql, List<object?> parameters)
    {
        var cmd = conn.CreateCommand();
        cmd.CommandText = sql;
        for (var i = 0; i < parameters.Count; i++)
        {
            var p = cmd.CreateParameter();
            // SqlClient, Npgsql, MySqlConnector and Sqlite take the marker in the name, Oracle does not
            p.ParameterName = (ParameterPrefix == "@" ? "@p" : "p") + i.ToString(CultureInfo.InvariantCulture);
            p.Value = ToDb(parameters[i]);
            cmd.Parameters.Add(p);
        }
        return cmd;
    }

    private void Execute(DbConnection conn, string sql, List<object?> parameters) => Command(conn, sql, parameters).ExecuteNonQuery();

    // Dates go to the provider as DateOnly / DateTime: Npgsql types a string parameter as text, which PostgreSQL
    // refuses for date and timestamp columns, while Microsoft.Data.Sqlite stores both as ISO text anyway
    private static object ToDb(object? value) => value switch
    {
        null => DBNull.Value,
        DateOnly or DateTime => value,
        _ => Values.Normalize(value)!,
    };

    private async Task<List<Record>> Read(DbConnection conn, string sql, List<object?> parameters, CancellationToken ct)
    {
        await using var reader = await Command(conn, sql, parameters).ExecuteReaderAsync(ct);
        var rows = new List<Record>();
        while (await reader.ReadAsync(ct))
        {
            var record = new Record();
            for (var i = 0; i < reader.FieldCount; i++)
            {
                var name = reader.GetName(i);
                if (!_model.FieldMap.TryGetValue(name, out var field)) continue;
                record[name] = FromDb(field, reader.IsDBNull(i) ? null : reader.GetValue(i));
            }
            rows.Add(record);
        }
        return rows;
    }

    // a JSON field goes in as JSON text: a parameter is a scalar for every provider
    private KeyValuePair<string, object?> Column(KeyValuePair<string, object?> e) =>
        e.Value is not null && _model.FieldMap.TryGetValue(e.Key, out var f) && f.IsJson
            ? KeyValuePair.Create(e.Key, (object?)Values.ToJson(e.Value)!.ToJsonString())
            : e;

    private static object? FromDb(FieldDef field, object? value) => value switch
    {
        null => null,
        string text when field.IsJson => Values.Plain(System.Text.Json.Nodes.JsonNode.Parse(text)),
        _ when field.Type == "BOOLEAN" => value is bool b ? b : Convert.ToInt64(value, CultureInfo.InvariantCulture) != 0,
        _ when field.Type == "DATE" => value switch
        {
            DateOnly d => d,
            DateTime dt => DateOnly.FromDateTime(dt),
            _ => DateOnly.FromDateTime(Values.ParseDateTime(value)),
        },
        _ when field.Type == FieldDef.TemplateDateTime => value is DateTime t ? t : Values.ParseDateTime(value),
        _ => Values.Normalize(value),
    };
}
