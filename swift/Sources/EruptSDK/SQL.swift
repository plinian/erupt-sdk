import Foundation

/// The SQL a database reads: identifier quotes, placeholders and LIKE.
public enum SQLDialect: Sendable {
    case sqlite, postgres, mysql
}

/// What SQLRepository needs from a database: run one statement with bound values and return the rows of a
/// SELECT keyed by column name. The SDK depends on no driver; EruptSQLite ships one for SQLite, and any other
/// library is wrapped in a few lines:
///
/// ```swift
/// let executor = SQLClosureExecutor(.postgres) { sql, params in
///     try connection.query(sql, params.map(toPostgresData)).map(toRecord)
/// }
/// ```
public protocol SQLExecutor: AnyObject {
    var dialect: SQLDialect { get }
    func execute(_ sql: String, _ params: [JSON]) throws -> [[String: JSON]]
}

/// A SQLExecutor from a closure.
public final class SQLClosureExecutor: SQLExecutor {
    public let dialect: SQLDialect
    private let run: (String, [JSON]) throws -> [[String: JSON]]

    public init(_ dialect: SQLDialect, _ run: @escaping (String, [JSON]) throws -> [[String: JSON]]) {
        self.dialect = dialect
        self.run = run
    }

    public func execute(_ sql: String, _ params: [JSON]) throws -> [[String: JSON]] { try run(sql, params) }
}

/// A table on PostgreSQL, MySQL or SQLite through a SQLExecutor. Column names are the model's field names
/// (quoted, so case sensitive on PostgreSQL); every value is a bound parameter; LIKE escapes with `ESCAPE '!'`,
/// which every database reads the same way. Without a sort, rows come back by primary key ascending.
/// `autoCreate` creates a missing SQLite table: create production tables yourself.
public final class SQLRepository: Repository {
    private static let ops = ["EQ": "=", "NEQ": "<>", "GT": ">", "GTE": ">=", "LT": "<", "LTE": "<="]
    private static let sqliteTypes = [
        EditType.number.rawValue: "NUMERIC", EditType.boolean.rawValue: "INTEGER", EditType.date.rawValue: "DATE",
        dateTimeType: "TIMESTAMP", EditType.referenceTable.rawValue: "INTEGER", EditType.referenceTree.rawValue: "INTEGER",
    ]

    private let executor: SQLExecutor
    private let table: String
    private let autoCreate: Bool
    private var dialect: SQLDialect { executor.dialect }
    private var model: Model!
    private var columns: [String: String] = [:]  // lower-cased column -> field

    public init(_ executor: SQLExecutor, table: String, autoCreate: Bool = false) throws {
        guard isIdentifier(table) else { throw DeclarationError("illegal table name '\(table)'") }
        guard !autoCreate || executor.dialect == .sqlite else { throw DeclarationError("autoCreate creates SQLite tables only") }
        self.executor = executor
        self.table = table
        self.autoCreate = autoCreate
    }

    public func bind(_ model: Model) throws {
        self.model = model
        columns = Dictionary(uniqueKeysWithValues: model.fieldNames.map { ($0.lowercased(), $0) })
        guard autoCreate else { return }
        let cols = model.fieldNames.map { name -> String in
            let f = model.field(name)!
            return f.pk ? "\(q(name)) INTEGER PRIMARY KEY AUTOINCREMENT" : "\(q(name)) \(Self.sqliteTypes[f.type] ?? "TEXT")"
        }
        _ = try executor.execute("CREATE TABLE IF NOT EXISTS \(q(table)) (\(cols.joined(separator: ", ")))", [])
    }

    public func page(_ query: Query) throws -> (total: Int, records: [Record]) {
        var p = Params(dialect)
        let count = try executor.execute("SELECT COUNT(*) AS n FROM \(q(table))\(try `where`(query, &p))", p.values)
        let total = count.first.flatMap { row in row.first { $0.key.lowercased() == "n" }?.value ?? row.values.first }
        p = Params(dialect)
        var sql = "SELECT * FROM \(q(table))\(try `where`(query, &p))"
        let sort = query.sort.isEmpty ? [(field: model.pk!, descending: false)] : query.sort
        sql += " ORDER BY " + sort.map { "\(q($0.field)) \($0.descending ? "DESC" : "ASC")" }.joined(separator: ", ")
        sql += " LIMIT \(p.add(.int(Int64(query.limit)))) OFFSET \(p.add(.int(Int64(query.offset))))"
        let rows = try executor.execute(sql, p.values)
        return (Int(try Values.number(total ?? 0).int ?? 0), try rows.map(record))
    }

    public func get(_ pk: JSON) throws -> Record? {
        var p = Params(dialect)
        let sql = "SELECT * FROM \(q(table)) WHERE \(q(model.pk!)) = \(p.add(pk))"
        return try executor.execute(sql, p.values).first.map(record)
    }

    public func add(_ record: Record) throws {
        let values = store(record)
        var p = Params(dialect)
        let marks = values.map { p.add($0.value) }
        let sql = "INSERT INTO \(q(table)) (\(values.map { q($0.key) }.joined(separator: ", "))) VALUES (\(marks.joined(separator: ", ")))"
        _ = try executor.execute(sql, p.values)
    }

