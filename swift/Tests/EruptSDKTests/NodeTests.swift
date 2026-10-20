import Foundation
import Testing

@testable import EruptSDK
import EruptSQLite

let token = "node-secret"

func articleModel() throws -> (Model, Model) {
    let category = try Model("Category") {
        Field("id", pk: true)
        Field("name", "Name", search: true)
        Field("parent", "Parent", .number)
    }
    let noteForm = try Model("NoteForm") { Field("note", "Note") }
    let article = try Model("Article", orderBy: "id desc") {
        Field("id", pk: true)
        Field("title", "Title", search: true, notNull: true, sortable: true)
        Field("status", "Status", search: true, choices: ["draft": "Draft", "published": "Published"])
        Field("views", "Views", .number, sortable: true)
        Field("publish_date", "Publish Date", .date, search: true)
        Field("category", "Category", .ref(category), search: true)
        Field("tags", "Tags", .json, search: true, choices: ["a": "A", "b": "B"], edit: Edit(type: .multiChoice))
        Field("divider", "Divider", edit: Edit(type: .divide), virtual: true)
        RowAction("hello", "Hello", mode: .button) { _ in "alert('hi')" }
        RowAction("note", "Note", mode: .button, form: noteForm) { op in op.param!["note"]!.text }
        RowAction("secret", "Secret", mode: .button, show: { _ in false }) { _ in nil }
    }
    return (category, article)
}

final class MemoProxy: DataProxy {
    var calls: [String] = []

    func searchCondition(_ condition: inout [String: JSON]) { condition["text"] = "hi" }
    func afterFetch(_ rows: inout [Record]) { for i in rows.indices { rows[i]["text"] = .string(rows[i]["text"]!.text.uppercased()) } }
    func addBehavior(_ record: inout Record) { record["text"] = "new" }
    func editBehavior(_ record: inout Record) { record["text"] = .string(record["text"]!.text + "?") }
    func validate(_ record: Record) throws { if record["text"] == "forbidden" { throw EruptFailure("forbidden text") } }

    // the write hooks only record that they ran, with the text they saw
    func beforeAdd(_ record: inout Record) { calls.append("beforeAdd \(record["text"]!.text)") }
    func afterAdd(_ record: Record) { calls.append("afterAdd \(record["text"]!.text)") }
    func beforeUpdate(_ record: inout Record) { calls.append("beforeUpdate \(record["text"]!.text)") }
    func afterUpdate(_ record: Record) { calls.append("afterUpdate \(record["text"]!.text)") }
    func beforeDelete(_ record: Record) { calls.append("beforeDelete \(record["text"]!.text)") }
    func afterDelete(_ record: Record) { calls.append("afterDelete \(record["text"]!.text)") }
}

struct TaskProxy: DataProxy {
    func beforeFetch(_ conditions: [Cond]) -> SQLFilter? { SQLFilter("owner = ?", [.string(User.current?.account ?? "")]) }
}

struct OpenProxy: DataProxy {
    func beforeFetch(_ conditions: [Cond]) -> SQLFilter? { "done = 0" }
}

func taskModel() throws -> Model {
    try Model(
        "Task",
        erupt: Erupt(vis: [Vis(code: "q", title: "Question", type: .table), Vis(title: "Reversed", type: .table)]),
        dataProxy: [TaskProxy(), OpenProxy()],
        visQuery: ["q": VisQuery(filter: "title = 'a?'"), "Reversed": VisQuery(filter: ["1 = 1", "2 = 2"], orderBy: "title desc")]
    ) {
        Field("id", pk: true)
        Field("title", "Title", search: true)
        Field("owner", "Owner")
        Field("done", "Done", .bool)
    }
}

