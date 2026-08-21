# 0006: Technical depth

<a id="technical-depth"></a>
## Technical depth

Concept: [Store transaction contract and owner epoch](0006-store-transaction-and-owner-epoch.md#concept).

<a id="technical-adr-0006-context"></a>
## Why Replay-Only Fencing Fails

Concept: [Context](0006-store-transaction-and-owner-epoch.md#concept-adr-0006-context).

Take two coordinators for one session. `A` owns epoch 4. `A` is partitioned,
paused, or simply slow. `B` takes over, durably advances the session to epoch 5,
and begins admitting commands. `A` has not noticed and issues a transaction.

Under replay-only rejection the store accepts `A`'s transaction and returns
`committed`. The stale records are now durable fact and eligible work: the
outbox/event-hub path can publish them and the dispatch path can present their
intent. A current executor fence may refuse that dispatch, but it cannot retract
a published fact or make the stale journal record truthful; if the downstream
fence has not advanced independently, the tool can run too. Some time later a
replay reads the journal, notices that a record carries epoch 4 after a record
carrying epoch 5, and discards it.

The history is now superficially correct and the world is not. A published fact
may already have been consumed and an effect may already have run; neither is
undone by dropping a row. Replay repairs the record of what happened; it cannot
repair what happened.

This is exactly the ordering the durability rule fixes: intent commits before
dispatch, and facts commit before publication. The commit *is* the fence. Moving
the check after the commit inverts the rule and leaves the interval between them
unprotected, which is the interval where every observable side effect happens.

`M0`'s deferred race is the same shape one level down. Reading the sentinel and
writing the file are two operations, so ownership can change between them. `M0`
narrowed the window to a triple-identity check under a single-machine assumption
and recorded the residue. A port reached over a network cannot narrow it that way
and must close it instead.

<a id="technical-adr-0006-decision"></a>
## Exact Contract, Schema, and Conformance Obligations

Concept: [Decision](0006-store-transaction-and-owner-epoch.md#concept-adr-0006-decision).

An ordinary commit request binds, at minimum:

```text
session_id
expected_owner_epoch      the epoch the caller believes it owns
expected_owner_incarnation_id
                          the fresh plain-data capability of this coordinator
                          incarnation
expected_journal_version  the version the caller believes it is extending
tx_id                     allocated before the call, recoverable from the
                          owning command or operation identity
canonical_record_bytes    exact bounded canonical encoding of the complete
                          ordered record set
canonical_mutation_digest digest of those exact canonical bytes, bound to tx_id
records                   the transaction's atomic record set
```

The store resolves `tx_id` before testing current ownership. When a terminal
resolution already exists, it compares every immutable binding, including both
the digest and the retained canonical record bytes, and returns the recorded
outcome only when all match. A mismatch is `tx_id_conflict`; the known-ID branch
never performs another journal mutation.

Only when an ordinary `tx_id` has no retained resolution does the store perform
the atomic conditional commit. It compares `expected_owner_epoch` against the
session's durable current epoch first, then
`expected_owner_incarnation_id` against the current pair's ID, and then
`expected_journal_version` against the durable current version. When all three
match, it allocates and stamps the next globally consecutive journal-version
range and commits the records. When any fails, it commits a terminal non-commit
resolution without journal or outbox records. In both cases the resolution
retains all immutable bindings, the canonical record bytes, and their digest.
If the store cannot durably establish that one terminal resolution, it returns
`commit_unknown(tx_id)` rather than a result it cannot reproduce.

This lookup, comparison, journal mutation when admitted, and terminal-resolution
write is one store operation. An unknown ordinary transaction from a superseded
caller therefore receives `stale_owner_epoch` even when its incarnation ID and
cached journal version are also stale; a wrong incarnation under the current
epoch is refused before the version comparison. A now-stale caller may still
retrieve `committed` for a known transaction committed under its then-valid
authority. There is no sequence of two store calls that a caller can perform
instead — a check followed by a write reintroduces exactly the race this record
exists to close.

Outcomes and required owner behavior:

| Result | Condition | Owner behavior |
| --- | --- | --- |
| `committed(tx_id)` | A matching known transaction was already committed, or an unknown transaction satisfied its atomic admission comparisons and its records became durable | Treat the commit as durable fact and eligible work; report that durable result truthfully, and process publication or dispatch only through the durable owned paths and their current fences |
| `not_committed(reason)` | A matching known transaction already has that terminal resolution, or an unknown transaction failed an admission comparison and its non-commit resolution became durable | Publish nothing, dispatch nothing, acknowledge nothing; a stale owner stops admitting |
| `commit_unknown(tx_id)` | Timeout, disconnect, crash, lost reply, or failure to establish a durable terminal resolution | Fence the domain and stop new dispatch; resolve by exact re-presentation, or safely supersede dead-owner succession through the status/head/CAS sequence before admission |

The separate read-only API
`transaction_status(session_id, mutation_domain, tx_id)` has four observations:

| Observation | Meaning | Recovery consequence |
| --- | --- | --- |
| `{:terminal, :committed}` | A matching scoped transaction has a durable committed resolution | Durable observation only; it conveys no authority or original bindings |
| `{:terminal, {:not_committed, reason}}` | A matching scoped transaction has a durable terminal refusal | Durable observation only; it conveys no authority or original bindings |
| `:absent` | No matching scoped transaction resolution exists at the lookup's linearization point | Authoritative for that instant, but not terminal; a concurrent transaction may linearize later |
| `:unavailable` | The store cannot make an authoritative status observation | The mutation domain remains fenced |

This is a separate read API, not a fourth commit outcome and not a mutation. Its
result contains no owner-incarnation ID, canonical record bytes, mutation
digest, expected version, or other mutation authority. A live caller that still
owns the original transaction request resolves ambiguity by exact
re-presentation so the store can compare every immutable binding; a status read
cannot substitute for that comparison. A mismatched exact re-presentation is
still `tx_id_conflict` even after status reported a terminal result.

Transaction status is scoped by the complete
`{session_id, mutation_domain, tx_id}` key. The same `tx_id` in another session
or mutation domain is unrelated and neither satisfies nor conflicts with the
lookup.

`committed` establishes durable fact and eligibility; it does not confer
caller-local post-commit authority. Eligibility lives in the committed outbox or
intent and is processed through the ordinary owner-pair-fenced paths, not by an
extra current-owner read between commit and action. Publication comes from the
durable outbox/event-hub path. Effect dispatch still has to pass the current
operation, session, and executor fences and
[ADR 0007](0007-local-executor-grant-job-receipt.md#concept)'s final executor
validation.

`reason` distinguishes at least `stale_owner_epoch`,
`stale_owner_incarnation_id`, `stale_journal_version`, and
implementation-specific refusals, because a stale owner must stop rather than
retry, while a version conflict may be re-derived and retried by the current
owner.

On first presentation, the store derives the exact bounded canonical bytes of
the complete ordered record set. Every terminal transaction-resolution entry,
including `not_committed`, retains those bytes, `session_id`, the mutation
domain, and `canonical_mutation_digest`. An ordinary resolution additionally
retains `expected_owner_epoch`, `expected_owner_incarnation_id`, and
`expected_journal_version`; an ownership-succession resolution retains its
observed prior epoch and version plus proposed new incarnation ID.
Re-presentation compares every applicable scalar binding, the digest, and
canonical bytes before returning the recorded terminal outcome; it is an
idempotent query or resolution, never a second logical mutation. Reusing the ID
with any different binding is `tx_id_conflict`. Equal digests do not make
different canonical record bytes equal, so a digest collision is refused rather
than treated as identity.

When the original bindings remain available, resolution after `commit_unknown`
re-presents those exact bindings and canonical record bytes. A retained terminal
entry returns its recorded outcome. If no entry exists, the request takes the
unknown-ID branch and can establish only one terminal outcome under the atomic
epoch-first, incarnation-second, and version-third comparison. The dead-owner
succession case, where the recovering process deliberately lacks the prior
capability and exact bindings, uses the non-authorizing status/head/CAS sequence
below instead. Until either path resolves or safely supersedes the uncertainty,
the domain is fenced: new mutations are refused or reported temporarily
unavailable, and if the store stays unavailable the session stays unavailable.
A proved `not_committed` outcome is terminal for that transaction ID. A current
owner may rederive from the new durable version only as a new logical transaction
with a new ID; it cannot turn the resolved non-commit into a commit by presenting
new expected values.

Every durable private record carries these store-stamped ownership and sequence
fields:

```text
owner_epoch
owner_incarnation_id
journal_version
```

Versions are one globally consecutive sequence for the session; an owner change
does not reset it. A multi-record transaction receives one contiguous range in
canonical record order. Replay refuses a gap, duplicate, reset, out-of-order
version, decreasing epoch, epoch or incarnation change without its recorded
succession transition, or records under a new ownership pair before that
transition. This never substitutes for the commit-time comparison; it detects a
store implementation that failed to honor its contract, which is the failure a
conformance suite cannot otherwise observe from outside.

Succession is a distinct `advance_owner` transaction. Each coordinator
incarnation creates a fresh `owner_incarnation_id`: an opaque bounded
serializable string or binary, never a PID, reference, function, atom derived
from input, or other runtime term. The request binds the durable current epoch
and session-global journal version plus its proposed ID. That proposed ID is
part of the transaction's immutable identity, canonical record bytes, mutation
digest, succession record, and retained terminal resolution.

For an unknown `advance_owner` transaction, the store atomically increments the
epoch by exactly one, installs `{new_epoch, proposed_owner_incarnation_id}` as
the current ownership pair, appends the succession record at the next
store-stamped version, and returns the pair only after that transition is
durable. Two contenders with distinct IDs and distinct transaction IDs using the
same prior epoch and version therefore produce exactly one winner; the loser
observes `not_committed(stale_owner_epoch)`. If they instead reuse one
transaction ID, the first immutable identity resolved owns that transaction and
the different proposed ID receives `tx_id_conflict`, never the first contender's
result.

A matching known `advance_owner` transaction returns its recorded terminal
outcome without performing succession again. Its `committed` result is
historical evidence, not transferable current authority. It authorizes the
holder to admit work only while the holder presents the same proposed ID and the
store's current pair is still `{recorded_epoch, proposed_owner_incarnation_id}`;
every ordinary commit enforces that pair atomically. Replaying the same result
after a later succession therefore remains truthfully `committed` but cannot
authorize a new mutation.

Crash recovery creates a new incarnation ID and may supersede the prior owner
without possessing the prior capability or exact prior transaction bindings. It
uses the recoverable scoped succession transaction ID to call
`transaction_status/3`. For either terminal observation or `:absent`, it then
calls the read-only `ownership_head(session_id, mutation_domain)`, which returns
the durable owner epoch and journal version needed for succession but no
incumbent incarnation ID. Recovery proposes its fresh ID in a new
`advance_owner` transaction against that head. `:unavailable` leaves admission
fenced.

The status lookup, ownership-head read, transaction-resolution writes, and
`advance_owner` compare-and-set all linearize in one serialized store history
for the session and mutation domain. They need not be one multi-call
transaction: the final compare-and-set closes every interval. If the dead
coordinator's in-flight succession or a third contender changes the head after
either read, recovery's stale compare-and-set is refused; recovery observes the
new durable history and repeats rather than overwriting it. If recovery advances
first, the older in-flight succession is refused by the same comparison. Thus
both orders converge on one current ownership pair, while continued
unavailability keeps the domain fenced. A dead coordinator cannot strand
ownership, and a second coordinator cannot treat the dead coordinator's status
or historical result as its own capability.

This is ownership of commit authority, not a liveness or hostile-code boundary.
The superseded coordinator may remain alive, but every later ordinary
transaction from it is fenced by its old pair. Runtime orchestration starts
succession only for legitimate startup or recovery; deliberate trusted code can
copy an incarnation ID, invoke succession against a live owner, or tamper with
private store state, and this trusted-local contract does not claim to prevent
that compromise.

A delayed `committed(tx_id)` reply does not transfer current-owner authority.
The transaction remains durable and must not be discarded merely because its
originator was superseded after commit. The delayed reply may truthfully
acknowledge that durable commit to its originator, but the stale coordinator
does not update the current cache or directly publish or dispatch from the
reply. A successor or other currently owned path recovers the one durable
logical outbox/event identity. The event hub delivers it at least once, and
consumers deduplicate by event ID and sequence. The owned effect path separately
recovers committed intent and admits dispatch only under current operation,
session, and executor fences plus durable executor deduplication, so recovery or
a delayed reply cannot start a second logical effect.

The conformance suite every implementation runs covers at minimum:

- an unknown transaction from a stale owner is refused at commit and observes
  `not_committed`, never `committed`, while that owner can retrieve a matching
  transaction committed before it was superseded;
- the refused transaction leaves no durable journal record and produces no
  outbox row, but does retain its matching terminal non-commit resolution;
- simultaneous successors with distinct incarnation IDs and distinct
  transaction IDs yield exactly one winner;
- simultaneous successors with distinct incarnation IDs and the same
  transaction ID yield one resolved identity and `tx_id_conflict` for the
  other, never a shared capability;
- an ordinary commit is refused independently for a wrong incarnation ID under
  the current epoch, a wrong epoch, and a stale journal version;
- replaying a matching committed `advance_owner` transaction while its pair is
  current returns the same result without advancing again, and its holder can
  still commit under that pair;
- replaying that transaction after supersession returns the historical result
  but does not transfer authority: an ordinary commit under the old pair is
  refused;
- a superseded but still-live coordinator cannot update the current cache or
  directly publish or dispatch from a delayed reply; that reply may truthfully
  report a transaction committed before succession, while a currently owned
  path exposes one durable event identity whose at-least-once deliveries retain
  the same event ID and sequence, and cannot start the committed logical effect
  twice under retry or delayed-reply recovery;
- a version conflict under the current ownership pair is distinguishable from
  stale ownership; an epoch mismatch wins when epoch and later comparisons fail,
  and an incarnation mismatch wins over version when the epoch is current;
- an interrupted commit resolves to exactly one of committed or not committed
  when re-presented by `tx_id`, and never to both;
- reusing a transaction ID with a different session, epoch, version, digest, or
  canonical record bytes is refused for both committed and terminal non-commit
  resolutions, including when different record bytes are presented with the
  same digest; a proved non-commit can be retried only under a new transaction
  ID;
- both terminal transaction-status results expose none of the owner-incarnation
  ID, canonical bytes, digest, expected version, or mutation authority, and
  neither permits an ordinary commit without the independently held current
  ownership pair;
- after either terminal status result, exact re-presentation with any mismatched
  binding still returns `tx_id_conflict` rather than the observed result;
- an unavailable status lookup for an unknown succession keeps admission and
  mutation fenced;
- when status reports `:absent` while the dead coordinator's succession is in
  flight, both linearization orders — original succession first and recovery
  succession first — leave exactly one current ownership pair and a refused
  loser;
- when a third succession commits after recovery's ownership-head read,
  recovery's final compare-and-set is refused instead of overwriting the third
  owner;
- equal transaction IDs in different sessions or mutation domains have isolated
  status and resolution state; neither scope can observe or satisfy the other;
- recovery from each of the four status observations converges or fences:
  terminal committed, terminal non-commit, and absence proceed through a fresh
  head read and fresh-ID succession, while unavailability remains fenced;
- mutation checks prove that removing any one of the ordinary commit's epoch,
  incarnation-ID, or journal-version comparisons makes its corresponding
  refusal case fail;
- the incarnation ID crosses the store boundary only as a bounded plain string
  or binary, and never appears in public events, transient progress, or
  diagnostics;
- replay refuses hand-constructed histories with a version gap, reset,
  duplicate, or out-of-order record, a decreasing epoch, or an epoch or
  incarnation transition lacking its succession record.

<a id="technical-adr-0006-alternatives"></a>
## Alternative Analysis

Concept: [Alternatives](0006-store-transaction-and-owner-epoch.md#concept-adr-0006-alternatives).

**Exclusive transactional lease.** The store issues one writer a lease and
refuses others while it holds. This is genuinely viable and is what a store with
strong session-scoped locking expresses most naturally. Two consequences follow
if it is adopted. First, correctness depends on lease expiry, and expiry depends
on clocks: a lease that expires while its holder still believes it valid
reproduces the stale-writer problem unless the store also fences at commit — at
which point the epoch comparison is back. Second, `M1` must then delete every
claim that fencing happens at replay, because under a lease the replay check
audits the lease rather than enforcing anything.

**Replay-only rejection.** Analyzed in the context section above. Its appeal is
that the write path stays simple and the store needs no conditional commit. That
simplicity is purchased by acknowledging a writer the system has already
replaced.

**Process-identity prevention.** `M0`'s token, OS process, and Erlang pid triple.
It is a strong local mechanism and it is why `M0` closed honestly. It does not
generalize: a store behind a socket sees none of those values, so a port defined
in their terms would either exclude every non-local implementation or degrade
silently for them.

**Single writer by construction, no store check.** Rely on the Coordinator being
the only writer and skip enforcement. This is the assumption every one of the
above exists to avoid trusting; a partitioned or paused owner is the ordinary
case that breaks it, and it is undetectable when it does.

<a id="technical-adr-0006-consequences"></a>
## Operational Consequences and Failure Modes

Concept: [Consequences](0006-store-transaction-and-owner-epoch.md#concept-adr-0006-consequences).

The conditional commit is one round trip, so the hot path cost is the comparison
itself rather than an extra call. The mandatory epoch advance on succession adds
one durable write per restart, paid once.

The visible new failure mode is a fenced session. While `commit_unknown` is
unresolved the session refuses work, and a caller sees unavailability rather than
an error. This is the intended trade: unavailability is recoverable and a
duplicated effect is not.

A stale owner that is refused must stop rather than retry. Retrying a
`stale_owner_epoch` refusal is a live-lock against a successor that has already
taken over, so the refusal reason is part of the contract and not diagnostic
text.

Replay validation can fail on a history that a correct store would never produce.
That is a store defect, and it must be reported as one rather than repaired by
discarding records, because silently dropping records is how the replay-only
design hides the failure this record rejects.

<a id="technical-adr-0006-compatibility"></a>
## Compatibility and Rollback Mechanics

Concept: [Compatibility, migration, and rollback](0006-store-transaction-and-owner-epoch.md#concept-adr-0006-compatibility).

Nothing is released and no store holds data that must survive, so there is no
migration. `M0`'s journals stay bound to `M0`'s closed record.

The record schema is fixed here because adding `owner_epoch` and
`journal_version` after records exist is a migration, and the whole point of
deciding before implementation is that `M1` does not perform one.

Rollback is removing the port while no implementation depends on it. After the
first implementation ships, rollback is a successor decision, not an edit.

No public compatibility claim is made. The port carries a conformance suite so
that a later milestone can make one with vectors and independent implementations;
it does not make one now.
