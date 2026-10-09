// Concept
// Check that both Node connections accept exactly the current durable event,
// snapshot and activity records, independently of the servers' codecs.
//
// Technical depth
// Every retained payload vector is wrapped in a complete event or snapshot
// record and must be admitted exactly when its literal is admitted. Ordinary
// event kinds, run endings, envelopes and unknown kinds use literals below.
// Live server output reaches the same validators through the workflows.
import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import { join } from "node:path";
import { validateEvent, validateProgress, validateSnapshot } from "./public-records.mjs";

const [directory] = process.argv.slice(2);
if (!directory) throw new Error("usage: public-records-tests.mjs <vector-directory>");
const endings = new Map([["answered", "interaction.answered"], ["declined", "interaction.declined"],
  ["expired", "interaction.expired"], ["cancelled", "interaction.cancelled"]]);
const families = [
  ["tool-finished.v1.json", () => "tool.finished"],
  ["model-question-requested.v1.json", () => "interaction.requested"],
  ["model-question-terminal.v1.json", v => endings.get(v.input?.disposition) ?? "interaction.answered"],
  ["policy-requested.v1.json", () => "interaction.requested"],
  ["policy-terminal.v1.json", v => v.event_kind],
  ["policy-answer-admitted.v1.json", () => "interaction.answer_admitted"],
  ["maintenance-view.v1.json", () => "context.maintenance_changed"],
  ["standalone-compact-completion.v1.json", () => "context.compaction_finished"],
  ["checkpoint-projection.v1.json", () => "context.compacted"],
  ["configuration-projection.v1.json", () => "session.configured", v => v.scope === "configured_event"]
];
const envelope = (kind, data, sequence = "7") =>
  ({ type: "event", session_id: "c18x", event: { kind, event_id: "AP8K", event_sequence: sequence, data } });
const admitted = (validate, record) => { try { validate(record); return true; } catch { return false; } };

let events = 0;
for (const [name, kindOf, select = () => true] of families) {
  const fixture = JSON.parse(readFileSync(join(directory, name), "utf8"));
  for (const vector of fixture.cases.filter(select)) {
    // One terminal-only refusal literal is byte-identical to a valid answered
    // policy admission; under that kind it is admitted, as the selector proves.
    const collision = name === "policy-terminal.v1.json" &&
      vector.name === "terminal-kind-interaction.answer_admitted-answered";
    assert.equal(admitted(validateEvent, envelope(kindOf(vector), vector.input)), !vector.error || collision,
      `${name}: ${vector.name}`);
    events++;
  }
}

const id = "AP8K";
const ordinary = [
  ["user.message_appended", { command_id: id, run_id: id, content_b64: "_wAK" }],
  ["user.message_appended", { command_id: id, run_id: id, content_b64: "" }],
  ["run.started", { command_id: id, run_id: id }],
  ["assistant.message_appended", { run_id: id, turn_id: id, content_b64: "_wAK" }],
  ["tool.started", { run_id: id, turn_id: id, tool_call_id: id, operation_id: id, tool_id: "loopex.read", tool_version: "1.2.3" }],
  ["steer.resolved", { command_id: id, run_id: id, disposition: "unapplied", reason: "run_terminal" }],
  ["steer.resolved", { command_id: id, run_id: id, disposition: "applied", reason: null }],
  ["follow_up.resolved", { command_id: id, run_id: id, disposition: "cancelled", reason: "aborted" }],
  ["session.settled", { run_id: id }],
  ["run.finished", { run_id: id, outcome: "completed", reconciliation_ref: null, cleanup_grace_ms: "5000", command_id: id }],
  ["run.finished", { run_id: id, outcome: "outcome_unknown", reconciliation_ref: id, cleanup_grace_ms: "5000", command_id: null }],
  ["run.finished", { run_id: id, outcome: "failed", reconciliation_ref: null, cleanup_grace_ms: "5000", command_id: null, reason: "model_call_failed" }],
  ["run.finished", { run_id: id, outcome: "bound_reached", reconciliation_ref: null, cleanup_grace_ms: "5000", command_id: null,
    bound: "max_turns", observed: "18446744073709551616", declared_limit: "3", accounting_source: null }]
];
for (const [kind, data] of ordinary) {
  assert.ok(admitted(validateEvent, envelope(kind, data)), kind);
  for (const key of Object.keys(data)) {
    const missing = { ...data };
    delete missing[key];
    assert.ok(!admitted(validateEvent, envelope(kind, missing)), `${kind} without ${key}`);
  }
  assert.ok(!admitted(validateEvent, envelope(kind, { ...data, private: "PRIVATE_CANARY" })), `${kind} private`);
  events += 2 + Object.keys(data).length;
}
const refused = [
  envelope("run.progressed", { run_id: id }),
  envelope("session.settled", { run_id: "AP8K=" }),
  envelope("session.settled", { run_id: "AB" }),
  envelope("session.settled", { run_id: id }, "18446744073709551616"),
  envelope("session.settled", { run_id: id }, "07"),
  envelope("session.settled", { run_id: id }, 7),
  envelope("tool.started", { ...ordinary[4][1], tool_version: "1.0.0-private" }),
  envelope("steer.resolved", { ...ordinary[5][1], disposition: "private" }),
  envelope("follow_up.resolved", { ...ordinary[7][1], reason: "private" }),
  envelope("run.finished", { ...ordinary[9][1], reconciliation_ref: id }),
  envelope("run.finished", { ...ordinary[11][1], reason: "PRIVATE_REASON" }),
  { ...envelope("session.settled", { run_id: id }), request_id: "c1" },
  { ...envelope("session.settled", { run_id: id }), event: { ...envelope("session.settled", { run_id: id }).event, private: 1 } }
];
for (const record of refused) { assert.ok(!admitted(validateEvent, record), JSON.stringify(record)); events++; }