func authorAndBook() throws -> (Model, Model) {
    let category = try articleModel().0
    let author = try Model(
        "Author", erupt: Erupt(drills: [Drill(link: Link(linkErupt: "Book"), title: "Books")]),
        drillJoin: ["Books": DrillJoin(joinColumn: "author.id")]
    ) {
        Field("id", pk: true)
        Field("name", "Name")
    }
    let book = try Model("Book") {
        Field("id", pk: true)
        Field("title", "Title")
        Field("author", "Author", .ref(author))
        Field("colour", "Colour", type: .color)
        Field("stars", "Stars", type: .rate)
        Field("secret", "Secret", type: .hidden)
        Field("readers", "Readers", .ref(category), type: .transfer)
        Field("shelf", "Shelf", .ref(category), edit: Edit(referenceTableType: ReferenceTableType(dependField: "author")), dependColumn: "parent")
    }
    return (author, book)
}

/// A node whose server is unreachable: every call is signed with power enforced, so it never asks it.
func node() throws -> Node {
    let (category, article) = try articleModel()
    let node = try Node(name: "test", accessToken: token, servers: ["http://127.0.0.1:9"], log: { _, _ in })
    try node.register(category, MemoryRepository([["name": "Tech"], ["name": "Python", "parent": 1]]))
    try node.register(article, MemoryRepository())
    return node
}

func call(_ node: Node, _ method: String, _ target: String, erupt: String = "Article", body: JSON? = nil,
          signed: Bool = true, account: String = "admin", headers extra: [String: String] = [:]) -> (Int, JSON?) {
    let raw = body.map { Array($0.serialized().utf8) } ?? []
    let user = Data("{\"account\":\"\(account)\"}".utf8).base64EncodedString()
    var headers = ["erupt": erupt, "user": user, "token": "t"]
    if signed {
        let now = Int64(Date().timeIntervalSince1970)
        headers["Erupt-Timestamp"] = String(now)
        headers["Erupt-Enforced"] = "power"
        headers["Erupt-Signature"] = Signature.sign(
            accessToken: token, method: method, pathAndQuery: target, timestamp: now, enforced: "power", user: user, body: raw)
    } else {
        headers["Access-Token"] = token
    }
    let response = node.handle(NodeRequest(method: method, target: target, headers: headers.merging(extra) { $1 }, body: raw))
    return (response.status, response.body.isEmpty ? nil : try? JSON.parse(response.body))
}

@Suite struct NodeTests {
    @Test func health() throws {
        let response = try node().handle(NodeRequest(method: "GET", target: "/node-health", headers: [:]))
        #expect(response.status == 200)
        #expect(String(decoding: response.body, as: UTF8.self) == "test")
    }

    @Test func guards() throws {
        let n = try node()
        #expect(n.handle(NodeRequest(method: "GET", target: "/erupt-api/build/Article", headers: ["erupt": "Article"])).status == 403)
        let wrong = ["erupt": "Article", "Access-Token": "nope"]
        #expect(n.handle(NodeRequest(method: "GET", target: "/erupt-api/build/Article", headers: wrong)).status == 403)
        #expect(call(n, "GET", "/erupt-api/build/Article", erupt: "Category").0 == 404)
        #expect(call(n, "GET", "/erupt-api/nothing").0 == 404)
    }

    @Test func buildMatchesTheSchema() throws {
        let (status, build) = call(try node(), "GET", "/erupt-api/build/Article")
        #expect(status == 200)
        let model = try #require(build?["eruptModel"])
        try Schema.check("Erupt", model["eruptJson"]!, partial: false)
        let fields = model["eruptFieldModels"]!.array!
        #expect(fields.map { $0["fieldName"]!.text } == ["id", "title", "status", "views", "publish_date", "category", "tags", "divider"])
        for f in fields { try Schema.check("EruptField", f["eruptFieldJson"]!, partial: false) }
        #expect(fields[6]["eruptFieldJson"]!["edit"]!["type"] == "MULTI_CHOICE")
        #expect(build?["power"]?["cellEdit"] == true) // the server edits the cell
    }

