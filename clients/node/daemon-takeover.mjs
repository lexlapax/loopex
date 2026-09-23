// Concept
//
// The cross-process takeover an operator relies on: this client observes a
// session another client controls, and when that controller is gone it waits
// for the lease to lapse, takes control with a fresh epoch, and aborts the work
// still running. It never forces a live holder off.
//
// Technical depth
//
// Usage: node daemon-takeover.mjs <socket-path> <session-id> [--prompt <text>]
//
// It attaches as an observer from sequence 0 and prints
// `{"attached":true}` once attached, so a harness knows when to remove the
// controller. It then asks for control once a second; `control_held` and
// `control_pending` mean the earlier lease is still live and are retried until
// the fixed patience below. With the granted epoch it sends `session.abort`
// under a fresh command identity, waits for the run's durable
// `run.finished`, releases control and prints one summary line:
// `{"granted":true,"abort":"<status>","finished":<bool>,"attempts":<n>}`.
// With `--prompt`, it instead waits for the killed controller's run to
// finish, sends `session.prompt` with that text under the granted epoch, waits
// for the new run's `run.finished` and prints
// `{"granted":true,"prompt":"<status>","answered":<bool>,"finished":<bool>,"attempts":<n>}`,
// where `answered` means an assistant message followed the admission.
// Any refusal ends the process non-zero with the refusal on standard error.

import { randomBytes } from "node:crypto";
import { DaemonConnection, wire } from "./daemon-client.mjs";

const [socketPath, sessionId, flag, promptText] = process.argv.slice(2);
const promptMode = flag === "--prompt";
const takeoverPatienceMs = 90_000;

if (!socketPath || !sessionId || (flag !== undefined && !(promptMode && promptText))) {
  process.stderr.write(
    "usage: node daemon-takeover.mjs <socket-path> <session-id> [--prompt <text>]\n",
  );
  process.exit(2);
}

const connection = await DaemonConnection.open(socketPath);
await connection.initialize();

const session = wire.identity(sessionId);
const attached = await connection.request("session.attach", {
  session_id: session,
  after_event_sequence: wire.u64(0),
});

if (attached.type !== "snapshot") fail("attach", attached);
process.stdout.write(JSON.stringify({ attached: true }) + "\n");

const started = Date.now();
let attempts = 0;
let epoch = null;

while (epoch === null) {
  attempts += 1;
  const reply = await connection.request("session.acquire_control", { session_id: session });

  if (reply.type === "result") {
    epoch = reply.result.writer_epoch;
  } else if (["control_held", "control_pending"].includes(reply.code)) {
    if (Date.now() - started > takeoverPatienceMs) fail("take over", reply);
    await new Promise((resolve) => setTimeout(resolve, 1_000));
  } else {
    fail("take over", reply);
  }
}

if (promptMode) {
  await connection.waitForEvent((event) => event.kind === "run.finished", 120_000);
  const mark = lastSequence(connection.events());

  const prompt = await connection.request("session.prompt", {
    command_id: wire.identity(`node-prompt-${randomBytes(8).toString("hex")}`),
    content_b64: wire.bytes(promptText),
    writer_epoch: epoch,
  });

  if (prompt.type !== "admission" || prompt.status !== "accepted") fail("prompt", prompt);
  const after = (kind) => (event) => event.kind === kind && BigInt(event.event_sequence) > mark;

  const finished = await connection
    .waitForEvent(after("run.finished"), 120_000)
    .then(() => true, () => false);

  const answered = connection.events().some(after("assistant.message_appended"));
  await connection.request("session.release_control", { session_id: session, writer_epoch: epoch });
  connection.close();

  process.stdout.write(
    JSON.stringify({ granted: true, prompt: prompt.status, answered, finished, attempts }) + "\n",
  );

  process.exit(0);
}

const abort = await connection.request("session.abort", {
  command_id: wire.identity(`node-abort-${randomBytes(8).toString("hex")}`),
  writer_epoch: epoch,
});

if (abort.type !== "admission") fail("abort", abort);

const finished = await connection
  .waitForEvent((event) => event.kind === "run.finished", 60_000)
  .then(() => true, () => false);

await connection.request("session.release_control", { session_id: session, writer_epoch: epoch });
connection.close();

process.stdout.write(
  JSON.stringify({ granted: true, abort: abort.status, finished, attempts }) + "\n",
);

function lastSequence(events) {
  return events.reduce((max, event) => {
    const sequence = BigInt(event.event_sequence);
    return sequence > max ? sequence : max;
  }, 0n);
}

function fail(step, record) {
  process.stderr.write(`${step} refused: ${record.code ?? record.reason ?? record.type}\n`);
  process.exit(1);
}
