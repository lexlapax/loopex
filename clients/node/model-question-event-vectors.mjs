// Concept
// Independently prove requested and terminal model-question payloads and captures.
// Technical depth
// Literal expected quantities and opaque bytes come from retained vectors.
// Boundary probes exercise native encoders and descriptor safety independently.
import assert from "node:assert/strict";
import { createHash } from "node:crypto";
import { readFileSync } from "node:fs";
import { decodeModelQuestionRequested, encodeModelQuestionRequested, decodeModelQuestionTerminal, encodeModelQuestionTerminal } from "./model-question-event.mjs";

const [vectorPath, schemaPath] = process.argv.slice(2);
if (!vectorPath || !schemaPath) throw new Error("usage: model-question-event-vectors.mjs <vectors> <schema>");
const vectorBytes = readFileSync(vectorPath);
const schemaBytes = readFileSync(schemaPath);
const fixture = JSON.parse(vectorBytes.toString("utf8"));
const schema = JSON.parse(schemaBytes.toString("utf8"));
const pins = {
  model_question_requested: ["04ea6b8ebe77217fef3fcc30875973cb447761c9e89af7b7ec6b34aa18e861cf", "fbaa077e006bed444e3b2bb8fe53f1eafe060aec9d4357b3e79da6883aabcab2"],
  model_question_terminal: ["747a893c1417f57dfe95da6a5d02ae69165683edb477a5e748c5e26a96e89b44", "6bb84c9594bef5532a463f664ee43463a92e881f94267cf4356143af5ebb4563"]
};
assert.ok(Object.hasOwn(pins, fixture.contract), "Unsupported vector contract");
assert.equal(createHash("sha256").update(vectorBytes).digest("hex"), pins[fixture.contract][0]);
assert.equal(createHash("sha256").update(schemaBytes).digest("hex"), pins[fixture.contract][1]);
assert.equal(fixture.format, "loopex.experimental.payload-vectors/1");
assert.equal(schema.contract, fixture.contract);
assert.equal(schema.required.length, 15);
assert.equal(schema.closed, true);

function retained(value) {
  if (typeof value === "bigint") return value.toString();
  if (Buffer.isBuffer(value)) return { opaque_hex: value.toString("hex") };
  if (Array.isArray(value)) return value.map(retained);
  if (value !== null && typeof value === "object") return Object.fromEntries(Object.entries(value).map(([key, member]) => [key, retained(member)]));
  return value;
}

