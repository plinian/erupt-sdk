// Erupt cloud node runtime: registers with the server, then answers the requests it forwards.
// The wire contract is erupt-cloud/PROTOCOL.md in the erupt repository.
import { AsyncLocalStorage } from "node:async_hooks";
import { randomBytes, timingSafeEqual } from "node:crypto";
import { verify } from "./signature.js";
import { createServer, type IncomingMessage, type Server, type ServerResponse } from "node:http";
import { createSocket } from "node:dgram";
import { type EruptRecord, type Field, isObject, type Model, type Operation, type Power, toJsonValue, type User } from "./model.js";
import type { Cond, Operator, Query, Repository } from "./repo.js";

export const VERSION = "0.1.0";

// the acting user and the browser's token of the request being served
const requestStore = new AsyncLocalStorage<{ user: User | null; token: string }>();

/** The acting user of the request being served: `{uid, account, name, tenantId}`. */
export function currentUser(): User | null {
  return requestStore.getStore()?.user ?? null;
}

// Features whose endpoints this SDK does not serve yet: hidden from the UI instead of failing there
const UNSUPPORTED_POWER: Power = { print: false, ai: false };

// Rights the server decides per user; the node ANDs them onto the declared power
const SERVER_POWER = ["add", "edit", "delete", "viewDetails", "export", "importable"];

const OPS = new Set(["EQ", "NEQ", "GT", "GTE", "LT", "LTE", "LIKE", "NOT_LIKE", "RANGE", "IN", "NOT_IN", "NULL", "NOT_NULL"]);

const MAX_PAGE_SIZE = 1000;

// invoke kind -> the field option holding its code
const INVOKED: Record<string, "fetch" | "onchange" | "complete" | "click"> = { options: "fetch", onchange: "onchange", autocomplete: "complete", button: "click" };


const MAX_BODY = 16 * 1024 * 1024;

/** A protocol status with an empty or JSON body. */
class Reply extends Error {
  constructor(readonly status: number, readonly body: unknown = "") {
    super(String(status));
  }
}

/** A business error shown to the user as a message: throw it from a DataProxy hook or an operation. */
export class Fail extends Error {}

const r = (success = true, message: string | null = null, data: unknown = null) =>
  ({ success, status: success ? "SUCCESS" : "ERROR", message, data, promptWay: "MESSAGE" });

interface Request {
  method: string;
  path: string;
  /** the request target as received (raw path and query), which the server signs */
  target: string;
  /** checks the server ran before forwarding, trusted only under a valid signature */
  enforced: Set<string>;
  query: URLSearchParams;
  headers: IncomingMessage["headers"];
  body: Buffer;
}

type Handler = (model: Model, repo: Repository, req: Request, ...args: string[]) => Promise<unknown>;

export interface NodeOptions {
  /** the address the server calls back; defaults to http://<interface ip>:<port> */
  address?: string;
  /** heartbeat period in seconds (default 15) */
  heartbeat?: number;
  /** refuse server calls without a valid Erupt-Signature: the plain access token alone no longer passes */
  requireSignature?: boolean;
}

export class Node {
  readonly servers: string[];
  readonly models = new Map<string, [Model, Repository]>();
  address: string | null;
  private serverIndex = 0;
  private readonly powerCache = new Map<string, [number, Power]>();
  private readonly instanceId = randomBytes(3).toString("hex");
  private readonly routes: [string, RegExp, Handler][];
  private timer: NodeJS.Timeout | null = null;
  private stopped = false;

