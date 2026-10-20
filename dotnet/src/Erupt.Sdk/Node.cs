using System.Collections.Concurrent;
using System.Globalization;
using System.Net;
using System.Net.Sockets;
using System.Security.Cryptography;
using System.Text;
using System.Text.Json;
using System.Text.Json.Nodes;
using System.Text.RegularExpressions;
using Microsoft.AspNetCore.Http;
using Microsoft.Extensions.Logging;
using Microsoft.Extensions.Logging.Abstractions;

namespace Erupt;

/// <summary>How a node registers with the erupt server.</summary>
public sealed class NodeOptions
{
    /// <summary>The node name created on the server (Node Config).</summary>
    public required string Name { get; init; }

    /// <summary>The node's access token from the server; keep it out of source control.</summary>
    public required string AccessToken { get; init; }

    /// <summary>erupt server base URLs, used round-robin.</summary>
    public required IReadOnlyList<string> Servers { get; init; }

    /// <summary>The URL the server reaches this node on; detected (preferring IPv4) when null.</summary>
    public string? Address { get; set; }

    public TimeSpan Heartbeat { get; init; } = TimeSpan.FromSeconds(15);

    /// <summary>Refuse server calls without a valid Erupt-Signature, so the plain access token alone no longer passes.</summary>
    public bool RequireSignature { get; init; }
}

/// <summary>
/// An erupt cloud node: registers with the server, then answers the requests it forwards. The wire contract is
/// erupt-cloud/PROTOCOL.md. Mount it with <c>app.MapEruptNode(node)</c> or run it with <see cref="RunAsync"/>.
/// </summary>
public sealed partial class EruptNode
{
    public const string Version = "0.1.0";

    // Features whose endpoints this SDK does not serve yet: hidden from the UI instead of failing there
    private static readonly string[] Unsupported = ["print", "ai"];

    // Rights the server decides per user; the node ANDs them onto the declared power
    private static readonly string[] ServerPower = ["add", "edit", "delete", "viewDetails", "export", "importable"];

    private static readonly HashSet<string> Ops = ["EQ", "NEQ", "GT", "GTE", "LT", "LTE", "LIKE", "NOT_LIKE", "RANGE", "IN", "NOT_IN", "NULL", "NOT_NULL"];

    private const int MaxPageSize = 1000;

    private static readonly AsyncLocal<EruptUser?> User = new();

    private readonly Dictionary<string, (EruptModel Model, IRepository Repo)> _models = [];
    private readonly ConcurrentDictionary<(string, string), (DateTime Expires, JsonObject Power)> _powerCache = new();
    private readonly List<(string Method, Regex Pattern, Func<Request, string[], Task<JsonNode?>> Handler)> _routes;
    private readonly string[] _servers;
    private int _next;

    internal HttpClient Http { get; set; } = new() { Timeout = TimeSpan.FromSeconds(5) };

    internal ILogger Logger { get; set; } = NullLogger.Instance;

    internal string InstanceId { get; } = Convert.ToHexString(RandomNumberGenerator.GetBytes(3)).ToLowerInvariant();

    public NodeOptions Options { get; }

    public EruptNode(NodeOptions options)
    {
        if (string.IsNullOrEmpty(options.AccessToken)) throw new ArgumentException("AccessToken is required");
        if (options.Servers.Count == 0) throw new ArgumentException("at least one server is required");
        Options = options;
        _servers = options.Servers.Select(s => s.TrimEnd('/')).ToArray();
        _routes =
        [
            ("GET", Route("^/erupt-api/build/([^/]+)$"), Build),
            ("POST", Route("^/erupt-api/data/table/([^/]+)$"), Table),
            ("GET", Route("^/erupt-api/data/init-value/([^/]+)$"), InitValue),
            ("GET", Route("^/erupt-api/data/([^/]+)/([^/]+)$"), Get),
            ("POST", Route("^/erupt-api/data/modify/([^/]+)$"), Add),
            ("POST", Route("^/erupt-api/data/modify/([^/]+)/update$"), Update),
            ("POST", Route("^/erupt-api/data/modify/([^/]+)/delete$"), Delete),
            ("POST", Route("^/erupt-api/invoke/([^/]+)/([^/]+)/([^/]+)$"), Invoke),
        ];
    }

