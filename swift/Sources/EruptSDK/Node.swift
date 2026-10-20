import Dispatch
import Foundation

#if canImport(FoundationNetworking)
    import FoundationNetworking
#endif
#if canImport(Glibc)
    import Glibc
#elseif canImport(Musl)
    import Musl
#else
    import Darwin
#endif

/// Erupt cloud node runtime: registers with the server, then answers the requests it forwards. The wire contract
/// is erupt-cloud/PROTOCOL.md (Level 0) in the erupt repository.
///
/// `serve` runs it on a small built-in HTTP server. To mount it in Vapor or Hummingbird instead, route
/// `/erupt-api/**` and `/node-health` to `handle(_:)` and call `start(port:)` / `stop()`.
public final class Node: @unchecked Sendable {
    public static let version = "0.1.0"

    /// Features whose endpoints this SDK does not serve yet: hidden from the UI instead of failing there
    static let unsupportedPower = ["print": false, "ai": false]
    /// Rights the server decides per user; the node ANDs them onto the declared power
    static let serverPower = ["add", "edit", "delete", "viewDetails", "export", "importable"]
    static let ops: Set<String> = ["EQ", "NEQ", "GT", "GTE", "LT", "LTE", "LIKE", "NOT_LIKE", "RANGE", "IN", "NOT_IN", "NULL", "NOT_NULL"]
    static let maxPageSize = 1000
    static let powerTTL: TimeInterval = 5

    public enum LogLevel: String { case info = "INFO", warn = "WARN", error = "ERROR" }

    public let name: String
    public private(set) var address: String?
    private let accessToken: String
    private let servers: [String]
    private let heartbeat: TimeInterval
    private let requireSignature: Bool
    private let log: (LogLevel, String) -> Void
    private var models: [String: (model: Model, repo: Repository)] = [:]
    private let lock = NSLock()
    private var tick = 0
    private var powerCache: [String: (expires: TimeInterval, power: [String: Bool])] = [:]
    private var instanceId = ""
    private var heartbeatThread: Thread?
    private let wake = DispatchSemaphore(value: 0)

    /// `requireSignature` refuses server calls without a valid Erupt-Signature, so the plain access token alone
    /// no longer passes (servers sign since erupt 2.3.x). `address` is where the server reaches this node;
    /// guessed from the local interface when nil.
    public init(
        name: String, accessToken: String, servers: [String], address: String? = nil, heartbeat: TimeInterval = 15,
        requireSignature: Bool = false, log: ((LogLevel, String) -> Void)? = nil
    ) throws {
        guard !accessToken.isEmpty else { throw DeclarationError("accessToken is required") }
        guard !servers.isEmpty else { throw DeclarationError("at least one erupt server is required") }
        self.name = name
        self.accessToken = accessToken
        self.servers = servers.map { $0.hasSuffix("/") ? String($0.dropLast()) : $0 }
        self.address = address
        self.heartbeat = heartbeat
        self.requireSignature = requireSignature
        self.log = log ?? { level, message in FileHandle.standardError.write("[erupt] \(level.rawValue) \(message)\n".data(using: .utf8)!) }
    }

    @discardableResult
    public func register(_ model: Model, _ repository: Repository) throws -> Node {
        guard model.pk != nil else {
            throw DeclarationError("\(model.name) has no primary key; only an operation form may omit it")
        }
        try lock.locked {
            guard models[model.name] == nil else { throw DeclarationError("erupt '\(model.name)' registered twice") }
            models[model.name] = (model, repository)
        }
        try repository.bind(model)
        return self
    }

    // MARK: - lifecycle

    /// Serves on `host:port` until SIGINT / SIGTERM: HTTP first (the server probes /node-health while
    /// registering), then the heartbeat; deregisters on the way out.
    public func serve(host: String = "0.0.0.0", port: Int = 9090) throws {
        let http = try HTTPServer(host: host, port: port, handler: handle)
        http.start()
        start(port: http.port)
        let done = DispatchSemaphore(value: 0)
        let signals = [SIGINT, SIGTERM].map { sig -> DispatchSourceSignal in
            signal(sig, SIG_IGN)
            let source = DispatchSource.makeSignalSource(signal: sig, queue: .global())
            source.setEventHandler { done.signal() }
            source.resume()
            return source
        }
        done.wait()
        signals.forEach { $0.cancel() }
        stop()
        http.close()
    }

