// Concept
// Select an existing interaction payload by producer and enclosing event kind.
// Technical depth
// This dormant pure composition serves the two independent clients when their
// complete M7 generations activate. Existing codecs own exact payload domains;
// enclosing frame bounds and prior-cursor relations remain the caller's duties.
import { decodeModelQuestionRequested, encodeModelQuestionRequested, decodeModelQuestionTerminal, encodeModelQuestionTerminal } from "./model-question-event.mjs";
import { decodePolicyRequested, encodePolicyRequested, decodePolicyTerminal, encodePolicyTerminal } from "./policy-interaction-event.mjs";
import { decodeAnswerAdmitted, encodeAnswerAdmitted } from "./open-interaction.mjs";

const modelEndings = new Map([
  ["interaction.answered", "answered"], ["interaction.declined", "declined"],
  ["interaction.expired", "expired"], ["interaction.cancelled", "cancelled"]
]);
const policyEndings = new Set(["interaction.resolved", "interaction.expired", "interaction.cancelled"]);

export function encodeInteractionEvent(kind, value) { return project(kind, value, true); }
export function decodeInteractionEvent(kind, value) { return project(kind, value, false); }

function project(kind, value, encode) {
  // Check descriptors before reading producer or disposition. Nested payloads
  // cross the existing codecs' own inert-data checks before any member access.
  if (typeof kind !== "string" || !plain(value)) return null;
  const producer = value.producer;
  if (kind === "interaction.answer_admitted") {
    return producer === "policy_defer" ? (encode ? encodeAnswerAdmitted : decodeAnswerAdmitted)(value) : null;
  }
  if (kind === "interaction.requested") {
    if (producer === "model_tool") return (encode ? encodeModelQuestionRequested : decodeModelQuestionRequested)(value);
    if (encode ? !Object.hasOwn(value, "producer") : producer === "policy_defer") {
      return (encode ? encodePolicyRequested : decodePolicyRequested)(value);
    }
    return null;
  }
  if (producer === "model_tool") {
    if (!modelEndings.has(kind) || value.disposition !== modelEndings.get(kind)) return null;
    return (encode ? encodeModelQuestionTerminal : decodeModelQuestionTerminal)(value);
  }
  if (policyEndings.has(kind) && (encode ? !Object.hasOwn(value, "producer") : producer === "policy_defer")) {
    return (encode ? encodePolicyTerminal : decodePolicyTerminal)(kind, value);
  }
  return null;
}

function plain(value) {
  if (value === null || typeof value !== "object" || Object.getPrototypeOf(value) !== Object.prototype) return false;
  const descriptors = Object.getOwnPropertyDescriptors(value);
  return Reflect.ownKeys(descriptors).every(key => typeof key === "string" &&
    Object.hasOwn(descriptors[key], "value") && descriptors[key].enumerable);
}