    @Test func crudAndSearch() throws {
        let n = try node()
        let add: (JSON) -> JSON? = { call(n, "POST", "/erupt-api/data/modify/Article", body: $0).1 }
        #expect(add(["title": "A", "status": "draft", "views": "3", "publish_date": "2026-01-05", "category": ["id": "2"], "tags": ["a"]])?["success"] == true)
        #expect(add(["title": "B", "status": "published", "views": 10, "tags": ["a", "b"]])?["success"] == true)
        #expect(add(["status": "draft"])?["message"] == "Title cannot be empty")
        #expect(add(["title": "C", "status": "gone"])?["success"] == false)
        #expect(add(["title": "C", "tags": ["z"]])?["success"] == false)

        let table: (JSON) -> JSON = { call(n, "POST", "/erupt-api/data/table/Article", body: $0).1! }
        let all = table([:])
        #expect(all["list"]!.array!.map { $0["title"]!.text } == ["B", "A"])
        #expect(all["list"]![1]!["category"] == 2)
        #expect(all["list"]![1]!["views"] == 3)
        #expect(table(["condition": [["key": "tags", "expression": "IN", "value": ["b"]]]])["total"] == 1)
        #expect(table(["condition": [["key": "title", "expression": "LIKE", "value": "a"]]])["total"] == 1)
        #expect(table(["condition": [["key": "category", "expression": "EQ", "value": ["id": 2]]]])["total"] == 1)
        #expect(table(["sort": [["field": "views", "direction": "ASC"]]])["list"]![0]!["title"] == "A")
        #expect(table(["sort": [["field": "status", "direction": "ASC"]]])["success"] == false)

        let pk = all["list"]![0]!["id"]!
        #expect(call(n, "GET", "/erupt-api/data/Article/\(pk.text)").1?["title"] == "B")
        #expect(call(n, "POST", "/erupt-api/data/modify/Article/delete", body: [pk]).1?["success"] == true)
        #expect(table([:])["total"] == 1)
        let op = "/erupt-api/invoke/Article/operation/", form = "/erupt-api/invoke/Article/operation-form/"
        #expect(call(n, "POST", op + "hello", body: ["ids": [], "param": [:]]).1?["data"] == "alert('hi')")
        #expect(call(n, "POST", op + "note", body: ["param": ["note": "go"]]).1?["data"] == "go")
        #expect(call(n, "POST", op + "secret", body: [:]).0 == 403)
        #expect(call(n, "POST", op + "missing", body: [:]).0 == 404)
        #expect(call(n, "POST", form + "note", body: [:]).1?["data"] == ["note": nil])
        #expect(call(n, "POST", form + "hello", body: [:]).1?["data"] == .null, "an operation without a form")
        #expect(call(n, "POST", form + "secret", body: [:]).0 == 403)
        // the old routes are gone; the picker is the server's, it reads the referenced model's own table
        #expect(call(n, "POST", "/erupt-api/data/Article/operator/hello", body: [:]).0 == 404)
        #expect(call(n, "POST", "/erupt-api/data/Article/operator/note/form-value", body: [:]).0 == 404)
        #expect(call(n, "POST", "/erupt-api/data/Article/reference-table/category", body: [:]).0 == 404)
    }

