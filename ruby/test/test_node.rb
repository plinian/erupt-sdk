# frozen_string_literal: true

require_relative "test_helper"
require "open3"
require "tmpdir"

module NodeFixture
  CALLS = []

  class Category
    extend Erupt::Model
    erupt "Category"
    field :id, pk: true
    field :name, "Name", search: true
    field :parent, "Parent", Integer
  end

  class PublishForm
    extend Erupt::Model
    erupt "Publish Options"
    field :note, "Note", not_null: true
  end

  class Article
    extend Erupt::Model
    erupt "Article", order_by: "id desc"
    field :id, pk: true
    field :title, "Title", search: true, not_null: true, sortable: true
    field :status, "Status", choices: { draft: "Draft", published: "Published" }, search: true
    field :views, "Views", Integer, sortable: true
    field :featured, "Featured", :boolean, search: true
    field :publish_date, "Publish Date", Date, search: true
    field :review_at, "Review At", Time
    field :body, "Body", type: Erupt::EditType::TEXTAREA, table: false
    field :category, "Category", Category, search: true
    field :topic, "Topic", Category, tree: :parent

    operation :publish, "Publish", form: PublishForm do |op|
      CALLS << [:publish, op.rows.map { |r| r["id"] }.sort, op.param]
      op.rows.each { |row| op.repo.update(row["id"], status: "published") }
    end

    operation :feature, "Feature", mode: Erupt::RowOperationMode::SINGLE, confirm: false do
      "alert('featured')"
    end

    operation :rebuild, "Rebuild", mode: Erupt::RowOperationMode::BUTTON, show: ->(user) { user && user["account"] == "root" } do |op|
      CALLS << [:rebuild, op.rows, op.param]
    end
  end

  class Note
    extend Erupt::Model
    erupt "Note", power: { delete: false }
    field :id, pk: true
    field :text, "Text"
  end

  class Widget
    extend Erupt::Model
    erupt "Widget"
    field :id, pk: true
    field :name, "Name"
    field :basic, "Basic", edit: { type: "DIVIDE" }, virtual: true
    field :roles, "Roles", Array, search: true, choices: { ADMIN: "Admin", USER: "User", GUEST: "Guest" }, edit: { type: "MULTI_CHOICE" }
    field :attrs, "Attributes", Hash, edit: { type: "KEY_VALUE" }
  end

  class MemoProxy < Erupt::DataProxy
    CALLS = []

    def search_condition(condition)
      condition["text"] = "hi"
    end

    def after_fetch(rows) = rows.each { |row| row["text"] = row["text"].upcase }

    def add_behavior(record)
      record["text"] = "new"
    end

    def edit_behavior(record)
      record["text"] += "?"
    end

    def validate(record)
      raise Erupt::Fail, "forbidden text" if record["text"] == "forbidden"
    end

    # the write hooks only record that they ran, with the text they saw
    %i[before_add after_add before_update after_update before_delete after_delete].each do |hook|
      define_method(hook) { |record| CALLS << [hook, record["text"]] }
    end
  end

  class Memo
    extend Erupt::Model
    erupt "Memo", data_proxy: MemoProxy
    field :id, pk: true
    field :text, "Text"
  end

  class TaskProxy < Erupt::DataProxy
    def before_fetch(_conditions) = ["owner = ?", [Erupt.current_user["account"]]]
  end

  class OpenProxy < Erupt::DataProxy
    def before_fetch(_conditions) = "done = 0"
  end

  class Task
    extend Erupt::Model
    erupt "Task", data_proxy: [TaskProxy, OpenProxy], vis: [
      { code: "q", title: "Question", type: "TABLE", filter: "title = 'a?'" },
      { title: "Reversed", type: "TABLE", filter: ["1 = 1", "2 = 2"], orderBy: "title desc" }
    ]
    field :id, pk: true
    field :title, "Title", search: true
    field :owner, "Owner"
    field :done, "Done", :boolean
  end

  class Doc
    extend Erupt::Model
    erupt "Doc", linkTree: { field: "topic", dependNode: true }
    field :id, pk: true
    field :title, "Title"
    field :topic, "Topic", Category, tree: :parent
  end

  class Order
    extend Erupt::Model
    erupt "Order"
    field :id, pk: true
    field :status, "Status", fetch: ->(form) { { new: "New", (form["note"] || "x") => "From form" } }
    field :tags, "Tags", type: Erupt::EditType::TAGS, fetch: ->(_form) { %w[red blue] }
    field :qty, "Qty", Integer, onchange: ->(form) { { formData: { note: "#{form["qty"]} items" } } }
    field :note, "Note"
    field :city, "City", type: Erupt::EditType::AUTO_COMPLETE, complete: ->(_form, typed) { %w[Paris Tokyo].select { |c| c.downcase.include?(typed.downcase) } }
    field :body, "Body", type: Erupt::EditType::MARKDOWN
    field :files, "Files", type: Erupt::EditType::ATTACHMENT
    field :cats, "Categories", Array, type: Erupt::EditType::CHECKBOX, ref: Category
    field :sections, "Sections", Array, type: Erupt::EditType::TAB_TREE, ref: Category
    field :calc, "Calc", type: Erupt::EditType::BUTTON, click: ->(_form) { { eval: "alert(1)", formData: { qty: 2 } } }
    field :stop, "Stop", type: Erupt::EditType::BUTTON, click: ->(_form) { raise Erupt::Fail, "not now" }
  end

  class Author
    extend Erupt::Model
    erupt "Author", drills: [{ title: "Books", link: { linkErupt: "Book", joinColumn: "author.id" } }]
    field :id, pk: true
    field :name, "Name"
  end

  class Book
    extend Erupt::Model
    erupt "Book"
    field :id, pk: true
    field :title, "Title"
    field :author, "Author", Author
    field :colour, "Colour", type: Erupt::EditType::COLOR
    field :stars, "Stars", Integer, type: Erupt::EditType::RATE
    field :secret, "Secret", type: Erupt::EditType::HIDDEN
    field :readers, "Readers", Array, type: Erupt::EditType::TRANSFER, ref: Category
    field :shelf, "Shelf", Category, edit: { referenceTableType: { dependField: "author", dependColumn: "parent" } }
  end
