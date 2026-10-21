/// One record, keyed by field name.
public typealias Record = [String: JSON]

/// What a field holds; it picks the edit type unless `type:` names one.
public enum FieldKind {
    /// INPUT
    case string
    /// NUMBER
    case number
    /// BOOLEAN
    case bool
    /// DATE, held as `2026-01-05`
    case date
    /// DATE with a time of day, held as `2026-01-05T10:30:00.000`
    case dateTime
    /// A JSON array or object (MULTI_CHOICE, KEY_VALUE): SQL repositories store it as JSON text
    case json
    /// A record of `model`, stored as its primary key, picked from a table that shows `label`
    case ref(Model, label: String = "name")
    /// A record of `model` picked from a tree over its parent field `pid`
    case tree(Model, pid: String, label: String = "name")
}

/// One column of a model. `title` labels both the table column and the form input; `view` / `edit` take typed
/// annotation attributes for anything the shortcuts do not cover. A `virtual` field is a form-only element
/// (DIVIDE, CALLOUT, EMPTY, GROUP) that is in the build but never read or written.
public struct Field {
    public let name: String
    public let title: String
    let kind: FieldKind
    let explicitType: EditType?
    let pk, search, notNull, sortable, table, form, virtual: Bool
    let choices: [(value: String, label: String)]?
    let view: View?
    let edit: Edit?
    /// the template key the field resolves to: an EditType, or DATE_TIME
    var type = ""

    public init(
        _ name: String, _ title: String = "", _ kind: FieldKind = .string, type: EditType? = nil, pk: Bool = false,
        search: Bool = false, notNull: Bool = false, sortable: Bool = false, table: Bool = true, form: Bool = true,
        choices: KeyValuePairs<String, String>? = nil, view: View? = nil, edit: Edit? = nil, virtual: Bool = false
    ) {
        self.name = name
        self.title = title
        self.kind = kind
        self.explicitType = type
        self.pk = pk
        self.search = search
        self.notNull = notNull
        self.sortable = sortable
        self.table = table
        self.form = form
        self.choices = choices.map { $0.map { (value: $0.key, label: $0.value) } }
        self.view = view
        self.edit = edit
        self.virtual = virtual
    }

    var isJSON: Bool { if case .json = kind { return true } else { return false } }

    var isReference: Bool { type == EditType.referenceTable.rawValue || type == EditType.referenceTree.rawValue }

    /// The referenced model, label and tree parent field of a reference.
    var reference: (target: Model, label: String, pid: String?)? {
        switch kind {
        case .ref(let model, let label): return (model, label, nil)
        case .tree(let model, let pid, let label): return (model, label, pid)
        default: return nil
        }
    }

    mutating func resolve(_ path: String) throws {
        guard isIdentifier(name) else { throw DeclarationError("\(path): name must be an identifier") }
        if let view { try Schema.check("View", view.json, path: "\(path).view") }
        if let edit { try Schema.check("Edit", edit.json, path: "\(path).edit") }
        if pk { return }
        switch kind {
        case .ref: type = EditType.referenceTable.rawValue
        case .tree: type = EditType.referenceTree.rawValue
        default:
            if let explicitType {
                type = explicitType.rawValue
            } else if choices != nil {
                type = EditType.choice.rawValue
            } else {
                switch kind {
                case .number: type = EditType.number.rawValue
                case .bool: type = EditType.boolean.rawValue
                case .date: type = EditType.date.rawValue
                case .dateTime: type = dateTimeType
                default: type = EditType.input.rawValue
                }
            }
        }
        guard Model.defaults["fields"]?[type] != nil else {
            throw DeclarationError("\(path): edit type \(type) is not supported yet")
        }
        if let (target, label, pid) = reference {
            guard target.pk != nil else { throw DeclarationError("\(path): \(target.name) has no primary key") }
            for key in [label, pid].compactMap({ $0 }) where target.fields[key] == nil {
                throw DeclarationError("\(path): \(target.name) has no field '\(key)'")
            }
        }
    }

