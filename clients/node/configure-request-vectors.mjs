// Concept
// Consume literal configure vectors through an independent native projection.
// Technical depth
// This consumer covers structured payloads. Duplicate JSON member cases belong
// to the existing Frame tests, before any JSON.parse map conversion.
import assert from "node:assert/strict";
import { createHash } from "node:crypto";
import { readFileSync } from "node:fs";
import { decodeConfigureRequest, decodeConfigureChanges } from "./configure-request.mjs";

const [vectorsPath, schemaPath] = process.argv.slice(2);
if (!vectorsPath || !schemaPath) throw new Error("usage: configure-request-vectors.mjs <vectors> <schema>");
const vectorsBytes = readFileSync(vectorsPath);
const schemaBytes = readFileSync(schemaPath);
assert.equal(createHash("sha256").update(vectorsBytes).digest("hex"), "fff66292cb2904ccb6fc4260de370a969e9bfc0eda478b6f0c726ecffed944fe");
assert.equal(createHash("sha256").update(schemaBytes).digest("hex"), "970400e653364af023918ceb960a499d6f6b1654646de5fc10330953e56a0ef4");
const vectors = JSON.parse(vectorsBytes.toString("utf8"));
const schema = JSON.parse(schemaBytes.toString("utf8"));
assert.equal(vectors.contract, "configure_request");
assert.equal(vectors.cases.length, 381);
assert.equal(schema.closed, true);
assert.equal(schema.generation_activation, false);
assert.deepEqual(schema.envelopes.foreground.required, ["request_id", "method", "command_id", "changes"]);
assert.deepEqual(schema.envelopes.daemon.required, ["request_id", "method", "command_id", "changes", "writer_epoch"]);

function retained(value) {
  if (typeof value === "bigint") return value.toString();
  if (Buffer.isBuffer(value)) return { opaque_hex: value.toString("hex") };
  if (value !== null && typeof value === "object") return Object.fromEntries(Object.entries(value).map(([key, member]) => [key, retained(member)]));
  return value;
}

for (const vector of vectors.cases) {
  assert.deepEqual(retained(decodeConfigureRequest(vector.input, vector.transport)), vector.error ? null : vector.decoded, vector.name);
}
for (const transport of ["foreground", "daemon"]) {
  const subsets = vectors.cases.filter(vector => vector.name.startsWith(`${transport}-subset-`));
  assert.equal(subsets.length, 63);
  assert.equal(new Set(subsets.map(vector => Object.keys(vector.input.changes).sort().join(","))).size, 63);
}

const request = vectors.cases.find(vector => vector.name === "foreground-subset-63").input;
let boundaries = 0;
assert.equal(decodeConfigureRequest(request, "unknown"), null); boundaries++;
assert.equal(decodeConfigureChanges({ model: "\ud800" }), null); boundaries++;
for (const key of ["base", "environment", "appendix"]) {
  assert.equal(decodeConfigureChanges({ instructions: { ...request.changes.instructions, [key]: "\udfff" } }), null); boundaries++;
}
for (const [value, decoder] of [[request, value => decodeConfigureRequest(value, "foreground")], [request.changes, decodeConfigureChanges]]) {
  for (const key of Object.keys(value)) {
    let invoked = 0;
    const getter = { ...value };
    Object.defineProperty(getter, key, { enumerable: true, get() { invoked++; return value[key]; } });
    assert.equal(decoder(getter), null); assert.equal(invoked, 0); boundaries++;
    const hidden = { ...value };
    Object.defineProperty(hidden, key, { value: value[key], enumerable: false });
    assert.equal(decoder(hidden), null); boundaries++;
  }
  assert.equal(decoder(Object.assign(Object.create(null), value)), null); boundaries++;
  assert.equal(decoder({ ...value, [Symbol("private")]: true }), null); boundaries++;
  assert.notEqual(decoder(Object.freeze({ ...value })), null); boundaries++;
}
for (const terminator of ["\n", "\r", "\u2028"]) {
  assert.equal(decodeConfigureChanges({ instructions: { ...request.changes.instructions, version: "v" + terminator } }), null); boundaries++;
  for (const quantity of ["max_tokens", "context_token_budget", "system_class_tokens"]) {
    assert.equal(decodeConfigureChanges({ [quantity]: "1" + terminator }), null); boundaries++;
  }
  for (const transport of ["foreground", "daemon"]) {
    const prototype = vectors.cases.find(vector => vector.name === `${transport}-subset-63`).input;
    assert.equal(decodeConfigureRequest({ ...prototype, request_id: "r" + terminator }, transport), null); boundaries++;
  }
}
let invoked = 0;
const sections = { ...request.changes.instructions };
Object.defineProperty(sections, "base", { enumerable: true, get() { invoked++; return "private"; } });
assert.equal(decodeConfigureChanges({ instructions: sections }), null);
assert.equal(invoked, 0); boundaries++;

console.log(JSON.stringify({ vectors: vectors.cases.length, subset_cases: 126, boundary_checks: boundaries }));