  constructor(readonly name: string, private readonly accessToken: string, servers: string | string[], private readonly options: NodeOptions = {}) {
    if (!accessToken) throw new Error("accessToken is required");
    this.servers = (Array.isArray(servers) ? servers : [servers]).map((s) => s.replace(/\/+$/, ""));
    this.address = options.address?.replace(/\/+$/, "") ?? null;
    this.routes = [
      ["GET", /^\/erupt-api\/build\/([^/]+)$/, this.build],
      ["POST", /^\/erupt-api\/data\/table\/([^/]+)$/, this.table],
      ["GET", /^\/erupt-api\/data\/init-value\/([^/]+)$/, this.initValue],
      ["GET", /^\/erupt-api\/data\/([^/]+)\/([^/]+)$/, this.get],
      ["POST", /^\/erupt-api\/data\/modify\/([^/]+)$/, this.add],
      ["POST", /^\/erupt-api\/data\/modify\/([^/]+)\/update$/, this.update],
      ["POST", /^\/erupt-api\/data\/modify\/([^/]+)\/delete$/, this.delete],
      ["POST", /^\/erupt-api\/invoke\/([^/]+)\/([^/]+)\/([^/]+)$/, this.invoke],
    ];
  }

  register(model: Model, repository: Repository): this {
    if (this.models.has(model.name)) throw new Error(`erupt '${model.name}' registered twice`);
    if (model.pk === null) throw new Error(`${model.name} has no field.pk(); only an operation form may omit it`);
    repository.bind(model);
    this.models.set(model.name, [model, repository]);
    return this;
  }

  // ---------------------------------------------------------------- HTTP

  /** A request listener for any node:http server. */
  readonly listener = (req: IncomingMessage, res: ServerResponse): void => {
    void this.respond(req, res);
  };

  private async respond(req: IncomingMessage, res: ServerResponse): Promise<void> {
    const url = new URL(req.url ?? "/", "http://node");
    let status: number;
    let body: unknown;
    try {
      const chunks: Buffer[] = [];
      let size = 0;
      for await (const chunk of req) {
        size += chunk.length;
        if (size > MAX_BODY) throw new Reply(413);
        chunks.push(chunk);
      }
      [status, body] = await this.dispatch({ method: req.method ?? "GET", path: url.pathname, target: req.url ?? "/", enforced: new Set(), query: url.searchParams, headers: req.headers, body: Buffer.concat(chunks) });
    } catch (e) {
      if (e instanceof Reply) [status, body] = [e.status, e.body];
      else if (e instanceof Fail) [status, body] = [200, r(false, e.message)];
      else {
        // never leak internals: message only, the stack stays in the node log
        console.error("erupt node error", e);
        [status, body] = [500, { path: url.pathname, status: 500, error: "erupt exception", message: e instanceof Error ? e.message : String(e) }];
      }
    }
    const text = typeof body === "string";
    const payload = Buffer.from(text ? (body as string) : JSON.stringify(body));
    res.writeHead(status, {
      "Content-Type": text ? "text/plain; charset=utf-8" : "application/json; charset=utf-8",
      "Content-Length": payload.length,
    });
    res.end(payload);
  }

  private async dispatch(req: Request): Promise<[number, unknown]> {
    if (req.path === "/node-health") return [200, this.name];
    if (!req.path.startsWith("/erupt-api/")) throw new Reply(404);
    // server-to-server only: an Origin header means a browser reached the node directly
    if (req.headers.origin) throw new Reply(403);
    this.authenticate(req);
    const erupt = header(req, "erupt");
    for (const [verb, pattern, handler] of this.routes) {
      const match = pattern.exec(req.path);
      if (verb !== req.method || !match) continue;
      let name: string, args: string[];
      try {
        [name, ...args] = match.slice(1).map(decodeURIComponent);
      } catch {
        throw new Reply(404);
      }
      const entry = this.models.get(name);
      if (erupt !== name || !entry) throw new Reply(404);
      const parent = header(req, "eruptparent") || req.query.get("_eruptParent");
      // nesting is not supported yet, so a parent can only vouch for itself
      if (parent && parent.split(".").pop() !== name) throw new Reply(404);
      const user = header(req, "user");
      const acting = user ? (JSON.parse(Buffer.from(user, "base64").toString("utf8")) as User) : null;
      return requestStore.run({ user: acting, token: header(req, "token") ?? "" }, async () => [200, await handler.call(this, entry[0], entry[1], req, ...args)]);
    }
    throw new Reply(404);
  }

