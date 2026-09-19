// Concept
//
// The chain outcome 5 names, driven from outside: the client finds an admitted
// skill and selects it, submits a task, the host policy asks a question rather
// than allowing, the client presents that question and answers it, the policy
// is asked again and mints the authorization, the tool runs, and the client
// reads back what it produced.
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
// The workspace reference is an operator input, read from the environment. It
// is deliberately not derivable from anything this client can ask the server
// for: the catalog withholds it, along with every entry, until a decision
// naming it is active. A client that could reconstruct it could admit its own
// trust, which is the thing this leg exists to show it cannot do.
//
// Usage: LOOPEX_WORKSPACE_REF=<ref> node interaction-workflow.mjs <elixir> <path>...

import { Connection, wire } from "./loopex-client.mjs";

const [elixir, ...paths] = process.argv.slice(2);
const workspaceRef = process.env.LOOPEX_WORKSPACE_REF;

// A durable Store is an operator input like any other. Without one this client
// drives one process and stops; with one it also proves what survives losing it.
const storePath = process.env.LOOPEX_WORKFLOW_STORE;

// The launch configuration the server runs under, the task it is asked to
// perform, and how long this client is willing to wait are all operator inputs.
// They are read from the environment for the same reason the workspace
// reference is: a client that chose them for itself would be deciding what the
// operator launched. The defaults are the scripted workflow's own.
const serverEntry = process.env.LOOPEX_WORKFLOW_ENTRY || "Loopex.AppServer.Fixture.serve()";
const task = process.env.LOOPEX_WORKFLOW_PROMPT || "write the output file";

// Patience is this client's alone and is never read as a verdict about the
// session: a scripted model answers in milliseconds, a real one takes seconds,
// and neither fact belongs in the protocol.
const patienceMs = Number(process.env.LOOPEX_WORKFLOW_PATIENCE_MS || 20_000);

if (!Number.isFinite(patienceMs) || patienceMs <= 0) {
  console.error("LOOPEX_WORKFLOW_PATIENCE_MS must be a positive number of milliseconds");
  process.exit(2);
}

if (!elixir || paths.length === 0) {
  console.error("usage: node interaction-workflow.mjs <elixir-executable> <path>...");
  process.exit(2);
}

if (!workspaceRef) {
  console.error("LOOPEX_WORKSPACE_REF is the operator's workspace reference and is required");
  process.exit(2);
}

const serverArgs = [];
for (const path of paths) {
  if (path.endsWith(".exs")) serverArgs.push("-r", path);
  else serverArgs.push("-pa", path);
}
serverArgs.push("-e", serverEntry);

