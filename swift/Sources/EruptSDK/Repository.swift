import Foundation

/// One search condition. `op`: EQ NEQ GT GTE LT LTE LIKE NOT_LIKE RANGE IN NOT_IN NULL NOT_NULL; RANGE, IN and
/// NOT_IN carry an array value.
public struct Cond: Sendable, Equatable {
    public let field: String
    public let op: String
    public let value: JSON

    public init(_ field: String, _ op: String, _ value: JSON = nil) {
        self.field = field
        self.op = op
        self.value = value
    }
}

/// SQL a `@Vis` view or a `DataProxy.beforeFetch` adds to a table page's WHERE, as written; with `params`, each
/// `?` in it is one of them, bound like every other value. A string literal is SQL without params.
public struct SQLFilter: Sendable, Equatable, ExpressibleByStringLiteral {
    public let sql: String
    public let params: [JSON]

    public init(_ sql: String, _ params: [JSON] = []) {
        self.sql = sql
        self.params = params
    }

    public init(stringLiteral value: String) { self.init(value) }
}

/// What a repository is asked for. `filters` come from a `@Vis` view and `DataProxy.beforeFetch`: a repository ANDs every one to
/// its conditions, or throws when it cannot apply them; it never ignores them.
public struct Query: Sendable {
    public var conditions: [Cond]
    public var sort: [(field: String, descending: Bool)]
    public var filters: [SQLFilter]
    public var offset: Int
    public var limit: Int

    public init(
        conditions: [Cond] = [], sort: [(field: String, descending: Bool)] = [], filters: [SQLFilter] = [], offset: Int = 0,
        limit: Int = 10
    ) {
        self.conditions = conditions
        self.sort = sort
        self.filters = filters
        self.offset = offset
        self.limit = limit
    }
}

/// Storage adapter: implement these to put a model on any storage. A repository only sees field names the node
/// has already checked against the model, so it may use them as identifiers; values always travel as parameters.
/// Called from many threads at once. `page` applies the query's `filters` or throws; a repository that cannot read
/// SQL refuses them, as `MemoryRepository` does.
public protocol Repository: AnyObject {
    /// Called once when the model is registered.
    func bind(_ model: Model) throws
    func page(_ query: Query) throws -> (total: Int, records: [Record])
    func get(_ pk: JSON) throws -> Record?
    func add(_ record: Record) throws
    /// Changes the fields `record` holds.
    func update(_ pk: JSON, _ record: Record) throws
    func delete(_ pks: [JSON]) throws
}

/// Records in memory, for tests and demos. It refuses a query with `filters`: it cannot read their SQL.
public final class MemoryRepository: Repository {
    private let lock = NSLock()
    private var rows: [Int64: Record] = [:]
    private var ids: [Int64] = []  // insertion order, the tie breaker of every sort
    private var seq: Int64 = 0
    private var pending: [Record]
    private var model: Model!

    /// `records` are added once the model is bound.
    public init(_ records: [Record] = []) { pending = records }

    public func bind(_ model: Model) throws {
        self.model = model
        for record in pending { try add(record) }
        pending = []
    }

    public func page(_ query: Query) throws -> (total: Int, records: [Record]) {
        guard query.filters.isEmpty else { throw DeclarationError("MemoryRepository cannot apply SQL filters (a view filter, beforeFetch)") }
        let all: [Record] = locked { ids.compactMap { rows[$0] } }
        let matching = all.filter { r in query.conditions.allSatisfy { Self.matches(r[$0.field] ?? .null, $0) } }
        let sorted = matching.enumerated().sorted { a, b in
            for (field, descending) in query.sort {
                let c = Self.compare(a.element[field] ?? .null, b.element[field] ?? .null)
                if c != 0 { return descending ? c > 0 : c < 0 }
            }
            return a.offset < b.offset
        }.map(\.element)
        return (sorted.count, Array(sorted.dropFirst(query.offset).prefix(query.limit)))
    }

    public func get(_ pk: JSON) throws -> Record? {
        guard let id = pk.int else { return nil }
        return locked { rows[id] }
    }

    public func add(_ record: Record) throws {
        let normalized = model.normalized(record)
        locked {
            seq += 1
            var row = normalized
            row[model.pk!] = .int(seq)
            rows[seq] = row
            ids.append(seq)
        }
    }

    public func update(_ pk: JSON, _ record: Record) throws {
        guard let id = pk.int else { return }
        let normalized = model.normalized(record)
        locked {
            guard var row = rows[id] else { return }
            for (k, v) in normalized where k != model.pk { row[k] = v }
            rows[id] = row
        }
    }

    public func delete(_ pks: [JSON]) throws {
        let gone = Set(pks.compactMap(\.int))
        locked {
            for id in gone { rows[id] = nil }
            ids.removeAll { gone.contains($0) }
        }
    }

    private func locked<T>(_ body: () -> T) -> T {
        lock.lock()
        defer { lock.unlock() }
        return body()
    }

    /// null sorts last; false before true; values of different kinds are equal
    static func compare(_ a: JSON, _ b: JSON) -> Int {
        if a == .null || b == .null { return (a == .null ? 1 : 0) - (b == .null ? 1 : 0) }
        switch (a, b) {
        case (.bool(let x), .bool(let y)): return x == y ? 0 : (x ? 1 : -1)
        case (.string(let x), .string(let y)): return x == y ? 0 : (x < y ? -1 : 1)
        default:
            guard let x = a.number, let y = b.number else { return 0 }
            return x == y ? 0 : (x < y ? -1 : 1)
        }
    }

    static func matches(_ value: JSON, _ cond: Cond) -> Bool {
        switch cond.op {
        case "NULL": return value == .null
        case "NOT_NULL": return value != .null
        default: break
        }
        if value == .null { return false }
        // a JSON value is matched as its text
        var value = value
        if case .array = value { value = .string(value.serialized()) }
        if case .object = value { value = .string(value.serialized()) }
        let expect = cond.value
        switch cond.op {
        case "EQ": return value == expect
        case "NEQ": return value != expect
        case "LIKE": return value.text.lowercased().contains(expect.text.lowercased())
        case "NOT_LIKE": return !value.text.lowercased().contains(expect.text.lowercased())
        case "IN": return expect.array?.contains(value) ?? false
        case "NOT_IN": return !(expect.array?.contains(value) ?? false)
        case "RANGE":
            guard let r = expect.array, r.count == 2 else { return false }
            return compare(r[0], value) <= 0 && compare(value, r[1]) <= 0
        case "GT": return compare(value, expect) > 0
        case "GTE": return compare(value, expect) >= 0
        case "LT": return compare(value, expect) < 0
        case "LTE": return compare(value, expect) <= 0
        default: return false
        }
    }
}
