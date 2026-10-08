// Concept
// Check the exact cancelled-creation record without inferring runtime outcome.
//
// Technical depth
// Retained schema/vector hashes pin all literal cases independently of Elixir.
// Descriptor and byte-boundary controls supplement the closed JSON fixtures.
// No transport, generation, Store read or activation runs through this program.
import assert from "node:assert/strict";
import { createHash } from "node:crypto";
import { readFileSync } from "node:fs";
import { decodeCreationCancellation, encodeCreationCancellation } from "./creation-cancellation.mjs";

const [vectorPath, schemaPath] = process.argv.slice(2);
if (!vectorPath || !schemaPath) throw new Error("usage: creation-cancellation-vectors.mjs <vectors> <schema>");
const vectors = readFileSync(vectorPath);
const schemas = readFileSync(schemaPath);
assert.equal(createHash("sha256").update(vectors).digest("hex"), "6846995cc9801c0ac72a0b843a819195b49cd8ac88b20fece4b75ed0d54f29ef");
assert.equal(createHash("sha256").update(schemas).digest("hex"), "410a328e4d98dcf4a96647fe3bdb9c458b588693f047101f3a3eab029349de3f");
const fixture = JSON.parse(vectors.toString("utf8"));
const schema = JSON.parse(schemas.toString("utf8"));
assert.equal(fixture.format, "loopex.experimental.payload-vectors/1");
assert.equal(fixture.contract, "creation_cancelled_admission");
assert.equal(fixture.cases.length, 102);
assert.equal(fixture.cases.filter(value => Object.hasOwn(value, "decoded")).length, 10);
assert.equal(schema.contract, fixture.contract);
assert.equal(schema.revision, 1);
assert.equal(schema.activation, "standalone_payload_not_independently_served");
assert.deepEqual(schema.required, ["type", "request_id", "method", "command_id", "status", "reason"]);
assert.equal(schema.additional_members, "refuse");
assert.equal(schema.type, "admission");
assert.equal(schema.method, "session.create");
assert.equal(schema.status, "refused");
assert.equal(schema.reason, "creation_cancelled");
assert.deepEqual(schema.request_id, { encoding: "ascii", min_bytes: 1, max_bytes: 64, grammar: "[A-Za-z0-9._~-]+" });
assert.deepEqual(schema.command_id, { encoding: "canonical_unpadded_base64url_of_original_opaque_bytes", original_min_bytes: 1, original_max_bytes: 256, encoded_max_bytes: 342 });
assert.deepEqual(schema.forbidden_members, ["session_id", "disposition"]);
assert.equal(schema.envelope, "complete_admission_record");

for (const vector of fixture.cases) {
  const decoded = decodeCreationCancellation(vector.input);
  const retained = decoded === null ? null : { ...decoded, command_id: { opaque_hex: decoded.command_id.toString("hex") } };
  assert.deepEqual(retained, vector.error ? null : vector.decoded, vector.name);
  if (!vector.error) assert.deepEqual(encodeCreationCancellation(decoded), vector.input, vector.name);
}

const wire = fixture.cases[0].input;
const native = { ...wire, command_id: Buffer.from([255]) };
let boundaryChecks = 0;
for (const size of [0, 1, 256, 257]) {
  const bytes = Buffer.alloc(size, 255);
  const encoded = encodeCreationCancellation({ ...native, command_id: bytes });
  const decoded = decodeCreationCancellation({ ...wire, command_id: bytes.toString("base64url") });
  if (size === 1 || size === 256) {
    assert.equal(encoded.command_id, bytes.toString("base64url"));
    assert.deepEqual(decoded.command_id, bytes);
  } else {
    assert.equal(encoded, null);
    assert.equal(decoded, null);
  }
  boundaryChecks += 2;
}
for (const size of [0, 1, 64, 65]) {
  const request = "r".repeat(size);
  assert.equal(decodeCreationCancellation({ ...wire, request_id: request }) !== null, size === 1 || size === 64);
  assert.equal(encodeCreationCancellation({ ...native, request_id: request }) !== null, size === 1 || size === 64);
  boundaryChecks += 2;
}

for (const [object, codec] of [[wire, decodeCreationCancellation], [native, encodeCreationCancellation]]) {
  for (const key of Object.keys(object)) {
    let invoked = 0;
    const getter = { ...object };
    Object.defineProperty(getter, key, { enumerable: true, get() { invoked++; return object[key]; } });
    assert.equal(codec(getter), null);
    assert.equal(invoked, 0);
    boundaryChecks++;
    const setter = { ...object };
    Object.defineProperty(setter, key, { enumerable: true, set() { invoked++; } });
    assert.equal(codec(setter), null);
    assert.equal(invoked, 0);
    boundaryChecks++;
    const hidden = { ...object };
    Object.defineProperty(hidden, key, { value: object[key], enumerable: false });
    assert.equal(codec(hidden), null);
    boundaryChecks++;
  }
  assert.equal(codec(Object.assign(Object.create(null), object)), null);
  assert.equal(codec(new Map(Object.entries(object))), null);
  assert.equal(codec(Object.assign(Object.create({ private: true }), object)), null);
  assert.equal(codec({ ...object, [Symbol("private")]: "PRIVATE_CANARY" }), null);
  assert.notEqual(codec(Object.freeze({ ...object })), null);
  boundaryChecks += 5;
}

// Concept: native opaque bytes cannot disguise their length or execute methods.
// Technical depth: typed-array intrinsics read the actual backing view; own
// accessors are not used for byte length, offset, buffer or string conversion.
for (const key of ["length", "byteLength", "byteOffset", "buffer", "toString"]) {
  let invoked = 0;
  const bytes = Buffer.from([255]);
  Object.defineProperty(bytes, key, { get() { invoked++; throw new Error("private accessor invoked"); } });
  assert.deepEqual(encodeCreationCancellation({ ...native, command_id: bytes }), wire);
  assert.equal(invoked, 0);
  boundaryChecks++;
}
let invoked = 0;
const oversized = Buffer.alloc(257, 255);
Object.defineProperty(oversized, "length", { get() { invoked++; return 1; } });
assert.equal(encodeCreationCancellation({ ...native, command_id: oversized }), null);
assert.equal(invoked, 0);
boundaryChecks++;
assert.equal(encodeCreationCancellation({ ...native, command_id: Object.create(Buffer.prototype) }), null);
boundaryChecks++;
assert.equal(boundaryChecks, 69);
process.stdout.write(JSON.stringify({ contract: fixture.contract, checked: fixture.cases.length, boundary_checks: boundaryChecks }) + "\n");
