// Concept
// Decode the committed configuration allowlist without private host captures.
// Technical depth
// Exact quantities use BigInt. Configuration version is unbounded positive;
// reply/context/system ceilings remain positive uint64. Instruction provenance
// is a closed version/digest pair. No decoding grants configuration authority.

const u64 = 18446744073709551615n;
const keys = ["configuration_version", "model", "reasoning", "max_tokens",
  "context_token_budget", "system_class_tokens", "instructions"];

export function decodeConfiguration(value) {
  if (!closed(value, keys) || !text(value.model) ||
      !["default", "none", "low", "medium", "high"].includes(value.reasoning) ||
      !closed(value.instructions, ["version", "digest"])) return null;
  const { version, digest } = value.instructions;
  if (typeof version !== "string" || version.length < 1 || version.length > 64 ||
      !/^[A-Za-z0-9]/.test(version) || /[^A-Za-z0-9._-]/.test(version) ||
      typeof digest !== "string" || digest.length !== 64 || !/^[0-9a-f]{64}$/.test(digest)) return null;
  const result = { ...value, instructions: { version, digest } };
  for (const key of ["configuration_version", "max_tokens", "context_token_budget", "system_class_tokens"]) {
    if (typeof value[key] !== "string" || !/^[1-9][0-9]*$/.test(value[key])) return null;
    const integer = BigInt(value[key]);
    if (integer.toString() !== value[key] || (key !== "configuration_version" && integer > u64)) return null;
    result[key] = integer;
  }
  return result;
}

export function decodeConfiguredEvent(value) {
  if (!closed(value, ["command_id", "configuration"]) || typeof value.command_id !== "string" ||
      value.command_id.length > 87382 || !/^[A-Za-z0-9_-]+$/.test(value.command_id)) return null;
  const command = Buffer.from(value.command_id, "base64url");
  const configuration = decodeConfiguration(value.configuration);
  return command.length < 1 || command.length > 65536 || command.toString("base64url") !== value.command_id ||
    configuration === null ? null : { command_id: command, configuration };
}

function text(value) {
  return typeof value === "string" && Buffer.byteLength(value, "utf8") >= 1 &&
    Buffer.byteLength(value, "utf8") <= 131072 && Buffer.from(value, "utf8").toString("utf8") === value;
}

function closed(value, required) {
  return value !== null && typeof value === "object" && !Array.isArray(value) &&
    Object.getPrototypeOf(value) === Object.prototype && Object.keys(value).length === required.length &&
    required.every(key => Object.hasOwn(value, key));
}