    /// <summary>The acting user of the request being served (also inside repositories).</summary>
    public static EruptUser? CurrentUser => User.Value;

    public IReadOnlyCollection<string> ModelNames => _models.Keys;

    public EruptNode Register<T>(IRepository repository) => Register(EruptModel.Of<T>(), repository);

    /// <summary>Serve <paramref name="model"/> from <paramref name="repository"/>. Register referenced models first.</summary>
    public EruptNode Register(EruptModel model, IRepository repository)
    {
        if (_models.ContainsKey(model.Name)) throw new ArgumentException($"erupt '{model.Name}' registered twice");
        if (model.Pk is null) throw new ArgumentException($"{model.Name} has no [Pk]; only an operation form may omit it");
        foreach (var f in model.Fields.Where(f => f.IsReference && f.Target.Name != model.Name))
            if (!_models.ContainsKey(f.Target.Name))
                throw new ArgumentException($"{model.Name}.{f.Name}: register {f.Target.Name} before the models referencing it");
        repository.Bind(model);
        _models[model.Name] = (model, repository);
        return this;
    }

    private static Regex Route(string pattern) => new(pattern, RegexOptions.CultureInvariant);

    // ---------------------------------------------------------------- HTTP

    private sealed record Request(HttpContext Http, EruptModel Model, IRepository Repo, JsonNode? Body);

    private sealed class Reply(int status) : Exception
    {
        internal int Status { get; } = status;
    }

    private static JsonObject R(bool success = true, string? message = null, JsonNode? data = null) => new()
    {
        ["success"] = success, ["status"] = success ? "SUCCESS" : "ERROR", ["message"] = message, ["data"] = data,
        ["promptWay"] = "MESSAGE",
    };

    /// <summary>Serve one forwarded request (<c>/node-health</c> and <c>/erupt-api/**</c>).</summary>
    public async Task HandleAsync(HttpContext context)
    {
        int status;
        object? body;
        try
        {
            (status, body) = await Dispatch(context);
        }
        catch (Reply reply)
        {
            (status, body) = (reply.Status, "");
        }
        catch (EruptFailure failure)
        {
            (status, body) = (200, R(false, failure.Message));
        }
        catch (Exception e) // never leak internals: message only, the stack stays in the node log
        {
            Logger.LogError(e, "erupt node error");
            (status, body) = (500, new JsonObject
            {
                ["path"] = context.Request.Path.Value, ["status"] = 500, ["error"] = "erupt exception", ["message"] = e.Message,
            });
        }
        context.Response.StatusCode = status;
        if (body is string text)
        {
            context.Response.ContentType = "text/plain; charset=utf-8";
            await context.Response.WriteAsync(text);
        }
        else
        {
            context.Response.ContentType = "application/json; charset=utf-8";
            await context.Response.WriteAsync(body is JsonNode node ? node.ToJsonString(Schema.Json) : "null");
        }
    }

    private async Task<(int, object?)> Dispatch(HttpContext context)
    {
        var request = context.Request;
        var path = request.Path.Value ?? "";
        if (path == "/node-health") return (200, Options.Name);
        if (!path.StartsWith("/erupt-api/", StringComparison.Ordinal)) throw new Reply(404);
        // server-to-server only: an Origin header means a browser reached the node directly
        if (!string.IsNullOrEmpty(request.Headers.Origin)) throw new Reply(403);
        var raw = await ReadBody(request);
        Authenticate(context, raw);
        var erupt = request.Headers["erupt"].ToString();
        foreach (var (method, pattern, handler) in _routes)
        {
            var match = pattern.Match(path);
            if (method != request.Method || !match.Success) continue;
            var name = match.Groups[1].Value;
            if (erupt != name || !_models.TryGetValue(name, out var entry)) throw new Reply(404);
            var parent = request.Headers["eruptParent"].ToString();
            if (parent.Length == 0) parent = request.Query["_eruptParent"].ToString();
            // nesting is not supported yet, so a parent can only vouch for itself
            if (parent.Length > 0 && parent.Split('.')[^1] != name) throw new Reply(404);
            var user = request.Headers["user"].ToString();
            User.Value = user.Length > 0 ? JsonSerializer.Deserialize<EruptUser>(Convert.FromBase64String(user)) : null;
            var body = ParseJson(raw);
            var args = match.Groups.Cast<Group>().Skip(2).Select(g => g.Value).ToArray();
            return (200, await handler(new Request(context, entry.Model, entry.Repo, body), args));
        }
        throw new Reply(404);
    }

