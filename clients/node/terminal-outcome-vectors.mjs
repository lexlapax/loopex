// Concept
// Execute the same terminal payload vectors as the Elixir protocol suite.
//
// Technical depth
// Expected quantities remain decimal strings in the fixture. This independent
// decoder uses BigInt internally and reports exact reference bytes as hex.
// Framing, runtime observation and chat driver behavior have separate proofs.

import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import { decodeTerminalOutcome } from "./terminal-outcome.mjs";

const [path] = process.argv.slice(2);
if (!path) throw new Error("usage: node terminal-outcome-vectors.mjs <vector-path>");
const fixture = JSON.parse(readFileSync(path, "utf8"));
assert.equal(fixture.format, "loopex.experimental.payload-vectors/1");

function retained(value) {
  if (typeof value === "bigint") return value.toString();
  if (Buffer.isBuffer(value)) return { opaque_hex: value.toString("hex") };
  if (value !== null && typeof value === "object") {
    return Object.fromEntries(Object.entries(value).map(([key, member]) => [key, retained(member)]));
  }
  return value;
}

for (const vector of fixture.cases) {
  const decoded = decodeTerminalOutcome(vector.input);
  assert.deepEqual(retained(decoded), vector.error ? null : vector.decoded, vector.name);
}

const reference = Buffer.alloc(65536, 255);
const unknown = { outcome: "outcome_unknown", details: { cleanup_grace_ms: "1", reconciliation_ref: reference.toString("base64url") } };
assert.deepEqual(decodeTerminalOutcome(unknown).details.reconciliation_ref, reference);
unknown.details.reconciliation_ref = Buffer.concat([reference, Buffer.from("x")]).toString("base64url");
assert.equal(decodeTerminalOutcome(unknown), null);
process.stdout.write(JSON.stringify({ contract: fixture.contract, checked: fixture.cases.length, boundary_checks: 2 }) + "\n");
