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
digest and exact task generation. Resolve the exact genesis before prepare through the shared pure helper below.
Then use the host-private exact-genesis create variant with the original command
and payload; the normal create writer shares its validator. Commit `bind_parent` with the returned session ID before publishing
the handle or allowing prompts. The object also retains the closed delegation
declaration: `enabled`, ordered enabled `roles`, `max_children`, aggregate
`token_budget`, `child_bounds`, `max_tokens`, and per-role resolved
`context_token_budget`/`system_class_tokens`, with a canonical digest. It uses
the existing 1 MiB object cap; no core record receives these host fields.
Lost acknowledgements first use the read-only creation queries below. An exact
historical result finishes binding without create or activation. A proven absent
result may re-present the same retained creation only during an authorized live
parent-create command; helper recovery never reissues child creation. Missing
binding alone never proves that creation did not happen.
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
`reserve`, `recover_uncreated`, `child_created`, `child_prompted`, `stop`, `settle` or `bind_receipt` in run logs. The fields below define those mutation families; unknown fields,
versions or kinds refuse. Commit append then fsync before acknowledging.

The ledger's version-1 codec makes binary representation explicit. Host text
fields are valid UTF-8; digests/checksums are lowercase hex. Opaque core IDs,
fences and epochs that are binaries use canonical padded RFC 4648 base64 in
those schema-declared fields; integer epochs stay integers. Nested exact core
payloads in retained creation objects use exactly `{encoding:
"loopex.ledger.plain_etf.v1.base64", bytes, sha256}`: bytes is base64 of
`:erlang.term_to_binary(plain_payload, [:deterministic])`, without compression,
and sha256 binds those decoded ETF bytes. This private codec serializes the
plain map directly; it is not the tagged map tree used by protocol Canonical.
Bound decoded payloads by their owning core limit before parsing, reject compressed
ETF and noncanonical base64, decode with safe existing-atom rules, validate the
owning closed plain-data schema and require decoding to consume the complete
retained payload, with no trailing bytes. Integrity is the SHA-256 of the retained bytes;
do not require re-encoding equality across OTP releases. Deterministic encoding
is a writer recipe, not a cross-major byte-stability guarantee. Readers validate
retained bytes without replacing them. Cross-floor/current-pair fixtures prove
that each pair reads the other's retained object. This is a
private representation, never arbitrary-term acceptance or an atom-creation path.
The host invokes the shared genesis validator after decoding retained genesis.
Measure complete JSON after encoding, including base64 expansion, for object,
frame, registry and closing-credit limits. Test non-UTF-8 IDs/digests, malformed
base64, wrong hash, compressed/unsafe terms, mixed field encodings and oversize
encoded frames. Never JSON-encode raw canonical request bytes or opaque binaries.

The composition application owns this ledger; core has no ledger dependency.
Cap a parent-run log at 16 MiB and child count at 128; the byte cap can bind
before the child-count ceiling. `max_children` is an upper bound, not a promise
of that many successful reservations; validation accepts 1 through 128. Neither
ceiling promises that 128 maximal children fit. Calculate storage credit using
the maximum encoded payload and framing for each remaining mutation kind and
every permitted attempt receipt; do not multiply an average frame size.
Capacity refusal is
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
refund, publication or reissue. This fence includes settlement, receipt commits
and slot release for independent parents sharing that adapter. Best-effort child
abort/cleanup can continue without another ledger mutation; a later successful
cleanup does not clear the fence. Recovery must resolve the original transaction
before those mutations resume. The ledger retains:

- Catalog identity and parent-run allowance: child count, reserved tokens,
  settled reported/estimated usage and unknown charges.
- Logical operation identity `(parent_session_id, parent_run_id, operation_id)`,
  canonical task digest, frozen role configuration and absolute cutoff.
- Stable create/prompt command IDs, returned child session/run IDs, original
  executor receipt tuple, child terminal evidence and final parent receipt.
