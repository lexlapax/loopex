# 0008: Technical depth

<a id="technical-depth"></a>
## Technical depth

Concept: [Owner succession recovery and runtime placement](0008-owner-succession-recovery-and-runtime-placement.md#concept).

<a id="technical-adr-0008-context"></a>
## The Two Information and Authority Gaps

Concept: [Context](0008-owner-succession-recovery-and-runtime-placement.md#concept-adr-0008-context).

ADR 0006's recovery sequence needs the exact transaction ID for candidate `T1`
before it can call `transaction_status(session_id, domain, T1)`. The sources
available after a complete runtime loss contain different information:

| Source | What survives | Why it is insufficient |
| --- | --- | --- |
| Runtime Control cache | Acquiring coordinator and candidate identity | It dies with the runtime or VM |
| Committed `owner_advanced` record | The last completed succession transaction | It names the incumbent, not an absent or in-flight successor |
| `transaction_status/3` | One exact transaction's terminal, absent, or unavailable state | It requires the missing transaction ID as input and intentionally does not enumerate |
| `ownership_head/2` | Durable owner epoch and journal version | It intentionally exposes no candidate transaction or incarnation capability |

Enumerating transaction IDs would widen a non-authorizing exact lookup into a
Store history API and still leave ordering and retention unspecified. Deriving
the candidate from an ephemeral generation or fresh incarnation is impossible
after those values die. A bounded durable locator is therefore the smallest
source that supplies the missing information.

The consequence race is distinct. Let Control A own epoch 1, let its ordinary
transaction commit, and delay only the result. Control B then commits succession
to epoch 2 through the same Store. A's runtime-local entry still says epoch 1 is
current because B cannot mutate A's memory. If A tests only that entry, it
accepts the delayed result. If A reads the Store head, B may still linearize
after the read and before A's local cache write. Without one global consequence
authority, process memory and Store ownership cannot be updated atomically.

<a id="technical-adr-0008-decision"></a>
## Exact Index, Recovery, and Placement Contract

Concept: [Decision](0008-owner-succession-recovery-and-runtime-placement.md#concept-adr-0008-decision).

### Stable succession identity

Runtime control identifies one logical create or resume succession by the
vision's runtime-command idempotency key:

```text
runtime_id + command_id
```

The Store binds that key to the command kind, target `session_id`, mutation
domain, exact canonical command bytes, and their versioned digest. The bounded
`succession_id` carried by staging and `advance_owner` is a canonical derivation
of the same runtime-scoped command identity; it is not a second idempotency
namespace. Reusing the command ID with another kind, session, canonical byte
string, or digest is a conflict even when a different session mutation domain
would otherwise be available.

The same logical create or resume re-presentation therefore finds the same
entry. A changed command ID is a new logical succession and cannot resolve
ambiguity belonging to the old one. The reference client retains and
re-presents a command ID only until it learns that logical command's durable
result. If the runtime that owned a completed command has died, the historical
result remains replayable but a fresh resume command ID is required to acquire a
new live coordinator. The Store, not the client, retains the private attempts
beneath each logical command.

### Attempt index

Each Store retains this private logical entry:

```text
key:
  runtime_id
  command_id

value:
  command_kind
  session_id
  mutation_domain
  canonical_command_bytes
  canonical_command_digest
  logical_status = open | completed
  attempt_generation
  candidate_tx_id
  stage_tx_id
  candidate_canonical_record_bytes
  candidate_canonical_mutation_digest
  completed_candidate_tx_id | nil
  completed_command_result | nil
```

The command and candidate canonical bytes and digests are compared on every
logical-command, stage, or candidate re-presentation. Equal digests never admit
different bytes. None of those bytes or digests is returned by the read API. An
open read returns `{open, attempt_generation, candidate_tx_id}`; a completed
read returns
`{completed, attempt_generation, completed_candidate_tx_id, command_result}` as
historical result identity, not owner authority. For M1 the bounded command
result is the existing `{:ok, session_id}` lifecycle result and contains no owner
incarnation or capability. It is `:absent` when no attempt has linearized for
that runtime command key and `:unavailable` when the Store cannot make an
authoritative observation.

`stage_owner_attempt` is a fourth transaction shape inside the existing Store
behaviour, not a fourth behaviour. It is a private session-ownership recovery
mutation in the same session mutation domain as `advance_owner`, serialized with
that domain's status reads, ownership-head reads, staging resolutions, and owner
compare-and-sets. It binds the key above, the prior attempt generation or
explicit absence, a fresh stage transaction ID, a fresh candidate transaction
ID, and the candidate's complete canonical bytes and digest. Its unknown-ID path
atomically compares the exact command binding, requires `logical_status = open`,
installs exactly the next generation and candidate, and retains its terminal
resolution. A stale expected generation or completed logical command is a
terminal non-commit for that new staging transaction. Exact re-presentation of a
known staging transaction validates every immutable scalar, exact byte string,
and digest before returning its retained outcome.

Staging changes only the private attempt index and the staging transaction's
terminal resolution. It does not advance `owner_epoch`, `journal_version`, or
outbox sequence; append a private session record; make an event eligible; or
alter the ownership head. Consequently a candidate built from an observed head
does not invalidate itself merely by being staged.

The mutation uses only ADR 0006's outcomes:

```text
committed(stage_tx_id)
not_committed(reason)
commit_unknown(stage_tx_id)
```

A `commit_unknown` staging result admits no `advance_owner`. Recovery has two
disjoint branches:

- A live staging caller that still holds the complete stage bindings resolves
  by exact re-presentation, as ADR 0006 requires. The index is not a weaker
  substitute for that comparison.
- After that caller is lost, its successor reads the index only to discover the
  exact candidate transaction ID. It does not convert the old caller's staging
  result into an acknowledgement. It queries the candidate status and follows
  status/head/fresh-CAS recovery without acquiring the old incarnation
  capability or canonical bytes. An absent or unavailable index leaves it
  fenced until the serialized staging/index history permits the next
  generation.

Two delayed staging requests that observed the same generation cannot both
install candidates. A caller whose candidate lost the staging compare-and-set
never submits that candidate to `advance_owner`.

Only one unresolved succession candidate may fence a session mutation domain at
a time, regardless of how many different command IDs could derive different
`succession_id` values. Runtime Control serializes succession commands for a
session, and the Store refuses a different logical succession while the domain
has an unresolved staged candidate. Recovery of an uncertain command therefore
re-presents that command's `succession_id`; inventing a new command ID cannot
bypass the fence.

The staged `advance_owner` transaction carries the same `succession_id`, attempt
generation, candidate transaction ID, and digest. Transaction resolution occurs
before current-index validation: if that scoped transaction ID already has a
terminal resolution, the Store validates all ADR 0006 immutable bindings and
returns the retained outcome regardless of a later attempt generation, logical
succession, or owner epoch. It does not apply ownership succession again.

Only an unknown `advance_owner` transaction's first presentation must find an
open logical succession whose current index generation points to that exact
candidate. An unstaged, index-superseded, completed-command, or mismatched
unknown candidate receives a retained terminal non-commit before the Store
applies ADR 0006's owner epoch and journal-version compare-and-set. If the
compare-and-set commits, the same atomic mutation advances ownership, retains
the transaction resolution, and changes that logical command from `open` to
`completed` with its candidate transaction ID and bounded command result. If it
does not commit, the Store retains that candidate's non-commit resolution but
leaves the logical command open so recovery may stage a later generation. Thus
a committed candidate and an open logical command cannot coexist in a correct
Store history.

Re-presenting a completed create or resume command returns its original durable
command result without staging, changing the owner head, or installing a local
route. If another logical succession later advances ownership, the older
command and its known committed `advance_owner` transaction remain truthful
historical results but confer no current authority. After whole-runtime loss, a
caller that needs a live coordinator submits a new resume command ID only after
the earlier command's result is known.

### Recovery algorithm

Initial acquisition with no indexed command entry first binds the exact logical
command, reads the ownership head, constructs a fresh candidate, stages
generation 1, and submits it only after staging is confirmed.

Recovery uses this loop:

1. Read and validate the exact command-bound attempt index.
2. If it is completed, return the original durable command result without an
   ownership mutation or local-route update.
3. If it is open, call `transaction_status/3` for its exact current candidate.
   If the command entry is absent, there is no prior candidate to authorize or
   replay and generation 1 may be staged.
4. A committed candidate must be accompanied by the same atomic completed index
   state; re-read that state and return its historical result. Any inconsistent
   committed/open observation is corruption or unavailability and fails closed.
5. On a terminal non-commit or `:absent`, read `ownership_head/2`. On
   `:unavailable`, keep command admission and mutation fenced.
6. Construct a new transaction and fresh owner incarnation, then stage it with
   a compare-and-set against the observed open attempt generation.
7. Submit `advance_owner` only if that exact unknown candidate owns the new index
   generation. Its commit atomically completes the logical command.
8. A stale stage or stale ownership head returns a terminal non-commit and
   restarts the loop from durable observations. No branch overwrites a newer
   attempt or ownership pair.

If the prior in-flight candidate linearizes after its status read, either it
atomically completes the command before the fresh stage and the stage is
refused, it changes the head before the new `advance_owner` and the new CAS is
refused, or the new index generation wins first and the old unknown candidate is
refused. If a third contender changes the attempt index or owner head after
either read, the corresponding final compare-and-set is refused. Repeated
coordinator or VM loss restarts at step 1 and therefore always finds either the
latest durably staged candidate or the command's single completed result.

### Catalogue and conformance

The production transition catalogue gains the attempt-staging transaction and
its declared fault points. Exact set equality among declared, injected, and
observed transition/fault pairs remains required. Store conformance adds:

- loss before staging linearization, after staging linearization, and during
  staging-result recovery;
- two candidates contending for one expected attempt generation;
- exact staging re-presentation and changed-binding conflict;
- command identity isolation by runtime, plus conflict when the same command ID
  is re-presented with another kind, session, domain, bytes, or digest;
- a staged candidate whose succession is terminal committed, terminal
  non-commit, absent, and unavailable;
- full loss again after staging the fresh candidate, proving the next recovery
  discovers that exact transaction;
- both orders of the absent/in-flight prior candidate and the fresh CAS;
- refusal of an unstaged or index-superseded unknown `advance_owner` candidate;
- exact re-presentation of a known terminal non-commit after the attempt index
  advances returns that retained non-commit rather than re-evaluating eligibility;
- exact re-presentation of a known committed `advance_owner` after a later
  logical succession returns the retained historical commit without changing
  the current owner;
- exact re-presentation of a completed create or resume returns its original
  result without advancing the epoch, and replay of an older completed command
  after a newer succession cannot displace or route around the current owner;
- a different `succession_id` refused while any candidate in the session
  mutation domain is unresolved, then admitted only after terminal resolution,
  with mutation sensitivity for both the domain fence and attempt-generation
  comparison; and
- resume through a different `runtime_id` refused without changing the attempt
  index, owner head, journal, or outbox.

The private attempt entry follows the same bounded plain-data rules as other
Store recovery rows. It never enters public events, snapshots, progress,
diagnostics, model context, jobs, or receipts.

### Runtime placement

The supported M1 placement key is the pair of Store identity and `runtime_id`.
Store identity is the logical authoritative session namespace addressed by one
or more adapter handles, never handle equality or a process pid. At most one
Runtime Control for that key is live and routing sessions. A session genesis
retains its creating runtime identity, and resume through a different runtime
identity is refused. The runtime identity is stable durable placement identity;
a replacement re-presents the same value and uses the same key only after the
old Control is quiescent or known dead.

This is a host placement invariant, not a registered-name implementation.
Loopex neither creates a VM-global lock nor infers a default runtime. The
multi-runtime selector starts independent references with distinct Store roots
and proves neither depends on a global name. Store conformance may still create
simultaneous raw succession contenders; that proves the port fence without
claiming that two complete Runtime Controls form a supported active-active
topology.

Every delayed-result consequence inside a supported runtime crosses the single
runtime-local post-commit fence. Durable public events remain Store outbox
truth, and any future effect still crosses current Store, operation, executor,
lease, and grant fences. A later active-active design must replace the placement
invariant with one globally ordered authority for routing and consequence
eligibility rather than treating two local caches as one.

<a id="technical-adr-0008-alternatives"></a>
## Alternative Analysis

Concept: [Alternatives](0008-owner-succession-recovery-and-runtime-placement.md#concept-adr-0008-alternatives).

**Caller-retained token.** The embedded caller supplies or persists every
candidate transaction ID and re-presents it after loss. It avoids the Store
index only by moving the index into every caller. It widens the lifecycle API,
couples clients to Store transaction mechanics, makes multi-client replacement
ambiguous, and still needs a protocol for loss before the next token reaches
durable caller state.

**Deterministic candidate IDs only.** A candidate ID derived from
`succession_id` and a fixed attempt number is recoverable, but ADR 0006 requires
a new ID after absence or terminal resolution. Repeated crashes therefore need
an unbounded attempt number. Without durable attempt generation, two processes
either reuse one ID with different incarnation bindings and conflict forever or
guess different generations and cannot know which one to query.

**Enumerate scoped transactions.** Let a successor list Store transaction
history and choose one. This exposes more private information than needed and
does not define which concurrent candidate is the owning operation. Adding the
stable indexed key is smaller and gives the answer directly.

**Store-head read before cache update.** This detects a succession that already
linearized, but not one that linearizes after the read and before the local
write. It can support diagnostics; it is not global consequence authority.

**Active-active consequence lease or router.** A Store-backed lease, durable
claim transaction, or globally ordered routing component can make multiple
Controls safe. It requires lease expiry or claim recovery, delivery/dispatch
handoff, partitions, and compatibility behavior. Those costs are justified by
a real multi-placement host, not M1's single-machine reference client.

<a id="technical-adr-0008-consequences"></a>
## Long-Term Costs and Benefits

Concept: [Consequences](0008-owner-succession-recovery-and-runtime-placement.md#concept-adr-0008-consequences).

### If accepted

- Owner acquisition adds one durable staging round trip and one small retained
  index entry per logical succession identity. Restart latency rises by that
  write before `advance_owner` can begin.
- Every Store adapter — local now, database or remote later — implements the
  same generation compare-and-set, terminal resolution, recovery read, and
  compaction rules. A backend that cannot do so cannot honestly implement the
  port.
- Transaction and fault catalogues grow by one mutation shape. This is
  deliberate evidence cost, not a new generic operation framework.
- Workstream A's previously green implementation must be revised and its Store
  selector re-proved before B can rejoin; Outcome 3 remains open until that
  expanded catalogue and conformance are green.
- Full-VM and remote-coordinator loss gain a stable recovery path. A future
  distributed runtime can reuse the attempt identity even though it must add a
  stronger placement authority.
- M1 remains explicitly active-passive at the runtime placement level. Hosts
  must preserve `runtime_id`, quiesce before handoff, accept the resulting
  downtime, and avoid split-brain startup. Operational documentation cannot
  imply active-active availability.
- Attempt indices, exact candidate bytes, and staging resolutions become part of
  backup and restore. Their growth requires an eventual compaction policy, and
  a future schema change must migrate unresolved identities without reopening
  them as new operations.
- A replayed completed create or resume reports its historical result but does
  not recreate a dead coordinator. After learning that result, a caller that
  still needs a live session pays for a fresh resume command and its staging
  write. This preserves command idempotency and makes recovery intent explicit.

### If rejected

- With no caller token, an absent or in-flight acquiring candidate is
  unidentifiable after memory loss. Keeping the domain fenced forever is safe
  but violates the required restart/recovery outcome.
- Reusing the last committed owner's transaction, guessing a new transaction,
  or treating `:absent` as terminal can race a delayed candidate and violates
  ADR 0006's exact recovery sequence.
- With no exclusive-placement limit and no global consequence mechanism, an old
  Control can retain a locally current route after another Control becomes the
  Store owner. Store commit fencing prevents a new stale journal write but does
  not make that old cache globally current or safe for authorization.
- Workstream B cannot establish its superseded-owner evidence, so C's model and
  executor dispatch must remain blocked. Proceeding would move the uncertainty
  to the first real effect, where the cost is duplicate or unauthorized work.

### What later active-active support must pay

A successor decision must name the global routing/consequence owner, show how
it survives partitions and delayed replies, specify handoff and lease or claim
recovery, retain current operation and executor fences, and prove upgrade and
rollback. The Store attempt index does not solve those questions and does not
pretend to; it only ensures that owner acquisition itself has recoverable
identity.

<a id="technical-adr-0008-compatibility"></a>
## Format, Migration, and Rollback Mechanics

Concept: [Compatibility, migration, and rollback](0008-owner-succession-recovery-and-runtime-placement.md#concept-adr-0008-compatibility).

The local durable format adds an attempt-index namespace and retained staging
resolutions, including exact staged candidate bytes and digests. M1 has no
installed data or compatibility freeze, so implementation tests start from
owned empty roots. M0 filesystem journals remain governed by M0 and are neither
read nor migrated.

The index is logically append-retained by runtime command identity for M1. Safe
compaction may replace historical staging resolutions only after the logical
succession is completed, while retaining its complete command binding and
historical result so exact re-presentation remains answerable. M1 need not
implement compaction; silently discarding identity and letting an old command
become a new succession is not compaction.

Rollback before closure removes the attempt transaction, index rows, selectors,
and dependent Runtime code together, then discards M1-owned test roots. Once an
adapter or data format is published, removing or changing the index requires a
successor ADR plus a migration that preserves unresolved and replayed
succession identities. Replacing exclusive placement with active-active
coordination likewise requires an additive successor decision and cannot be
inferred from a new host topology.