    @Test func dataProxy() throws {
        let proxy = MemoProxy()
        let memo = try Model("Memo", dataProxy: [proxy]) {
            Field("id", pk: true)
            Field("text", "Text")
        }
        let n = try node()
        try n.register(memo, MemoryRepository())
        #expect(call(n, "GET", "/erupt-api/build/Memo", erupt: "Memo").1?["eruptModel"]?["searchCondition"] == ["text": "hi"])
        #expect(call(n, "GET", "/erupt-api/data/init-value/Memo", erupt: "Memo").1?["text"] == "new")
        let r = call(n, "POST", "/erupt-api/data/modify/Memo", erupt: "Memo", body: ["text": "forbidden"]).1
        #expect(r?["success"] == false && r?["message"] == "forbidden text")
        #expect(call(n, "POST", "/erupt-api/data/modify/Memo", erupt: "Memo", body: ["text": "a"]).1?["success"] == true)
        let page = call(n, "POST", "/erupt-api/data/table/Memo", erupt: "Memo", body: [:]).1
        #expect(page?["list"]?.array?.map { $0["text"]!.text } == ["A"])
        let pk = try #require(page?["list"]?[0]?["id"])
        #expect(call(n, "GET", "/erupt-api/data/Memo/\(pk.text)", erupt: "Memo").1?["text"] == "a?")
        #expect(call(n, "POST", "/erupt-api/data/modify/Memo/update", erupt: "Memo", body: ["id": pk, "text": "b"]).1?["success"] == true)
        #expect(call(n, "POST", "/erupt-api/data/modify/Memo/delete", erupt: "Memo", body: [pk]).1?["success"] == true)
        #expect(proxy.calls == ["beforeAdd a", "afterAdd a", "beforeUpdate b", "afterUpdate b", "beforeDelete b", "afterDelete b"])
    }

