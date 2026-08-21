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

A commit request binds, at minimum:

```text
session_id
expected_owner_epoch      the epoch the caller believes it owns
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

Only when `tx_id` has no retained resolution does the store perform the atomic
conditional commit. It compares `expected_owner_epoch` against the session's
durable current epoch first, then compares `expected_journal_version` against
its durable current version. When both match, it allocates and stamps the next
globally consecutive journal-version range and commits the records. When either
fails, it commits a terminal non-commit resolution without journal or outbox
records. In both cases the resolution retains all immutable bindings, the
canonical record bytes, and their digest. If the store cannot durably establish
that one terminal resolution, it returns `commit_unknown(tx_id)` rather than a
result it cannot reproduce.

This lookup, comparison, journal mutation when admitted, and terminal-resolution
write is one store operation. An unknown transaction from a superseded caller
therefore receives `stale_owner_epoch` even when its cached journal version is
also stale, while a now-stale caller may still retrieve `committed` for a known
transaction committed under its then-valid authority. There is no sequence of
two store calls that a caller can perform instead — a check followed by a write
reintroduces exactly the race this record exists to close.

Outcomes and required owner behavior:

| Result | Condition | Owner behavior |
| --- | --- | --- |
| `committed(tx_id)` | A matching known transaction was already committed, or an unknown transaction matched both comparisons and its records became durable | Treat the commit as durable fact and eligible work; report that durable result truthfully, and process publication or dispatch only through the durable owned paths and their current fences |
| `not_committed(reason)` | A matching known transaction already has that terminal resolution, or an unknown transaction failed a comparison and its non-commit resolution became durable | Publish nothing, dispatch nothing, acknowledge nothing; a stale owner stops admitting |
| `commit_unknown(tx_id)` | Timeout, disconnect, crash, lost reply, or failure to establish a durable terminal resolution | Fence the domain, stop new dispatch, resolve by `tx_id` before choosing a branch |

`committed` establishes durable fact and eligibility; it does not confer
caller-local post-commit authority. Eligibility lives in the committed outbox or
intent and is processed through the ordinary owner-epoch-fenced paths, not by an
extra current-owner read between commit and action. Publication comes from the
durable outbox/event-hub path. Effect dispatch still has to pass the current
operation, session, and executor fences and
[ADR 0007](0007-local-executor-grant-job-receipt.md#concept)'s final executor
validation.

`reason` distinguishes at least `stale_owner_epoch`, `stale_journal_version`, and
implementation-specific refusals, because a stale owner must stop rather than
retry, while a version conflict may be re-derived and retried by the current
owner.

On first presentation, the store derives the exact bounded canonical bytes of
the complete ordered record set. Every terminal transaction-resolution entry,
including `not_committed`, retains those bytes alongside `session_id`, the
session-journal mutation domain, `expected_owner_epoch`,
`expected_journal_version`, and `canonical_mutation_digest`. Re-presentation
compares the scalar bindings, digest, and canonical bytes before returning the
recorded terminal outcome; it is an idempotent query or resolution, never a
second logical mutation. Reusing the ID with any different binding is
`tx_id_conflict`. Equal digests do not make different canonical record bytes
equal, so a digest collision is refused rather than treated as identity.

Resolution after `commit_unknown` re-presents those exact bindings and canonical
record bytes. A retained terminal entry returns its recorded outcome. If no
entry exists, the request takes the unknown-ID branch and can establish only one
terminal outcome under the atomic epoch-first and version-second comparison.
Until it resolves, the domain is fenced: new mutations are refused or reported
temporarily unavailable, and if the store stays unavailable the session stays
unavailable. A proved `not_committed` outcome is terminal for that transaction
ID. A current owner may rederive from the new durable version only as a new
logical transaction with a new ID; it cannot turn the resolved non-commit into a
commit by presenting new expected values.

Every durable record retains `owner_epoch` and the store-stamped
`journal_version`. Versions are one globally consecutive sequence for the
session; an owner change does not reset it. A multi-record transaction receives
one contiguous range in canonical record order. Replay refuses a gap, duplicate,
reset, out-of-order version, decreasing epoch, epoch increment without its
recorded succession transition, or records under a new epoch before that
transition. This never substitutes for the commit-time comparison; it detects a
store implementation that failed to honor its contract, which is the failure a
conformance suite cannot otherwise observe from outside.

Succession is a distinct `advance_owner` transaction. It binds the durable
current epoch and session-global journal version, atomically increments the
epoch by exactly one, appends the succession record at the next store-stamped
version, and returns the new epoch only after that transition is durable. Only
that winner may admit commands. Two contenders using the same prior epoch and
version therefore produce exactly one winner; the loser observes
`not_committed(stale_owner_epoch)`. This is ownership of commit authority, not a
liveness guarantee: the superseded coordinator may remain alive, but every
later transaction from it is fenced by its old epoch.

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
- two simultaneous successors yield exactly one winner;
- a superseded but still-live coordinator cannot update the current cache or
  directly publish or dispatch from a delayed reply; that reply may truthfully
  report a transaction committed before succession, while a currently owned
  path exposes one durable event identity whose at-least-once deliveries retain
  the same event ID and sequence, and cannot start the committed logical effect
  twice under retry or delayed-reply recovery;
- a version conflict from the current owner is distinguishable from a stale
  epoch, and an epoch mismatch wins when both comparisons fail;
- an interrupted commit resolves to exactly one of committed or not committed
  when re-presented by `tx_id`, and never to both;
- reusing a transaction ID with a different session, epoch, version, digest, or
  canonical record bytes is refused for both committed and terminal non-commit
  resolutions, including when different record bytes are presented with the
  same digest; a proved non-commit can be retried only under a new transaction
  ID;
- replay refuses hand-constructed histories with a version gap, reset,
  duplicate, or out-of-order record, a decreasing epoch, or an epoch transition
  lacking its succession record.

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
