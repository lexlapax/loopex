// Concept
// Preserve accepted policy question and ending provenance without authority.
// Technical depth
// Native projections use Buffer identities and BigInt quantities. Terminal kind
// is explicit. Reasons are bounded native bytes and omitted from wire; decoding
// cannot restore them. JSON first crosses the duplicate-aware transport frame.
import { decodeOpenInteraction, encodeOpenInteraction } from "./open-interaction.mjs";

const requestKeys = ["interaction_id", "run_id", "turn", "tool_call_id", "prompt", "choices", "expires_at"];
const wireRequestKeys = [...requestKeys, "producer", "interaction_kind", "status"];
const terminalKeys = ["interaction_id", "run_id", "turn", "tool_call_id", "resolution", "answer_command_id"];
const wireTerminalKeys = ["interaction_id", "run_id", "turn", "tool_call_id", "producer", "interaction_kind", "status", "answer_choice_id", "answer_command_id"];
const statuses = {
  "interaction.resolved": { allowed: "answered", denied: "denied" },
  "interaction.expired": { expired: "expired" },
  "interaction.cancelled": { cancelled: "cancelled" }
};
const outputRecordBytes = 2097152;

export function encodePolicyRequested(value) {
  if (!closed(value, requestKeys)) return null;
  const projected = encodeOpenInteraction({ ...value, producer: "policy_defer", kind: "choice", status: "pending" });
  if (projected === null) return null;
  const wire = { ...projected, interaction_kind: "choice" };
  delete wire.kind;
  return bounded(wire) ? wire : null;
}
export function decodePolicyRequested(value) {
  if (!closed(value, wireRequestKeys) || value.producer !== "policy_defer" || value.interaction_kind !== "choice" || value.status !== "pending" || !requestJSON(value) || !bounded(value)) return null;
  const question = { ...value, kind: "choice" };
  delete question.interaction_kind;
  const projected = decodeOpenInteraction(question);
  return projected === null ? null : Object.fromEntries(requestKeys.map(key => [key, projected[key]]));
}
export function encodePolicyTerminal(kind, value) {
  if (!plain(value) || typeof kind !== "string" || !Object.hasOwn(statuses, kind)) return null;
  const keys = [...terminalKeys];
  if (Object.hasOwn(value, "choice_id")) keys.push("choice_id");
  if (Object.hasOwn(value, "reason")) keys.push("reason");
  if (!closed(value, keys) || (Object.hasOwn(value, "reason") && (!Buffer.isBuffer(value.reason) || value.reason.length > 65536)) ||
      (value.answer_command_id === null ? Object.hasOwn(value, "choice_id") : !Object.hasOwn(value, "choice_id") || value.choice_id === null)) return null;
  if (typeof value.resolution !== "string") return null;
  const status = statuses[kind][value.resolution];
  if (typeof status !== "string" || !Object.hasOwn(statuses[kind], value.resolution)) return null;
  const choice = value.answer_command_id === null ? null : value.choice_id;
  if (!pair(status, choice, value.answer_command_id)) return null;
  const scalars = terminalScalars(value, choice, true);
  if (scalars === null) return null;
  const wire = { ...scalars, producer: "policy_defer", interaction_kind: "choice", status };
  return bounded(wire) ? wire : null;
}
export function decodePolicyTerminal(kind, value) {
  if (!closed(value, wireTerminalKeys) || value.producer !== "policy_defer" || value.interaction_kind !== "choice" ||
      typeof kind !== "string" || !Object.hasOwn(statuses, kind)) return null;
  const resolution = Object.keys(statuses[kind]).find(key => statuses[kind][key] === value.status);
  if (resolution === undefined || !pair(value.status, value.answer_choice_id, value.answer_command_id) ||
      !wireTerminalKeys.filter(key => !["answer_choice_id", "answer_command_id"].includes(key)).every(key => textScalar(value[key])) ||
      !["answer_choice_id", "answer_command_id"].every(key => value[key] === null || textScalar(value[key])) || !bounded(value)) return null;
  const scalars = terminalScalars(value, value.answer_choice_id, false);
  if (scalars === null) return null;
  const native = { ...scalars, resolution };
  delete native.answer_choice_id;
  if (scalars.answer_choice_id !== null) native.choice_id = scalars.answer_choice_id;
  return native;
}
function terminalScalars(value, choice, encode) {
  if (encode ? typeof value.turn !== "bigint" || value.turn <= 0n : typeof value.turn !== "string" || !/^[1-9][0-9]*$/.test(value.turn)) return null;
  const result = { turn: encode ? value.turn.toString() : BigInt(value.turn) };
  const identities = { interaction_id: value.interaction_id, run_id: value.run_id, tool_call_id: value.tool_call_id, answer_command_id: value.answer_command_id, answer_choice_id: choice };
  for (const [key, member] of Object.entries(identities)) {
    const optional = key === "answer_choice_id" || key === "answer_command_id";
    const scalar = member === null && optional ? null : identity(member, key === "answer_choice_id" ? 64 : 65536, encode);
    if (scalar === null && !(member === null && optional)) return null;
    result[key] = scalar;
  }
  return result;
}
function pair(status, choice, command) {
  if (["answered", "denied"].includes(status)) return choice !== null && command !== null;
  return ["expired", "cancelled"].includes(status) && (choice === null) === (command === null);
}
function identity(value, maximum, encode) {
  if (encode) return Buffer.isBuffer(value) && value.length >= 1 && value.length <= maximum ? value.toString("base64url") : null;
  if (typeof value !== "string" || value.length > 87382 || !/^[A-Za-z0-9_-]+$/.test(value)) return null;
  const bytes = Buffer.from(value, "base64url");
  return bytes.length >= 1 && bytes.length <= maximum && bytes.toString("base64url") === value ? bytes : null;
}
function textScalar(value) { return typeof value === "string" && Buffer.from(value, "utf8").toString("utf8") === value; }
function requestJSON(value) {
  return wireRequestKeys.filter(key => key !== "choices").every(key => textScalar(value[key])) && dense(value.choices) &&
    value.choices.length >= 1 && value.choices.length <= 8 && value.choices.every(choice => closed(choice, ["id", "label"]) && textScalar(choice.id) && textScalar(choice.label));
}
function bounded(value) { return Buffer.byteLength(JSON.stringify(value), "utf8") + 1 <= outputRecordBytes; }
function plain(value) {
  if (value === null || typeof value !== "object" || Object.getPrototypeOf(value) !== Object.prototype) return false;
  const descriptors = Object.getOwnPropertyDescriptors(value);
  return Reflect.ownKeys(descriptors).every(key => typeof key === "string" && Object.hasOwn(descriptors[key], "value") && descriptors[key].enumerable);
}
function closed(value, keys) { return plain(value) && Object.keys(value).length === keys.length && keys.every(key => Object.hasOwn(value, key)); }
function dense(value) {
  if (!Array.isArray(value) || Object.getPrototypeOf(value) !== Array.prototype || value.length > 8) return false;
  const descriptors = Object.getOwnPropertyDescriptors(value);
  return Reflect.ownKeys(descriptors).length === value.length + 1 && Reflect.ownKeys(descriptors).every(key => key === "length" ||
    (typeof key === "string" && /^(0|[1-9][0-9]*)$/.test(key) && Number(key) < value.length && Object.hasOwn(descriptors[key], "value") && descriptors[key].enumerable));
}