    /// Starts registering (and the heartbeat) for a node served on `port` by any HTTP server.
    public func start(port: Int) {
        lock.locked {
            instanceId = String(UInt32.random(in: 0...0xFF_FFFF), radix: 16)
            let base = address ?? "http://\(localIP(servers[0])):\(port)"
            address = base.hasSuffix("/") ? String(base.dropLast()) : base
        }
        log(.info, "erupt node '\(name)' at \(address!) -> \(servers.joined(separator: ", "))")
        let thread = Thread { [self] in heartbeatLoop() }
        lock.locked { heartbeatThread = thread }
        thread.start()
    }

    /// Stops the heartbeat and deregisters.
    public func stop() {
        guard let thread = lock.locked({ () -> Thread? in
            defer { heartbeatThread = nil }
            return heartbeatThread
        }) else { return }
        thread.cancel()
        wake.signal()
        do {
            _ = try serverCall(
                "POST", "/erupt-cloud-api/remove-instance-node",
                form: ["nodeName": name, "accessToken": accessToken, "locations": address ?? ""])
        } catch {
            log(.error, "deregister failed: \(error)")
        }
    }

    private func heartbeatLoop() {
        var failing = false
        while !Thread.current.isCancelled {
            let server = nextServer()
            do {
                _ = try serverCall("POST", "/erupt-cloud-api/register-node", server: server, json: nodeInfo(), timeout: 10)
                if failing { log(.info, "\(server) -> connection success") }
                failing = false
                _ = wake.wait(timeout: .now() + heartbeat)
            } catch {
                failing = true
                log(.error, "\(server) -> register failed: \(error)")
                _ = wake.wait(timeout: .now() + heartbeat / 2)
            }
        }
    }

    private func nodeInfo() -> JSON {
        let erupts = lock.locked { models.keys.sorted() }
        return [
            "instanceId": .string(instanceId), "nodeName": .string(name), "accessToken": .string(accessToken),
            "version": .string("swift-\(Node.version)"), "nodeAddress": [.string(address ?? "")], "eruptModules": [],
            "erupts": .array(erupts.map(JSON.string)), "resources": [:], "capabilities": ["invoke"],
        ]
    }

    // MARK: - requests

    /// Answered with a bare status
    private struct Reply: Error {
        let status: Int
    }

    /// Answers one request the erupt server forwarded (or its /node-health probe).
    public func handle(_ request: NodeRequest) -> NodeResponse {
        if request.path == "/node-health" {
            return NodeResponse(status: 200, contentType: "text/plain; charset=utf-8", body: Array(name.utf8))
        }
        do {
            return respond(200, try dispatch(request))
        } catch let reply as Reply {
            return NodeResponse(status: reply.status, contentType: "text/plain; charset=utf-8", body: [])
        } catch let failure as EruptFailure {
            return respond(200, r(success: false, message: failure.message))
        } catch {  // never leak internals: message only, the stack stays in the node log
            log(.error, "erupt node error: \(error)")
            return respond(500, ["path": .string(request.path), "status": 500, "error": "erupt exception", "message": .string("\(error)")])
        }
    }

    private func respond(_ status: Int, _ body: JSON) -> NodeResponse {
        return NodeResponse(status: status, contentType: "application/json; charset=utf-8", body: Array(body.serialized().utf8))
    }

    private typealias Route = (method: String, pattern: [String], handler: (Node) -> (Context) throws -> JSON)

    private static let routes: [Route] = [
        ("GET", ["build", "*"], { $0.build }),
        ("POST", ["data", "table", "*"], { $0.table }),
        ("GET", ["data", "init-value", "*"], { $0.initValue }),
        ("GET", ["data", "*", "*"], { $0.get }),
        ("POST", ["data", "modify", "*"], { $0.add }),
        ("POST", ["data", "modify", "*", "update"], { $0.update }),
        ("POST", ["data", "modify", "*", "delete"], { $0.delete }),
        ("POST", ["invoke", "*", "*", "*"], { $0.invoke }),
    ]

