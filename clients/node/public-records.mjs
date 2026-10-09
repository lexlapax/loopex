// Concept
// Check every durable event, snapshot and progress record a server publishes
// against this client's own closed reading of the current contract, before the
// record reaches a caller.
//
// Technical depth
// Both connections share this independent validation. Each event kind has one
// closed payload: ordinary kinds are checked here and every other kind through
// its independently authored decoder. A record outside the contract throws, so
// a workflow never acts on a map that merely carries a familiar kind. Opaque
// identities must be canonical base64url and quantities canonical decimal;
// nothing is rounded through a JavaScript number.
import { isDeepStrictEqual } from "node:util";
import { decodeCheckpoint } from "./checkpoint.mjs";
import { decodeCompactCompletion } from "./compact-result.mjs";
import { decodeCompactionProgress } from "./compaction-progress.mjs";
import { decodeConfiguredEvent } from "./configuration.mjs";
import { decodeInteractionEvent } from "./interaction-event.mjs";
import { decodeMaintenanceView } from "./maintenance-view.mjs";
import { decodeSnapshot } from "./snapshot.mjs";
import { decodeTerminalOutcome } from "./terminal-outcome.mjs";
import { decodeToolFinished } from "./tool-finished.mjs";

const toolId = /^[a-z][a-z0-9_]*(\.[a-z][a-z0-9_]*)*$/;
const ordinary = {
  "user.message_appended": { command_id: identity, run_id: identity, content_b64: content },
  "run.started": { command_id: identity, run_id: identity },
  "assistant.message_appended": { run_id: identity, turn_id: identity, content_b64: content },
  "tool.started": {
    run_id: identity, turn_id: identity, tool_call_id: identity, operation_id: identity,
    tool_id: value => typeof value === "string" && value.length <= 128 && toolId.test(value),
    tool_version: value => typeof value === "string" && Buffer.byteLength(value) <= 131072 &&
      /^[0-9]+\.[0-9]+\.[0-9]+$/.test(value)
  },
  "steer.resolved": {
    command_id: identity, run_id: identity,
    disposition: value => ["applied", "unapplied", "cancelled"].includes(value),
    reason: value => value === null || text(value, 0)
  },
  "follow_up.resolved": {
    command_id: identity, run_id: identity,
    disposition: value => value === "cancelled", reason: value => value === "aborted"
  },
  "session.settled": { run_id: identity }
};
const decoders = {
  "tool.finished": decodeToolFinished,
  "run.finished": decodeRunFinished,
  "session.configured": decodeConfiguredEvent,
  "context.compacted": decodeCheckpoint,
  "context.maintenance_changed": decodeMaintenanceView,
  "context.compaction_finished": decodeCompactCompletion
};
// Concept: transient progress families carry exactly their public members.
// Technical depth: the stream domain is 32 lowercase hexadecimal bytes; indexes
// are safe JSON integers; text and fragments are bounded UTF-8 without
// terminal escapes; quantities stay BigInt-checked decimal text.
const u64 = value => quantity(value) !== null;
const domain = value => {
  const bytes = identity(value, 32);
  return bytes !== null && bytes.length === 32 && /^[0-9a-f]{32}$/.test(bytes.toString("latin1"));
};
const index = value => Number.isSafeInteger(value) && value >= 0;
const safe = value => typeof value === "string" && value.isWellFormed() && Buffer.byteLength(value) <= 65536 &&
  !value.includes("\u001b");
const nullable = check => value => value === null || check(value);
const closure = value => ["complete", "abandoned"].includes(value);
const base = { kind: () => true, turn_id: value => identity(value) !== null, stream_domain_id: domain, base_event_sequence: u64 };
const progressMembers = {
  text_delta: { ...base, model_sequence: u64, content_index: index, text: safe },
  reasoning_delta: { ...base, model_sequence: u64, content_index: index, text: safe },
  tool_call_delta: { ...base, model_sequence: u64, call_index: index,
    tool_call_id: nullable(value => identity(value) !== null), name: nullable(safe), arguments_fragment: nullable(safe) },
  tool_progress: { ...base, tool_call_id: value => identity(value) !== null, progress_sequence: u64,
    stream: value => ["stdout", "stderr", "progress"].includes(value), byte_offset: u64,
    chunk_b64: value => { const bytes = content(value); return bytes !== null && bytes.length <= 65536; } },
  model_stream_closed: { ...base, disposition: closure, delta_count: u64 },
  tool_stream_closed: { ...base, tool_call_id: value => identity(value) !== null, disposition: closure, progress_count: u64 }
};
const interactionKinds = new Set(["interaction.requested", "interaction.answer_admitted",
  "interaction.resolved", "interaction.expired", "interaction.cancelled",
  "interaction.answered", "interaction.declined"]);