if (fixture.contract === "model_question_requested") {
assert.equal(fixture.cases.length, 141);
assert.equal(schema.event_kind, "interaction.requested");
assert.deepEqual(schema.required_null_fields, ["answer", "command_digest", "command_id", "disposition", "settlement_sequence"]);
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

} else {

assert.equal(fixture.cases.length, 377);
assert.equal(schema.choice_only_additional_field, "choice_id");
assert.deepEqual(schema.kind_by_disposition, { answered: "interaction.answered", declined: "interaction.declined", expired: "interaction.expired", cancelled: "interaction.cancelled" });
let boundaries = 0;
for (const vector of fixture.cases) {
  const native = decodeModelQuestionTerminal(vector.input);
  assert.deepEqual(retained(native), vector.error ? null : vector.decoded, vector.name);
  if (!vector.error) assert.deepEqual(encodeModelQuestionTerminal(native), vector.input, vector.name);
}
const wire = fixture.cases.find(value => value.name === "terminal-answered-text").input;
const native = decodeModelQuestionTerminal(wire);
const full = Buffer.alloc(65536, 255);
for (const key of ["interaction_id", "run_id", "tool_call_id", "command_id"]) {
  const value = { ...native, [key]: full };
  assert.deepEqual(decodeModelQuestionTerminal(encodeModelQuestionTerminal(value))[key], full); boundaries++;
  assert.equal(encodeModelQuestionTerminal({ ...value, [key]: Buffer.concat([full, Buffer.from("x")]) }), null); boundaries++;
  assert.equal(encodeModelQuestionTerminal({ ...value, [key]: Buffer.alloc(0) }), null); boundaries++;
}
assert.deepEqual(schema.variants.expired.null_fields, ["answer", "command_id", "command_digest"]);
assert.deepEqual(schema.variants.cancelled.null_fields, ["answer"]);
assert.equal(schema.variants.cancelled.command_captures, "both_null_or_both_valid");
for (const key of ["command_id", "command_digest"]) {
  assert.deepEqual(schema.fields[key].null_on, ["expired"]);
  assert.deepEqual(schema.fields[key].nullable_on, ["cancelled"]);
}
for (const kind of ["text", "choice"]) {
  const cancelledWire = fixture.cases.find(value => value.name === `terminal-cancelled-${kind}-abort-command`).input;
  const cancelled = decodeModelQuestionTerminal(cancelledWire);
  const value = { ...cancelled, command_id: full };
  assert.deepEqual(decodeModelQuestionTerminal(encodeModelQuestionTerminal(value)).command_id, full); boundaries++;
  for (const command of [Buffer.alloc(0), Buffer.concat([full, Buffer.from("x")]), null, 1, true, {}, []]) {
    assert.equal(encodeModelQuestionTerminal({ ...cancelled, command_id: command }), null); boundaries++;
  }
  for (const digest of [null, "", "A".repeat(64), "a".repeat(63), "a".repeat(65), true, {}, []]) {
    assert.equal(encodeModelQuestionTerminal({ ...cancelled, command_digest: digest }), null); boundaries++;
  }
  const closing = { ...cancelled, command_id: null, command_digest: null };
  assert.deepEqual(decodeModelQuestionTerminal(encodeModelQuestionTerminal(closing)), closing); boundaries++;
  assert.equal(encodeModelQuestionTerminal({ ...cancelled, status: "expired", disposition: "expired" }), null); boundaries++;
}
for (const value of [0n, -1n, 18446744073709551616n, 1, "1", null, true, {}, []]) {
  assert.equal(encodeModelQuestionTerminal({ ...native, settlement_sequence: value }), null); boundaries++;
}
assert.equal(decodeModelQuestionTerminal({ ...wire, settlement_sequence: "1".repeat(21) }), null); boundaries++;
for (const answer of [{ text: "" }, { text: "\ud800" }, { text: "x".repeat(8193) }, { text: "answer", private: null }]) {
  assert.equal(encodeModelQuestionTerminal({ ...native, answer }), null); boundaries++;
}
assert.notEqual(encodeModelQuestionTerminal({ ...native, answer: { text: "é".repeat(4096) } }), null); boundaries++;
assert.equal(encodeModelQuestionTerminal({ ...native, answer: { text: "é".repeat(4096) + "x" } }), null); boundaries++;

for (const vector of fixture.cases.filter(value => !value.error)) {
  const decoded = decodeModelQuestionTerminal(vector.input);
  for (const [value, codec] of [[vector.input, decodeModelQuestionTerminal], [decoded, encodeModelQuestionTerminal]]) {
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
    if (value.answer !== null) {
      for (const key of Object.keys(value.answer)) {
        let invoked = 0;
        const answer = { ...value.answer };
        Object.defineProperty(answer, key, { enumerable: true, get() { invoked++; return value.answer[key]; } });
        assert.equal(codec({ ...value, answer }), null); assert.equal(invoked, 0); boundaries++;
        assert.equal(codec({ ...value, answer: { ...value.answer, [Symbol("private")]: null } }), null); boundaries++;
        assert.equal(codec({ ...value, answer: Object.assign(Object.create(null), value.answer) }), null); boundaries++;
      }
    }
    if (value.choices.length) {
      let invoked = 0;
      const choices = [...value.choices];
      Object.defineProperty(choices, "0", { enumerable: true, get() { invoked++; return value.choices[0]; } });
      assert.equal(codec({ ...value, choices }), null); assert.equal(invoked, 0); boundaries++;
      const choice = { ...value.choices[0] };
      Object.defineProperty(choice, "label", { enumerable: true, get() { invoked++; return "private"; } });
      assert.equal(codec({ ...value, choices: [choice, ...value.choices.slice(1)] }), null); assert.equal(invoked, 0); boundaries++;
      const sparse = [...value.choices]; delete sparse[0];
      assert.equal(codec({ ...value, choices: sparse }), null); boundaries++;
    }
  }
}
console.log(JSON.stringify({ vectors: fixture.cases.length, boundary_checks: boundaries }));
}