    private static async Task<byte[]> ReadBody(HttpRequest request)
    {
        using var buffer = new MemoryStream();
        await request.Body.CopyToAsync(buffer);
        return buffer.ToArray();
    }

    /// <summary>
    /// A signed call must verify, and then stands for the token; its Erupt-Enforced is trusted only then.
    /// </summary>
    private void Authenticate(HttpContext context, byte[] body)
    {
        var request = context.Request;
        var signature = request.Headers[Signature.HeaderSignature].ToString();
        if (signature.Length == 0)
        {
            if (Options.RequireSignature || !CryptographicOperations.FixedTimeEquals(
                    Encoding.UTF8.GetBytes(request.Headers["Access-Token"].ToString()), Encoding.UTF8.GetBytes(Options.AccessToken)))
                throw new Reply(403);
            return;
        }
        var multipart = (request.ContentType ?? "").Contains("multipart/form-data", StringComparison.OrdinalIgnoreCase);
        var enforced = request.Headers[Signature.HeaderEnforced].ToString();
        var pathAndQuery = request.Path.ToUriComponent() + request.QueryString.ToUriComponent();
        if (!Signature.Verify(Options.AccessToken, request.Method, pathAndQuery, request.Headers[Signature.HeaderTimestamp].ToString(),
                enforced, request.Headers["user"].ToString(), multipart ? null : body, signature, DateTimeOffset.UtcNow.ToUnixTimeSeconds()))
            throw new Reply(403);
        context.Items[EnforcedKey] = enforced.Split(',', StringSplitOptions.RemoveEmptyEntries).ToHashSet();
    }

    private static readonly object EnforcedKey = new();

    private static bool Enforced(HttpContext http, string check) =>
        http.Items[EnforcedKey] is HashSet<string> enforced && enforced.Contains(check);

    private static JsonNode? ParseJson(byte[] raw)
    {
        var text = Encoding.UTF8.GetString(raw);
        if (text.Length == 0) return null;
        try
        {
            return JsonNode.Parse(text);
        }
        catch (JsonException)
        {
            throw new EruptFailure("malformed JSON body");
        }
    }

    private static JsonObject BodyObject(Request r) => r.Body switch
    {
        null => [],
        JsonObject obj => obj,
        _ => throw new EruptFailure("a JSON object is required"),
    };

    // ---------------------------------------------------------------- endpoints

    private async Task<JsonNode?> Build(Request r, string[] _) => r.Model.BuildModel(await Power(r.Model, r.Http), CurrentUser);

    private async Task<JsonNode?> Table(Request r, string[] _)
    {
        await Require(r, "query");
        return await Page(r.Model, r.Repo, BodyObject(r), r.Http.RequestAborted);
    }

