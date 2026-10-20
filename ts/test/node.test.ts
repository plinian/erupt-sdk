import assert from "node:assert/strict";
import { createServer, type Server } from "node:http";
import type { AddressInfo } from "node:net";
import { after, test } from "node:test";
import { type EruptRecord, Fail, field, MemoryRepository, model, Node, operation, type Repository } from "../src/index.js";

const listen = (server: Server) => new Promise<string>((resolve) =>
  server.listen(0, "127.0.0.1", () => resolve(`http://127.0.0.1:${(server.address() as AddressInfo).port}`)));

const servers: Server[] = [];
after(() => servers.forEach((s) => s.close()));

test("listener serves a model behind any http server", async () => {
  // the erupt server only answers erupt-power here
  const erupt = createServer((_req, res) => res.end(JSON.stringify({ add: true, edit: true, delete: true, viewDetails: true })));
  servers.push(erupt);
  const node = new Node("t", "secret", await listen(erupt));
  node.register(model("Item", { id: field.pk(), name: field.input("Name", { notNull: true }) }), new MemoryRepository());
  const app = createServer(node.listener);
  servers.push(app);
  const base = await listen(app);
  const call = async (path: string, body?: unknown, headers: Record<string, string> = {}) => {
    const res = await fetch(base + path, {
      method: body === undefined ? "GET" : "POST", body: body === undefined ? undefined : JSON.stringify(body),
      headers: { "access-token": "secret", erupt: "Item", token: "t", ...headers },
    });
    return [res.status, (await res.json().catch(() => null)) as any] as const;
  };
  assert.deepEqual(await call("/erupt-api/data/modify/Item", { name: "a" }), [200, { success: true, status: "SUCCESS", message: null, data: null, promptWay: "MESSAGE" }]);
  assert.equal((await call("/erupt-api/data/modify/Item", {}))[1].message, "Name cannot be empty");
  const [, page] = await call("/erupt-api/data/table/Item", { pageIndex: 1, pageSize: 10 });
  assert.deepEqual(page.list, [{ id: 1, name: "a" }]);
  assert.equal((await call("/erupt-api/build/Item", undefined, { "access-token": "secreT" }))[0], 403);
});

test("virtual and JSON fields", async () => {
  const { mkdtempSync } = await import("node:fs");
  const { tmpdir } = await import("node:os");
  const { join } = await import("node:path");
  const { SqliteRepository } = await import("../src/index.js");
  const erupt = createServer((_req, res) => res.end(JSON.stringify({ add: true, edit: true, delete: true, viewDetails: true })));
  servers.push(erupt);
  const db = join(mkdtempSync(join(tmpdir(), "erupt-ts-")), "w.db");
  const server = await listen(erupt);
  for (const repo of [new MemoryRepository(), new SqliteRepository(db, "widget")]) {
    const node = new Node("t", "secret", server);
    node.register(model("Widget", {
      id: field.pk(),
      name: field.input("Name"),
      basic: field.input("Basic", { virtual: true, edit: { type: "DIVIDE" } }),
      roles: field.json("Roles", { search: true, edit: { type: "MULTI_CHOICE" } }, { ADMIN: "Admin", USER: "User", GUEST: "Guest" }),
      attrs: field.json("Attributes", { edit: { type: "KEY_VALUE" } }),
    }), repo);
    const app = createServer(node.listener);
    servers.push(app);
    const base = await listen(app);
    const call = async (path: string, body?: unknown) => {
      const res = await fetch(base + path, {
        method: body === undefined ? "GET" : "POST", body: body === undefined ? undefined : JSON.stringify(body),
        headers: { "access-token": "secret", erupt: "Widget", token: "t" },
      });
      return (await res.json()) as any;
    };
    const build = await call("/erupt-api/build/Widget");
    const fields = build.eruptModel.eruptFieldModels;
    assert.deepEqual(fields.map((f: any) => [f.fieldName, f.eruptFieldJson.edit.type]),
      [["id", "NUMBER"], ["name", "INPUT"], ["basic", "DIVIDE"], ["roles", "MULTI_CHOICE"], ["attrs", "KEY_VALUE"]]);
    assert.deepEqual(fields[3].componentValue.map((o: any) => o.label), ["Admin", "User", "Guest"]);
    assert.equal((await call("/erupt-api/data/modify/Widget", { name: "A", roles: ["ADMIN", "USER"], attrs: { env: "prod" }, basic: "x" })).success, true);
    assert.equal((await call("/erupt-api/data/modify/Widget", { name: "B", roles: ["GUEST"], attrs: {} })).success, true);
    assert.equal((await call("/erupt-api/data/modify/Widget", { name: "C", roles: ["ROOT"] })).success, false);
    const page = await call("/erupt-api/data/table/Widget", { pageIndex: 1, pageSize: 10 });
    assert.deepEqual(page.list[0], { id: 1, name: "A", roles: ["ADMIN", "USER"], attrs: { env: "prod" } });
    const found = await call("/erupt-api/data/table/Widget", { condition: [{ key: "roles", expression: "IN", value: ["GUEST"] }] });
    assert.deepEqual(found.list.map((r: any) => r.name), ["B"]);
    assert.deepEqual((await call("/erupt-api/data/Widget/1")).attrs, { env: "prod" });
  }
});

