import base64
import datetime
import io
import json
import os
import tempfile
import unittest

from erupt import DataProxy, Fail, Field, current_user, MemoryRepository, Node, SqliteRepository, _schema, erupt, operation

TOKEN = "node-secret"


@erupt("Category")
class Category:
    id: int = Field(pk=True)
    name: str = Field("Name", search=True)
    parent: int = Field("Parent")


@erupt("Publish Options")
class PublishForm:
    note: str = Field("Note", not_null=True)


CALLS = []


@erupt("Article", order_by="id desc")
class Article:
    id: int = Field(pk=True)
    title: str = Field("Title", search=True, not_null=True, sortable=True)
    status: str = Field("Status", choices={"draft": "Draft", "published": "Published"}, search=True)
    views: int = Field("Views", sortable=True)
    featured: bool = Field("Featured", search=True)
    publish_date: datetime.date = Field("Publish Date", search=True)
    review_at: datetime.datetime = Field("Review At")
    body: str = Field("Body", type="TEXTAREA", table=False)
    category: Category = Field("Category", search=True)
    topic: Category = Field("Topic", tree="parent")

    @operation("Publish", form=PublishForm)
    def publish(op):
        CALLS.append(("publish", [r["id"] for r in op.rows], op.param))
        for row in op.rows:
            op.repo.update(row["id"], {"status": "published"})

    @operation("Feature", mode="SINGLE", confirm=False)
    def feature(op):
        return "alert('featured')"

    @operation("Rebuild", mode="BUTTON", show=lambda user: user and user["account"] == "root")
    def rebuild(op):
        CALLS.append(("rebuild", op.rows, op.param))


@erupt("Note", power={"delete": False})
class Note:
    id: int = Field(pk=True)
    text: str = Field("Text")


@erupt("Widget")
class Widget:
    id: int = Field(pk=True)
    name: str = Field("Name")
    basic = Field("Basic", type="INPUT", edit={"type": "DIVIDE"}, virtual=True)
    roles: list = Field("Roles", search=True, choices={"ADMIN": "Admin", "USER": "User", "GUEST": "Guest"},
                        edit={"type": "MULTI_CHOICE"})
    attrs: dict = Field("Attributes", edit={"type": "KEY_VALUE"})


class MemoProxy(DataProxy):
    calls = []

    def search_condition(self, condition):
        condition["text"] = "hi"

    def after_fetch(self, rows):
        for row in rows:
            row["text"] = row["text"].upper()

    def add_behavior(self, record):
        record["text"] = "new"

    def edit_behavior(self, record):
        record["text"] += "?"

    def validate(self, record):
        if record.get("text") == "forbidden":
            raise Fail("forbidden text")

    # the write hooks only record that they ran, with the text they saw
    def before_add(self, record):
        self.calls.append(("before_add", record["text"]))

    def after_add(self, record):
        self.calls.append(("after_add", record["text"]))

    def before_update(self, record):
        self.calls.append(("before_update", record["text"]))

    def after_update(self, record):
        self.calls.append(("after_update", record["text"]))

    def before_delete(self, record):
        self.calls.append(("before_delete", record["text"]))

    def after_delete(self, record):
        self.calls.append(("after_delete", record["text"]))


@erupt("Memo", data_proxy=MemoProxy)
class Memo:
    id: int = Field(pk=True)
    text: str = Field("Text")


class TaskProxy(DataProxy):
    def before_fetch(self, conditions):
        return "owner = ?", [current_user()["account"]]


class OpenProxy(DataProxy):
    def before_fetch(self, conditions):
        return "done = 0"


@erupt("Task", data_proxy=[TaskProxy, OpenProxy], vis=[
    {"code": "q", "title": "Question", "type": "TABLE", "filter": "title = 'a?'"},
    {"title": "Reversed", "type": "TABLE", "filter": ["1 = 1", "2 = 2"], "orderBy": "title desc"}])
