// Concept
// Check literal compaction activity without treating delivery as completion.
//
// Technical depth
// The independent decoder consumes retained schema/vector bytes. Full identity
// boundaries and inert-object controls are separate from the small literals.
// No transport, producer lifecycle or served generation is activated here.
import assert from "node:assert/strict";
import { createHash } from "node:crypto";
import { readFileSync } from "node:fs";
import { decodeCompactionProgress } from "./compaction-progress.mjs";

const [vectorPath, schemaPath] = process.argv.slice(2);
if (!vectorPath || !schemaPath) throw new Error("usage: compaction-progress-vectors.mjs <vectors> <schema>");
const vectorBytes = readFileSync(vectorPath);
const schemaBytes = readFileSync(schemaPath);
assert.equal(createHash("sha256").update(vectorBytes).digest("hex"), "abba85710b11506ab9696f29245a639eebe3450576738dd59cfc43e725bc72e6");
assert.equal(createHash("sha256").update(schemaBytes).digest("hex"), "9180e6bb1ba51a85c0806dd5761033bb9a16b53fde964d6e58d758d2d155617e");
const fixture = JSON.parse(vectorBytes.toString("utf8"));
const schema = JSON.parse(schemaBytes.toString("utf8"));
assert.equal(fixture.format, "loopex.experimental.payload-vectors/1");
assert.equal(fixture.contract, "compaction_progress");
assert.equal(fixture.cases.length, 185);
assert.equal(schema.contract, fixture.contract);
assert.equal(schema.revision, 1);
assert.equal(schema.activation, "standalone_payload_not_independently_served");
assert.deepEqual(schema.required, ["kind", "episode_id", "owner", "stream_domain_id", "progress_sequence", "base_event_sequence"]);
assert.equal(schema.additional_members, "refuse");
assert.equal(schema.kind, "context.compaction_progress");
assert.equal(schema.owner, "checkpoint_owner/1");
assert.deepEqual(schema.episode_id, { encoding: "canonical_unpadded_base64url_of_original_opaque_bytes", original_min_bytes: 1, original_max_bytes: 65536 });
assert.deepEqual(schema.stream_domain_id, { encoding: "canonical_unpadded_base64url_of_original_opaque_bytes", original_bytes: 32, original_grammar: "[0-9a-f]{32}" });
assert.deepEqual(schema.progress_sequence, { encoding: "canonical_decimal_string", constant: "0" });
assert.deepEqual(schema.base_event_sequence, { encoding: "canonical_decimal_string", minimum: "0", maximum: "18446744073709551615" });
assert.equal(schema.delivery, "single_best_effort_observation_per_positively_permitted_attempt");
assert.equal(schema.closure, "none");

function retained(value) {
  if (typeof value === "bigint") return value.toString();
  if (Buffer.isBuffer(value)) return { opaque_hex: value.toString("hex") };
  if (value !== null && typeof value === "object") return Object.fromEntries(Object.entries(value).map(([key, member]) => [key, retained(member)]));
  return value;
}

for (const vector of fixture.cases) {
  assert.deepEqual(retained(decodeCompactionProgress(vector.input)), vector.error ? null : vector.decoded, vector.name);
}

let boundaryChecks = 0;
const wire = fixture.cases.find(vector => vector.name === "run-zero-opaque").input;
for (const kind of ["run", "compact"]) {
  for (const member of ["episode_id", "owner.id"]) {
    for (const size of [1, 65536]) {
      const value = structuredClone(wire);
      value.owner.kind = kind;
      const bytes = Buffer.alloc(size, 255);
      if (member === "episode_id") value.episode_id = bytes.toString("base64url");
      else value.owner.id = bytes.toString("base64url");
      const decoded = decodeCompactionProgress(value);
      assert.deepEqual(member === "episode_id" ? decoded.episode_id : decoded.owner.id, bytes);
      boundaryChecks++;
    }
    for (const size of [0, 65537]) {
      const value = structuredClone(wire);
      value.owner.kind = kind;
      const bytes = Buffer.alloc(size, 255);
      if (member === "episode_id") value.episode_id = bytes.toString("base64url");
      else value.owner.id = bytes.toString("base64url");
      assert.equal(decodeCompactionProgress(value), null);
      boundaryChecks++;
    }
  }
}

// Concept: inert malformed records must not execute private accessors.
// Technical depth: both the payload and nested owner reject getter/setter,
// nonenumerable and symbol members before delegating owner identity decoding.
for (const member of ["payload", "owner"]) {
  const object = member === "payload" ? wire : wire.owner;
  const wrap = value => member === "payload" ? value : { ...wire, owner: value };
  for (const key of Object.keys(object)) {
    let invoked = 0;
    const getter = { ...object };
    Object.defineProperty(getter, key, { enumerable: true, get() { invoked++; return object[key]; } });
    assert.equal(decodeCompactionProgress(wrap(getter)), null);
    assert.equal(invoked, 0);
    boundaryChecks++;
    const setter = { ...object };
    Object.defineProperty(setter, key, { enumerable: true, set() { invoked++; } });
    assert.equal(decodeCompactionProgress(wrap(setter)), null);
    assert.equal(invoked, 0);
    boundaryChecks++;
    const hidden = { ...object };
    Object.defineProperty(hidden, key, { value: object[key], enumerable: false });
    assert.equal(decodeCompactionProgress(wrap(hidden)), null);
    boundaryChecks++;
  }
  assert.equal(decodeCompactionProgress(wrap(Object.assign(Object.create(null), object))), null);
  boundaryChecks++;
  assert.equal(decodeCompactionProgress(wrap(new Map(Object.entries(object)))), null);
  boundaryChecks++;
  assert.equal(decodeCompactionProgress(wrap(Object.assign(Object.create({ private: true }), object))), null);
  boundaryChecks++;
  assert.equal(decodeCompactionProgress(wrap({ ...object, [Symbol("private")]: "PRIVATE_CANARY" })), null);
  boundaryChecks++;
  assert.notEqual(decodeCompactionProgress(wrap(Object.freeze({ ...object }))), null);
  boundaryChecks++;
}
assert.notEqual(decodeCompactionProgress(Object.freeze({ ...wire, owner: Object.freeze({ ...wire.owner }) })), null);
boundaryChecks++;
assert.equal(boundaryChecks, 51);
process.stdout.write(JSON.stringify({ contract: fixture.contract, checked: fixture.cases.length, boundary_checks: boundaryChecks }) + "\n");
