<a id="technical-depth"></a>
## Technical depth

Concept: [Serial read-only child sessions](0046-child-session-tool.md#concept).

<a id="technical-adr-0046-decision"></a>
### Contract

Concept: [Context and decision](0046-child-session-tool.md#concept-adr-0046-decision).

The composition routes `loopex.task` to this adapter and existing tools to the
local executor through the existing executor behaviour. Policy, grant validation,
intent-before-dispatch, fencing and receipt validation are unchanged. The router
must preserve the existing local executor's request and receipt bytes.

**Construction.** Acquire the host placement lease, open host state and the
local executor, then start the composite executor router closed. Start the
runtime with that router and the exact retained reference tool generations.
Bind the router once to that runtime reference/incarnation, resolve retained
parent bindings, then open admission and expose the runtime. Identical binding
is idempotent; binding a different runtime refuses. Recovery dispatch also waits
for binding. Runtime loss closes routing. Failed startup unwinds resources.
No global lookup or unbound router may launch a helper.

**Session selection.** Creation accepts immutable `active_tools` entries of
`{tool_id, tool_version, definition_digest}` and `policy_defer_mode` of `admit`
or `refuse`. Omitted tools resolve the runtime defaults; explicit empty means
none. Omitted mode is `admit`. Validate registered definitions, exact digests
and unique model-visible names; retain full normalized definitions and mappings
in ADR 0044's genesis. Helpers select exactly read/grep/find/ls and `refuse`.
The existing policy evaluator runs once, preserving allow/deny and normalizing
defer to `interaction_unsupported` before an interaction is committed. Neither
question answers nor parent grants become child authority. Configure cannot
change tools or mode. Recovery uses retained selections before any dispatch.
Check duplicate create identity before expanding current defaults; retain the
original input digest separately from the resolved configuration, so a replay
cannot select a changed default or allocate a second session.

The fixed `loopex.task` version `1.0.0` is class `effect`, disabled by default,
with `effect_class: external_effect` because it creates provider work, and
`idempotency_class: reconcile_then_retry`. Its explicit budgets are
`wall_time_ms: 600000`, `output_bytes: 32768`, `artifact_bytes: 8388608`.
Do not inherit the generic 120,000-ms default. Child deadline configuration
cannot exceed this fixed wall ceiling and must be displayed by effective
inspection. Parent deadlines and dispatch delay can make the effective cutoff
earlier. Its closed arguments are:

| Argument | Bound |
| --- | --- |
| `role` | Required enabled role name matching `[a-z][a-z0-9_-]{0,63}` |
| `description` | Nonempty UTF-8, at most 256 bytes |
| `prompt` | Nonempty UTF-8, at most 16 KiB |

The host retains the enabled role catalog, exact instruction bytes/digests,
provider/model settings and delegation limits before publishing the parent
handle. One fixed `loopex.task` generation has the bounded role string schema,
not a per-catalog enum. Validate membership against the retained catalog before
reservation. Frozen enabled-role names and catalog digest are host environment
facts under ADR 0042, preserved during instruction reconfiguration. Catalog
changes affect new sessions only. Startup preloads exact retained reference
generations through the reserved reference-tool path, never a public registry
call that bypasses namespace restrictions. No per-call
model, credential, policy, tool, workspace or budget override is admitted.
Missing or corrupt retained catalog data refuses dispatch; current files are
never recovery substitutes.

**Private ledger.** Version 1 lives under the host's state root and is scoped by
runtime identity and parent session/run. One serial adapter owner and an
exclusive store lock protect it. A host-private ledger module provides
`open`, `commit(tx_id, expected_version, mutation)`, `lookup(tx_id)` and `read`.
It does not extend `Loopex.Store`'s closed transaction union or manufacture a
session journal. Reuse only independent file/framing helpers where suitable.

The ledger directory is `delegation/<runtime-id-sha256>/` under the state root,
owned under the same exclusive host placement lease. Reject symlinks and paths
outside that root. Never recover a live writer's file. An immutable catalog is
canonical JSON at most 1 MiB, content-addressed by SHA-256, installed by fsynced
temporary-file rename and directory fsync before its reference is committed.
A parent-binding log is keyed by runtime identity and original parent-create
command ID. Retain an immutable resolved creation object, at most 1 MiB, before
`prepare_parent` commits its digest, original command/input digest, catalog
digest and exact task generation. Then call core create with that exact command
and payload. Commit `bind_parent` with the returned session ID before publishing
the handle or allowing prompts. Lost acknowledgements replay that same create,
then finish binding; missing binding never proves that creation did not happen.
Unresolved binding fences parent admission through the host. Delegation checks
session → binding → catalog → role; changed files cannot repair missing state.
The two-transition binding log has a 1 MiB cap and reserves completion space
before prepare. It uses the same framing, fsync and unknown-resolution rules as
the run logs. No core Store transaction gains host catalog data.

Each parent-run log is named by the SHA-256 of its canonical identity tuple.
Its version-1 file header precedes frames with a fixed header containing magic,
version, big-endian 32-bit payload length and a SHA-256 header checksum, then
canonical UTF-8 JSON payload and a 32-byte SHA-256 payload digest. Validate the
complete header checksum before using its length. A complete invalid header
refuses; it cannot be reclassified as an interrupted append. Payload is at
most 65,536 bytes. Each frame is one atomic logical transaction containing
`version`, `tx_id`, `expected_version`, `mutation_digest`, and one mutation of
kind `prepare_parent` or `bind_parent` in binding logs, or `initialize`,
`reserve`, `child_created`, `child_prompted`, `stop`, `settle` or `bind_receipt` in run logs. The fields below define those mutation families; unknown fields,
versions or kinds refuse. Commit append then fsync before acknowledging.

The composition application owns this ledger; core has no ledger dependency.
Cap a parent-run log at 16 MiB and child count at 128; the byte cap can bind
before the child-count ceiling. Neither ceiling promises that 128 maximal
children fit. Capacity refusal is
definite before append, never a hidden eviction. Before reserving a child,
reserve disk-log capacity for the maximum bounded create, prompt, stop, settlement
and final-receipt frames. Persist this storage credit with the token reservation.
Other appends cannot consume its closing-record credit. Release it only after
conclusive terminal settlement and receipt persistence. Insufficient capacity
refuses before child creation, so the cap never prevents recording admitted
work's terminal evidence. Replay validates the whole
prefix, identity, sequence and digest. Only an incomplete final frame may be
removed after exclusive recovery establishes the previous writer is gone;
a complete invalid header, payload checksum mismatch or interior corruption
refuses, never skips. Test every header/length-byte corruption separately from
genuine crash-truncated headers and payloads. Transaction IDs
index original results: identical replay returns the result, conflicting reuse
refuses. `lookup` returns committed, proven absent after complete recovery, or
unknown. A partial write/fsync error returns unknown until replay resolves it.
No selective catalog/ledger collection is added in M7. Host retirement follows
existing policy over the complete root, including parent bindings, catalogs,
children and receipts. Parent completion or quiescence alone cannot retire
unresolved evidence needed for recovery or idempotency. Do not write another
session's journal. A ledger `commit_unknown` fences this
adapter's mutation domain until resolved; it cannot authorize child creation,
refund, publication or reissue. The ledger retains:

- Catalog identity and parent-run allowance: child count, reserved tokens,
  settled reported/estimated usage and unknown charges.
- Logical operation identity `(parent_session_id, parent_run_id, operation_id)`,
  canonical task digest, frozen role configuration and absolute cutoff.
- Stable create/prompt command IDs, returned child session/run IDs, original
  executor receipt tuple, child terminal evidence and final parent receipt.
- The immutable resolved child-creation input, including cleanup grace, tool
  definitions, policy mode and configuration, or a digest-bound retained object
  installed before reservation under the same 1 MiB object rules as parent
  creation. Keep the original command input and its digest as well as resolved
  values. Current startup defaults cannot reconstruct a different create input.

Use core's idempotent create command and returned session ID. Create and prompt
command IDs derive from the logical operation, excluding executor attempt.
`child_created` commits the returned ID, exact selected tools, policy mode and
configuration digest before the first prompt. Child context and system budgets
come from ADR 0049, validated against that child's exact model.
Different arguments under the same identity refuse. Retain each original
attempt tuple separately; operation deduplication does not make an old receipt
valid for a new attempt.

**Allowance.** All limits come explicitly from ADR 0049. Initialize once per
parent run. In one ledger transaction, check child count and aggregate remaining
tokens, reserve `min(child_token_budget, remaining)` and increment child count.
Commit before creating the child. Replays of that operation reuse its reservation.
Pass the reserved token threshold and configured turn/reply limits to the child.
Settle exactly once using retained terminal usage. Reported overshoot charges in
full; unknown usage consumes the reservation and prevents a speculative refund.
Refund only conclusively unused tokens; child count is never refunded after
admission. Exhaustion denies the next child, not the parent's own remaining work.
Independent parent runs have independent allowances; resumed runs never reset one.

**Deadline.** Persist `min(parent_job.effective_job_deadline, admission_time + child_deadline_ms)`
as the absolute cutoff before create. Extend the generic run-bound contract
with optional `bounds.deadline_at_ms` on prompt and follow-up commands: a
positive integer absolute UTC millisecond timestamp no greater than 2^53−1,
covered by canonical command identity and committed at admission. Check command
identity/replay before clock validation, so a duplicate admitted command keeps
its original result after the timestamp passes. A fresh expired command records
its ordinary idempotent refusal before any run admission. Resolution of an
uncertain admission/refusal commit uses its original identity and digest; it
never reevaluates the clock as a new command. A queued follow-up retains its explicitly supplied ceiling
unchanged through promotion; absent means no inherited ceiling from its parent
run. If an admitted run or follow-up expires before first staging, settle the
ordinary deadline terminal without provider dispatch, rather than changing its
already committed admission disposition. Effective deadline is the earlier of that ceiling and the
existing relative deadline; all staging, dispatch, timers and recovery obey it.
The ceiling is part of the generic bounds/schema revision and exact request
staging deadline; it never authorizes work past another tighter bound. The coordinator uses a monotonic timer
for a live owner and recomputes remaining time from the persisted absolute
ceiling after recovery, like existing durable deadlines. Owner loss cannot
extend it. The adapter passes that exact ceiling in its idempotent prompt and
also aborts on its own cutoff. Test loss of the adapter owner immediately before
the cutoff and delayed recovery while the child owner remains alive. No core
parent identity or child-specific deadline logic is introduced. Cancellation or expiry
cannot publish a successful receipt while cleanup is uncertain.

The new normalized-command revision binds exact authored prompt bounds,
including omission, before defaults are resolved. Prompt overrides remain
partial and closed to `max_turns`, `token_budget`, `deadline_ms` and
`deadline_at_ms`. Follow-up `bounds` is closed to `deadline_at_ms` alone;
ordinary limits inherit under ADRs 0013/0017 and do not read current defaults
at promotion. Steer accepts no bounds. This explicitly amends ADRs 0011/0017's
old normalized identity, which omitted ordinary bound configuration. Resolve
effective prompt defaults once at admission, retain them separately, and
check duplicate command facts before resolving them again. Preserve old
normalized bytes/digests and their duplicate behavior. Test changed authored
limits under one new ID, identical replay after defaults change, follow-up
inheritance and old-command replay.

**Result.** Apply ADR 0041's 2,048-encoded-byte model projection to helper results
as well, retaining larger available text through the artifact path. Retain up to
16 KiB of final child text with an explicit truncation
indicator and child identity for full replay. The bounded structured trailer
contains role/catalog digest, model, child identity, outcome, reported/estimated
usage and separate parent/delegation/combined totals. A conclusive failed,
cancelled or bound-reached child terminal is a failed model-facing tool result
when the parent job remains active. Parent-job cancellation or its cutoff uses
the executor contract's cancelled receipt only when cancellation caused
termination and cleanup is confirmed. Preserve a validated completed or failed
child fact that won before cancellation, even if receipt persistence follows
the cancellation. Uncertain cleanup cannot produce a cancelled receipt. Keep these executor dispositions
distinct from the child outcome carried by the model-facing result.
A conclusive `failed(model_call_failed)` child terminal remains a known failed
tool result, including ADR 0018's settled provider-ambiguity failure. Unknown
child lifecycle, unresolved effect or cleanup evidence remains unknown; absence
of a terminal cannot manufacture a known failure.

**Stop fence and recovery.** Only live `execute/5` handling a validated current
executor job may reserve/create/prompt. One host mutation producer serializes
those calls with cancellation; no detached worker keeps a reusable launch permit.
Stable command IDs deduplicate live calls, but do not authorize recovery to
submit a previously unadmitted command. Serialize job registration and cancel
at the router before handing a helper launch to its mutation producer. Register
the job ID and validated original tuple before reserve/create/prompt. A known
helper cancel uses its durable operation stop. An unclassified job ID has no
bound digest and cannot create a durable stop, as ADR 0016 requires. It closes
a single volatile `helper_admission_closed` flag for this router incarnation
and returns unconfirmed unless the unchanged local executor establishes its
own conclusive receipt. The closed flag prevents every later helper launch,
including a delayed execute that had not registered when cancel arrived; it
never reopens in this incarnation. Local-tool routing/receipt bytes remain
unchanged. Existing known helpers can settle or be cancelled normally.

The router reference names its exact PID/incarnation, never a global alias that
silently rebinds after failure. A replacement requires normal host construction
and a fresh runtime/router incarnation: restart the full composition and reopen
the local executor before constructing the replacement runtime/router. Reuse
that executor's identity/epoch; do not invent a router-only job epoch or
translate local jobs/receipts. Local's existing identity/epoch may be constant;
do not claim that reopening it increments a numeric epoch. The exact process
references and runtime incarnation prevent rebinding stale calls. No
manager-only transparent rebind is allowed.
Stale references/jobs cannot reach it as fresh execution. Startup reconciles predecessor ledgers before admission as
specified below. This conservative unknown-cancel case may require host restart
to admit new helpers; it does not add an unbound durable tombstone or return a
false cleaned result. Establish that a predecessor producer
is gone and account for calls it already sent before taking over its operation.

The monotonic `stop` mutation carries the logical operation identity, original
attempt binding, stop transaction ID and a closed reason: `cancel`, `cutoff` or
`adapter_recovery`. Stop is write-once per logical operation. A later cancel,
cutoff or startup returns the original stop without appending or replacing its
reason. Resolve an unknown first stop by its retained transaction identity
before deciding whether it exists. Settlement is also write-once; each admitted
attempt has at most one retained receipt, with identical replay returning the
original bytes and conflicting replay refusing. Closing credit accounts for
all admitted attempt receipts before their admission.
After stop commits, no create/prompt/activation transition is
allowed for that operation, including under a later execute attempt. Cleanup,
terminal evidence and receipt commitment remain allowed. `cancel/2` enters the
same owner, commits stop, then cleans up. If a launch call won first, account for
its admission and cleanup rather than claiming it never happened. An unresolved
stop commit fences launch, refund and successful publication. Its reserved
closing-record credit prevents a full log from blocking this fact.
Cancellation also closes the volatile launch fence immediately. Best-effort
abort and cleanup of already known children continue while a stop commit is
unresolved; they do not authorize another ledger mutation or a cleaned receipt.

On adapter startup, before opening routing/admission, mark every unfinished
predecessor operation stopped with reason adapter_recovery. A missing earlier
cancel record changes nothing: loss of the manager itself selects stop-only
recovery. Never infer permission from a snapshot saying the parent is active.
Conclusive completed evidence remains recoverable. Reconciliation uses the full
original operation/attempt/request digest/session epoch/executor epoch/identity/
fence tuple; solicited receipts use the current query ID and owner epoch.

| Retained gap | Stop-only recovery |
| --- | --- |
| Reservation; missing create result | Read `Runtime.lookup_create_result/3` with the exact retained original creation input; never replay create. Preserve cleanup grace and all resolved creation settings. Incompatible reconstruction, conflict, unexpected replies and unavailable evidence remain unknown. Account for the old producer and any in-flight create before treating absence as conclusive. |
| Child known; prompt acknowledgement missing | Never replay prompt. Inspect/rebuild the child through prepared recovery and abort any admitted work. An unprompted child remains unprompted. |
| Child unfinished | Abort through its live attachment, or use `Loopex.prepare_resume_session/3` to rebuild without scheduling, attach and admit an idempotent abort. Never call `activate_resume/1`; abort invalidates activation. Abandon an unused capability. |
| Child terminal; receipt missing | Retain the original attempt-bound receipt only from conclusive terminal/cleanup evidence, preserving failure or uncertainty and actual usage. |
| Receipt retained | Return its exact bytes through solicited reconciliation. Parent cancellation stays terminal. |

Host startup and every host admission route, including CLI, foreground
app-server and daemon resume and new-prompt paths, derive helper identity from validated host
binding/operation records and read-only create-result resolution, checked
against retained parent delegation intents. Complete classification precedes
activation; missing/corrupt required records refuse instead of defaulting to
ordinary eager resume. A session-directory discovery index is not authority.
Recognized helpers use only their retained operation path. Ordinary client
prompt admission or eager resume cannot independently adopt or activate one.
Classification is complete before exposing those operations, even after a child
has settled. Missing required classification refuses. This is host enforcement;
core still has no parent or helper field.
Startup completes bounded stop/cleanup/reconciliation for each unfinished
operation before activating its affected parent. Each operation uses its
original retained cleanup grace; unresolved
work at that bound remains unknown and cannot be launched by later activation.
A
live child can continue until its abort is admitted. The existing absolute
cutoff bounds it while the adapter is unavailable. Confirm every launch call,
child admission and provider/tool cleanup before answering cleaned. An
unaccounted call, live child, callback failure or uncertain cleanup answers
unconfirmed/unknown; no success or speculative usage refund conceals that gap.

`retained_receipt/2` is observational, as the executor contract requires. It
reads a retained receipt or returns the existing unresolved/in-flight error;
it starts no worker and commits no stop, create, prompt or recovery mutation.
Startup recovery and cancel perform those actions separately. Missing receipt
is not proof of no dispatch and cannot become `absent` for an unresolved
operation. Stale unsolicited results are rejected. A solicited valid terminal
receipt may preserve an earlier fact without reopening the parent run.

<a id="technical-adr-0046-evidence"></a>
### Evidence

Concept: [Observable consequences](0046-child-session-tool.md#concept-adr-0046-consequences).

- Executor conformance and local-tool byte equivalence through the router.
- Fresh child context, role-catalog immutability across config edits/restart,
  cross-provider selection and rejection of unknown/disabled roles.
- Per-session tool selection, immutable policy mode, allow/deny/defer, no
  nesting/questions or widening; duplicate creation after defaults change.
- Router binding/startup failure, retained parent creation across both stores,
  missing catalogs and reserved-generation reconstruction before recovery.
- Store/process failure before and after every ledger and child-command boundary;
  unresolved ledger commit fences dispatch, at most one child and one prompt.
- Crash after child_created but before prompt, parent cancellation while the
  manager is down, then recovery: zero prompt submissions/provider dispatches.
- Both sides of create/prompt acknowledgement, live versus dormant child,
  stop fsync uncertainty, cancel/launch ordering and blocked eager activation.
- Cancel before execute registration closes helper admission; a delayed execute
  cannot launch, stale references cannot rebind, and local-tool receipt bytes
  remain unchanged. Unknown job cancellation is never falsely cleaned.
- Cancelling an unclassified local job can close helper admission even if the
  local executor later proves cleanup. Record that availability consequence.
- Child lookup after cleanup-grace/default changes uses the retained create
  input; conflict/unavailability remains unknown. Every host refuses independent
  prompt/resume adoption of both active and settled helper sessions.
- Maximum-frame capacity reserves completion credit and refuses further children
  before 128 when necessary. Unknown stop commits still permit bounded abort
  attempts without admitting new ledger mutations or launches.
- Repeated restart after a committed stop, at the log-cap boundary, appends no
  replacement stop and preserves the original reason, settlement and receipt.
- Parent observation can end before nested child cleanup completes. The parent
  stays unknown even if later receipt lookup finds completed child cleanup.
  Parent-job cancellation uses the executor receipt's causation rule; a child
  terminal before cancellation but before bind_receipt retains its proven fact.
- Repeated receipt lookup performs no mutations or dispatch; completed receipt
  preserves its exact original binding and cannot reopen the parent.
- Budget reservation, known overshoot, unknown charge, no double settlement or
  restart reset, exhausted-child-count refusal and separate visible totals.
- Delayed admission at the absolute cutoff; parent cancellation, stuck child,
  stale receipt, cleanup uncertainty and parent owner succession.
- Real provider parent on A and child on B; investigation and review fixtures
  return known findings with unchanged helper workspace bytes.

<a id="technical-adr-0046-compatibility"></a>
### Compatibility Mechanics and Alternatives

Concept: [Compatibility and rollback](0046-child-session-tool.md#concept-adr-0046-compatibility).

Version, bound and validate every ledger record before use. Unsupported or
malformed state opens read-only for diagnosis or refuses before mutation and
dispatch. Back up the complete quiescent host root, including ledger and child
sessions, before upgrade. Downgrade restores that backup; it cannot erase or
replay unresolved operations. Implement the ledger format specified above with replay and corruption fixtures;
record actual fixture identities before integration. A queue, parallel workers, writable children, nested delegation
and charging children to core parent counters are outside this decision.