    @Test func beforeFetch() throws {
        let n = try node()
        try n.register(try taskModel(), try SQLRepository(try SQLiteExecutor(path: ":memory:"), table: "task", autoCreate: true))
        for (title, owner, done) in [("a", "admin", false), ("b", "admin", true), ("c", "root", false), ("a?", "admin", false)] {
            _ = call(n, "POST", "/erupt-api/data/modify/Task", erupt: "Task", body: ["title": .string(title), "owner": .string(owner), "done": .bool(done)])
        }
        let titles: (JSON, String) -> [String]? = { body, account in
            call(n, "POST", "/erupt-api/data/table/Task", erupt: "Task", body: body, account: account).1?["list"]?.array?.map { $0["title"]!.text }
        }
        #expect(titles([:], "admin") == ["a", "a?"])
        #expect(titles(["condition": [["key": "title", "expression": "EQ", "value": "a"]]], "root") == [])
        // a @Vis view's filter (a '?' in plain SQL stays as written) and order
        #expect(titles(["vis": "q"], "admin") == ["a?"])
        #expect(titles(["vis": "Reversed"], "admin") == ["a?", "a"])
        let vis = call(n, "GET", "/erupt-api/build/Task", erupt: "Task").1?["eruptModel"]?["eruptJson"]?["vis"]?.array ?? []
        #expect(vis.map { $0["code"]?.text } == ["q", "Reversed"])
        #expect(vis.allSatisfy { $0["filter"] == nil && $0["orderBy"] == nil })
        #expect(throws: DeclarationError.self) {
            try Model("Task", erupt: Erupt(vis: [Vis(title: "A")]), visQuery: ["B": VisQuery(filter: "1 = 1")]) { Field("id", pk: true) }
        }
        #expect(throws: DeclarationError.self) {
            try Model("Task", erupt: Erupt(vis: [Vis(title: "A")]), visQuery: ["A": VisQuery(orderBy: "nope")]) { Field("id", pk: true) }
        }
    }

    @Test func linkTree() throws {
        let n = try node()
        let category = try articleModel().0
        let doc = try Model("Doc", erupt: Erupt(linkTree: LinkTree(dependNode: true, field: "topic"))) {
            Field("id", pk: true)
            Field("title", "Title")
            Field("topic", "Topic", .tree(category, pid: "parent"))
        }
        try n.register(doc, MemoryRepository([["title": "a", "topic": 1], ["title": "b", "topic": 2], ["title": "c", "topic": 3]]))
        let titles: (JSON) -> [String]? = { body in
            call(n, "POST", "/erupt-api/data/table/Doc", erupt: "Doc", body: body).1?["list"]?.array?.map { $0["title"]!.text }
        }
        #expect(titles([:]) == [], "dependNode: nothing until a tree node is picked")
        #expect(titles(["linkTreeVal": [2]]) == ["b"])
        #expect(titles(["linkTreeVal": ["1", "2"]]) == ["a", "b"])
        #expect(throws: DeclarationError.self) {
            try Model("Doc", erupt: Erupt(linkTree: LinkTree(field: "title"))) { Field("id", pk: true); Field("title", "Title") }
        }
    }

    @Test func fieldTypesAndInvoke() throws {
        let n = try node()
        let category = try articleModel().0
        let order = try Model("Order") {
            Field("id", pk: true)
            Field("status", "Status", fetch: .options { form in [("new", "New"), (form["note"]?.string ?? "x", "From form")] })
            Field("tags", "Tags", type: .tags, fetch: .tags { _ in ["red", "blue"] })
            Field("qty", "Qty", .number, onchange: { form in FormChange(formData: ["note": .string("\(form["qty"]!.text) items")]) })
            Field("note", "Note")
            Field("city", "City", type: .autoComplete, complete: { _, typed in ["Paris", "Tokyo"].filter { $0.lowercased().contains(typed.lowercased()) } })
            Field("body", "Body", type: .markdown)
            Field("files", "Files", type: .attachment)
            Field("cats", "Categories", .ref(category), type: .checkbox)
            Field("sections", "Sections", .ref(category), type: .tabTree)
            Field("calc", "Calc", type: .button, click: { _ in FormChange(eval: "alert(1)", formData: ["qty": 2]) })
            Field("stop", "Stop", type: .button, click: { _ in throw EruptFailure("not now") })
        }
        try n.register(order, MemoryRepository())
        let build = call(n, "GET", "/erupt-api/build/Order", erupt: "Order").1?["eruptModel"]?["eruptFieldModels"]?.array ?? []
        let fields = Dictionary(uniqueKeysWithValues: build.map { ($0["fieldName"]!.text, $0) })
        let edit = fields.mapValues { $0["eruptFieldJson"]!["edit"]! }
        for f in build { try Schema.check("EruptField", f["eruptFieldJson"]!, partial: false) }
        #expect(edit["status"]?["choiceType"]?["fetchHandler"] == ["invoke"])
        #expect(edit["tags"]?["tagsType"]?["fetchHandler"] == ["invoke"])
        #expect(edit["qty"]?["onchange"] == "invoke")
        #expect([edit["body"]?["type"], edit["files"]?["type"], edit["calc"]?["type"]] == ["MARKDOWN", "ATTACHMENT", "BUTTON"])
        #expect(fields["calc"]?["eruptFieldJson"]?["views"] == [])
        #expect([fields["cats"]?["fieldReturnName"], fields["sections"]?["fieldReturnName"]] == ["Category", "Category"])

        let invoke: (String, String, JSON, JSON) -> (Int, JSON?) = { kind, field, form, value in
            call(n, "POST", "/erupt-api/invoke/Order/\(kind)/\(field)", erupt: "Order", body: ["form": form, "value": value])
        }
        #expect(invoke("options", "status", ["note": "n"], nil).1?["data"] == [["value": "new", "label": "New"], ["value": "n", "label": "From form"]])
        #expect(invoke("options", "tags", [:], nil).1?["data"] == ["red", "blue"])
        #expect(invoke("onchange", "qty", ["qty": 3], nil).1?["data"]?["formData"] == ["note": "3 items"])
        #expect(invoke("autocomplete", "city", [:], "pa").1?["data"] == ["Paris"])
        #expect(invoke("button", "calc", [:], nil).1?["data"]?["eval"] == "alert(1)")
        let stop = invoke("button", "stop", [:], nil).1
        #expect(stop?["success"] == false && stop?["message"] == "not now")
        #expect(invoke("button", "qty", [:], nil).0 == 404, "a field without that code")
        #expect(invoke("options", "missing", [:], nil).0 == 404)

        // picked records arrive as [{id: key}] and are stored as their keys
        let add = call(n, "POST", "/erupt-api/data/modify/Order", erupt: "Order",
                       body: ["cats": [["id": 1], ["id": "2"]], "sections": [["id": 3]], "tags": "[\"red\"]"]).1
        #expect(add?["success"] == true)
        let row = call(n, "POST", "/erupt-api/data/table/Order", erupt: "Order", body: [:]).1?["list"]?[0]
        #expect(row?["cats"] == [1, 2] && row?["sections"] == [3])
        #expect(row?["calc"] == nil)

        #expect(throws: DeclarationError.self) { try Model("M") { Field("id", pk: true); Field("a", "A", click: { _ in FormChange() }) } }
        #expect(throws: DeclarationError.self) { try Model("M") { Field("id", pk: true); Field("a", "A", fetch: .tags { _ in [] }) } }
        #expect(throws: DeclarationError.self) { try Model("M") { Field("id", pk: true); Field("a", "A", type: .checkbox) } }
    }

    @Test func drill() throws {
        let n = try node()
        let (author, book) = try authorAndBook()
        try n.register(author, MemoryRepository([["name": "Ann"], ["name": "Bob"]]))
        try n.register(book, MemoryRepository([["title": "a", "author": 1], ["title": "b", "author": 2], ["title": "c", "author": 1]]))
        let drill = ["Drill": "Books", "DrillSourceErupt": "Author", "DrillValue": "1"]
        let page = call(n, "POST", "/erupt-api/data/table/Book", erupt: "Book", body: [:], headers: drill).1
        #expect(page?["list"]?.array?.map { $0["title"]!.text } == ["a", "c"])
        #expect(call(n, "POST", "/erupt-api/data/table/Book", erupt: "Book", body: [:], headers: drill.merging(["Drill": "x"]) { $1 }).0 == 403)
        let eruptJson = call(n, "GET", "/erupt-api/build/Author", erupt: "Author").1?["eruptModel"]?["eruptJson"]
        try Schema.check("Erupt", eruptJson!, partial: false)
        let drills = eruptJson?["drills"]?.array ?? []
        #expect(drills.map { [$0["code"], $0["title"], $0["link"]?["linkErupt"]] } == [["Books", "Books", "Book"]])
        #expect(drills[0]["link"]?["joinColumn"] == nil)
        #expect(throws: DeclarationError.self) {
            try Model("A", erupt: Erupt(drills: [Drill(link: Link(linkErupt: "Book"), title: "Books")])) { Field("id", pk: true) }
        }
    }

    @Test func simpleTypesAndDependColumn() throws {
        let n = try node()
        let (author, book) = try authorAndBook()
        try n.register(author, MemoryRepository())
        try n.register(book, MemoryRepository())
        let build = call(n, "GET", "/erupt-api/build/Book", erupt: "Book").1?["eruptModel"]?["eruptFieldModels"]?.array ?? []
        // dependColumn is @Transient in Java, so the schema does not know it
        for f in build where f["fieldName"] != "shelf" { try Schema.check("EruptField", f["eruptFieldJson"]!, partial: false) }
        let edit = Dictionary(uniqueKeysWithValues: build.map { ($0["fieldName"]!.text, $0["eruptFieldJson"]!["edit"]!) })
        #expect(["colour", "stars", "secret", "readers"].map { edit[$0]?["type"] } == ["COLOR", "RATE", "HIDDEN", "TRANSFER"])
        #expect(edit["shelf"]?["referenceTableType"]?["dependColumn"] == "parent", "the server reads it off the build")
        let add = call(n, "POST", "/erupt-api/data/modify/Book", erupt: "Book", body: ["title": "d", "stars": "4", "readers": [["id": 2]]]).1
        #expect(add?["success"] == true)
        let row = call(n, "POST", "/erupt-api/data/table/Book", erupt: "Book", body: [:]).1?["list"]?[0]
        #expect(row?["stars"] == 4 && row?["readers"] == [2])
        #expect(throws: DeclarationError.self) { try Model("M") { Field("id", pk: true); Field("a", "A", dependColumn: "x") } }
    }

    @Test func nodeConfigAndUserInfo() throws {
        var seen: [(String, String?)] = []
        let server = try HTTPServer(host: "127.0.0.1", port: 0) { req in
            seen.append((req.path, req.header("token")))
            let body = req.path.contains("userinfo") ? "{\"account\":\"admin\",\"roles\":[\"r\"]}" : "cfg"
            return NodeResponse(status: 200, contentType: "text/plain", body: Array(body.utf8))
        }
        server.start()
        defer { server.close() }
        var n: Node?
        let who = try Model("Who") {
            Field("id", pk: true)
            RowAction("who", "Who", mode: .button) { _ in try n!.userInfo()?["account"]?.text }
        }
        n = try Node(name: "blog", accessToken: token, servers: ["http://127.0.0.1:\(server.port)"], log: { _, _ in })
        try n!.register(who, MemoryRepository())
        #expect(try n!.config() == "cfg")
        #expect(try n!.groupConfig() == "cfg")
        #expect(call(n!, "POST", "/erupt-api/invoke/Who/operation/who", erupt: "Who", body: ["ids": []]).1?["data"] == "admin")
        #expect(seen.map(\.0) == ["/erupt-cloud-api/node-config/blog", "/erupt-cloud-api/node-group-config/blog", "/erupt-cloud-api/userinfo/blog"])
        #expect(seen.last?.1 == "t", "the request's token")
    }

    @Test func beforeFetchNeedsSQL() throws {
        let n = try node()
        try n.register(try taskModel(), MemoryRepository())
        #expect(call(n, "POST", "/erupt-api/data/table/Task", erupt: "Task", body: [:]).0 == 500)
    }

    @Test func plainAccessToken() throws {
        // without a signature the node asks the server for the user's power and, unreachable, fails closed
        let n = try node()
        #expect(call(n, "GET", "/erupt-api/build/Article", signed: false).1?["power"]?["add"] == false)
        #expect(call(n, "POST", "/erupt-api/data/modify/Article", body: ["title": "x"], signed: false).0 == 403)
    }

    @Test func servesOverHTTP() throws {
        let n = try node()
        let server = try HTTPServer(host: "127.0.0.1", port: 0, handler: n.handle)
        server.start()
        defer { server.close() }
        let body = try String(contentsOf: URL(string: "http://127.0.0.1:\(server.port)/node-health")!, encoding: .utf8)
        #expect(body == "test")
    }
}

