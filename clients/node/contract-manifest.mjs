// Concept
// Independently reproduce the canonical bytes used by M7 schema digests.
//
// Technical depth
// This handles integer-only JSON schema data. Maps become sorted lists of
// key/value tuples inside the loopex_map tuple, following loopex.canonical.v1.
// Current client pins below identify the complete foreground and daemon manifests.
import { createHash } from "node:crypto";

const atom = (name) => Buffer.concat([Buffer.from([119, name.length]), Buffer.from(name)]);
const tuple = (members) => Buffer.concat([Buffer.from([104, members.length]), ...members]);
const uint32 = (value) => { const bytes = Buffer.alloc(4); bytes.writeUInt32BE(value); return bytes; };
const binary = (value) => {
  if (!value.isWellFormed()) throw new Error("invalid Unicode string");
  const bytes = Buffer.from(value, "utf8");
  return Buffer.concat([Buffer.from([109]), uint32(bytes.length), bytes]);
};
const list = (members) => members.length === 0 ? Buffer.from([106]) :
  Buffer.concat([Buffer.from([108]), uint32(members.length), ...members, Buffer.from([106])]);

// Concept: schema values contain data properties, so encoding reads no getter.
// Technical depth: inspect every own descriptor before taking member values;
// frozen ordinary properties remain data descriptors and retain the same bytes.
function dataDescriptors(value) {
  const descriptors = Object.getOwnPropertyDescriptors(value);
  if (Object.values(descriptors).some((descriptor) => !Object.hasOwn(descriptor, "value"))) {
    throw new Error("accessor schema properties refused");
  }
  return descriptors;
}

function encode(value) {
  if (value === null) return atom("nil");
  if (typeof value === "boolean") return atom(value ? "true" : "false");
  if (typeof value === "string") return binary(value);
  if (typeof value === "number") {
    if (!Number.isSafeInteger(value)) throw new Error("integer-only schema data required");
    if (value >= 0 && value <= 255) return Buffer.from([97, value]);
    if (value >= -2147483648 && value <= 2147483647) {
      const bytes = Buffer.alloc(5); bytes[0] = 98; bytes.writeInt32BE(value, 1); return bytes;
    }
    let magnitude = BigInt(value < 0 ? -value : value);
    const digits = [];
    while (magnitude > 0n) { digits.push(Number(magnitude & 255n)); magnitude >>= 8n; }
    return Buffer.from([110, digits.length, value < 0 ? 1 : 0, ...digits]);
  }
  if (Array.isArray(value)) {
    if (Reflect.ownKeys(value).length !== value.length + 1 || Object.keys(value).length !== value.length) {
      throw new Error("plain dense JSON array required");
    }
    const descriptors = dataDescriptors(value);
    const members = Array.from({ length: descriptors.length.value }, (_unused, index) => descriptors[index].value);
    if (members.length > 0 && members.length <= 65535 && members.every((member) =>
      Number.isInteger(member) && member >= 0 && member <= 255)) {
      const size = Buffer.alloc(2); size.writeUInt16BE(members.length);
      return Buffer.concat([Buffer.from([107]), size, Buffer.from(members)]);
    }
    return list(members.map(encode));
  }
  if (typeof value === "object" && Object.getPrototypeOf(value) === Object.prototype) {
    if (Reflect.ownKeys(value).some((key) => typeof key !== "string") ||
      Reflect.ownKeys(value).length !== Object.keys(value).length) throw new Error("binary map keys required");
    const descriptors = dataDescriptors(value);
    const entries = Object.entries(descriptors).map(([key, descriptor]) => [binary(key), encode(descriptor.value)]);
    entries.sort(([left], [right]) => Buffer.compare(left, right));
    return tuple([atom("loopex_map"), list(entries.map((pair) => tuple(pair)))]);
  }
  throw new Error("plain integer-only schema data required");
}

export function canonicalSchemaBytes(value) {
  return Buffer.concat([Buffer.from([131]), encode(value)]);
}

export function canonicalSchemaDigest(value) {
  return createHash("sha256").update(canonicalSchemaBytes(value)).digest("hex");
}

// Concept: duplicate members must be rejected before map conversion.
// Technical depth: the recursive walk preserves decoded key identity and number
// lexemes; JSON.parse is used only for a single validated string token.
export function parseSchemaJson(bytes) {
  const text = new TextDecoder("utf-8", { fatal: true }).decode(bytes);
  let position = 0;
  const whitespace = () => { while (/[ \t\r\n]/.test(text[position] ?? "") && position < text.length) position++; };
  const string = () => {
    const start = position++;
    while (position < text.length) {
      const character = text[position++];
      if (character === "\\") position++;
      else if (character === '\"') {
        const value = JSON.parse(text.slice(start, position));
        if (!value.isWellFormed()) throw new Error("invalid Unicode string");
        return value;
      }
    }
    throw new Error("unterminated string");
  };
  const value = () => {
    whitespace();
    const character = text[position];
    if (character === '\"') return string();
    if (character === "{" || character === "[") {
      const object = character === "{";
      const output = object ? {} : [];
      const keys = new Set();
      position++; whitespace();
      if (text[position] === (object ? "}" : "]")) { position++; return output; }
      for (;;) {
        let key;
        if (object) {
          if (text[position] !== '\"') throw new Error("object key required");
          key = string();
          if (keys.has(key)) throw new Error("duplicate member");
          keys.add(key); whitespace();
          if (text[position++] !== ":") throw new Error("colon required");
        }
        const member = value();
        if (object) Object.defineProperty(output, key, { value: member, enumerable: true, writable: true, configurable: true });
        else output.push(member);
        whitespace();
        if (text[position] === (object ? "}" : "]")) { position++; return output; }
        if (text[position++] !== ",") throw new Error("comma required");
        whitespace();
      }
    }
    for (const [literal, member] of [["null", null], ["true", true], ["false", false]]) {
      if (text.startsWith(literal, position)) { position += literal.length; return member; }
    }
    const number = /^-?(?:0|[1-9][0-9]*)/.exec(text.slice(position));
    if (!number) throw new Error("invalid schema value");
    position += number[0].length;
    const member = Number(number[0]);
    if (!Number.isSafeInteger(member)) throw new Error("invalid schema integer");
    return member;
  };
  const output = value(); whitespace();
  if (position !== text.length) throw new Error("trailing schema bytes");
  return output;
}