  /** A signed call must verify, and then stands for the token; its Erupt-Enforced is trusted only then. */
  private authenticate(req: Request): void {
    const signature = header(req, "erupt-signature");
    if (signature === undefined) {
      if (this.options.requireSignature || !sameSecret(header(req, "access-token") ?? "", this.accessToken)) throw new Reply(403);
      return;
    }
    const multipart = (header(req, "content-type") ?? "").includes("multipart/form-data");
    const enforced = header(req, "erupt-enforced");
    if (!verify(this.accessToken, req.method, req.target, header(req, "erupt-timestamp"), enforced, header(req, "user"),
      multipart ? null : req.body, signature, Math.floor(Date.now() / 1000))) throw new Reply(403);
    req.enforced = new Set((enforced ?? "").split(",").filter(Boolean));
  }

  // ---------------------------------------------------------------- endpoints

  private async build(model: Model, _repo: Repository, req: Request): Promise<unknown> {
    return model.buildModel(await this.power(model, req), currentUser());
  }

  private async table(model: Model, repo: Repository, req: Request): Promise<unknown> {
    await this.require(model, req, "query");
    return this.page(model, repo, objectBody(req), req);
  }

  private async page(model: Model, repo: Repository, body: Record<string, any>, req: Request): Promise<unknown> {
    const pageIndex = Math.max(Math.trunc(Number(body.pageIndex)) || 1, 1);
    const pageSize = Math.min(Math.max(Math.trunc(Number(body.pageSize)) || 10, 1), MAX_PAGE_SIZE);
    const query: Query = { conditions: [], sort: [], offset: (pageIndex - 1) * pageSize, limit: pageSize };
    // under a signed "query" the server checked the browser's conditions and may add its own (a dependent picker)
    const trusted = req.enforced.has("query");
    for (const c of asList(body.condition)) query.conditions.push(...conditions(model, c, trusted));
    const drill = await this.drill(model, req, query);
    for (const s of asList(body.sort)) {
      const f = isObject(s) ? model.fields[s.field] : undefined;
      if (!f || !(f.sortable || f.pk)) throw new Fail(`illegal sort field '${isObject(s) ? s.field : s}'`);
      query.sort.push([f.name, String((s as Record<string, unknown>).direction ?? "ASC").toUpperCase() === "DESC"]);
    }
    // a @LinkTree table shows the rows under the picked tree keys; with dependNode, none until one is picked
    const picked = body.linkTreeVal;
    if (model.linkTree && picked != null) query.conditions.push(condition(model.fields[model.linkTree[0]], "IN", picked));
    // a @Vis view's own filter and order, then the DataProxy's
    const [filters, sort] = model.vis.get(body.vis) ?? [[], []];
    if (!query.sort.length) query.sort = [...(sort.length ? sort : model.orderBy)];
    query.filters = [...drill, ...filters, ...await model.filters(query.conditions)];
    const [total, records] = model.linkTree?.[1] && picked == null ? [0, []] : await repo.page(query);
    const rows = this.rows(model, records);
    await model.hook("afterFetch", rows);
    return {
      pageIndex, pageSize, total, totalPage: Math.ceil(total / pageSize), list: rows,
      sort: null, alert: null, extraContent: null,
    };
  }

