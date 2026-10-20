/// Checks annotation JSON against erupt-annotations.schema.json (the same schema Types.swift is generated from),
/// so an unknown attribute or enum value fails when the model is declared instead of silently doing nothing in
/// the browser.
public enum Schema {
    static let defs: [String: JSON] = {
        guard let defs = try? JSON.parse(Embedded.annotationsSchema)["$defs"]?.object else {
            fatalError("the embedded erupt-annotations.schema.json is malformed")
        }
        return defs
    }()

    /// The declared defaults of definition `name`, as Java fills an attribute left out.
    static func defaults(_ name: String) -> [String: JSON] {
        (defs[name]?["properties"]?.object ?? [:]).compactMapValues { $0["default"] }
    }

    /// Throws unless `value` fits definition `name`. `partial` (an override) lets every attribute be omitted;
    /// otherwise the attributes the Java side always emits must be present.
    public static func check(_ name: String, _ value: JSON, path: String? = nil, partial: Bool = true) throws {
        try walk(["$ref": .string("#/$defs/\(name)")], value, path ?? name, partial)
    }

    private static func walk(_ schema: JSON, _ value: JSON, _ path: String, _ partial: Bool) throws {
        if let ref = schema["$ref"]?.string {
            return try walkRef(String(ref.split(separator: "/").last!), value, path, partial)
        }
        let kind = schema["type"]?.string ?? ""
        switch kind {
        case "array":
            guard let items = value.array else { throw DeclarationError("\(path): expected an array") }
            for (i, item) in items.enumerated() { try walk(schema["items"]!, item, "\(path)[\(i)]", partial) }
        case "object":
            guard let members = value.object else { throw DeclarationError("\(path): expected an object") }
            if let each = schema["additionalProperties"] {
                for (k, item) in members { try walk(each, item, "\(path).\(k)", partial) }
            }
        default:
            let ok: Bool
            switch (kind, value) {
            case ("string", .string), ("integer", .int), ("boolean", .bool), ("number", .int), ("number", .double): ok = true
            case ("integer", .double): ok = value.int != nil
            default: ok = false
            }
            if !ok { throw DeclarationError("\(path): expected \(kind), got \(value.serialized())") }
        }
    }

    private static func walkRef(_ name: String, _ value: JSON, _ path: String, _ partial: Bool) throws {
        guard let d = defs[name] else { throw DeclarationError("\(path): unknown definition \(name)") }
        if let values = d["enum"]?.array {
            if values.contains(value) { return }
            throw DeclarationError(
                "\(path): '\(value.text)' is not a \(name), expected one of \(values.map(\.text).joined(separator: ", "))")
        }
        guard let members = value.object else { throw DeclarationError("\(path): expected an object (\(name))") }
        let properties = d["properties"]?.object ?? [:]
        for key in members.keys.sorted() {
            guard let property = properties[key] else { throw DeclarationError("\(path): \(name) has no attribute '\(key)'") }
            try walk(property, members[key]!, "\(path).\(key)", partial)
        }
        if !partial {
            let missing = (d["required"]?.array ?? []).compactMap(\.string).filter { members[$0] == nil }
            if !missing.isEmpty { throw DeclarationError("\(path): missing \(missing.joined(separator: ", "))") }
        }
    }
}
