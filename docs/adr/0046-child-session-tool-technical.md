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
`reserve`, `child_created`, `child_prompted`, `settle` or `bind_receipt` in run logs. The fields below define those mutation families; unknown fields,
versions or kinds refuse. Commit append then fsync before acknowledging.

Cap a parent-run log at 16 MiB and child count at 128; capacity refusal is
definite before append, never a hidden eviction. Before reserving a child,
reserve disk-log capacity for the maximum bounded create, prompt, settlement
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
its original result after the timestamp passes. A fresh expired command refuses
before admission. A queued follow-up retains its explicitly supplied ceiling
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

**Result.** Apply ADR 0041's 2,048-encoded-byte model projection to helper results
as well, retaining larger available text through the artifact path. Retain up to
16 KiB of final child text with an explicit truncation
indicator and child identity for full replay. The bounded structured trailer
contains role/catalog digest, model, child identity, outcome, reported/estimated
usage and separate parent/delegation/combined totals. A conclusive failed,
cancelled or bound-reached terminal is a failed tool result. A conclusive `failed(model_call_failed)` child terminal remains a known failed
tool result, including ADR 0018's settled provider-ambiguity failure. Unknown
child lifecycle, unresolved effect or cleanup evidence remains unknown; absence
of a terminal cannot manufacture a known failure.

**Recovery.** Cover reservation→create→prompt→terminal→receipt as separate gaps.
Re-present identical public command IDs after missing acknowledgements. Reconcile
from retained child evidence and the full original operation/attempt/request
digest/session epoch/executor epoch/identity/fence tuple. Solicit receipts with
the current reconciliation query ID and current owner epoch. Resume the existing
child only under ordinary model/effect ambiguity rules. Absence of a receipt,
missing ledger state or an unfinished child never proves that dispatch did not
happen. Stale unsolicited results are rejected. A currently solicited, fully validated
receipt may preserve a terminal fact after cancellation without reopening the
cancelled parent run or granting new authority.

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
  unresolved ledger commit fences dispatch, exactly one child and one prompt.
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