    /// One request being served: its model, repository and the path parameters after the erupt name.
    private struct Context {
        let request: NodeRequest
        let model: Model
        let repo: Repository
        let args: [String]
        var arg: String? { args.first }
        let enforced: [String]
        var user: User? { User.current }
    }

    private func dispatch(_ req: NodeRequest) throws -> JSON {
        guard req.path.hasPrefix("/erupt-api/") else { throw Reply(status: 404) }
        // server-to-server only: an Origin header means a browser reached the node directly
        guard (req.header("Origin") ?? "").isEmpty else { throw Reply(status: 403) }
        let enforced = try authenticate(req)
        let segments = req.path.dropFirst("/erupt-api/".count).split(separator: "/", omittingEmptySubsequences: false).map(String.init)
        for route in Node.routes where route.method == req.method && route.pattern.count == segments.count {
            var captures: [String] = []
            guard zip(route.pattern, segments).allSatisfy({ p, s in
                if p == "*" { captures.append(unescape(s)); return !s.isEmpty }
                return p == s
            }) else { continue }
            let eruptName = captures[0]
            guard req.header("erupt") == eruptName, let entry = lock.locked({ models[eruptName] }) else { throw Reply(status: 404) }
            // nesting is not supported yet, so a parent can only vouch for itself
            if let parent = req.header("eruptParent") ?? queryParam(req.query, "_eruptParent"), !parent.isEmpty,
                parent.split(separator: ".", omittingEmptySubsequences: false).last.map(String.init) != eruptName
            {
                throw Reply(status: 404)
            }
            let user = try (req.header("user")).flatMap { header -> User? in
                guard !header.isEmpty else { return nil }
                guard let data = Data(base64Encoded: header), let json = try? JSON.parse(Array(data)) else {
                    throw EruptFailure("illegal user header")
                }
                return User(json)
            }
            let context = Context(request: req, model: entry.model, repo: entry.repo, args: Array(captures.dropFirst()), enforced: enforced)
            return try User.$current.withValue(user) { try route.handler(self)(context) }
        }
        throw Reply(status: 404)
    }

    /// A signed call must verify, and then stands for the token; its Erupt-Enforced is trusted only then.
    private func authenticate(_ req: NodeRequest) throws -> [String] {
        guard let signature = req.header("Erupt-Signature") else {
            guard !requireSignature, constantTimeEquals(req.header("Access-Token") ?? "", accessToken) else { throw Reply(status: 403) }
            return []
        }
        let enforced = req.header("Erupt-Enforced")
        let multipart = (req.header("Content-Type") ?? "").contains("multipart/form-data")
        let ok = Signature.verify(
            accessToken: accessToken, method: req.method, pathAndQuery: req.path + (req.query.isEmpty ? "" : "?\(req.query)"),
            timestamp: req.header("Erupt-Timestamp"), enforced: enforced, user: req.header("user"),
            body: multipart ? nil : req.body, signature: signature, now: Int64(Date().timeIntervalSince1970))
        guard ok else { throw Reply(status: 403) }
        return (enforced ?? "").split(separator: ",").map(String.init).filter { !$0.isEmpty }
    }

    // MARK: - endpoints

    private func build(_ c: Context) throws -> JSON { c.model.buildModel(power: try power(c.model, c), user: c.user) }

    private func table(_ c: Context) throws -> JSON {
        try requirePower(c.model, c, "query")
        return try page(c.model, c.repo, try readObject(c))
    }

