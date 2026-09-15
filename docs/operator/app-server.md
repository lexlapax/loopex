# App Server Operations

<a id="concept"></a>
## Concept

M4 adds a second way to reach a Loopex runtime: a foreground server process
that speaks one JSON object per line on standard input and standard output. It
exists so a program written in another language can drive a coding session
without embedding the runtime, and everything it exposes is the same session
contract a host already has in process. There is no second loop behind it.

It is a foreground host, not a daemon. It owns no session residency: when the
process ends, the connection ends, and the durable session stays where it was.
Nothing listens on a socket, nothing runs in the background, and a second
process cannot take a session over from the first.

The protocol generation is named `loopex.session.v1-experimental`. The word is
part of the name so that no client can read it as a released contract and no
version comparison can round it up to one. It may change in any later
milestone without a migration path.

Related: [Runtime operations](runtime.md#concept) for the embedded runtime
beneath this, and [How a run works](how-a-run-works.md#concept) for the flow
of a single run.

<a id="operator-app-server-launching"></a>
## Launching the Server

The server reads a runtime that the launching host composed. Every choice that
matters — the Store, the model, the executor, the tool set, the host policy,
the skill manifest — is made at launch and cannot be changed by anything a
client sends. That is the point of the split: a client drives a session, it
does not configure one.

Launch it from a source build with the compiled code directories on the path:

```bash
elixir -pa _build/dev/lib/loopex_protocol/ebin -pa _build/dev/lib/loopex/ebin -pa _build/dev/lib/loopex_app_server/ebin -pa _build/dev/lib/telemetry/ebin -e "Loopex.AppServer.Stdio.serve(runtime)"
```

**The virtual machine must be started with `-noinput`.** Without it the VM
keeps standard input for its own shell, and two owners of one descriptor is not
something that can be made to work: the server reads nothing and the client
waits forever. Set it through the environment of the process you launch:

```bash
ELIXIR_ERL_OPTIONS=-noinput
```

The server says so on standard error if it is started without it, rather than
leaving you to discover it from a silent stall.

Standard output carries protocol records and nothing else, so a client can
parse every line it receives. Anything an operator should see — warnings,
diagnostics, the `-noinput` complaint — goes to standard error. A host that
prints to standard output breaks every client reading that stream.

<a id="operator-app-server-client"></a>
## Running the Node Consumer

The independent consumer lives in [`clients/node`](../../clients/node/README.md).
It is plain JavaScript that the pinned Node runs directly: no build step, no
package manifest, no lockfile, no dependency. The pinned version is named in
`scripts/fixtures/m4/client-toolchain.txt` and verified before any client lane
runs; an absent or mismatched Node is reported as unavailable evidence rather
than as a failure of the product.

The consumer launches its own server process, so it needs the Elixir
executable and the same code directories:

```bash
node clients/node/workflow.mjs "$(which elixir)" _build/dev/lib/loopex_protocol/ebin _build/dev/lib/loopex/ebin _build/dev/lib/loopex_app_server/ebin _build/dev/lib/telemetry/ebin
```

The chain consumer, `interaction-workflow.mjs`, takes the same arguments and
one operator input: `LOOPEX_WORKSPACE_REF`, the workspace reference the skill
manifest was launched with. It is an input rather than something the client
asks the server for, and that is deliberate — see
[skills and trust](#operator-app-server-skills) below.

<a id="operator-app-server-watching"></a>
## What an Operator Sees

A session moves through the same stages it does in process. Over the wire each
one is a record a client receives, and they arrive in this order.

| Stage | What the client receives | What it means |
| --- | --- | --- |
| Initialize | `initialized`, once | The generation was selected, and the server reports its exact schema digest, its supported methods and its limits. It happens exactly once per connection; a second attempt is refused. |
| Attach | `snapshot` | The authoritative durable state at an exact event sequence. It is anchored, not live: it does not advance as events arrive. One attachment per session; a second is refused as a conflict rather than taking over. |
| Prompt | `admission` | The command was accepted and journaled. Acceptance is not completion; the run's progress arrives as events. |
| Pending interaction | `event`, kind `interaction.requested` | The host policy deferred rather than allowing. The question carries its exact wording, its offered choices and its own identity. |
| Answer | `admission`, then `event` kind `interaction.resolved` | The answer was admitted as a durable command. The answer is an input to the host's decision; it is never the decision. |
| Tool receipt | `event`, kind `tool.finished` | The policy was asked again after the answer committed, minted the authorization, and the tool ran. Any artifacts it retained are named here. |
| Artifact transfer | `result` records | An opened transfer, bounded chunks, and a close. |
| Settlement | `event`, kinds `run.finished` then `session.settled` | The run ended, and the session has no queued follow-up. |

Progress records arrive on their own plane. They are a rendering aid and never
durable truth: they do not advance a client's cursor, and losing one costs
nothing but smoothness. Durable events do advance the cursor, which is why the
two are bounded separately — 64 records or 4 MiB for durable events, 32 records
or 512 KiB for progress. A client too slow to drain durable events is detached
at its cursor, so it can reattach and replay rather than silently miss history.
A client too slow for progress simply loses progress.

<a id="operator-app-server-skills"></a>
## Skills and Trust

A client may list the admitted catalog and select a skill, and it may do
neither without an operator's trust decision.

Before any decision the catalog names only the manifest the host was launched
with. There are no entries, no descriptions, and no workspace reference. The
workspace reference is exactly the field a trust decision must carry, so a
client cannot assemble its own admission out of anything the server told it.
The decision comes from the operator, the client relays it, and the runtime
binds it to the launch-time manifest before admitting it.

After admission the catalog describes its entries, and a selection must carry
the identity and pack digest the catalog gave. Skill content is content: it is
staged into a run as provenance-typed context and grants no permission to do
anything.

<a id="operator-app-server-ending"></a>
## Ending a Session: Three Different Things

These are not interchangeable, and confusing them is how an operator loses work
or believes a cancellation happened that did not.

**Clean end of input (EOF).** The client closes its side. This is an orderly
shutdown of the *connection*, and nothing else: no run is cancelled, no
interaction is withdrawn, and a question still pending stays pending. The
durable session is exactly where it was. If input ends in the middle of a
frame, the server says so with an `invalid_frame` record rather than leaving
the client to wonder whether its last write was read.

**Abrupt death.** The process is killed. Nothing is recorded, because nothing
had a chance to record it. The outcome is identical to EOF as far as durable
state is concerned — the session stands, the interaction stands — the
difference being only that no final record reaches the client.

**`session.abort`.** This is the one deliberate cancellation. It ends the run
and cancels the open question, and an aborted interaction never reappears. If
you want the run stopped, this is the method; closing the pipe is not.

<a id="operator-app-server-restart"></a>
## Answering an Interaction After a Restart

A pending question survives both a clean exit and an abrupt one, because it is
durable session state rather than connection state. A fresh process attaches to
the same session, receives the pending interaction in its snapshot at the same
cursor, and answers it with the identity the question carried. The policy is
then asked again, exactly as it would have been in the original process.

This is why EOF cancels nothing. A client that crashed mid-question can come
back and finish.

<a id="operator-app-server-artifacts"></a>
## Artifact Transfers and What They Cost

An artifact is read back over the wire in bounded windows rather than handed
over as a path. A transfer is opened, read in chunks, and closed.

**One verification per authorized transfer, never one per chunk.** The object
is verified once, when the transfer opens; each chunk then carries its own
chunk digest so a client can check what it received without the server
re-reading the whole object. That is what keeps a large artifact from costing
its own size in verification work for every window.

The proposed transfer profile caps objects at 64 MiB, the opening verification
at 60 seconds and 128 MiB of work, chunks at 32 KiB with five seconds per read,
an open transfer's lifetime at ten minutes, concurrency at two per connection
and four per runtime, and connection work at 1 GiB with a 1 MiB minimum debit
per open. A transfer belongs to the attachment that opened it and is released
when that attachment goes.

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
belongs is refused rather than rounded. A client that is lenient about framing
would not notice a server that was.

<a id="operator-app-server-unavailable"></a>
## What Is Not Provided

| Capability | State |
| --- | --- |
| Drive a session from another language over stdio | Available, experimental |
| Run as a daemon or listen on a socket | Not provided |
| Attach more than one client to a session, or take one over | Not provided |
| Install a Hex package, binary or installer | Not provided |
| Rely on the generation across milestones | Not provided; the name says experimental |

These are not alternate routes to hidden functionality. A later daemon, socket
transport or packaged client must drive this same session contract rather than
introduce another loop.

## Related

- [Runtime operations](runtime.md#concept) — the embedded runtime this serves.
- [Coding sessions](coding-sessions.md#concept) — the `loopex` command over the same contract.
- [Tools and policy](tools-and-policy.md#concept) — host authority, and why skill content grants none.
- [Node client](../../clients/node/README.md) — the independent consumer.

Back to the [operator index](README.md).