// Concept: compare a server's identity with a separately retained client pin.
// Technical depth: this returns a verdict only. The owning connection must gate
// session requests and close on false; this helper sends no request or replay.
export function matchesContractIdentity(reply, expected) {
  return reply !== null && typeof reply === "object" &&
    Object.getPrototypeOf(reply) === Object.prototype &&
    expected !== null && typeof expected === "object" &&
    Object.getPrototypeOf(expected) === Object.prototype &&
    typeof expected.generation === "string" &&
    typeof expected.schemaDigest === "string" &&
    /^[0-9a-f]{64}$/.test(expected.schemaDigest) &&
    reply.type === "initialized" &&
    reply.selected_generation === expected.generation &&
    reply.exact_schema_sha256 === expected.schemaDigest;
}

// Concept: retain client expectations independently from the server reply.
// Technical depth: these literal identities are checked against complete canonical
// preimages by current-contract-manifest-vectors.mjs before transport qualification.
export const CURRENT_CONTRACTS = Object.freeze({
  foreground: Object.freeze({ generation: "loopex.experimental/3", schemaDigest: "2becc338d4ca5de3afa84e9d6adb038ee65b0690a3233947c93dd05e7049f237" }),
  daemon: Object.freeze({ generation: "loopex.experimental/4", schemaDigest: "9306e4aeb2ffb9aab3cf4dac94db5a1e4699f09d3f58cc57e2fa79a7e63ef7b9" }),
});

// Concept: the complete current manifest has one closed top-level recipe.
// Technical depth: reject duplicate JSON members first, then require all seven
// keys and exact inventory-to-definition coverage. Canonical encoding separately
// refuses values outside the integer-only schema data domain.
export function parseContractManifest(bytes) {
  const manifest = parseSchemaJson(bytes);
  const required = ["generation", "canonicalization_revision", "methods", "record_families", "error_codes", "limits", "payload_definitions"];
  if (manifest === null || typeof manifest !== "object" || Array.isArray(manifest) ||
      Object.keys(manifest).length !== required.length || required.some(key => !Object.hasOwn(manifest, key)) ||
      !["loopex.experimental/3", "loopex.experimental/4"].includes(manifest.generation) ||
      manifest.canonicalization_revision !== "loopex.canonical.v1") throw new Error("invalid current contract manifest");
  for (const key of ["methods", "record_families", "error_codes"]) {
    const inventory = manifest[key];
    if (!Array.isArray(inventory) || inventory.length === 0 || inventory.some(value => typeof value !== "string") ||
        new Set(inventory).size !== inventory.length) throw new Error("invalid ordered manifest inventory");
  }
  const definitions = manifest.payload_definitions;
  const object = value => value !== null && typeof value === "object" && !Array.isArray(value);
  if (!object(manifest.limits) || !object(definitions) || Object.keys(definitions).length === 0 ||
      !object(definitions.requests?.methods) || !object(definitions.records)) throw new Error("missing manifest definitions");
  const sameKeys = (value, keys) => Object.keys(value).length === keys.length && keys.every(key => Object.hasOwn(value, key));
  if (!sameKeys(definitions.requests.methods, ["initialize", ...manifest.methods]) ||
      !sameKeys(definitions.records, manifest.record_families) ||
      Object.values(definitions.requests.methods).some(value => value.closed !== true) ||
      Object.values(definitions.records).some(value => value.closed !== true)) throw new Error("incomplete closed manifest definitions");
  if (!object(definitions.nested)) throw new Error("missing nested manifest definitions");
  function references(value) {
    if (value === null || typeof value !== "object") return;
    if (!Array.isArray(value) && Object.hasOwn(value, "definition_ref")) {
      if (typeof value.definition_ref !== "string") throw new Error("invalid manifest definition reference");
      let definition = definitions.nested;
      for (const key of value.definition_ref.split(".")) {
        if (!object(definition) || !Object.hasOwn(definition, key)) throw new Error("unresolved manifest definition reference");
        definition = definition[key];
      }
    }
    for (const child of Object.values(value)) references(child);
  }
  references(definitions);
  canonicalSchemaBytes(manifest);
  return manifest;
}
