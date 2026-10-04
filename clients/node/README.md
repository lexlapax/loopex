# Node client

A client for the experimental public session protocol, written as plain
JavaScript that Node runs directly.

There is no build step, no package manifest, no lockfile and no
`node_modules`. That is deliberate and was the maintainer's choice: a second
package manager in this repository would cost every lane an install and a
lockfile for a client whose whole job is to prove a byte contract. Nothing here
imports anything outside Node's own standard library.

## Files

| File | What it does |
| --- | --- |
| `loopex-client.mjs` | The connection, the request correlation, and the four wire representations |
| `workflow.mjs` | The integrated workflow: negotiate, create, attach, prompt, follow events, inspect, leave |
| `interaction-workflow.mjs` | The chain: find and select an admitted skill, submit a task, answer the host policy's question, watch the tool run, read the artifact it kept |
| `daemon-client.mjs` | The generation-2 connection to a running daemon over its Unix-domain socket, sharing the wire helpers above |
| `daemon-takeover.mjs` | The cross-process takeover: observe a session another client controls, wait for that controller's lease to lapse, take control with a fresh epoch, abort the running work and release |
| `question-answer.mjs` | Decode the closed M7 choice/text/decline answer payload; preparation for the coordinated generation-3/4 switch |
| `question-answer-vectors.mjs` | Independently check literal answer vectors and UTF-8/identity byte boundaries |
| `terminal-outcome.mjs` | Decode chat's closed terminal run objects with exact BigInt counts and opaque references |
| `terminal-outcome-vectors.mjs` | Independently check terminal outcome vectors and reference boundaries |
| `compact-result.mjs` | Decode standalone compaction results and completed-command payloads with exact usage, closed failures and opaque identities; both connections validate completion events |
| `compact-result-vectors.mjs` | Independently check result/completion vectors, accounting and checkpoint/command/episode boundaries |
| `checkpoint-owner.mjs` | Decode closed run/compact checkpoint owners and opaque identity bytes; both connections validate checkpoint events |
| `checkpoint-owner-vectors.mjs` | Independently check literal owner vectors, superseded aliases and identity boundaries |
| `maintenance-view.mjs` | Decode the closed active-maintenance payload, exact admission bounds and opaque owner/episode identities |
| `maintenance-view-vectors.mjs` | Independently check maintenance literals, private-field refusals and full UTF-8/identity byte boundaries |
| `configuration.mjs` | Decode the closed committed configuration and configuration-change payload, preserving exact quantities and instruction identity |
| `checkpoint.mjs` | Decode the complete checkpoint projection, actual owner, original-source references and exact coverage/usage quantities |
| `snapshot-payload-vectors.mjs` | Independently check configuration/checkpoint literals and every opaque identity and text byte boundary |

Run the M7 answer payload checks with the pinned Node interpreter:

```bash
node clients/node/question-answer-vectors.mjs apps/loopex_protocol/priv/vectors/question-answer.v1.json
node clients/node/compact-result-vectors.mjs apps/loopex_protocol/priv/vectors/standalone-compact-result.v1.json apps/loopex_protocol/priv/vectors/standalone-compact-completion.v1.json
node clients/node/checkpoint-owner-vectors.mjs apps/loopex_protocol/priv/vectors/checkpoint-owner.v1.json
node clients/node/maintenance-view-vectors.mjs apps/loopex_protocol/priv/vectors/maintenance-view.v1.json
node clients/node/snapshot-payload-vectors.mjs apps/loopex_protocol/priv/vectors/configuration-projection.v1.json apps/loopex_protocol/priv/vectors/checkpoint-projection.v1.json
```

This checks payloads only. The foreground and daemon clients still require
their coordinated M7 initialization, complete schema-digest pins and live
workflow updates before sending the new branches.

## Running it

The workflow launches its own server process, so it needs the Elixir
executable, the entry point to start, and the compiled code directories. Each
argument ending in `.exs` is required before the entry point; every other one is
a code directory, so a shell glob over a build expands to exactly the set the
server needs.

