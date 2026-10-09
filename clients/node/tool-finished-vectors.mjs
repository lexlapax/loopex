// Concept
// Check both closed tool-terminal shapes against literal vectors, without
// trusting the server's decoder for any expected value.
//
// Technical depth
// The retained schema and vector bytes are pinned by digest. Full identity,
// reason and quantity boundaries plus inert-object controls run separately from
// the small literals. No transport or producer lifecycle is exercised here.
import assert from "node:assert/strict";
import { createHash } from "node:crypto";
import { readFileSync } from "node:fs";
import { decodeToolFinished } from "./tool-finished.mjs";

const [vectorPath, schemaPath] = process.argv.slice(2);
if (!vectorPath || !schemaPath) throw new Error("usage: tool-finished-vectors.mjs <vectors> <schema>");
const vectorBytes = readFileSync(vectorPath);
const schemaBytes = readFileSync(schemaPath);
assert.equal(createHash("sha256").update(vectorBytes).digest("hex"), "be179d2088911e1669b72c746f1602ed499ec1d85d2e18f3e3a774776803f9e0");
assert.equal(createHash("sha256").update(schemaBytes).digest("hex"), "62446d5e307f631aae78ae6418bafd6c6f4f52d6fb35f0ceb91da87a5f1b19d4");
const fixture = JSON.parse(vectorBytes.toString("utf8"));
const schema = JSON.parse(schemaBytes.toString("utf8"));
assert.equal(fixture.format, "loopex.experimental.payload-vectors/1");
assert.equal(fixture.contract, "tool_finished");
assert.equal(schema.contract, fixture.contract);
assert.equal(schema.revision, 1);
assert.equal(schema.event_kind, "tool.finished");
assert.equal(schema.selection, "exact_member_key_set_without_fallback");
assert.deepEqual(schema.variants.receipt_backed.required,
  ["run_id", "turn_id", "tool_call_id", "operation_id", "tool_id", "outcome", "reason", "artifacts"]);
assert.equal(schema.variants.receipt_backed.reason, null);
assert.deepEqual(schema.variants.operation_less.required,
  ["run_id", "turn_id", "tool_call_id", "tool_id", "outcome", "reason", "artifacts"]);
assert.deepEqual(schema.variants.operation_less.reason,
  { nullable: true, encoding: "utf8", minimum_bytes: 0, maximum_bytes: 131072, normalization: "none" });
assert.deepEqual(schema.variants.operation_less.artifacts, { type: "array", exact: [] });
assert.deepEqual(schema.outcome_enum,
  ["completed", "failed", "denied", "cancelled", "outcome_unknown", "cancelled_workspace_lease_lost"]);

function retained(value) {
  if (typeof value === "bigint") return value.toString();
  if (Buffer.isBuffer(value)) return { opaque_hex: value.toString("hex") };
  if (Array.isArray(value)) return value.map(retained);
  if (value !== null && typeof value === "object") return Object.fromEntries(Object.entries(value).map(([key, member]) => [key, retained(member)]));
  return value;
}

let positive = 0;
for (const vector of fixture.cases) {
  assert.deepEqual(retained(decodeToolFinished(vector.input)), vector.error ? null : vector.decoded, vector.name);
  if (!vector.error) {
    positive++;
    assert.equal(Object.hasOwn(vector.input, "operation_id"), vector.variant === "receipt_backed", vector.name);
  }
}

let boundaryChecks = 0;
const check = (value, admitted, label) => {
  assert.equal(decodeToolFinished(value) !== null, admitted, label);
  boundaryChecks++;
};
const receipt = fixture.cases.find(vector => vector.name === "r8-completed").input;
const lessened = fixture.cases.find(vector => vector.name === "t7-completed-null-reason").input;
for (const key of ["run_id", "turn_id", "tool_call_id", "operation_id"]) {
  for (const [size, admitted] of [[1, true], [65536, true], [65537, false]]) {
    const bytes = Buffer.alloc(size, 255);
    const value = { ...receipt, [key]: bytes.toString("base64url") };
    check(value, admitted, `${key}: ${size}`);
    if (admitted) assert.deepEqual(decodeToolFinished(value)[key], bytes);
  }
}
for (const [reason, admitted] of [
  ["a".repeat(131072), true], ["a".repeat(131073), false],
  ["é".repeat(65536), true], ["é".repeat(65536) + "a", false],
  ["\ud800", false], ["a\udfffb", false], ["", true]
]) {
  check({ ...lessened, reason }, admitted, `reason bytes ${Buffer.byteLength(reason)}`);
  if (admitted) assert.equal(decodeToolFinished({ ...lessened, reason }).reason, reason);
}
const artifact = fixture.cases.find(vector => vector.name === "r8-one-artifact-size-u64-max").input.artifacts[0];
for (const [size, admitted] of [["18446744073709551615", true], ["18446744073709551616", false], ["9007199254740993", true]]) {
  const value = { ...receipt, artifacts: [{ ...artifact, size }] };
  check(value, admitted, `size ${size}`);
  if (admitted) assert.equal(decodeToolFinished(value).artifacts[0].size, BigInt(size));
}
for (const [locator, admitted] of [["x".repeat(1024), true], ["é".repeat(512), true], ["é".repeat(512) + "x", false]]) {
  check({ ...receipt, artifacts: [{ ...artifact, locator }] }, admitted, `locator ${Buffer.byteLength(locator)}`);
}
// Inert data only: accessors, inherited members, symbols, non-plain prototypes
// and hidden members refuse before any member value is read.
const getter = { ...lessened };
delete getter.reason;
Object.defineProperty(getter, "reason", { get() { throw new Error("getter executed"); }, enumerable: true });
check(getter, false, "accessor member");
check(Object.assign(Object.create({ reason: null }), (({ reason, ...rest }) => rest)(lessened)), false, "inherited member");
check({ ...lessened, [Symbol("private")]: "PRIVATE_CANARY" }, false, "symbol member");
const hidden = { ...lessened };
Object.defineProperty(hidden, "private_reason", { value: "PRIVATE_CANARY", enumerable: false });
check(hidden, false, "non-enumerable member");
check(Object.assign(Object.create(null), lessened), false, "null prototype");
class Event { constructor() { Object.assign(this, lessened); } }
check(new Event(), false, "class instance");
const arrayLike = { ...receipt, artifacts: Object.assign(Object.create({ length: 0 }), {}) };
check(arrayLike, false, "array-like artifacts");
check({ ...lessened, artifacts: new (class extends Array {})() }, false, "array subclass artifacts");
check({ ...receipt, artifacts: [Object.assign(Object.create(null), artifact)] }, false, "null-prototype artifact");

process.stdout.write(JSON.stringify({ contract: "tool_finished", checked: fixture.cases.length, positive, boundary_checks: boundaryChecks }) + "\n");
