import assert from "node:assert/strict";
import { mkdtempSync, rmSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { after, test } from "node:test";
import { DatabaseSync } from "node:sqlite";
import {
  field, MemoryRepository, model, type Query, type Repository, type SqlDialect, type SqlExecutor, SqliteRepository, sqliteExecutor,
  SqlRepository,
} from "../src/index.js";

const Item = model("Item", {
  id: field.pk(), name: field.input("Name", { search: true }), n: field.number("N"), ok: field.boolean("Ok"), d: field.date("D"),
});

const dir = mkdtempSync(join(tmpdir(), "erupt-ts-"));
after(() => rmSync(dir, { recursive: true, force: true }));

const query = (q: Partial<Query> = {}): Query => ({ conditions: [], sort: [["id", false]], offset: 0, limit: 100, ...q });

for (const [kind, create] of [
  ["memory", () => new MemoryRepository()],
  ["sqlite", () => new SqliteRepository(join(dir, `t${Math.random()}.db`), "item")],
  ["sql over an executor", () => new SqlRepository(sqliteExecutor(new DatabaseSync(join(dir, `e${Math.random()}.db`))), "item",
    { dialect: "sqlite", autoCreate: true })],
] as [string, () => Repository][]) {
  test(`${kind} repository`, async () => {
    const repo = create();
    repo.bind(Item);
    for (const r of [
      { name: "100% pure", n: 1, ok: true, d: "2026-01-01" },
      { name: "100 points", n: 2, ok: false, d: "2026-02-01" },
      { name: "under_score", n: null, ok: null, d: null },
      { name: "bang!x", n: 4, ok: false, d: null },
    ]) await repo.add(r);
    const names = async (q: Partial<Query>) => (await repo.page(query(q)))[1].map((r) => r.name);
    assert.deepEqual(await names({ conditions: [{ field: "name", op: "LIKE", value: "100%" }] }), ["100% pure"]);
    assert.deepEqual(await names({ conditions: [{ field: "name", op: "LIKE", value: "r_s" }] }), ["under_score"]);
    assert.deepEqual(await names({ conditions: [{ field: "name", op: "LIKE", value: "g!x" }] }), ["bang!x"]);
    assert.deepEqual(await names({ sort: [] }), ["100% pure", "100 points", "under_score", "bang!x"], "no sort: primary key ascending");
    assert.deepEqual(await names({ conditions: [{ field: "name", op: "NOT_LIKE", value: "100" }] }), ["under_score", "bang!x"]);
    assert.deepEqual(await names({ conditions: [{ field: "n", op: "IN", value: [2, 3] }] }), ["100 points"]);
    assert.deepEqual(await names({ conditions: [{ field: "n", op: "IN", value: [] }] }), []);
    assert.deepEqual(await names({ conditions: [{ field: "n", op: "NULL" }] }), ["under_score"]);
    assert.deepEqual(await names({ conditions: [{ field: "n", op: "GTE", value: 2 }] }), ["100 points", "bang!x"]);
    assert.deepEqual(await names({ conditions: [{ field: "d", op: "RANGE", value: ["2026-01-15", "2026-12-31"] }] }), ["100 points"]);
    assert.deepEqual(await names({ conditions: [{ field: "ok", op: "EQ", value: true }] }), ["100% pure"]);
    assert.deepEqual(await names({ sort: [["n", true]], conditions: [{ field: "n", op: "NOT_NULL" }] }), ["bang!x", "100 points", "100% pure"]);
    const [total, page] = await repo.page(query({ offset: 1, limit: 1 }));
    assert.deepEqual([total, page.map((r) => r.name)], [4, ["100 points"]]);
    assert.equal((await repo.get(1))!.ok, true);
    await repo.update(1, { name: "renamed" });
    assert.deepEqual(await repo.get(1), { id: 1, name: "renamed", n: 1, ok: true, d: "2026-01-01" });
    await repo.delete([1, 2, 4]);
    assert.deepEqual(await names({}), ["under_score"]);
    assert.equal(await repo.get(1), null);
  });
}

/** Records the statements a dialect writes, answering COUNT(*) with a numeric string the way pg does. */
function capture(rows: Record<string, unknown>[] = []): SqlExecutor & { calls: [string, unknown[]][] } {
  const calls: [string, unknown[]][] = [];
  return {
    calls,
    query: async (sql, params) => {
      calls.push([sql, params]);
      return sql.startsWith("SELECT COUNT") ? [{ n: "2" }] : rows;
    },
    execute: async (sql, params) => void calls.push([sql, params]),
  };
}

const search: Query = {
  conditions: [
    { field: "name", op: "LIKE", value: "5%_![x" }, { field: "n", op: "IN", value: [1, 2] }, { field: "ok", op: "EQ", value: true },
  ],
  sort: [], offset: 20, limit: 10,
};

for (const [dialect, expected] of [
  ["postgres", {
    page: `SELECT * FROM "item" WHERE "name" ILIKE $1 ESCAPE '!' AND "n" IN ($2, $3) AND "ok" = $4 ORDER BY "id" ASC LIMIT $5 OFFSET $6`,
    params: ["%5!%!_!![x%", 1, 2, true, 10, 20],
    insert: `INSERT INTO "item" ("name", "ok") VALUES ($1, $2)`,
  }],
  ["mysql", {
    page: "SELECT * FROM `item` WHERE `name` LIKE ? ESCAPE '!' AND `n` IN (?, ?) AND `ok` = ? ORDER BY `id` ASC LIMIT ? OFFSET ?",
    params: ["%5!%!_!![x%", 1, 2, 1, 10, 20],
    insert: "INSERT INTO `item` (`name`, `ok`) VALUES (?, ?)",
  }],
  ["mssql", {
    page: "SELECT * FROM [item] WHERE [name] LIKE @p0 ESCAPE '!' AND [n] IN (@p1, @p2) AND [ok] = @p3 ORDER BY [id] ASC OFFSET @p4 ROWS FETCH NEXT @p5 ROWS ONLY",
    params: ["%5!%!_!!![x%", 1, 2, 1, 20, 10],
    insert: "INSERT INTO [item] ([name], [ok]) VALUES (@p0, @p1)",
  }],
] as [SqlDialect, { page: string; params: unknown[]; insert: string }][]) {
  test(`${dialect} statements`, async () => {
    const exec = capture([{ id: "7", name: "x", n: "12.5", ok: dialect === "postgres" ? true : 1, d: new Date(2026, 0, 5, 10, 30) }]);
    const repo = new SqlRepository(exec, "item", { dialect });
    repo.bind(Item);
    const [total, rows] = await repo.page(search);
    assert.equal(total, 2);
    assert.deepEqual(rows, [{ id: 7, name: "x", n: 12.5, ok: true, d: "2026-01-05" }], "driver values normalized");
    assert.equal(exec.calls[0][0].replace(/^SELECT COUNT\(\*\) AS n FROM /, ""), expected.page.replace(/^SELECT \* FROM /, "")
      .replace(/ ORDER BY .*$/, ""), "count uses the same filter");
    assert.deepEqual(exec.calls[1], [expected.page, expected.params]);
    await repo.add({ name: "y", ok: true });
    assert.deepEqual(exec.calls[2][0], expected.insert);
  });
}

test("driver dates and numbers", async () => {
  const When = model("When", { id: field.pk(), at: field.dateTime("At"), big: field.number("Big") });
  const repo = new SqlRepository(capture([
    { id: 1n, at: "2026-01-05 10:30:00.123456", big: "9007199254740993" },
    { id: 2, at: new Date(2026, 0, 5, 10, 30, 0, 7), big: 3n },
  ]), "w", { dialect: "postgres" });
  repo.bind(When);
  const [, rows] = await repo.page({ conditions: [], sort: [], offset: 0, limit: 10 });
  assert.deepEqual(rows, [
    { id: 1, at: "2026-01-05T10:30:00.123", big: "9007199254740993" },
    { id: 2, at: "2026-01-05T10:30:00.007", big: 3 },
  ]);
  assert.throws(() => new SqlRepository(capture(), "w", { dialect: "postgres", autoCreate: true }), /SQLite tables only/);
  assert.throws(() => new SqlRepository(capture(), "w; drop", { dialect: "postgres" }), /illegal table name/);
});

test("filters are ANDed as written, each ? of one with params bound in the dialect", async () => {
  const exec = capture();
  const repo = new SqlRepository(exec, "item", { dialect: "postgres" });
  repo.bind(Item);
  await repo.page({ ...search, filters: [["owner = ? OR n > ?", ["a", 1]], ["ok <> '?'", []]] });
  assert.deepEqual(exec.calls[1], [`SELECT * FROM "item" WHERE (owner = $1 OR n > $2) AND (ok <> '?') AND "name" ILIKE $3 ESCAPE '!' AND "n" IN ($4, $5) ` +
    `AND "ok" = $6 ORDER BY "id" ASC LIMIT $7 OFFSET $8`, ["a", 1, "%5!%!_!![x%", 1, 2, true, 10, 20]]);
  assert.match(exec.calls[0][0], /WHERE \(owner = \$1 OR n > \$2\) AND \(ok <> '\?'\) AND/, "count uses the same filter");
  await assert.rejects(Promise.resolve(repo.page({ ...search, filters: [["owner = ?", ["a", "b"]]] })), /1 '\?' for 2 params/);
  assert.throws(() => new MemoryRepository().page({ ...search, filters: [["ok", []]] }), /cannot apply/);
});
