// Concept
// Independently check producer and event-kind selection against retained literals.
// Technical depth
// These are the existing payload vectors, not a new schema or generation. Exact
// fixture hashes and decoded literals provide expectations independently of the
// selector. Cursor relations, authority and live delivery are separate proofs.
import assert from "node:assert/strict";
import { createHash } from "node:crypto";
import { readFileSync } from "node:fs";
import { join } from "node:path";
import { decodeInteractionEvent, encodeInteractionEvent } from "./interaction-event.mjs";

const [directory] = process.argv.slice(2);
if (!directory) throw new Error("usage: interaction-event-vectors.mjs <vector-directory>");
const endings = new Map([
  ["answered", "interaction.answered"], ["declined", "interaction.declined"],
  ["expired", "interaction.expired"], ["cancelled", "interaction.cancelled"]
]);
const pins = [
  ["model-question-requested", "04ea6b8ebe77217fef3fcc30875973cb447761c9e89af7b7ec6b34aa18e861cf", 141, () => "interaction.requested"],
  ["model-question-terminal", "747a893c1417f57dfe95da6a5d02ae69165683edb477a5e748c5e26a96e89b44", 377, v => endings.get(v.input?.disposition) ?? "interaction.answered"],
  ["policy-requested", "9dcae66c03cb1cabf0db28f46deedb52f9952bb722a16b73a7128766c0d64bbe", 187, () => "interaction.requested"],
  ["policy-terminal", "b63a8de4efca09b1098ac557cdc9175ff146bdfdf41e23b673d2144b730e73e3", 237, v => v.event_kind],
  ["policy-answer-admitted", "3b2dea43ce6525c5bb9fecfc55947da54d2bfeb36faaea459264bc0001fd77b2", 60, () => "interaction.answer_admitted"]
];
function restore(value, key) {
  if (value !== null && typeof value === "object" && !Array.isArray(value)) {
    if (Object.keys(value).length === 1 && Object.hasOwn(value, "opaque_hex")) return Buffer.from(value.opaque_hex, "hex");
    return Object.fromEntries(Object.entries(value).map(([key, member]) => [key, restore(member, key)]));
  }
  if (Array.isArray(value)) return value.map(member => restore(member, key));
  if (["turn", "expires_at", "settlement_sequence"].includes(key) && typeof value === "string") return BigInt(value);
  return value;
}
// Exactly one terminal-only wrong-kind literal is valid in this shared admission branch.
// The native expectation is literal, and its wire bytes must match the retained positive resolution.
const collisionAdmission = {
  interaction_id: Buffer.from([0, 255, 10]), run_id: Buffer.from([114, 117, 110, 128]),
  turn: 1n, tool_call_id: Buffer.from([99, 97, 108, 108, 0]), producer: "policy_defer",
  interaction_kind: "choice", status: "answered", answer_choice_id: Buffer.from([255]),
  answer_command_id: Buffer.from([97, 110, 115, 119, 101, 114, 0, 254])
};
const fixtures = new Map();
let vectors = 0, kindChecks = 0, boundaries = 0;
for (const [file, hash, count, kind] of pins) {
  const bytes = readFileSync(join(directory, `${file}.v1.json`));
  assert.equal(createHash("sha256").update(bytes).digest("hex"), hash);
  const fixture = JSON.parse(bytes.toString("utf8"));
  assert.equal(fixture.format, "loopex.experimental.payload-vectors/1");
  assert.equal(fixture.contract, file.replaceAll("-", "_"));
  assert.equal(fixture.cases.length, count);
  fixtures.set(file, fixture.cases);
  for (const vector of fixture.cases) {
    const eventKind = kind(vector);
    const collision = file === "policy-terminal" && vector.name === "terminal-kind-interaction.answer_admitted-answered";
    if (collision) {
      assert.equal(vector.error, true);
      assert.equal(eventKind, "interaction.answer_admitted");
      const positive = fixture.cases.find(v => v.name === "terminal-answered-answered");
      assert.equal(positive.error, undefined);
      assert.equal(positive.event_kind, "interaction.resolved");
      assert.deepEqual(vector.input, positive.input);
    }
    const expected = collision ? collisionAdmission : vector.error ? null : restore(vector.decoded);
    assert.deepEqual(decodeInteractionEvent(eventKind, vector.input), expected, vector.name);
    if (collision || !vector.error) assert.deepEqual(encodeInteractionEvent(eventKind, expected), vector.input, vector.name);
    vectors++;
  }
}
function find(file, name) {
  const value = fixtures.get(file).find(vector => vector.name === name);
  assert.ok(value, name);
  return value;
}
for (const vector of fixtures.get("model-question-terminal").filter(vector => !vector.error)) {
  const native = restore(vector.decoded), expectedKind = endings.get(vector.input.disposition);
  for (const kind of ["interaction.requested", "interaction.answer_admitted", "interaction.resolved", ...endings.values()]) {
    const valid = kind === expectedKind;
    assert.deepEqual(decodeInteractionEvent(kind, vector.input), valid ? native : null, `${vector.name}/${kind}`);
    assert.deepEqual(encodeInteractionEvent(kind, native), valid ? vector.input : null, `${vector.name}/${kind}`);
    kindChecks += 2;
  }
}
for (const kind of ["interaction.expired", "interaction.cancelled"]) {
  const model = fixtures.get("model-question-terminal").find(v => !v.error && endings.get(v.input.disposition) === kind);
  const policy = fixtures.get("policy-terminal").find(v => !v.error && v.event_kind === kind);
  for (const vector of [model, policy]) {
    const native = restore(vector.decoded);
    assert.deepEqual(decodeInteractionEvent(kind, vector.input), native);
    assert.deepEqual(encodeInteractionEvent(kind, native), vector.input);
    const other = vector.input.producer === "model_tool" ? "policy_defer" : "model_tool";
    assert.equal(decodeInteractionEvent(kind, { ...vector.input, producer: other }), null);
    const stripped = { ...vector.input }; delete stripped.producer;
    assert.equal(decodeInteractionEvent(kind, stripped), null);
    assert.equal(encodeInteractionEvent(kind, { ...native, producer: other }), null);
    kindChecks += 5;
  }
}
const model = find("model-question-requested", "requested-model-choice");
const policy = find("policy-requested", "requested-policy-choice");
for (const vector of [model, policy]) {
  const wire = { ...vector.input }; delete wire.producer;
  assert.equal(decodeInteractionEvent("interaction.requested", wire), null); boundaries++;
}
const strippedModel = restore(model.decoded); delete strippedModel.producer;
assert.equal(encodeInteractionEvent("interaction.requested", strippedModel), null); boundaries++;
const nativePolicy = restore(policy.decoded);
for (const value of [{ ...nativePolicy, producer: null }, { ...nativePolicy, producer: "policy_defer" },
                     { producer: undefined }, {}, { ...nativePolicy, grant: "PRIVATE_CANARY" }]) {
  assert.equal(encodeInteractionEvent("interaction.requested", value), null); boundaries++;
}