class Task:
    id: int = Field(pk=True)
    title: str = Field("Title", search=True)
    owner: str = Field("Owner")
    done: bool = Field("Done")


@erupt("Doc", linkTree={"field": "topic", "dependNode": True})
class Doc:
    id: int = Field(pk=True)
    title: str = Field("Title")
    topic: Category = Field("Topic", tree="parent")


def _city(form, typed):
    return [c for c in ("Paris", "Tokyo") if typed.lower() in c.lower()]


def _refuse(form):
    raise Fail("not now")


@erupt("Order")
class Order:
    id: int = Field(pk=True)
    status: str = Field("Status", fetch=lambda form: {"new": "New", form.get("note") or "x": "From form"})
    tags: str = Field("Tags", type="TAGS", fetch=lambda form: ["red", "blue"])
    qty: int = Field("Qty", onchange=lambda form: {"formData": {"note": f"{form.get('qty')} items"}})
    note: str = Field("Note")
    city: str = Field("City", type="AUTO_COMPLETE", complete=_city)
    body: str = Field("Body", type="MARKDOWN")
    files: str = Field("Files", type="ATTACHMENT")
    cats: list = Field("Categories", type="CHECKBOX", ref=Category)
    sections: list = Field("Sections", type="TAB_TREE", ref=Category)
    calc = Field("Calc", type="BUTTON", click=lambda form: {"eval": "alert(1)", "formData": {"qty": 2}})
    stop = Field("Stop", type="BUTTON", click=_refuse)