@Suite struct DeclarationTests {
    @Test func rejectsIllegalDeclarations() throws {
        #expect(throws: DeclarationError.self) { try Model("bad name") { Field("id", pk: true) } }
        #expect(throws: DeclarationError.self) { try Model("M") { Field("id", pk: true); Field("id") } }
        #expect(throws: DeclarationError.self) { try Model("M") { Field("id", pk: true); Field("x-y") } }
        #expect(throws: DeclarationError.self) { try Model("M", power: ["fly": true]) { Field("id", pk: true) } }
        #expect(throws: DeclarationError.self) { try Model("M", orderBy: "nope desc") { Field("id", pk: true) } }
        #expect(throws: DeclarationError.self) { try Model("M") { Field("id", pk: true); Field("a", type: .password) } }
        let target = try Model("T") { Field("id", pk: true) }
        #expect(throws: DeclarationError.self) { try Model("M") { Field("id", pk: true); Field("t", "T", .ref(target)) } }
        let form = try Model("F") { Field("note") }
        #expect(throws: DeclarationError.self) {
            try Node(name: "n", accessToken: "t", servers: ["http://x"]).register(form, MemoryRepository())
        }
    }
}

@Suite struct ValueTests {
    @Test func dates() throws {
        #expect(try Values.dateTime("2026-01-05") == "2026-01-05T00:00:00.000")
        #expect(try Values.dateTime("2026-01-05 10:30") == "2026-01-05T10:30:00.000")
        #expect(try Values.dateTime("2026-01-05T10:30:01.5Z") == "2026-01-05T10:30:01.500")
        #expect(try Values.date("2024-02-29T23:59:59") == "2024-02-29")
        for bad: JSON in ["2023-02-29", "2026-13-01", "someday", "2026-01-05T25:00", 20260105] {
            #expect(throws: EruptFailure.self) { try Values.date(bad) }
        }
    }

