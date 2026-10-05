// Concept
// Decode a complete revision-3 public session snapshot at one committed cursor.
// Technical depth
// Reuse the independently implemented closed payload decoders. Configuration
// is required; optional current views remain null. Cross-view checks do not
// authenticate durable history or grant controller/interaction authority.

import { decodeConfiguration } from "./configuration.mjs";
import { decodeCheckpoint } from "./checkpoint.mjs";
import { decodeMaintenanceView } from "./maintenance-view.mjs";
import { decodeCompactCompletion } from "./compact-result.mjs";
import { decodeOpenInteraction } from "./open-interaction.mjs";

const keys = ["snapshot_revision", "session_id", "event_sequence", "active_run_id", "active_run_phase",
  "configuration", "checkpoint", "active_maintenance", "open_interaction", "last_compact"];

export function decodeSnapshot(value) {
  if (!closed(value, keys) || value.snapshot_revision !== 3 ||
      ![null, "admitted_unstaged", "started"].includes(value.active_run_phase)) return null;
  const session = identity(value.session_id, 256);
  const run = value.active_run_id === null ? null : identity(value.active_run_id, 65536);
  const cursor = quantity(value.event_sequence);
  const configuration = decodeConfiguration(value.configuration);
  const checkpoint = value.checkpoint === null ? null : decodeCheckpoint(value.checkpoint);
  const question = value.open_interaction === null ? null : decodeOpenInteraction(value.open_interaction);
  const maintenance = decodeMaintenanceView({ active_maintenance: value.active_maintenance });
  const compact = value.last_compact === null ? null : decodeCompactCompletion(value.last_compact);
  if (session === null || cursor === null || configuration === null ||
      (value.active_run_id !== null && run === null) || (value.checkpoint !== null && checkpoint === null) ||
      (value.open_interaction !== null && question === null) || maintenance === null ||
      (value.last_compact !== null && compact === null)) return null;
  const active = maintenance.active_maintenance;
  if ((run === null) !== (value.active_run_phase === null) ||
      (question !== null && (run === null || active !== null || !question.run_id.equals(run))) ||
      (active !== null && (active.configuration_version !== configuration.configuration_version ||
        (active.owner.kind === "run" ? run === null || !active.owner.id.equals(run) : run !== null))) ||
      (checkpoint !== null && checkpoint.configuration_version > configuration.configuration_version) ||
      (cursor === 0n && [run, checkpoint, active, question, compact].some(member => member !== null))) return null;
  return { ...value, session_id: session, event_sequence: cursor, active_run_id: run,
    configuration, checkpoint, open_interaction: question, active_maintenance: active, last_compact: compact };
}

function identity(value, maximum) {
  if (typeof value !== "string" || value.length > 87382 || !/^[A-Za-z0-9_-]+$/.test(value)) return null;
  const bytes = Buffer.from(value, "base64url");
  return bytes.length >= 1 && bytes.length <= maximum && bytes.toString("base64url") === value ? bytes : null;
}
function quantity(value) {
  if (typeof value !== "string" || !/^(0|[1-9][0-9]*)$/.test(value)) return null;
  const integer = BigInt(value);
  return integer.toString() === value && integer <= 18446744073709551615n ? integer : null;
}
function closed(value, required) {
  return value !== null && typeof value === "object" && !Array.isArray(value) &&
    Object.getPrototypeOf(value) === Object.prototype && Object.keys(value).length === required.length &&
    required.every(key => Object.hasOwn(value, key));
}