    private async Task<JsonNode> Page(EruptModel model, IRepository repo, JsonObject body, CancellationToken ct)
    {
        var pageIndex = Math.Max(Int(body["pageIndex"], 1), 1);
        var pageSize = Math.Min(Math.Max(Int(body["pageSize"], 10), 1), MaxPageSize);
        var query = new Query { Offset = (pageIndex - 1) * pageSize, Limit = pageSize };
        foreach (var c in body["condition"] as JsonArray ?? []) query.Conditions.Add(Condition(model, c as JsonObject ?? []));
        foreach (var s in body["sort"] as JsonArray ?? [])
        {
            var name = Values.Plain(s?["field"]) as string;
            if (name is null || !model.FieldMap.TryGetValue(name, out var f) || !(f.Sortable || f.IsPk))
                throw new EruptFailure($"illegal sort field '{name}'");
            query.Sort.Add((f.Name, Values.Str(Values.Plain(s?["direction"]) ?? "ASC").ToUpperInvariant() == "DESC"));
        }
        // a @LinkTree table shows the rows under the picked tree keys; with DependNode, none until one is picked
        var picked = Values.Plain(body["linkTreeVal"]);
        if (model.LinkTree is (var link, _) && picked is not null) query.Conditions.Add(Condition(model.FieldMap[link], "IN", picked));
        // a @Vis view's own filter and order, then the DataProxy's
        var (filters, sort) = model.Views.GetValueOrDefault(Values.Plain(body["vis"]) as string ?? "", ([], []));
        if (query.Sort.Count == 0) query.Sort = [.. sort.Count > 0 ? sort : model.OrderBy];
        query.Filters.AddRange(filters);
        query.Filters.AddRange(model.Filters(query.Conditions));
        var (total, records) = model.LinkTree is { DependNode: true } && picked is null ? (0, []) : await repo.PageAsync(query, ct);
        var rows = await Rows(model, records, ct);
        model.Hook(p => p.AfterFetch(rows.Cast<JsonObject>().ToList()));
        return new JsonObject
        {
            ["pageIndex"] = pageIndex, ["pageSize"] = pageSize, ["total"] = total,
            ["totalPage"] = (long)Math.Ceiling(total / (double)pageSize), ["list"] = rows,
            ["sort"] = null, ["alert"] = null, ["extraContent"] = null,
        };
    }

    private static int Int(JsonNode? node, int fallback) =>
        Values.Plain(node) is { } value && value is not "" and not false ? Convert.ToInt32(value, CultureInfo.InvariantCulture) : fallback;

    private static Cond Condition(EruptModel model, JsonObject c)
    {
        var key = Values.Plain(c["key"]) as string;
        if (key is null || !model.FieldMap.TryGetValue(key, out var f) || f.IsPk || !f.Search)
            throw new EruptFailure($"illegal search field '{key}'");
        var op = Values.Plain(c["expression"]) as string;
        return Condition(f, string.IsNullOrEmpty(op) ? "EQ" : op, Values.Plain(c["value"]));
    }

    private static Cond Condition(FieldDef f, string op, object? value)
    {
        if (!Ops.Contains(op)) throw new EruptFailure($"illegal operator '{op}'");
        if (op is "NULL" or "NOT_NULL") return new Cond(f.Name, op);
        if (f.IsReference && op is not ("EQ" or "NEQ" or "IN" or "NOT_IN")) throw new EruptFailure($"illegal operator '{op}' for a reference");
        if (op is "LIKE" or "NOT_LIKE") return new Cond(f.Name, op, Values.Str(value));
        try
        {
            if (op == "RANGE")
            {
                if (value is not List<object?> { Count: 2 } range) throw new FormatException("range needs two values");
                return new Cond(f.Name, op, range.Select(f.Coerce).ToList());
            }
            if (op is "IN" or "NOT_IN") return new Cond(f.Name, op, (value as List<object?> ?? [value]).Select(f.Coerce).ToList());
            return new Cond(f.Name, op, f.Coerce(value));
        }
        catch (FormatException e)
        {
            throw new EruptFailure(e.Message);
        }
    }

    private async Task<JsonNode?> InitValue(Request r, string[] _)
    {
        await Require(r, "add");
        var record = new Record(r.Model.Stored.ToDictionary(f => f.Name, _ => (object?)null));
        r.Model.Hook(p => p.AddBehavior(record));
        return (await Rows(r.Model, [record], r.Http.RequestAborted))[0];
    }

    private async Task<JsonNode?> Get(Request r, string[] args)
    {
        var power = await Power(r.Model, r.Http);
        if (!(Bool(power, "edit") || Bool(power, "viewDetails"))) throw new Reply(403);
        var record = await r.Repo.GetAsync(Pk(r.Model, args[0])!, r.Http.RequestAborted) ?? throw new EruptFailure("record not found");
        r.Model.Hook(p => p.EditBehavior(record));
        return (await Rows(r.Model, [record], r.Http.RequestAborted))[0];
    }