    public func update(_ pk: JSON, _ record: Record) throws {
        let values = store(record)
        if values.isEmpty { return }
        var p = Params(dialect)
        let sets = values.map { "\(q($0.key)) = \(p.add($0.value))" }.joined(separator: ", ")
        _ = try executor.execute("UPDATE \(q(table)) SET \(sets) WHERE \(q(model.pk!)) = \(p.add(pk))", p.values)
    }

    public func delete(_ pks: [JSON]) throws {
        if pks.isEmpty { return }
        var p = Params(dialect)
        let marks = pks.map { p.add($0) }.joined(separator: ", ")
        _ = try executor.execute("DELETE FROM \(q(table)) WHERE \(q(model.pk!)) IN (\(marks))", p.values)
    }

    /// A quoted identifier; the closing quote is doubled.
    func q(_ identifier: String) -> String {
        let quote = dialect == .mysql ? "`" : "\""
        return quote + identifier.replacingOccurrences(of: quote, with: quote + quote) + quote
    }

    /// Collects bound values and writes the dialect's placeholder for each.
    struct Params {
        let dialect: SQLDialect
        var values: [JSON] = []

        init(_ dialect: SQLDialect) { self.dialect = dialect }

        mutating func add(_ value: JSON) -> String {
            var v = value
            if case .bool(let b) = value, dialect != .postgres { v = .int(b ? 1 : 0) }
            values.append(v)
            return dialect == .postgres ? "$\(values.count)" : "?"
        }
    }

    /// A value as the column holds it: JSON as its text, a DATE_TIME with a space (every database reads it)
    private func bindable(_ field: Field?, _ value: JSON) -> JSON {
        guard let field, value != .null else { return value }
        if field.isJSON { return .string(value.serialized()) }
        if field.type == dateTimeType, case .string(let s) = value { return .string(s.replacingOccurrences(of: "T", with: " ")) }
        return value
    }

    private func store(_ record: Record) -> [(key: String, value: JSON)] {
        record.keys.sorted().filter { $0 != model.pk && model.field($0) != nil }.map { ($0, bindable(model.field($0), record[$0]!)) }
    }

    private func `where`(_ query: Query, _ p: inout Params) throws -> String {
        // the developer's own SQL, as written; with params, each '?' is one of them, bound like every other value
        let filters = try query.filters.map { f -> String in
            let pieces = f.params.isEmpty ? [f.sql] : f.sql.components(separatedBy: "?")
            guard pieces.count - 1 == f.params.count else {
                throw DeclarationError("filter: \(pieces.count - 1) '?' for \(f.params.count) params in \(f.sql)")
            }
            return "(" + pieces[0] + zip(f.params, pieces.dropFirst()).map { p.add($0) + $1 }.joined() + ")"
        }
        let clauses = try filters + query.conditions.map { c -> String in
            let col = q(c.field)
            let f = model.field(c.field)
            let values = c.value.array ?? [c.value]
            if let op = Self.ops[c.op] { return "\(col) \(op) \(p.add(bindable(f, c.value)))" }
            switch c.op {
            case "LIKE", "NOT_LIKE":
                // '!' rather than a backslash: MySQL reads a backslash inside a string literal as an escape itself;
                // ILIKE because PostgreSQL's LIKE is case sensitive, the others' (and the memory repository's) is not
                var pattern = "%"
                for ch in c.value.text {
                    if ch == "!" || ch == "%" || ch == "_" { pattern.append("!") }
                    pattern.append(ch)
                }
                pattern += "%"
                let like = dialect == .postgres ? "ILIKE" : "LIKE"
                return "\(col) \(c.op == "NOT_LIKE" ? "NOT " : "")\(like) \(p.add(.string(pattern))) ESCAPE '!'"
            case "RANGE":
                guard values.count == 2 else { throw EruptFailure("range needs two values") }
                return "\(col) BETWEEN \(p.add(bindable(f, values[0]))) AND \(p.add(bindable(f, values[1])))"
            case "IN", "NOT_IN":
                if values.isEmpty { return c.op == "IN" ? "1=0" : "1=1" }
                let marks = values.map { p.add(bindable(f, $0)) }.joined(separator: ", ")
                return "\(col) \(c.op == "NOT_IN" ? "NOT " : "")IN (\(marks))"
            case "NULL": return "\(col) IS NULL"
            case "NOT_NULL": return "\(col) IS NOT NULL"
            default: throw EruptFailure("illegal operator '\(c.op)'")
            }
        }
        return clauses.isEmpty ? "" : " WHERE " + clauses.joined(separator: " AND ")
    }

    /// A driver row as a record: columns matched to fields case-insensitively, values normalized by field type.
    private func record(_ row: [String: JSON]) throws -> Record {
        var byField: [String: JSON] = [:]
        for (k, v) in row { byField[columns[k.lowercased()] ?? k] = v }
        var out: Record = [:]
        for name in model.fieldNames {
            let value = byField[name] ?? .null
            out[name] = value == .null ? .null : try normalize(model.field(name)!, value)
        }
        return out
    }

    private func normalize(_ field: Field, _ value: JSON) throws -> JSON {
        if field.isJSON {
            if case .string(let s) = value { return try JSON.parse(s) }
            return value
        }
        if field.pk || field.isReference || field.type == EditType.number.rawValue { return try Values.number(value) }
        switch field.type {
        case EditType.boolean.rawValue: return .bool([.bool(true), .int(1), "1", "t", "true"].contains(value))
        case EditType.date.rawValue: return .string(try Values.date(value))
        case dateTimeType: return .string(try Values.dateTime(value))
        default: return value
        }
    }
}
