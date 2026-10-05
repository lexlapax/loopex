// Concept
// Independently verify the approved inspection and policy answer projections.
// Technical depth
// Literal expected identity bytes and quantities do not come from a codec.
// Boundary probes preserve each original byte ceiling and reject accessors.
import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import { decodeOpenInteraction, encodeOpenInteraction, decodeAnswerAdmitted, encodeAnswerAdmitted } from "./open-interaction.mjs";
import { decodeInspection } from "./inspection.mjs";
const [openPath, eventPath, inspectPath] = process.argv.slice(2);
if (!openPath || !eventPath || !inspectPath) throw new Error("usage: inspection-vectors.mjs <open> <answer-admitted> <inspection>");
const open = JSON.parse(readFileSync(openPath, "utf8"));
const events = JSON.parse(readFileSync(eventPath, "utf8"));
const inspections = JSON.parse(readFileSync(inspectPath, "utf8"));
function retained(value) {
  if (typeof value === "bigint") return value.toString();
  if (Buffer.isBuffer(value)) return { opaque_hex: value.toString("hex") };
  if (Array.isArray(value)) return value.map(retained);
  if (value !== null && typeof value === "object") return Object.fromEntries(Object.entries(value).map(([key, scalar]) => [key, retained(scalar)]));
  return value;
}
for (const [fixture, decode, encode] of [[open, decodeOpenInteraction, encodeOpenInteraction], [events, decodeAnswerAdmitted, encodeAnswerAdmitted], [inspections, decodeInspection, null]]) {
  assert.equal(fixture.format, "loopex.experimental.payload-vectors/1");
  for (const vector of fixture.cases) {
    const result = decode(vector.input);
    assert.deepEqual(retained(result), vector.error ? null : vector.decoded, vector.name);
    if (!vector.error && encode !== null) assert.deepEqual(encode(result), vector.input, vector.name);
  }
}
const answered = open.cases.find(v => v.name === "policy-answered").input;
const event = events.cases.find(v => v.name === "admitted-policy-answer").input;
const inspection = inspections.cases.find(v => v.name === "active-policy-answer-exact-bounds").input;
let boundaries = 0;
const full = Buffer.alloc(65536, 255);
const short = Buffer.alloc(64, 255);
assert.deepEqual(decodeOpenInteraction({ ...answered, answer_command_id: full.toString("base64url") }).answer_command_id, full); boundaries++;
assert.equal(decodeOpenInteraction({ ...answered, answer_command_id: Buffer.concat([full, Buffer.from("x")]).toString("base64url") }), null); boundaries++;
const longChoice = { ...answered, choices: [{ id: short.toString("base64url"), label: "Proceed" }], answer_choice_id: short.toString("base64url") };
assert.deepEqual(decodeOpenInteraction(longChoice).answer_choice_id, short); boundaries++;
assert.equal(decodeOpenInteraction({ ...longChoice, answer_choice_id: Buffer.concat([short, Buffer.from("x")]).toString("base64url") }), null); boundaries++;
for (const key of ["interaction_id", "run_id", "tool_call_id", "answer_command_id"]) {
  assert.deepEqual(decodeAnswerAdmitted({ ...event, [key]: full.toString("base64url") })[key], full); boundaries++;
  assert.equal(decodeAnswerAdmitted({ ...event, [key]: Buffer.concat([full, Buffer.from("x")]).toString("base64url") }), null); boundaries++;
}
assert.deepEqual(decodeAnswerAdmitted({ ...event, answer_choice_id: short.toString("base64url") }).answer_choice_id, short); boundaries++;
assert.equal(decodeAnswerAdmitted({ ...event, answer_choice_id: Buffer.concat([short, Buffer.from("x")]).toString("base64url") }), null); boundaries++;
assert.deepEqual(decodeInspection({ ...inspection, active_run_id: full.toString("base64url") }).active_run_id, full); boundaries++;
assert.equal(decodeInspection({ ...inspection, active_run_id: Buffer.concat([full, Buffer.from("x")]).toString("base64url") }), null); boundaries++;
assert.equal(decodeInspection({ ...inspection, pending_work_ids: Array(1024).fill("YQ") }).pending_work_ids.length, 1024); boundaries++;
assert.equal(decodeInspection({ ...inspection, pending_work_ids: Array(1025).fill("YQ") }), null); boundaries++;
for (const [value, decode] of [[answered, decodeOpenInteraction], [event, decodeAnswerAdmitted], [inspection, decodeInspection]]) {
  let invoked = 0;
  const getter = { ...value };
  Object.defineProperty(getter, "status", { enumerable: true, get() { invoked++; return "answered"; } });
  assert.equal(decode(getter), null); assert.equal(invoked, 0); boundaries++;
  assert.equal(decode(Object.assign(Object.create(null), value)), null); boundaries++;
  assert.equal(decode({ ...value, [Symbol("private")]: "canary" }), null); boundaries++;
  assert.notEqual(decode(Object.freeze({ ...value })), null); boundaries++;
}
let invoked = 0;
const nested = { ...inspection, configuration: { ...inspection.configuration } };
Object.defineProperty(nested.configuration, "model", { enumerable: true, get() { invoked++; return "private"; } });
assert.equal(decodeInspection(nested), null); assert.equal(invoked, 0); boundaries++;
const choices = [...answered.choices];
Object.defineProperty(choices, "0", { enumerable: true, get() { invoked++; return answered.choices[0]; } });
assert.equal(decodeOpenInteraction({ ...answered, choices }), null); assert.equal(invoked, 0); boundaries++;
for (const [value, encode] of [[decodeOpenInteraction(answered), encodeOpenInteraction], [decodeAnswerAdmitted(event), encodeAnswerAdmitted]]) {
  assert.equal(encode({ ...value, turn: 1 }), null); boundaries++;
  assert.equal(encode({ ...value, answer_command_id: "YQ" }), null); boundaries++;
  assert.equal(encode({ ...value, answer_choice_id: Buffer.alloc(65) }), null); boundaries++;
}
console.log(JSON.stringify({ open_vectors: open.cases.length, answer_admitted_vectors: events.cases.length, inspection_vectors: inspections.cases.length, boundary_checks: boundaries }));