test("data proxy", async () => {
  const erupt = createServer((_req, res) => res.end(JSON.stringify({ add: true, edit: true, delete: true, viewDetails: true })));
  servers.push(erupt);
  const node = new Node("t", "secret", await listen(erupt));
  // the write hooks only record that they ran, with the text they saw
  const calls: [string, unknown][] = [];
  const write = (name: string) => (record: EruptRecord) => void calls.push([name, record.text]);
  node.register(model("Memo", { id: field.pk(), text: field.input("Text") }, {
    dataProxy: {
      searchCondition: (condition) => void (condition.text = "hi"),
      afterFetch: (rows) => rows.forEach((row) => (row.text = String(row.text).toUpperCase())),
      addBehavior: (record) => void (record.text = "new"),
      editBehavior: (record) => void (record.text += "?"),
      validate: (record) => {
        if (record.text === "forbidden") throw new Fail("forbidden text");
      },
      beforeAdd: write("beforeAdd"), afterAdd: write("afterAdd"),
      beforeUpdate: write("beforeUpdate"), afterUpdate: write("afterUpdate"),
      beforeDelete: write("beforeDelete"), afterDelete: write("afterDelete"),
    },
  }), new MemoryRepository());
  const app = createServer(node.listener);
  servers.push(app);
  const base = await listen(app);
  const call = async (path: string, body?: unknown) => {
    const res = await fetch(base + path, {
      method: body === undefined ? "GET" : "POST", body: body === undefined ? undefined : JSON.stringify(body),
      headers: { "access-token": "secret", erupt: "Memo", token: "t" },
    });
    return (await res.json()) as any;
  };
  assert.deepEqual((await call("/erupt-api/build/Memo")).eruptModel.searchCondition, { text: "hi" });
  assert.equal((await call("/erupt-api/data/init-value/Memo")).text, "new");
  const refused = await call("/erupt-api/data/modify/Memo", { text: "forbidden" });
  assert.deepEqual([refused.success, refused.message], [false, "forbidden text"]);
  assert.equal((await call("/erupt-api/data/modify/Memo", { text: "a" })).success, true);
  const page = await call("/erupt-api/data/table/Memo", {});
  assert.deepEqual(page.list.map((row: any) => row.text), ["A"]);
  const pk = page.list[0].id;
  assert.equal((await call(`/erupt-api/data/Memo/${pk}`)).text, "a?");
  assert.equal((await call("/erupt-api/data/modify/Memo/update", { id: pk, text: "b" })).success, true);
  assert.equal((await call("/erupt-api/data/modify/Memo/delete", [pk])).success, true);
  assert.deepEqual(calls, [["beforeAdd", "a"], ["afterAdd", "a"], ["beforeUpdate", "b"], ["afterUpdate", "b"],
    ["beforeDelete", "b"], ["afterDelete", "b"]]);
});

test("link tree", async () => {
  const erupt = createServer((_req, res) => res.end(JSON.stringify({ add: true, edit: true, delete: true, viewDetails: true })));
  servers.push(erupt);
  const node = new Node("t", "secret", await listen(erupt));
  const category = model("Category", { id: field.pk(), name: field.input("Name"), parent: field.number("Parent") });
  node.register(model("Doc", { id: field.pk(), title: field.input("Title"), topic: field.ref(category, "Topic", { tree: "parent" }) }, {
    erupt: { linkTree: { field: "topic", dependNode: true } },
  }), new MemoryRepository([{ title: "a", topic: 1 }, { title: "b", topic: 2 }, { title: "c", topic: 3 }]));
  const app = createServer(node.listener);
  servers.push(app);
  const base = await listen(app);
  const titles = async (body: unknown) => {
    const res = await fetch(base + "/erupt-api/data/table/Doc", {
      method: "POST", body: JSON.stringify(body), headers: { "access-token": "secret", erupt: "Doc", token: "t" },
    });
    return ((await res.json()) as any).list.map((r: any) => r.title);
  };
  assert.deepEqual(await titles({}), [], "dependNode: nothing until a tree node is picked");
  assert.deepEqual(await titles({ linkTreeVal: [2] }), ["b"]);
  assert.deepEqual(await titles({ linkTreeVal: ["1", "2"] }), ["a", "b"]);
});