  /**
   * A drill into this table from a row of another model (erupt-cloud/PROTOCOL.md §7.2): the rows whose
   * joinColumn holds the source row's column; its linkCondition is returned as a filter.
   */
  private async drill(model: Model, req: Request, query: Query): Promise<[string, unknown[]][]> {
    const code = header(req, "drill");
    if (code === undefined) return [];
    const source = this.models.get(header(req, "drillsourceerupt") ?? "");
    const link = source?.[0].drills.get(code);
    if (!source || !link) throw new Reply(403);
    if (link.erupt !== model.name || !(link.join in model.fields)) throw new Fail(`illegal erupt from drill '${code}'`);
    const row = await source[1].get(primaryKey(source[0], header(req, "drillvalue")));
    if (!row) throw new Fail("record not found");
    query.conditions.push(condition(model.fields[link.join], "EQ", row[link.column]));
    return link.condition ? [[link.condition, []]] : [];
  }

  private async initValue(model: Model, _repo: Repository, req: Request): Promise<unknown> {
    await this.require(model, req, "add");
    const record = Object.fromEntries(Object.keys(model.fields).map((name) => [name, null]));
    await model.hook("addBehavior", record);
    return this.rows(model, [record])[0];
  }

  private async get(model: Model, repo: Repository, req: Request, pk: string): Promise<unknown> {
    const power = await this.power(model, req);
    if (!(power.edit || power.viewDetails)) throw new Reply(403);
    const record = await repo.get(primaryKey(model, pk));
    if (!record) throw new Fail("record not found");
    await model.hook("editBehavior", record);
    return this.rows(model, [record])[0];
  }

  private async add(model: Model, repo: Repository, req: Request): Promise<unknown> {
    await this.require(model, req, "add");
    const record = coerceRecord(model, objectBody(req));
    await model.hook("validate", record);
    await model.hook("beforeAdd", record);
    await repo.add(record);
    await model.hook("afterAdd", record);
    return r();
  }

  private async update(model: Model, repo: Repository, req: Request): Promise<unknown> {
    await this.require(model, req, "edit");
    const body = objectBody(req);
    const pk = primaryKey(model, body[model.pk!]);
    if (!(await repo.get(pk))) throw new Fail("record not found");
    const record = coerceRecord(model, body);
    await model.hook("validate", record);
    await model.hook("beforeUpdate", record);
    await repo.update(pk, record);
    await model.hook("afterUpdate", record);
    return r();
  }

  private async delete(model: Model, repo: Repository, req: Request): Promise<unknown> {
    await this.require(model, req, "delete");
    const body = readJson(req);
    if (!Array.isArray(body)) throw new Fail("a list of ids is required");
    const pks = body.map((pk) => primaryKey(model, pk));
    // the hooks see each record as it was; reading them costs nothing without a proxy
    const records = model.proxies.length ? (await Promise.all(pks.map((pk) => repo.get(pk)))).filter((x) => x != null) : [];
    for (const record of records) await model.hook("beforeDelete", record);
    await repo.delete(pks);
    for (const record of records) await model.hook("afterDelete", record);
    return r();
  }

  /**
   * The node's own code (erupt-cloud/PROTOCOL.md §5.5): a row operation and its form values under the
   * operation code, or a field's fetched options, onchange, auto-complete or button with the form's values.
   */
  private async invoke(model: Model, repo: Repository, req: Request, kind: string, name: string): Promise<unknown> {
    if (kind === "operation") return this.operation(model, repo, req, name);
    if (kind === "operation-form") return r(true, null, this.operationFormValue(model, name));
    const f = model.declared.find((f) => f.name === name);
    const fn = f && Object.hasOwn(INVOKED, kind) ? f.options[INVOKED[kind]] : undefined;
    if (!fn) throw new Reply(404);
    const body = objectBody(req);
    const form = isObject(body.form) ? body.form : {};
    if (kind === "autocomplete") return r(true, null, [...await f!.options.complete!(form, String(body.value ?? ""))]);
    let answer = await (fn as (form: Record<string, any>) => unknown)(form);
    if (kind === "options" && f!.type !== "TAGS") {
      // {value: label} or [value, label] pairs, as the choices of a field
      answer = (Array.isArray(answer) ? answer : Object.entries(answer as object)).map(([value, label]) => ({ value: String(value), label }));
    }
    return r(true, null, answer);
  }