    private func page(_ model: Model, _ repo: Repository, _ body: [String: JSON]) throws -> JSON {
        let pageIndex = max(try int(body["pageIndex"] ?? 1), 1)
        let pageSize = min(max(try int(body["pageSize"] ?? 10), 1), Node.maxPageSize)
        var query = Query(offset: (pageIndex - 1) * pageSize, limit: pageSize)
        for c in body["condition"]?.array ?? [] { query.conditions += try conditions(model, c) }
        for s in body["sort"]?.array ?? [] {
            let fieldName = s["field"]?.text ?? ""
            guard let f = model.field(fieldName), f.sortable || f.pk else { throw EruptFailure("illegal sort field '\(fieldName)'") }
            query.sort.append((f.name, (s["direction"]?.text ?? "").uppercased() == "DESC"))
        }
        // a @LinkTree table shows the rows under the picked tree keys; with dependNode, none until one is picked
        let picked = body["linkTreeVal"].flatMap { $0 == .null ? nil : $0 }
        if let link = model.linkTree, let picked { query.conditions.append(try condition(model.field(link.field)!, "IN", picked)) }
        // a @Vis view's own filter and order, then the DataProxy's
        let vis = body["vis"]?.string.flatMap { model.vis[$0] }
        if query.sort.isEmpty { query.sort = vis?.order.isEmpty == false ? vis!.order : model.order }
        query.filters = (vis?.filters ?? []) + (try model.filters(query.conditions))
        let (total, records) = model.linkTree?.dependNode == true && picked == nil ? (0, []) : try repo.page(query)
        var list = rows(model, records)
        try model.hook { try $0.afterFetch(&list) }
        return [
            "pageIndex": .int(Int64(pageIndex)), "pageSize": .int(Int64(pageSize)), "total": .int(Int64(total)),
            "totalPage": .int(Int64((total + pageSize - 1) / pageSize)), "list": .array(list.map(JSON.object)),
            "sort": nil, "alert": nil, "extraContent": nil,
        ]
    }

    private func conditions(_ model: Model, _ c: JSON) throws -> [Cond] {
        let key = c["key"]?.text ?? ""
        guard let f = model.field(key), !f.pk, f.search else { throw EruptFailure("illegal search field '\(key)'") }
        let op = c["expression"]?.string ?? "EQ"
        guard Node.ops.contains(op) else { throw EruptFailure("illegal operator '\(op)'") }
        let value = c["value"] ?? .null
        guard f.isJSON else { return [try condition(f, op, value)] }
        // a JSON value (MULTI_CHOICE) holds every value searched for, matched as "<value>" in its text
        guard ["EQ", "IN", "NEQ", "NOT_IN"].contains(op) else { throw EruptFailure("illegal operator '\(op)' for \(f.title)") }
        let like = op == "EQ" || op == "IN" ? "LIKE" : "NOT_LIKE"
        let values = value.array ?? (value == .null ? [] : [value])
        return values.map { Cond(f.name, like, .string(JSON.string($0.text).serialized())) }
    }

    private func condition(_ f: Field, _ op: String, _ value: JSON) throws -> Cond {
        if op == "NULL" || op == "NOT_NULL" { return Cond(f.name, op) }
        if f.isReference, !["EQ", "NEQ", "IN", "NOT_IN"].contains(op) { throw EruptFailure("illegal operator '\(op)' for a reference") }
        switch op {
        case "LIKE", "NOT_LIKE": return Cond(f.name, op, .string(value == .null ? "" : value.text))
        case "RANGE":
            guard let range = value.array, range.count == 2 else { throw EruptFailure("range needs two values") }
            return Cond(f.name, op, .array(try range.map { try coerce(f, $0) }))
        case "IN", "NOT_IN": return Cond(f.name, op, .array(try (value.array ?? [value]).map { try coerce(f, $0) }))
        default: return Cond(f.name, op, try coerce(f, value))
        }
    }

    private func initValue(_ c: Context) throws -> JSON {
        try requirePower(c.model, c, "add")
        var record = Record(uniqueKeysWithValues: c.model.fieldNames.map { ($0, JSON.null) })
        try c.model.hook { try $0.addBehavior(&record) }
        return .object(rows(c.model, [record])[0])
    }

    private func get(_ c: Context) throws -> JSON {
        let granted = try power(c.model, c)
        guard granted["edit"] == true || granted["viewDetails"] == true else { throw Reply(status: 403) }
        guard var record = try c.repo.get(try pkOf(c.model, .string(c.arg!))) else { throw EruptFailure("record not found") }
        try c.model.hook { try $0.editBehavior(&record) }
        return .object(rows(c.model, [record])[0])
    }

