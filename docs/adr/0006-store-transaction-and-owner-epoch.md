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

Replay-only fencing means the store acknowledges a stale writer's commit. The
stale owner then does exactly what an acknowledgement authorizes: it publishes
its events and dispatches its effects. Replay discards the record later, so the
durable history is eventually correct and the observable world is not — an effect
ran, a subscriber saw a fact, and neither is recoverable by discarding a row. The
vision's ordering exists to prevent precisely this: intent commits before
dispatch, and facts commit before publication.

Technical depth: [Why replay-only fencing fails](0006-store-transaction-and-owner-epoch-technical.md#technical-adr-0006-context).

<a id="concept-adr-0006-decision"></a>
## Decision

- **Fencing happens at commit, not at replay.** Every session-journal
  transaction carries an expected owner epoch and an expected journal version.
  The store compares both **atomically with the commit** and refuses the
  transaction when either does not match. A stale owner never receives
  `committed`.
- **The store contract has exactly three outcomes**, as the vision fixes them:
  `committed(tx_id)`, `not_committed(reason)`, and `commit_unknown(tx_id)`. A
  refused stale owner is `not_committed`, and a timeout is never evidence of
  failure.
- **Nothing follows a non-commit.** No acknowledgement, no publication, and no
  dispatch occurs on `not_committed` or while `commit_unknown` is unresolved.
  `commit_unknown(tx_id)` fences its mutation domain and resolves by transaction
  ID before either branch is chosen.
- **At most one live coordinator at a time.** A successor durably advances the
  session epoch before admitting any command. Ownership is a durable fact in the
  store, not an inference from a live process.
- **Epochs are retained in records anyway.** Commit-time comparison is the
  safety mechanism; retained epochs are the audit mechanism. Replay validates
  them and refuses a history that could not have been produced by a legal
  sequence of owners, which detects a store that failed to enforce its own
  contract instead of trusting it.
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
above: it acknowledges a stale writer, which authorizes publication and dispatch
that no later replay can retract.

**Write prevention by process identity alone** is `M0`'s mechanism carried
forward. It is not sufficient for a replaceable port, because a store reached
over a socket has no access to the writer's OS process or Erlang pid, and the
guarantee would silently weaken for every implementation that is not a local
file.

Technical depth: [Alternative analysis](0006-store-transaction-and-owner-epoch-technical.md#technical-adr-0006-alternatives).

<a id="concept-adr-0006-consequences"></a>
## Consequences

Every session-journal transaction carries two more bound values, and every store
implementation must express one atomic conditional commit. A store that cannot
express one cannot implement this port — that is the intended filter.

Recovery becomes slower and more explicit: a successor must durably advance the
epoch before it admits anything, so restart has a mandatory write before its
first command. The alternative is admitting a command whose ownership is
unproven.

`commit_unknown` makes unavailability visible. When the store cannot say whether
a transaction committed, the session is unavailable rather than optimistic. A
caller sees a stall where a speculating system would have shown a duplicate
effect.

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
record format carries owner epochs, removing them is a schema change, which is
why the schema is fixed here rather than discovered during implementation.

Technical depth: [Compatibility and rollback mechanics](0006-store-transaction-and-owner-epoch-technical.md#technical-adr-0006-compatibility).

## Links

- [ADR 0007](0007-local-executor-grant-job-receipt.md#concept) — the grant
  boundary that depends on a store able to refuse a stale owner
- [Vision technical §9.1](../vision-technical.md#technical-depth) — the three
  store outcomes and transaction-ID resolution this decision adopts
- [Plans register](../plans/README.md) — milestone register and lifecycle
- [AGENTS.md](../../AGENTS.md) — durability and recovery truth, one serial
  session owner
