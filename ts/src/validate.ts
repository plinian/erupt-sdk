// Checks annotation JSON against erupt-annotations.schema.json (the same schema types.ts is generated
// from), so a misspelt attribute or an unknown enum value fails when the model is declared instead of
// silently doing nothing in the browser.
import SCHEMA from "./schema.json" with { type: "json" };

interface Schema {
  $ref?: string;
  type?: string;
  enum?: string[];
  items?: Schema;
  properties?: Record<string, Schema>;
  additionalProperties?: Schema | boolean;
  required?: string[];
  default?: unknown;
}

const DEFS = (SCHEMA as unknown as { $defs: Record<string, Schema> }).$defs;

const PRIMITIVES: Record<string, (v: unknown) => boolean> = {
  string: (v) => typeof v === "string",
  integer: (v) => Number.isInteger(v),
  number: (v) => typeof v === "number" && Number.isFinite(v),
  boolean: (v) => typeof v === "boolean",
};

const isObject = (v: unknown): v is Record<string, unknown> => typeof v === "object" && v !== null && !Array.isArray(v);

/**
 * Throw unless `value` fits definition `name`. `partial` (an override) lets every attribute be omitted;
 * otherwise the attributes the Java side always emits must be present.
 */
export function check(name: string, value: unknown, path = name, partial = true): void {
  walk({ $ref: "#/$defs/" + name }, value, path, partial);
}

/** The declared defaults of definition `name`, as Java fills an attribute left out. */
export function defaults(name: string): Record<string, unknown> {
  return Object.fromEntries(Object.entries(DEFS[name].properties!).filter(([, v]) => "default" in v).map(([k, v]) => [k, v.default]));
}

function walk(schema: Schema, value: unknown, path: string, partial: boolean): void {
  if (schema.$ref) {
    const name = schema.$ref.split("/").pop()!;
    const def = DEFS[name];
    if (def.enum) {
      if (!def.enum.includes(value as string)) {
        throw new Error(`${path}: '${value}' is not a ${name}, expected one of ${def.enum.join(", ")}`);
      }
      return;
    }
    if (!isObject(value)) throw new Error(`${path}: expected an object (${name})`);
    const props = def.properties!;
    for (const [key, item] of Object.entries(value)) {
      if (!(key in props)) throw new Error(`${path}: ${name} has no attribute '${key}'`);
      walk(props[key], item, `${path}.${key}`, partial);
    }
    if (!partial) {
      const missing = (def.required ?? []).filter((k) => !(k in value));
      if (missing.length) throw new Error(`${path}: missing ${missing.join(", ")}`);
    }
    return;
  }
  if (schema.type === "array") {
    if (!Array.isArray(value)) throw new Error(`${path}: expected an array`);
    value.forEach((item, i) => walk(schema.items!, item, `${path}[${i}]`, partial));
  } else if (schema.type === "object") {
    if (!isObject(value)) throw new Error(`${path}: expected an object`);
    if (typeof schema.additionalProperties !== "object") return;
    for (const [key, item] of Object.entries(value)) walk(schema.additionalProperties, item, `${path}.${key}`, partial);
  } else if (!PRIMITIVES[schema.type!](value)) {
    throw new Error(`${path}: expected ${schema.type}, got ${JSON.stringify(value)}`);
  }
}