    private func add(_ c: Context) throws -> JSON {
        try requirePower(c.model, c, "add")
        var rec = try record(c.model, try readObject(c))
        try c.model.hook { try $0.validate(rec) }
        try c.model.hook { try $0.beforeAdd(&rec) }
        try c.repo.add(rec)
        try c.model.hook { try $0.afterAdd(rec) }
        return r()
    }

    private func update(_ c: Context) throws -> JSON {
        try requirePower(c.model, c, "edit")
        let body = try readObject(c)
        let pk = try pkOf(c.model, body[c.model.pk!] ?? .null)
        guard try c.repo.get(pk) != nil else { throw EruptFailure("record not found") }
        var rec = try record(c.model, body)
        try c.model.hook { try $0.validate(rec) }
        try c.model.hook { try $0.beforeUpdate(&rec) }
        try c.repo.update(pk, rec)
        try c.model.hook { try $0.afterUpdate(rec) }
        return r()
    }

    private func delete(_ c: Context) throws -> JSON {
        try requirePower(c.model, c, "delete")
        guard let ids = try readJSON(c)?.array else { throw EruptFailure("a list of ids is required") }
        let pks = try ids.map { try pkOf(c.model, $0) }
        // the hooks see each record as it was; reading them costs nothing without a proxy
        let records = c.model.proxies.isEmpty ? [] : try pks.compactMap { try c.repo.get($0) }
        for rec in records { try c.model.hook { try $0.beforeDelete(rec) } }
        try c.repo.delete(pks)
        for rec in records { try c.model.hook { try $0.afterDelete(rec) } }
        return r()
    }

    /// The node's own code (erupt-cloud/PROTOCOL.md §5.5): a row operation and its form values under the operation
    /// code, or a field's fetched options, onchange, auto-complete or button with the form's values.
    private func invoke(_ c: Context) throws -> JSON {
        if c.args[0] == "operation" { return try operation(c) }
        if c.args[0] == "operation-form" { return r(data: try operationFormValue(c)) }
        guard let f = c.model.declared.first(where: { $0.name == c.args[1] }) else { throw Reply(status: 404) }
        let body = try readObject(c)
        let form = body["form"]?.object ?? [:]
        switch (c.args[0], f.fetch) {
        case ("options", .options(let fetch)?):
            return r(data: .array(try fetch(form).map { ["value": .string($0.value), "label": .string($0.label)] }))
        case ("options", .tags(let fetch)?): return r(data: .array(try fetch(form).map(JSON.string)))
        case ("onchange", _) where f.onchange != nil: return r(data: try f.onchange!(form).json)
        case ("autocomplete", _) where f.complete != nil:
            return r(data: .array(try f.complete!(form, body["value"].flatMap { $0 == .null ? nil : $0.text } ?? "").map(JSON.string)))
        case ("button", _) where f.click != nil: return r(data: try f.click!(form).json)
        default: throw Reply(status: 404)
        }
    }

    /// Records to browser rows. A reference stays its key: the server resolves its label, the flattened
    /// <field>_<label> column and the tree (erupt-cloud/PROTOCOL.md §7.3).
    private func rows(_ model: Model, _ records: [Record]) -> [Record] {
        records.map { rec in Record(uniqueKeysWithValues: model.fieldNames.map { ($0, rec[$0] ?? .null) }) }
    }

    private func action(_ c: Context) throws -> RowAction {
        guard let a = c.model.action(c.args[1]) else { throw Reply(status: 404) }
        // a hidden operation does not exist for this user, exactly like the Java proxy filters it out
        guard a.isVisible(to: c.user) else { throw Reply(status: 403) }
        return a
    }

    private func operationFormValue(_ c: Context) throws -> JSON {
        // none without a form: the server answers the browser a 404, and it opens an empty one
        guard let form = try action(c).form else { return .null }
        return .object(Dictionary(uniqueKeysWithValues: form.fieldNames.map { ($0, JSON.null) }))
    }

