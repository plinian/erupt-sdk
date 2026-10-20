// Storage adapters. A repository only sees field names the node has already checked against the model,
// so it may use them as identifiers; values always travel as parameters.
import type { DatabaseSync } from "node:sqlite";
import type { EruptRecord, Field, Model } from "./model.js";

export type Operator = "EQ" | "NEQ" | "GT" | "GTE" | "LT" | "LTE" | "LIKE" | "NOT_LIKE" | "RANGE" | "IN" | "NOT_IN" | "NULL" | "NOT_NULL";

export interface Cond {
  field: string;
  op: Operator;
  value?: unknown;
}

export interface Query {
  conditions: Cond[];
  /** [field, descending] */
  sort: [string, boolean][];
  /**
   * `[sql, params]` of a @Vis view and `DataProxy.beforeFetch`, ANDed to the WHERE as written; with params,
   * each `?` is one of them, bound.
   * A repository applies every one or refuses the query by throwing; it never ignores them.
   */
  filters?: [string, unknown[]][];
  offset: number;
  limit: number;
}

export type Awaitable<T> = T | Promise<T>;

/** Implement these methods to put an erupt model on any storage; each may be async. */
export interface Repository {
  /** called once by `Node.register` with the model this repository stores */
  bind(model: Model): void;
  /** `[total, records]`; a record is keyed by field name. Apply `query.filters` or throw, never ignore them. */
  page(query: Query): Awaitable<[number, EruptRecord[]]>;
  get(pk: unknown): Awaitable<EruptRecord | null>;
  add(record: EruptRecord): Awaitable<void>;
  update(pk: unknown, record: EruptRecord): Awaitable<void>;
  delete(pks: unknown[]): Awaitable<void>;
}

type Comparable = string | number | boolean;

function match(value: unknown, cond: Cond): boolean {
  const expect = cond.value as Comparable;
  if (cond.op === "NULL") return value == null;
  if (cond.op === "NOT_NULL") return value != null;
  if (value == null) return false;
  // a JSON value is matched as its text
  const v = (typeof value === "object" && !(value instanceof Date) ? JSON.stringify(value) : value) as Comparable;
  switch (cond.op) {
    case "EQ":
      return v === expect;
    case "NEQ":
      return v !== expect;
    case "LIKE":
      return String(v).toLowerCase().includes(String(expect).toLowerCase());
    case "NOT_LIKE":
      return !String(v).toLowerCase().includes(String(expect).toLowerCase());
    case "IN":
      return (cond.value as unknown[]).includes(v);
    case "NOT_IN":
      return !(cond.value as unknown[]).includes(v);
    case "RANGE": {
      const [low, high] = cond.value as Comparable[];
      return low <= v && v <= high;
    }
    case "GT":
      return v > expect;
    case "GTE":
      return v >= expect;
    case "LT":
      return v < expect;
    case "LTE":
      return v <= expect;
  }
}

function compare(a: unknown, b: unknown): number {
  // nulls last, like the Python repository
  if (a == null || b == null) return a == null ? (b == null ? 0 : 1) : -1;
  return a < b ? -1 : a > b ? 1 : 0;
}

export class MemoryRepository implements Repository {
  private model!: Model;
  private readonly rows = new Map<number, EruptRecord>();
  private seq = 0;

  /** `records` are added (with fresh ids 1, 2, ...) once the repository is registered */
  constructor(private readonly seed: EruptRecord[] = []) {}

  bind(model: Model): void {
    this.model = model;
    for (const record of this.seed) this.add(record);
  }

  page(query: Query): [number, EruptRecord[]] {
    if (query.filters?.length) throw new Error("MemoryRepository cannot apply SQL filters (a view filter, beforeFetch)");
    const rows = [...this.rows.values()].filter((r) => query.conditions.every((c) => match(r[c.field], c)));
    // no sort: primary key ascending, the default of every repository
    const sort: [string, boolean][] = query.sort.length ? query.sort : [[this.model.pk!, false]];
    rows.sort((a, b) => {
      for (const [name, desc] of sort) {
        const c = compare(a[name], b[name]);
        if (c) return desc ? -c : c;
      }
      return 0;
    });
    return [rows.length, rows.slice(query.offset, query.offset + query.limit).map((r) => ({ ...r }))];
  }