end

class NodeTest < Minitest::Test
  include NodeFixture

  TOKEN = "node-secret"

  # what the stubbed erupt server answers to erupt-power
  attr_reader :server

  def article_repo = Erupt::MemoryRepository.new
  def widget_repo = Erupt::MemoryRepository.new

  def setup
    @remote = { "add" => true, "edit" => true, "delete" => true, "viewDetails" => true, "export" => true, "importable" => true }
    test = self
    @server = -> { @remote.dup }
    @node = Erupt::Node.new("blog", TOKEN, "http://server", logger: Quiet.new)
    @node.define_singleton_method(:server_call) { |*, **| test.server.call }
    @node.register(Category, Erupt::MemoryRepository.new([{ name: "Tech", parent: nil }, { name: "Python", parent: 1 },
                                                          { name: "Life", parent: nil }]))
    @node.register(Article, article_repo)
    @node.register(Note, Erupt::MemoryRepository.new)
    @node.register(Widget, widget_repo)
    @node.register(Memo, Erupt::MemoryRepository.new)
    @node.register(Doc, Erupt::MemoryRepository.new([{ title: "a", topic: 1 }, { title: "b", topic: 2 }, { title: "c", topic: 3 }]))
    @node.register(Order, Erupt::MemoryRepository.new)
    @node.register(Author, Erupt::MemoryRepository.new([{ name: "Ann" }, { name: "Bob" }]))
    @node.register(Book, Erupt::MemoryRepository.new([{ title: "a", author: 1 }, { title: "b", author: 2 }, { title: "c", author: 1 }]))
    CALLS.clear
    MemoProxy::CALLS.clear
  end

  class Quiet
    %i[debug info warn error].each { |level| define_method(level) { |_msg| nil } }
  end

  def call(method, path, body = nil, erupt: "Article", headers: {}, account: "admin")
    raw = body.nil? ? "" : JSON.generate(body)
    path, query = path.split("?", 2)
    env = { "REQUEST_METHOD" => method, "PATH_INFO" => path, "QUERY_STRING" => query.to_s, "rack.input" => StringIO.new(raw),
            "HTTP_ACCESS_TOKEN" => TOKEN, "HTTP_TOKEN" => "t1",
            "HTTP_USER" => [JSON.generate("uid" => 1, "account" => account)].pack("m0") }
    env["HTTP_ERUPT"] = erupt if erupt
    env.merge!(headers).compact!
    status, response_headers, payload = @node.call(env)
    text = payload.join
    [status, response_headers["content-type"].start_with?("application/json") ? JSON.parse(text) : text]
  end

  def add(**row)
    status, r = call("POST", "/erupt-api/data/modify/Article", row)
    assert_equal 200, status
    assert r["success"], r
  end

  def table(condition = [], sort: [], size: 10)
    status, page = call("POST", "/erupt-api/data/table/Article", { pageIndex: 1, pageSize: size, condition: condition, sort: sort })
    assert_equal 200, status, page
    page
  end

  def titles(page) = page["list"].map { |r| r["title"] }

  def test_virtual_and_json_fields
    _, build = call("GET", "/erupt-api/build/Widget", erupt: "Widget")
    fields = build["eruptModel"]["eruptFieldModels"].to_h { |f| [f["fieldName"], f] }
    assert_equal({ "id" => "NUMBER", "name" => "INPUT", "basic" => "DIVIDE", "roles" => "MULTI_CHOICE", "attrs" => "KEY_VALUE" },
                 fields.transform_values { |f| f["eruptFieldJson"]["edit"]["type"] })
    assert_equal %w[Admin User Guest], fields["roles"]["componentValue"].map { |o| o["label"] }
    [{ name: "A", roles: %w[ADMIN USER], attrs: { env: "prod" }, basic: "ignored" }, { name: "B", roles: ["GUEST"], attrs: {} }].each do |row|
      _, r = call("POST", "/erupt-api/data/modify/Widget", row, erupt: "Widget")
      assert r["success"], r
    end
    _, r = call("POST", "/erupt-api/data/modify/Widget", { name: "C", roles: ["ROOT"] }, erupt: "Widget")
    refute r["success"]
    _, page = call("POST", "/erupt-api/data/table/Widget", { pageIndex: 1, pageSize: 10 }, erupt: "Widget")
    a = page["list"].find { |row| row["name"] == "A" }
    assert_equal [%w[ADMIN USER], { "env" => "prod" }], a.values_at("roles", "attrs")
    refute a.key?("basic")
    _, page = call("POST", "/erupt-api/data/table/Widget", { condition: [{ key: "roles", expression: "IN", value: ["GUEST"] }] }, erupt: "Widget")
    assert_equal ["B"], page["list"].map { |row| row["name"] }
    _, row = call("GET", "/erupt-api/data/Widget/#{a["id"]}", erupt: "Widget")
    assert_equal %w[ADMIN USER], row["roles"]
  end

  def test_build
    status, build = call("GET", "/erupt-api/build/Article")
    assert_equal 200, status
    model = build["eruptModel"]
    assert_equal "Article", model["eruptName"]
    fields = model["eruptFieldModels"].to_h { |f| [f["fieldName"], f] }
    assert_equal({ "id" => "NUMBER", "title" => "INPUT", "status" => "CHOICE", "views" => "NUMBER", "featured" => "BOOLEAN",
                   "publish_date" => "DATE", "review_at" => "DATE", "body" => "TEXTAREA", "category" => "REFERENCE_TABLE",
                   "topic" => "REFERENCE_TREE" }, fields.transform_values { |f| f["eruptFieldJson"]["edit"]["type"] })
    assert_equal "Category", fields["category"]["fieldReturnName"]
    assert_equal({ "dependField" => "", "id" => "id", "label" => "name" }, fields["category"]["eruptFieldJson"]["edit"]["referenceTableType"])
    assert_equal "name", fields["category"]["eruptFieldJson"]["views"][0]["column"]
    assert_equal "parent", fields["topic"]["eruptFieldJson"]["edit"]["referenceTreeType"]["pid"]
    ops = model["eruptJson"]["rowOperation"].to_h { |o| [o["code"], o] }
    assert_equal %w[publish feature], ops.keys # rebuild is hidden from admin
    assert_equal "PublishForm", ops["publish"]["eruptClass"]
    assert_equal ["void", "", "SINGLE"], ops["feature"].values_at("eruptClass", "callHint", "mode")
    assert_equal ["publish"], build["operationErupts"].keys
    assert_equal ["note"], build["operationErupts"]["publish"]["eruptFieldModels"].map { |f| f["fieldName"] }
    assert_equal "DATE_TIME", fields["review_at"]["eruptFieldJson"]["edit"]["dateType"]["type"]
    assert_equal "DATE", fields["publish_date"]["eruptFieldJson"]["views"][0]["type"]
    assert_equal [], fields["body"]["eruptFieldJson"]["views"]
    assert_equal %w[draft published], fields["status"]["componentValue"].map { |v| v["value"] }
    assert fields["title"]["eruptFieldJson"]["edit"]["notNull"]
    assert build["power"]["export"] # Excel is done by the server
    assert build["power"]["cellEdit"] # the server edits the cell
  end

  def test_build_matches_schema
    %w[Article Note Category Author].each do |name|
      _, build = call("GET", "/erupt-api/build/#{name}", erupt: name, account: "root")
      [build["eruptModel"], *(build["operationErupts"] || {}).values].each do |m|
        Erupt::Schema.check("Erupt", m["eruptJson"], m["eruptName"], partial: false)
        m["eruptJson"]["rowOperation"].each { |op| Erupt::Schema.check("RowOperation", op, op["code"], partial: false) }
        m["eruptFieldModels"].each { |f| Erupt::Schema.check("EruptField", f["eruptFieldJson"], f["fieldName"], partial: false) }
      end
    end
  end

  def test_power_is_declared_and_server
    @remote["add"] = false
    assert_equal 403, call("POST", "/erupt-api/data/modify/Article", { title: "x" }).first
    _, build = call("GET", "/erupt-api/build/Note", erupt: "Note")
    refute build["power"]["delete"]
    assert_equal 403, call("POST", "/erupt-api/data/modify/Note/delete", [1], erupt: "Note").first
  end

  def test_power_fails_closed
    @server = -> { raise IOError, "server down" }
    assert_equal 403, call("POST", "/erupt-api/data/modify/Article", { title: "x" }).first
  end

  def test_guards
    assert_equal 403, call("GET", "/erupt-api/build/Article", headers: { "HTTP_ORIGIN" => "http://evil" }).first
    assert_equal 403, call("GET", "/erupt-api/build/Article", headers: { "HTTP_ACCESS_TOKEN" => "bad" }).first
    assert_equal 403, call("GET", "/erupt-api/build/Article", headers: { "HTTP_ACCESS_TOKEN" => nil }).first
    assert_equal 404, call("GET", "/erupt-api/build/Missing", erupt: "Missing").first
    assert_equal 404, call("GET", "/erupt-api/build/Article", erupt: "Note").first
    assert_equal 404, call("GET", "/erupt-api/build/Article", headers: { "HTTP_ERUPTPARENT" => "blog.Note" }).first
    assert_equal 200, call("GET", "/erupt-api/build/Article", headers: { "HTTP_ERUPTPARENT" => "blog.Article" }).first
    assert_equal [200, "blog"], call("GET", "/node-health", erupt: nil, headers: { "HTTP_ACCESS_TOKEN" => nil })
  end

  def test_signature
    @remote["add"] = false
    signed = lambda do |path, body: "", ts: Time.now.to_i, enforced: nil, signed_body: body|
      user = "e30=" # base64 of {}
      p, q = path.split("?", 2)
      env = { "REQUEST_METHOD" => "GET", "PATH_INFO" => p, "QUERY_STRING" => q.to_s, "rack.input" => StringIO.new(body),
              "HTTP_ERUPT" => "Note", "HTTP_USER" => user, "HTTP_ERUPT_TIMESTAMP" => ts.to_s, "HTTP_ERUPT_ENFORCED" => enforced,
              "HTTP_ERUPT_SIGNATURE" => Erupt::Signature.sign(TOKEN, "GET", path, ts, enforced, user, signed_body) }.compact
      status, _, payload = @node.call(env)
      [status, status == 200 ? JSON.parse(payload.join)["power"]["add"] : nil]
    end
    # Erupt-Enforced: power skips the erupt-power callback (which denies add here)
    assert_equal [200, true], signed.call("/erupt-api/build/Note?_probe=1", enforced: "power")
    assert_equal [200, false], signed.call("/erupt-api/build/Note", enforced: "record")
    assert_equal [403, nil], signed.call("/erupt-api/build/Note", enforced: "power", ts: Time.now.to_i - 301)
    assert_equal [403, nil], signed.call("/erupt-api/build/Note", enforced: "power", body: "{}", signed_body: "")
    # an unsigned Erupt-Enforced is ignored
    _, build = call("GET", "/erupt-api/build/Note", erupt: "Note", headers: { "HTTP_ERUPT_ENFORCED" => "power" })
    refute build["power"]["add"]
    # require_signature refuses the plain access token
    strict = Erupt::Node.new("blog", TOKEN, "http://server", require_signature: true)
    assert_equal 403, strict.call({ "REQUEST_METHOD" => "GET", "PATH_INFO" => "/erupt-api/build/X", "HTTP_ACCESS_TOKEN" => TOKEN }).first
  end

  def test_crud
    add(title: "Hello erupt", status: "published", views: 10, featured: true, publish_date: "2026-01-05",
        review_at: "2026-01-05 10:30:00", body: "...")
    add(title: "Second", status: "draft", views: "3", featured: false, publish_date: "2026-03-01")
    page = table
    assert_equal [2, 1], page.values_at("total", "totalPage")
    first = page["list"].find { |r| r["title"] == "Hello erupt" }
    assert_equal ["2026-01-05", "2026-01-05T10:30:00.000", 10, true], first.values_at("publish_date", "review_at", "views", "featured")

    assert_equal ["Hello erupt"], titles(table([{ key: "title", expression: "LIKE", value: "hello" }]))
    assert_equal ["Second"], titles(table([{ key: "status", expression: "EQ", value: "draft" }]))
    assert_equal ["Hello erupt"], titles(table([{ key: "featured", expression: "EQ", value: true }]))
    assert_equal ["Second"], titles(table([{ key: "publish_date", expression: "RANGE", value: %w[2026-02-01 2026-12-31] }]))
    assert_equal ["Second", "Hello erupt"], titles(table(sort: [{ field: "views", direction: "ASC" }]))

    pk = first["id"]
    _, row = call("GET", "/erupt-api/data/Article/#{pk}")
    assert_equal "Hello erupt", row["title"]
    _, r = call("POST", "/erupt-api/data/modify/Article/update", row.merge("title" => "Renamed"))
    assert r["success"], r
    assert_equal "Renamed", call("GET", "/erupt-api/data/Article/#{pk}").last["title"]
    _, r = call("POST", "/erupt-api/data/modify/Article/delete", [pk])
    assert r["success"]
    assert_equal 1, table["total"]
  end

  def test_data_proxy
    _, build = call("GET", "/erupt-api/build/Memo", erupt: "Memo")
    assert_equal({ "text" => "hi" }, build["eruptModel"]["searchCondition"])
    assert_equal "new", call("GET", "/erupt-api/data/init-value/Memo", erupt: "Memo").last["text"]
    _, r = call("POST", "/erupt-api/data/modify/Memo", { text: "forbidden" }, erupt: "Memo")
    assert_equal [false, "forbidden text"], r.values_at("success", "message")
    assert call("POST", "/erupt-api/data/modify/Memo", { text: "a" }, erupt: "Memo").last["success"]
    _, page = call("POST", "/erupt-api/data/table/Memo", {}, erupt: "Memo")
    assert_equal ["A"], page["list"].map { |row| row["text"] }
    pk = page["list"].first["id"]
    assert_equal "a?", call("GET", "/erupt-api/data/Memo/#{pk}", erupt: "Memo").last["text"]
    assert call("POST", "/erupt-api/data/modify/Memo/update", { id: pk, text: "b" }, erupt: "Memo").last["success"]
    assert call("POST", "/erupt-api/data/modify/Memo/delete", [pk], erupt: "Memo").last["success"]
    assert_equal [[:before_add, "a"], [:after_add, "a"], [:before_update, "b"], [:after_update, "b"],
                  [:before_delete, "b"], [:after_delete, "b"]], MemoProxy::CALLS
  end

  def test_link_tree
    titles = ->(body) { call("POST", "/erupt-api/data/table/Doc", body, erupt: "Doc")[1]["list"].map { |r| r["title"] } }
    assert_equal [], titles.({}), "dependNode: nothing until a tree node is picked"
    assert_equal ["b"], titles.({ "linkTreeVal" => [2] })
    assert_equal %w[a b], titles.({ "linkTreeVal" => %w[1 2] })
  end

  def test_field_types_and_invoke
    _, build = call("GET", "/erupt-api/build/Order", erupt: "Order")
    fields = build["eruptModel"]["eruptFieldModels"].to_h { |f| [f["fieldName"], f] }
    edit = fields.transform_values { |f| f["eruptFieldJson"]["edit"] }
    assert_equal ["invoke"], edit["status"]["choiceType"]["fetchHandler"]
    assert_equal ["invoke"], edit["tags"]["tagsType"]["fetchHandler"]
    assert_equal "invoke", edit["qty"]["onchange"]
    assert_equal %w[MARKDOWN ATTACHMENT BUTTON], [edit["body"]["type"], edit["files"]["type"], edit["calc"]["type"]]
    assert_equal %w[Category Category], [fields["cats"]["fieldReturnName"], fields["sections"]["fieldReturnName"]]

    invoke = ->(kind, field, form = {}, value = nil) { call("POST", "/erupt-api/invoke/Order/#{kind}/#{field}", { form: form, value: value }, erupt: "Order") }
    assert_equal [{ "value" => "new", "label" => "New" }, { "value" => "n", "label" => "From form" }], invoke.("options", "status", { note: "n" })[1]["data"]
    assert_equal %w[red blue], invoke.("options", "tags")[1]["data"]
    assert_equal({ "formData" => { "note" => "3 items" } }, invoke.("onchange", "qty", { qty: 3 })[1]["data"])
    assert_equal ["Paris"], invoke.("autocomplete", "city", {}, "pa")[1]["data"]
    assert_equal "alert(1)", invoke.("button", "calc")[1]["data"]["eval"]
    assert_equal [false, "not now"], invoke.("button", "stop")[1].values_at("success", "message")
    assert_equal 404, invoke.("button", "qty")[0], "a field without that code"
    assert_equal 404, invoke.("options", "missing")[0]

    # picked records arrive as [{id: key}] and are stored as their keys
    _, r = call("POST", "/erupt-api/data/modify/Order", { cats: [{ id: 1 }, { id: "2" }], sections: [{ id: 3 }], tags: '["red"]' }, erupt: "Order")
    assert r["success"], r
    row = call("POST", "/erupt-api/data/table/Order", {}, erupt: "Order")[1]["list"][0]
    assert_equal [[1, 2], [3]], row.values_at("cats", "sections")
    refute row.key?("calc")
  end

  def test_drill
    drill = { "HTTP_DRILL" => "Books", "HTTP_DRILLSOURCEERUPT" => "Author", "HTTP_DRILLVALUE" => "1" }
    _, page = call("POST", "/erupt-api/data/table/Book", {}, erupt: "Book", headers: drill)
    assert_equal %w[a c], page["list"].map { |r| r["title"] }
    assert_equal 403, call("POST", "/erupt-api/data/table/Book", {}, erupt: "Book", headers: drill.merge("HTTP_DRILL" => "x")).first
    _, build = call("GET", "/erupt-api/build/Author", erupt: "Author")
    drills = build["eruptModel"]["eruptJson"]["drills"]
    assert_equal [%w[Books Books Book]], drills.map { |d| [d["code"], d["title"], d["link"]["linkErupt"]] }
    refute drills.first["link"].key?("joinColumn")
  end

  def test_simple_types_and_depend_column
    _, build = call("GET", "/erupt-api/build/Book", erupt: "Book")
    edit = build["eruptModel"]["eruptFieldModels"].to_h { |f| [f["fieldName"], f["eruptFieldJson"]["edit"]] }
    assert_equal %w[COLOR RATE HIDDEN TRANSFER], edit.values_at("colour", "stars", "secret", "readers").map { |e| e["type"] }
    assert_equal "parent", edit["shelf"]["referenceTableType"]["dependColumn"], "the server reads it off the build"
    assert call("POST", "/erupt-api/data/modify/Book", { title: "d", stars: "4", readers: [{ id: 2 }] }, erupt: "Book").last["success"]
    row = call("POST", "/erupt-api/data/table/Book", {}, erupt: "Book").last["list"].last
    assert_equal [4, [2]], row.values_at("stars", "readers")
  end

  def test_node_config_and_user_info
    seen = []
    @node.define_singleton_method(:server_call) do |_method, path, headers: {}, **|
      seen << [path, headers["token"]]
      path.include?("userinfo") ? '{"account": "admin", "roles": ["r"]}' : "cfg"
    end
    assert_equal %w[cfg cfg], [@node.config, @node.group_config]
    assert_equal({ "account" => "admin", "roles" => ["r"] }, @node.user_info)
    assert_equal %w[/erupt-cloud-api/node-config/blog /erupt-cloud-api/node-group-config/blog /erupt-cloud-api/userinfo/blog],
                 seen.map(&:first)
  end

  def test_trusted_query
    # under a signed query, the server's own condition may name any stored field; an operator is still checked
    signed = lambda do |condition|
      body, user, ts = JSON.generate(condition: condition), "e30=", Time.now.to_i
      path = "/erupt-api/data/table/Article"
      env = { "REQUEST_METHOD" => "POST", "PATH_INFO" => path, "rack.input" => StringIO.new(body), "HTTP_ERUPT" => "Article",
              "HTTP_USER" => user, "HTTP_ERUPT_TIMESTAMP" => ts.to_s, "HTTP_ERUPT_ENFORCED" => "power,query",
              "HTTP_ERUPT_SIGNATURE" => Erupt::Signature.sign(TOKEN, "POST", path, ts, "power,query", user, body) }
      JSON.parse(@node.call(env).last.join)
    end
    add(title: "A", views: 1)
    add(title: "B", views: 2)
    assert_equal ["A"], titles(signed.call([{ key: "views", expression: "EQ", value: 1 }]))
    refute signed.call([{ key: "views", expression: "DROP", value: 1 }])["success"]
    refute call("POST", "/erupt-api/data/table/Article", { condition: [{ key: "views", expression: "EQ", value: 1 }] }).last["success"]
  end

  def test_before_fetch_needs_sql
    @node.register(Task, Erupt::MemoryRepository.new)
    assert_equal 500, call("POST", "/erupt-api/data/table/Task", {}, erupt: "Task").first
  end

  def test_reference
    # the picker is the server's: it reads the referenced model's own table
    assert_equal 404, call("POST", "/erupt-api/data/Article/reference-table/category", {}).first

    add(title: "Ref", category: { id: "2", name: "Python" }, topic: { id: 1, name: "Tech" })
    row = table["list"].first
    # a reference travels as its key; the server resolves labels and flattened columns
    assert_equal [2, 1], row.values_at("category", "topic")
    refute row.key?("category_name")
    assert_equal 2, call("GET", "/erupt-api/data/Article/#{row["id"]}").last["category"]
    assert_equal 1, table([{ key: "category", expression: "EQ", value: { id: 2, name: "Python" } }])["total"]
    assert_equal 0, table([{ key: "category", expression: "IN", value: [{ id: 1 }, { id: 3 }] }])["total"]
    _, r = call("POST", "/erupt-api/data/table/Article", { condition: [{ key: "category", expression: "LIKE", value: "x" }] })
    refute r["success"]
  end

  def test_reference_tree_is_the_servers
    assert_equal 404, call("GET", "/erupt-api/data/Article/reference-tree/topic").first
  end

  def test_operations
    add(title: "A")
    add(title: "B")
    ids = table["list"].map { |r| r["id"] }
    path = "/erupt-api/invoke/Article/operation/"
    refute call("POST", "#{path}publish", { ids: ids, param: {} }).last["success"] # the form's required note is missing
    _, r = call("POST", "#{path}publish", { ids: ids, param: { note: "go" } })
    assert_equal "Executed successfully", r["message"]
    assert_equal [[:publish, ids.sort, { "note" => "go" }]], CALLS
    assert_equal ["published"], table["list"].map { |x| x["status"] }.uniq
    refute call("POST", "#{path}feature", { ids: ids, param: nil }).last["success"] # SINGLE takes exactly one row
    assert_equal "alert('featured')", call("POST", "#{path}feature", { ids: ids.first(1), param: nil }).last["data"]
    refute call("POST", "#{path}publish", { ids: [], param: { note: "go" } }).last["success"]
    assert_equal 403, call("POST", "#{path}rebuild", { ids: nil, param: nil }).first
    assert call("POST", "#{path}rebuild", { ids: nil, param: nil }, account: "root").last["success"]
    assert_equal [:rebuild, [], nil], CALLS.last
    assert_equal 404, call("POST", "#{path}missing", {}).first
    form = "/erupt-api/invoke/Article/operation-form/"
    assert_equal({ "note" => nil }, call("POST", "#{form}publish", {}).last["data"])
    assert_nil call("POST", "#{form}feature", {}).last["data"] # an operation without a form
    assert_equal 404, call("POST", "/erupt-api/data/Article/operator/publish", { ids: ids }).first
  end

  def test_default_order
    add(title: "first")
    add(title: "second")
    assert_equal %w[second first], titles(table)
    assert_equal %w[first second], titles(table(sort: [{ field: "title", direction: "ASC" }]))
  end

  def test_rejects_illegal_input
    _, r = call("POST", "/erupt-api/data/modify/Article", { status: "draft" })
    refute r["success"]
    assert_includes r["message"], "Title"
    [{ title: "x", status: "deleted" }, { title: "x", views: "many" }, { title: "x", publish_date: "2026-02-30" }].each do |row|
      refute call("POST", "/erupt-api/data/modify/Article", row).last["success"], row
    end
    [{ condition: [{ key: "views", expression: "EQ", value: 1 }] }, { condition: [{ key: "title\" OR 1=1 --", value: 1 }] },
     { sort: [{ field: "body", direction: "ASC" }] }, { condition: [{ key: "title", expression: "DROP", value: 1 }] },
     { condition: ["title"] }].each do |body|
      refute call("POST", "/erupt-api/data/table/Article", body).last["success"], body
    end
    refute call("POST", "/erupt-api/data/modify/Article/delete", { id: 1 }).last["success"]
    refute call("GET", "/erupt-api/data/Article/abc").last["success"]
  end

  def test_internal_errors_hide_the_stack
    @node.models["Article"].last.define_singleton_method(:page) { |_q| raise "boom" }
    status, body = call("POST", "/erupt-api/data/table/Article", {})
    assert_equal [500, "boom", "erupt exception"], [status, body["message"], body["error"]]
  end
