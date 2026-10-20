import assert from "node:assert/strict";
import { createServer, type Server } from "node:http";
import type { AddressInfo } from "node:net";
import { after, test } from "node:test";
import { type EruptRecord, Fail, field, MemoryRepository, model, Node, type Repository } from "../src/index.js";

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