  get(pk: unknown): EruptRecord | null {
    const row = this.rows.get(pk as number);
    return row ? { ...row } : null;
  }

  add(record: EruptRecord): void {
    const id = ++this.seq;
    this.rows.set(id, { ...record, [this.model.pk!]: id });
  }

  update(pk: unknown, record: EruptRecord): void {
    const row = this.rows.get(pk as number);
    if (row) Object.assign(row, record, { [this.model.pk!]: pk });
  }

  delete(pks: unknown[]): void {
    for (const pk of pks) this.rows.delete(pk as number);
  }
}

const SQL_OPS: Partial<Record<Operator, string>> = { EQ: "=", NEQ: "<>", GT: ">", GTE: ">=", LT: "<", LTE: "<=" };

const SQLITE_TYPES: Record<string, string> = {
  NUMBER: "NUMERIC", RATE: "NUMERIC", SLIDER: "NUMERIC", BOOLEAN: "INTEGER", DATE: "TEXT", DATE_TIME: "TEXT", REFERENCE_TABLE: "INTEGER", REFERENCE_TREE: "INTEGER",
};

type Row = Record<string, unknown>;

/** What `SqlRepository` needs from a database driver; adapt yours with `pgExecutor`, `mysqlExecutor`, ... */
export interface SqlExecutor {
  /** rows of a SELECT, keyed by column name */
  query(sql: string, params: unknown[]): Awaitable<Row[]>;
  /** an INSERT / UPDATE / DELETE / DDL statement */
  execute(sql: string, params: unknown[]): Awaitable<void>;
}

/** node-postgres `Pool` or `Client`. */
export function pgExecutor(db: { query(text: string, values?: unknown[]): Promise<{ rows: Row[] }> }): SqlExecutor {
  return {
    query: async (sql, params) => (await db.query(sql, params)).rows,
    execute: async (sql, params) => void (await db.query(sql, params)),
  };
}

/** mysql2/promise `Pool` or `Connection` (`query`, so values are substituted client side, LIMIT included). */
export function mysqlExecutor(db: { query(sql: string, values?: unknown[]): Promise<[unknown, unknown]> }): SqlExecutor {
  return {
    query: async (sql, params) => (await db.query(sql, params))[0] as Row[],
    execute: async (sql, params) => void (await db.query(sql, params)),
  };
}

interface MssqlRequest {
  input(name: string, value: unknown): MssqlRequest;
  query(sql: string): Promise<{ recordset?: Row[] }>;
}

/** mssql (tedious) `ConnectionPool`; parameters are bound as @p0, @p1, ... */
export function mssqlExecutor(pool: { request(): MssqlRequest }): SqlExecutor {
  const run = (sql: string, params: unknown[]) => {
    const request = pool.request();
    params.forEach((value, i) => request.input(`p${i}`, value));
    return request.query(sql);
  };
  return {
    query: async (sql, params) => (await run(sql, params)).recordset ?? [],
    execute: async (sql, params) => void (await run(sql, params)),
  };
}

type SqliteParam = null | number | bigint | string;

/** node:sqlite `DatabaseSync` (or anything with the same `prepare(sql).all / run`). */
export function sqliteExecutor(db: { prepare(sql: string): { all(...p: SqliteParam[]): unknown[]; run(...p: SqliteParam[]): unknown } }): SqlExecutor {
  return {
    query: (sql, params) => db.prepare(sql).all(...(params as SqliteParam[])) as Row[],
    execute: (sql, params) => void db.prepare(sql).run(...(params as SqliteParam[])),
  };
}

export type SqlDialect = "sqlite" | "postgres" | "mysql" | "mssql";