- The immutable resolved child-creation input, including cleanup grace, tool
  definitions, policy mode and configuration, in a mandatory digest-bound
  retained object installed before reservation under the same 1 MiB object rules
  as parent creation. Frames retain only its digest/reference, never inline
  base64 genesis; closing credit includes that fixed reference. Keep original options/input and their digest, plus the exact fully
  resolved v2/v3 genesis submitted at creation, including its normalized options
  and runtime_configuration. The parent creation object retains the same pair.
  Use one planned pure core helper, `Loopex.Runtime.SessionGenesis.normalize/1`,
  shared by the M7 create writer and both retained-genesis paths. It accepts the
  complete v2/v3 payload and returns `{:ok, normalized_genesis}` or
  `{:error, :invalid_session_genesis | :session_configuration_too_large}`; it
  inserts no defaults and performs no Store call. Composition must not duplicate
  its closed decoders or normalization. A second pure helper, `SessionGenesis.resolve/2`, accepts normalized session
  options and an explicit closed input map `{genesis_version,
  runtime_configuration, initial_configuration, tool_selection,
  policy_defer_mode}` for v3; v2 accepts only version and runtime configuration.
  Values are already resolved startup data, including actual cleanup grace and
  exact definitions; tool_selection omits artifact_read, which the resolver derives
  under ADR 0041; it performs no catalog, registry, Store or clock lookup.
  It constructs the payload then calls normalize/1, with the same result union.
  Control and composition share this resolver; no host copies its schema.
  The new host-private `Runtime.create_session_with_genesis/4` accepts runtime,
  command ID, original session options and that complete genesis. Its canonical
  create identity binds both original options and the exact genesis digest;
  conflicting genesis under one ID refuses. It checks duplicate identity first, validates options equality and the complete
  retained payload, and commits exactly that genesis without substituting current
  defaults. Fresh creation still validates registered generations and admitted
  host configuration; failure changes no prior mapping. It returns `{:ok, session_id}` on known creation, or the same
  `{:error, reason}` union as create_session/3, including commit_unknown and
  the existing conflict errors. Historical duplicates preserve their original result. This live-authorized variant is not exposed on the wire
  and is never called by helper recovery. Current startup defaults cannot
  reconstruct a different create input.

Use core's idempotent create command and returned session ID. Create and prompt
command IDs derive from the logical operation, excluding executor attempt.
`child_created` commits the returned ID, exact selected tools, policy mode and
configuration digest before the first prompt. Child context and system budgets
come from ADR 0049, validated against that child's exact model.
Different arguments under the same identity refuse. Retain each original
attempt tuple separately; operation deduplication does not make an old receipt
valid for a new attempt.

**Allowance.** ADR 0049 supplies the declaration retained with the parent
binding, not fresh invocation values on resume. `initialize` binds its digest
and effective limits once per parent run. A new run uses the same immutable
declaration with new counters; a resumed run reuses its existing counters. In one ledger transaction, check child count and aggregate remaining
tokens, reserve `min(child_token_budget, remaining)` and increment child count.
Commit before creating the child. Replays of that operation reuse its reservation.
Pass the reserved token threshold and configured turn/reply limits to the child.
Settle exactly once using retained terminal usage. Reported overshoot charges in
full, including automatic maintenance performed inside that child session;
separate maintenance reporting must not omit or double-charge it. Unknown usage
consumes the reservation and prevents a speculative refund.
Refund only conclusively unused tokens; child count is never refunded after
admission. Exhaustion denies the next child, not the parent's own remaining work.
Independent parent runs have independent allowances; resumed runs never reset one.

**Serial scope.** The one-active-helper limit applies to the parent session,
across run boundaries. Before reservation, the same serial adapter owner checks
all retained operations for that parent; an unresolved reservation, create,
prompt, stop, terminal or cleanup obligation still occupies its slot. A new
operation refuses while that slot is occupied; it is not queued. Replaying the
same logical operation uses its retained state. Release requires conclusive
terminal and cleanup evidence, settled accounting and persisted attempt receipts.
Before opening admission, use complete classification of retained parent
delegation intents across runs to establish the expected run/operation set, then
reconcile its existing binding/run logs. Enumerating present hashed log files
alone cannot establish completeness or an empty slot. The read-only query and
missing-log recovery rules below distinguish proven uncreated work from missing
child evidence. Corrupt or unavailable required coverage refuses the affected
parent's helper admission; it does not erase a known unrelated session's
classification. A session whose own provenance cannot be established cannot be
mutated as an ordinary session. Build the live occupied-slot view from
that validated reconciliation rather than rescanning history on each call. This
adds no separate persistent slot record or cross-log transaction. The exclusive
owner serializes reservation and release, including between runs.
Independent parent sessions have separate slots and may have live children at
the same time. The owner must not hold admission while waiting for a child's
provider work or cleanup. The per-ID unknown-cancel tombstones, overflow-only helper fence and startup
recovery gate below still apply; concurrency bypasses none of them.

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
at promotion. Retain a queued follow-up's own `deadline_at_ms` separately from
the predecessor's declared bounds. Promotion copies only inherited ordinary
limits and applies that follow-up's captured ceiling; omission never copies the
predecessor's absolute ceiling. This belongs to the already proposed admission
and normalized-command revision; old records retain their old promotion rules.
Steer accepts no bounds. This explicitly amends ADRs 0011/0017's
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
submit a previously unadmitted command. Serialize registration and cancellation
at the router for every forwarded job, local or helper, before forwarding or
reserve/create/prompt. A closed registry row contains `job_id`, `route` (`local`
or `helper`), `operation_id`, `attempt`, `session_id`, `run_id`,
`canonical_request_digest`, `origin_session_epoch`, `origin_executor_epoch`,
`executor_identity`, `fencing_token` and `cleanup_grace_ms`, all from the
validated job. Use lowercase hex for the digest and canonical padded RFC 4648 base64 for
opaque binary identity/fence fields in its JSON size projection, as in the
ledger codec below. Decode by field schema, never by guessing a string's shape. A repeated ID with different
binding refuses; an exact repeated job reuses the row. A row supplies routing
and cancellation bounds, never a launch permit or a replacement grant.

