// Concept
//
// An independent client configures and compacts its session through either
// server: an authored model alias is resolved once by the runtime, the public
// configuration change and compaction completion are decoded by this client's
// own readers, and exact retries return the historical admissions. Over the
// daemon a stale controller epoch is refused first.
//
// Technical depth
//
// Usage:
//   node maintenance-workflow.mjs <model-alias> --daemon <socket-path>
//   node maintenance-workflow.mjs <model-alias> <elixir-executable> <path>...
//
// The second form launches the foreground server exactly as workflow.mjs does.
// Every record also crosses the connection's shared closed validator. The
// summary line names only public values. Any refusal ends non-zero.

import { isDeepStrictEqual } from "node:util";
import { Connection, wire } from "./loopex-client.mjs";
import { DaemonConnection } from "./daemon-client.mjs";
import { decodeConfiguredEvent } from "./configuration.mjs";
import { decodeCompactCompletion } from "./compact-result.mjs";

const [alias, target, ...rest] = process.argv.slice(2);
if (!alias || !target || (target === "--daemon" ? rest.length !== 1 : rest.length === 0)) {
  process.stderr.write("usage: node maintenance-workflow.mjs <model-alias> (--daemon <socket> | <elixir> <path>...)\n");
  process.exit(2);
}
const fail = (step, reply) => {
  process.stderr.write(`${step}: ${JSON.stringify(reply)}\n`);
  process.exit(1);
};

const daemon = target === "--daemon";
const connection = daemon ? await DaemonConnection.open(rest[0]) : foreground(target, rest);
await connection.initialize();

const created = await connection.request("session.create", {
  command_id: wire.identity("node-create"), session_options: { version: 1 },
});
if (created.status !== "accepted") fail("create", created);
const session = created.session_id;
let epoch = {};
if (daemon) {
  const control = await connection.request("session.acquire_control", { session_id: session });
  if (!control.result?.writer_epoch) fail("acquire", control);
  epoch = { writer_epoch: control.result.writer_epoch };
}
const attached = await connection.request("session.attach", { session_id: session, after_event_sequence: wire.u64(0) });
if (attached.type !== "snapshot") fail("attach", attached);

const configure = { command_id: wire.identity("node-configure"), changes: { model: alias, max_tokens: "512" }, ...epoch };
let stale = null;
if (daemon) {
  const refused = await connection.request("session.configure", { ...configure, writer_epoch: wire.identity("stale") });
  if (refused.type !== "error" || refused.code !== "control_not_held") fail("stale", refused);
  stale = refused.code;
}

const configured = await connection.request("session.configure", configure);
if (configured.status !== "accepted") fail("configure", configured);
const change = await connection.waitForEvent((event) => event.kind === "session.configured");
const decoded = decodeConfiguredEvent(change.data);
if (decoded === null || !decoded.command_id.equals(Buffer.from("node-configure"))) fail("configured", change);
const configureRetry = await connection.request("session.configure", configure);

const compact = {
  command_id: wire.identity("node-compact"),
  bounds: { max_attempts: "4", deadline_ms: "60000", token_budget: "32768" },
  ...epoch,
};
const compacted = await connection.request("session.compact", compact);
if (compacted.status !== "accepted") fail("compact", compacted);
const finished = await connection.waitForEvent((event) => event.kind === "context.compaction_finished");
if (decodeCompactCompletion(finished.data) === null) fail("compaction_finished", finished);
const compactRetry = await connection.request("session.compact", compact);
const same = (left, right) => isDeepStrictEqual({ ...left, request_id: null }, { ...right, request_id: null });

process.stdout.write(JSON.stringify({
  stale,
  model: decoded.configuration.model,
  max_tokens: decoded.configuration.max_tokens.toString(),
  configure_retry_matches: same(configured, configureRetry),
  disposition: finished.data.result.disposition,
  compact_retry_matches: same(compacted, compactRetry),
  configured_events: connection.events().filter((event) => event.kind === "session.configured").length,
}) + "\n");
connection.close();
if (!daemon) await connection.ended();

function foreground(elixir, paths) {
  const args = [];
  for (const path of paths) args.push(...(path.endsWith(".exs") ? ["-r", path] : ["-pa", path]));
  args.push("-e", process.env.LOOPEX_WORKFLOW_ENTRY || "Loopex.AppServer.Fixture.serve()");
  return new Connection(elixir, args);
}
