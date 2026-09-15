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
executable and the compiled code directories:

```bash
node clients/node/workflow.mjs "$(which elixir)" _build/dev/lib/loopex_protocol/ebin _build/dev/lib/loopex/ebin _build/dev/lib/loopex_app_server/ebin _build/dev/lib/telemetry/ebin apps/loopex/test/support/m1_runtime_helper.exs apps/loopex/test/support/agent_loop_helper.exs apps/loopex_app_server/test/support/fixture_server.exs
```

Each argument ending in `.exs` is required before the entry point; every other
one is a code directory. The server must be started with `-noinput`, because
the virtual machine otherwise keeps standard input for its own shell, and the
workflow sets that for the process it launches.

`apps/loopex_app_server/test/external_workflow_test.exs` runs exactly this and
asserts what the client reported.

`interaction-workflow.mjs` takes the same arguments and one operator input,
`LOOPEX_WORKSPACE_REF`, the workspace reference the skill manifest was launched
with. It is an input rather than something the client asks for, because the
catalog withholds the reference along with every entry until a trust decision
naming it is active. The client relays that decision; it does not judge it, and
it could not construct one from anything the server told it.

## What it does not do

It drives a scripted model. The attended real-provider demonstration is the
maintainer's to perform, because it spends a provider key and needs a person
watching.

Back to [clients](../README.md).
