// Concept
//
// An independent controller configures and compacts its session through the
// daemon socket: a stale epoch is refused, an authored model alias is resolved
// once by the runtime, the public configuration change is decoded by this
// client's own reader, and exact retries return the historical admissions.
//
// Technical depth
//
// Usage: node daemon-maintenance-workflow.mjs <socket-path> <model-alias>
//
// Every record also crosses the connection's shared closed validator. The
// summary line names only public values: the canonical model and max-token
// quantity from `session.configured`, the compaction disposition and whether
// each retry matched its original admission. Any refusal ends non-zero.

import { isDeepStrictEqual } from "node:util";
import { DaemonConnection, wire } from "./daemon-client.mjs";
import { decodeConfiguredEvent } from "./configuration.mjs";
import { decodeCompactCompletion } from "./compact-result.mjs";

const [socketPath, alias] = process.argv.slice(2);
if (!socketPath || !alias) {
  process.stderr.write("usage: node daemon-maintenance-workflow.mjs <socket-path> <model-alias>\n");
  process.exit(2);
}
const fail = (step, reply) => {
  process.stderr.write(`${step}: ${JSON.stringify(reply)}\n`);
  process.exit(1);
};

const connection = await DaemonConnection.open(socketPath);
await connection.initialize();

const created = await connection.request("session.create", {
  command_id: wire.identity("node-create"), session_options: { version: 1 },
});
if (created.status !== "accepted") fail("create", created);
const session = created.session_id;
const control = await connection.request("session.acquire_control", { session_id: session });
const epoch = control.result?.writer_epoch;
if (!epoch) fail("acquire", control);
const attached = await connection.request("session.attach", { session_id: session, after_event_sequence: wire.u64(0) });
if (attached.type !== "snapshot") fail("attach", attached);

const configure = {
  command_id: wire.identity("node-configure"),
  changes: { model: alias, max_tokens: "512" },
  writer_epoch: epoch,
};
const stale = await connection.request("session.configure", { ...configure, writer_epoch: wire.identity("stale") });
if (stale.type !== "error" || stale.code !== "control_not_held") fail("stale", stale);

const configured = await connection.request("session.configure", configure);
if (configured.status !== "accepted") fail("configure", configured);
const change = await connection.waitForEvent((event) => event.kind === "session.configured");
const decoded = decodeConfiguredEvent(change.data);
if (decoded === null || !decoded.command_id.equals(Buffer.from("node-configure"))) fail("configured", change);
const configureRetry = await connection.request("session.configure", configure);

const compact = {
  command_id: wire.identity("node-compact"),
  bounds: { max_attempts: "4", deadline_ms: "60000", token_budget: "32768" },
  writer_epoch: epoch,
};
const compacted = await connection.request("session.compact", compact);
if (compacted.status !== "accepted") fail("compact", compacted);
const finished = await connection.waitForEvent((event) => event.kind === "context.compaction_finished");
if (decodeCompactCompletion(finished.data) === null) fail("compaction_finished", finished);
const compactRetry = await connection.request("session.compact", compact);
const same = (left, right) => isDeepStrictEqual({ ...left, request_id: null }, { ...right, request_id: null });

process.stdout.write(JSON.stringify({
  stale: stale.code,
  model: decoded.configuration.model,
  max_tokens: decoded.configuration.max_tokens.toString(),
  configure_retry_matches: same(configured, configureRetry),
  disposition: finished.data.result.disposition,
  compact_retry_matches: same(compacted, compactRetry),
  configured_events: connection.events().filter((event) => event.kind === "session.configured").length,
}) + "\n");
connection.close();
