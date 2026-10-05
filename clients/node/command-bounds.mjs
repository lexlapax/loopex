// Concept
// Preserve authored command bounds independently of the Elixir implementation.
// Technical depth
// M7's accepted closed grammar uses BigInt for native decimal quantities and
// Number for JSON-safe absolute deadlines. Omission belongs to the enclosing
// request; this object codec rejects undefined/null and supplies no defaults.

const u64 = 18446744073709551615n;
const fields = {
  prompt: { max_turns: null, token_budget: null, deadline_ms: u64, deadline_at_ms: "json_integer" },
  follow_up: { deadline_at_ms: "json_integer" },
  compact: { max_attempts: 4n, deadline_ms: 60000n, token_budget: 32768n }
};

export function decodeCommandBounds(value, kind) {
  return project(value, kind, false);
}

export function encodeCommandBounds(value, kind) {
  return project(value, kind, true);
}

function project(value, kind, encode) {
  if (typeof kind !== "string" || !Object.hasOwn(fields, kind)) return null;
  if (value === null || typeof value !== "object" || Array.isArray(value) ||
      Object.getPrototypeOf(value) !== Object.prototype) return null;
  const descriptors = Object.getOwnPropertyDescriptors(value);
  const keys = Reflect.ownKeys(descriptors);
  const allowed = fields[kind];
  if (keys.some(key => typeof key !== "string" || !Object.hasOwn(allowed, key) ||
      !Object.hasOwn(descriptors[key], "value") || !descriptors[key].enumerable) ||
      (kind === "compact" && keys.length !== 3)) return null;
  const result = {};
  for (const key of keys) {
    const scalar = descriptors[key].value;
    const maximum = allowed[key];
    if (maximum === "json_integer") {
      if (!Number.isSafeInteger(scalar) || scalar <= 0) return null;
      result[key] = scalar;
    } else {
      if (encode ? typeof scalar !== "bigint" :
          typeof scalar !== "string" || !/^[1-9][0-9]*$/.test(scalar)) return null;
      const integer = encode ? scalar : BigInt(scalar);
      if (integer <= 0n || (maximum !== null && integer > maximum)) return null;
      // Exact comparison also refuses trailing LF, which JS's $ anchor permits.
      if (!encode && integer.toString() !== scalar) return null;
      result[key] = encode ? integer.toString() : integer;
    }
  }
  return result;
}
