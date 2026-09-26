# Runtime Operations

<a id="concept"></a>
## Concept

The Loopex runtime is a headless, single-machine loop that a host program
starts explicitly. The host supplies a durable local Store, a model adapter, a
trusted-local executor, the tool definitions, and a host policy; Loopex returns
a runtime reference that every session operation requires. Nothing is started
implicitly and there is no global default runtime.

This page is for an operator running or embedding that runtime directly, and
for anyone recovering one after a crash. The `loopex` command, the daemon and
the app server are hosts over this same runtime; if you only want to use the
command, start with [getting started](getting-started.md) instead.

What you can do here:

- run the complete loop from the source tree, with or without a real provider;
- start, stop and resume a runtime and its sessions in a fixed order;
- recover after a process or machine crash and reconcile an in-flight effect
  from the executor's receipt ledger;
- read the runtime's refusals as the stop conditions they are.

Constraints: one active run per session, one active runtime per Store and
`runtime_id`, no network transport, remote executor or distribution, and no
production credential manager. Keeping sessions alive between processes for
several local clients is the job of [the daemon](daemon.md#concept).

Developer composition details:
[Runtime and embedding](../developer/runtime-and-embedding.md#technical-depth).

<a id="operator-runtime-available"></a>
## What the Runtime Provides

A host can start the runtime, submit a prompt, call a model, authorize and run
tools, observe durable events, stop, and resume from retained state. The
reference client drives the same embedded API a host has; it owns no test-only
or alternate loop.

| Capability | State |
| --- | --- |
| Run the complete loop from this source tree | Available |
| Use a deterministic model for a credential-free demonstration | Available |
| Use the ReqLLM adapter with a real provider | Available |
| Execute tools in separate operating-system processes | Available |
| Retain sessions, events and tool receipts, and resume after process loss | Available |
| Drive sessions with the `loopex` command | Available: [coding sessions](coding-sessions.md#concept) |
| Keep sessions alive for several local clients over a Unix-domain socket | Available: [the daemon](daemon.md#concept) |
| Drive a session from another language over standard input and output | Available: [app server operations](app-server.md#concept) |
| Install a released package | Not provided |
| Run a remote executor, network client, or distributed service | Not provided |

The missing surfaces are not hidden routes to the same functionality. Every
surface that exists drives this one runtime contract rather than a second loop.

<a id="operator-runtime-first-run"></a>
## Run the Working Loop

From the repository root, the credential-free demonstration is:

```bash
MIX_ENV=test mix test apps/loopex_reference_client/test/reference_client_test.exs --seed 0 --trace
```

It starts an isolated runtime and durable local Store in temporary directories,
submits a prompt through the reference client, receives a deterministic model
tool call, runs the controlled workspace-write tool in a child process, consumes
the durable event sequence through `run.finished`, checks the resulting file,
and removes its temporary state. Success is every case in the file passing with
none excluded.

To run the same path through the real ReqLLM adapter, export the provider key
as `LOOPEX_PROVIDER_API_KEY` from your secret store, then:

```bash
MIX_ENV=test mix test apps/loopex_reference_client/test/real_model_session_test.exs --only real_provider --seed 0 --trace
```

It makes two real model calls around one controlled tool effect and checks that
both calls send the canonical request bytes the session already committed. Keep
the credential out of the command line, the repository, the state root, logs and
fixtures, and unset it afterwards if nothing else manages its lifetime.

These are source-tree demonstrations, not a command contract. To embed Loopex in
your own host, follow the
[developer runtime and embedding guide](../developer/runtime-and-embedding.md#concept).

<a id="operator-runtime-prerequisites"></a>
## Before Starting

- Give the runtime one owned state root for the Store log, the executor's
  receipt ledger and the artifact store, and a separate workspace for the tools.
  Never point a development or test runtime at real user state.
- Start only one active runtime for a Store and `runtime_id`. Start a
  replacement only after the previous runtime's operating-system process tree is
  known to be gone or has been stopped.
- Keep the provider credential in the host. The reference composition reads
  `LOOPEX_PROVIDER_API_KEY` once, moves it into private custody and removes it
  from the process environment; a second composition in the same
  operating-system process refuses with `provider_credential_required` rather
  than finding it again. The credential never belongs in session options,
  commands, Store data, executor jobs, receipts, events, diagnostics, fixtures
  or logs. Where it does go is described under
  [credential boundary](tools-and-policy.md#operator-tools-credential).
- The trusted-local executor is not a sandbox. It runs only its registered
  tools beneath a held workspace lease, and each tool process receives an
  explicit environment containing only `PATH`. See
  [what local execution can reach](tools-and-policy.md#operator-tools-reach).
- The reference executor needs `/bin/bash` for its own supervision and `/bin/ps`
  to confirm cleanup; see the
  [local supervision prerequisite](tools-and-policy.md#operator-local-supervision-shell).

<a id="operator-runtime-lifecycle"></a>
## Operating Lifecycle

The reference composition, `LoopexComposition.start/1` or
`LoopexComposition.with_runtime/2`, performs the first three steps in this order
and the last one in reverse. A host composing its own stack follows the same
order.

1. Start the durable local Store for its log path.
2. Start the workspace lease and the trusted-local executor for the workspace
   and receipt-ledger paths.
3. Start Loopex with an explicit `runtime_id`, Store, model, executor, tools and
   host policy. A runtime with no policy refuses to start.
4. Create or resume a session, attach at a durable event cursor, and submit a
   prompt.
5. Consume committed events. `user.message_appended`, `run.started`,
   `assistant.message_appended`, `tool.started`, `tool.finished` and
   `run.finished` are durable public facts. Progress and diagnostics are
   transient and are never durable truth.
6. Stop Loopex before the executor, the lease and the Store. A normal stop
   keeps the Store and ledger bytes for a later resume.

Ordering inside a run is fixed: the canonical model request is committed before
the model is called, effect intent and the host grant are committed before the
executor is asked to act, and a validated receipt is committed before the loop
continues or the matching fact is published.
[What is durable at each step](how-a-run-works-technical.md#technical-run-durability)
has the full table.

<a id="operator-runtime-recovery"></a>
## Crash Recovery

After a normal stop or an ungraceful process or machine death:

1. Reopen the local Store with `recover_stale_writer: true`. That is a request,
   not a removal. The Store reads the writer marker the previous holder left
   (`loopex_store_writer_v2`, recording that process's operating-system pid and
   start identity) and asks the operating system whether that process is still
   alive.
   - A live holder is refused as `store_writer_active`. The one exception is a
     marker recorded by this same VM whose Store process is proved dead; that
     marker is recovered.
   - A holder that is gone, or whose pid now belongs to a different process, is
     recovered.
   - A marker the Store cannot verify is refused as `store_writer_unverifiable`:
     one with no identity in it, unreadable bytes, or a process probe that
     failed or did not answer within five seconds. Remove it by hand only once
     you know its writer is dead.

   Only the probe's exact "no such process" answer counts as absence, and a
   Store that cannot record its own identity refuses to open, so check that
   `/bin/ps` runs where Loopex does. Concurrent recovery is refused.
2. Start a replacement runtime with the same `runtime_id`, Store, workspace,
   executor identity, receipt ledger and tool definitions.
3. Resume the session under a fresh command identity. Resume commits a new owner
   epoch before it accepts commands or consequences.
4. If the session reports an effect awaiting recovery, request its current
   reconciliation query, look up the exact job receipt in the executor ledger,
   and answer the query with that retained receipt.
5. If no provable receipt exists, answer `outcome_unknown`. Never redispatch an
   effect because its result is missing. `outcome_unknown` is durable and ends
   that run.

A receipt is admitted only when the current query, operation, attempt,
canonical request digest, session and executor epochs, executor identity and
fencing token all match the journaled intent. Stale, unsolicited, incomplete or
mismatched evidence is refused, and a field the answer omits counts as a
mismatch. [Crash, and what recovery proves](how-a-run-works-technical.md#technical-run-recovery)
states the full match.

<a id="operator-runtime-failures"></a>
## Reading Failures

- A missing provider credential is a configuration error. The run did not
  happen; it is never a skipped success.
- `commit_unknown` fences its mutation domain until the exact transaction is
  re-presented and reaches a retained resolution. Nothing is acknowledged,
  published or dispatched through that fence.
- A lost workspace lease cancels or kills executor-owned work and produces a
  retained non-success receipt.
- A full attachment queue disconnects only that attachment and returns its last
  stable durable cursor. Reattach from that cursor; the session keeps committing.
- Store corruption, a torn record that cannot be repaired safely, or a writer
  marker whose owner may still be alive is a stop condition, not a reason to
  guess or recreate state.
- A log removed or replaced beneath a live Store is the same kind of stop
  condition. The Store holds that exact file, not its path, so it reports the
  write as ambiguous and stops rather than continuing into a new, empty log.
  Recover it as any `commit_unknown` is recovered: establish that the previous
  process tree is gone, reopen, and re-present the exact transaction. Do not
  restore a partial copy of a state root.

## Related

- [Runtime and embedding](../developer/runtime-and-embedding.md#concept) — the developer companion to this runbook.
- [How a run works](how-a-run-works.md#concept) — the same loop seen from the `loopex` command.
- [Observability](observability.md#concept) — tracing and telemetry for a runtime you host.
- [Development setup](../../DEVELOPMENT.md) — toolchains and repository checks.
- [Operator documentation index](README.md).