Keep rows only while execution/cancellation is active, capped at 4,096 rows and
8,388,608 canonical JSON bytes including keys. A local row is removed after its
callback returns and any concurrent cancel observer has finished. A helper row
may then leave this active table because its original job binding and receipts
remain in the validated durable helper index below. Capacity refuses a new
concurrent registration with `{:error, {:refused_before_effect,
:router_registration_capacity}}`; settlement reclaims capacity. This is not a
lifetime-throughput limit. Existing cancellation and receipt reads remain usable.
Recovery registers only unresolved helper jobs from the complete validated
intent/terminal join below before cancelling. Predecessor local jobs are never
re-registered: a conclusive Local receipt classifies them; otherwise use the
unknown-ID cancellation path. Historical helper receipts use the read index
without consuming active rows. An
incomplete classification refuses affected activation, never guesses a route.

Known local cancellation forwards unchanged to Local and does not close helper
admission. Known helper cancellation uses only its durable operation stop.
Derive the cancellation callback's absolute monotonic observation deadline once
on entry for helper cancellation from the registered parent job's `cleanup_grace_ms` and
`Executor.cancellation_bounds/1`, minus a fixed 250-ms reply margin. Core begins
its observation earlier; this margin permits bounded handoff delay, not a
scheduling guarantee. Local cancellation forwards immediately on a dedicated
path, never queued behind ledger or child-stop work. Local forwarding is a
pass-through bounded by core's original observation window, without this helper
reply margin or a second nested timeout. Nested helper waits spend the
remaining deadline; an answer that misses core's window remains unconfirmed.
Do not use the current runtime grace or renew the deadline between child waits.
The child may have a longer committed grace. Its cleanup can therefore finish
after the parent's observation window; return unconfirmed and preserve the
parent's unknown outcome without a refund or later terminal rewrite.

A cancel before registration has no bound digest and cannot create a durable
stop. First consult the validated helper job index and then a conclusive
validated Local receipt, before allocating a tombstone. For a genuinely unknown ID,
insert an incarnation-local tombstone for that exact ID before returning
unconfirmed or forwarding to Local. Every later registration of that ID refuses
launch with `{:error, {:refused_before_effect, :cancelled_before_registration}}`.
Tombstones are monotonic until that incarnation ends; none is evicted or cleared
by a later unknown result. They are capped separately at 4,096 entries and
8,388,608 encoded bytes. Only inability to retain a new tombstone closes the
incarnation-wide `helper_admission_closed` flag; that fence prevents every later
helper launch and requires full host restart. A late cancel of an evicted local
job therefore fences its ID, not unrelated parents. A conclusive validated Local
receipt can establish local classification, but absence alone cannot. Classified
helpers may still settle or cancel. Local request/receipt bytes remain unchanged.

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
to admit new helpers after tombstone overflow; it creates no durable launch
authority or false cleaned result. Establish that a predecessor producer
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
Classified cancellation also closes that operation's volatile launch fence
immediately. It does not close the incarnation-wide `helper_admission_closed`
flag; only tombstone-capacity exhaustion above does that. Best-effort
abort and cleanup of already known children continue while a stop commit is
unresolved; they do not authorize another ledger mutation or a cleaned receipt.

