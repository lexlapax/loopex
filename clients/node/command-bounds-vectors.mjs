// Concept
// Check literal bounds vectors without deriving expected results from a codec.
// Technical depth
// Decimal native values compare as retained strings; absolute deadlines remain
// Numbers. Both encoding directions and enclosing omission are checked.
import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import { decodeCommandBounds, encodeCommandBounds } from "./command-bounds.mjs";

const [path, schemaPath] = process.argv.slice(2);
if (!path || !schemaPath) throw new Error("usage: command-bounds-vectors.mjs <vectors> <schema>");
const fixture = JSON.parse(readFileSync(path, "utf8"));
const schema = JSON.parse(readFileSync(schemaPath, "utf8"));
assert.equal(fixture.format, "loopex.experimental.payload-vectors/1");
assert.equal(fixture.contract, "command_bounds");
assert.equal(schema.contract, fixture.contract);
assert.equal(schema.prompt.fields.deadline_ms.maximum, "18446744073709551615");
assert.equal(schema.prompt.fields.deadline_at_ms.maximum, 9007199254740991);
assert.deepEqual(schema.compact.required, ["max_attempts", "deadline_ms", "token_budget"]);
function retained(value) {
  if (value === null) return null;
  return Object.fromEntries(Object.entries(value).map(([key, scalar]) =>
    [key, typeof scalar === "bigint" ? scalar.toString() : scalar]));
}
for (const vector of fixture.cases) {
  const decoded = decodeCommandBounds(vector.input, vector.kind);
  assert.deepEqual(retained(decoded), vector.error ? null : vector.decoded, vector.name);
  if (!vector.error) assert.deepEqual(encodeCommandBounds(decoded, vector.kind), vector.input, vector.name);
}
for (const vector of fixture.enclosing_request_cases) {
  const request = { ...vector.request };
  if (Object.hasOwn(request, "bounds")) {
    request.bounds = encodeCommandBounds(decodeCommandBounds(request.bounds, vector.kind), vector.kind);
  }
  assert.deepEqual(request, vector.expected);
  assert.equal(Object.hasOwn(request, "bounds"), Object.hasOwn(vector.request, "bounds"));
}
let boundaryChecks = 0;
for (const kind of ["prompt", "follow_up", "compact"]) {
  for (const value of [undefined, Object.create(null), new Map(), new Date()]) {
    assert.equal(decodeCommandBounds(value, kind), null); boundaryChecks++;
  }
}
for (const [kind, key] of [["prompt", "max_turns"], ["follow_up", "deadline_at_ms"], ["compact", "token_budget"]]) {
  let invoked = 0;
  const value = kind === "compact" ? { max_attempts: "1", deadline_ms: "1" } : {};
  Object.defineProperty(value, key, { enumerable: true, get() { invoked++; return "1"; } });
  assert.equal(decodeCommandBounds(value, kind), null);
  assert.equal(invoked, 0); boundaryChecks++;
}
const frozen = Object.freeze({ max_turns: "9007199254740993", deadline_at_ms: 9007199254740991 });
assert.deepEqual(encodeCommandBounds(decodeCommandBounds(frozen, "prompt"), "prompt"), frozen); boundaryChecks++;
for (const value of [0n, -1n, "1", 1, 1.5, null, true, {}, []]) {
  assert.equal(encodeCommandBounds({ max_turns: value }, "prompt"), null); boundaryChecks++;
}
for (const [kind, key, maximum] of [["prompt", "deadline_ms", 18446744073709551615n],
  ["compact", "max_attempts", 4n], ["compact", "deadline_ms", 60000n], ["compact", "token_budget", 32768n]]) {
  const value = kind === "compact" ? { max_attempts: 1n, deadline_ms: 1n, token_budget: 1n } : {};
  value[key] = maximum + 1n;
  assert.equal(encodeCommandBounds(value, kind), null); boundaryChecks++;
}
for (const value of [0, -1, 9007199254740992, 1.5, 1n, "1", null, true]) {
  assert.equal(encodeCommandBounds({ deadline_at_ms: value }, "prompt"), null); boundaryChecks++;
}
for (const value of [Object.assign({ max_turns: "1" }, { [Symbol("private")]: "canary" }),
  Object.defineProperty({}, "max_turns", { value: "1", enumerable: false })]) {
  assert.equal(decodeCommandBounds(value, "prompt"), null); boundaryChecks++;
}
process.stdout.write(JSON.stringify({ contract: fixture.contract, checked: fixture.cases.length,
  enclosing_checks: fixture.enclosing_request_cases.length, boundary_checks: boundaryChecks }) + "\n");
