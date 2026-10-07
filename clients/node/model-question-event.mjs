// Concept
// Preserve requested and terminal model questions without manufacturing evidence.
// Technical depth
// Delegate captured model-question domains to OpenInteraction. Check closed
// data descriptors before member access. Requests retain null captures; terminal
// answers, command captures and settlement sequences are checked together.
import { decodeOpenInteraction, encodeOpenInteraction } from "./open-interaction.mjs";

const captures = ["answer", "command_digest", "command_id", "disposition", "settlement_sequence"];
const keys = ["interaction_id", "run_id", "turn", "tool_call_id", "status", "prompt", "choices", "expires_at", "producer", "interaction_kind", ...captures];

export function decodeModelQuestionRequested(value) { return project(value, decodeOpenInteraction); }
export function encodeModelQuestionRequested(value) { return project(value, encodeOpenInteraction); }

function project(value, codec) {
  if (!closed(value) || value.producer !== "model_tool" || value.status !== "pending" ||
      !captures.every(key => value[key] === null)) return null;
  const question = { ...value, kind: value.interaction_kind };
  delete question.interaction_kind;
  for (const key of captures) delete question[key];
  const projected = codec(question);
  if (projected === null) return null;
  const result = { ...projected, interaction_kind: projected.kind };
  delete result.kind;
  for (const key of captures) result[key] = null;
  return result;
}

function closed(value, required = keys) {
  if (value === null || typeof value !== "object" || Object.getPrototypeOf(value) !== Object.prototype) return false;
  const descriptors = Object.getOwnPropertyDescriptors(value);
  const names = Reflect.ownKeys(descriptors);
  return names.length === required.length && names.every(key => typeof key === "string" &&
    required.includes(key) && Object.hasOwn(descriptors[key], "value") && descriptors[key].enumerable);
}


export function decodeModelQuestionTerminal(value) { return terminal(value, false); }
export function encodeModelQuestionTerminal(value) { return terminal(value, true); }

// Concept: a terminal retains the original question and exact admitted evidence.
// Technical depth: validate its descriptors before member access, then reuse the
// pending question codec for only its captured question fields. No event kind,
// authority, transport generation or open terminal view is manufactured.
function terminal(value, encode) {
  if (!plain(value) || !["answered", "declined", "expired", "cancelled"].includes(value.disposition) ||
      value.status !== value.disposition || value.producer !== "model_tool") return null;
  const choice = value.disposition === "answered" && value.interaction_kind === "choice";
  if (!closed(value, choice ? [...keys, "choice_id"] : keys)) return null;
  const question = { ...value, kind: value.interaction_kind, status: "pending" };
  delete question.interaction_kind;
  delete question.choice_id;
  for (const key of captures) delete question[key];
  const projected = (encode ? encodeOpenInteraction : decodeOpenInteraction)(question);
  if (projected === null) return null;
  const sequence = settlement(value.settlement_sequence, encode);
  if (sequence === null) return null;
  let evidence;
  if (value.disposition === "expired") {
    if (!["answer", "command_id", "command_digest"].every(key => value[key] === null)) return null;
    evidence = { answer: null, command_id: null, command_digest: null };
  } else if (value.disposition === "cancelled") {
    if (value.answer !== null) return null;
    if (value.command_id === null && value.command_digest === null) {
      evidence = { answer: null, command_id: null, command_digest: null };
    } else {
      const command = identity(value.command_id, 65536, encode);
      if (command === null || typeof value.command_digest !== "string" || !/^[0-9a-f]{64}$/.test(value.command_digest)) return null;
      evidence = { answer: null, command_id: command, command_digest: value.command_digest };
    }
  } else {
    const command = identity(value.command_id, 65536, encode);
    if (command === null || typeof value.command_digest !== "string" || !/^[0-9a-f]{64}$/.test(value.command_digest)) return null;
    let answer;
    if (value.disposition === "declined") {
      if (!closed(value.answer, ["disposition"]) || value.answer.disposition !== "declined") return null;
      answer = { disposition: "declined" };
    } else if (value.interaction_kind === "text") {
      if (!closed(value.answer, ["text"]) || !text(value.answer.text, 8192)) return null;
      answer = { text: value.answer.text };
    } else {
      if (!closed(value.answer, ["choice_id", "label"])) return null;
      const id = identity(value.choice_id, 64, encode);
      const answerId = identity(value.answer.choice_id, 64, encode);
      if (id === null || answerId === null || !same(id, answerId, encode)) return null;
      const offered = projected.choices.find(member => same(member.id, id, encode));
      if (!offered || value.answer.label !== offered.label) return null;
      answer = { choice_id: id, label: offered.label };
      evidence = { choice_id: id };
    }
    evidence = { ...evidence, answer, command_id: command, command_digest: value.command_digest };
  }
  const result = { ...projected, interaction_kind: projected.kind, status: value.disposition,
    disposition: value.disposition, settlement_sequence: sequence, ...evidence };
  delete result.kind;
  return result;
}

function plain(value) {
  if (value === null || typeof value !== "object" || Object.getPrototypeOf(value) !== Object.prototype) return false;
  const descriptors = Object.getOwnPropertyDescriptors(value);
  return Reflect.ownKeys(descriptors).every(key => typeof key === "string" &&
    Object.hasOwn(descriptors[key], "value") && descriptors[key].enumerable);
}
function same(left, right, encode) { return encode ? left === right : left.equals(right); }
function identity(value, maximum, encode) {
  if (encode) return Buffer.isBuffer(value) && value.length >= 1 && value.length <= maximum ? value.toString("base64url") : null;
  if (typeof value !== "string" || value.length > 87382 || !/^[A-Za-z0-9_-]+$/.test(value)) return null;
  const bytes = Buffer.from(value, "base64url");
  return bytes.length >= 1 && bytes.length <= maximum && bytes.toString("base64url") === value ? bytes : null;
}
function settlement(value, encode) {
  if (encode ? typeof value !== "bigint" : typeof value !== "string" || value.length > 20 || !/^[1-9][0-9]*$/.test(value)) return null;
  const integer = encode ? value : BigInt(value);
  return integer >= 1n && integer <= 18446744073709551615n ? (encode ? integer.toString() : integer) : null;
}
function text(value, maximum) {
  return typeof value === "string" && Buffer.byteLength(value, "utf8") >= 1 &&
    Buffer.byteLength(value, "utf8") <= maximum && Buffer.from(value, "utf8").toString("utf8") === value;
}
