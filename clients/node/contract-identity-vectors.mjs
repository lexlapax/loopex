// Concept
// Check literal initialize replies, including mismatched digests, against both
// clients' retained contract pins.
//
// Technical depth
// Each vector names a client and whether its exact pinned generation/digest
// pair must verify. The verdict comes from the same matcher both connections
// use before admitting session traffic.
import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import { CURRENT_CONTRACTS, matchesContractIdentity } from "./contract-manifest.mjs";

const [path] = process.argv.slice(2);
if (!path) throw new Error("usage: contract-identity-vectors.mjs <vectors>");
const fixture = JSON.parse(readFileSync(path, "utf8"));
assert.equal(fixture.format, "loopex.experimental.contract-identity-vectors/1");
let verified = 0;
for (const vector of fixture.cases) {
  const verdict = matchesContractIdentity(vector.reply, CURRENT_CONTRACTS[vector.client]);
  assert.equal(verdict, vector.verified, vector.name);
  if (verdict) verified++;
}
process.stdout.write(JSON.stringify({ checked: fixture.cases.length, verified }) + "\n");
