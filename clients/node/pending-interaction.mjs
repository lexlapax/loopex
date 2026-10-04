// Concept
// Preserve a pending question's producer, kind and original call identity.
// Technical depth
// Decode exact opaque bytes and BigInt quantities. Model-tool text/choice and
// policy-defer choice are distinct closed branches; reading grants no authority.

const keys = ["interaction_id", "run_id", "turn", "tool_call_id", "status",
  "prompt", "choices", "expires_at", "producer", "kind"];

export function decodePendingInteraction(value) {
  if (!closed(value, keys) || value.status !== "pending" ||
      !["model_tool", "policy_defer"].includes(value.producer) ||
      !["choice", "text"].includes(value.kind) || !text(value.prompt, 2048) ||
      !Array.isArray(value.choices) || value.choices.length > 8) return null;
  const result = { ...value };
  for (const key of ["interaction_id", "run_id", "tool_call_id"]) {
    result[key] = identity(value[key], 65536);
    if (result[key] === null) return null;
  }
  result.turn = quantity(value.turn, 1n, null);
  result.expires_at = quantity(value.expires_at, 0n, 18446744073709551615n);
  if (result.turn === null || result.expires_at === null) return null;
  const choices = [];
  for (const choice of value.choices) {
    if (!closed(choice, ["id", "label"]) || !text(choice.label, 256)) return null;
    const id = identity(choice.id, 64);
    if (id === null || choices.some(previous => previous.id.equals(id))) return null;
    if (value.producer === "model_tool" &&
        (!id.equals(Buffer.from(`choice-${choices.length + 1}`, "utf8")) ||
          choices.some(previous => previous.label === choice.label))) return null;
    choices.push({ id, label: choice.label });
  }
  if (value.kind === "text" ? value.producer !== "model_tool" || choices.length !== 0 : choices.length === 0) return null;
  return { ...result, choices };
}

function identity(value, maximum) {
  if (typeof value !== "string" || value.length > 87382 || !/^[A-Za-z0-9_-]+$/.test(value)) return null;
  const bytes = Buffer.from(value, "base64url");
  return bytes.length >= 1 && bytes.length <= maximum && bytes.toString("base64url") === value ? bytes : null;
}
function quantity(value, minimum, maximum) {
  if (typeof value !== "string" || !/^(0|[1-9][0-9]*)$/.test(value)) return null;
  const integer = BigInt(value);
  return integer.toString() === value && integer >= minimum && (maximum === null || integer <= maximum) ? integer : null;
}
function text(value, maximum) {
  return typeof value === "string" && Buffer.byteLength(value, "utf8") >= 1 &&
    Buffer.byteLength(value, "utf8") <= maximum && Buffer.from(value, "utf8").toString("utf8") === value;
}
function closed(value, required) {
  return value !== null && typeof value === "object" && !Array.isArray(value) &&
    Object.getPrototypeOf(value) === Object.prototype && Object.keys(value).length === required.length &&
    required.every(key => Object.hasOwn(value, key));
}
