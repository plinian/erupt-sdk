// The conformance fixture (conformance/README.md) in Swift.
import EruptSDK
import Foundation

let env = ProcessInfo.processInfo.environment
let port = Int(env["PORT"] ?? "") ?? 9090

struct NoteProxy: DataProxy {
    func addBehavior(_ record: inout Record) { record["text"] = "new" }

    func validate(_ record: Record) throws {
        if record["text"] == "forbidden" { throw EruptFailure("forbidden text") }
    }
}

do {
    let category = try Model("Category") {
        Field("id", pk: true)
        Field("name", "Name", search: true)
        Field("parent", "Parent", .number)
    }

    let publishForm = try Model("PublishForm", title: "Publish Options") {
        Field("note", "Note", notNull: true)
    }

    let article = try Model("Article", orderBy: "id desc") {
        Field("id", pk: true)
        Field("title", "Title", search: true, notNull: true, sortable: true, edit: Edit(inputType: InputType(length: 64)))
        Field("status", "Status", search: true, choices: ["draft": "Draft", "published": "Published"])
        Field("views", "Views", .number, sortable: true)
        Field("featured", "Featured", .bool, search: true)
        Field("publish_date", "Publish Date", .date, search: true)
        Field("review_at", "Review At", .dateTime)
        Field("body", "Body", type: .textarea, table: false)
        Field("category", "Category", .ref(category), search: true)
        Field("topic", "Topic", .tree(category, pid: "parent"))

        RowAction("publish", "Publish", icon: "fa fa-paper-plane", form: publishForm, ifExpr: "item.status !== 'published'") { op in
            for row in op.rows { try op.repo.update(row["id"]!, ["status": "published"]) }
            return nil
        }
        RowAction("feature", "Feature", mode: .single, confirm: false) { _ in "alert('featured')" }
        RowAction("rebuild", "Rebuild", mode: .button, show: { $0?.account == "root" }) { _ in nil }
    }

    let note = try Model("Note", power: ["delete": false], dataProxy: [NoteProxy()]) {
        Field("id", pk: true)
        Field("text", "Text")
    }

    let node = try Node(
        name: "conformance", accessToken: env["ERUPT_ACCESS_TOKEN"] ?? "", servers: [env["ERUPT_SERVER"] ?? ""],
        address: "http://127.0.0.1:\(port)")
    try node.register(category, MemoryRepository([["name": "Tech", "parent": nil], ["name": "Python", "parent": 1], ["name": "Life", "parent": nil]]))
    try node.register(article, MemoryRepository())
    try node.register(note, MemoryRepository())
    try node.serve(host: "127.0.0.1", port: port)
} catch {
    FileHandle.standardError.write("\(error)\n".data(using: .utf8)!)
    exit(1)
}
