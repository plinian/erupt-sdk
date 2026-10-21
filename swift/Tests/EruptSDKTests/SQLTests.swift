import Foundation
import Testing

@testable import EruptSDK
@testable import EruptSQLite

func sqlModel() throws -> Model {
    try Model("Item") {
        Field("id", pk: true)
        Field("name", "Name", search: true)
        Field("price", "Price", .number, sortable: true)
        Field("active", "Active", .bool)
        Field("day", "Day", .date)
        Field("at", "At", .dateTime)
        Field("attrs", "Attrs", .json)
        Field("note", "Note", edit: Edit(type: .divide), virtual: true)
    }
}

@Suite struct SQLiteRepositoryTests {
    func repository() throws -> SQLRepository {
        let repo = try SQLRepository(try SQLiteExecutor(path: ":memory:"), table: "item", autoCreate: true)
        try repo.bind(try sqlModel())
        return repo
    }

    @Test func roundTrip() throws {
        let repo = try repository()
        try repo.add(["name": "100%_off!", "price": 9.5, "active": true, "day": "2026-01-05", "at": "2026-01-05T10:30:00.000", "attrs": ["k": "v"]])
        try repo.add(["name": "plain", "price": 2, "active": false])
        try repo.add(["name": "Nothing"])
        let (total, rows) = try repo.page(Query(limit: 10))
        #expect(total == 3)
        // without a sort, by primary key ascending
        #expect(rows.map { $0["name"]!.text } == ["100%_off!", "plain", "Nothing"])
        #expect(rows[0] == ["id": 1, "name": "100%_off!", "price": 9.5, "active": true, "day": "2026-01-05",
                            "at": "2026-01-05T10:30:00.000", "attrs": ["k": "v"]])
        #expect(rows[1]["active"] == false)
        #expect(rows[2]["price"] == .null)
    }

    @Test func conditions() throws {
        let repo = try repository()
        for (i, name) in ["100%_off!", "100 off", "a_b", "AXB"].enumerated() {
            try repo.add(["name": .string(name), "price": .int(Int64(i)), "at": .string("2026-01-0\(i + 1)T08:00:00.000")])
        }
        func names(_ conditions: [Cond], sort: [(String, Bool)] = []) throws -> [String] {
            try repo.page(Query(conditions: conditions, sort: sort.map { ($0.0, $0.1) }, limit: 10)).records.map { $0["name"]!.text }
        }
        #expect(try names([Cond("name", "LIKE", "%_")]) == ["100%_off!"])
        #expect(try names([Cond("name", "LIKE", "a_b")]) == ["a_b"])
        #expect(try names([Cond("name", "LIKE", "axb")]) == ["AXB"])
        #expect(try names([Cond("name", "NOT_LIKE", "100")]) == ["a_b", "AXB"])
        #expect(try names([Cond("price", "IN", [])]).isEmpty)
        #expect(try names([Cond("price", "NOT_IN", [])]).count == 4)
        #expect(try names([Cond("price", "RANGE", [1, 2])]) == ["100 off", "a_b"])
        #expect(try names([Cond("at", "GTE", "2026-01-03T08:00:00.000")]) == ["a_b", "AXB"])
        #expect(try names([Cond("day", "NULL")]).count == 4)
        #expect(try names([], sort: [("price", true)]).first == "AXB")
        let one = try repo.page(Query(sort: [("price", false)], offset: 1, limit: 1))
        #expect(one.total == 4 && one.records.map { $0["name"]!.text } == ["100 off"])
    }

    @Test func updateAndDelete() throws {
        let repo = try repository()
        try repo.add(["name": "a"])
        try repo.add(["name": "b"])
        try repo.update(1, ["name": "A", "price": 3])
        #expect(try repo.get(1)?["name"] == "A")
        #expect(try repo.get(1)?["price"] == 3)
        try repo.delete([1, 2])
        #expect(try repo.page(Query()).total == 0)
        #expect(try repo.get(1) == nil)
    }

    @Test func dialects() throws {
        var statements: [(String, [JSON])] = []
        for dialect in [SQLDialect.postgres, .mysql] {
            let executor = SQLClosureExecutor(dialect) { sql, params in
                statements.append((sql, params))
                return [["N": 0]]
            }
            let repo = try SQLRepository(executor, table: "item")
            try repo.bind(try sqlModel())
            _ = try repo.page(Query(conditions: [Cond("name", "LIKE", "x"), Cond("active", "EQ", true)], limit: 5))
        }
        #expect(statements[1].0 == #"SELECT * FROM "item" WHERE "name" ILIKE $1 ESCAPE '!' AND "active" = $2 ORDER BY "id" ASC LIMIT $3 OFFSET $4"#)
        #expect(statements[1].1 == ["%x%", true, 5, 0])
        #expect(statements[3].0 == "SELECT * FROM `item` WHERE `name` LIKE ? ESCAPE '!' AND `active` = ? ORDER BY `id` ASC LIMIT ? OFFSET ?")
        #expect(statements[3].1 == ["%x%", 1, 5, 0])
        #expect(throws: DeclarationError.self) { try SQLRepository(SQLClosureExecutor(.mysql) { _, _ in [] }, table: "x", autoCreate: true) }
        #expect(throws: DeclarationError.self) { try SQLRepository(SQLClosureExecutor(.sqlite) { _, _ in [] }, table: "x;drop") }
    }

    @Test func filters() throws {
        var statements: [(String, [JSON])] = []
        let repo = try SQLRepository(SQLClosureExecutor(.postgres) { sql, params in
            statements.append((sql, params))
            return [["n": 0]]
        }, table: "item")
        try repo.bind(try sqlModel())
        _ = try repo.page(Query(conditions: [Cond("name", "EQ", "x")], filters: [SQLFilter("price > ? OR price < ?", [1, 9]), "active"]))
        #expect(statements[0].0 == #"SELECT COUNT(*) AS n FROM "item" WHERE (price > $1 OR price < $2) AND (active) AND "name" = $3"#)
        #expect(statements[1].1 == [1, 9, "x", 10, 0])
        _ = try repo.page(Query(filters: ["name = 'a?'"]))  // without params, '?' is plain SQL
        #expect(statements[2].0 == #"SELECT COUNT(*) AS n FROM "item" WHERE (name = 'a?')"#)
        #expect(throws: DeclarationError.self) { try repo.page(Query(filters: [SQLFilter("price > ?", [1, 2])])) }
    }
}

@Suite struct MemoryRepositoryTests {
    @Test func sortsNullLastAndKeepsInsertionOrder() throws {
        let repo = MemoryRepository([["name": "b", "price": 2], ["name": "a"], ["name": "c", "price": 1], ["name": "d", "price": 2]])
        try repo.bind(try sqlModel())
        let sorted = try repo.page(Query(sort: [("price", false)])).records.map { $0["name"]!.text }
        #expect(sorted == ["c", "b", "d", "a"])
        #expect(try repo.page(Query(conditions: [Cond("price", "GT", 1)])).total == 2)
        #expect(try repo.page(Query(conditions: [Cond("name", "LIKE", "B")])).total == 1)
    }
}
