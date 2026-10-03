// Concept
// Decode chat's terminal run object without the Elixir codec or runtime.
//
// Technical depth
// Closed binary-keyed payloads follow ADR 0049. Quantities use BigInt to retain
// ordinary turn/token counts beyond u64; references remain opaque Buffers.
// The caller owns framing, the presentation cap and the truth of settlement.

import { decodeContextFailure } from "./context-failure.mjs";

const u64 = 18446744073709551615n;
const observedMax = 55340232221128654844n;
const dimensions = new Set([
  "system_class_tokens", "context_tokens", "context_record_bytes",
  "context_record_depth", "context_record_cardinality",
]);

export function decodeTerminalOutcome(value) {
  if (!closed(value, ["outcome", "details"])) return null;
  const details = value.details;
  let decoded;

  switch (value.outcome) {
    case "completed":
    case "cancelled":
      if (!closed(details, ["cleanup_grace_ms"])) return null;
      decoded = {};
      break;
    case "outcome_unknown": {
      if (!closed(details, ["cleanup_grace_ms", "reconciliation_ref"])) return null;
      const reference = identity(details.reconciliation_ref);
      if (reference === null) return null;
      decoded = { reconciliation_ref: reference };
      break;
    }
    case "bound_reached": {
      if (!closed(details, ["bound", "observed", "declared_limit", "accounting_source", "cleanup_grace_ms"])) return null;
      if (!["max_turns", "token_budget", "deadline"].includes(details.bound)) return null;
      if (![null, "reported", "estimated"].includes(details.accounting_source)) return null;
      const maximum = details.bound === "deadline" ? u64 : null;
      const observed = quantity(details.observed, 0n, maximum);
      const limit = quantity(details.declared_limit, 0n, maximum);
      if (observed === null || limit === null) return null;
      decoded = { bound: details.bound, observed, declared_limit: limit, accounting_source: details.accounting_source };
      break;
    }
    case "failed": {
      if (!closed(details, ["reason", "failure", "cleanup_grace_ms"])) return null;
      if (["model_call_failed", "unreadable_model_answer"].includes(details.reason) && details.failure === null) {
        decoded = { reason: details.reason, failure: null };
      } else if (details.reason === null) {
        const failure = decodeFailure(details.failure);
        if (failure === null) return null;
        decoded = { reason: null, failure };
      } else return null;
      break;
    }
    default: return null;
  }

  const grace = quantity(details.cleanup_grace_ms, 1n, u64);
  return grace === null ? null : { outcome: value.outcome, details: { ...decoded, cleanup_grace_ms: grace } };
}

function decodeFailure(value) {
  if (value?.version === 2) return decodeContextFailure(value);
  if (!closed(value, ["category", "retryable", "dimension", "observed", "limit"]) || value.retryable !== false) return null;
  if (value.category === "deadline_preflight_failed") {
    return value.dimension === null && value.observed === null && value.limit === null ? { ...value } : null;
  }
  if (value.category !== "context_budget_exceeded" || !dimensions.has(value.dimension)) return null;
  const observed = quantity(value.observed, 0n, observedMax);
  const limit = quantity(value.limit, 1n, u64);
  return observed === null || limit === null ? null : { ...value, observed, limit };
}

function closed(value, keys) {
  return value !== null && typeof value === "object" && !Array.isArray(value) &&
    Object.getPrototypeOf(value) === Object.prototype &&
    Object.keys(value).length === keys.length && keys.every(key => Object.hasOwn(value, key));
}

function quantity(value, minimum, maximum) {
  if (typeof value !== "string" || !/^(0|[1-9][0-9]*)$/.test(value)) return null;
  const parsed = BigInt(value);
  return parsed.toString() === value && parsed >= minimum && (maximum === null || parsed <= maximum) ? parsed : null;
}

function identity(value) {
  if (typeof value !== "string" || value.length > 87382 || !/^[A-Za-z0-9_-]+$/.test(value)) return null;
  const decoded = Buffer.from(value, "base64url");
  return decoded.length >= 1 && decoded.length <= 65536 && decoded.toString("base64url") === value ? decoded : null;
}
