// Concept
// Decode checkpoint coverage and ownership without private maintenance content.
// Technical depth
// Original-source references use the three conversation variants. Quantities
// retain BigInt precision, identities retain Buffers and strategy revision is
// the literal number 3. The serial owner separately authenticates coverage.

import { decodeCheckpointOwner } from "./checkpoint-owner.mjs";

export function decodeCheckpoint(value) {
  if (!closed(value, ["checkpoint_id", "episode_id", "covered_range", "prior_checkpoint_id", "strategy",
      "strategy_revision", "model", "reasoning", "configuration_version", "usage", "owner", "source_excerpted"]) ||
      value.strategy !== "loopex.compaction.reference" || value.strategy_revision !== 3 || value.reasoning !== "none" ||
      typeof value.source_excerpted !== "boolean" || !text(value.model)) return null;
  const checkpoint = identity(value.checkpoint_id);
  const episode = identity(value.episode_id);
  const prior = value.prior_checkpoint_id === null ? null : identity(value.prior_checkpoint_id);
  const owner = decodeCheckpointOwner(value.owner);
  const version = quantity(value.configuration_version, 1n);
  const range = decodeRange(value.covered_range);
  const usage = decodeUsage(value.usage);
  if (checkpoint === null || episode === null || (value.prior_checkpoint_id !== null && prior === null) ||
      (prior !== null && checkpoint.equals(prior)) || owner === null || version === null || range === null || usage === null) return null;
  return { ...value, checkpoint_id: checkpoint, episode_id: episode, prior_checkpoint_id: prior,
    owner, configuration_version: version, covered_range: range, usage };
}

function decodeRange(value) {
  if (!closed(value, ["unit_count", "record_count", "source_count", "first", "last", "first_kept", "digest"]) ||
      typeof value.digest !== "string" || value.digest.length !== 64 || !/^[0-9a-f]{64}$/.test(value.digest)) return null;
  const units = quantity(value.unit_count, 1n);
  const records = quantity(value.record_count, 1n);
  const sources = quantity(value.source_count, 1n);
  const first = reference(value.first);
  const last = reference(value.last);
  const kept = value.first_kept === null ? null : reference(value.first_kept);
  if (units === null || records === null || sources === null || units > sources || records > sources ||
      first === null || last === null || (value.first_kept !== null && kept === null) ||
      (kept !== null && (sameReference(first, kept) || sameReference(last, kept)))) return null;
  return { ...value, unit_count: units, record_count: records, source_count: sources, first, last, first_kept: kept };
}

function reference(value) {
  const variants = { session_command: ["kind", "run_id", "command_id"], session_assistant: ["kind", "run_id", "turn"],
    session_tool_result: ["kind", "run_id", "turn", "call_id"] };
  if (value === null || typeof value !== "object" || typeof value.kind !== "string" ||
      !Object.hasOwn(variants, value.kind) || !closed(value, variants[value.kind])) return null;
  const run = identity(value.run_id);
  if (run === null) return null;
  if (value.kind === "session_command") {
    const command = identity(value.command_id);
    return command === null ? null : { ...value, run_id: run, command_id: command };
  }
  const turn = quantity(value.turn, 1n);
  if (turn === null) return null;
  if (value.kind === "session_tool_result") {
    const call = identity(value.call_id);
    return call === null ? null : { ...value, run_id: run, turn, call_id: call };
  }
  return { ...value, run_id: run, turn };
}

function sameReference(left, right) {
  if (left.kind !== right.kind || !left.run_id.equals(right.run_id)) return false;
  if (left.kind === "session_command") return left.command_id.equals(right.command_id);
  return left.turn === right.turn && (left.kind !== "session_tool_result" || left.call_id.equals(right.call_id));
}

function decodeUsage(value) {
  const keys = ["attempts", "reported_tokens", "estimated_tokens", "total_tokens"];
  if (!closed(value, keys)) return null;
  const result = {};
  for (const key of keys) {
    result[key] = quantity(value[key], 0n);
    if (result[key] === null) return null;
  }
  return result.total_tokens === result.reported_tokens + result.estimated_tokens ? result : null;
}

function quantity(value, minimum) {
  if (typeof value !== "string" || !/^(0|[1-9][0-9]*)$/.test(value)) return null;
  const result = BigInt(value);
  return result.toString() === value && result >= minimum ? result : null;
}

function identity(value) {
  if (typeof value !== "string" || value.length > 87382 || !/^[A-Za-z0-9_-]+$/.test(value)) return null;
  const bytes = Buffer.from(value, "base64url");
  return bytes.length >= 1 && bytes.length <= 65536 && bytes.toString("base64url") === value ? bytes : null;
}

function text(value) {
  return typeof value === "string" && Buffer.byteLength(value, "utf8") >= 1 && Buffer.byteLength(value, "utf8") <= 131072 &&
    Buffer.from(value, "utf8").toString("utf8") === value;
}

function closed(value, keys) {
  return value !== null && typeof value === "object" && !Array.isArray(value) && Object.getPrototypeOf(value) === Object.prototype &&
    Object.keys(value).length === keys.length && keys.every(key => Object.hasOwn(value, key));
}
