// Concept
// Decode the current context failure shared by compact and terminal outcomes.
//
// Technical depth
// ADR 0043 fixes the same closed v2 fields, scopes and numeric relations for
// both enclosing results. This independent codec retains quantities as BigInt;
// callers still validate their own reasons, cleanup and presentation limits.

const u64 = 18446744073709551615n;
const dimensions = new Set([
  "system_class_tokens", "context_tokens", "context_record_bytes",
  "context_record_depth", "context_record_cardinality",
]);
const preparationCauses = new Set([
  "maintenance_model_unconfigured", "maintenance_instructions_unconfigured",
  "maintenance_reasoning_unsupported", "compaction_excerpt_budget_too_small",
  "compaction_no_progress", "compaction_preparation_deadline",
  "maintenance_deadline_unrepresentable", "maintenance_summary_incomplete",
  "maintenance_summary_invalid", "canonical_history_rendering_unsupported",
  "artifact_read_unavailable", "artifact_metadata_unrepresentable",
  "artifact_preparation_count_exhausted", "artifact_preparation_bytes_exhausted",
  "artifact_preparation_deadline", "artifact_preparation_failed",
  "context_projection_invalid",
]);

export function decodeContextFailure(value) {
  if (!plain(value) || value.retryable !== false) return null;
  if (value.version !== 2) return null;
  if (value.category === "context_preparation_failed") {
    return closed(value, ["version", "category", "retryable", "measurement_scope", "cause"]) &&
      [null, "ordinary"].includes(value.measurement_scope) && preparationCauses.has(value.cause) ? { ...value } : null;
  }
  if (!["context_budget_exceeded", "thinking_exchange_headroom"].includes(value.category) ||
      !closed(value, ["version", "category", "retryable", "measurement_scope", "dimension", "observed", "limit", "hard_limit"]) ||
      !["ordinary", "maintenance"].includes(value.measurement_scope) || !dimensions.has(value.dimension)) return null;
  const result = quantities(value, ["observed", "limit", "hard_limit"], u64);
  if (result === null || result.limit === 0n || result.hard_limit === 0n ||
      (result.dimension === "context_record_bytes" && result.hard_limit !== 65536n)) return null;
  if (result.category === "thinking_exchange_headroom") {
    return ["context_tokens", "context_record_bytes"].includes(result.dimension) &&
      result.limit <= result.hard_limit && result.observed > result.limit ? result : null;
  }
  return result.limit === result.hard_limit &&
    (result.dimension === "system_class_tokens" ? result.observed >= result.limit : result.observed > result.limit) ? result : null;
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