  /**
   * Records to browser rows. A reference stays its key: the server resolves its label, the flattened
   * <field>_<label> column and the tree (erupt-cloud/PROTOCOL.md §7.3).
   */
  private rows(model: Model, records: EruptRecord[]): EruptRecord[] {
    const fields = Object.values(model.fields);
    return records.map((record) => Object.fromEntries(fields.map((f) => [f.name, toJsonValue(record[f.name] ?? null, f.type)])));
  }

  private operationOf(model: Model, code: string): Operation {
    const op = model.operations[code];
    // a hidden operation does not exist for this user, exactly like the Java proxy filters it out
    if (!op || !op.visible(currentUser())) throw new Reply(op ? 403 : 404);
    return op;
  }

  private operationFormValue(model: Model, code: string): Record<string, null> | null {
    const op = this.operationOf(model, code);
    // none without a form: the server answers the browser a 404, and it opens an empty one
    return op.form ? Object.fromEntries(Object.keys(op.form.fields).map((name) => [name, null])) : null;
  }

  private async operation(model: Model, repo: Repository, req: Request, code: string): Promise<unknown> {
    const op = this.operationOf(model, code);
    const body = objectBody(req);
    const param = op.form ? coerceRecord(op.form, isObject(body.param) ? body.param : {}) : null;
    const rows: EruptRecord[] = [];
    if (op.mode !== "BUTTON") {
      const ids = body.ids;
      if (!Array.isArray(ids) || !ids.length) throw new Fail("select at least one row");
      if (op.mode === "SINGLE" && ids.length !== 1) throw new Fail("select exactly one row");
      for (const pk of ids) {
        const record = await repo.get(primaryKey(model, pk));
        if (!record) throw new Fail(`record '${pk}' not found`);
        rows.push(record);
      }
    }
    const result = await op.handler({ rows, param, repo, model, user: currentUser() });
    return typeof result === "string" && result ? r(true, null, result) : r(true, "Executed successfully");
  }

  // ---------------------------------------------------------------- permissions (PROTOCOL.md §6.1)

  private async require(model: Model, req: Request, right: string): Promise<void> {
    if (!(await this.power(model, req))[right]) throw new Reply(403);
  }

  private async power(model: Model, req: Request): Promise<Power> {
    // the server checked the user's rights and restricts the build's power itself: only the model's own
    // declaration is left to apply here
    if (req.enforced.has("power")) return { ...model.power, ...UNSUPPORTED_POWER };
    const token = header(req, "token") ?? "";
    const key = `${token}\u0000${model.name}`;
    const cached = this.powerCache.get(key);
    if (cached && cached[0] > Date.now()) return cached[1];
    const power: Power = { ...model.power, ...UNSUPPORTED_POWER };
    let remote: Record<string, unknown> = {};
    try {
      const params = new URLSearchParams({ nodeName: this.name, eruptName: model.name });
      const res = await fetch(`${this.nextServer()}/erupt-cloud-api/erupt-power?${params}`,
        { headers: { token }, signal: AbortSignal.timeout(5000) });
      if (!res.ok) throw new Error(`HTTP ${res.status}`);
      const json: unknown = await res.json();
      if (isObject(json)) remote = json;
    } catch (e) {
      // fail closed: without the server's verdict nothing is writable
      console.warn(`erupt-power unavailable: ${e instanceof Error ? e.message : e}`);
    }
    for (const right of SERVER_POWER) power[right] = power[right] && !!remote[right];
    if (this.powerCache.size > 10000) this.powerCache.clear();
    this.powerCache.set(key, [Date.now() + 5000, power]);
    return power;
  }

  // ---------------------------------------------------------------- server calls

  /** The config text set for this node on the erupt server (Node Config). */
  config(): Promise<string> {
    return this.serverText(`/erupt-cloud-api/node-config/${this.name}`, { "Access-Token": this.accessToken });
  }

