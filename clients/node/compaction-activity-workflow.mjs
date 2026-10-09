// Concept
//
// An independent client asks either server to compact a session with real
// history and observes the compaction's activity on its own connection: one
// closed item naming the compact owner and the episode the completion names.
//
// Technical depth
//
// Usage:
//   node compaction-activity-workflow.mjs --daemon <socket-path>
//   node compaction-activity-workflow.mjs <elixir-executable> <path>...
//
// The second form launches the foreground server as workflow.mjs does. Every
// record crosses the connection's shared closed validator before it is kept.
// Durable output may precede queued transient items, so the activity is awaited
// by kind after the completion within this client's own patience. The summary
// line names only public values. Any refusal ends non-zero.

import { Connection, wire } from "./loopex-client.mjs";
import { DaemonConnection } from "./daemon-client.mjs";
import { decodeCompactionProgress } from "./compaction-progress.mjs";
import { decodeCompactCompletion } from "./compact-result.mjs";

const [target, ...rest] = process.argv.slice(2);
if (!target || (target === "--daemon" ? rest.length !== 1 : rest.length === 0)) {
  process.stderr.write("usage: node compaction-activity-workflow.mjs (--daemon <socket> | <elixir> <path>...)\n");
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

const prompted = await connection.request("session.prompt", {
  command_id: wire.identity("node-history"), content_b64: wire.bytes("old ".repeat(2000)), ...epoch,
});
if (prompted.status !== "accepted") fail("prompt", prompted);
await connection.waitForEvent((event) => event.kind === "run.finished");

const compacted = await connection.request("session.compact", {
  command_id: wire.identity("node-compact"),
  bounds: { max_attempts: "4", deadline_ms: "60000", token_budget: "32768" },
  ...epoch,
});
if (compacted.status !== "accepted") fail("compact", compacted);
const finished = await connection.waitForEvent((event) => event.kind === "context.compaction_finished");
const completion = decodeCompactCompletion(finished.data);
if (completion === null) fail("compaction_finished", finished);

const deadline = Date.now() + 10_000;
let items = [];
while ((items = connection.progress().filter((item) => item.kind === "context.compaction_progress")).length === 0) {
  if (Date.now() > deadline) fail("activity", connection.progress());
  await new Promise((resolve) => setTimeout(resolve, 10));
}
const activity = decodeCompactionProgress(items[0]);
if (activity === null) fail("activity", items[0]);

process.stdout.write(JSON.stringify({
  activities: items.length,
  owner: { kind: activity.owner.kind, id: activity.owner.id.toString("utf8") },
  same_episode: activity.episode_id.equals(completion.episode_id),
  disposition: finished.data.result.disposition,
}) + "\n");
connection.close();
if (!daemon) await connection.ended();

function foreground(elixir, paths) {
  const args = [];
  for (const path of paths) args.push(...(path.endsWith(".exs") ? ["-r", path] : ["-pa", path]));
  args.push("-e", process.env.LOOPEX_WORKFLOW_ENTRY || "Loopex.AppServer.Fixture.serve()");
  return new Connection(elixir, args);
}