end

if SQLITE3
  class SqliteNodeTest < NodeTest
    def article_repo
      @db = SQLite3::Database.new(File.join(Dir.mktmpdir, "node.db"))
      Erupt::SqlRepository.new(Erupt::SqlExecutor.sqlite3(@db), "article", auto_create: true)
    end

    def widget_repo = Erupt::SqlRepository.new(Erupt::SqlExecutor.sqlite3(@db), "widget", auto_create: true)

    def test_before_fetch
      @node.register(Task, Erupt::SqlRepository.new(Erupt::SqlExecutor.sqlite3(@db), "task", auto_create: true))
      [["a", "admin", false], ["b", "admin", true], ["c", "root", false], ["a?", "admin", false]].each do |title, owner, done|
        call("POST", "/erupt-api/data/modify/Task", { title: title, owner: owner, done: done }, erupt: "Task")
      end
      _, page = call("POST", "/erupt-api/data/table/Task", {}, erupt: "Task")
      assert_equal ["a", "a?"], page["list"].map { |r| r["title"] }
      _, page = call("POST", "/erupt-api/data/table/Task", { condition: [{ key: "title", expression: "EQ", value: "a" }] },
                     erupt: "Task", account: "root")
      assert_equal [], page["list"]
      # a view's own filter and order run on the node, and stay out of the build
      _, page = call("POST", "/erupt-api/data/table/Task", { vis: "q" }, erupt: "Task")
      assert_equal ["a?"], page["list"].map { |r| r["title"] }
      _, page = call("POST", "/erupt-api/data/table/Task", { vis: "Reversed" }, erupt: "Task")
      assert_equal ["a?", "a"], page["list"].map { |r| r["title"] }
      _, build = call("GET", "/erupt-api/build/Task", erupt: "Task")
      vis = build["eruptModel"]["eruptJson"]["vis"]
      assert_equal [%w[q Question TABLE], %w[Reversed Reversed TABLE]], vis.map { |v| v.values_at("code", "title", "type") }
      assert(vis.none? { |v| v.key?("filter") || v.key?("orderBy") })
    end

    def test_like_escapes_wildcards
      add(title: "100% pure")
      add(title: "100 points")
      assert_equal ["100% pure"], titles(table([{ key: "title", expression: "LIKE", value: "100%" }]))
    end
  end