  /** The config text of this node's group on the erupt server. */
  groupConfig(): Promise<string> {
    return this.serverText(`/erupt-cloud-api/node-group-config/${this.name}`, { "Access-Token": this.accessToken });
  }

  /** The acting user's full info from the erupt server (roles, org, post...), for the request being served. */
  async userInfo(): Promise<Record<string, any> | null> {
    const text = await this.serverText(`/erupt-cloud-api/userinfo/${this.name}`,
      { "Access-Token": this.accessToken, token: requestStore.getStore()?.token ?? "" });
    return text ? JSON.parse(text) : null;
  }

  private async serverText(path: string, headers: Record<string, string>): Promise<string> {
    const res = await fetch(this.nextServer() + path, { headers, signal: AbortSignal.timeout(5000) });
    if (!res.ok) throw new Error(`${path}: HTTP ${res.status}`);
    return res.text();
  }

  private nextServer(): string {
    return this.servers[this.serverIndex++ % this.servers.length];
  }

  private nodeInfo() {
    return {
      instanceId: this.instanceId, nodeName: this.name, accessToken: this.accessToken, version: `ts-${VERSION}`,
      nodeAddress: [this.address], eruptModules: [], erupts: [...this.models.keys()], resources: {},
      capabilities: ["invoke"],
    };
  }

  private async heartbeat(failing = false): Promise<void> {
    if (this.stopped) return;
    const server = this.nextServer();
    let next = (this.options.heartbeat ?? 15) * 1000;
    try {
      const res = await fetch(`${server}/erupt-cloud-api/register-node`, {
        method: "POST", headers: { "Content-Type": "application/json" }, body: JSON.stringify(this.nodeInfo()),
        signal: AbortSignal.timeout(10000),
      });
      if (!res.ok) throw new Error(`HTTP ${res.status}`);
      if (failing) console.info(`${server} -> connection success`);
      failing = false;
    } catch (e) {
      failing = true;
      next /= 2;
      console.error(`${server} -> register failed: ${e instanceof Error ? e.message : e}`);
    }
    if (!this.stopped) this.timer = setTimeout(() => void this.heartbeat(failing), next);
  }

  /** Start registering with the server; call once `address` answers /node-health. */
  startHeartbeat(): void {
    this.stopped = false;
    void this.heartbeat();
  }

  /** Stop the heartbeat and tell the server this instance is gone. */
  async deregister(): Promise<void> {
    this.stopped = true;
    if (this.timer) clearTimeout(this.timer);
    try {
      await fetch(`${this.nextServer()}/erupt-cloud-api/remove-instance-node`, {
        method: "POST",
        body: new URLSearchParams({ nodeName: this.name, accessToken: this.accessToken, locations: this.address ?? "" }),
        signal: AbortSignal.timeout(5000),
      });
    } catch (e) {
      console.error(`deregister failed: ${e instanceof Error ? e.message : e}`);
    }
  }

  /**
   * Serve until SIGINT / SIGTERM: HTTP first (the server probes /node-health while registering), then the
   * heartbeat; on a signal deregister and close.
   */
  async serve(port = 9090, host = "0.0.0.0"): Promise<Server> {
    this.address ??= `http://${await localIp(this.servers[0])}:${port}`;
    const server = createServer(this.listener);
    await new Promise<void>((resolve) => server.listen(port, host, resolve));
    console.info(`erupt node '${this.name}' at ${this.address} -> ${this.servers.join(", ")}`);
    this.startHeartbeat();
    const stop = async () => {
      await this.deregister();
      server.close();
      server.closeAllConnections();
    };
    process.once("SIGINT", stop);
    process.once("SIGTERM", stop);
    return server;
  }
}

// ---------------------------------------------------------------- helpers

function header(req: Request, name: string): string | undefined {
  const value = req.headers[name];
  return Array.isArray(value) ? value[0] : value;
}

