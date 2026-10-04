// Concept
// Check literal configuration and checkpoint payloads independently of Elixir.
// Technical depth
// JSON literals retain exact decimal spellings and expected opaque byte images.
// Separate full-byte cases exercise every identity position and UTF-8 ceilings.

import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import { decodeConfiguration, decodeConfiguredEvent } from "./configuration.mjs";
import { decodeCheckpoint } from "./checkpoint.mjs";

const [configurationPath, checkpointPath] = process.argv.slice(2);
if (!configurationPath || !checkpointPath) throw new Error("usage: snapshot-payload-vectors.mjs <configuration-vectors> <checkpoint-vectors>");
const configurations = JSON.parse(readFileSync(configurationPath, "utf8"));
const checkpoints = JSON.parse(readFileSync(checkpointPath, "utf8"));

function retained(value) {
  if (typeof value === "bigint") return value.toString();
  if (Buffer.isBuffer(value)) return { opaque_hex: value.toString("hex") };
  if (value !== null && typeof value === "object") return Object.fromEntries(Object.entries(value).map(([key, member]) => [key, retained(member)]));
  return value;
}

for (const fixture of [configurations, checkpoints]) {
  assert.equal(fixture.format, "loopex.experimental.payload-vectors/1");
  for (const vector of fixture.cases) {
    const decode = fixture.contract === "checkpoint_projection" ? decodeCheckpoint :
      vector.scope === "configured_event" ? decodeConfiguredEvent : decodeConfiguration;
    assert.deepEqual(retained(decode(vector.input)), vector.error ? null : vector.decoded, vector.name);
  }
}

let boundaries = 0;
const config = configurations.cases.find(vector => vector.name === "initial").input;
const checkpoint = checkpoints.cases.find(vector => vector.name === "run-covered-prefix").input;
const model = "é".repeat(65536);
for (const [value, decode] of [[config, decodeConfiguration], [checkpoint, decodeCheckpoint]]) {
  assert.notEqual(decode({ ...value, model }), null); boundaries++;
  assert.equal(decode({ ...value, model: model + "x" }), null); boundaries++;
  assert.equal(decode({ ...value, model: "\ud800" }), null); boundaries++;
  assert.equal(decode(Object.assign(Object.create(null), value)), null); boundaries++;
  assert.equal(decode(new Map(Object.entries(value))), null); boundaries++;
}
assert.notEqual(decodeConfiguration({ ...config, instructions: { ...config.instructions, version: "v".repeat(64) } }), null); boundaries++;
assert.equal(decodeConfiguration({ ...config, instructions: { ...config.instructions, version: "v".repeat(65) } }), null); boundaries++;

function put(value, path, member) {
  const copy = structuredClone(value);
  let at = copy;
  for (const key of path.slice(0, -1)) at = at[key];
  at[path.at(-1)] = member;
  return copy;
}

const bytes = Buffer.alloc(65536, 255);
for (const path of [["checkpoint_id"], ["episode_id"], ["prior_checkpoint_id"], ["owner", "id"],
    ["covered_range", "first", "run_id"], ["covered_range", "first", "command_id"],
    ["covered_range", "last", "run_id"], ["covered_range", "first_kept", "run_id"],
    ["covered_range", "first_kept", "call_id"]]) {
  let decoded = decodeCheckpoint(put(checkpoint, path, bytes.toString("base64url")));
  assert.notEqual(decoded, null);
  for (const key of path) decoded = decoded[key];
  assert.deepEqual(decoded, bytes); boundaries++;
  assert.equal(decodeCheckpoint(put(checkpoint, path, Buffer.concat([bytes, Buffer.from("x")]).toString("base64url"))), null); boundaries++;
}
const change = { command_id: bytes.toString("base64url"), configuration: config };
assert.deepEqual(decodeConfiguredEvent(change).command_id, bytes); boundaries++;
assert.equal(decodeConfiguredEvent({ ...change, command_id: Buffer.concat([bytes, Buffer.from("x")]).toString("base64url") }), null); boundaries++;
assert.equal(decodeConfiguredEvent(Object.assign(Object.create(null), change)), null); boundaries++;
assert.equal(decodeConfiguredEvent(new Map(Object.entries(change))), null); boundaries++;
process.stdout.write(JSON.stringify({ configuration_vectors: configurations.cases.length,
  checkpoint_vectors: checkpoints.cases.length, boundary_checks: boundaries }) + "\n");
