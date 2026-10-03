// Concept
// Decode the completed standalone compaction result independently of Elixir.
//
// Technical depth
// ADR 0043 fixes the closed result and failure unions. Quantities retain their
// exact values as BigInt, and checkpoint identities remain opaque Buffers.
// The enclosing transport owns framing and size limits; this proves no command
// completion or authority and never manufactures a run outcome.

import { decodeContextFailure } from "./context-failure.mjs";

const u64 = 18446744073709551615n;
export function decodeCompactResult(value) {
  if (!closed(value, ["disposition", "checkpoint_id", "failure", "usage", "cleanup"])) return null;
  if (!["checkpointed", "unchanged", "failed"].includes(value.disposition) ||
      !["confirmed", "unknown"].includes(value.cleanup)) return null;
  const checkpoint = value.checkpoint_id === null ? null : identity(value.checkpoint_id);
  if (value.checkpoint_id !== null && checkpoint === null) return null;
  let failure = null;
  if (value.disposition === "failed") {
    failure = decodeFailure(value.failure);
    if (failure === null) return null;
  } else if (value.failure !== null || value.cleanup !== "confirmed" ||
             (value.disposition === "checkpointed" ? checkpoint === null : checkpoint !== null)) return null;
  const usage = decodeUsage(value.usage);
  return usage === null ? null : { ...value, checkpoint_id: checkpoint, failure, usage };
}

function decodeUsage(value) {
  const keys = ["attempts", "reported_tokens", "estimated_tokens", "total_tokens"];
  const converted = quantities(value, keys, null, true);
  return converted !== null && converted.total_tokens === converted.reported_tokens + converted.estimated_tokens ? converted : null;
}

function decodeFailure(value) {
  if (!plain(value) || value.retryable !== false) return null;
  if (["model_call_failed", "cancelled"].includes(value.category)) {
    return closed(value, ["category", "retryable"]) ? { ...value } : null;
  }
  if (value.category === "bound_reached") {
    if (!closed(value, ["category", "retryable", "bound", "observed", "declared_limit", "accounting_source"]) ||
        !["max_attempts", "deadline_ms", "token_budget"].includes(value.bound) ||
        ![null, "reported", "estimated"].includes(value.accounting_source) ||
        (value.bound === "max_attempts" && value.accounting_source !== null)) return null;
    const result = quantities(value, ["observed", "declared_limit"], value.bound === "deadline_ms" ? u64 : null);
    return result !== null && result.declared_limit > 0n ? result : null;
  }
  return decodeContextFailure(value);
}

function quantities(value, keys, maximum, exact = false) {
  if (!plain(value) || (exact && !closed(value, keys))) return null;
  const result = { ...value };
  for (const key of keys) {
    if (typeof value[key] !== "string" || !/^(0|[1-9][0-9]*)$/.test(value[key])) return null;
    const integer = BigInt(value[key]);
    if (integer.toString() !== value[key] || (maximum !== null && integer > maximum)) return null;
    result[key] = integer;
  }
  return result;
}

function plain(value) {
  return value !== null && typeof value === "object" && !Array.isArray(value) &&
    Object.getPrototypeOf(value) === Object.prototype;
}

function closed(value, keys) {
  return plain(value) && Object.keys(value).length === keys.length && keys.every(key => Object.hasOwn(value, key));
}

function identity(value) {
  if (typeof value !== "string" || value.length > 87382 || !/^[A-Za-z0-9_-]+$/.test(value)) return null;
  const decoded = Buffer.from(value, "base64url");
  return decoded.length >= 1 && decoded.length <= 65536 && decoded.toString("base64url") === value ? decoded : null;
}
