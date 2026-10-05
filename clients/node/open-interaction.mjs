// Concept
// Preserve pending questions and answered policy questions at a public cursor.
// Technical depth
// Native opaque identities are Buffers and exact quantities are BigInt. Policy
// answers remain open while resolution is owed; model answers have no open
// answered branch. Data descriptors are checked before reading any members.
const keys = ["interaction_id", "run_id", "turn", "tool_call_id", "status", "prompt", "choices", "expires_at", "producer", "kind"];
const answerKeys = [...keys, "answer_choice_id", "answer_command_id"];
const eventKeys = ["interaction_id", "run_id", "turn", "tool_call_id", "producer", "interaction_kind", "status", "answer_choice_id", "answer_command_id"];
const u64 = 18446744073709551615n;
export function decodeOpenInteraction(value) { return project(value, false); }
export function encodeOpenInteraction(value) { return project(value, true); }
export function decodeAnswerAdmitted(value) { return admitted(value, false); }
export function encodeAnswerAdmitted(value) { return admitted(value, true); }
function project(value, encode) {
  if (!plain(value)) return null;
  const answered = value.status === "answered";
  if (!closed(value, answered ? answerKeys : keys) ||
      (answered ? value.producer !== "policy_defer" || value.kind !== "choice" : value.status !== "pending") ||
      !["model_tool", "policy_defer"].includes(value.producer) || !["choice", "text"].includes(value.kind) ||
      !text(value.prompt, 2048) || !dense(value.choices, 8)) return null;
  const result = { ...value };
  for (const key of ["interaction_id", "run_id", "tool_call_id"]) {
    result[key] = identity(value[key], 65536, encode);
    if (result[key] === null) return null;
  }
  result.turn = quantity(value.turn, 1n, null, encode);
  result.expires_at = quantity(value.expires_at, 0n, u64, encode);
  if (result.turn === null || result.expires_at === null) return null;
  const choices = [];
  for (const choice of value.choices) {
    if (!closed(choice, ["id", "label"]) || !text(choice.label, 256)) return null;
    const id = identity(choice.id, 64, encode);
    if (id === null || choices.some(previous => same(previous.id, id, encode))) return null;
    const ordered = Buffer.from(`choice-${choices.length + 1}`, "utf8");
    if (value.producer === "model_tool" &&
        (!same(id, encode ? ordered.toString("base64url") : ordered, encode) ||
          choices.some(previous => previous.label === choice.label))) return null;
    choices.push({ id, label: choice.label });
  }
  if (value.kind === "text" ? value.producer !== "model_tool" || choices.length !== 0 : choices.length === 0) return null;
  result.choices = choices;
  if (answered) {
    const choice = identity(value.answer_choice_id, 64, encode);
    const command = identity(value.answer_command_id, 65536, encode);
    if (choice === null || command === null || !choices.some(offered => same(offered.id, choice, encode))) return null;
    result.answer_choice_id = choice;
    result.answer_command_id = command;
  }
  return result;
}
function admitted(value, encode) {
  if (!closed(value, eventKeys) || value.producer !== "policy_defer" ||
      value.interaction_kind !== "choice" || value.status !== "answered") return null;
  const result = { ...value };
  result.turn = quantity(value.turn, 1n, null, encode);
  if (result.turn === null) return null;
  for (const key of ["interaction_id", "run_id", "tool_call_id", "answer_choice_id", "answer_command_id"]) {
    result[key] = identity(value[key], key === "answer_choice_id" ? 64 : 65536, encode);
    if (result[key] === null) return null;
  }
  return result;
}
function same(left, right, encode) { return encode ? left === right : left.equals(right); }
function identity(value, maximum, encode) {
  if (encode) return Buffer.isBuffer(value) && value.length >= 1 && value.length <= maximum ? value.toString("base64url") : null;
  if (typeof value !== "string" || value.length > 87382 || !/^[A-Za-z0-9_-]+$/.test(value)) return null;
  const bytes = Buffer.from(value, "base64url");
  return bytes.length >= 1 && bytes.length <= maximum && bytes.toString("base64url") === value ? bytes : null;
}
function quantity(value, minimum, maximum, encode) {
  if (encode ? typeof value !== "bigint" : typeof value !== "string" || !/^(0|[1-9][0-9]*)$/.test(value)) return null;
  const integer = encode ? value : BigInt(value);
  if ((!encode && integer.toString() !== value) || integer < minimum || (maximum !== null && integer > maximum)) return null;
  return encode ? integer.toString() : integer;
}
function text(value, maximum) {
  return typeof value === "string" && Buffer.byteLength(value, "utf8") >= 1 &&
    Buffer.byteLength(value, "utf8") <= maximum && Buffer.from(value, "utf8").toString("utf8") === value;
}
function plain(value) {
  if (value === null || typeof value !== "object" || Object.getPrototypeOf(value) !== Object.prototype) return false;
  const descriptors = Object.getOwnPropertyDescriptors(value);
  return Reflect.ownKeys(descriptors).every(key => typeof key === "string" &&
    Object.hasOwn(descriptors[key], "value") && descriptors[key].enumerable);
}
function closed(value, required) {
  return plain(value) && Object.keys(value).length === required.length && required.every(key => Object.hasOwn(value, key));
}
function dense(value, maximum) {
  if (!Array.isArray(value) || Object.getPrototypeOf(value) !== Array.prototype || value.length > maximum) return false;
  const descriptors = Object.getOwnPropertyDescriptors(value);
  const names = Reflect.ownKeys(descriptors);
  return names.length === value.length + 1 && names.every(key => key === "length" ||
    (typeof key === "string" && /^(0|[1-9][0-9]*)$/.test(key) && Number(key) < value.length &&
      Object.hasOwn(descriptors[key], "value") && descriptors[key].enumerable));
}
