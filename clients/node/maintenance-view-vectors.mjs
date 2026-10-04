// Concept
// Prove the maintenance payload with an independent consumer of literal bytes.
//
// Technical depth
// Expected quantities stay decimal strings and opaque identities are hex.
// Separate boundary cases exercise full identity and UTF-8 byte ceilings.

import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import { decodeMaintenanceView } from "./maintenance-view.mjs";

const [path] = process.argv.slice(2);
if (!path) throw new Error("usage: node maintenance-view-vectors.mjs <vector-path>");
const fixture = JSON.parse(readFileSync(path, "utf8"));
assert.equal(fixture.format, "loopex.experimental.payload-vectors/1");
assert.equal(fixture.contract, "maintenance_view");

function retained(value) {
  if (typeof value === "bigint") return value.toString();
  if (Buffer.isBuffer(value)) return { opaque_hex: value.toString("hex") };
  if (value !== null && typeof value === "object") {
    return Object.fromEntries(Object.entries(value).map(([key, member]) => [key, retained(member)]));
  }
  return value;
}

for (const vector of fixture.cases) {
  assert.deepEqual(retained(decodeMaintenanceView(vector.input)), vector.error ? null : vector.decoded, vector.name);
}

const payload = structuredClone(fixture.cases.find(value => value.name === "run-captured-null-deadline").input);
const view = payload.active_maintenance;
const reference = Buffer.alloc(65536, 255);
let boundaryChecks = 0;
for (const member of ["episode_id", "owner"]) {
  const container = member === "owner" ? view.owner : view;
  const key = member === "owner" ? "id" : member;
  const prior = container[key];
  container[key] = reference.toString("base64url");
  const decoded = decodeMaintenanceView(payload).active_maintenance;
  assert.deepEqual(member === "owner" ? decoded.owner.id : decoded.episode_id, reference);
  container[key] = Buffer.concat([reference, Buffer.from("x")]).toString("base64url");
  assert.equal(decodeMaintenanceView(payload), null);
  container[key] = prior;
  boundaryChecks += 2;
}
view.model = "🙂".repeat(32768);
assert.equal(decodeMaintenanceView(payload).active_maintenance.model, view.model);
view.model += "x";
assert.equal(decodeMaintenanceView(payload), null);
view.model = "\ud800";
assert.equal(decodeMaintenanceView(payload), null);
view.model = "model";
for (const target of [payload, view, view.owner, view.bounds]) {
  const path = target === payload ? [] : target === view ? ["active_maintenance"] :
    target === view.owner ? ["active_maintenance", "owner"] : ["active_maintenance", "bounds"];
  for (const replacement of [Object.assign(Object.create(null), target), new Map(Object.entries(target))]) {
    const altered = structuredClone(payload);
    if (path.length === 0) assert.equal(decodeMaintenanceView(replacement), null);
    else {
      let parent = altered;
      for (const key of path.slice(0, -1)) parent = parent[key];
      parent[path.at(-1)] = replacement;
      assert.equal(decodeMaintenanceView(altered), null);
    }
    boundaryChecks++;
  }
}
boundaryChecks += 3;
process.stdout.write(JSON.stringify({ contract: fixture.contract, checked: fixture.cases.length, boundary_checks: boundaryChecks }) + "\n");
