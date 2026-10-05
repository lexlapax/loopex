// Concept
// Preserve requested model questions without manufacturing answer evidence.
// Technical depth
// Delegate the exact model pending domains to OpenInteraction. Check the closed
// shell's data descriptors before reading members, and retain all five nulls.
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

function closed(value) {
  if (value === null || typeof value !== "object" || Object.getPrototypeOf(value) !== Object.prototype) return false;
  const descriptors = Object.getOwnPropertyDescriptors(value);
  const names = Reflect.ownKeys(descriptors);
  return names.length === keys.length && names.every(key => typeof key === "string" &&
    keys.includes(key) && Object.hasOwn(descriptors[key], "value") && descriptors[key].enumerable);
}
