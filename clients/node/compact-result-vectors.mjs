// Concept
// Check literal standalone compaction results with an independent consumer.
//
// Technical depth
// Both protocol implementations read the retained fixture, whose expected
// quantities remain decimal strings and checkpoint bytes are hexadecimal.

import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import { decodeCompactResult, decodeCompactCompletion } from "./compact-result.mjs";

const [path, completionPath] = process.argv.slice(2);
if (!path) throw new Error("usage: node compact-result-vectors.mjs <vector-path>");
const fixture = JSON.parse(readFileSync(path, "utf8"));
assert.equal(fixture.format, "loopex.experimental.payload-vectors/1");
assert.equal(fixture.contract, "standalone_compact_result");

function retained(value) {
  if (typeof value === "bigint") return value.toString();
  if (Buffer.isBuffer(value)) return { opaque_hex: value.toString("hex") };
  if (value !== null && typeof value === "object") {
    return Object.fromEntries(Object.entries(value).map(([key, member]) => [key, retained(member)]));
  }
  return value;
}

for (const vector of fixture.cases) {
  assert.deepEqual(retained(decodeCompactResult(vector.input)), vector.error ? null : vector.decoded, vector.name);
}

const reference = Buffer.alloc(65536, 255);
const result = { disposition: "checkpointed", checkpoint_id: reference.toString("base64url"), failure: null,
  usage: { attempts: "0", reported_tokens: "0", estimated_tokens: "0", total_tokens: "0" }, cleanup: "confirmed" };
assert.deepEqual(decodeCompactResult(result).checkpoint_id, reference);
result.checkpoint_id = Buffer.concat([reference, Buffer.from("x")]).toString("base64url");
assert.equal(decodeCompactResult(result), null);
result.checkpoint_id = "_w";
assert.equal(decodeCompactResult(Object.assign(Object.create(null), result)), null);
assert.equal(decodeCompactResult(new Map(Object.entries(result))), null);
process.stdout.write(JSON.stringify({ contract: fixture.contract, checked: fixture.cases.length, boundary_checks: 4 }) + "\n");

if (completionPath) {
  const completionFixture = JSON.parse(readFileSync(completionPath, "utf8"));
  assert.equal(completionFixture.format, "loopex.experimental.payload-vectors/1");
  assert.equal(completionFixture.contract, "standalone_compact_completion");
  for (const vector of completionFixture.cases) {
    assert.deepEqual(retained(decodeCompactCompletion(vector.input)), vector.error ? null : vector.decoded, vector.name);
  }
  const completion = { episode_id: reference.toString("base64url"), command_id: reference.toString("base64url"), result };
  for (const key of ["episode_id", "command_id"]) {
    assert.deepEqual(decodeCompactCompletion(completion)[key], reference);
    completion[key] += "AA";
    assert.equal(decodeCompactCompletion(completion), null);
    completion[key] = reference.toString("base64url");
  }
  assert.equal(decodeCompactCompletion(Object.assign(Object.create(null), completion)), null);
  assert.equal(decodeCompactCompletion(new Map(Object.entries(completion))), null);
  process.stdout.write(JSON.stringify({ contract: completionFixture.contract, checked: completionFixture.cases.length, boundary_checks: 6 }) + "\n");
}
