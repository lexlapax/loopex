// Concept
// Preserve cancelled creation's exact request and command identities.
//
// Technical depth
// Accepted ADR 0061 fixes six closed members; no session or disposition exists.
// Opaque native commands are Buffers. Descriptor checks refuse accessors before
// reading values. These dormant codecs prove neither non-commit nor authority.

const keys = ["type", "request_id", "method", "command_id", "status", "reason"];
const typedArray = Object.getPrototypeOf(Uint8Array.prototype);
const byteLength = Object.getOwnPropertyDescriptor(typedArray, "byteLength").get;
const byteOffset = Object.getOwnPropertyDescriptor(typedArray, "byteOffset").get;
const backingBuffer = Object.getOwnPropertyDescriptor(typedArray, "buffer").get;

export function decodeCreationCancellation(value) {
  if (!closed(value) || !fixed(value) || !request(value.request_id)) return null;
  const command = identity(value.command_id);
  if (command === null) return null;
  return {
    type: "admission", request_id: value.request_id, method: "session.create",
    command_id: command, status: "refused", reason: "creation_cancelled"
  };
}

export function encodeCreationCancellation(value) {
  if (!closed(value) || !fixed(value) || !request(value.request_id) ||
      !Buffer.isBuffer(value.command_id) || !ArrayBuffer.isView(value.command_id)) return null;
  const size = byteLength.call(value.command_id);
  if (size < 1 || size > 256) return null;
  const command = Buffer.from(new Uint8Array(backingBuffer.call(value.command_id), byteOffset.call(value.command_id), size));
  return {
    type: "admission", request_id: value.request_id, method: "session.create",
    command_id: command.toString("base64url"), status: "refused", reason: "creation_cancelled"
  };
}

function fixed(value) {
  return value.type === "admission" && value.method === "session.create" &&
    value.status === "refused" && value.reason === "creation_cancelled";
}

function request(value) {
  return typeof value === "string" && value.length >= 1 && value.length <= 64 &&
    !/[^A-Za-z0-9._~-]/.test(value);
}

function identity(value) {
  if (typeof value !== "string" || value.length < 1 || value.length > 342 ||
      /[^A-Za-z0-9_-]/.test(value)) return null;
  const bytes = Buffer.from(value, "base64url");
  return bytes.length >= 1 && bytes.length <= 256 && bytes.toString("base64url") === value ? bytes : null;
}

function closed(value) {
  if (value === null || typeof value !== "object" || Object.getPrototypeOf(value) !== Object.prototype) return false;
  const descriptors = Object.getOwnPropertyDescriptors(value);
  const names = Reflect.ownKeys(descriptors);
  return names.length === keys.length && names.every(key => typeof key === "string" &&
    keys.includes(key) && Object.hasOwn(descriptors[key], "value") && descriptors[key].enumerable);
}