**Read-only recovery queries.** These are new M7 joins owned by core's runtime
Control process, not existing APIs or composition reads of adapter internals.
They require the exact `Runtime.t()` capability and validate the runtime's Store
scope. They never start/attach a coordinator, acquire an owner, append records,
resolve an unknown write by mutation, or dispatch provider/executor work. No
query result grants command or effect authority. Do not expose their private
payloads through wire schemas, progress or diagnostics. Unknown fields and
versions refuse; callers never construct atoms from returned input. Field lists
in braces below denote closed plain maps; tagged API results are tuples.

- `Runtime.effect_intents(runtime, session_id, cursor, limit)` accepts `nil`
  or the closed cursor `{version: 1, runtime_id, session_id, through_version,
  after_version}` and integer `limit` from 1 to 16. The first call captures
  `through_version` from `Store.ownership_head/3`; later calls scan that same
  immutable prefix through `Store.load_records/4`. Each call scans at most
  `limit` private records, advances past every scanned record, and returns
  `{:ok, {version: 1, runtime_id, session_id, through_version, scanned_through,
  rows, next_cursor}}`. Rows are a closed union: `{kind: "intent", journal_version,
  job}` for effect_intent_committed, with the validated plain JobRequest projection;
  or `{kind: "terminal", journal_version, run_id, tool_call_id, disposition}`.
  Terminal disposition is `refused_before_effect`, `receipt_committed` or
  `outcome_unknown`. Derive it from validated reducer facts: a failed
  tool_result_committed without an executor receipt proves pre-effect refusal;
  a committed executor receipt proves receipt_committed; other terminal facts
  without conclusive receipt remain outcome_unknown. Never infer it from reason
  text, model output, a missing ledger or volatile executor state. Emit terminal
  facts in journal order and join only by the exact run/tool-call identities to
  the earlier intent. Conflicting or unsupported joins are invalid_history.
  Exclude grants and owner-incarnation stamps. Return all executor kinds;
  composition selects the retained task generation after complete coverage.
  Empty `rows` does not end a scan: only `next_cursor: nil` proves that the
  captured prefix is complete. Preserve Store's 65,536-byte per-record bound;
  at most 16 rows and 1,114,112 uncompressed plain ETF bytes, measured with
  `:erlang.external_size(value, [:deterministic])` as the Store does, may leave one call. Charge the
  complete response envelope; stop before the cap with a cursor advancing only
  past scanned records. A single unrepresentable row is invalid_history, never
  skipped or an apparent complete page.
  This private API returns plain data, not the ledger JSON representation. Invalid cursor
  scope, ordering, gaps or unsupported records refuse; an available empty
  session differs from absent/unavailable history. The closed errors are
  `invalid_query`, `session_absent`, `history_unavailable`, `invalid_history`
  and `runtime_unavailable`, returned as `{:error, reason}`. Composition's
  startup recovery deadline applies between pages; timeout never means complete.
- `Runtime.creation_provenance(runtime, selector)` accepts exactly
  `{kind: :command, command_id}`, `{kind: :session, session_id}`, or
  `{kind: :runtime_page, cursor, limit}`. The first two are point queries. The new
  read-only Store callback `creation_provenance(reference, runtime_id, selector)`
  returns `{:historical, {version: 1, runtime_id, command_id, session_id,
  genesis_version, canonical_create_digest}}`, `:absent`, `:conflict`, or
  `:unavailable`. IDs retain existing Store limits, `genesis_version` is 2 or 3,
  and the digest is 64 lowercase hexadecimal characters. The complete historical
  projection is at most 65,536 encoded bytes. Read only an atomically committed
  create mapping; a cross-kind command or wrong-runtime session is `:conflict`.
  A mapping whose supported genesis/digest cannot be validated is unavailable.
  Build any reverse index from retained create transactions during replay; do
  not infer provenance from session-directory metadata or add a helper field.
  Runtime returns `{:ok, {:historical, projection} | :absent | :conflict |
  :store_unavailable | :unexpected}` and uses `{:error, :runtime_unavailable}`
  for Control loss; malformed selectors
  return `{:ok, :unexpected}`. Store unavailability/malformed output maps to
  `:store_unavailable`, never absence. This read callback extends ADR 0008 and
  the Store conformance suites without changing retained transaction bytes. A Store lacking this optional
  callback yields store_unavailable, never absence or incomplete coverage.
  The runtime-page selector extends that same Store callback. Limit is 1–16;
  cursor is nil or exactly `{version: 1, runtime_id, through_create_ordinal,
  after_create_ordinal}`. The first call captures the committed creation high-water
  ordinal; each page returns `{:page, {version: 1, runtime_id,
  through_create_ordinal, rows, next_cursor}}`. Rows are the historical projection
  above plus `create_ordinal`, ordered by that ordinal, each at most 65,536 bytes;
  complete response is at most 1,114,112 plain ETF bytes under the same size
  and early-stop rule as effect_intents. An unrepresentable row is unavailable. Runtime wraps a valid
  page in `{:ok, {:page, projection}}`. Only nil next_cursor proves complete
  coverage. Point queries never return pages. Invalid cursors return unexpected;
  incomplete/corrupt indexes return store_unavailable, never an empty page.
  Build ordinals from authoritative committed create transactions in replay order,
  scoped by runtime, preserving them on reopen. They are derived read indexes,
  not new session fields or directory-discovery authority. Both Stores must prove
  complete enumeration, empty/populated paging and concurrent-create cut behavior.