    func build() -> JSON {
        var tpl = Model.defaults["fields"]![pk ? "id" : type]!
        tpl["fieldName"] = .string(name)
        tpl["componentValue"] = .null
        if pk { return tpl }
        var edit = tpl["eruptFieldJson"]!["edit"]!
        var view = tpl["eruptFieldJson"]!["views"]![0]!
        edit["title"] = .string(title)
        edit["notNull"] = .bool(notNull)
        edit["show"] = .bool(form)
        edit["search"]!["value"] = .bool(search)
        view["title"] = .string(title)
        view["sortable"] = .bool(sortable)
        if type == EditType.date.rawValue { view["type"] = "DATE" }
        if let (target, label, pid) = reference {
            tpl["fieldReturnName"] = .string(target.name)
            let picker = type == EditType.referenceTable.rawValue ? "referenceTableType" : "referenceTreeType"
            edit[picker]!["id"] = .string(target.pk!)
            edit[picker]!["label"] = .string(label)
            if let pid { edit[picker]!["pid"] = .string(pid) }
            view["column"] = .string(label)
        }
        if let override = self.edit { merge(&edit, override.json) }
        if let override = self.view { merge(&view, override.json) }
        tpl["eruptFieldJson"]!["edit"] = edit
        tpl["eruptFieldJson"]!["views"] = table ? [view] : []
        if let choices {  // CHOICE, or MULTI_CHOICE over a JSON array
            tpl["componentValue"] = .array(choices.map {
                ["value": .string($0.value), "label": .string($0.label), "desc": nil, "color": nil, "disable": false]
            })
        }
        return tpl
    }

    /// A JSON value from the browser as the value the repository stores.
    func coerce(_ value: JSON) throws -> JSON {
        if let (target, _, _) = reference {
            // the browser sends the picked record as {<id>: ..., <label>: ...}
            var v = value
            if case .object(let o) = value { v = o[target.pk!] ?? .null }
            return try target.fields[target.pk!]!.coerce(v)
        }
        if value == .null || value == "" { return .null }
        if pk {
            if let i = value.int, value.double != nil { return .int(i) }
            if case .string(let s) = value, let i = Int64(s.trimmingSpaces) { return .int(i) }
            throw EruptFailure("illegal id '\(value.text)'")
        }
        if isJSON {
            var v = value
            if case .string(let s) = value {
                guard let parsed = try? JSON.parse(s) else { throw EruptFailure("must be a JSON array or object") }
                v = parsed
            }
            switch v {
            case .array(let items):
                if let choices, let bad = items.first(where: { item in !choices.contains { $0.value == item.text } }) {
                    throw EruptFailure("illegal option '\(bad.text)'")
                }
                return v
            case .object: return v
            default: throw EruptFailure("must be a JSON array or object")
            }
        }
        switch type {
        case EditType.boolean.rawValue:
            if case .bool = value { return value }
            return .bool(["true", "1"].contains(value.text.lowercased()))
        case EditType.number.rawValue: return try Values.number(value)
        case dateTimeType: return .string(try Values.dateTime(value))
        case EditType.date.rawValue: return .string(try Values.date(value))
        case EditType.choice.rawValue:
            if let choices, !choices.contains(where: { $0.value == value.text }) {
                throw EruptFailure("illegal option '\(value.text)'")
            }
            return .string(value.text)
        default: return .string(value.text)
        }
    }
}

/// Not an EditType: the template of a DATE whose picker includes the time of day
let dateTimeType = "DATE_TIME"

func isIdentifier(_ s: String) -> Bool {
    guard let first = s.unicodeScalars.first, first == "_" || (first.isASCII && first.properties.isAlphabetic) else {
        return false
    }
    return s.unicodeScalars.allSatisfy { $0 == "_" || ($0.isASCII && ($0.properties.isAlphabetic || ("0"..."9").contains($0))) }
}

/// The acting user of a request, as the server describes it.
public struct User: Sendable {
    public let raw: JSON
    public var uid: JSON { raw["uid"] ?? .null }
    public var account: String? { raw["account"]?.string }
    public var name: String? { raw["name"]?.string }
    public var tenantId: JSON { raw["tenantId"] ?? .null }

    public init(_ raw: JSON) { self.raw = raw }

    /// The user of the request being served, in repositories and operation handlers.
    @TaskLocal public static var current: User?
}

/// What an operation handler receives: `rows` (selected records as the repository returned them; empty for
/// BUTTON mode), `param` (coerced form values, nil without a form), `repo`, `model` and `user`.
public struct OperationContext {
    public let rows: [Record]
    public let param: Record?
    public let repo: Repository
    public let model: Model
    public let user: User?
}

/// The confirm dialog of an operation: `true` (the default text), `false` (none) or a text of its own.
public enum Confirm: ExpressibleByBooleanLiteral, ExpressibleByStringLiteral {
    case ask
    case none
    case text(String)