// Admission and allowed resolution have identical nine wire members. The kind
// selects a different native meaning; payload equality never proves permission.
const admissionVector = find("policy-answer-admitted", "admitted-policy-answer");
const admission = restore(admissionVector.decoded), admittedWire = admissionVector.input;
const resolution = { ...admission, choice_id: admission.answer_choice_id, resolution: "allowed" };
for (const key of ["producer", "interaction_kind", "status", "answer_choice_id"]) delete resolution[key];
assert.deepEqual(decodeInteractionEvent("interaction.answer_admitted", admittedWire), admission);
assert.deepEqual(decodeInteractionEvent("interaction.resolved", admittedWire), resolution);
assert.deepEqual(encodeInteractionEvent("interaction.answer_admitted", admission), admittedWire);
assert.deepEqual(encodeInteractionEvent("interaction.resolved", resolution), admittedWire);
assert.equal(encodeInteractionEvent("interaction.resolved", admission), null);
assert.equal(encodeInteractionEvent("interaction.answer_admitted", resolution), null);
assert.equal(decodeInteractionEvent("interaction.answer_admitted", { ...admittedWire, status: "denied" }), null);
kindChecks += 7;
const collisionVector = find("policy-terminal", "terminal-kind-interaction.answer_admitted-answered");
const positiveResolution = find("policy-terminal", "terminal-answered-answered");
const collisionResolution = restore(positiveResolution.decoded);
assert.deepEqual(collisionVector.input, positiveResolution.input);
assert.deepEqual(decodeInteractionEvent("interaction.answer_admitted", collisionVector.input), collisionAdmission);
assert.deepEqual(decodeInteractionEvent("interaction.resolved", collisionVector.input), collisionResolution);
assert.deepEqual(encodeInteractionEvent("interaction.answer_admitted", collisionAdmission), positiveResolution.input);
assert.deepEqual(encodeInteractionEvent("interaction.resolved", collisionResolution), collisionVector.input);
assert.equal(encodeInteractionEvent("interaction.resolved", collisionAdmission), null);
assert.equal(encodeInteractionEvent("interaction.answer_admitted", collisionResolution), null);
kindChecks += 6;

