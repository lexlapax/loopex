// Concept
// Preserve committed active bounds independently of the Elixir codec.
// Technical depth
// Four required data members decode decimal quantities to BigInt. Only the
// absolute deadline permits null or zero. No Number coercion or clock occurs.
const keys = ["max_turns", "token_budget", "deadline_ms", "deadline"];
const u64 = 18446744073709551615n;

export function decodeActiveBounds(value) { return project(value, false); }
export function encodeActiveBounds(value) { return project(value, true); }

function project(value, encode) {
  if (value === null || typeof value !== "object" || Array.isArray(value) ||
      Object.getPrototypeOf(value) !== Object.prototype) return null;
  const descriptors = Object.getOwnPropertyDescriptors(value);
  const ownKeys = Reflect.ownKeys(descriptors);
  if (ownKeys.length !== keys.length || ownKeys.some(key =>
      typeof key !== "string" || !keys.includes(key) ||
      !Object.hasOwn(descriptors[key], "value") || !descriptors[key].enumerable)) return null;
  const result = {};
  for (const key of keys) {
    const scalar = descriptors[key].value;
    if (key === "deadline" && scalar === null) { result[key] = null; continue; }
    if (encode ? typeof scalar !== "bigint" :
        typeof scalar !== "string" || !/^(0|[1-9][0-9]*)$/.test(scalar)) return null;
    const integer = encode ? scalar : BigInt(scalar);
    if (!encode && integer.toString() !== scalar) return null;
    if (integer < (key === "deadline" ? 0n : 1n) ||
        (["deadline", "deadline_ms"].includes(key) && integer > u64)) return null;
    result[key] = encode ? integer.toString() : integer;
  }
  return result;
}