    private func operation(_ c: Context) throws -> JSON {
        let a = try action(c)
        let body = try readObject(c)
        let param = try a.form.map { try record($0, body["param"]?.object ?? [:]) }
        var selected: [Record] = []
        if a.mode != .button {
            guard let ids = body["ids"]?.array, !ids.isEmpty else { throw EruptFailure("select at least one row") }
            if a.mode == .single, ids.count != 1 { throw EruptFailure("select exactly one row") }
            selected = try ids.map { id in
                guard let row = try c.repo.get(try pkOf(c.model, id)) else { throw EruptFailure("record '\(id.text)' not found") }
                return row
            }
        }
        let result = try a.handler(OperationContext(rows: selected, param: param, repo: c.repo, model: c.model, user: c.user))
        if let script = result, !script.isEmpty { return r(data: .string(script)) }
        return r(message: "Executed successfully")
    }

    private func pkOf(_ model: Model, _ value: JSON) throws -> JSON { try coerce(model.field(model.pk!)!, value) }

    private func coerce(_ f: Field, _ value: JSON) throws -> JSON { try f.coerce(value) }

    private func record(_ model: Model, _ body: [String: JSON]) throws -> Record {
        var out: Record = [:]
        for name in model.fieldNames {
            let f = model.field(name)!
            if f.pk || !f.form { continue }
            let value: JSON
            do {
                value = try f.coerce(body[name] ?? .null)
            } catch let failure as EruptFailure {
                throw EruptFailure("\(f.title): \(failure.message)")
            }
            if f.notNull, value == .null { throw EruptFailure("\(f.title) cannot be empty") }
            out[name] = value
        }
        return out
    }

    private func r(success: Bool = true, message: String? = nil, data: JSON = nil) -> JSON {
        [
            "success": .bool(success), "status": success ? "SUCCESS" : "ERROR", "message": message.map(JSON.string) ?? nil,
            "data": data, "promptWay": "MESSAGE",
        ]
    }

    // MARK: - permissions (PROTOCOL.md §6.1)

    private func requirePower(_ model: Model, _ c: Context, _ right: String) throws {
        guard try power(model, c)[right] == true else { throw Reply(status: 403) }
    }

    private func power(_ model: Model, _ c: Context) throws -> [String: Bool] {
        var granted = model.power.merging(Node.unsupportedPower) { _, off in off }
        // the server checked the user's rights and restricts the build's power itself: the model's own
        // declaration is all that is left to apply here
        if c.enforced.contains("power") { return granted }
        let token = c.request.header("token") ?? ""
        let key = "\(token)\n\(model.name)"
        let now = ProcessInfo.processInfo.systemUptime
        if let cached = lock.locked({ powerCache[key] }), cached.expires > now { return cached.power }
        var remote: [String: JSON] = [:]
        do {
            remote = try serverCall(
                "GET", "/erupt-cloud-api/erupt-power", query: ["nodeName": name, "eruptName": model.name],
                headers: ["token": token])?.object ?? [:]
        } catch {  // fail closed: without the server's verdict nothing is writable
            log(.warn, "erupt-power unavailable: \(error)")
        }
        for right in Node.serverPower { granted[right] = (granted[right] ?? false) && remote[right]?.bool == true }
        lock.locked {
            if powerCache.count > 10_000 { powerCache.removeAll() }
            powerCache[key] = (now + Node.powerTTL, granted)
        }
        return granted
    }

    // MARK: - server calls

    private func nextServer() -> String {
        lock.locked {
            tick += 1
            return servers[tick % servers.count]
        }
    }

    private struct ServerError: Error, CustomStringConvertible {
        let description: String
    }