const childEnvironment = { ...process.env, LOOPEX_WORKFLOW_SCRIPT: "tool" };
const connection = new Connection(elixir, serverArgs, { env: childEnvironment });

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

  const summary = {};

  // Before any trust decision the catalog names the manifest the host was
  // launched with and nothing else: no workspace reference, no entries, no
  // descriptions. Content is withheld, not merely unselected.
  const withheld = await connection.request("resources.catalog", { session_id: sessionId });

  assert(withheld.type === "result", `the catalog was refused: ${withheld.code}`);

  const manifestDigest = withheld.result.configured_manifest_digest;

  assert(typeof manifestDigest === "string", "the catalog named no configured manifest");

  summary.catalog_before = {
    disposition: withheld.result.decision_disposition,
    entries: withheld.result.entries.length,
    admitted: withheld.result.admitted_manifest_digest,
    names_workspace: Object.keys(withheld.result).includes("workspace_ref"),
  };

  // The operator's decision is relayed, not minted. This client carries the
  // reference it was given and the digest the catalog named; it judges neither.
  const admitted = await connection.request("session.admit_resources", {
    command_id: wire.identity("chain-admit"),
    manifest_digest: manifestDigest,
    decision: {
      manifest_digest: manifestDigest,
      workspace_ref: workspaceRef,
      trust_scope: "project_skills",
      decision_source: "interactive_operator",
      issued_at: new Date().toISOString().replace(/\.\d{3}Z$/, "Z"),
      expires_at: null,
      revocation_state: "active",
    },
  });

  assert(
    admitted.status === "accepted",
    `the admission was ${admitted.status}: ${admitted.reason ?? "no reason"}`,
  );

  summary.admission_accepted = true;

  // Only now does the catalog describe anything.
  const catalog = await connection.request("resources.catalog", { session_id: sessionId });

  assert(catalog.type === "result", `the catalog was refused: ${catalog.code}`);

  const entries = catalog.result.entries;

  summary.catalog_after = {
    disposition: catalog.result.decision_disposition,
    entries: entries.length,
    names: entries.map((entry) => entry.name),
  };

  const [skill] = entries;

  assert(skill, "the admitted catalog described no skill");

  // The selection carries exactly what the catalog gave, including the pack
  // digest. A client that invented one is refused, which is why it is read
  // here rather than computed.
  const activated = await connection.request("session.activate_skill", {
    command_id: wire.identity("chain-skill"),
    manifest_digest: manifestDigest,
    pack_digest: skill.pack_digest,
    source_id: skill.source_id,
    name: skill.name,
    supporting_labels: ["notes.txt"],
  });

  assert(
    activated.status === "accepted",
    `the skill selection was ${activated.status}: ${activated.reason ?? "no reason"}`,
  );

  summary.skill_selected = skill.name;
  summary.skill_pack_digest = skill.pack_digest;

  const prompted = await connection.request("session.prompt", {
    command_id: wire.identity("chain-prompt"),
    content_b64: wire.bytes(task),
  });

  assert(prompted.status === "accepted", `the prompt was ${prompted.status}: ${prompted.reason}`);

  // The policy asks rather than allowing, and the question arrives as a durable
  // event like any other.
  const requested = await connection.waitForEvent(
    (event) => event.kind === "interaction.requested",
    patienceMs,
  );
  const question = requested.data;

  summary.session_created = true;
  summary.question_prompt = question.prompt;
  summary.choice_ids = (question.choices ?? []).map((choice) => choice.id);
  summary.interaction_id = question.interaction_id;

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

  const resolved = await connection.waitForEvent(
    (event) => event.kind === "interaction.resolved",
    patienceMs,
  );
  summary.resolution = resolved.data.status ?? resolved.data.resolution ?? null;

  // The policy was asked again after the answer committed, and only then did
  // the tool run.
  const finished = await connection.waitForEvent(
    (event) => event.kind === "tool.finished",
    patienceMs,
  );
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

  await connection.waitForEvent((event) => event.kind === "run.finished", patienceMs);
  summary.event_kinds = connection.events().map((event) => event.kind);

  if (storePath) {
    Object.assign(summary, await surviveAbruptLoss(sessionId));
  }

  return summary;
}

// Concept: the session outlives the process that was serving it.
//
// Technical depth: the first server is killed rather than closed, so nothing it
// held was written on the way out. A second server over the same Store then
// resumes the session and reads it back. What it reports is what was already
// durable when the first process died, which is the only kind of survival worth
// claiming.
async function surviveAbruptLoss(sessionId) {
  connection.kill();

  const successor = new Connection(elixir, serverArgs, { env: childEnvironment });

  try {
    await successor.initialize();

    const resumed = await successor.request("session.resume", {
      command_id: wire.identity("chain-resume"),
      session_id: sessionId,
    });

    const reattached = await successor.request("session.attach", {
      session_id: sessionId,
      after_event_sequence: wire.u64(0),
    });

    const inspected = await successor.request("session.inspect", { session_id: sessionId });

    return {
      restarted: true,
      resume_refused: resumed.type === "error" ? (resumed.code ?? true) : false,
      reattached: reattached.type === "snapshot",
      session_known_after_restart: inspected.type === "result",
    };
  } finally {
    successor.close();
  }
}

function assert(condition, message) {
  if (!condition) throw new Error(message);
}
