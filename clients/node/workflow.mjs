// Concept
//
// The integrated workflow an independent client performs against the shipped
// server: negotiate, create a session, attach, prompt, follow the durable
// events to the end of the run, read the session back, and leave. Every step
// goes over the wire and nothing reaches inside the runtime.
//
// Technical depth
//
// This is the client half of outcome 5's evidence. It prints one JSON summary
// on its own standard output so the Elixir case that runs it can assert against
// what the client observed rather than against what the server logged. The
// summary carries only what the client can see through the protocol, which is
// the point: anything it could not have learned from a record it received has
// no business in the evidence.
//
// Usage: node workflow.mjs <elixir-executable> <path>...
//
// Each path ending in .exs is required before the entry point; every other path
// is a compiled code directory. The server is launched with exactly what it is
// given and nothing this client invented, because a client that chose the
// server's launch inputs would be proving its own configuration rather than the
// protocol.

import { Connection, wire } from "./loopex-client.mjs";

const [elixir, ...paths] = process.argv.slice(2);

if (!elixir || paths.length === 0) {
  console.error("usage: node workflow.mjs <elixir-executable> <path>...");
  process.exit(2);
}

const serverArgs = [];
for (const path of paths) {
  if (path.endsWith(".exs")) serverArgs.push("-r", path);
  else serverArgs.push("-pa", path);
}
serverArgs.push("-e", "Loopex.AppServer.Fixture.serve()");

const connection = new Connection(elixir, serverArgs);

try {
  const summary = await run(connection);
  process.stdout.write(JSON.stringify(summary) + "\n");
  connection.close();
  await connection.ended();
  process.exit(0);
} catch (failure) {
  process.stdout.write(JSON.stringify({ failed: String(failure.message ?? failure) }) + "\n");
  connection.close();
  process.exit(1);
}

async function run(connection) {
  const initialized = await connection.initialize();

  // A client checks the contract it was written against before it changes
  // anything, which is the whole reason the digest is on the wire.
  const summary = {
    generation: initialized.selected_generation,
    schema_digest: initialized.exact_schema_sha256,
    method_count: initialized.supported_methods.length,
    frame_bytes: initialized.limits.frame_bytes,
  };

  const created = await connection.request("session.create", {
    command_id: wire.identity("client-create"),
    session_options: {},
  });

  assert(created.type === "admission", `expected an admission, received ${created.type}`);
  assert(created.status === "accepted", `creation was ${created.status}`);
  summary.session_created = true;
  summary.command_id_returned = wire.decodeIdentity(created.command_id);

  const sessionId = created.session_id;

  const attached = await connection.request("session.attach", {
    session_id: sessionId,
    after_event_sequence: wire.u64(0),
  });

  assert(attached.type === "snapshot", `expected a snapshot, received ${attached.type}`);
  assert(attached.snapshot.snapshot_revision === 2, "unexpected snapshot revision");
  summary.attached_cursor = attached.event_cursor;
  summary.snapshot_members = Object.keys(attached.snapshot).sort();

  const prompted = await connection.request("session.prompt", {
    command_id: wire.identity("client-prompt"),
    content_b64: wire.bytes("do the task"),
  });

  assert(prompted.type === "admission", `expected an admission, received ${prompted.type}`);
  assert(prompted.status === "accepted", `the prompt was ${prompted.status}: ${prompted.reason}`);
  summary.prompt_accepted = true;

  // The run's end is a durable fact the client waits for, not a timer it
  // guesses at.
  const finished = await connection.waitForEvent((event) => event.kind === "run.finished");
  summary.run_finished_sequence = finished.event_sequence;

  const kinds = connection.events().map((event) => event.kind);
  summary.event_kinds = kinds;

  // Durable sequences are decimal strings and arrive in order.
  const sequences = connection.events().map((event) => wire.decodeU64(event.event_sequence));
  summary.sequences_ordered = sequences.every((value, index) =>
    index === 0 ? true : value > sequences[index - 1],
  );

  const inspected = await connection.request("session.inspect", { session_id: sessionId });
  assert(inspected.type === "result", `expected a result, received ${inspected.type}`);
  summary.inspect_members = Object.keys(inspected.result).sort();
  summary.event_sequence_is_string = typeof inspected.result.event_sequence === "string";

  // A method the generation does not name is refused, and the connection
  // survives the refusal.
  const refused = await connection.request("session.teleport", {});
  assert(refused.type === "error", "an unknown method was not refused");
  summary.unknown_method_code = refused.code;

  const stillAlive = await connection.request("session.inspect", { session_id: sessionId });
  assert(stillAlive.type === "result", "the connection did not survive a refusal");
  summary.survived_refusal = true;

  return summary;
}

function assert(condition, message) {
  if (!condition) throw new Error(message);
}
