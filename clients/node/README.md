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

## Running it

The workflow launches its own server process, so it needs the Elixir
executable, the entry point to start, and the compiled code directories. Each
argument ending in `.exs` is required before the entry point; every other one is
a code directory, so a shell glob over a build expands to exactly the set the
server needs.

Against the shipped host, with the inputs
[the operator guide](../../docs/operator/app-server.md#operator-app-server-launching)
names already exported:

```bash
export LOOPEX_WORKFLOW_ENTRY="Loopex.AppServer.Host.serve()"
node clients/node/workflow.mjs "$(command -v elixir)" _build/prod/lib/*/ebin
```

The server must be started with `-noinput`, because the virtual machine
otherwise keeps standard input for its own shell, and the workflow sets that for
the process it launches. This client never answers a question, so pair it with
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
computes the workspace reference from the workspace it was launched with:

```bash
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
