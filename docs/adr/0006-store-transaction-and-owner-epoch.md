# 0006. Store transaction contract and owner epoch

<a id="concept"></a>
## Concept

Technical depth: [Transaction and fencing mechanics](0006-store-transaction-and-owner-epoch-technical.md#technical-depth).

- **Status:** Proposed
- **Date:** 2026-08-21
- **Decision owner:** Maintainer
- **Prerequisite for:** `M1` acceptance, and implementation of its outcomes 2, 3,
  and 8

## Governance Record

| Decision | Authority | Authority evidence | Bound bytes |
| --- | --- | --- | --- |
| Acceptance | — | — | — |

<a id="concept-adr-0006-context"></a>
## Context

`M0` proved a single-machine session loop with a filesystem journal. It bound
every mutation to the owning Coordinator's active claim by token, OS process, and
Erlang pid, and it recorded one deferred race: reading the ownership sentinel and
performing the write are separable, so ownership can change between the check and
the mutation. That deferral was explicitly assigned here.

`M1` needs a durable store behind a replaceable port, and its plan currently
answers the deferred question inside the plan itself: it mandates that a stale
writer's records be refused *at replay* rather than prevented at write. That
answer is unsafe, and choosing it in a plan rather than a decision is why this
record exists.

Replay-only fencing makes a stale writer's records durable and eligible work.
Before a later replay rejects them, the durable outbox/event-hub path can publish
their facts and the dispatch path can present their intent for execution. Current
executor fences remain required and may refuse that dispatch, but they cannot
make the stale durable fact truthful or retract a publication; if the downstream
fence has not advanced separately, the effect can run too. The vision's ordering
exists to prevent precisely this: intent commits before dispatch, and facts
commit before publication.

Technical depth: [Why replay-only fencing fails](0006-store-transaction-and-owner-epoch-technical.md#technical-adr-0006-context).

<a id="concept-adr-0006-decision"></a>
## Decision

- **Fencing happens at commit, not at replay.** Every ordinary session-journal
  transaction carries an expected owner epoch, expected owner-incarnation ID,
  and expected journal version. For a transaction ID without a retained
  terminal outcome, the store compares all three **atomically with the commit**
  and refuses the transaction when any does not match. Ownership succession
  instead compares its prior epoch and version while binding the fresh ID it
  proposes to install. A superseded owner can never newly commit.
  Re-presenting a known transaction first validates its immutable bindings and
  returns its recorded outcome, so a now-stale originator receives `committed`
  only for a transaction committed while its authority was valid.
- **The store contract has exactly three outcomes**, as the vision fixes them:
  `committed(tx_id)`, `not_committed(reason)`, and `commit_unknown(tx_id)`. A
  refused stale owner is `not_committed`, and a timeout is never evidence of
  failure.
- **Nothing follows a non-commit.** No acknowledgement, no publication, and no
  dispatch occurs on `not_committed` or while `commit_unknown` is unresolved.
  `commit_unknown(tx_id)` fences its mutation domain and resolves by transaction
  ID before either branch is chosen.
- **At most one current committing owner at a time.** The store owns the durable
  `{owner_epoch, owner_incarnation_id}` pair. Each coordinator incarnation
  generates a fresh opaque bounded string or binary, and succession atomically
  installs that ID with the next epoch before admitting any command. A
  superseded coordinator may still be alive, but neither its old epoch nor a
  different incarnation at the same proposed epoch can commit or authorize
  work. Ownership is a store fact, not an inference from process liveness.
- **Transaction identity is immutable.** A transaction ID is bound to its
  session and mutation domain, expected ownership, expected version, and
  complete canonical mutation digest and record-set bytes. An `advance_owner`
  transaction also binds its proposed fresh owner-incarnation ID. These values
  are retained with every terminal outcome, including a non-commit. Repeating
  the same identity and bytes resolves the same outcome; changing any binding is
  a conflict even if two record sets have the same digest. A retry after a
  proved non-commit uses a new transaction ID.
- **Versions form one store-stamped session sequence.** Journal versions remain
  globally consecutive across owner changes. The store, not the caller, stamps
  the committed record range, so replay can detect gaps, resets, and epoch
  changes that were not durably recorded.
- **Ownership is retained in private records anyway.** Commit-time comparison
  is the safety mechanism; retained epochs and incarnation IDs are the audit
  mechanism. Replay validates them and refuses a history that could not have
  been produced by a legal sequence of owners, which detects a store that failed
  to enforce its own contract instead of trusting it.
- **The port owns this, not one implementation.** Refusing a stale owner is a
  conformance obligation every store implementation runs, so the guarantee
  survives replacing the filesystem journal.

Technical depth: [Exact contract, schema, and conformance obligations](0006-store-transaction-and-owner-epoch-technical.md#technical-adr-0006-decision).

<a id="concept-adr-0006-alternatives"></a>
## Alternatives

**An exclusive transactional lease** — the store grants one writer a lease and
refuses every other writer for its duration — is viable and is the honest
alternative. It moves the comparison from per-transaction data to a
connection-scoped or row-scoped lock, which some stores express more naturally
than a compare-and-set. If it is chosen, `M1` must stop claiming replay-based
fencing anywhere, because under a lease the replay check is an audit of the lease
and proves nothing on its own. It is not recommended because a lease's
correctness depends on lease-expiry timing that differs per implementation, while
an epoch-and-version comparison is the same arithmetic everywhere.

**Replay-only rejection** is what the current `M1` plan mandates. It is rejected
above: it makes stale outbox and intent records durable eligible work. A later
replay cannot retract publication, and relying on a downstream executor fence
does not make the session journal truthful.

**Write prevention by process identity alone** is `M0`'s mechanism carried
forward. It is not sufficient for a replaceable port, because a store reached
over a socket has no access to the writer's OS process or Erlang pid, and the
guarantee would silently weaken for every implementation that is not a local
file.

Technical depth: [Alternative analysis](0006-store-transaction-and-owner-epoch-technical.md#technical-adr-0006-alternatives).

<a id="concept-adr-0006-consequences"></a>
## Consequences

Every ordinary session-journal transaction carries three bound comparison
values, and every store implementation must express one atomic conditional
commit. A succession transaction additionally binds the proposed incarnation
ID it will install. A store that cannot express this cannot implement the port —
that is the intended filter.

Recovery becomes slower and more explicit: a successor must durably advance the
epoch with a new incarnation ID before it admits anything, so restart has a
mandatory write before its first command. It need not possess the prior owner's
ID: after resolving any earlier uncertain succession, it may atomically
supersede the current pair with its own fresh ID. The alternative is admitting a
command whose ownership is unproven.

A commit remains committed even if its reply reaches a coordinator after that
coordinator has been superseded. The delayed reply may truthfully acknowledge
the durable commit, but the stale process cannot update the current cache or
directly publish or dispatch from that reply. Each committed outbox fact has one
durable logical event identity; delivery is at least once, and consumers
deduplicate by event ID and sequence. A successor or other currently owned path
may dispatch committed intent only after current operation, session, and
executor fences, durable effect deduplication, and
[ADR 0007](0007-local-executor-grant-job-receipt.md#concept)'s final validation
permit the one logical effect.

`commit_unknown` makes unavailability visible. When the store cannot say whether
a transaction committed, the session is unavailable rather than optimistic. A
caller sees a stall where a speculating system would have shown a duplicate
effect.

The owner-incarnation ID is a trusted-local capability and private recovery
data, not a public security credential. It is plain bounded serializable data —
never a PID, reference, or other runtime term — and never enters public events,
progress, or diagnostics. Deliberate trusted code that copies the ID or tampers
with the store can impersonate its holder; this decision does not claim to
defend against that trusted-code compromise.

`M0`'s `Loopex.Journal` becomes an adapter behind this port or is replaced by
one. That choice is implementation and belongs to `M1`'s work, not to this
decision.

Technical depth: [Operational consequences and failure modes](0006-store-transaction-and-owner-epoch-technical.md#technical-adr-0006-consequences).

<a id="concept-adr-0006-compatibility"></a>
## Compatibility, Migration, and Rollback

No released surface exists and no store is deployed, so nothing requires
migration. `M0`'s retained journals are bound to `M0`'s closed record and are not
carried forward.

Rollback is removing the port while no implementation depends on it. Once a
record format carries owner epochs and incarnation IDs, removing them is a
schema change, which is why the schema is fixed here rather than discovered
during implementation.

Technical depth: [Compatibility and rollback mechanics](0006-store-transaction-and-owner-epoch-technical.md#technical-adr-0006-compatibility).

## Links

- [ADR 0007](0007-local-executor-grant-job-receipt.md#concept) — the grant
  boundary that depends on a store able to refuse a stale owner
- [Vision transaction and recovery truth](../vision-technical.md#technical-vision-recovery-truth) — the three
  store outcomes and transaction-ID resolution this decision adopts
- [Plans register](../plans/README.md) — milestone register and lifecycle
- [AGENTS.md](../../AGENTS.md) — durability and recovery truth, one serial
  session owner
