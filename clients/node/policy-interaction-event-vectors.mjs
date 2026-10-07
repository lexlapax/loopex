// Concept
// Independently consume literal policy request and terminal projections.
// Technical depth
// Expected identities and quantities are literal. Every vector has an explicit
// kind when terminal; negative branches never become admission or authority.
import assert from "node:assert/strict";
import { createHash } from "node:crypto";
import { readFileSync } from "node:fs";
import { decodePolicyRequested, encodePolicyRequested, decodePolicyTerminal, encodePolicyTerminal } from "./policy-interaction-event.mjs";

const [contract, vectorPath, schemaPath] = process.argv.slice(2);
const pins = {
  "policy-requested": { count: 187, vectors: "9dcae66c03cb1cabf0db28f46deedb52f9952bb722a16b73a7128766c0d64bbe", schema: "684f2bd45fb6720291eeeac31e09a99e1f81f0b0662fbf122cfc1ccf4791e9c7", fields: 10, native: 7 },
  "policy-terminal": { count: 237, vectors: "b63a8de4efca09b1098ac557cdc9175ff146bdfdf41e23b673d2144b730e73e3", schema: "bab1d537933764c1c51bc1b2c9430ba1d3e1dbeee7f4978cc244cd7680b94e76", fields: 9, native: 6 }
};
if (!Object.hasOwn(pins, contract) || !vectorPath || !schemaPath) throw new Error("usage: policy-interaction-event-vectors.mjs <policy-requested|policy-terminal> <vectors> <schema>");
const pin = pins[contract];
const vectorBytes = readFileSync(vectorPath), schemaBytes = readFileSync(schemaPath);
assert.equal(createHash("sha256").update(vectorBytes).digest("hex"), pin.vectors);
assert.equal(createHash("sha256").update(schemaBytes).digest("hex"), pin.schema);
const fixture = JSON.parse(vectorBytes.toString("utf8")), schema = JSON.parse(schemaBytes.toString("utf8"));
assert.equal(fixture.format, "loopex.experimental.payload-vectors/1");
assert.equal(fixture.contract, contract.replaceAll("-", "_"));
assert.equal(fixture.cases.length, pin.count);
assert.equal(schema.closed, true);
assert.equal(schema.required.length, pin.fields);
assert.equal(schema.native_required.length, pin.native);
assert.equal(schema.producer, "policy_defer");
assert.equal(schema.interaction_kind, "choice");
assert.equal(schema.authority_granted, false);
assert.equal(schema.output_record_bytes_including_newline, 2097152);
const terminal = contract === "policy-terminal";
function retained(value) {
  if (typeof value === "bigint") return value.toString();
  if (Buffer.isBuffer(value)) return { opaque_hex: value.toString("hex") };
  if (Array.isArray(value)) return value.map(retained);
  if (value !== null && typeof value === "object") return Object.fromEntries(Object.entries(value).map(([key, member]) => [key, retained(member)]));
  return value;
}
for (const vector of fixture.cases) {
  const native = terminal ? decodePolicyTerminal(vector.event_kind, vector.input) : decodePolicyRequested(vector.input);
  assert.deepEqual(retained(native), vector.error ? null : vector.decoded, vector.name);
  if (!vector.error) assert.deepEqual(terminal ? encodePolicyTerminal(vector.event_kind, native) : encodePolicyRequested(native), vector.input, vector.name);
}
const wire = fixture.cases[0].input;
const native = terminal ? decodePolicyTerminal("interaction.resolved", wire) : decodePolicyRequested(wire);
const decode = terminal ? value => decodePolicyTerminal("interaction.resolved", value) : decodePolicyRequested;
const encode = terminal ? value => encodePolicyTerminal("interaction.resolved", value) : encodePolicyRequested;
let boundaries = 0;
for (const field of ["interaction_id", "run_id", "tool_call_id", ...(terminal ? ["answer_command_id", "choice_id"] : [])]) {
  const maximum = field === "choice_id" ? 64 : 65536;
  const full = Buffer.alloc(maximum, 255);
  const value = { ...native, [field]: full };
  assert.notEqual(encode(value), null); boundaries++;
  for (const invalid of [Buffer.alloc(0), Buffer.concat([full, Buffer.from("x")]), null, 1, "identity", [], {}]) {
    assert.equal(encode({ ...native, [field]: invalid }), null); boundaries++;
  }
}
for (const turn of [0n, -1n, 1, "1", null, true, {}, []]) { assert.equal(encode({ ...native, turn }), null); boundaries++; }
for (const [value, codec] of [[wire, decode], [native, encode]]) {
  for (const field of Object.keys(value)) {
    let invoked = 0;
    const getter = { ...value };
    Object.defineProperty(getter, field, { enumerable: true, get() { invoked++; return value[field]; } });
    assert.equal(codec(getter), null); assert.equal(invoked, 0); boundaries++;
    const setter = { ...value };
    Object.defineProperty(setter, field, { enumerable: true, set() { invoked++; } });
    assert.equal(codec(setter), null); assert.equal(invoked, 0); boundaries++;
    const hidden = { ...value };
    Object.defineProperty(hidden, field, { value: value[field], enumerable: false });
    assert.equal(codec(hidden), null); boundaries++;
  }
  assert.equal(codec(Object.assign(Object.create(null), value)), null); boundaries++;
  assert.equal(codec({ ...value, [Symbol("private")]: "canary" }), null); boundaries++;
  assert.notEqual(codec(Object.freeze({ ...value })), null); boundaries++;
}
if (terminal) {
  for (const reason of [Buffer.alloc(0), Buffer.from([255, 0]), Buffer.alloc(65536, 255)]) {
    assert.deepEqual(encode({ ...native, reason }), wire); boundaries++;
    assert.equal(Object.hasOwn(decode(wire), "reason"), false); boundaries++;
  }
  for (const reason of [Buffer.alloc(65537), null, 1, "reason", {}, []]) { assert.equal(encode({ ...native, reason }), null); boundaries++; }
  let invoked = 0;
  const resolution = { toString() { invoked++; return "allowed"; } };
  assert.equal(encode({ ...native, resolution }), null); assert.equal(invoked, 0); boundaries++;
  for (const kind of [null, 1, {}, "interaction.answer_admitted", "interaction.requested"]) {
    assert.equal(encodePolicyTerminal(kind, native), null); assert.equal(decodePolicyTerminal(kind, wire), null); boundaries++;
  }
} else {
  for (const expires_at of [-1n, 18446744073709551616n, 1, "1", null, true, {}, []]) { assert.equal(encode({ ...native, expires_at }), null); boundaries++; }
  assert.equal(encode({ ...native, prompt: "\ud800" }), null); boundaries++;
  let invoked = 0;
  const choices = [...wire.choices];
  Object.defineProperty(choices, "0", { enumerable: true, get() { invoked++; return wire.choices[0]; } });
  assert.equal(decode({ ...wire, choices }), null); assert.equal(invoked, 0); boundaries++;
  const entry = { ...wire.choices[0] };
  Object.defineProperty(entry, "label", { enumerable: true, get() { invoked++; return "private"; } });
  assert.equal(decode({ ...wire, choices: [entry] }), null); assert.equal(invoked, 0); boundaries++;
  const sparse = [...wire.choices]; delete sparse[0];
  assert.equal(decode({ ...wire, choices: sparse }), null); boundaries++;
  assert.equal(encode({ ...native, choices: [{ id: Buffer.from("x"), label: "\ud800" }] }), null); boundaries++;
  assert.notEqual(decode(Object.freeze({ ...wire, choices: Object.freeze(wire.choices.map(value => Object.freeze({ ...value }))) })), null); boundaries++;
}
console.log(JSON.stringify({ vectors: fixture.cases.length, boundary_checks: boundaries }));