test("field types and invoke", async () => {
  const erupt = createServer((_req, res) => res.end(JSON.stringify({ add: true, edit: true, delete: true, viewDetails: true })));
  servers.push(erupt);
  const node = new Node("t", "secret", await listen(erupt));
  const category = model("Category", { id: field.pk(), name: field.input("Name"), parent: field.number("Parent") });
  node.register(category, new MemoryRepository());
  node.register(model("Order", {
    id: field.pk(),
    status: field.choice("Status", {}, { fetch: (form) => ({ new: "New", [form.note ?? "x"]: "From form" }) }),
    tags: field.of("TAGS", "Tags", { fetch: () => ["red", "blue"] }),
    qty: field.number("Qty", { onchange: (form) => ({ formData: { note: `${form.qty} items` } }) }),
    note: field.input("Note"),
    city: field.of("AUTO_COMPLETE", "City", { complete: async (_form, typed) => ["Paris", "Tokyo"].filter((c) => c.toLowerCase().includes(typed.toLowerCase())) }),
    body: field.of("MARKDOWN", "Body"),
    files: field.of("ATTACHMENT", "Files"),
    cats: field.checkbox(category, "Categories"),
    sections: field.tabTree(category, "Sections"),
    calc: field.button("Calc", () => ({ eval: "alert(1)", formData: { qty: 2 } })),
    stop: field.button("Stop", () => {
      throw new Fail("not now");
    }),
  }, {
    operations: {
      approve: operation("Approve", { form: model("ApproveForm", { reason: field.input("Reason") }) }, (op) => `approved:${op.param?.reason}`),
      archive: operation("Archive", { mode: "BUTTON" }, () => undefined),
      hidden: operation("Hidden", { mode: "BUTTON", show: () => false }, () => undefined),
    },
  }), new MemoryRepository());
  const app = createServer(node.listener);
  servers.push(app);
  const base = await listen(app);
  const call = async (path: string, body?: unknown) => {
    const res = await fetch(base + path, {
      method: body === undefined ? "GET" : "POST", body: body === undefined ? undefined : JSON.stringify(body),
      headers: { "access-token": "secret", erupt: "Order", token: "t" },
    });
    return [res.status, (await res.json().catch(() => null)) as any] as const;
  };
  const [, build] = await call("/erupt-api/build/Order");
  const fields = Object.fromEntries(build.eruptModel.eruptFieldModels.map((f: any) => [f.fieldName, f]));
  const edit = (name: string) => fields[name].eruptFieldJson.edit;
  assert.deepEqual(edit("status").choiceType.fetchHandler, ["invoke"]);
  assert.deepEqual(edit("tags").tagsType.fetchHandler, ["invoke"]);
  assert.equal(edit("qty").onchange, "invoke");
  assert.deepEqual([edit("body").type, edit("files").type, edit("calc").type], ["MARKDOWN", "ATTACHMENT", "BUTTON"]);
  assert.deepEqual([fields.cats.fieldReturnName, fields.sections.fieldReturnName], ["Category", "Category"]);

  const invoke = async (kind: string, field: string, form: object = {}, value?: string) =>
    call(`/erupt-api/invoke/Order/${kind}/${field}`, { form, value });
  assert.deepEqual((await invoke("options", "status", { note: "n" }))[1].data, [{ value: "new", label: "New" }, { value: "n", label: "From form" }]);
  assert.deepEqual((await invoke("options", "tags"))[1].data, ["red", "blue"]);
  assert.deepEqual((await invoke("onchange", "qty", { qty: 3 }))[1].data, { formData: { note: "3 items" } });
  assert.deepEqual((await invoke("autocomplete", "city", {}, "pa"))[1].data, ["Paris"]);
  assert.equal((await invoke("button", "calc"))[1].data.eval, "alert(1)");
  const [, refused] = await invoke("button", "stop");
  assert.deepEqual([refused.success, refused.message], [false, "not now"]);
  assert.equal((await invoke("button", "qty"))[0], 404, "a field without that code");
  assert.equal((await invoke("options", "missing"))[0], 404);

  // a row operation and its form values run through invoke too, under the operation code
  const op = "/erupt-api/invoke/Order/operation/";
  assert.deepEqual((await call(op + "archive", { ids: null, param: null }))[1].message, "Executed successfully");
  assert.equal((await call(op + "hidden", {}))[0], 403);
  assert.equal((await call(op + "missing", {}))[0], 404);
  const form = "/erupt-api/invoke/Order/operation-form/";
  assert.deepEqual((await call(form + "approve", {}))[1].data, { reason: null });
  assert.equal((await call(form + "archive", {}))[1].data, null, "an operation without a form");
  assert.equal((await call("/erupt-api/data/Order/operator/archive", {}))[0], 404);
  assert.equal((await call("/erupt-api/data/Order/operator/approve/form-value", {}))[0], 404);
  assert.equal((await call("/erupt-api/data/Order/reference-table/cats", {}))[0], 404);

  // picked records arrive as [{id: key}] and are stored as their keys
  assert.equal((await call("/erupt-api/data/modify/Order", { cats: [{ id: 1 }, { id: "2" }], sections: [{ id: 3 }], tags: "[\"red\"]" }))[1].success, true);
  const [, page] = await call("/erupt-api/data/table/Order", {});
  assert.deepEqual([page.list[0].cats, page.list[0].sections], [[1, 2], [3]]);
  assert.ok(!("calc" in page.list[0]));
});

