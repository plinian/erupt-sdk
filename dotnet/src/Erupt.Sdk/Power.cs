using System.Text.Json.Nodes;
using System.Text.Json.Serialization;

namespace Erupt;

/// <summary>Switches features of a model off (all are on by default); the server can still narrow them per user.</summary>
public sealed class Power
{
    [JsonPropertyName("add")] public bool? Add { get; set; }
    [JsonPropertyName("edit")] public bool? Edit { get; set; }
    [JsonPropertyName("delete")] public bool? Delete { get; set; }
    [JsonPropertyName("query")] public bool? Query { get; set; }
    [JsonPropertyName("viewDetails")] public bool? ViewDetails { get; set; }
    [JsonPropertyName("export")] public bool? Export { get; set; }
    [JsonPropertyName("importable")] public bool? Importable { get; set; }
    [JsonPropertyName("print")] public bool? Print { get; set; }
    [JsonPropertyName("copy")] public bool? Copy { get; set; }
    [JsonPropertyName("cellEdit")] public bool? CellEdit { get; set; }
    [JsonPropertyName("ai")] public bool? Ai { get; set; }
    [JsonPropertyName("comment")] public bool? Comment { get; set; }
    [JsonPropertyName("revision")] public bool? Revision { get; set; }

    internal JsonObject ToJson() => (JsonObject)System.Text.Json.JsonSerializer.SerializeToNode(this, Schema.Json)!;
}

/// <summary>The acting user the server forwards with every request.</summary>
public sealed class EruptUser
{
    [JsonPropertyName("uid")] public long? Uid { get; set; }
    [JsonPropertyName("account")] public string? Account { get; set; }
    [JsonPropertyName("name")] public string? Name { get; set; }
    [JsonPropertyName("tenantId")] public string? TenantId { get; set; }
}

/// <summary>A record as repositories store it: field name to value (a reference holds the referenced primary key).</summary>
public sealed class Record : Dictionary<string, object?>
{
    public Record()
    {
    }

    public Record(IDictionary<string, object?> values) : base(values)
    {
    }
}

/// <summary>Thrown by an operation, a DataProxy hook or a repository to refuse with a message the user sees.</summary>
public sealed class EruptFailure(string message) : Exception(message);
