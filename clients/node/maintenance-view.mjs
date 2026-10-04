// Concept
// Decode the same active-maintenance payload in public events and snapshots.
//
// Technical depth
// ADR 0043 permits only the captured identity, model and admission bounds.
// Quantities remain BigInt and identities remain opaque Buffers. This closed
// decoder grants no authority and proves no committed episode binding.

import { decodeCheckpointOwner } from "./checkpoint-owner.mjs";

const u64 = 18446744073709551615n;

export function decodeMaintenanceView(value) {
  if (!closed(value, ["active_maintenance"])) return null;
  if (value.active_maintenance === null) return { active_maintenance: null };
  const view = value.active_maintenance;
  if (!closed(view, ["episode_id", "owner", "model", "reasoning", "configuration_version", "bounds"]) ||
      !text(view.model) || view.reasoning !== "none") return null;
  const episode = identity(view.episode_id);
  const owner = decodeCheckpointOwner(view.owner);
  const version = quantity(view.configuration_version, 1n, null);
  if (episode === null || owner === null || version === null) return null;
  const bounds = decodeBounds(view.bounds, owner.kind);
  return bounds === null ? null : {
    active_maintenance: { ...view, episode_id: episode, owner, configuration_version: version, bounds }
  };
}

function decodeBounds(value, kind) {
  if (kind === "compact") {
    if (!closed(value, ["max_attempts", "deadline_ms", "token_budget"])) return null;
    const attempts = quantity(value.max_attempts, 1n, 4n);
    const duration = quantity(value.deadline_ms, 1n, 60000n);
    const tokens = quantity(value.token_budget, 1n, 32768n);
    return [attempts, duration, tokens].includes(null) ? null : {
      max_attempts: attempts, deadline_ms: duration, token_budget: tokens
    };
  }
  if (!closed(value, ["max_attempts", "max_turns", "token_budget", "deadline_ms", "run_deadline"])) return null;
  const attempts = quantity(value.max_attempts, 4n, 4n);
  const turns = quantity(value.max_turns, 1n, null);
  const tokens = quantity(value.token_budget, 1n, null);
  const duration = quantity(value.deadline_ms, 1n, u64);
  const deadline = value.run_deadline === null ? null : quantity(value.run_deadline, 0n, u64);
  return [attempts, turns, tokens, duration].includes(null) ||
    (value.run_deadline !== null && deadline === null) ? null : {
      max_attempts: attempts, max_turns: turns, token_budget: tokens,
      deadline_ms: duration, run_deadline: deadline
    };
}

function quantity(value, minimum, maximum) {
  if (typeof value !== "string" || !/^(0|[1-9][0-9]*)$/.test(value)) return null;
  const integer = BigInt(value);
  return integer.toString() === value && integer >= minimum &&
    (maximum === null || integer <= maximum) ? integer : null;
}

function identity(value) {
  if (typeof value !== "string" || value.length > 87382 || !/^[A-Za-z0-9_-]+$/.test(value)) return null;
  const bytes = Buffer.from(value, "base64url");
  return bytes.length >= 1 && bytes.length <= 65536 && bytes.toString("base64url") === value ? bytes : null;
}

function text(value) {
  return typeof value === "string" && Buffer.byteLength(value, "utf8") >= 1 &&
    Buffer.byteLength(value, "utf8") <= 131072 && Buffer.from(value, "utf8").toString("utf8") === value;
}

function closed(value, keys) {
  return value !== null && typeof value === "object" && !Array.isArray(value) &&
    Object.getPrototypeOf(value) === Object.prototype && Object.keys(value).length === keys.length &&
    keys.every(key => Object.hasOwn(value, key));
}