export interface SqlRepositoryOptions {
  dialect: SqlDialect;
  /** identifier quotes: one character for both sides or [open, close]; defaults per dialect */
  quote?: string | [string, string];
  /** CREATE TABLE IF NOT EXISTS on register, SQLite only */
  autoCreate?: boolean;
}

const QUOTES: Record<SqlDialect, [string, string]> = {
  sqlite: ['"', '"'], postgres: ['"', '"'], mysql: ["`", "`"], mssql: ["[", "]"],
};

const pad = (n: number, width = 2) => String(n).padStart(width, "0");

/** A driver value of a DATE / DATE_TIME column as the SDK's wall-clock string. */
function wallClock(value: unknown, type: string): unknown {
  let text: string;
  if (value instanceof Date) {
    // drivers build a local-time Date from a column without time zone, so local fields give back the wall clock
    text = `${value.getFullYear()}-${pad(value.getMonth() + 1)}-${pad(value.getDate())}T${pad(value.getHours())}:` +
      `${pad(value.getMinutes())}:${pad(value.getSeconds())}.${pad(value.getMilliseconds(), 3)}`;
  } else if (typeof value === "string") {
    text = value;
  } else {
    return value;
  }
  if (type === "DATE") return text.slice(0, 10);
  // "2026-01-05 10:30:00[.123456]" -> "2026-01-05T10:30:00.123"
  const m = /^(\d{4}-\d{2}-\d{2})[T ](\d{2}:\d{2}(?::\d{2})?)(?:\.(\d+))?/.exec(text);
  if (!m) return text;
  const time = m[2].length === 5 ? m[2] + ":00" : m[2];
  return `${m[1]}T${time}.${(m[3] ?? "").padEnd(3, "0").slice(0, 3)}`;
}

/** Numbers the driver returns as text (pg bigint / numeric) or bigint, back to numbers when exact. */
function number(value: unknown): unknown {
  if (typeof value === "bigint") return Number.isSafeInteger(Number(value)) ? Number(value) : value.toString();
  if (typeof value === "string" && /^-?\d+(\.\d+)?$/.test(value)) {
    const n = Number(value);
    return value.includes(".") || Number.isSafeInteger(n) ? n : value;
  }
  return value;
}

/** Collects bound values and writes the dialect's placeholder for each. */
class Params {
  readonly values: unknown[] = [];

  constructor(private readonly dialect: SqlDialect) {}

  add(value: unknown): string {
    // only PostgreSQL has a boolean type every driver binds; elsewhere a boolean is 0 / 1
    this.values.push(typeof value === "boolean" && this.dialect !== "postgres" ? Number(value) : value ?? null);
    const n = this.values.length;
    return this.dialect === "postgres" ? `$${n}` : this.dialect === "mssql" ? `@p${n - 1}` : "?";
  }
}

/**
 * A table on any SQL database through a `SqlExecutor`. Identifiers are the model's field names (already
 * checked as identifiers) and quoted; every value is a bound parameter. LIKE escapes with `!`, which reads
 * the same on every database. Without a sort, rows come back by primary key ascending.
 */
export class SqlRepository implements Repository {
  protected model!: Model;
  private readonly quotes: [string, string];
  private ready: Promise<void> = Promise.resolve();

  constructor(protected readonly executor: SqlExecutor, protected readonly table: string, readonly options: SqlRepositoryOptions) {
    if (!/^[A-Za-z_][A-Za-z0-9_]*$/.test(table)) throw new Error(`illegal table name '${table}'`);
    if (options.autoCreate && options.dialect !== "sqlite") throw new Error("autoCreate creates SQLite tables only");
    const quote = options.quote;
    this.quotes = typeof quote === "string" ? [quote, quote] : quote ?? QUOTES[options.dialect];
  }

  protected q(identifier: string): string {
    const [open, close] = this.quotes;
    return open + identifier.replaceAll(close, close + close) + close;
  }