    private async Task<JsonNode?> Add(Request r, string[] _)
    {
        await Require(r, "add");
        var record = ToRecord(r.Model, BodyObject(r));
        r.Model.Hook(p => p.Validate(record));
        r.Model.Hook(p => p.BeforeAdd(record));
        await r.Repo.AddAsync(record, r.Http.RequestAborted);
        r.Model.Hook(p => p.AfterAdd(record));
        return R();
    }

    private async Task<JsonNode?> Update(Request r, string[] _)
    {
        await Require(r, "edit");
        var body = BodyObject(r);
        var pk = Pk(r.Model, Values.Plain(body[r.Model.Pk!]));
        if (pk is null || await r.Repo.GetAsync(pk, r.Http.RequestAborted) is null) throw new EruptFailure("record not found");
        var record = ToRecord(r.Model, body);
        r.Model.Hook(p => p.Validate(record));
        r.Model.Hook(p => p.BeforeUpdate(record));
        await r.Repo.UpdateAsync(pk, record, r.Http.RequestAborted);
        r.Model.Hook(p => p.AfterUpdate(record));
        return R();
    }

    private async Task<JsonNode?> Delete(Request r, string[] _)
    {
        await Require(r, "delete");
        if (r.Body is not JsonArray ids) throw new EruptFailure("a list of ids is required");
        var pks = ids.Select(id => Pk(r.Model, Values.Plain(id))!).ToList();
        // the hooks see each record as it was; reading them costs nothing without a proxy
        var records = new List<Record>();
        if (r.Model.Proxies.Count > 0)
            foreach (var pk in pks)
                if (await r.Repo.GetAsync(pk, r.Http.RequestAborted) is { } record) records.Add(record);
        foreach (var record in records) r.Model.Hook(p => p.BeforeDelete(record));
        await r.Repo.DeleteAsync(pks, r.Http.RequestAborted);
        foreach (var record in records) r.Model.Hook(p => p.AfterDelete(record));
        return R();
    }

    /// <summary>
    /// The node's own code (erupt-cloud/PROTOCOL.md §5.5): a row operation and its form values under the operation
    /// code, or a field's fetched options, onchange, auto-complete or button with the form's values.
    /// </summary>
    private static async Task<JsonNode?> Invoke(Request r, string[] args)
    {
        if (args[0] == "operation") return await Operation(r, args[1]);
        if (args[0] == "operation-form") return R(data: OperationFormValue(r.Model, args[1]));
        if (!r.Model.FieldMap.TryGetValue(args[1], out var f) || !f.Invoked.TryGetValue(args[0], out var code)) throw new Reply(404);
        var body = BodyObject(r);
        var form = new Record(Values.Plain(body["form"]) as Dictionary<string, object?> ?? []);
        return R(data: await code(form, Values.Plain(body["value"]) as string ?? ""));
    }

    /// <summary>
    /// Records to browser rows. A reference stays its key: the server resolves its label, the flattened
    /// &lt;field&gt;_&lt;label&gt; column and the tree (erupt-cloud/PROTOCOL.md §7.3).
    /// </summary>
    private static Task<JsonArray> Rows(EruptModel model, IReadOnlyList<Record> records, CancellationToken ct)
    {
        var rows = new JsonArray();
        foreach (var record in records)
        {
            var row = new JsonObject();
            foreach (var f in model.Stored) row[f.Name] = Values.ToJson(record.GetValueOrDefault(f.Name));
            rows.Add(row);
        }
        return Task.FromResult(rows);
    }

    private static OperationDef OperationOf(EruptModel model, string code)
    {
        var op = model.Operations.FirstOrDefault(o => o.Code == code) ?? throw new Reply(404);
        // a hidden operation does not exist for this user, exactly like the Java proxy filters it out
        return op.Visible(CurrentUser) ? op : throw new Reply(403);
    }

    private static JsonObject? OperationFormValue(EruptModel model, string code) =>
        // none without a form: the server answers the browser a 404, and it opens an empty one
        OperationOf(model, code).Form is { } form ? new JsonObject(form.Fields.Select(f => KeyValuePair.Create(f.Name, (JsonNode?)null))) : null;

