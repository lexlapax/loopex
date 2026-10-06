// Concept
// Independently decode the accepted authored configure request without defaults.
// Technical depth
// Input is a JSON object already admitted by the transport's duplicate-aware
// framing boundary. Quantities use BigInt; identities use opaque Buffer bytes.
const changesKeys = ["model", "reasoning", "instructions", "max_tokens", "context_token_budget", "system_class_tokens"];
const quantityKeys = ["max_tokens", "context_token_budget", "system_class_tokens"];
const instructionKeys = ["version", "base", "environment", "appendix"];

function members(value) {
  if (value === null || typeof value !== "object" || Object.getPrototypeOf(value) !== Object.prototype) return null;
  const descriptors = Object.getOwnPropertyDescriptors(value);
  if (Reflect.ownKeys(descriptors).some(key => typeof key !== "string")) return null;
  if (Object.values(descriptors).some(entry => !entry.enumerable || !("value" in entry))) return null;
  return Object.fromEntries(Object.entries(descriptors).map(([key, entry]) => [key, entry.value]));
}

function closed(value, keys) {
  const data = members(value);
  return data && Object.keys(data).length === keys.length && keys.every(key => Object.hasOwn(data, key)) ? data : null;
}

function text(value, minimum, maximum = Infinity) {
  return typeof value === "string" && Buffer.from(value, "utf8").toString("utf8") === value &&
    Buffer.byteLength(value, "utf8") >= minimum && Buffer.byteLength(value, "utf8") <= maximum;
}

function identity(value, maximum) {
  if (typeof value !== "string" || !/^[A-Za-z0-9_-]+$/.test(value)) return null;
  const bytes = Buffer.from(value, "base64url");
  return bytes.length >= 1 && bytes.length <= maximum && bytes.toString("base64url") === value ? bytes : null;
}

function positiveU64(value) {
  if (typeof value !== "string" || !/^[1-9][0-9]*$/.test(value)) return null;
  const integer = BigInt(value);
  return integer <= 18446744073709551615n ? integer : null;
}

export function decodeConfigureChanges(value) {
  const data = members(value);
  if (!data || Object.keys(data).length === 0 || Object.keys(data).some(key => !changesKeys.includes(key))) return null;
  const output = {};
  for (const [key, member] of Object.entries(data)) {
    if (key === "model") {
      if (!text(member, 1)) return null;
      output[key] = member;
    } else if (key === "reasoning") {
      if (!["default", "none", "low", "medium", "high"].includes(member)) return null;
      output[key] = member;
    } else if (key === "instructions") {
      const sections = closed(member, instructionKeys);
      if (!sections || !text(sections.version, 1, 64) || !/^[A-Za-z0-9][A-Za-z0-9._-]{0,63}$/.test(sections.version) ||
          !text(sections.base, 1, 32768) || !text(sections.environment, 0, 4096) || !text(sections.appendix, 0, 16384)) return null;
      output[key] = sections;
    } else if (quantityKeys.includes(key)) {
      const integer = positiveU64(member);
      if (integer === null) return null;
      output[key] = integer;
    }
  }
  return output;
}

export function decodeConfigureRequest(value, transport) {
  if (transport !== "foreground" && transport !== "daemon") return null;
  const keys = ["request_id", "method", "command_id", "changes"];
  if (transport === "daemon") keys.push("writer_epoch");
  const data = closed(value, keys);
  if (!data || data.method !== "session.configure" || !text(data.request_id, 1, 64) || !/^[A-Za-z0-9._~-]+$/.test(data.request_id)) return null;
  const commandId = identity(data.command_id, 65536);
  const changes = decodeConfigureChanges(data.changes);
  if (commandId === null || changes === null) return null;
  const output = { request_id: data.request_id, command_id: commandId, changes };
  if (transport === "daemon") {
    const writer = identity(data.writer_epoch, 64);
    if (writer === null) return null;
    output.writer_epoch = writer;
  }
  return output;
}
