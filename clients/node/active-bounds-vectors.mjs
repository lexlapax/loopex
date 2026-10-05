// Concept
// Check literal active bounds in an independent Node consumer.
// Technical depth
// Expected native quantities are retained strings in the vectors. The runner
// verifies BigInt types, both directions, closed objects and inert accessors.
import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import { createHash } from "node:crypto";
import { decodeActiveBounds, encodeActiveBounds } from "./active-bounds.mjs";

const [vectorPath, schemaPath] = process.argv.slice(2);
if (!vectorPath || !schemaPath) throw new Error("usage: active-bounds-vectors.mjs <vectors> <schema>");
const bytes = readFileSync(vectorPath);
const schemaBytes = readFileSync(schemaPath);
const fixture = JSON.parse(bytes);
const schema = JSON.parse(schemaBytes);
assert.equal(fixture.format, "loopex.experimental.payload-vectors/1");
assert.equal(fixture.contract, "active_bounds");
assert.deepEqual(schema, {
  "contract": "active_bounds",
  "revision": 1,
  "required": [
    "max_turns",
    "token_budget",
    "deadline_ms",
    "deadline"
  ],
  "additional_members": "refuse",
  "null": "refuse",
  "native_keys": "binary strings",
  "defaults": "none",
  "clock": "none",
  "max_turns": {
    "encoding": "canonical_decimal_string",
    "domain": "arbitrary_positive_integer",
    "minimum": "1"
  },
  "token_budget": {
    "encoding": "canonical_decimal_string",
    "domain": "arbitrary_positive_integer",
    "minimum": "1"
  },
  "deadline_ms": {
    "encoding": "canonical_decimal_string",
    "domain": "positive_uint64",
    "minimum": "1",
    "maximum": "18446744073709551615"
  },
  "deadline": {
    "encoding": "null_or_canonical_decimal_string",
    "domain": "nonnegative_uint64_or_null",
    "minimum": "0",
    "maximum": "18446744073709551615"
  }
});
assert.equal(createHash("sha256").update(bytes).digest("hex"), "27c8733a76233b4e9ca41ba22ca7484043b8c9ed815341b27855c8d49a522a83");
assert.equal(createHash("sha256").update(schemaBytes).digest("hex"), "f18c1c86184f3a34a0d627398318fdc9273aec9a7645a400b184e0d30130b4d5");
function retained(value) {
  if (value === null) return null;
  return Object.fromEntries(Object.entries(value).map(([key, scalar]) => {
    if (scalar !== null) assert.equal(typeof scalar, "bigint", key);
    return [key, scalar === null ? null : scalar.toString()];
  }));
}
for (const vector of fixture.cases) {
  const native = decodeActiveBounds(vector.input);
  assert.deepEqual(retained(native), vector.error ? null : vector.decoded, vector.name);
  if (!vector.error) assert.deepEqual(encodeActiveBounds(native), vector.input, vector.name);
}
const wire = { max_turns: "8", token_budget: "10000", deadline_ms: "60000", deadline: null };
const native = { max_turns: 8n, token_budget: 10000n, deadline_ms: 60000n, deadline: null };
let boundaryChecks = 0;
for (const encode of [false, true]) {
  const convert = encode ? encodeActiveBounds : decodeActiveBounds;
  const valid = encode ? native : wire;
  for (const value of [undefined, Object.create(null), new Map(), new Date()]) {
    assert.equal(convert(value), null); boundaryChecks++;
  }
  for (const key of Object.keys(valid)) {
    for (const type of ["getter", "setter"]) {
      let invoked = 0;
      const value = { ...valid };
      Object.defineProperty(value, key, type === "getter" ?
        { enumerable: true, get() { invoked++; return valid[key]; } } :
        { enumerable: true, set() { invoked++; } });
      assert.equal(convert(value), null);
      assert.equal(invoked, 0); boundaryChecks++;
    }
    assert.equal(convert({ ...valid, [key]: 1 }), null); boundaryChecks++;
    const hidden = { ...valid };
    Object.defineProperty(hidden, key, { enumerable: false, value: valid[key] });
    assert.equal(convert(hidden), null); boundaryChecks++;
  }
  assert.equal(convert({ ...valid, [Symbol("extra")]: "private" }), null); boundaryChecks++;
  assert.equal(convert({ ...valid, private: "canary" }), null); boundaryChecks++;
  const inherited = Object.assign(Object.create(valid), valid);
  assert.equal(convert(inherited), null); boundaryChecks++;
  assert.deepEqual(convert(Object.freeze({ ...valid })), encode ? wire : native); boundaryChecks++;
}
for (const key of Object.keys(native)) {
  for (const scalar of [-1n, "1", 1, 1.5, undefined, true, [], {}]) {
    assert.equal(encodeActiveBounds({ ...native, [key]: scalar }), null); boundaryChecks++;
  }
}
for (const key of ["max_turns", "token_budget", "deadline_ms"]) {
  for (const scalar of [0n, null]) {
    assert.equal(encodeActiveBounds({ ...native, [key]: scalar }), null); boundaryChecks++;
  }
}
for (const key of ["deadline_ms", "deadline"]) {
  assert.equal(encodeActiveBounds({ ...native, [key]: 18446744073709551616n }), null); boundaryChecks++;
}
assert.deepEqual(encodeActiveBounds({ ...native, deadline: 0n }), { ...wire, deadline: "0" }); boundaryChecks++;
console.log(JSON.stringify({ contract: "active_bounds", checked: fixture.cases.length, boundary_checks: boundaryChecks }));