    private static async Task<JsonNode?> Operation(Request r, string code)
    {
        var op = OperationOf(r.Model, code);
        var body = BodyObject(r);
        Record? param = null;
        if (op.Form is not null) param = ToRecord(op.Form, body["param"] as JsonObject ?? []);
        var rows = new List<Record>();
        if (op.Mode != RowOperationMode.BUTTON)
        {
            if (body["ids"] is not JsonArray { Count: > 0 } ids) throw new EruptFailure("select at least one row");
            if (op.Mode == RowOperationMode.SINGLE && ids.Count != 1) throw new EruptFailure("select exactly one row");
            foreach (var id in ids)
            {
                var record = await r.Repo.GetAsync(Pk(r.Model, Values.Plain(id))!, r.Http.RequestAborted);
                rows.Add(record ?? throw new EruptFailure($"record '{Values.Str(Values.Plain(id))}' not found"));
            }
        }
        var result = await op.Handler(new OperationContext
        {
            Rows = rows, Param = param, Repo = r.Repo, Model = r.Model, User = CurrentUser, CancellationToken = r.Http.RequestAborted,
        });
        return string.IsNullOrEmpty(result) ? R(message: "Executed successfully") : R(data: result);
    }

    private static object? Pk(EruptModel model, object? value)
    {
        try
        {
            return FieldDef.CoercePk(value) ?? throw new FormatException();
        }
        catch (FormatException)
        {
            throw new EruptFailure($"illegal id '{Values.Str(value)}'");
        }
    }

    private static Record ToRecord(EruptModel model, JsonObject body)
    {
        var record = new Record();
        foreach (var f in model.Stored.Where(f => !f.IsPk && f.Form))
        {
            object? value;
            try
            {
                value = f.Coerce(Values.Plain(body[f.Name]));
            }
            catch (FormatException e)
            {
                throw new EruptFailure($"{f.Title}: {e.Message}");
            }
            if (f.NotNull && value is null) throw new EruptFailure($"{f.Title} cannot be empty");
            record[f.Name] = value;
        }
        return record;
    }

    // ---------------------------------------------------------------- permissions (PROTOCOL.md §6.1)

    private async Task Require(Request r, string right)
    {
        if (!Bool(await Power(r.Model, r.Http), right)) throw new Reply(403);
    }

    private static bool Bool(JsonObject power, string right) => power[right] is JsonValue v && v.GetValueKind() == JsonValueKind.True;

    private async Task<JsonObject> Power(EruptModel model, HttpContext http)
    {
        if (Enforced(http, "power"))
        {
            // the server checked the user's rights and restricts the build's power itself: the model's own
            // declaration is all that is left to apply here
            var declared = model.PowerJson.DeepClone().AsObject();
            foreach (var feature in Unsupported) declared[feature] = false;
            return declared;
        }
        var token = http.Request.Headers["token"].ToString();
        var key = (token, model.Name);
        if (_powerCache.TryGetValue(key, out var cached) && cached.Expires > DateTime.UtcNow) return cached.Power;
        var power = model.PowerJson.DeepClone().AsObject();
        foreach (var feature in Unsupported) power[feature] = false;
        JsonObject remote;
        try
        {
            var query = $"?nodeName={Uri.EscapeDataString(Options.Name)}&eruptName={Uri.EscapeDataString(model.Name)}";
            using var request = new HttpRequestMessage(HttpMethod.Get, NextServer() + "/erupt-cloud-api/erupt-power" + query);
            request.Headers.TryAddWithoutValidation("token", token);
            using var response = await Http.SendAsync(request, http.RequestAborted);
            response.EnsureSuccessStatusCode();
            remote = JsonNode.Parse(await response.Content.ReadAsStringAsync(http.RequestAborted)) as JsonObject ?? [];
        }
        catch (Exception e) when (e is HttpRequestException or TaskCanceledException or JsonException)
        {
            // fail closed: without the server's verdict nothing is writable
            Logger.LogWarning("erupt-power unavailable: {Message}", e.Message);
            remote = [];
        }
        foreach (var right in ServerPower) power[right] = Bool(power, right) && Bool(remote, right);
        if (_powerCache.Count > 10000) _powerCache.Clear();
        _powerCache[key] = (DateTime.UtcNow.AddSeconds(5), power);
        return power;
    }

