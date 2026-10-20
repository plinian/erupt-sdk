using System.Text.Json;
using System.Text.Json.Nodes;
using System.Text.RegularExpressions;

namespace Erupt;

/// <summary>
/// Checks annotation JSON against erupt-annotations.schema.json (the schema Types.g.cs is generated from), so a
/// misspelt attribute or an unknown enum value fails when the model is declared instead of silently doing
/// nothing in the browser. Also serves the field templates of erupt-node-defaults.json.
/// </summary>
internal static partial class Schema
{
    internal static readonly JsonObject Defs = Load("erupt-annotations.schema.json")["$defs"]!.AsObject();

    internal static readonly JsonObject Defaults = Load("erupt-node-defaults.json");

    internal static readonly JsonSerializerOptions Json = new()
    {
        DefaultIgnoreCondition = System.Text.Json.Serialization.JsonIgnoreCondition.WhenWritingNull,
        Encoder = System.Text.Encodings.Web.JavaScriptEncoder.UnsafeRelaxedJsonEscaping,
    };

    [GeneratedRegex(@"^-?\d+$")]
    private static partial Regex Integer();

    private static JsonObject Load(string name)
    {
        using var stream = typeof(Schema).Assembly.GetManifestResourceStream(name)
                           ?? throw new InvalidOperationException($"missing embedded resource {name}");
        return JsonNode.Parse(stream)!.AsObject();
    }

    /// <summary>The declared defaults of definition <paramref name="name"/>, as Java fills an attribute left out.</summary>
    internal static JsonObject DefaultsOf(string name) =>
        new(Defs[name]!["properties"]!.AsObject().Where(p => p.Value!["default"] is not null)
            .Select(p => KeyValuePair.Create(p.Key, (JsonNode?)p.Value!["default"]!.DeepClone())));

    /// <summary>A generated annotation object (or raw JSON) as JSON, checked as a partial override of <paramref name="name"/>.</summary>
    internal static JsonObject Override(string name, object? value, string path)
    {
        if (value is null) return new JsonObject();
        var node = value as JsonNode ?? JsonSerializer.SerializeToNode(value, value.GetType(), Json);
        if (node is not JsonObject obj) throw new ArgumentException($"{path}: expected an object ({name})");
        Check(name, obj, path);
        return obj;
    }

    /// <summary>
    /// Throw <see cref="ArgumentException"/> unless <paramref name="value"/> fits definition <paramref name="name"/>.
    /// <paramref name="partial"/> (an override) lets every attribute be omitted; otherwise the attributes the Java side
    /// always emits must be present.
    /// </summary>
    internal static void Check(string name, JsonNode? value, string path, bool partial = true) =>
        Check(new JsonObject { ["$ref"] = "#/$defs/" + name }, value, path, partial);

    private static void Check(JsonNode schema, JsonNode? value, string path, bool partial)
    {
        if (schema["$ref"] is JsonNode reference)
        {
            var name = reference.GetValue<string>().Split('/')[^1];
            var def = Defs[name]!;
            if (def["enum"] is JsonArray values)
            {
                var text = value is JsonValue v && v.GetValueKind() == JsonValueKind.String ? v.GetValue<string>() : null;
                if (text is null || !values.Any(x => x!.GetValue<string>() == text))
                    throw new ArgumentException($"{path}: '{value?.ToJsonString()}' is not a {name}, expected one of {string.Join(", ", values.Select(x => x!.GetValue<string>()))}");
                return;
            }
            if (value is not JsonObject obj) throw new ArgumentException($"{path}: expected an object ({name})");
            var props = def["properties"]!.AsObject();
            foreach (var (key, item) in obj)
            {
                if (!props.ContainsKey(key)) throw new ArgumentException($"{path}: {name} has no attribute '{key}'");
                Check(props[key]!, item, $"{path}.{key}", partial);
            }
            if (!partial && def["required"] is JsonArray required)
            {
                var missing = required.Select(x => x!.GetValue<string>()).Where(k => !obj.ContainsKey(k)).ToList();
                if (missing.Count > 0) throw new ArgumentException($"{path}: missing {string.Join(", ", missing)}");
            }
            return;
        }
        switch (schema["type"]!.GetValue<string>())
        {
            case "array":
                if (value is not JsonArray array) throw new ArgumentException($"{path}: expected an array");
                for (var i = 0; i < array.Count; i++) Check(schema["items"]!, array[i], $"{path}[{i}]", partial);
                return;
            case "object":
                if (value is not JsonObject map) throw new ArgumentException($"{path}: expected an object");
                if (schema["additionalProperties"] is not JsonNode items) return;
                foreach (var (key, item) in map) Check(items, item, $"{path}.{key}", partial);
                return;
            case var kind:
                var actual = value is JsonValue jv ? jv.GetValueKind() : JsonValueKind.Undefined;
                var ok = kind switch
                {
                    "string" => actual == JsonValueKind.String,
                    "boolean" => actual is JsonValueKind.True or JsonValueKind.False,
                    "number" => actual == JsonValueKind.Number,
                    "integer" => actual == JsonValueKind.Number && Integer().IsMatch(value!.ToJsonString()),
                    _ => false,
                };
                if (!ok) throw new ArgumentException($"{path}: expected {kind}, got {value?.ToJsonString() ?? "null"}");
                return;
        }
    }
}
