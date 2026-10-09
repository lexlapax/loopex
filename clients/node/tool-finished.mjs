// Concept
// Decode the tool terminal a session committed, in either of its two closed
// public shapes: receipt-backed with an operation identity, or reported without
// one, such as an answered model question or a policy refusal.
//
// Technical depth
// Accepted ADR 0067 selects the variant by exact member set with no fallback.
// Opaque identities become Buffers and artifact sizes BigInt, so no quantity is
// rounded. A missing operation identity grants nothing and proves neither that
// no operation exists nor that nothing ran. Inert data descriptors are checked
// before any member is read.
const receiptBacked = ["run_id", "turn_id", "tool_call_id", "operation_id", "tool_id", "outcome", "reason", "artifacts"];
const operationLess = ["run_id", "turn_id", "tool_call_id", "tool_id", "outcome", "reason", "artifacts"];
const artifactKeys = ["digest", "size", "locator", "media_type", "role", "use_canonicalization_version", "use_digest", "use_locator"];
const outcomes = ["completed", "failed", "denied", "cancelled", "outcome_unknown", "cancelled_workspace_lease_lost"];
const u64Max = 18446744073709551615n;

export function decodeToolFinished(value) {
  const receipt = closed(value, receiptBacked);
  if (!receipt && !closed(value, operationLess)) return null;

  const decoded = {};
  for (const key of ["run_id", "turn_id", "tool_call_id", ...(receipt ? ["operation_id"] : [])]) {
    decoded[key] = identity(value[key]);
    if (decoded[key] === null) return null;
  }

  if (value.tool_id === null && !receipt) decoded.tool_id = null;
  else if (toolId(value.tool_id)) decoded.tool_id = value.tool_id;
  else return null;

  if (!outcomes.includes(value.outcome)) return null;
  decoded.outcome = value.outcome;

  if (value.reason === null) decoded.reason = null;
  else if (!receipt && typeof value.reason === "string" && value.reason.isWellFormed() &&
      Buffer.byteLength(value.reason, "utf8") <= 131072) decoded.reason = value.reason;
  else return null;

  if (!Array.isArray(value.artifacts) || Object.getPrototypeOf(value.artifacts) !== Array.prototype) return null;
  if (!receipt) {
    if (value.artifacts.length !== 0) return null;
    decoded.artifacts = [];
    return decoded;
  }
  decoded.artifacts = [];
  for (const member of value.artifacts) {
    const artifact = artifactUse(member);
    if (artifact === null) return null;
    decoded.artifacts.push(artifact);
  }
  return decoded;
}

function artifactUse(value) {
  if (!closed(value, artifactKeys) || !digest(value.digest) || !digest(value.use_digest) ||
      !safeText(value.locator, 1024) || !safeText(value.media_type, 255) ||
      value.role !== "tool_output" || value.use_canonicalization_version !== "loopex.canonical.v1" ||
      value.use_locator !== `use:${value.use_digest}`) return null;
  const size = quantity(value.size);
  if (size === null) return null;
  return {
    digest: value.digest,
    size,
    locator: value.locator,
    media_type: value.media_type,
    role: value.role,
    use_canonicalization_version: value.use_canonicalization_version,
    use_digest: value.use_digest,
    use_locator: value.use_locator
  };
}

function closed(value, required) {
  if (value === null || typeof value !== "object" || Object.getPrototypeOf(value) !== Object.prototype) return false;
  const descriptors = Object.getOwnPropertyDescriptors(value);
  const names = Reflect.ownKeys(descriptors);
  return names.length === required.length && names.every(key => typeof key === "string" &&
    required.includes(key) && Object.hasOwn(descriptors[key], "value") && descriptors[key].enumerable);
}

function identity(value) {
  if (typeof value !== "string" || value.length < 2 || value.length > 87382 || !/^[A-Za-z0-9_-]+$/.test(value)) return null;
  const bytes = Buffer.from(value, "base64url");
  return bytes.length >= 1 && bytes.length <= 65536 && bytes.toString("base64url") === value ? bytes : null;
}

function toolId(value) {
  return typeof value === "string" && value.length >= 1 && value.length <= 128 &&
    /^[a-z][a-z0-9_]*(\.[a-z][a-z0-9_]*)*$/.test(value);
}

function digest(value) {
  return typeof value === "string" && /^[0-9a-f]{64}$/.test(value);
}

function safeText(value, maximum) {
  if (typeof value !== "string" || !value.isWellFormed()) return false;
  const size = Buffer.byteLength(value, "utf8");
  return size >= 1 && size <= maximum && !/[\p{Cc}\p{Cf}\p{Zl}\p{Zp}]/u.test(value);
}

function quantity(value) {
  if (typeof value !== "string" || value.length > 20 || !/^(0|[1-9][0-9]*)$/.test(value)) return null;
  const integer = BigInt(value);
  return integer <= u64Max ? integer : null;
}