Against the shipped host, with the inputs
[the operator guide](../../docs/operator/app-server.md#operator-app-server-launching)
names already exported, including `LOOPEX_POLICY=allow-all` and a credential
provided by the host, set the Elixir no-input option before launching:

```bash
export ELIXIR_ERL_OPTIONS=-noinput
export LOOPEX_WORKFLOW_PATIENCE_MS=120000
export LOOPEX_WORKFLOW_ENTRY="Loopex.AppServer.Host.serve()"
node clients/node/workflow.mjs "$(command -v elixir)" _build/prod/lib/*/ebin
```

The server must be started with `-noinput`, because the virtual machine
otherwise keeps standard input for its own shell. The workflow passes its
launch arguments and environment through; it does not add that option. This
client never answers a question, so pair it with
`LOOPEX_POLICY=allow-all`; under `ask` the first tool call waits for an answer it
will not send.

`apps/loopex_app_server/test/external_workflow_test.exs` runs this against a
scripted launch configuration and asserts what the client reported.

`interaction-workflow.mjs` takes the same arguments and one more operator input,
`LOOPEX_WORKSPACE_REF`, the workspace reference a trust decision must carry. It
is an input rather than something the client asks for, because the catalog
withholds the reference along with every entry until a trust decision naming it
is active. The client relays that decision; it does not judge it, and it could
not construct one from anything the server told it. This is the client that
answers, so it is the one to run under `LOOPEX_POLICY=ask`. The shipped host
computes the workspace reference from the workspace it was launched with.
Prepare that workspace with an admitted project skill under
`.agents/skills/<name>/`: its `SKILL.md` and a supporting `notes.txt` must both
exist. The client selects the first catalog entry and requests `notes.txt`, so
an empty catalog or a different first skill cannot complete this example.
Set `LOOPEX_WORKFLOW_PROMPT` to a task naming a workspace file for the model to
read, then run:

```bash
export ELIXIR_ERL_OPTIONS=-noinput
export LOOPEX_WORKFLOW_PATIENCE_MS=120000
export LOOPEX_POLICY=ask
export LOOPEX_WORKFLOW_PROMPT="Use the read tool once on architecture.txt, then finish."
export LOOPEX_WORKSPACE_REF="$(ERL_LIBS=_build/prod/lib elixir -e 'IO.write(Loopex.AppServer.Host.workspace_reference!())')"
export LOOPEX_WORKFLOW_ENTRY="Loopex.AppServer.Host.serve()"
node clients/node/interaction-workflow.mjs "$(command -v elixir)" _build/prod/lib/*/ebin
```

Both clients read the same optional launch inputs from the environment, so one
client can drive a differently launched server without being changed:
`LOOPEX_WORKFLOW_ENTRY`, the entry point the server process is started with;
`LOOPEX_WORKFLOW_PROMPT`, the task the session is given; and
`LOOPEX_WORKFLOW_PATIENCE_MS`, how long this client waits for an event before it
stops waiting. Each defaults to what the scripted workflow uses, which is why a
run against the shipped host names the entry point and raises the patience.

## What it does not do

It decides nothing. Which model answers behind the server is the launch
configuration's business, not the client's: with the default entry point a
scripted model answers, and
`apps/loopex_app_server/test/external_workflow_real_test.exs` drives this same
client, by the command above, against the shipped host built from an extracted
source archive with a real provider behind it. That case is excluded from
ordinary runs, because it spends a provider key.

Back to [clients](../README.md).

## Against a daemon

`daemon-takeover.mjs` connects to a daemon that is already running rather than
starting a server of its own:

```bash
node clients/node/daemon-takeover.mjs "$LOOPEX_HOME/daemon/d.sock" <session-id>
```

It prints `{"attached":true}` once it observes the session, then one summary
line after it has taken over and aborted. It never forces a live holder off:
while another client holds the lease it keeps asking, once a second, for up to
ninety seconds. `apps/loopex_daemon/test/external_socket_workflow_test.exs`
runs it against a killed controller.