    /// GET with a query (JSON answer), or POST a JSON / form body; throws unless the server answers 2xx.
    private func serverCall(
        _ method: String, _ path: String, server: String? = nil, query: [String: String]? = nil, json: JSON? = nil,
        form: [String: String]? = nil, headers: [String: String] = [:], timeout: TimeInterval = 5
    ) throws -> JSON? {
        guard var url = URLComponents(string: (server ?? nextServer()) + path) else { throw ServerError(description: "illegal server URL") }
        if let query { url.queryItems = query.keys.sorted().map { URLQueryItem(name: $0, value: query[$0]) } }
        var request = URLRequest(url: url.url!, timeoutInterval: timeout)
        request.httpMethod = method
        for (k, v) in headers { request.setValue(v, forHTTPHeaderField: k) }
        if let json {
            request.httpBody = Data(json.serialized().utf8)
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }
        if let form {
            request.httpBody = Data(formEncode(form).utf8)
            request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        }
        let done = DispatchSemaphore(value: 0)
        var result: Result<(Int, Data), Error> = .failure(ServerError(description: "timed out"))
        let task = URLSession.shared.dataTask(with: request) { data, response, error in
            if let error {
                result = .failure(error)
            } else {
                result = .success(((response as? HTTPURLResponse)?.statusCode ?? 0, data ?? Data()))
            }
            done.signal()
        }
        task.resume()
        if done.wait(timeout: .now() + timeout + 1) == .timedOut {
            task.cancel()
            throw ServerError(description: "\(path) timed out")
        }
        let (status, data) = try result.get()
        guard (200..<300).contains(status) else { throw ServerError(description: "\(path) answered HTTP \(status)") }
        return data.isEmpty ? nil : try JSON.parse(Array(data))
    }

    private func formEncode(_ form: [String: String]) -> String {
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~")
        return form.keys.sorted().map { k in
            "\(k.addingPercentEncoding(withAllowedCharacters: allowed)!)=\(form[k]!.addingPercentEncoding(withAllowedCharacters: allowed)!)"
        }.joined(separator: "&")
    }

    // MARK: - helpers

    private func readObject(_ c: Context) throws -> [String: JSON] {
        guard let body = try readJSON(c) else { return [:] }
        guard let object = body.object else { throw EruptFailure("a JSON object is required") }
        return object
    }

    private func readJSON(_ c: Context) throws -> JSON? {
        if c.request.body.isEmpty { return nil }
        do {
            return try JSON.parse(c.request.body)
        } catch {
            throw EruptFailure("malformed JSON body")
        }
    }

    private func int(_ value: JSON) throws -> Int {
        if let i = value.int { return Int(clamping: i) }
        if case .string(let s) = value, let i = Int(s.trimmingSpaces) { return i }
        throw EruptFailure("illegal number '\(value.text)'")
    }

    private func unescape(_ s: String) -> String { s.removingPercentEncoding ?? s }

    private func queryParam(_ query: String, _ name: String) -> String? {
        for pair in query.split(separator: "&") {
            let kv = pair.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false).map(String.init)
            let key = kv[0].replacingOccurrences(of: "+", with: " ").removingPercentEncoding
            if key == name { return kv.count > 1 ? kv[1].replacingOccurrences(of: "+", with: " ").removingPercentEncoding : "" }
        }
        return nil
    }

    /// The interface address the server would see this node on.
    private func localIP(_ server: String) -> String {
        guard let host = URL(string: server)?.host else { return "127.0.0.1" }
        var hints = addrinfo()
        hints.ai_family = AF_INET
        #if os(Linux)
            hints.ai_socktype = Int32(SOCK_DGRAM.rawValue)
        #else
            hints.ai_socktype = SOCK_DGRAM
        #endif
        var info: UnsafeMutablePointer<addrinfo>?
        guard getaddrinfo(host, "80", &hints, &info) == 0, let first = info else { return "127.0.0.1" }
        defer { freeaddrinfo(info) }
        let fd = socket(first.pointee.ai_family, first.pointee.ai_socktype, 0)
        guard fd >= 0 else { return "127.0.0.1" }
        defer { _ = systemClose(fd) }
        guard connect(fd, first.pointee.ai_addr, first.pointee.ai_addrlen) == 0 else { return "127.0.0.1" }
        var local = sockaddr_in()
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        _ = withUnsafeMutablePointer(to: &local) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(fd, $0, &length) } }
        var text = [CChar](repeating: 0, count: Int(INET_ADDRSTRLEN))
        guard inet_ntop(AF_INET, &local.sin_addr, &text, socklen_t(INET_ADDRSTRLEN)) != nil else { return "127.0.0.1" }
        return String(cString: text)
    }
}

extension NSLock {
    func locked<T>(_ body: () throws -> T) rethrows -> T {
        lock()
        defer { unlock() }
        return try body()
    }
}