- `Runtime.lookup_create_result(runtime, command_id, session_options,
  retained_genesis)` adds a four-argument exact-history variant. Normalize and
  require `session_options` to equal the retained genesis `options`; validate
  the complete retained payload under its exact v2 or ADR 0044 v3 decoder and
  65,536-byte cap, then use `Store.create_session/3` only as the pure transaction
  constructor and `Store.runtime_command/2` as the read. Never call transact or
  insert current defaults, cleanup grace, definitions or provider mappings.
  Keep `/3`'s existing result union: `{:ok, {:historical, session_id} | :absent |
  :conflict | :store_unavailable | :unexpected}` or
  `{:error, :runtime_unavailable}`. Invalid supplied genesis returns unexpected;
  a different retained binding returns conflict. Keep `/3` and v2 history
  unchanged; parent/child binding recovery uses `/4`. This is the narrow
  ADR 0016 amendment for exact-genesis live creation and historical lookup,
  not permission to
  change an existing session's grace or to replay a historical create.

A helper-disabled ephemeral host uses Local directly and has no durable helper
history to classify. Durable hosts construct the router and complete the scan
below even when new delegation is disabled, so an old helper cannot be adopted
as ordinary work. A resumed parent with task uses its committed enabled binding
under ADR 0049; file defaults cannot disable it. No file flag proves a root
helper-free or skips classification. Retain measured
startup duration, pages/records read and peak buffers for a large-history fixture,
plus deadline exhaustion that refuses incomplete classification; no throughput
or service-time promise is introduced.

Before opening admission, the host completely enumerates committed creating
mappings with the runtime-page selector, then scans each enumerated session's
intent prefix. This yields the complete expected parent/operation set even when
host binding/log files are missing; Control's live-session map and the daemon's
discovery index cannot establish completeness. Account for all predecessor
producers/in-flight creates before capturing the startup cuts. After opening,
the serial adapter retains each newly authorized parent/helper create identity
and joins its committed mapping before exposing session mutations. An unseen
session triggers a complete creation-watermark delta scan and intent coverage
before classification, or remains fenced. New commits cannot be omitted by
reusing an old cut as current completeness proof.
The host then joins creating-command provenance to deterministic child-create
IDs derived from those intents, not only reservations whose logs happen to exist.
An ID match alone is insufficient: where retained creation input exists, its
exact genesis/create digest must also match. Conflicts remain fenced; a colliding
client ID never grants helper or ordinary mutation authority. During a still-accountable
in-flight create, defer mutation classification until the mapping is conclusive.
A helper's provenance remains helper-owned after settlement or log loss.
Unresolved evidence fences the affected parent/helper; it does not downgrade
that session to ordinary or erase a separately established unrelated identity.

**Expected operations.** Complete intent/terminal coverage excludes a task
intent with a matching committed pre-effect refusal from expected delegation
operations, child-ID classification and allowance reconstruction. Such a refusal
consumed no slot, requires no ledger record, and cannot fence its parent after
restart. Every other retained task intent remains expected; no terminal or an
unknown terminal is never proof of refusal. Receipt evidence and ledger joins
remain required for admitted work. Bounded paged/indexed construction joins
terminal rows at the same captured cut without collecting an unbounded history.

**Intent without retained reservation.** A missing run log, or an expected
operation absent from a valid recovered log prefix, is not automatically proof
of tampering or of zero prior reservations. After the predecessor producer is
gone and all sent creates are accounted for, query creation provenance by each
expected child-create command ID. A historical result without its required
reservation/creation input refuses as missing evidence; conflict, unavailable
or unexpected also refuse. Only conclusive absence permits the recovery below.
A present reservation still uses exact `/4` lookup; never replace it by this
weaker identity-only check. A corrupt log is not eligible for reconstruction.

Create a missing `initialize` from the immutable parent declaration, then commit
one `recover_uncreated` mutation per expected operation in journal order. Its
closed fields are `operation_identity`, `source_intent` (exactly `session_id`, `journal_version` and
`canonical_request_digest` as lowercase hex), derived `create_command_id` and `prompt_command_id`,
`reservation_state: "unknown"`, `reason: "adapter_recovery"`,
`child_session_id: null`, `child_run_id: null`, `reported_child_usage: 0`,
`count_charge: 1`, and `closing_credit_bytes`, plus `kind: "recover_uncreated"`. It uses the normal versioned frame.
The source reference resolves only the captured immutable intent row through the
bounded query above, validating operation and original attempt against that job;
never embed its binary canonical request bytes in JSON. Repeated recovery re-reads
and validates the same row before building a receipt; missing source refuses.
Use a transaction ID derived from that operation; replay returns the original
mutation without another charge. Absence proves no child/provider usage, but
cannot prove that the lost log never reserved a count slot. Therefore charge
one conservative count slot, never reconstruct zero counts or refresh allowance.
Reserve bounded credit for settlement and all original-attempt receipts before
this mutation. If expected operations exceed the retained count or storage
bounds, refuse that parent's recovery; do not clamp counts or discard intents.
This transition is already stopped, creates no launch permit, and may only
settle known no-child failure and bind the original-attempt receipt. It consumes
no child tokens and cannot later transition to reserve/create/prompt. The normal
stop-only recovery, conclusive-receipt and slot-release rules still apply.

On adapter startup, before opening routing/admission, mark every unfinished
predecessor operation stopped with reason adapter_recovery. A missing earlier
cancel record changes nothing: loss of the manager itself selects stop-only
recovery. Never infer permission from a snapshot saying the parent is active.
Conclusive completed evidence remains recoverable. Reconciliation uses the full
original operation/attempt/request digest/session epoch/executor epoch/identity/
fence tuple; solicited receipts use the current query ID and owner epoch.

| Retained gap | Stop-only recovery |
| --- | --- |
| Reservation; missing create result | Read `Runtime.lookup_create_result/4` with the original options and retained complete v2/v3 genesis; never replay create or rebuild with current runtime defaults. Exact history returns the original session despite changed current cleanup grace. Conflict identifies an incompatible retained binding; diagnose and preserve uncertainty, never treat it as absence. Unexpected/unavailable evidence also remains unknown. Account for the old producer and any in-flight create before treating absence as conclusive. |
| Child known; prompt acknowledgement missing | Never replay prompt. Inspect/rebuild the child through prepared recovery and abort any admitted work. An unprompted child remains unprompted. |
| Child unfinished | Abort through its live attachment, or use `Loopex.prepare_resume_session/3` to rebuild without scheduling, attach and admit an idempotent abort. Never call `activate_resume/1`; abort invalidates activation. Abandon an unused capability. |
| Child terminal; receipt missing | Retain the original attempt-bound receipt only from conclusive terminal/cleanup evidence, preserving failure or uncertainty and actual usage. |
| Receipt retained | Return its exact bytes through solicited reconciliation. Parent cancellation stays terminal. |

Host startup and every host admission route, including CLI, foreground
app-server and daemon resume and new-prompt paths, derive helper identity from validated host
binding/operation records, complete `effect_intents/4` coverage and
`creation_provenance/2`, checked against expected derived child-create command
IDs. Exact retained creation inputs use `lookup_create_result/4`. Complete classification precedes
activation and every session mutation admission, including commands through
existing attachments; missing/corrupt required records refuse instead of defaulting to
ordinary eager resume. A session-directory discovery index is not authority.
Recognized helpers use only their retained operation path. Ordinary client
mutations, including prompt, steer, follow-up, configure, standalone compact,
interaction response and abort, cannot independently adopt or control one;
eager resume also refuses. The owning adapter may submit its retained prompt
or abort/recovery commands under the existing operation contract. Read-only
attachment, inspection, history and artifact retrieval remain subject to ordinary
authority and grant no mutation route or provider authority. In particular,
standalone compaction of a settled child cannot spend provider work outside
its original operation and delegation allowance.
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

`retained_receipt/2` first routes by job ID through the helper index built from
complete validated intent coverage joined to ledger operation/attempt bindings.
Include every original attempt, including predecessor-incarnation jobs and
recover_uncreated receipts; an active row is not required. The index is a disposable, versioned derived cache over retained truth, with bounded paged construction and a bounded
4,096-entry/8-MiB cache. The ledger owns `lookup_job(reference, job_id)`: it reads
one derived entry keyed by SHA-256 of that ID under its private index directory,
then validates the referenced source-intent and ledger frame/receipt. Entries
are exactly `{version: 1, job, source_intent, run_log, frame_offset}`; job is the
original binding, and frame_offset is null before the first operation frame,
otherwise its validated offset. job is exactly the closed router-binding row
above, never full canonical_request_bytes. The directory is job-index-v1 under
the private delegation runtime directory. Entries contain no independent receipt facts,
at most 65,536 JSON bytes; they are installed atomically under the exclusive host
lease. They grant no authority and are not another journal. Rebuild the complete
index from validated intent/ledger coverage at startup; live registration updates
it before exposing work, and receipt binding updates it before publication.
An index-write failure before reservation returns refused_before_effect with
`helper_index_unavailable`; after possible work it returns effect_unresolved
and fences that operation until rebuild. It cannot suppress a committed receipt
or report absence. Discarding the cache is safe only while admission is closed;
rebuild from authoritative coverage before reopening.
Eviction preserves that point lookup. Missing/corrupt index or source coverage
means unresolved until rebuild, never absence or fallback to a local route. It carries no launch authority or independent
truth writer. Local receipt lookup is used only for a proven local route, or
to obtain a conclusive validated Local receipt for an unknown ID; unknown plus
Local absence stays `effect_unresolved`. A helper lookup returns its exact
original receipt tuple for core's current solicited reconciliation validation.
The callback is observational: it reads a retained receipt or returns the existing
unresolved/in-flight error;
it starts no worker and commits no stop, create, prompt or recovery mutation.
Startup recovery and cancel perform those actions separately. Missing receipt
is not proof of no dispatch and cannot become `absent` for an unresolved
operation. Stale unsolicited results are rejected. A solicited valid terminal
receipt may preserve an earlier fact without reopening the parent run.

<a id="technical-adr-0046-evidence"></a>
### Evidence

Concept: [Observable consequences](0046-child-session-tool.md#concept-adr-0046-consequences).

- Executor conformance and local-tool byte equivalence through the router.
  More than 4,096 sequential ordinary jobs reclaim active capacity; delayed
  local cancels do not fence unrelated helpers. Routed Local cancellation at
  its boundary matches direct cancellation with no helper-margin timeout. Pre-registration cancel blocks
  that ID, tombstone overflow fences helpers, and concurrent helper stops do not
  delay local cancel forwarding. Predecessor and recovered-no-child receipts
  route without active registration and retain their original binding.
  Exact resolved genesis is available before prepare; changed startup grace
  cannot alter live exact-genesis creation or historical lookup. Cross-toolchain
  ledger objects validate without re-encoding equality; exact-genesis /4 create
  and provenance fixtures cross both toolchain pairs and validate retained create
  digests through Store's own transaction recipe. Child frames contain
  object references and remain within the JSON frame cap.
- Pre-effect refusals for exhausted allowance, unknown role and occupied slot
  survive restart without count/token charge or parent recovery fencing; admitted
  missing-ledger work still takes conservative recovery. Empty intermediate pages
  cannot hide later terminal facts. Derived-cache loss/write failures and both
  helper-enabled and helper-disabled startup paths have bounded witnesses.
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
- Cancel before registration fences that exact ID; delayed execute cannot launch
  while unrelated helpers remain available. Tombstone overflow separately proves
  the incarnation-wide helper fence. Stale references cannot rebind and unknown
  cancellation is never falsely cleaned; Local receipt bytes stay unchanged.
- Registered or evicted local cancellation leaves unrelated helper admission
  open; helper cancellation remains operation-scoped. Fill active registry count
  and byte limits independently, prove refusal before forwarding, then settle and
  reuse capacity. Historical receipts use the durable index without active rows.
  Fill tombstone limits separately; only full restart resets that monotonic fence,
  preserving stop-only recovery and unresolved ledger truth.
- Core query conformance for both Stores: no write, owner acquisition,
  coordinator start or dispatch; bounded empty matching pages still advance;
  fixed high-water coverage, missing/corrupt history, wrong-runtime selectors,
  reverse creation lookup, complete runtime enumeration with absent binding/log
  files, changing watermarks and cross-kind conflict, plus exact Control loss.
- Crash after core intent but before host initialize/reserve; prove absent-create
  stop-only recovery, conservative count charge and zero provider work. Remove
  a reserve-only log before create: absence still cannot reset the count. Remove
  a log for a historical child: refuse. Crash after each reconstruction frame;
  replay never repeats its count, settlement or receipt. Changed startup grace
  does not break an exact retained-v2/v3 lookup; altered retained bytes conflict.
- Child lookup after cleanup-grace/default changes uses the retained create
  input; conflict/unavailability remains unknown. Every host refuses independent
  client mutation/resume adoption of both active and settled helper sessions,
  including each mutation through an existing attachment and standalone compact
  and configure after child settlement, before and after restart. Assert no
  provider call, configuration/checkpoint commit or ledger/accounting mutation;
  owner abort/recovery
  and read-only inspection still work through their respective paths.
- Maximum-frame capacity reserves completion credit and refuses further children
  before 128 when necessary. Unknown stop commits still permit bounded abort
  attempts without admitting new ledger mutations or launches.
- Repeated restart after a committed stop, at the log-cap boundary, appends no
  replacement stop and preserves the original reason, settlement and receipt.
- Parent observation can end before nested child cleanup completes. The parent
  stays unknown even if later receipt lookup finds completed child cleanup.
  Cover both equal grace values and a child whose committed grace exceeds the
  parent job's; the callback uses only the registered parent observation bound.
  Parent-job cancellation uses the executor receipt's causation rule; a child
  terminal before cancellation but before bind_receipt retains its proven fact.
- Repeated receipt lookup performs no mutations or dispatch; completed receipt
  preserves its exact original binding and cannot reopen the parent.
- Budget reservation, known overshoot, unknown charge, no double settlement or
  restart reset, exhausted-child-count refusal and separate visible totals.
- Two parent sessions have overlapping live helpers, with independent allowances
  and cancellation. A second helper in one parent refuses until its first is
  conclusively settled, including across run boundaries and restart with unknown
  cleanup. Replayed operations consume no second slot; no waiting helper queue
  or runtime-wide slot is introduced.
- Remove an older run's log while retaining its parent intent and historical
  child creation: reconstruction refuses, never invents an empty slot. Cancelling
  a classified helper in parent A does not prevent parent B's next otherwise
  admissible helper. Separately, inject an unknown ledger commit in A and prove
  the documented adapter-wide mutation fence also delays B's settlement.
- Edit every delegation declaration field and use `--no-helpers` before resume:
  retained effective limits and counters remain; conflicting explicit disable
  refuses. A new run initializes from the parent binding, not the edited file.
- Follow-up with no absolute ceiling after a predecessor with one does not inherit
  it; a supplied follow-up ceiling survives promotion/restart unchanged while
  ordinary limits retain their existing inheritance and legacy replay.
- Delayed admission at the absolute cutoff; parent cancellation, stuck child,
  stale receipt, cleanup uncertainty and parent owner succession.
- Real provider parent on A and child on B; investigation and review fixtures
  return known findings with unchanged helper workspace bytes.

<a id="technical-adr-0046-compatibility"></a>
### Compatibility Mechanics and Alternatives

Concept: [Compatibility and rollback](0046-child-session-tool.md#concept-adr-0046-compatibility).

The authored-bound command revision and public deadline fields join
ADR 0044's foreground `/3` and daemon `/4` wire contracts. The M7 negotiation
matrix refuses old offers before session work; it does not reinterpret
historical normalized-command bytes or grant controller authority.

Version, bound and validate every ledger record before use. Unsupported or
malformed state opens read-only for diagnosis or refuses before mutation and
dispatch. Back up the complete quiescent host root, including ledger and child
sessions, before upgrade. Downgrade restores that backup; it cannot erase or
replay unresolved operations. Implement the ledger format specified above with replay and corruption fixtures;
record actual fixture identities before integration. A queue, parallel children
within one parent session, writable children, nested delegation
and charging children to core parent counters are outside this decision.