    public init(booleanLiteral value: Bool) { self = value ? .ask : .none }
    public init(stringLiteral value: String) { self = .text(value) }
}

/// A row operation. The handler may return JavaScript the browser runs, so only return code you wrote, and may
/// throw an `EruptFailure` to show a message. `mode`: `.single` (row button), `.multi` (row and toolbar),
/// `.multiOnly` (toolbar), `.button` (toolbar, no rows). `form`: a model whose fields are asked for before
/// running. `show` hides the operation and refuses to run it; `ifExpr` is browser-side JavaScript over `item`
/// that disables (or hides) the row button; `raw` carries any other `@RowOperation` attribute.
public struct RowAction {
    public typealias Handler = (OperationContext) throws -> String?

    public let code: String
    public let title: String
    let mode: RowOperationMode
    let icon: String?
    let tip: String
    let confirm: Confirm
    let form: Model?
    let ifExpr: String
    let raw: RowOperation?
    let show: ((User?) -> Bool)?
    let handler: Handler

    public init(
        _ code: String, _ title: String, mode: RowOperationMode = .multi, icon: String? = nil, tip: String = "",
        confirm: Confirm = .ask, form: Model? = nil, ifExpr: String = "", raw: RowOperation? = nil,
        show: ((User?) -> Bool)? = nil, handler: @escaping Handler
    ) {
        self.code = code
        self.title = title
        self.mode = mode
        self.icon = icon
        self.tip = tip
        self.confirm = confirm
        self.form = form
        self.ifExpr = ifExpr
        self.raw = raw
        self.show = show
        self.handler = handler
    }

    func isVisible(to user: User?) -> Bool { show?(user) ?? true }

    func build() -> JSON {
        var tpl = Model.defaults["rowOperation"]!
        tpl["code"] = .string(code)
        tpl["title"] = .string(title)
        tpl["mode"] = mode.json
        tpl["tip"] = .string(tip)
        tpl["ifExpr"] = .string(ifExpr)
        tpl["type"] = "ERUPT"
        tpl["eruptClass"] = .string(form?.name ?? "void")
        if let icon { tpl["icon"] = .string(icon) }
        switch confirm {
        case .ask: break
        case .none: tpl["callHint"] = ""  // the browser runs it without asking
        case .text(let text): tpl["callHint"] = .string(text)
        }
        if let raw { merge(&tpl, raw.json) }
        return tpl
    }
}

/// Hooks around a model's data, as erupt's Java `DataProxy`: implement what you need and pass it as
/// `Model(..., dataProxy: [...])`. A record is what the repository stores, a row what the browser reads; change
/// them in place. Throw an `EruptFailure` to refuse with a message.
public protocol DataProxy {
    /// Default values of the search bar, `condition[field] = value`.
    func searchCondition(_ condition: inout [String: JSON])
    /// SQL ANDed to a table page's WHERE, as written: `"status <> 'deleted'"`, or with its values bound,
    /// `SQLFilter("owner = ?", [uid])`. `conditions` are the search bar's. Only SQL repositories apply it.
    func beforeFetch(_ conditions: [Cond]) throws -> SQLFilter?
    /// The rows of a table page, before they are sent.
    func afterFetch(_ rows: inout [Record]) throws
    /// The values a new record's form opens with.
    func addBehavior(_ record: inout Record) throws
    /// A record read by its key, for the edit form or the detail view.
    func editBehavior(_ record: inout Record) throws
    /// A record about to be added or updated.
    func validate(_ record: Record) throws
    func beforeAdd(_ record: inout Record) throws
    func afterAdd(_ record: Record) throws
    func beforeUpdate(_ record: inout Record) throws
    func afterUpdate(_ record: Record) throws
    func beforeDelete(_ record: Record) throws
    func afterDelete(_ record: Record) throws
}

extension DataProxy {
    public func searchCondition(_ condition: inout [String: JSON]) {}
    public func beforeFetch(_ conditions: [Cond]) throws -> SQLFilter? { nil }
    public func afterFetch(_ rows: inout [Record]) throws {}
    public func addBehavior(_ record: inout Record) throws {}
    public func editBehavior(_ record: inout Record) throws {}
    public func validate(_ record: Record) throws {}
    public func beforeAdd(_ record: inout Record) throws {}
    public func afterAdd(_ record: Record) throws {}
    public func beforeUpdate(_ record: inout Record) throws {}
    public func afterUpdate(_ record: Record) throws {}
    public func beforeDelete(_ record: Record) throws {}
    public func afterDelete(_ record: Record) throws {}
}