class NodeTest(unittest.TestCase):
    repo_factory = staticmethod(lambda: MemoryRepository())
    widget_factory = staticmethod(lambda: MemoryRepository())

    def setUp(self):
        self.node = Node("blog", TOKEN, "http://server")
        self.remote = {"add": True, "edit": True, "delete": True, "viewDetails": True, "export": True, "importable": True}
        self.node._server_get = lambda path, params, headers: dict(self.remote)
        self.node.register(Category, MemoryRepository([
            {"name": "Tech", "parent": None}, {"name": "Python", "parent": 1}, {"name": "Life", "parent": None}]))
        self.node.register(Article, self.repo_factory())
        self.node.register(Note, MemoryRepository())
        self.node.register(Widget, self.widget_factory())
        self.node.register(Memo, MemoryRepository())
        self.node.register(Order, MemoryRepository())
        self.node.register(Doc, MemoryRepository([{"title": "a", "topic": 1}, {"title": "b", "topic": 2}, {"title": "c", "topic": 3}]))
        CALLS.clear()
        MemoProxy.calls.clear()

    def call(self, method, path, body=None, erupt="Article", headers=None, account="admin"):
        raw = b"" if body is None else json.dumps(body).encode()
        environ = {"REQUEST_METHOD": method, "PATH_INFO": path, "QUERY_STRING": "", "CONTENT_LENGTH": str(len(raw)),
                   "wsgi.input": io.BytesIO(raw), "HTTP_ACCESS_TOKEN": TOKEN, "HTTP_TOKEN": "t1",
                   "HTTP_USER": base64.b64encode(json.dumps({"uid": 1, "account": account}).encode()).decode()}
        if erupt:
            environ["HTTP_ERUPT"] = erupt
        environ.update(headers or {})
        out = {}
        payload = b"".join(self.node(environ, lambda status, h: out.update(status=int(status.split()[0]))))
        text = payload.decode()
        return out["status"], (json.loads(text) if text and text[0] in "{[" else text)

    def add(self, **row):
        status, r = self.call("POST", "/erupt-api/data/modify/Article", row)
        self.assertEqual(200, status)
        self.assertTrue(r["success"], r)

    def table(self, condition=(), sort=(), size=10):
        status, page = self.call("POST", "/erupt-api/data/table/Article",
                                 {"pageIndex": 1, "pageSize": size, "condition": list(condition), "sort": list(sort)})
        self.assertEqual(200, status, page)
        return page

    def test_build(self):
        status, build = self.call("GET", "/erupt-api/build/Article")
        self.assertEqual(200, status)
        model = build["eruptModel"]
        self.assertEqual("Article", model["eruptName"])
        fields = {f["fieldName"]: f for f in model["eruptFieldModels"]}
        types = {k: f["eruptFieldJson"]["edit"]["type"] for k, f in fields.items()}
        self.assertEqual({"id": "NUMBER", "title": "INPUT", "status": "CHOICE", "views": "NUMBER", "featured": "BOOLEAN",
                          "publish_date": "DATE", "review_at": "DATE", "body": "TEXTAREA",
                          "category": "REFERENCE_TABLE", "topic": "REFERENCE_TREE"}, types)
        self.assertEqual("Category", fields["category"]["fieldReturnName"])
        self.assertEqual({"dependField": "", "id": "id", "label": "name"}, fields["category"]["eruptFieldJson"]["edit"]["referenceTableType"])
        self.assertEqual("name", fields["category"]["eruptFieldJson"]["views"][0]["column"])
        self.assertEqual("parent", fields["topic"]["eruptFieldJson"]["edit"]["referenceTreeType"]["pid"])
        ops = {o["code"]: o for o in model["eruptJson"]["rowOperation"]}
        self.assertEqual(["publish", "feature"], list(ops))  # rebuild is hidden from admin
        self.assertEqual("PublishForm", ops["publish"]["eruptClass"])
        self.assertEqual("void", ops["feature"]["eruptClass"])
        self.assertEqual("", ops["feature"]["callHint"])
        self.assertEqual("SINGLE", ops["feature"]["mode"])
        self.assertEqual(["publish"], list(build["operationErupts"]))
        self.assertEqual(["note"], [f["fieldName"] for f in build["operationErupts"]["publish"]["eruptFieldModels"]])
        self.assertEqual("DATE_TIME", fields["review_at"]["eruptFieldJson"]["edit"]["dateType"]["type"])
        self.assertEqual("DATE", fields["publish_date"]["eruptFieldJson"]["views"][0]["type"])
        self.assertEqual([], fields["body"]["eruptFieldJson"]["views"])
        self.assertEqual(["draft", "published"], [v["value"] for v in fields["status"]["componentValue"]])
        self.assertTrue(fields["title"]["eruptFieldJson"]["edit"]["notNull"])
        self.assertTrue(build["power"]["export"])  # Excel is done by the server
        self.assertTrue(build["power"]["cellEdit"])  # the server edits the cell

    def test_power_is_declared_and_server(self):
        self.remote["add"] = False
        self.assertEqual(403, self.call("POST", "/erupt-api/data/modify/Article", {"title": "x"})[0])
        _, build = self.call("GET", "/erupt-api/build/Note", erupt="Note")
        self.assertFalse(build["power"]["delete"])
        self.assertEqual(403, self.call("POST", "/erupt-api/data/modify/Note/delete", [1], erupt="Note")[0])

    def test_power_fails_closed(self):
        def down(*args):
            raise OSError("server down")
        self.node._server_get = down
        self.assertEqual(403, self.call("POST", "/erupt-api/data/modify/Article", {"title": "x"})[0])

    def test_guards(self):
        self.assertEqual(403, self.call("GET", "/erupt-api/build/Article", headers={"HTTP_ORIGIN": "http://evil"})[0])
        self.assertEqual(403, self.call("GET", "/erupt-api/build/Article", headers={"HTTP_ACCESS_TOKEN": "bad"})[0])
        self.assertEqual(403, self.call("GET", "/erupt-api/build/Article", headers={"HTTP_ACCESS_TOKEN": ""})[0])
        self.assertEqual(404, self.call("GET", "/erupt-api/build/Missing", erupt="Missing")[0])
        self.assertEqual(404, self.call("GET", "/erupt-api/build/Article", erupt="Note")[0])
        self.assertEqual(404, self.call("GET", "/erupt-api/build/Article", headers={"HTTP_ERUPTPARENT": "blog.Note"})[0])
        self.assertEqual(200, self.call("GET", "/erupt-api/build/Article", headers={"HTTP_ERUPTPARENT": "blog.Article"})[0])
        self.assertEqual((200, "blog"), self.call("GET", "/node-health", erupt=None, headers={"HTTP_ACCESS_TOKEN": ""}))

    def test_crud(self):
        self.add(title="Hello erupt", status="published", views=10, featured=True, publish_date="2026-01-05",
                 review_at="2026-01-05 10:30:00", body="...")
        self.add(title="Second", status="draft", views="3", featured=False, publish_date="2026-03-01")
        page = self.table()
        self.assertEqual(2, page["total"])
        self.assertEqual(1, page["totalPage"])
        first = next(r for r in page["list"] if r["title"] == "Hello erupt")
        self.assertEqual("2026-01-05", first["publish_date"])
        self.assertEqual("2026-01-05T10:30:00.000", first["review_at"])
        self.assertEqual(10, first["views"])

        self.assertEqual(["Hello erupt"], [r["title"] for r in self.table([{"key": "title", "expression": "LIKE", "value": "hello"}])["list"]])
        self.assertEqual(["Second"], [r["title"] for r in self.table([{"key": "status", "expression": "EQ", "value": "draft"}])["list"]])
        self.assertEqual(["Hello erupt"], [r["title"] for r in self.table([{"key": "featured", "expression": "EQ", "value": True}])["list"]])
        ranged = self.table([{"key": "publish_date", "expression": "RANGE", "value": ["2026-02-01", "2026-12-31"]}])
        self.assertEqual(["Second"], [r["title"] for r in ranged["list"]])
        self.assertEqual(["Second", "Hello erupt"], [r["title"] for r in self.table(sort=[{"field": "views", "direction": "ASC"}])["list"]])

        pk = first["id"]
        status, row = self.call("GET", f"/erupt-api/data/Article/{pk}")
        self.assertEqual("Hello erupt", row["title"])
        _, r = self.call("POST", "/erupt-api/data/modify/Article/update", {**row, "title": "Renamed"})
        self.assertTrue(r["success"], r)
        self.assertEqual("Renamed", self.call("GET", f"/erupt-api/data/Article/{pk}")[1]["title"])
        _, r = self.call("POST", "/erupt-api/data/modify/Article/delete", [pk])
        self.assertTrue(r["success"])
        self.assertEqual(1, self.table()["total"])

    def test_virtual_and_json_fields(self):
        _, build = self.call("GET", "/erupt-api/build/Widget", erupt="Widget")
        fields = {f["fieldName"]: f["eruptFieldJson"]["edit"]["type"] for f in build["eruptModel"]["eruptFieldModels"]}
        self.assertEqual({"id": "NUMBER", "name": "INPUT", "basic": "DIVIDE", "roles": "MULTI_CHOICE", "attrs": "KEY_VALUE"}, fields)
        for row in ({"name": "A", "roles": ["ADMIN", "USER"], "attrs": {"env": "prod"}, "basic": "ignored"},
                    {"name": "B", "roles": ["GUEST"], "attrs": {}}):
            _, r = self.call("POST", "/erupt-api/data/modify/Widget", row, erupt="Widget")
            self.assertTrue(r["success"], r)
        _, page = self.call("POST", "/erupt-api/data/table/Widget", {"pageIndex": 1, "pageSize": 10}, erupt="Widget")
        a = next(r for r in page["list"] if r["name"] == "A")
        self.assertEqual((["ADMIN", "USER"], {"env": "prod"}), (a["roles"], a["attrs"]))
        self.assertNotIn("basic", a)
        _, r = self.call("POST", "/erupt-api/data/modify/Widget", {"name": "C", "roles": ["ROOT"]}, erupt="Widget")
        self.assertFalse(r["success"])
        self.assertEqual(["Admin", "User", "Guest"], [o["label"] for o in next(
            f for f in build["eruptModel"]["eruptFieldModels"] if f["fieldName"] == "roles")["componentValue"]])
        _, page = self.call("POST", "/erupt-api/data/table/Widget", {"condition": [{"key": "roles", "expression": "IN", "value": ["GUEST"]}]},
                            erupt="Widget")
        self.assertEqual(["B"], [r["name"] for r in page["list"]])
        _, r = self.call("GET", f"/erupt-api/data/Widget/{a['id']}", erupt="Widget")
        self.assertEqual(["ADMIN", "USER"], r["roles"])

    def test_data_proxy(self):
        _, build = self.call("GET", "/erupt-api/build/Memo", erupt="Memo")
        self.assertEqual({"text": "hi"}, build["eruptModel"]["searchCondition"])
        self.assertEqual("new", self.call("GET", "/erupt-api/data/init-value/Memo", erupt="Memo")[1]["text"])
        _, r = self.call("POST", "/erupt-api/data/modify/Memo", {"text": "forbidden"}, erupt="Memo")
        self.assertEqual((False, "forbidden text"), (r["success"], r["message"]))
        self.assertTrue(self.call("POST", "/erupt-api/data/modify/Memo", {"text": "a"}, erupt="Memo")[1]["success"])
        _, page = self.call("POST", "/erupt-api/data/table/Memo", {}, erupt="Memo")
        self.assertEqual(["A"], [row["text"] for row in page["list"]])
        pk = page["list"][0]["id"]
        self.assertEqual("a?", self.call("GET", f"/erupt-api/data/Memo/{pk}", erupt="Memo")[1]["text"])
        self.assertTrue(self.call("POST", "/erupt-api/data/modify/Memo/update", {"id": pk, "text": "b"}, erupt="Memo")[1]["success"])
        self.assertTrue(self.call("POST", "/erupt-api/data/modify/Memo/delete", [pk], erupt="Memo")[1]["success"])
        self.assertEqual([("before_add", "a"), ("after_add", "a"), ("before_update", "b"), ("after_update", "b"),
                          ("before_delete", "b"), ("after_delete", "b")], MemoProxy.calls)

    def test_link_tree(self):
        def titles(body):
            return [r["title"] for r in self.call("POST", "/erupt-api/data/table/Doc", body, erupt="Doc")[1]["list"]]
        self.assertEqual([], titles({}), "dependNode: nothing until a tree node is picked")
        self.assertEqual(["b"], titles({"linkTreeVal": [2]}))
        self.assertEqual(["a", "b"], titles({"linkTreeVal": ["1", "2"]}))

    def test_field_types_and_invoke(self):
        _, build = self.call("GET", "/erupt-api/build/Order", erupt="Order")
        fields = {f["fieldName"]: f for f in build["eruptModel"]["eruptFieldModels"]}
        edit = {name: f["eruptFieldJson"]["edit"] for name, f in fields.items()}
        self.assertEqual(["invoke"], edit["status"]["choiceType"]["fetchHandler"])
        self.assertEqual(["invoke"], edit["tags"]["tagsType"]["fetchHandler"])
        self.assertEqual("invoke", edit["qty"]["onchange"])
        self.assertEqual(("MARKDOWN", "ATTACHMENT", "BUTTON"), (edit["body"]["type"], edit["files"]["type"], edit["calc"]["type"]))
        self.assertEqual(("Category", "Category"), (fields["cats"]["fieldReturnName"], fields["sections"]["fieldReturnName"]))

        def invoke(kind, field, form=None, value=None):
            return self.call("POST", f"/erupt-api/invoke/Order/{kind}/{field}", {"form": form or {}, "value": value}, erupt="Order")

        self.assertEqual([{"value": "new", "label": "New"}, {"value": "n", "label": "From form"}],
                         invoke("options", "status", {"note": "n"})[1]["data"])
        self.assertEqual(["red", "blue"], invoke("options", "tags")[1]["data"])
        self.assertEqual({"formData": {"note": "3 items"}}, invoke("onchange", "qty", {"qty": 3})[1]["data"])
        self.assertEqual(["Paris"], invoke("autocomplete", "city", value="pa")[1]["data"])
        self.assertEqual("alert(1)", invoke("button", "calc")[1]["data"]["eval"])
        self.assertEqual((False, "not now"), (invoke("button", "stop")[1]["success"], invoke("button", "stop")[1]["message"]))
        self.assertEqual(404, invoke("button", "qty")[0], "a field without that code")
        self.assertEqual(404, invoke("options", "missing")[0])

        # picked records arrive as [{id: key}] and are stored as their keys
        self.assertTrue(self.call("POST", "/erupt-api/data/modify/Order",
                                  {"cats": [{"id": 1}, {"id": "2"}], "sections": [{"id": 3}], "tags": "[\"red\"]"}, erupt="Order")[1]["success"])
        row = self.call("POST", "/erupt-api/data/table/Order", {}, erupt="Order")[1]["list"][0]
        self.assertEqual(([1, 2], [3]), (row["cats"], row["sections"]))
        self.assertNotIn("calc", row)

    def test_before_fetch_needs_sql(self):
        self.node.register(Task, MemoryRepository())
        self.assertEqual(500, self.call("POST", "/erupt-api/data/table/Task", {}, erupt="Task")[0])

    def test_reference(self):
        # the picker is the server's: it reads the referenced model's own table
        self.assertEqual(404, self.call("POST", "/erupt-api/data/Article/reference-table/category", {})[0])

        self.add(title="Ref", category={"id": "2", "name": "Python"}, topic={"id": 1, "name": "Tech"})
        row = self.table()["list"][0]
        # a reference travels as its key; the server resolves labels and flattened columns
        self.assertEqual((2, 1), (row["category"], row["topic"]))
        self.assertNotIn("category_name", row)
        _, got = self.call("GET", f"/erupt-api/data/Article/{row['id']}")
        self.assertEqual(2, got["category"])
        hit = self.table([{"key": "category", "expression": "EQ", "value": {"id": 2, "name": "Python"}}])
        self.assertEqual(1, hit["total"])
        miss = self.table([{"key": "category", "expression": "IN", "value": [{"id": 1}, {"id": 3}]}])
        self.assertEqual(0, miss["total"])
        _, r = self.call("POST", "/erupt-api/data/table/Article", {"condition": [{"key": "category", "expression": "LIKE", "value": "x"}]})
        self.assertFalse(r["success"])

    def test_reference_tree_is_the_servers(self):
        self.assertEqual(404, self.call("GET", "/erupt-api/data/Article/reference-tree/topic")[0])

    def test_operations(self):
        self.add(title="A")
        self.add(title="B")
        ids = [r["id"] for r in self.table()["list"]]
        path = "/erupt-api/invoke/Article/operation/"
        _, r = self.call("POST", path + "publish", {"ids": ids, "param": {}})
        self.assertFalse(r["success"])  # the form's required note is missing
        _, r = self.call("POST", path + "publish", {"ids": ids, "param": {"note": "go"}})
        self.assertTrue(r["success"], r)
        self.assertEqual("Executed successfully", r["message"])
        self.assertEqual([("publish", sorted(ids), {"note": "go"})], [(c[0], sorted(c[1]), c[2]) for c in CALLS])
        self.assertEqual({"published"}, {r["status"] for r in self.table()["list"]})
        _, r = self.call("POST", path + "feature", {"ids": ids, "param": None})
        self.assertFalse(r["success"])  # SINGLE takes exactly one row
        _, r = self.call("POST", path + "feature", {"ids": ids[:1], "param": None})
        self.assertEqual("alert('featured')", r["data"])
        _, r = self.call("POST", path + "publish", {"ids": [], "param": {"note": "go"}})
        self.assertFalse(r["success"])
        self.assertEqual(403, self.call("POST", path + "rebuild", {"ids": None, "param": None})[0])
        _, r = self.call("POST", path + "rebuild", {"ids": None, "param": None}, account="root")
        self.assertTrue(r["success"])
        self.assertEqual(("rebuild", [], None), CALLS[-1])
        self.assertEqual(404, self.call("POST", path + "missing", {})[0])
        form = "/erupt-api/invoke/Article/operation-form/"
        self.assertEqual({"note": None}, self.call("POST", form + "publish", {})[1]["data"])
        self.assertIsNone(self.call("POST", form + "feature", {})[1]["data"], "an operation without a form")
        self.assertEqual(404, self.call("POST", "/erupt-api/data/Article/operator/publish", {"ids": ids})[0])

    def test_default_order(self):
        self.add(title="first")
        self.add(title="second")
        self.assertEqual(["second", "first"], [r["title"] for r in self.table()["list"]])
        self.assertEqual(["first", "second"], [r["title"] for r in self.table(sort=[{"field": "title", "direction": "ASC"}])["list"]])

    def test_build_matches_schema(self):
        for name in ("Article", "Note"):
            _, build = self.call("GET", f"/erupt-api/build/{name}", erupt=name)
            models = [build["eruptModel"], *(build["operationErupts"] or {}).values()]
            for model in models:
                _schema.check("Erupt", model["eruptJson"], model["eruptName"], partial=False)
                for op in model["eruptJson"]["rowOperation"]:
                    _schema.check("RowOperation", op, f"{model['eruptName']}.{op['code']}", partial=False)
                for f in model["eruptFieldModels"]:
                    _schema.check("EruptField", f["eruptFieldJson"], f"{model['eruptName']}.{f['fieldName']}", partial=False)

    def test_rejects_illegal_input(self):
        _, r = self.call("POST", "/erupt-api/data/modify/Article", {"status": "draft"})
        self.assertFalse(r["success"])
        self.assertIn("Title", r["message"])
        _, r = self.call("POST", "/erupt-api/data/modify/Article", {"title": "x", "status": "deleted"})
        self.assertFalse(r["success"])
        _, r = self.call("POST", "/erupt-api/data/table/Article", {"condition": [{"key": "views", "expression": "EQ", "value": 1}]})
        self.assertFalse(r["success"])
        _, r = self.call("POST", "/erupt-api/data/table/Article", {"condition": [{"key": "title\" OR 1=1 --", "value": 1}]})
        self.assertFalse(r["success"])
        _, r = self.call("POST", "/erupt-api/data/table/Article", {"sort": [{"field": "body", "direction": "ASC"}]})
        self.assertFalse(r["success"])
        _, r = self.call("POST", "/erupt-api/data/table/Article", {"condition": [{"key": "title", "expression": "DROP", "value": 1}]})
        self.assertFalse(r["success"])


