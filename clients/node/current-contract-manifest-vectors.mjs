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

// Concept: admitted opening cleanup is a closed six-field variant; ordinary
// read/close/pre-admission refusals retain a separate five-field form.
// Technical depth: fixed independent literals below do not derive expectations
// from the server, manifest or vector. A declared admitted disposition with a
// missing cleanup is refused even if its reason also names a pre-admission case.
const admittedOpenReasons = ["invalid_artifact_request", "invalid_open_context", "reservation_required", "reservation_conflict", "unknown_artifact_use", "artifact_use_mismatch", "artifact_integrity_failed", "artifact_digest_mismatch", "unknown_artifact", "artifact_too_large", "invalid_window", "open_deadline_exhausted", "open_work_budget_exhausted", "transfer_limit_reached", "transfers_unavailable", "artifact_unreadable", "cancelled"];
const ordinaryReasons = {"open_preadmission": ["attachment_required", "invalid_attachment", "stale_attachment", "invalid_artifact_request", "artifact_transfer_unsupported", "transfer_limit_reached", "open_work_budget_exhausted", "transfers_unavailable"], "read": ["attachment_required", "invalid_attachment", "stale_attachment", "unknown_transfer", "invalid_chunk_length", "open_work_budget_exhausted", "transfers_unavailable", "read_deadline_exhausted", "artifact_unreadable", "runtime_unavailable"], "close": ["attachment_required", "invalid_attachment", "stale_attachment", "unknown_transfer", "cleanup_unproved"]};
const requiredAdmitted = ["type", "request_id", "code", "message", "reason", "cleanup"];
const requiredOrdinary = requiredAdmitted.filter(key => key !== "cleanup");
function decodeArtifactRefusal(value, scope) {
  const admitted = scope === "open_admitted";
  const reasons = admitted ? admittedOpenReasons : ordinaryReasons[scope];
  const keys = admitted ? requiredAdmitted : requiredOrdinary;
  if (!reasons || value === null || typeof value !== "object" ||
      Object.getPrototypeOf(value) !== Object.prototype ||
      Object.keys(value).length !== keys.length || keys.some(key => !Object.hasOwn(value, key)) ||
      value.type !== "error" || value.code !== "transfer_refused" ||
      typeof value.request_id !== "string" || !/^[A-Za-z0-9._~-]{1,64}$/.test(value.request_id) ||
      typeof value.message !== "string" || !value.message.isWellFormed() ||
      Buffer.byteLength(value.message, "utf8") > 131072 || !reasons.includes(value.reason) ||
      (admitted && !["proved", "unproved"].includes(value.cleanup))) return null;
  return value;
}

const [path] = process.argv.slice(2);
if (!path) throw new Error("usage: current-contract-manifest-vectors.mjs <vectors>");
const fixture = parseSchemaJson(readFileSync(path));
assert.equal(fixture.format, "loopex.experimental.current-contract-manifests.v1");
assert.equal(fixture.canonicalization_revision, "loopex.canonical.v1");
assert.equal(fixture.manifests.length, 2);
let changes = 0;
let artifactRefusalVectors = 0;
let artifactRefusalPositive = 0;
let artifactRefusalNegative = 0;
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
  const error = manifest.payload_definitions.records.error;
  assert.deepEqual(error.transfer_refused_admitted_open, {
    required: requiredAdmitted, code: "transfer_refused", reason_enum: admittedOpenReasons,
    cleanup_enum: ["proved", "unproved"], closed: true,
  });
  assert.deepEqual(error.transfer_refused_without_cleanup, {
    required: requiredOrdinary, code: "transfer_refused", reason_enum_by_operation: ordinaryReasons,
    cleanup: "absent", closed: true,
  });
  assert.equal(error.transfer_refused_forms_are_mutually_exclusive, true);
  assert.equal(error.transfer_refused_reason_enum_scope, "without_cleanup_only");
  assert.deepEqual(error.transfer_refused_reason_enum, [...new Set(Object.values(ordinaryReasons).flat())]);
  const payloadLimits = manifest.payload_definitions.payload_limits;
  assert.equal(payloadLimits.artifact_open_storage_work_bytes, 134217728);
  assert.equal(payloadLimits.artifact_open_metadata_read_bytes, 131073);
  assert.equal(payloadLimits.artifact_cleanup_observation_ms, 5000);
  for (const key of ["artifact_open_metadata_read_bytes", "artifact_cleanup_observation_ms"]) {
    const original = payloadLimits[key];
    payloadLimits[key]++;
    assert.notEqual(canonicalSchemaDigest(manifest), vector.sha256, key);
    payloadLimits[key] = original;
  }
  const wire = JSON.parse(readFileSync(resolve(dirname(path), `loopex-experimental-${index + 3}.json`), "utf8"));
  const refusalCases = wire.cases.filter(value => Object.hasOwn(value, "artifact_refusal_scope"));
  assert.equal(refusalCases.length, 108);
  const admittedCases = refusalCases.filter(value => value.artifact_refusal_scope === "open_admitted" && value.artifact_refusal_valid);
  assert.equal(admittedCases.length, 34);
  for (const reason of admittedOpenReasons) {
    for (const cleanup of ["proved", "unproved"]) {
      const selected = admittedCases.filter(value => {
        const record = parseSchemaJson(Buffer.from(value.raw_hex, "hex"));
        return record.reason === reason && record.cleanup === cleanup;
      });
      assert.equal(selected.length, 1, `${reason}: ${cleanup}`);
    }
  }
  for (const [scope, reasons] of Object.entries(ordinaryReasons)) {
    for (const reason of reasons) {
      const selected = refusalCases.filter(value => {
        const record = parseSchemaJson(Buffer.from(value.raw_hex, "hex"));
        return value.artifact_refusal_scope === scope && value.artifact_refusal_valid && record.reason === reason;
      });
      assert.equal(selected.length, 1, `${scope}: ${reason}`);
    }
  }
  for (const value of refusalCases) {
    const bytes = Buffer.from(value.raw_hex, "hex");
    assert.equal(bytes[bytes.length - 1], 10);
    const record = parseSchemaJson(bytes);
    assert.equal(decodeArtifactRefusal(record, value.artifact_refusal_scope) !== null, value.artifact_refusal_valid, value.id);
    artifactRefusalVectors++;
    if (value.artifact_refusal_valid) artifactRefusalPositive++;
    else artifactRefusalNegative++;
  }
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
    let expected = vector.error ? null : vector.decoded;
    if (name === "question-answer.v1.json" && !vector.error) {
      // The accepted answer vectors retain text choices as UTF-8 and binary
      // choices separately as hex. Compare both against exact opaque bytes.
      if (vector.decoded_choice_hex !== undefined) {
        expected = { choice_id: { opaque_hex: vector.decoded_choice_hex } };
      } else if (vector.decoded.choice_id !== undefined) {
        expected = { choice_id: { opaque_hex: Buffer.from(vector.decoded.choice_id, "utf8").toString("hex") } };
      }
    }
    assert.deepEqual(retained(decode(vector)), expected, `${name}: ${vector.name}`);
    payloadVectors++;
  }
}
process.stdout.write(JSON.stringify({ manifests: 2, payload_vectors: payloadVectors, embedded_definition_changes: changes, artifact_refusal_vectors: artifactRefusalVectors, artifact_refusal_positive: artifactRefusalPositive, artifact_refusal_negative: artifactRefusalNegative }) + "\n");
