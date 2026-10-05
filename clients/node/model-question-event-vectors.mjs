// Concept
// Independently prove the complete requested-model payload and exact captures.
// Technical depth
// Literal expected quantities and opaque bytes come from retained vectors.
// Boundary probes exercise native encoders and descriptor safety independently.
import assert from "node:assert/strict";
import { createHash } from "node:crypto";
import { readFileSync } from "node:fs";
import { decodeModelQuestionRequested, encodeModelQuestionRequested } from "./model-question-event.mjs";

const [vectorPath, schemaPath] = process.argv.slice(2);
if (!vectorPath || !schemaPath) throw new Error("usage: model-question-event-vectors.mjs <vectors> <schema>");
const vectorBytes = readFileSync(vectorPath);
const schemaBytes = readFileSync(schemaPath);
assert.equal(createHash("sha256").update(vectorBytes).digest("hex"), "04ea6b8ebe77217fef3fcc30875973cb447761c9e89af7b7ec6b34aa18e861cf");
assert.equal(createHash("sha256").update(schemaBytes).digest("hex"), "e91c864a7ae2db429243f2ec874667ab3adcb521a94b9d404fb81f1ab1a67fc6");
const fixture = JSON.parse(vectorBytes.toString("utf8"));
const schema = JSON.parse(schemaBytes.toString("utf8"));
assert.equal(fixture.format, "loopex.experimental.payload-vectors/1");
assert.equal(fixture.contract, "model_question_requested");
assert.equal(fixture.cases.length, 141);
assert.equal(schema.event_kind, "interaction.requested");
assert.equal(schema.required.length, 15);
assert.equal(schema.closed, true);
assert.deepEqual(schema.required_null_fields, ["answer", "command_digest", "command_id", "disposition", "settlement_sequence"]);

function retained(value) {
  if (typeof value === "bigint") return value.toString();
  if (Buffer.isBuffer(value)) return { opaque_hex: value.toString("hex") };
  if (Array.isArray(value)) return value.map(retained);
  if (value !== null && typeof value === "object") return Object.fromEntries(Object.entries(value).map(([key, member]) => [key, retained(member)]));
  return value;
}

for (const vector of fixture.cases) {
  const native = decodeModelQuestionRequested(vector.input);
  assert.deepEqual(retained(native), vector.error ? null : vector.decoded, vector.name);
  if (!vector.error) assert.deepEqual(encodeModelQuestionRequested(native), vector.input, vector.name);
}

const wire = fixture.cases.find(value => value.name === "requested-model-choice").input;
const native = decodeModelQuestionRequested(wire);
let boundaries = 0;
const full = Buffer.alloc(65536, 255);
for (const key of ["interaction_id", "run_id", "tool_call_id"]) {
  const value = { ...native, [key]: full };
  assert.deepEqual(decodeModelQuestionRequested(encodeModelQuestionRequested(value))[key], full); boundaries++;
  assert.equal(encodeModelQuestionRequested({ ...value, [key]: Buffer.concat([full, Buffer.from("x")]) }), null); boundaries++;
  assert.equal(encodeModelQuestionRequested({ ...value, [key]: Buffer.alloc(0) }), null); boundaries++;
}
for (const key of schema.required_null_fields) {
  for (const value of [false, 0, "", [], {}, Buffer.from("private")]) {
    assert.equal(encodeModelQuestionRequested({ ...native, [key]: value }), null); boundaries++;
  }
}
for (const value of [0n, -1n, 1, "1", null, true, {}, []]) {
  assert.equal(encodeModelQuestionRequested({ ...native, turn: value }), null); boundaries++;
}
for (const value of [-1n, 18446744073709551616n, 1, "1", null, true, {}, []]) {
  assert.equal(encodeModelQuestionRequested({ ...native, expires_at: value }), null); boundaries++;
}
assert.equal(encodeModelQuestionRequested({ ...native, prompt: "\ud800" }), null); boundaries++;

for (const [value, codec] of [[wire, decodeModelQuestionRequested], [native, encodeModelQuestionRequested]]) {
  for (const key of Object.keys(value)) {
    let invoked = 0;
    const getter = { ...value };
    Object.defineProperty(getter, key, { enumerable: true, get() { invoked++; return value[key]; } });
    assert.equal(codec(getter), null); assert.equal(invoked, 0); boundaries++;
    const setter = { ...value };
    Object.defineProperty(setter, key, { enumerable: true, set() { invoked++; } });
    assert.equal(codec(setter), null); assert.equal(invoked, 0); boundaries++;
    const hidden = { ...value };
    Object.defineProperty(hidden, key, { value: value[key], enumerable: false });
    assert.equal(codec(hidden), null); boundaries++;
  }
  assert.equal(codec(Object.assign(Object.create(null), value)), null); boundaries++;
  assert.equal(codec({ ...value, [Symbol("private")]: "canary" }), null); boundaries++;
  assert.notEqual(codec(Object.freeze({ ...value })), null); boundaries++;
}
let invoked = 0;
const choices = [...wire.choices];
Object.defineProperty(choices, "0", { enumerable: true, get() { invoked++; return wire.choices[0]; } });
assert.equal(decodeModelQuestionRequested({ ...wire, choices }), null); assert.equal(invoked, 0); boundaries++;
const entry = { ...wire.choices[0] };
Object.defineProperty(entry, "label", { enumerable: true, get() { invoked++; return "private"; } });
assert.equal(decodeModelQuestionRequested({ ...wire, choices: [entry, wire.choices[1]] }), null); assert.equal(invoked, 0); boundaries++;
const sparse = [...wire.choices];
delete sparse[0];
assert.equal(decodeModelQuestionRequested({ ...wire, choices: sparse }), null); boundaries++;
assert.notEqual(decodeModelQuestionRequested(Object.freeze({ ...wire, choices: Object.freeze(wire.choices.map(value => Object.freeze({ ...value }))) })), null); boundaries++;

console.log(JSON.stringify({ vectors: fixture.cases.length, boundary_checks: boundaries }));