class SqliteNodeTest(NodeTest):

    def setUp(self):
        self.db = tempfile.NamedTemporaryFile(suffix=".db", delete=False).name
        self.repo_factory = lambda: SqliteRepository(self.db, "article")
        self.widget_factory = lambda: SqliteRepository(self.db, "widget")
        super().setUp()

    def tearDown(self):
        os.remove(self.db)

    def test_before_fetch(self):
        self.node.register(Task, SqliteRepository(self.db, "task"))
        for title, owner, done in [("a", "admin", False), ("b", "admin", True), ("c", "root", False), ("a?", "admin", False)]:
            self.call("POST", "/erupt-api/data/modify/Task", {"title": title, "owner": owner, "done": done}, erupt="Task")
        _, page = self.call("POST", "/erupt-api/data/table/Task", {}, erupt="Task")
        self.assertEqual(["a", "a?"], [r["title"] for r in page["list"]])
        _, page = self.call("POST", "/erupt-api/data/table/Task", {"condition": [{"key": "title", "expression": "EQ", "value": "a"}]},
                            erupt="Task", account="root")
        self.assertEqual([], page["list"])
        # a view's own filter and order run on the node, and stay out of the build
        _, page = self.call("POST", "/erupt-api/data/table/Task", {"vis": "q"}, erupt="Task")
        self.assertEqual(["a?"], [r["title"] for r in page["list"]])
        _, page = self.call("POST", "/erupt-api/data/table/Task", {"vis": "Reversed"}, erupt="Task")
        self.assertEqual(["a?", "a"], [r["title"] for r in page["list"]])
        _, build = self.call("GET", "/erupt-api/build/Task", erupt="Task")
        self.assertEqual([{"code": "q", "title": "Question", "type": "TABLE"}, {"code": "Reversed", "title": "Reversed", "type": "TABLE"}],
                         [{k: v[k] for k in ("code", "title", "type")} for v in build["eruptModel"]["eruptJson"]["vis"]])
        self.assertFalse(any("filter" in v or "orderBy" in v for v in build["eruptModel"]["eruptJson"]["vis"]))

    def test_like_escapes_wildcards(self):
        self.add(title="100% pure")
        self.add(title="100 points")
        self.assertEqual(["100% pure"], [r["title"] for r in self.table([{"key": "title", "expression": "LIKE", "value": "100%"}])["list"]])