    @Test func numbers() throws {
        #expect(try Values.number("3") == .int(3))
        #expect(try Values.number(9.0) == .int(9))
        #expect(try Values.number("9.9") == .double(9.9))
        for bad: JSON in ["many", "nan", true, [1]] { #expect(throws: EruptFailure.self) { try Values.number(bad) } }
    }

    @Test func json() throws {
        let text = #"{"a":[1,2.5,true,null,"\u00e9\ud83d\ude00\n"],"b":{}}"#
        let value = try JSON.parse(text)
        #expect(value["a"]![0] == .int(1))
        #expect(value["a"]![4] == "é😀\n")
        #expect(try JSON.parse(value.serialized()) == value)
        #expect(value.serialized() == #"{"a":[1,2.5,true,null,"é😀\n"],"b":{}}"#)
        for bad in ["", "{", "[1,]", "01x", "\"\\x\"", "nul", "{\"a\" 1}"] {
            #expect(throws: JSONParseError.self) { try JSON.parse(bad) }
        }
    }
}

@Suite struct SignatureTests {
    @Test func javaVectors() throws {
        let url = URL(fileURLWithPath: #filePath).appendingPathComponent("../../../../conformance/signature-vectors.json").standardized
        let doc = try JSON.parse(Array(try Data(contentsOf: url)))
        let accessToken = doc["accessToken"]!.text
        for v in doc["vectors"]!.array! {
            let body = v["body"]!.string.map { Array($0.utf8) }
            let ts = v["timestamp"]!.int!
            let args = (v["method"]!.text, v["pathAndQuery"]!.text, v["enforced"]!.string, v["user"]!.string)
            let signature = v["signature"]!.text
            #expect(Signature.sign(accessToken: accessToken, method: args.0, pathAndQuery: args.1, timestamp: ts,
                                   enforced: args.2, user: args.3, body: body) == signature, "\(v["case"]!.text)")
            func verify(_ s: String, _ now: Int64) -> Bool {
                Signature.verify(accessToken: accessToken, method: args.0, pathAndQuery: args.1, timestamp: String(ts),
                                 enforced: args.2, user: args.3, body: body, signature: s, now: now)
            }
            #expect(verify(signature, ts + 300))
            #expect(!verify(signature, ts + 301))
            #expect(!verify(String(signature.reversed()), ts))
        }
        #expect(!Signature.verify(accessToken: "t", method: "GET", pathAndQuery: "/", timestamp: "soon", enforced: nil,
                                  user: nil, body: [], signature: "00", now: 0))
    }

    @Test func sha256() {
        #expect(Signature.hex(SHA256.hash(Array("abc".utf8))) == "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad")
        #expect(Signature.hex(SHA256.hash(Array(repeating: 0x61, count: 1000))).hasPrefix("41edece4"))
        // RFC 4231 test case 2
        #expect(Signature.hex(SHA256.hmac(key: Array("Jefe".utf8), message: Array("what do ya want for nothing?".utf8)))
            == "5bdcc146bf60754e6a042426089575c75a003f089d2739839dec58b964ec3843")
    }
}
