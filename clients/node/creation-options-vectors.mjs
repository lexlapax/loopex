// Concept
// Independently validate literal authored creation options without host capture.
// Technical depth
// This dormant consumer checks parsed objects after duplicate-aware framing.
// Every literal and byte-boundary case uses BigInt and an exact native projection.
import assert from "node:assert/strict";
import { createHash } from "node:crypto";
import { readFileSync } from "node:fs";
import { decodeCreationOptions, decodeConfigureChanges } from "./configure-request.mjs";

const [vectorsPath, schemaPath] = process.argv.slice(2);
if (!vectorsPath || !schemaPath) throw new Error("usage: creation-options-vectors.mjs <vectors> <schema>");
const vectorsBytes = readFileSync(vectorsPath);
const schemaBytes = readFileSync(schemaPath);
assert.equal(createHash("sha256").update(vectorsBytes).digest("hex"), "ce9a93a1a3ea92135f914642784467b9dc45cd769b66aaa6b1ae9b0ae003ccbb");
assert.equal(createHash("sha256").update(schemaBytes).digest("hex"), "017ccd7949985f9ae07aa6dce90e2139ed086040b157dde75fcf396cff64b876");
const vectors = JSON.parse(vectorsBytes.toString("utf8"));
const schema = JSON.parse(schemaBytes.toString("utf8"));
assert.equal(vectors.contract, "creation_options");
assert.equal(vectors.cases.length, 398);
assert.equal(schema.closed, true);
assert.deepEqual(schema.required, ["version"]);
assert.deepEqual(schema.optional, ["configuration", "tools"]);
assert.deepEqual(schema.version, { type: "json_integer", exact: 1 });
assert.equal(schema.tools.items_max, 1024);
assert.equal(schema.generation_activation, false);

function retained(value) {
  if (typeof value === "bigint") return value.toString();
  if (Array.isArray(value)) return value.map(retained);
  if (value !== null && typeof value === "object") return Object.fromEntries(Object.entries(value).map(([key, member]) => [key, retained(member)]));
  return value;
}
for (const vector of vectors.cases) {
  assert.deepEqual(retained(decodeCreationOptions(vector.input)), vector.error ? null : vector.decoded, vector.name);
}
for (const mode of ["omitted", "empty", "ordered"]) {
  const subsets = vectors.cases.filter(vector => vector.name.startsWith("configuration-subset-") && vector.name.endsWith(`-tools-${mode}`));
  assert.equal(subsets.length, 63);
  assert.equal(new Set(subsets.map(vector => Object.keys(vector.input.configuration).sort().join(","))).size, 63);
}
let boundaries = 0;
function refuses(value) { assert.equal(decodeCreationOptions(value), null); boundaries++; }
for (const value of [undefined, 1n, { version: 1, model: "private" }, { version: 1, tools: ["\ud800"] }, { version: 1, configuration: { model: "\udfff" } }]) refuses(value);
for (const terminator of ["\n", "\r", "\u2028"]) {
  for (const quantity of ["max_tokens", "context_token_budget", "system_class_tokens"]) {
    refuses({ version: 1, configuration: { [quantity]: "1" + terminator } });
  }
}
const options = { version: 1, configuration: { model: "alias" }, tools: ["read", "write"] };
for (const key of Object.keys(options)) {
  let invoked = 0;
  const getter = { ...options };
  Object.defineProperty(getter, key, { enumerable: true, get() { invoked++; return options[key]; } });
  refuses(getter); assert.equal(invoked, 0);
  const hidden = { ...options };
  Object.defineProperty(hidden, key, { value: options[key], enumerable: false });
  refuses(hidden);
}
refuses(Object.assign(Object.create(null), options));
refuses({ ...options, [Symbol("private")]: true });
assert.deepEqual(decodeCreationOptions(Object.freeze({ ...options, tools: Object.freeze(["read", "write"]) })), options); boundaries++;
refuses({ version: 1, tools: new Array(1) });
refuses({ version: 1, tools: Object.assign(["read"], { private: "x" }) });
refuses({ version: 1, tools: Object.assign(["read"], { [Symbol("private")]: true }) });
const wrongPrototype = ["read"];
Object.setPrototypeOf(wrongPrototype, null);
refuses({ version: 1, tools: wrongPrototype });
let invoked = 0;
const getterTools = ["read"];
Object.defineProperty(getterTools, "0", { enumerable: true, get() { invoked++; return "private"; } });
refuses({ version: 1, tools: getterTools }); assert.equal(invoked, 0);
for (const key of ["base", "environment", "appendix"]) {
  refuses({ version: 1, configuration: { instructions: { version: "v", base: "a", environment: "", appendix: "", [key]: "\ud800" } } });
}
// Existing configure exports retain their authored domains and native BigInt.
assert.deepEqual(decodeConfigureChanges({ model: " alias ", max_tokens: "9007199254740993" }), { model: " alias ", max_tokens: 9007199254740993n });
console.log(JSON.stringify({ vectors: vectors.cases.length, subset_cases: 189, boundary_checks: boundaries }));