let snapshots = 0;
for (const vector of JSON.parse(readFileSync(join(directory, "session-snapshot.v3.json"), "utf8")).cases) {
  const snapshot = vector.input;
  const record = { type: "snapshot", request_id: "c1", session_id: snapshot?.session_id,
    event_cursor: snapshot?.event_sequence, snapshot, open_interaction: snapshot?.open_interaction ?? null };
  assert.equal(admitted(validateSnapshot, record), !vector.error, `snapshot: ${vector.name}`);
  snapshots++;
  if (!vector.error) {
    assert.ok(!admitted(validateSnapshot, { ...record, event_cursor: `${BigInt(record.event_cursor) + 1n}` }));
    assert.ok(!admitted(validateSnapshot, { ...record, session_id: "AP8K" }));
    assert.ok(!admitted(validateSnapshot, { ...record, private: true }));
    snapshots += 3;
  }
}

let progress = 0;
for (const vector of JSON.parse(readFileSync(join(directory, "compaction-progress.v1.json"), "utf8")).cases) {
  assert.equal(admitted(validateProgress, { type: "progress", session_id: "c18x", progress: vector.input }), !vector.error, vector.name);
  progress++;
}

const streamDomain = Buffer.from("0123456789abcdef0123456789abcdef").toString("base64url");
const streamBase = { turn_id: id, stream_domain_id: streamDomain, base_event_sequence: "18446744073709551615" };
const items = [
  { kind: "text_delta", ...streamBase, model_sequence: "0", content_index: 0, text: "é" },
  { kind: "reasoning_delta", ...streamBase, model_sequence: "1", content_index: 9007199254740991, text: "" },
  { kind: "tool_call_delta", ...streamBase, model_sequence: "2", call_index: 0, tool_call_id: null, name: null, arguments_fragment: "{" },
  { kind: "tool_progress", ...streamBase, tool_call_id: id, progress_sequence: "0", stream: "stdout", byte_offset: "0", chunk_b64: "_wAK" },
  { kind: "model_stream_closed", ...streamBase, disposition: "complete", delta_count: "3" },
  { kind: "tool_stream_closed", ...streamBase, tool_call_id: id, disposition: "abandoned", progress_count: "0" }
];
for (const item of items) {
  const record = { type: "progress", session_id: "c18x", progress: item };
  assert.ok(admitted(validateProgress, record), item.kind);
  for (const [key, value] of [["private", "PRIVATE_CANARY"], ["base_event_sequence", 1], ["turn_id", "AB"],
    ["stream_domain_id", Buffer.from("0123456789ABCDEF0123456789abcdef").toString("base64url")]]) {
    assert.ok(!admitted(validateProgress, { ...record, progress: { ...item, [key]: value } }), `${item.kind} ${key}`);
  }
  progress += 5;
}
assert.ok(!admitted(validateProgress, { type: "progress", session_id: "c18x", progress: { ...items[0], text: "\u001b[2J" } }));
assert.ok(!admitted(validateProgress, { type: "progress", session_id: "c18x", progress: { ...items[0], content_index: 2 ** 53 } }));
progress += 2;

process.stdout.write(JSON.stringify({ events, snapshots, progress }) + "\n");
