// Concept
// Independently bind both current complete contracts before session traffic.
// Technical depth
// Compare literal canonical preimages, digest pins and ordered inventories. Run
// the existing approved positive and negative payload vectors through independent
// decoders. These source conformance checks do not prove native server lifecycle.
import assert from "node:assert/strict";
import { createHash } from "node:crypto";
import { readFileSync } from "node:fs";
import { dirname, resolve } from "node:path";
import { canonicalSchemaBytes, canonicalSchemaDigest, parseSchemaJson, CURRENT_CONTRACTS, parseContractManifest } from "./contract-manifest.mjs";
import { decodeConfigureRequest, decodeCreationOptions } from "./configure-request.mjs";
import { decodeQuestionAnswer } from "./question-answer.mjs";
import { decodeCommandBounds } from "./command-bounds.mjs";
import { decodeActiveBounds } from "./active-bounds.mjs";
import { decodeSnapshot } from "./snapshot.mjs";
import { decodeInspection } from "./inspection.mjs";
import { decodeConfiguration, decodeConfiguredEvent } from "./configuration.mjs";
import { decodeCheckpoint } from "./checkpoint.mjs";
import { decodeCheckpointOwner } from "./checkpoint-owner.mjs";
import { decodeMaintenanceView } from "./maintenance-view.mjs";
import { decodeCompactResult, decodeCompactCompletion } from "./compact-result.mjs";
import { decodeCompactionProgress } from "./compaction-progress.mjs";
import { decodeOpenInteraction, decodeAnswerAdmitted } from "./open-interaction.mjs";
import { decodeModelQuestionRequested, decodeModelQuestionTerminal } from "./model-question-event.mjs";
import { decodePolicyRequested, decodePolicyTerminal } from "./policy-interaction-event.mjs";
import { decodeCreationCancellation } from "./creation-cancellation.mjs";
import { decodeTerminalOutcome } from "./terminal-outcome.mjs";

const [path] = process.argv.slice(2);
if (!path) throw new Error("usage: current-contract-manifest-vectors.mjs <vectors>");
const fixture = parseSchemaJson(readFileSync(path));
assert.equal(fixture.format, "loopex.experimental.current-contract-manifests.v1");
assert.equal(fixture.canonicalization_revision, "loopex.canonical.v1");
assert.equal(fixture.manifests.length, 2);
let changes = 0;
for (const [index, vector] of fixture.manifests.entries()) {
  const bytes = readFileSync(resolve(dirname(path), "../schema", vector.schema));
  assert.equal(createHash("sha256").update(bytes).digest("hex"), vector.schema_file_sha256);
  const manifest = parseContractManifest(bytes);
  assert.equal(manifest.generation, vector.generation);
  assert.deepEqual(manifest.methods, vector.methods);
  assert.deepEqual(manifest.record_families, vector.record_families);
  assert.deepEqual(manifest.error_codes, vector.error_codes);
  assert.equal(canonicalSchemaBytes(manifest).toString("hex"), vector.canonical_hex);
  assert.equal(canonicalSchemaBytes(manifest).length, vector.canonical_bytes);
  assert.equal(canonicalSchemaDigest(manifest), vector.sha256);
  const pin = CURRENT_CONTRACTS[index === 0 ? "foreground" : "daemon"];
  assert.equal(pin.generation, vector.generation);
  assert.equal(pin.schemaDigest, vector.sha256);
  const nested = manifest.payload_definitions.nested;
  assert.equal(nested.session_snapshot.snapshot_revision, 3);
  assert.equal(nested.session_snapshot.required.length, 10);
  assert.equal(nested.inspection.required.length, 11);
  assert.deepEqual(nested.compaction_progress.owner, nested.checkpoint_owner);
  for (const key of Object.keys(nested)) {
    const retained = nested[key];
    delete nested[key];
    assert.notEqual(canonicalSchemaDigest(manifest), vector.sha256, key);
    nested[key] = retained;
    changes++;
  }
  assert.equal(canonicalSchemaDigest(manifest), vector.sha256);
  assert.throws(() => parseContractManifest(Buffer.from(JSON.stringify({ ...manifest, unknown: true }))));
  assert.throws(() => parseContractManifest(Buffer.from(JSON.stringify({ ...manifest, canonicalization_revision: "unknown" }))));
  assert.throws(() => parseContractManifest(Buffer.from(JSON.stringify({ ...manifest, payload_definitions: {} }))));
  const duplicate = bytes.toString("utf8").replace("{", '{"generation":"loopex.experimental/3",');
  assert.throws(() => parseContractManifest(Buffer.from(duplicate)), /duplicate/);
}

function retained(value) {
  if (typeof value === "bigint") return value.toString();
  if (Buffer.isBuffer(value)) return { opaque_hex: value.toString("hex") };
  if (Array.isArray(value)) return value.map(retained);
  if (value !== null && typeof value === "object") return Object.fromEntries(Object.entries(value).map(([key, member]) => [key, retained(member)]));
  return value;
}
const decoders = {
  "configure-request.v1.json": v => decodeConfigureRequest(v.input, v.transport),
  "creation-options.v1.json": v => decodeCreationOptions(v.input),
  "question-answer.v1.json": v => decodeQuestionAnswer(v.input),
  "command-bounds.v1.json": v => decodeCommandBounds(v.input, v.kind),
  "active-bounds.v1.json": v => decodeActiveBounds(v.input),
  "session-snapshot.v3.json": v => decodeSnapshot(v.input),
  "inspection.v1.json": v => decodeInspection(v.input),
  "configuration-projection.v1.json": v => v.scope === "configured_event" ? decodeConfiguredEvent(v.input) : decodeConfiguration(v.input),
  "checkpoint-projection.v1.json": v => decodeCheckpoint(v.input),
  "checkpoint-owner.v1.json": v => decodeCheckpointOwner(v.input),
  "maintenance-view.v1.json": v => decodeMaintenanceView(v.input),
  "standalone-compact-result.v1.json": v => decodeCompactResult(v.input),
  "standalone-compact-completion.v1.json": v => decodeCompactCompletion(v.input),
  "compaction-progress.v1.json": v => decodeCompactionProgress(v.input),
  "open-interaction.v1.json": v => decodeOpenInteraction(v.input),
  "policy-answer-admitted.v1.json": v => decodeAnswerAdmitted(v.input),
  "model-question-requested.v1.json": v => decodeModelQuestionRequested(v.input),
  "model-question-terminal.v1.json": v => decodeModelQuestionTerminal(v.input),
  "policy-requested.v1.json": v => decodePolicyRequested(v.input),
  "policy-terminal.v1.json": v => decodePolicyTerminal(v.event_kind, v.input),
  "creation-cancelled-admission.v1.json": v => decodeCreationCancellation(v.input),
  "chat-terminal-outcome.v1.json": v => decodeTerminalOutcome(v.input),
  "chat-terminal-context-failure.v2.json": v => decodeTerminalOutcome(v.input),
};
let payloadVectors = 0;
for (const [name, decode] of Object.entries(decoders)) {
  // Negative payload literals deliberately include fractions and malformed
  // scalar strings. They are test inputs, not canonical schema data.
  const payload = JSON.parse(readFileSync(resolve(dirname(path), name), "utf8"));
  for (const vector of payload.cases) {
    assert.deepEqual(retained(decode(vector)), vector.error ? null : vector.decoded, `${name}: ${vector.name}`);
    payloadVectors++;
  }
}
process.stdout.write(JSON.stringify({ manifests: 2, payload_vectors: payloadVectors, embedded_definition_changes: changes }) + "\n");
