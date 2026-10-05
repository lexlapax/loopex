// Concept
// Decode the approved eleven-member current inspection without host captures.
// Technical depth
// Reuse the exact independent payload decoders; quantities remain BigInt and
// identities remain Buffers. No default, clock or historical projection occurs.
import { decodeActiveBounds } from "./active-bounds.mjs";
import { decodeConfiguration } from "./configuration.mjs";
import { decodeCheckpoint } from "./checkpoint.mjs";
import { decodeMaintenanceView } from "./maintenance-view.mjs";
import { decodeOpenInteraction } from "./open-interaction.mjs";
const keys = ["status", "event_sequence", "active_run_id", "cleanup_grace_ms", "active_context_token_budget", "pending_work_ids", "open_interaction", "configuration", "active_bounds", "checkpoint", "active_maintenance"];
const u64 = 18446744073709551615n;
export function decodeInspection(value) {
  if (!plainTree(value) || !closed(value, keys) || value.status !== "active") return null;
  const cursor = quantity(value.event_sequence, 0n);
  const cleanup = quantity(value.cleanup_grace_ms, 0n);
  const context = value.active_context_token_budget === null ? null : quantity(value.active_context_token_budget, 1n);
  const run = value.active_run_id === null ? null : identity(value.active_run_id);
  if (cursor === null || cleanup === null ||
      (value.active_context_token_budget !== null && context === null) ||
      (value.active_run_id !== null && run === null) || !Array.isArray(value.pending_work_ids) || value.pending_work_ids.length > 1024) return null;
  const pending = value.pending_work_ids.map(identity);
  if (pending.includes(null)) return null;
  const configuration = decodeConfiguration(value.configuration);
  const bounds = value.active_bounds === null ? null : decodeActiveBounds(value.active_bounds);
  const interaction = value.open_interaction === null ? null : decodeOpenInteraction(value.open_interaction);
  const checkpoint = value.checkpoint === null ? null : decodeCheckpoint(value.checkpoint);
  const maintenance = decodeMaintenanceView({ active_maintenance: value.active_maintenance });
  if (configuration === null || (value.active_bounds !== null && bounds === null) ||
      (value.open_interaction !== null && interaction === null) ||
      (value.checkpoint !== null && checkpoint === null) || maintenance === null || (run === null) !== (bounds === null)) return null;
  return { ...value, event_sequence: cursor, cleanup_grace_ms: cleanup, active_context_token_budget: context,
    active_run_id: run, pending_work_ids: pending, configuration, active_bounds: bounds,
    open_interaction: interaction, checkpoint, active_maintenance: maintenance.active_maintenance };
}
function quantity(value, minimum) {
  if (typeof value !== "string" || !/^(0|[1-9][0-9]*)$/.test(value)) return null;
  const integer = BigInt(value);
  return integer.toString() === value && integer >= minimum && integer <= u64 ? integer : null;
}
function identity(value) {
  if (typeof value !== "string" || value.length > 87382 || !/^[A-Za-z0-9_-]+$/.test(value)) return null;
  const bytes = Buffer.from(value, "base64url");
  return bytes.length >= 1 && bytes.length <= 65536 && bytes.toString("base64url") === value ? bytes : null;
}
function closed(value, required) {
  return value !== null && typeof value === "object" && !Array.isArray(value) &&
    Object.getPrototypeOf(value) === Object.prototype && Object.keys(value).length === required.length && required.every(key => Object.hasOwn(value, key));
}
// Concept: nested shared decoders receive only plain JSON data, never getters.
// Technical depth: examine descriptors recursively before invoking a decoder;
// the inherited frame depth/cardinality limits remain unchanged.
function plainTree(value, depth = 0) {
  if (depth > 16) return false;
  if (value === null || typeof value === "string" || typeof value === "boolean") return true;
  if (typeof value === "number") return Number.isSafeInteger(value);
  if (typeof value !== "object") return false;
  const array = Array.isArray(value);
  if (Object.getPrototypeOf(value) !== (array ? Array.prototype : Object.prototype)) return false;
  const descriptors = Object.getOwnPropertyDescriptors(value);
  const names = Reflect.ownKeys(descriptors);
  if (array && (value.length > 1024 || names.length !== value.length + 1)) return false;
  if (!array && names.length > 1024) return false;
  return names.every(key => {
    if (array && key === "length") return true;
    const d = descriptors[key];
    return typeof key === "string" && Object.hasOwn(d, "value") && d.enumerable &&
      (!array || /^(0|[1-9][0-9]*)$/.test(key) && Number(key) < value.length) && plainTree(d.value, depth + 1);
  });
}
