// Concept
// Prove canonical schema bytes independently and bind every approved payload.
//
// Technical depth
// Golden values come from the Elixir canonical codec and are literal fixtures.
// Each changed embedded payload leaf must change the enclosing proof digest.
// This script pins no live generation and proves no transport lifecycle.
import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import { dirname, resolve } from "node:path";
import { canonicalSchemaBytes, canonicalSchemaDigest, parseSchemaJson, matchesContractIdentity } from "./contract-manifest.mjs";

const [path] = process.argv.slice(2);
if (!path) throw new Error("usage: node contract-manifest-vectors.mjs <canonical-schema-proof-vector>");
const fixture = parseSchemaJson(readFileSync(path));
assert.equal(fixture.format, "loopex.canonical.schema-proof.v1");
assert.equal(fixture.canonicalization_revision, "loopex.canonical.v1");
for (const vector of fixture.cases) {
  assert.equal(canonicalSchemaBytes(vector.input).toString("hex"), vector.canonical_hex, vector.name);
  assert.equal(canonicalSchemaDigest(vector.input), vector.sha256, vector.name);
}

const payloads = {};
for (const vector of fixture.payloads) {
  const payload = parseSchemaJson(readFileSync(resolve(dirname(path), "../schema", vector.schema)));
  assert.equal(canonicalSchemaBytes(payload).length, vector.canonical_bytes, vector.schema);
  assert.equal(canonicalSchemaDigest(payload), vector.canonical_sha256, vector.schema);
  payloads[vector.schema] = payload;
}
// This is a digest-binding experiment, not a foreground or daemon manifest.
const proof = { canonicalization_revision: fixture.canonicalization_revision, payload_definitions: payloads };
const digest = canonicalSchemaDigest(proof);
let mutations = 0;
function mutateLeaves(value, visit) {
  if (Array.isArray(value) || (value !== null && typeof value === "object")) {
    for (const key of Object.keys(value)) {
      const child = value[key];
      if (child !== null && typeof child === "object") mutateLeaves(child, visit);
      else {
        value[key] = child === null ? false : typeof child === "boolean" ? !child : typeof child === "number" ? child + 1 : child + "!";
        visit(); value[key] = child;
      }
    }
  }
}
mutateLeaves(payloads, () => { assert.notEqual(canonicalSchemaDigest(proof), digest); mutations++; });
assert.equal(canonicalSchemaDigest(proof), digest);
assert.notEqual(canonicalSchemaDigest({ ...proof, payload_definitions: {} }), digest);
assert.equal(canonicalSchemaDigest({ z: 1, aa: 2 }), canonicalSchemaDigest({ aa: 2, z: 1 }));
assert.notEqual(canonicalSchemaDigest(["a", "b"]), canonicalSchemaDigest(["b", "a"]));
assert.equal(canonicalSchemaDigest(parseSchemaJson(Buffer.from('-0'))), canonicalSchemaDigest(0));

const rejectedJson = ['{"a":1,"a":2}', '{"nested":{"x":1,"x":2}}', '{"x":1,"\\u0078":2}', '[1.5]', '[1e3]', '[9007199254740992]', '[-9007199254740992]', '[01]', '[1,]', '{"a":1,}', 'null null', '"\\ud800"'];
for (const value of rejectedJson) assert.throws(() => parseSchemaJson(Buffer.from(value)));
assert.throws(() => parseSchemaJson(Buffer.from([0xff])));
for (const value of [undefined, 1.5, NaN, Infinity, 9007199254740992, new Map(), Object.create(null), Array(2), Object.assign([], { extra: 1 }), Object.defineProperty({}, "hidden", { value: 1 }), Symbol("x"), "\ud800"]) {
  assert.throws(() => canonicalSchemaBytes(value));
}
let getterInvocations = 0;
const objectGetter = Object.defineProperty({}, "x", { enumerable: true, get() { getterInvocations++; return 1; } });
const arrayGetter = Object.defineProperty([1], "0", { enumerable: true, get() { getterInvocations++; return 1; } });
const objectSetter = Object.defineProperty({}, "x", { enumerable: true, set(_value) { throw new Error("setter invoked"); } });
const arraySetter = Object.defineProperty([1], "0", { enumerable: true, get: undefined, set(_value) { throw new Error("setter invoked"); } });
for (const value of [objectGetter, arrayGetter, objectSetter, arraySetter]) {
  assert.throws(() => canonicalSchemaBytes(value), /accessor/);
}
assert.equal(getterInvocations, 0);
assert.equal(canonicalSchemaDigest(Object.freeze({ x: 1 })), canonicalSchemaDigest({ x: 1 }));
assert.equal(canonicalSchemaDigest(Object.freeze([1, "x"])), canonicalSchemaDigest([1, "x"]));
const expected = { generation: "test-generation", schemaDigest: fixture.payloads[0].canonical_sha256 };
const reply = { type: "initialized", selected_generation: expected.generation, exact_schema_sha256: expected.schemaDigest };
assert.equal(matchesContractIdentity(reply, expected), true);
assert.equal(matchesContractIdentity({ ...reply, selected_generation: "wrong-generation" }, expected), false);
assert.equal(matchesContractIdentity({ ...reply, exact_schema_sha256: "0".repeat(64) }, expected), false);
assert.equal(matchesContractIdentity({ ...reply, type: "error" }, expected), false);
assert.equal(matchesContractIdentity(null, expected), false);
assert.equal(matchesContractIdentity(reply, { ...expected, schemaDigest: expected.schemaDigest.toUpperCase() }), false);
process.stdout.write(JSON.stringify({ canonical_cases: fixture.cases.length, approved_payloads: fixture.payloads.length, embedded_leaf_mutations: mutations, rejected_json: rejectedJson.length + 1, identity_checks: 6, accessor_checks: 4, frozen_data_checks: 2 }) + "\n");