  bind(model: Model): void {
    this.model = model;
    if (!this.options.autoCreate) return;
    const cols = Object.values(model.fields).map((f) =>
      f.pk ? `${this.q(f.name)} INTEGER PRIMARY KEY AUTOINCREMENT` : `${this.q(f.name)} ${SQLITE_TYPES[f.type!] ?? "TEXT"}`);
    // bind is synchronous; an async executor's DDL is awaited before the first statement
    this.ready = Promise.resolve(this.executor.execute(`CREATE TABLE IF NOT EXISTS ${this.q(this.table)} (${cols.join(", ")})`, []));
  }

  private where(query: Query, p: Params): string {
    const clauses: string[] = [];
    for (const [sql, params] of query.filters ?? []) {
      // the developer's own SQL, as written; with params, each '?' is one of them, bound like every other value
      const pieces = params.length ? sql.split("?") : [sql];
      if (pieces.length - 1 !== params.length) throw new Error(`filter: ${pieces.length - 1} '?' for ${params.length} params in '${sql}'`);
      clauses.push("(" + pieces.reduce((out, piece, i) => out + p.add(params[i - 1]) + piece) + ")");
    }
    for (const c of query.conditions) {
      const col = this.q(c.field);
      const values = Array.isArray(c.value) ? c.value : [];
      if (SQL_OPS[c.op]) {
        clauses.push(`${col} ${SQL_OPS[c.op]} ${p.add(c.value)}`);
      } else if (c.op === "LIKE" || c.op === "NOT_LIKE") {
        // ILIKE: PostgreSQL's LIKE is case sensitive, the others' (and the memory repository's) is not
        const like = this.options.dialect === "postgres" ? "ILIKE" : "LIKE";
        // [ opens a character class in SQL Server's LIKE
        const special = this.options.dialect === "mssql" ? /[!%_[]/g : /[!%_]/g;
        const pattern = `%${String(c.value).replace(special, (ch) => "!" + ch)}%`;
        clauses.push(`${col} ${c.op === "NOT_LIKE" ? "NOT " : ""}${like} ${p.add(pattern)} ESCAPE '!'`);
      } else if (c.op === "RANGE") {
        clauses.push(`${col} BETWEEN ${p.add(values[0])} AND ${p.add(values[1])}`);
      } else if (c.op === "IN" || c.op === "NOT_IN") {
        if (!values.length) {
          clauses.push(c.op === "IN" ? "1=0" : "1=1");
          continue;
        }
        clauses.push(`${col} ${c.op === "NOT_IN" ? "NOT " : ""}IN (${values.map((v) => p.add(v)).join(", ")})`);
      } else if (c.op === "NULL" || c.op === "NOT_NULL") {
        clauses.push(`${col} IS ${c.op === "NOT_NULL" ? "NOT " : ""}NULL`);
      }
    }
    return clauses.length ? " WHERE " + clauses.join(" AND ") : "";
  }

  /** A driver row as an erupt record: booleans, numbers and dates normalized by field type. */
  protected record(row: Row): EruptRecord {
    const record: EruptRecord = {};
    for (const f of Object.values(this.model.fields) as Field[]) {
      const value = row[f.name];
      if (value == null) {
        record[f.name] = null;
      } else if (f.json) {
        record[f.name] = typeof value === "string" ? JSON.parse(value) : value;
      } else if (f.type === "BOOLEAN") {
        record[f.name] = typeof value === "string" ? value === "1" || value === "true" : !!Number(value);
      } else if (f.type === "DATE" || f.type === "DATE_TIME") {
        record[f.name] = wallClock(value, f.type);
      } else if (f.pk || f.type === "NUMBER" || f.type === "RATE" || f.type === "SLIDER" || f.type === "REFERENCE_TABLE" || f.type === "REFERENCE_TREE") {
        record[f.name] = number(value);
      } else {
        record[f.name] = value;
      }
    }
    return record;
  }

  async page(query: Query): Promise<[number, EruptRecord[]]> {
    await this.ready;
    const table = this.q(this.table);
    const count = new Params(this.options.dialect);
    const countWhere = this.where(query, count);
    const [{ n }] = (await this.executor.query(`SELECT COUNT(*) AS n FROM ${table}${countWhere}`, count.values)) as [{ n: unknown }];
    const p = new Params(this.options.dialect);
    const where = this.where(query, p);
    const sort: [string, boolean][] = query.sort.length ? query.sort : [[this.model.pk!, false]];
    const order = sort.map(([name, desc]) => `${this.q(name)} ${desc ? "DESC" : "ASC"}`).join(", ");
    const paging = this.options.dialect === "mssql"
      ? `OFFSET ${p.add(query.offset)} ROWS FETCH NEXT ${p.add(query.limit)} ROWS ONLY`
      : `LIMIT ${p.add(query.limit)} OFFSET ${p.add(query.offset)}`;
    const rows = await this.executor.query(`SELECT * FROM ${table}${where} ORDER BY ${order} ${paging}`, p.values);
    return [Number(n), rows.map((r) => this.record(r))];
  }

  async get(pk: unknown): Promise<EruptRecord | null> {
    await this.ready;
    const p = new Params(this.options.dialect);
    const [row] = await this.executor.query(`SELECT * FROM ${this.q(this.table)} WHERE ${this.q(this.model.pk!)} = ${p.add(pk)}`, p.values);
    return row ? this.record(row) : null;
  }

  /** The columns of a record, a JSON value as its text. */
  private entries(record: EruptRecord): [string, unknown][] {
    return Object.entries(record).filter(([k]) => k !== this.model.pk)
      .map(([k, v]) => [k, this.model.fields[k]?.json && v != null ? JSON.stringify(v) : v]);
  }

  async add(record: EruptRecord): Promise<void> {
    await this.ready;
    const entries = this.entries(record);
    const p = new Params(this.options.dialect);
    const values = entries.map(([, v]) => p.add(v));
    await this.executor.execute(
      `INSERT INTO ${this.q(this.table)} (${entries.map(([k]) => this.q(k)).join(", ")}) VALUES (${values.join(", ")})`, p.values);
  }

  async update(pk: unknown, record: EruptRecord): Promise<void> {
    await this.ready;
    const entries = this.entries(record);
    if (!entries.length) return;
    const p = new Params(this.options.dialect);
    const sets = entries.map(([k, v]) => `${this.q(k)} = ${p.add(v)}`);
    await this.executor.execute(`UPDATE ${this.q(this.table)} SET ${sets.join(", ")} WHERE ${this.q(this.model.pk!)} = ${p.add(pk)}`, p.values);
  }

  async delete(pks: unknown[]): Promise<void> {
    await this.ready;
    if (!pks.length) return;
    const p = new Params(this.options.dialect);
    const marks = pks.map((pk) => p.add(pk));
    await this.executor.execute(`DELETE FROM ${this.q(this.table)} WHERE ${this.q(this.model.pk!)} IN (${marks.join(", ")})`, p.values);
  }
}

/** A SQLite table via node:sqlite (Node >= 22.5), created on first use when missing. */
export class SqliteRepository extends SqlRepository {
  private db: DatabaseSync | null = null;

  constructor(private readonly path: string, table: string) {
    // the executor opens the file on first use; `this` is not available before super()
    const self: { repo?: SqliteRepository } = {};
    super({ query: (sql, params) => self.repo!.exec().query(sql, params), execute: (sql, params) => self.repo!.exec().execute(sql, params) },
      table, { dialect: "sqlite", autoCreate: true });
    self.repo = this;
  }

  private exec(): SqlExecutor {
    if (!this.db) {
      // loaded lazily: node:sqlite warns as experimental on import, which an app using only memory should not see
      const { DatabaseSync } = process.getBuiltinModule("node:sqlite") as typeof import("node:sqlite");
      this.db = new DatabaseSync(this.path);
    }
    return sqliteExecutor(this.db);
  }

  /** Close the database file. */
  close(): void {
    this.db?.close();
    this.db = null;
  }
}
