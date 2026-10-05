// Concept
// Independently verify complete current snapshots and open questions.
// Technical depth
// Literal expected opaque bytes and decimal quantities are authored separately
// from the Elixir codecs. Full-byte probes retain exact UTF-8 and identity bounds.

import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import { decodeOpenInteraction } from "./open-interaction.mjs";
import { decodeSnapshot } from "./snapshot.mjs";

const [pendingPath, snapshotPath] = process.argv.slice(2);
if (!pendingPath || !snapshotPath) throw new Error("usage: snapshot-vectors.mjs <pending-vectors> <snapshot-vectors>");
const pending = JSON.parse(readFileSync(pendingPath, "utf8"));
const snapshots = JSON.parse(readFileSync(snapshotPath, "utf8"));

function retained(value) {
  if (typeof value === "bigint") return value.toString();
  if (Buffer.isBuffer(value)) return { opaque_hex: value.toString("hex") };
  if (Array.isArray(value)) return value.map(retained);
  if (value !== null && typeof value === "object") return Object.fromEntries(Object.entries(value).map(([key, member]) => [key, retained(member)]));
  return value;
}

for (const [fixture, decode] of [[pending, decodeOpenInteraction], [snapshots, decodeSnapshot]]) {
  assert.equal(fixture.format, "loopex.experimental.payload-vectors/1");
  for (const vector of fixture.cases) {
    assert.deepEqual(retained(decode(vector.input)), vector.error ? null : vector.decoded, vector.name);
  }
}

let boundaries = 0;
const policy = pending.cases.find(vector => vector.name === "policy-choice").input;
const creation = snapshots.cases.find(vector => vector.name === "creation").input;
const full = Buffer.alloc(65536, 255);
for (const key of ["interaction_id", "run_id", "tool_call_id"]) {
  assert.deepEqual(decodeOpenInteraction({ ...policy, [key]: full.toString("base64url") })[key], full); boundaries++;
  assert.equal(decodeOpenInteraction({ ...policy, [key]: Buffer.concat([full, Buffer.from("x")]).toString("base64url") }), null); boundaries++;
}
const short = Buffer.alloc(64, 255);
assert.deepEqual(decodeOpenInteraction({ ...policy, choices: [{ id: short.toString("base64url"), label: "Proceed" }] }).choices[0].id, short); boundaries++;
assert.equal(decodeOpenInteraction({ ...policy, choices: [{ id: Buffer.concat([short, Buffer.from("x")]).toString("base64url"), label: "Proceed" }] }), null); boundaries++;
assert.notEqual(decodeOpenInteraction({ ...policy, prompt: "é".repeat(1024) }), null); boundaries++;
assert.equal(decodeOpenInteraction({ ...policy, prompt: "é".repeat(1024) + "x" }), null); boundaries++;
assert.notEqual(decodeOpenInteraction({ ...policy, choices: [{ id: "YQ", label: "é".repeat(128) }] }), null); boundaries++;
assert.equal(decodeOpenInteraction({ ...policy, choices: [{ id: "YQ", label: "é".repeat(128) + "x" }] }), null); boundaries++;
assert.equal(decodeOpenInteraction({ ...policy, prompt: "\ud800" }), null); boundaries++;
for (const [value, decode] of [[policy, decodeOpenInteraction], [creation, decodeSnapshot]]) {
  assert.equal(decode(Object.assign(Object.create(null), value)), null); boundaries++;
  assert.equal(decode(new Map(Object.entries(value))), null); boundaries++;
}
const session = Buffer.alloc(256, 255);
assert.deepEqual(decodeSnapshot({ ...creation, session_id: session.toString("base64url") }).session_id, session); boundaries++;
assert.equal(decodeSnapshot({ ...creation, session_id: Buffer.concat([session, Buffer.from("x")]).toString("base64url") }), null); boundaries++;
const running = { ...creation, event_sequence: "1", active_run_phase: "started", active_run_id: full.toString("base64url") };
assert.deepEqual(decodeSnapshot(running).active_run_id, full); boundaries++;
assert.equal(decodeSnapshot({ ...running, active_run_id: Buffer.concat([full, Buffer.from("x")]).toString("base64url") }), null); boundaries++;
process.stdout.write(JSON.stringify({ open_vectors: pending.cases.length, snapshot_vectors: snapshots.cases.length, boundary_checks: boundaries }) + "\n");