    // ---------------------------------------------------------------- registration

    internal string NextServer() => _servers[(int)((uint)Interlocked.Increment(ref _next) % _servers.Length)];

    /// <summary>The address the server should call: configured, else this machine's address towards the server.</summary>
    internal void ResolveAddress(int port)
    {
        if (Options.Address is not null)
        {
            Options.Address = Options.Address.TrimEnd('/');
            return;
        }
        Options.Address = "http://" + HostPort(LocalIp(_servers[0]), port);
    }

    /// <summary>host:port, an IPv6 host bracketed as a URL requires.</summary>
    internal static string HostPort(IPAddress ip, int port) =>
        (ip.AddressFamily == AddressFamily.InterNetworkV6 ? $"[{ip}]" : ip.ToString()) + ":" + port.ToString(CultureInfo.InvariantCulture);

    /// <summary>The interface address the server would see us on, IPv4 first ("localhost" may resolve to ::1 first).</summary>
    internal static IPAddress LocalIp(string server)
    {
        try
        {
            var host = new Uri(server).Host.Trim('[', ']');
            var candidates = IPAddress.TryParse(host, out var literal) ? [literal] : Dns.GetHostAddresses(host);
            var target = candidates.FirstOrDefault(a => a.AddressFamily == AddressFamily.InterNetwork) ?? candidates.First();
            using var socket = new Socket(target.AddressFamily, SocketType.Dgram, ProtocolType.Udp);
            socket.Connect(target, 80);
            return ((IPEndPoint)socket.LocalEndPoint!).Address;
        }
        catch (Exception e) when (e is SocketException or UriFormatException or InvalidOperationException)
        {
            return IPAddress.Loopback;
        }
    }

    internal JsonObject NodeInfo() => new()
    {
        ["instanceId"] = InstanceId, ["nodeName"] = Options.Name, ["accessToken"] = Options.AccessToken,
        ["version"] = "dotnet-" + Version, ["nodeAddress"] = new JsonArray(Options.Address),
        ["eruptModules"] = new JsonArray(), ["erupts"] = new JsonArray(_models.Keys.Select(k => (JsonNode)k).ToArray()),
        ["resources"] = new JsonObject(), ["capabilities"] = new JsonArray("invoke"),
    };

    /// <summary>Register every <see cref="NodeOptions.Heartbeat"/> until cancelled (half the interval after a failure).</summary>
    internal async Task HeartbeatAsync(CancellationToken ct)
    {
        var failing = false;
        while (!ct.IsCancellationRequested)
        {
            var server = NextServer();
            try
            {
                using var content = new StringContent(NodeInfo().ToJsonString(), Encoding.UTF8, "application/json");
                using var response = await Http.PostAsync(server + "/erupt-cloud-api/register-node", content, ct);
                response.EnsureSuccessStatusCode();
                if (failing) Logger.LogInformation("{Server} -> connection success", server);
                failing = false;
                await Task.Delay(Options.Heartbeat, ct);
            }
            catch (OperationCanceledException) when (ct.IsCancellationRequested)
            {
                return;
            }
            catch (Exception e) when (e is HttpRequestException or TaskCanceledException)
            {
                failing = true;
                Logger.LogError("{Server} -> register failed: {Message}", server, e.Message);
                try
                {
                    await Task.Delay(Options.Heartbeat / 2, ct);
                }
                catch (OperationCanceledException)
                {
                    return;
                }
            }
        }
    }

    /// <summary>Tell the server to stop routing to this instance.</summary>
    internal async Task DeregisterAsync()
    {
        try
        {
            using var content = new FormUrlEncodedContent(new Dictionary<string, string>
            {
                ["nodeName"] = Options.Name, ["accessToken"] = Options.AccessToken, ["locations"] = Options.Address ?? "",
            });
            using var response = await Http.PostAsync(NextServer() + "/erupt-cloud-api/remove-instance-node", content);
        }
        catch (Exception e) when (e is HttpRequestException or TaskCanceledException)
        {
            Logger.LogError("deregister failed: {Message}", e.Message);
        }
    }
}