end

class DeclarationTest < Minitest::Test
  def declare(**erupt, &body)
    Class.new do
      extend Erupt::Model
      erupt "Bad", name: "Bad", **erupt
      field :id, pk: true
      class_eval(&body) if body
    end
  end

  def test_rejects_unknown_annotation_values
    {
      -> { declare { field :title, "T", edit: { inputTyp: { length: 9 } } } } => "Edit has no attribute 'inputTyp'",
      -> { declare { field :title, "T", view: { sortable: "yes" } } } => "expected boolean",
      -> { declare { field :title, "T", type: "INPUTT" } } => "is not a EditType",
      -> { declare { field :title, "T", edit: { search: { operator: "ABOUT" } } } } => "is not a QueryExpression",
      -> { declare { field :title, "T", Object } } => "cannot infer an edit type",
      -> { declare(orderBy: "id") } => "Erupt has no attribute 'orderBy'",
      -> { declare(layout: { pageSize: "10" }) } => "expected integer",
      -> { declare { field :id, pk: true } } => "declared twice",
      -> { declare { field :title, "T", click: ->(_form) {} } } => "click belong to",
      -> { declare { operation(:go, "Go", mode: "ALL") { nil } } } => "is not a RowOperationMode",
      -> { declare { operation(:go, "Go", colour: "red") { nil } } } => "RowOperation has no attribute 'colour'",
      -> { declare { operation(:go, "Go", form: String) { nil } } } => "form must be a model class",
      -> { Erupt::Node.new("n", "t", "http://s").register(declare(order_by: "missing desc"), Erupt::MemoryRepository.new) } => "illegal order_by"
    }.each do |declaration, message|
      error = assert_raises(ArgumentError) { declaration.call }
      assert_includes error.message, message
    end
  end

  def test_raw_attributes_pass_through
    cls = declare(layout: { pageSize: 30 }) { field :title, "T", edit: { inputType: { length: 9 } } }
    model = cls.erupt_model.build_erupt
    assert_equal 30, model["eruptJson"]["layout"]["pageSize"]
    assert_equal 9, model["eruptFieldModels"][1]["eruptFieldJson"]["edit"]["inputType"]["length"]
  end

  def test_coerce
    f = Erupt::Field.new(:at, "At", Time)
    assert_equal Time.new(2026, 1, 5, 10, 30, Rational(123, 1000)), f.coerce("2026-01-05T10:30:00.123Z")
    assert_equal Time.new(2026, 1, 5, 10, 30), f.coerce("2026-01-05 10:30")
    assert_raises(ArgumentError) { f.coerce("2026-13-01") }
    n = Erupt::Field.new(:n, "N", Float)
    assert_equal [3, 2.5, nil], [n.coerce("3"), n.coerce(2.5), n.coerce("")]
    assert_raises(ArgumentError) { n.coerce(true) }
  end

  def test_generated_files_are_current
    root = File.expand_path("..", __dir__)
    _, status = Open3.capture2e(RbConfig.ruby, File.join(root, "tools/gen_types.rb"), File.join(root, "../schema"), "--check")
    assert status.success?, "run ruby tools/gen_types.rb ../schema"
  end
end
