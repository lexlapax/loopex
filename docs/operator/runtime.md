# Runtime Operations

<a id="concept"></a>
## Concept

M1 supplies one source-tree, single-machine embedded runtime. A host starts an
explicit runtime with a durable local Store, model adapter, trusted-local
executor, one controlled tool definition, and an explicit host-policy decision.
The returned runtime reference is required for every session operation; Loopex
installs no global default.

This is a working milestone surface, not an installable package or released
contract. It supports one attached caller and one active run per session. It
does not provide a daemon, network transport, multi-client attachment, remote
executor, distribution, or production credential manager.

Developer composition details: [Runtime and embedding](../developer/runtime-and-embedding.md#technical-depth).

<a id="operator-runtime-prerequisites"></a>
## Before Starting

- Use one owned state root for the Store log, executor receipt ledger, and
  workspace. Never point a development or test runtime at real user state.
- Start only one active Runtime Control for a Store namespace and `runtime_id`.
  A replacement may start only after the prior runtime OS-process tree is known
  dead or has been quiesced.
- Hold provider credentials in the host. The reference ReqLLM adapter reads only
  `LOOPEX_PROVIDER_API_KEY` for the request it performs. Credentials must not be
  placed in session options, commands, Store data, executor jobs, receipts,
  events, diagnostics, fixtures, or logs.
- The trusted-local executor is not a sandbox. It launches only its fixed,
  validated tool registry beneath a held workspace lease. The controlled tool
  process receives an explicit environment containing only `PATH`; it receives
  neither the provider credential name nor its value.

<a id="operator-runtime-lifecycle"></a>
## Operating Lifecycle

1. Start the durable local Store for its explicit log path.
2. Start the workspace lease and trusted-local executor for the owned workspace
   and receipt-ledger paths.
3. Start Loopex with an explicit `runtime_id`, Store handle, model, executor,
   tool, and host-policy allow decision.
4. Create or resume a session, attach at a durable event cursor, and submit a
   prompt through the embedded API.
5. Consume committed events. `user.message_appended`, `run.started`,
   `assistant.message_appended`, `tool.started`, `tool.finished`, and
   `run.finished` are durable public facts. Progress and diagnostics are
   transient and must never be interpreted as durable truth.
6. Stop the Loopex runtime before stopping the executor, lease, and Store. A
   normal stop preserves Store and executor-ledger bytes for explicit resume;
   once the stopped process is known gone, the next Store opener uses the same
   deliberate stale-writer recovery procedure as crash recovery.

The runtime commits canonical model-request bytes before calling the model. It
commits effect intent and the host grant before executor dispatch, and commits a
validated executor receipt before continuing the model loop or publishing the
corresponding durable fact.

<a id="operator-runtime-recovery"></a>
## Crash Recovery

After a normal stop or an ungraceful VM or OS-process death:

1. Establish that the prior runtime process tree is gone. Do not attempt
   concurrent recovery.
2. Reopen the local Store with `recover_stale_writer: true`. That option removes
   the deliberate stale writer marker; it is safe only under the single-active
   placement rule above.
3. Start a replacement runtime with the same `runtime_id`, Store namespace,
   workspace, executor identity, receipt ledger, and tool contract.
4. Resume the session under a fresh command identity. Resume commits a new owner
   epoch before accepting commands or consequences.
5. If the session reports an effect awaiting recovery, request the current
   reconciliation query. Look up the exact job receipt in the executor ledger
   and answer that query with the retained receipt.
6. If no provable receipt exists, answer `outcome_unknown`. Never redispatch the
   old effect merely because its result is missing. `outcome_unknown` is durable
   and terminal for that run.

A receipt is admitted only when the current query, operation, attempt, canonical
request digest, session and executor epochs, executor identity, and fencing
token all match the journaled intent. Stale, unsolicited, incomplete, or
mismatched recovery evidence is refused.

<a id="operator-runtime-failures"></a>
## Failure Interpretation

- A missing provider credential is unavailable evidence or an operator
  configuration error; it is never a skipped success.
- `commit_unknown` fences its mutation domain until exact transaction
  re-presentation reaches a retained terminal resolution. Do not acknowledge,
  publish, or dispatch through that fence.
- A lost workspace lease cancels or kills executor-owned work and produces a
  retained non-success receipt.
- A full attachment queue disconnects only that attachment and returns its last
  stable durable cursor. Reattach from that cursor; session commits remain live.
- Store corruption, a torn record that cannot be safely repaired, or a writer
  marker whose prior owner may still be alive is a stop condition, not a reason
  to guess or recreate state.

The exact developer and gate commands live in [DEVELOPMENT.md](../../DEVELOPMENT.md).
The M1 evidence records are indexed under [docs/evidence](../evidence/README.md).