function sameSecret(given: string, expected: string): boolean {
  const a = Buffer.from(given);
  const b = Buffer.from(expected);
  // timingSafeEqual needs equal lengths; comparing b with itself keeps the time independent of `given`
  return timingSafeEqual(a.length === b.length ? a : b, b) && a.length === b.length;
}

function readJson(req: Request): unknown {
  if (!req.body.length) return undefined;
  try {
    return JSON.parse(req.body.toString("utf8"));
  } catch {
    throw new Fail("malformed JSON body");
  }
}

function objectBody(req: Request): Record<string, any> {
  const body = readJson(req);
  return isObject(body) ? body : {};
}

const asList = (v: unknown): unknown[] => (Array.isArray(v) ? v : []);

function conditions(model: Model, c: unknown, trusted = false): Cond[] {
  const key = isObject(c) ? c.key : undefined;
  const f = typeof key === "string" ? model.fields[key] : undefined;
  if (!f || (!trusted && (f.pk || !f.search))) throw new Fail(`illegal search field '${key}'`);
  const op = String((c as Record<string, unknown>).expression || "EQ");
  if (!OPS.has(op)) throw new Fail(`illegal operator '${op}'`);
  const value = (c as Record<string, unknown>).value;
  if (!f.json) return [condition(f, op, value)];
  // a JSON value (MULTI_CHOICE) holds every value searched for, matched as "<value>" in its text
  if (!["EQ", "IN", "NEQ", "NOT_IN"].includes(op)) throw new Fail(`illegal operator '${op}' for ${f.title}`);
  const like: Operator = op === "EQ" || op === "IN" ? "LIKE" : "NOT_LIKE";
  return (Array.isArray(value) ? value : [value]).map((v) => ({ field: f.name, op: like, value: JSON.stringify(String(v)) }));
}

function condition(f: Field, op: string, value: unknown): Cond {
  const cond = (v?: unknown): Cond => ({ field: f.name, op: op as Operator, value: v });
  if (op === "NULL" || op === "NOT_NULL") return cond();
  if (f.isReference && !["EQ", "NEQ", "IN", "NOT_IN"].includes(op)) throw new Fail(`illegal operator '${op}' for a reference`);
  if (op === "LIKE" || op === "NOT_LIKE") return cond(String(value));
  try {
    if (op === "RANGE") {
      if (!Array.isArray(value) || value.length !== 2) throw new Error("range needs two values");
      return cond(value.map((v) => f.coerce(v)));
    }
    if (op === "IN" || op === "NOT_IN") return cond((Array.isArray(value) ? value : [value]).map((v) => f.coerce(v)));
    return cond(f.coerce(value));
  } catch (e) {
    throw new Fail((e as Error).message);
  }
}

function primaryKey(model: Model, value: unknown): unknown {
  try {
    return model.fields[model.pk!].coerce(value);
  } catch {
    throw new Fail(`illegal id '${value}'`);
  }
}

function coerceRecord(model: Model, body: Record<string, unknown>): EruptRecord {
  const record: EruptRecord = {};
  for (const f of Object.values(model.fields)) {
    if (f.pk || !f.form) continue;
    let value: unknown;
    try {
      value = f.coerce(body[f.name]);
    } catch (e) {
      throw new Fail(`${f.title}: ${(e as Error).message}`);
    }
    if (f.notNull && value == null) throw new Fail(`${f.title} cannot be empty`);
    record[f.name] = value;
  }
  return record;
}

/** The interface address the server would see us on. */
function localIp(server: string): Promise<string> {
  return new Promise((resolve) => {
    const socket = createSocket("udp4");
    const done = (ip: string) => {
      socket.close();
      resolve(ip);
    };
    socket.on("error", () => done("127.0.0.1"));
    try {
      socket.connect(80, new URL(server).hostname || "127.0.0.1", () => done(socket.address().address));
    } catch {
      done("127.0.0.1");
    }
  });
}