/// What the node applies when a table is read for one `@Vis` view, given as `Model(..., visQuery:)` under the
/// view's code: `filter` is SQL ANDed to the WHERE as written (SQL repositories only, like `beforeFetch`), `orderBy`
/// the view's order when the request has none (`"title desc, id"`). Java keeps both `@Transient`: they are not in
/// `Vis` and never in the build.
public struct VisQuery {
    let filter: [String]
    let orderBy: String?

    public init(filter: [String] = [], orderBy: String? = nil) {
        self.filter = filter
        self.orderBy = orderBy
    }

    public init(filter: String, orderBy: String? = nil) { self.init(filter: [filter], orderBy: orderBy) }
}

/// One element of a model declaration.
public enum ModelPart {
    case field(Field)
    case action(RowAction)
}

@resultBuilder
public enum ModelBuilder {
    public static func buildExpression(_ field: Field) -> [ModelPart] { [.field(field)] }
    public static func buildExpression(_ action: RowAction) -> [ModelPart] { [.action(action)] }
    public static func buildBlock(_ parts: [ModelPart]...) -> [ModelPart] { parts.flatMap { $0 } }
    public static func buildOptional(_ parts: [ModelPart]?) -> [ModelPart] { parts ?? [] }
    public static func buildEither(first parts: [ModelPart]) -> [ModelPart] { parts }
    public static func buildEither(second parts: [ModelPart]) -> [ModelPart] { parts }
    public static func buildArray(_ parts: [[ModelPart]]) -> [ModelPart] { parts.flatMap { $0 } }
}

/// A declared erupt model, compiled into erupt build JSON.
///
/// Nothing here re-implements annotation semantics. Every field and operation starts from the template the
/// Java proxies emit (erupt-node-defaults.json, generated by erupt-test NodeDefaultsTest); a declaration only
/// overrides values on top of it.
///
/// ```swift
/// let article = try Model("Article", orderBy: "id desc") {
///     Field("id", pk: true)
///     Field("title", "Title", search: true, notNull: true)
///     RowAction("publish", "Publish") { op in ... }
/// }
/// ```
public final class Model {
    static let defaults: JSON = {
        guard let d = try? JSON.parse(Embedded.nodeDefaults) else { fatalError("the embedded erupt-node-defaults.json is malformed") }
        return d
    }()

    /// The erupt name the server addresses as `<node>.<name>`.
    public let name: String
    public let title: String
    /// The primary key field; nil for a model that only serves as an operation form.
    public let pk: String?
    /// The stored fields, in declaration order (virtual ones left out).
    public let fieldNames: [String]
    let power: [String: Bool]
    let raw: Erupt?
    let declared: [Field]
    let fields: [String: Field]
    let actions: [RowAction]
    let proxies: [DataProxy]
    /// the default table order, applied by the node
    let order: [(field: String, descending: Bool)]
    /// view code -> the filters and order the node applies to that view's table queries
    let vis: [String: (filters: [SQLFilter], order: [(field: String, descending: Bool)])]

