// Concept
// Check literal checkpoint owners with an independent consumer.
//
// Technical depth
// Retain exact opaque bytes, reject superseded aliases and test the complete
// identity ceiling separately from the small checked-in literal fixture.

import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import { decodeCheckpointOwner } from "./checkpoint-owner.mjs";

const [path] = process.argv.slice(2);
if (!path) throw new Error("usage: node checkpoint-owner-vectors.mjs <vector-path>");
const fixture = JSON.parse(readFileSync(path, "utf8"));
assert.equal(fixture.format, "loopex.experimental.payload-vectors/1");
assert.equal(fixture.contract, "checkpoint_owner");
for (const vector of fixture.cases) {
  const decoded = decodeCheckpointOwner(vector.input);
  const retained = decoded === null ? null : { kind: decoded.kind, id: { opaque_hex: decoded.id.toString("hex") } };
  assert.deepEqual(retained, vector.error ? null : vector.decoded, vector.name);
}
const id = Buffer.alloc(65536, 255);
const value = { kind: "compact", id: id.toString("base64url") };
assert.deepEqual(decodeCheckpointOwner(value).id, id);
assert.equal(decodeCheckpointOwner({ ...value, id: Buffer.concat([id, Buffer.from("x")]).toString("base64url") }), null);
assert.equal(decodeCheckpointOwner(Object.assign(Object.create(null), value)), null);
assert.equal(decodeCheckpointOwner(new Map(Object.entries(value))), null);
process.stdout.write(JSON.stringify({ contract: fixture.contract, checked: fixture.cases.length, boundary_checks: 4 }) + "\n");