class DeclarationTest(unittest.TestCase):

    def declare(self, **attrs):
        return type("Bad", (), {"id": Field(pk=True), **attrs})

    def test_rejects_unknown_annotation_values(self):
        cases = [
            ({"title": Field("T", edit={"inputTyp": {"length": 9}})}, {}, "Edit has no attribute 'inputTyp'"),
            ({"title": Field("T", view={"sortable": "yes"})}, {}, "expected boolean"),
            ({"title": Field("T", type="INPUTT")}, {}, "is not a EditType"),
            ({"title": Field("T", edit={"search": {"operator": "ABOUT"}})}, {}, "is not a QueryExpression"),
            ({}, {"orderBy": "id"}, "Erupt has no attribute 'orderBy'"),
            ({}, {"layout": {"pageSize": "10"}}, "expected integer"),
            ({}, {"order_by": "missing desc"}, "illegal order_by"),
        ]
        for attrs, kwargs, message in cases:
            with self.subTest(message), self.assertRaisesRegex(ValueError, message):
                erupt("Bad", **kwargs)(self.declare(**attrs))
        with self.assertRaisesRegex(ValueError, "is not a RowOperationMode"):
            operation("Go", mode="ALL")(lambda op: None)
        with self.assertRaisesRegex(ValueError, "RowOperation has no attribute 'colour'"):
            operation("Go", colour="red")(lambda op: None)

    def test_raw_attributes_pass_through(self):
        cls = erupt("Ok", layout={"pageSize": 30})(self.declare(title=Field("T", edit={"inputType": {"length": 9}})))
        model = cls.__erupt__.build_erupt()
        self.assertEqual(30, model["eruptJson"]["layout"]["pageSize"])
        self.assertEqual(9, model["eruptFieldModels"][1]["eruptFieldJson"]["edit"]["inputType"]["length"])

    def test_generated_types_are_current(self):
        import importlib.util, pathlib
        root = pathlib.Path(__file__).resolve().parent.parent
        spec = importlib.util.spec_from_file_location("gen_types", root / "tools" / "gen_types.py")
        gen = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(gen)
        schema = json.loads((root / "src" / "erupt" / "_schema.json").read_text("utf-8"))
        self.assertEqual(gen.generate(schema), (root / "src" / "erupt" / "_types.py").read_text("utf-8"))


if __name__ == "__main__":
    unittest.main()