    /// `name` is what the server addresses; `power` switches features off (`["delete": false]`); `orderBy` is
    /// the default table order (`"views desc, id"`); `erupt` carries other `@Erupt` attributes
    /// (`Erupt(layout: Layout(pageSize: 30))`); `dataProxy` runs around every read and write of the model, in
    /// order; `visQuery` gives a `@Vis` view (by its code, or its title when it has none) a filter and an order.
    /// An unknown attribute or value fails here, not in the browser.
    public init(
        _ name: String, title: String? = nil, power: [String: Bool] = [:], orderBy: String? = nil, erupt: Erupt? = nil,
        dataProxy: [DataProxy] = [], visQuery: [String: VisQuery] = [:], @ModelBuilder _ body: () -> [ModelPart]
    ) throws {
        guard isIdentifier(name) else { throw DeclarationError("erupt name '\(name)' must be an identifier") }
        self.name = name
        self.title = title ?? name
        var granted = Dictionary(uniqueKeysWithValues: (Model.defaults["power"]?.object ?? [:]).map { ($0, $1.bool ?? false) })
        for (right, value) in power {
            guard granted[right] != nil else { throw DeclarationError("erupt \(name): unknown power '\(right)'") }
            granted[right] = value
        }
        self.power = granted
        var erupt = erupt
        // a view without a code is addressed by its title
        let views = erupt?.vis?.map { v in
            var v = v
            if v.code == nil { v.code = v.title ?? "" }
            return v
        }
        erupt?.vis = views
        self.raw = erupt
        self.proxies = dataProxy
        if let erupt { try Schema.check("Erupt", erupt.json, path: "erupt \(name)") }

        var declared: [Field] = [], fields: [String: Field] = [:], names: [String] = [], actions: [RowAction] = []
        var pk: String?
        for part in body() {
            switch part {
            case .field(var f):
                try f.resolve("\(name).\(f.name)")
                guard !declared.contains(where: { $0.name == f.name }) else {
                    throw DeclarationError("\(name): field '\(f.name)' declared twice")
                }
                if f.pk {
                    guard pk == nil else { throw DeclarationError("\(name): at most one primary key") }
                    pk = f.name
                }
                declared.append(f)
                if !f.virtual {
                    fields[f.name] = f
                    names.append(f.name)
                }
            case .action(let a):
                guard !actions.contains(where: { $0.code == a.code }) else {
                    throw DeclarationError("\(name): operation code '\(a.code)' declared twice")
                }
                if let raw = a.raw { try Schema.check("RowOperation", raw.json, path: "operation \(a.code)") }
                actions.append(a)
            }
        }
        self.declared = declared
        self.fields = fields
        self.fieldNames = names
        self.actions = actions
        self.pk = pk
        func parseOrder(_ text: String?) throws -> [(field: String, descending: Bool)] {
            try (text ?? "").split(separator: ",").map { String($0).trimmingSpaces }.filter { !$0.isEmpty }.map { part in
                let words = part.split(separator: " ").map(String.init)
                let dir = words.count > 1 ? words[1].lowercased() : "asc"
                guard fields[words[0]] != nil, words.count <= 2, dir == "asc" || dir == "desc" else {
                    throw DeclarationError("\(name): illegal orderBy '\(part)'")
                }
                return (words[0], dir == "desc")
            }
        }
        self.order = try parseOrder(orderBy)
        let codes = Set(erupt?.vis?.compactMap(\.code) ?? [])
        self.vis = try visQuery.mapValues { q in (q.filter.map { SQLFilter($0) }, try parseOrder(q.orderBy)) }
        if let code = visQuery.keys.sorted().first(where: { !codes.contains($0) }) {
            throw DeclarationError("\(name): visQuery '\(code)' is not a declared vis")
        }
    }

    func field(_ name: String) -> Field? { fields[name] }

    func action(_ code: String) -> RowAction? { actions.first { $0.code == code } }

    /// Runs one DataProxy hook on every proxy, in declaration order.
    func hook(_ run: (DataProxy) throws -> Void) rethrows { for p in proxies { try run(p) } }

    /// The SQL every proxy's `beforeFetch` adds.
    func filters(_ conditions: [Cond]) throws -> [SQLFilter] { try proxies.compactMap { try $0.beforeFetch(conditions) } }

    /// Values as the fields hold them, where they can be read so: lets seeds be written loosely
    /// (`"2026-10-02 10:00"`, `"9.9"`); anything else is kept as given.
    func normalized(_ record: Record) -> Record {
        var out = record
        for (key, value) in record {
            if let f = fields[key], !f.pk, let v = try? f.coerce(value) { out[key] = v }
        }
        return out
    }

    func buildErupt(_ actions: [RowAction] = []) -> JSON {
        var erupt = Model.defaults["erupt"]!
        erupt["primaryKeyCol"] = .string(pk ?? "id")
        erupt["rowOperation"] = .array(actions.map { $0.build() })
        if let raw { merge(&erupt, raw.json) }
        var condition: [String: JSON] = [:]
        hook { $0.searchCondition(&condition) }
        return [
            "eruptName": .string(name), "eruptJson": erupt, "eruptFieldModels": .array(declared.map { $0.build() }),
            "searchCondition": .object(condition), "extraRow": false, "tags": [:],
        ]
    }

    func buildModel(power: [String: Bool], user: User?) -> JSON {
        let visible = actions.filter { $0.isVisible(to: user) }
        var forms: [String: JSON] = [:]
        for a in visible { if let form = a.form { forms[a.code] = form.buildErupt() } }
        return [
            "eruptModel": buildErupt(visible), "power": .object(power.mapValues(JSON.bool)), "tabErupts": nil,
            "combineErupts": nil, "operationErupts": forms.isEmpty ? nil : .object(forms),
        ]
    }
}