const terminal = find("policy-terminal", "terminal-denied-answered"), nativeTerminal = restore(terminal.decoded);
for (const reason of [Buffer.alloc(0), Buffer.from([0, 255]), Buffer.alloc(65536, 255)]) {
  assert.deepEqual(encodeInteractionEvent("interaction.resolved", { ...nativeTerminal, reason }), terminal.input);
  assert.deepEqual(decodeInteractionEvent("interaction.resolved", terminal.input), nativeTerminal);
  boundaries += 2;
}
for (const reason of [null, 1, {}, [], Buffer.alloc(65537)]) {
  assert.equal(encodeInteractionEvent("interaction.resolved", { ...nativeTerminal, reason }), null); boundaries++;
}
for (const field of ["policy_ref", "credential", "grant", "private_capture", "producer"]) {
  assert.equal(encodeInteractionEvent("interaction.resolved", { ...nativeTerminal, [field]: "PRIVATE_CANARY" }), null);
  assert.equal(decodeInteractionEvent("interaction.resolved", { ...terminal.input, [field]: "PRIVATE_CANARY" }), null);
  boundaries += 2;
}
const text = find("model-question-terminal", "terminal-answered-text"), nativeText = restore(text.decoded);
const full = Buffer.alloc(65536, 255);
const maximum = { ...nativeText, interaction_id: full, command_id: full };
const maximumWire = encodeInteractionEvent("interaction.answered", maximum);
assert.notEqual(maximumWire, null);
assert.deepEqual(decodeInteractionEvent("interaction.answered", maximumWire), maximum);
assert.equal(encodeInteractionEvent("interaction.answered", { ...maximum, command_id: Buffer.alloc(65537, 255) }), null);
boundaries += 3;
for (const kind of [null, 1, {}, Symbol("kind"), "__proto__", "interaction.unknown"]) {
  assert.equal(encodeInteractionEvent(kind, nativeText), null);
  assert.equal(decodeInteractionEvent(kind, text.input), null);
  kindChecks += 2;
}
for (const [kind, native, wire] of [["interaction.requested", nativePolicy, policy.input],
                                  ["interaction.resolved", nativeTerminal, terminal.input],
                                  ["interaction.answered", nativeText, text.input],
                                  ["interaction.answer_admitted", admission, admittedWire]]) {
  for (const [value, codec] of [[native, encodeInteractionEvent], [wire, decodeInteractionEvent]]) {
    for (const key of Object.keys(value)) {
      let invoked = 0;
      const getter = { ...value };
      Object.defineProperty(getter, key, { enumerable: true, get() { invoked++; return value[key]; } });
      assert.equal(codec(kind, getter), null); assert.equal(invoked, 0); boundaries++;
      const setter = { ...value };
      Object.defineProperty(setter, key, { enumerable: true, set() { invoked++; } });
      assert.equal(codec(kind, setter), null); assert.equal(invoked, 0); boundaries++;
      const hidden = { ...value };
      Object.defineProperty(hidden, key, { value: value[key], enumerable: false });
      assert.equal(codec(kind, hidden), null); boundaries++;
    }
    for (const invalid of [null, [], Object.assign(Object.create(null), value),
                           { ...value, [Symbol("private")]: "canary" }]) {
      assert.equal(codec(kind, invalid), null); boundaries++;
    }
    assert.notEqual(codec(kind, Object.freeze({ ...value })), null); boundaries++;
  }
}
let invoked = 0;
const choices = [...model.input.choices];
Object.defineProperty(choices, "0", { enumerable: true, get() { invoked++; return model.input.choices[0]; } });
assert.equal(decodeInteractionEvent("interaction.requested", { ...model.input, choices }), null);
assert.equal(invoked, 0); boundaries++;
const answer = { ...text.input.answer };
Object.defineProperty(answer, "text", { enumerable: true, get() { invoked++; return "private"; } });
assert.equal(decodeInteractionEvent("interaction.answered", { ...text.input, answer }), null);
assert.equal(invoked, 0); boundaries++;
assert.equal(vectors, 1002);
console.log(JSON.stringify({ vectors, kind_checks: kindChecks, boundary_checks: boundaries }));