// Throws unless the record is one complete current event of a known kind.
export function validateEvent(record) {
  const event = record?.event;
  if (!closed(record, ["type", "session_id", "event"]) || record.type !== "event" ||
      identity(record.session_id, 256) === null ||
      !closed(event, ["kind", "event_id", "event_sequence", "data"]) ||
      identity(event.event_id) === null || quantity(event.event_sequence) === null) {
    throw new Error("invalid event envelope");
  }
  const { kind, data } = event;
  let valid;
  if (Object.hasOwn(ordinary, kind)) {
    const members = ordinary[kind];
    valid = closed(data, Object.keys(members)) &&
      Object.entries(members).every(([key, check]) => check(data[key]) !== null && check(data[key]) !== false);
  } else if (interactionKinds.has(kind)) {
    valid = decodeInteractionEvent(kind, data) !== null;
  } else if (Object.hasOwn(decoders, kind)) {
    valid = decoders[kind](data) !== null;
  } else valid = false;
  if (!valid) throw new Error(`invalid ${typeof kind === "string" ? kind : "unknown"} event`);
  return event;
}

// Throws unless the snapshot is complete and anchored at its own cursor.
export function validateSnapshot(record) {
  const snapshot = closed(record, ["type", "request_id", "session_id", "event_cursor", "snapshot", "open_interaction"])
    ? decodeSnapshot(record.snapshot) : null;
  const cursor = quantity(record?.event_cursor);
  if (snapshot === null || record.type !== "snapshot" || record.session_id !== record.snapshot.session_id ||
      cursor === null || cursor !== snapshot.event_sequence ||
      !isDeepStrictEqual(record.open_interaction, record.snapshot.open_interaction)) throw new Error("invalid snapshot");
  return record;
}

// Throws unless the record is one closed progress item of a current family;
// an activity item must be the closed compaction progress payload.
export function validateProgress(record) {
  const item = record?.progress;
  const members = Object.hasOwn(progressMembers, item?.kind ?? "") ? progressMembers[item.kind] : null;
  const valid = closed(record, ["type", "session_id", "progress"]) && record.type === "progress" &&
    identity(record.session_id, 256) !== null &&
    (item?.kind === "context.compaction_progress" ? decodeCompactionProgress(item) !== null :
      members !== null && closed(item, Object.keys(members)) &&
      Object.entries(members).every(([key, check]) => check(item[key])));
  if (!valid) throw new Error("invalid progress");
  return record;
}

// Concept: run endings share the closed terminal outcome algebra.
// Technical depth: the flat event adds run, command and reconciliation
// references; failed carries exactly one of reason or failure.
function decodeRunFinished(data) {
  const extra = data?.outcome === "bound_reached" ? ["bound", "observed", "declared_limit", "accounting_source"]
    : data?.outcome === "failed" ? [Object.hasOwn(data, "failure") ? "failure" : "reason"] : [];
  if (!closed(data, ["run_id", "outcome", "reconciliation_ref", "cleanup_grace_ms", "command_id", ...extra]) ||
      identity(data.run_id) === null ||
      (data.command_id !== null && identity(data.command_id) === null) ||
      (data.reconciliation_ref !== null && identity(data.reconciliation_ref) === null)) return null;
  const details = { cleanup_grace_ms: data.cleanup_grace_ms };
  for (const key of extra) details[key] = data[key];
  if (data.outcome === "failed") Object.assign(details, { reason: data.reason ?? null, failure: data.failure ?? null });
  if (data.outcome === "outcome_unknown") details.reconciliation_ref = data.reconciliation_ref;
  else if (data.reconciliation_ref !== null) return null;
  return decodeTerminalOutcome({ outcome: data.outcome, details });
}

function closed(value, keys) {
  if (value === null || typeof value !== "object" || Object.getPrototypeOf(value) !== Object.prototype) return false;
  const descriptors = Object.getOwnPropertyDescriptors(value);
  const names = Reflect.ownKeys(descriptors);
  return names.length === keys.length && names.every(key => typeof key === "string" && keys.includes(key) &&
    Object.hasOwn(descriptors[key], "value") && descriptors[key].enumerable);
}

function identity(value, maximum = 65536) {
  if (typeof value !== "string" || !/^[A-Za-z0-9_-]+$/.test(value) || value.length > Math.ceil(maximum * 4 / 3)) return null;
  const bytes = Buffer.from(value, "base64url");
  return bytes.length >= 1 && bytes.length <= maximum && bytes.toString("base64url") === value ? bytes : null;
}

function content(value) {
  if (typeof value !== "string" || value.length > 131072 || !/^[A-Za-z0-9_-]*$/.test(value)) return null;
  const bytes = Buffer.from(value, "base64url");
  return bytes.toString("base64url") === value ? bytes : null;
}

function text(value, minimum) {
  return typeof value === "string" && value.isWellFormed() &&
    Buffer.byteLength(value) >= minimum && Buffer.byteLength(value) <= 131072;
}

function quantity(value) {
  if (typeof value !== "string" || value.length > 20 || !/^(0|[1-9][0-9]*)$/.test(value)) return null;
  const integer = BigInt(value);
  return integer <= 18446744073709551615n ? integer : null;
}
