// Concept
//
// The chain outcome 5 names, driven from outside: the client submits a task,
// the host policy asks a question rather than allowing, the client presents
// that question and answers it, the policy is asked again and mints the
// authorization, the tool runs, and the client reads back what it produced.
//
// Technical depth
//
// Every step crosses the wire. The client never reaches inside the runtime and
// never decides anything: it presents the exact pending question it was given
// and sends back one of the choice identities that question offered. The allow
// is the host's, minted after the answer committed, which is the property this
// workflow exists to show. A client that could allow its own tool call would
// make the whole interaction ceremony pointless.
//
// It prints one JSON summary on standard output so the Elixir case that runs it
// can assert what the client observed rather than what the server logged.
//
// Usage: node interaction-workflow.mjs <elixir-executable> <path>...

import { Connection, wire } from "./loopex-client.mjs";

const [elixir, ...paths] = process.argv.slice(2);

if (!elixir || paths.length === 0) {
  console.error("usage: node interaction-workflow.mjs <elixir-executable> <path>...");
  process.exit(2);
}

const serverArgs = [];
for (const path of paths) {
  if (path.endsWith(".exs")) serverArgs.push("-r", path);
  else serverArgs.push("-pa", path);
}
serverArgs.push("-e", "Loopex.AppServer.Fixture.serve()");

const connection = new Connection(elixir, serverArgs, {
  env: { ...process.env, LOOPEX_WORKFLOW_SCRIPT: "tool" },
});

try {
  const summary = await run(connection);
  process.stdout.write(JSON.stringify(summary) + "\n");
  connection.close();
  process.exit(0);
} catch (failure) {
  process.stdout.write(JSON.stringify({ failed: String(failure.message ?? failure) }) + "\n");
  connection.close();
  process.exit(1);
}

async function run(connection) {
  await connection.initialize();

  const created = await connection.request("session.create", {
    command_id: wire.identity("chain-create"),
  });

  assert(created.status === "accepted", `creation was ${created.status}`);
  const sessionId = created.session_id;

  const attached = await connection.request("session.attach", {
    session_id: sessionId,
    after_event_sequence: wire.u64(0),
  });

  assert(attached.type === "snapshot", `expected a snapshot, received ${attached.type}`);

  const prompted = await connection.request("session.prompt", {
    command_id: wire.identity("chain-prompt"),
    content_b64: wire.bytes("write the output file"),
  });

  assert(prompted.status === "accepted", `the prompt was ${prompted.status}: ${prompted.reason}`);

  // The policy asks rather than allowing, and the question arrives as a durable
  // event like any other.
  const requested = await connection.waitForEvent((event) => event.kind === "interaction.requested");
  const question = requested.data;

  const summary = {
    session_created: true,
    question_prompt: question.prompt,
    choice_ids: (question.choices ?? []).map((choice) => choice.id),
    interaction_id: question.interaction_id,
  };

  // The client answers with one of the identities the question offered, and
  // nothing else. It does not decide; it relays.
  const answered = await connection.request("session.respond_interaction", {
    command_id: wire.identity("chain-answer"),
    interaction_id: wire.identity(question.interaction_id),
    answer: { choice_id: wire.identity("allow") },
  });

  assert(
    answered.status === "accepted",
    `the answer was ${answered.status}: ${answered.reason ?? "no reason"}`,
  );

  summary.answer_accepted = true;

  const resolved = await connection.waitForEvent((event) => event.kind === "interaction.resolved");
  summary.resolution = resolved.data.status ?? resolved.data.resolution ?? null;

  // The policy was asked again after the answer committed, and only then did
  // the tool run.
  const finished = await connection.waitForEvent((event) => event.kind === "tool.finished", 20_000);
  summary.tool_finished = true;
  summary.artifacts = (finished.data.artifacts ?? []).length;

  const [artifact] = finished.data.artifacts ?? [];

  if (artifact) {
    const opened = await connection.request("artifact.open_transfer", {
      use_ref: wire.reference(artifact),
      start_offset: wire.u64(0),
    });

    if (opened.type === "result") {
      summary.transfer_opened = true;
      summary.total_size = opened.result.total_size;

      const chunk = await connection.request("artifact.read_chunk", {
        transfer_ref: opened.result.transfer_ref,
        length: 64,
      });

      if (chunk.type === "result" && !chunk.result.eof) {
        summary.chunk_bytes = wire.decodeBytes(chunk.result.bytes_b64).length;
        summary.chunk_has_digest = typeof chunk.result.chunk_digest === "string";
      }

      const closed = await connection.request("artifact.close_transfer", {
        transfer_ref: opened.result.transfer_ref,
      });

      summary.transfer_closed = closed.type === "result";
    } else {
      summary.transfer_refused = opened.reason ?? opened.code;
    }
  }

  await connection.waitForEvent((event) => event.kind === "run.finished", 20_000);
  summary.event_kinds = connection.events().map((event) => event.kind);

  return summary;
}

function assert(condition, message) {
  if (!condition) throw new Error(message);
}