test("before fetch", async () => {
  const { mkdtempSync } = await import("node:fs");
  const { tmpdir } = await import("node:os");
  const { join } = await import("node:path");
  const { currentUser, SqliteRepository } = await import("../src/index.js");
  const erupt = createServer((_req, res) => res.end(JSON.stringify({ add: true, edit: true, delete: true, viewDetails: true })));
  servers.push(erupt);
  const server = await listen(erupt);
  const task = () => model("Task", {
    id: field.pk(), title: field.input("Title", { search: true }), owner: field.input("Owner"), done: field.boolean("Done"),
  }, {
    dataProxy: [{ beforeFetch: () => ["owner = ?", [currentUser()!.account]] }, { beforeFetch: () => "done = 0" }],
    erupt: { vis: [
      { code: "q", title: "Question", type: "TABLE", filter: "title = 'a?'" },
      { title: "Reversed", type: "TABLE", filter: ["1 = 1", "2 = 2"], orderBy: "title desc" },
    ] },
  });
  const serve = async (repo: Repository) => {
    const node = new Node("t", "secret", server);
    node.register(task(), repo);
    const app = createServer(node.listener);
    servers.push(app);
    const base = await listen(app);
    return async (path: string, body: unknown, account = "admin") => {
      const res = await fetch(base + path, {
        method: "POST", body: JSON.stringify(body),
        headers: { "access-token": "secret", erupt: "Task", token: "t", user: Buffer.from(JSON.stringify({ account })).toString("base64") },
      });
      return [res.status, (await res.json().catch(() => null)) as any] as const;
    };
  };
  const call = await serve(new SqliteRepository(join(mkdtempSync(join(tmpdir(), "erupt-ts-")), "t.db"), "task"));
  for (const [title, owner, done] of [["a", "admin", false], ["b", "admin", true], ["c", "root", false], ["a?", "admin", false]]) {
    await call("/erupt-api/data/modify/Task", { title, owner, done });
  }
  const [, page] = await call("/erupt-api/data/table/Task", {});
  assert.deepEqual([page.total, page.list.map((r: any) => r.title)], [2, ["a", "a?"]]);
  const [, found] = await call("/erupt-api/data/table/Task", { condition: [{ key: "title", expression: "EQ", value: "a" }] }, "root");
  assert.deepEqual(found.list, []);
  // a view's own filter and order run on the node, and stay out of the build
  assert.deepEqual((await call("/erupt-api/data/table/Task", { vis: "q" }))[1].list.map((r: any) => r.title), ["a?"]);
  assert.deepEqual((await call("/erupt-api/data/table/Task", { vis: "Reversed" }))[1].list.map((r: any) => r.title), ["a?", "a"]);
  const vis = task().buildErupt().eruptJson.vis;
  assert.deepEqual(vis.map((v: any) => [v.code, v.title, v.type]), [["q", "Question", "TABLE"], ["Reversed", "Reversed", "TABLE"]]);
  assert.ok(!vis.some((v: any) => "filter" in v || "orderBy" in v));
  // the memory repository cannot run SQL: it refuses rather than shows every row
  assert.equal((await (await serve(new MemoryRepository()))("/erupt-api/data/table/Task", {}))[0], 500);
});
