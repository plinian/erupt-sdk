import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import { test } from "node:test";
import { checkSchema, field, model, operation } from "../src/index.js";

const declare = (fields: Record<string, ReturnType<typeof field.pk>> = {}, options: object = {}) =>
  model("Bad", { id: field.pk(), ...fields }, options);

test("rejects unknown annotation values at declaration", () => {
  const cases: [() => unknown, RegExp][] = [
    [() => declare({ title: field.input("T", { edit: { inputTyp: { length: 9 } } as never }) }), /Edit has no attribute 'inputTyp'/],
    [() => declare({ title: field.input("T", { view: { sortable: "yes" } as never }) }), /expected boolean/],
    [() => field.of("INPUTT" as never, "T"), /is not a EditType/],
    [() => field.of("PASSWORD", "T") && declare({ t: field.of("PASSWORD", "T") }), /PASSWORD is not supported yet/],
    [() => declare({ title: field.input("T", { edit: { search: { operator: "ABOUT" } } as never }) }), /is not a QueryExpression/],
    [() => declare({}, { erupt: { orderBy: "id" } }), /Erupt has no attribute 'orderBy'/],
    [() => declare({}, { erupt: { layout: { pageSize: "10" } } }), /expected integer/],
    [() => declare({}, { orderBy: "missing desc" }), /illegal orderBy/],
    [() => declare({}, { erupt: { vis: [{ title: "V", orderBy: "missing" }] } }), /illegal orderBy/],
    [() => operation("Go", { mode: "ALL" as never }, () => undefined), /is not a RowOperationMode/],
    [() => operation("Go", { raw: { colour: "red" } as never }, () => undefined), /RowOperation has no attribute 'colour'/],
    [() => declare({ c: field.ref(declare(), "C", { label: "title" }) }), /has no field 'title'/],
    [() => declare({ t: field.input("T", { fetch: () => ({}) }) }), /fetch, complete and click belong to/],
    [() => declare({ t: field.input("T", { click: () => ({}) }) }), /fetch, complete and click belong to/],
    [() => model("bad name", {}), /must be an identifier/],
    [() => model("Two", { a: field.pk(), b: field.pk() }), /at most one/],
  ];
  for (const [fn, message] of cases) assert.throws(fn, message);
});

test("raw attributes pass through", () => {
  const m = declare({ title: field.input("T", { edit: { inputType: { length: 9 } } }) }, { erupt: { layout: { pageSize: 30 } } });
  const built = m.buildErupt();
  assert.equal(built.eruptJson.layout.pageSize, 30);
  assert.equal(built.eruptFieldModels[1].eruptFieldJson.edit.inputType.length, 9);
  checkSchema("Erupt", built.eruptJson, "Bad", false);
});

test("coerces browser values like the Python SDK", () => {
  const m = model("Values", {
    id: field.pk(), d: field.date("D"), t: field.dateTime("T"), n: field.number("N"), b: field.boolean("B"),
    c: field.choice("C", { a: "A" }),
  });
  const f = m.fields;
  assert.equal(f.t.coerce("2026-01-05 10:30:00"), "2026-01-05T10:30:00.000");
  assert.equal(f.t.coerce("2026-01-05T10:30:00.123456Z"), "2026-01-05T10:30:00.123");
  assert.equal(f.t.coerce("2026-1-5 9:05"), "2026-01-05T09:05:00.000");
  assert.equal(f.d.coerce("2026-03-01 23:59:59"), "2026-03-01");
  assert.throws(() => f.d.coerce("2026-02-30"), /illegal date/);
  assert.throws(() => f.d.coerce("someday"), /illegal date/);
  assert.equal(f.n.coerce("3"), 3);
  assert.equal(f.n.coerce(2.5), 2.5);
  assert.throws(() => f.n.coerce("many"), /illegal number/);
  assert.equal(f.b.coerce("TRUE"), true);
  assert.equal(f.b.coerce(0), false);
  assert.equal(f.c.coerce("a"), "a");
  assert.throws(() => f.c.coerce("b"), /illegal option/);
  assert.equal(f.id.coerce("42"), 42);
  assert.throws(() => f.id.coerce("4x"), /illegal integer/);
  assert.equal(f.n.coerce(""), null);
});

test("generated files are current", async () => {
  const gen = await import(new URL("../../tools/gen-types.mjs", import.meta.url).href);
  const src = new URL("../../src/", import.meta.url);
  const schema = JSON.parse(readFileSync(new URL("schema.json", src), "utf8"));
  assert.equal(gen.generate(schema), readFileSync(new URL("types.ts", src), "utf8"));
});
