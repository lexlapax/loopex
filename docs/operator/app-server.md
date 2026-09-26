# App Server Operations

<a id="concept"></a>
## Concept

The app server is a foreground process that serves one Loopex session connection
as one JSON object per line on standard input and standard output. It exists so
a program in another language can drive a coding session without embedding the
runtime. Everything it exposes is the session contract a host already has in
process; there is no second loop behind it.

What you can do with it:

- launch a server with the state root, workspace, provider, policy and
  credential fixed at launch;
- drive it from the independent Node consumer, or any client that speaks the
  protocol;
- let a person answer the host policy's questions, including after a restart;
- read artifacts back in bounded, verified chunks.

Constraints:

- It is a foreground host for one connection, not a daemon. When the process
  ends the connection ends, and the durable session stays where it was. Nothing
  listens on a socket and a second process cannot take a session over. For
  those, use [the daemon](daemon.md#concept).
- The protocol generation is named `loopex.experimental/1`. The word
  "experimental" is part of the name, so no client can mistake it for a released
  contract; it may change without a migration path.
- A client drives a session; it never configures one. Every choice that
  matters is made at launch.

Related: [Runtime operations](runtime.md#concept) for the embedded runtime
beneath this, [How a run works](how-a-run-works.md#concept) for the flow of one
run, and the [protocol reference](../developer/app-server-protocol.md#concept)
for the wire contract.

<a id="operator-app-server-launching"></a>
## Launching the Server

`Loopex.AppServer.Host` is the local host this repository ships. It reads the
launch inputs below from the environment, composes the reference stack — Store,
model, executor, tools, host policy and skill manifest — and serves one
connection until standard input ends. An embedder that wants a different stack
composes its own runtime and calls `Loopex.AppServer.Stdio.serve/1` with it;
the rest of this page is about the shipped host.

### Build it

From a clean source checkout, or from a `git archive` extraction that carries
its `SOURCE_IDENTITY` file:

```bash
mix deps.get
MIX_ENV=prod mix compile
(cd apps/loopex_llm_reqllm && MIX_ENV=prod mix loopex.provider.build)
```

The compile leaves one directory per application under `_build/prod/lib`, the
shape `ERL_LIBS` expects. The provider build writes the private companion and a
non-secret `_build/prod/loopex_provider.launch` beside it; it refuses a checkout
with uncommitted or untracked changes, or an archive whose source identity it
cannot establish. Building the `loopex` command, as
[getting started](getting-started.md#operator-start-build) does, produces the
same companion and launch file.

### Name the inputs

| Variable | What it names |
| --- | --- |
| `LOOPEX_HOME` | The state root. The session log, the artifact store and the receipt ledger live beneath it. |
| `LOOPEX_WORKSPACE` | The workspace root the executor leases, and the tree project skills are discovered under. |
| `LOOPEX_PROVIDER_LAUNCH` | The `.launch` file naming the provider companion this host may start. It carries no credential. |
| `LOOPEX_POLICY` | `ask` or `allow-all`. There is no default. |
| `LOOPEX_PROVIDER_API_KEY` | The provider credential. Read once at start into private custody and removed from the environment; it never reaches an argument, a record, a log or a file. |

```bash
export LOOPEX_HOME="$HOME/.loopex"
export LOOPEX_WORKSPACE="$PWD"
export LOOPEX_PROVIDER_LAUNCH=/path/to/checkout/_build/prod/loopex_provider.launch
export LOOPEX_POLICY=ask
export ELIXIR_ERL_OPTIONS=-noinput
read -rs LOOPEX_PROVIDER_API_KEY
export LOOPEX_PROVIDER_API_KEY
```

A missing or unusable input is refused on standard error with the variable's
name and purpose, and the process exits with status `3`. It never starts
half-composed.

`LOOPEX_POLICY=ask` defers every executor tool call to the client as a durable
question — `Allow this tool call?`, with the choice identities `allow` and
`deny` — and decides once the answer has committed. The answer is an input to
the decision, never the decision itself. `LOOPEX_POLICY=allow-all` allows every
call and says so once on standard error; it is permissive local authority, not a
permission model. Both are described under
[host policy](tools-and-policy.md#operator-tools-policy).

**A question has five minutes, counted from when it committed and capped by the
run's deadline.** That instant is fixed once and never extended — not by a
restart, not by attaching again. Unanswered by then, the question expires and
the tool call it suspended is denied; the denial is a truthful outcome and is
never retried.

### Launch it

```bash
ERL_LIBS=_build/prod/lib elixir -e "Loopex.AppServer.Host.serve()"
```

**The VM must be started with `-noinput`**, which the `ELIXIR_ERL_OPTIONS`
export above does. Without it the VM keeps standard input for its own shell, the
server reads nothing, and the client waits forever. The server says so on
standard error rather than stalling silently.

Standard output carries protocol records and nothing else, so a client can parse
every line. Everything an operator should see — the workspace reference,
warnings, diagnostics, the `-noinput` complaint — goes to standard error.

<a id="operator-app-server-client"></a>
## Running the Node Consumer

The independent consumer lives in [`clients/node`](../../clients/node/README.md).
It is plain JavaScript that the pinned Node runs directly, with no build step,
package manifest, lockfile or dependency. The pinned version is named in
`scripts/fixtures/m4/client-toolchain.txt`.

The consumer launches its own server process, so it needs the Elixir executable,
the entry point to start, and the compiled code directories. Every argument that
is not a `.exs` file is a code directory, so a shell glob over the prod build
expands to exactly what the server needs:

```bash
export LOOPEX_WORKFLOW_ENTRY="Loopex.AppServer.Host.serve()"
node clients/node/workflow.mjs "$(command -v elixir)" _build/prod/lib/*/ebin
```

`workflow.mjs` never answers a question, so pair it with
`LOOPEX_POLICY=allow-all`. Under `ask` the first tool call waits for an answer
this client will not send, and the run stops there with nothing wrong.

The chain consumer, `interaction-workflow.mjs`, takes the same arguments and one
more input: `LOOPEX_WORKSPACE_REF`, the workspace reference a trust decision
must carry. It is an operator input rather than something the client asks the
server for — see [skills and trust](#operator-app-server-skills). The host
computes the value from `LOOPEX_WORKSPACE`, so ask it:

```bash
export LOOPEX_WORKSPACE_REF="$(ERL_LIBS=_build/prod/lib elixir -e 'IO.write(Loopex.AppServer.Host.workspace_reference!())')"
export LOOPEX_WORKFLOW_ENTRY="Loopex.AppServer.Host.serve()"
node clients/node/interaction-workflow.mjs "$(command -v elixir)" _build/prod/lib/*/ebin
```

This is the client that answers, so run it under `LOOPEX_POLICY=ask`. The server
also writes the workspace reference to standard error as it starts, for an
operator watching a server someone else launched.

Two more inputs belong to the client, not the server:
`LOOPEX_WORKFLOW_PROMPT` is what the session is asked to do, and
`LOOPEX_WORKFLOW_PATIENCE_MS` is how long the client waits for an event before
giving up. A real model takes seconds per turn, so raise the patience well above
its default when a real provider is behind the server.

<a id="operator-app-server-watching"></a>
## What an Operator Sees

A session moves through the same stages it does in process. Over the wire each
is a record the client receives, in this order.

| Stage | What the client receives | What it means |
| --- | --- | --- |
| Initialize | `initialized`, once | The generation was selected; the server reports its exact schema digest, supported methods and limits. A second initialize is refused. |
| Attach | `snapshot` | The authoritative durable state at an exact event sequence. It is anchored, not live. One attachment per session; a second is refused as a conflict rather than taking over. |
| Prompt | `admission` | The command was accepted and journaled. Acceptance is not completion; progress arrives as events. |
| Pending interaction | `event`, kind `interaction.requested` | The host policy deferred. The question carries its wording, its offered choices and its own identity. |
| Answer | `admission`, then `event` kind `interaction.resolved` | The answer was admitted as a durable command. It is an input to the host's decision. |
| Tool receipt | `event`, kind `tool.finished` | The policy was asked again after the answer committed, allowed the call, and the tool ran. Retained artifacts are named here. |
| Artifact transfer | `result` records | An opened transfer, bounded chunks, and a close. |
| Settlement | `event`, kinds `run.finished` then `session.settled` | The run ended and the session has no queued follow-up. |

Progress records arrive on their own plane. They are a rendering aid and never
durable truth: they do not advance a client's cursor, and losing one costs only
smoothness. Durable events do advance the cursor, so the two are bounded
separately — 64 records or 4 MiB for durable events, 32 records or 512 KiB for
progress. A client too slow to drain durable events is detached at its cursor,
so it can reattach and replay rather than miss history. A client too slow for
progress simply loses progress.

<a id="operator-app-server-skills"></a>
## Skills and Trust

A client may list the admitted skill catalog and select a skill, but neither
works without an operator's trust decision.

Before any decision the catalog names only the manifest the host was launched
with: no entries, no descriptions and no workspace reference. The workspace
reference is exactly the field a trust decision must carry, so a client cannot
assemble an admission from anything the server told it. The decision comes from
the operator, the client relays it, and the runtime binds it to the launch-time
manifest before admitting it.

After admission the catalog describes its entries, and a selection must carry
the identity and pack digest the catalog gave. Skill content is staged into a
run as provenance-typed context and grants no permission; see
[skill content does not grant authority](tools-and-policy.md#operator-tools-skill-authority).

<a id="operator-app-server-ending"></a>
## Ending a Session: Three Different Things

These are not interchangeable, and confusing them is how an operator loses work
or believes a cancellation happened that did not.

**Clean end of input.** The client closes its side. That ends the *connection*
and nothing else: no run is cancelled, no question is withdrawn, and a pending
question stays pending. If input ends in the middle of a frame, the server says
so with an `invalid_frame` record.

**Abrupt death.** The process is killed. Nothing is recorded, because nothing
had a chance to record it. For durable state the outcome is the same as end of
input — the session stands, the question stands — except that no final record
reaches the client.

**`session.abort`.** The one deliberate cancellation. It ends the run and
cancels the open question, which never reappears. If you want the run stopped,
use this; closing the pipe does not stop it.

<a id="operator-app-server-restart"></a>
## Answering an Interaction After a Restart

A pending question survives both a clean exit and an abrupt one, because it is
durable session state rather than connection state. A fresh server attaches to
the same session, receives the pending question in its snapshot at the same
cursor, and answers it with the identity the question carried. The policy is
then asked again, exactly as it would have been in the original process.

**The clock does not stop while the process is gone.** A recovered question is
re-armed against what remains of its fixed instant, not a fresh five minutes.
Kill a server four minutes into a question and restart it three minutes later,
and the question is already past its expiry: it resolves as expired at once and
the suspended tool call is denied. Nothing is lost — the denial is durable and
the session intact. If you expect a gap that long, abort the run and prompt
again instead.

An answer that committed before the loss is not re-armed at all, because the run
owes it a resumed evaluation rather than a timer. An expiry never overtakes an
answer that was already durable.

<a id="operator-app-server-artifacts"></a>
## Artifact Transfers and What They Cost

An artifact is read back over the wire in bounded windows rather than handed
over as a path: a transfer is opened, read in chunks, and closed. The daemon's
generation offers the same transfers.

**One verification per transfer, never one per chunk.** The object is verified
once, when the transfer opens; each chunk then carries its own digest so a
client can check what it received without the server re-reading the object.

The server caps objects at 64 MiB; the opening verification at 60 seconds and
128 MiB of storage work; chunks at 32 KiB with five seconds per read; an open
transfer's lifetime at ten minutes; and concurrency at two transfers per
attachment and four per runtime. These are safety ceilings, not a service-level
promise. Accepted [ADR 0028](../adr/0028-bounded-artifact-retrieval.md#concept)
states the concurrency unit as the connection and adds 1 GiB of cumulative
transfer work per connection; the implementation counts per attachment and
enforces no cumulative work allowance. That divergence is recorded in the
[M5 plan](../plans/M5.md#concept) and awaits a maintainer decision. A transfer belongs to
the attachment that opened it and is released when that attachment goes.

<a id="operator-app-server-limits"></a>
## Frame and Connection Limits

| Limit | Value |
| --- | --- |
| Frame bytes before initialization | 65,536 |
| Frame bytes after initialization | 1,048,576 |
| Output record bytes | 2,097,152 |
| Object nesting depth | 16 |
| Members per object | 1,024 |
| String bytes | 131,072 |
| Session identity bytes | 256 |
| Requests in flight | 32 |
| Integers | ±(2⁵³ − 1) |

Framing is strict on purpose. One JSON object per line, LF only: a carriage
return is a protocol error rather than something quietly stripped, duplicate
object members are refused rather than collapsed, and a float where an integer
belongs is refused rather than rounded.

<a id="operator-app-server-unavailable"></a>
## What Is Not Provided

| Capability | State |
| --- | --- |
| Drive a session from another language over standard input and output | Available, experimental |
| Run in the background or listen on a socket | Not here; `loopex daemon` does, on generation 2 — see [the daemon](daemon.md#concept) |
| Attach more than one client to a session, or take one over | Not here; the daemon provides both |
| Install a Hex package, binary or installer | Not provided |
| Rely on the generation staying unchanged | Not provided; the name says experimental |

These are not alternate routes to hidden functionality. The daemon drives this
same session contract over its socket rather than introducing another loop.

## Related

- [Runtime operations](runtime.md#concept) — the embedded runtime this serves.
- [Coding sessions](coding-sessions.md#concept) — the `loopex` command over the same contract.
- [Tools and policy](tools-and-policy.md#concept) — host authority, and why skill content grants none.
- [App server protocol](../developer/app-server-protocol.md#concept) — the wire contract for client authors.
- [Node client](../../clients/node/README.md) — the independent consumer.
- [Operator documentation index](README.md).
