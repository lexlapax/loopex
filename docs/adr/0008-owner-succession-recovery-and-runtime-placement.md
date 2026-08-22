# 0008. Owner succession recovery and runtime placement

<a id="concept"></a>
## Concept

Technical depth: [Recovery index and placement mechanics](0008-owner-succession-recovery-and-runtime-placement-technical.md#technical-depth).

- **Status:** Proposed
- **Date:** 2026-08-22
- **Decision owner:** Maintainer
- **Prerequisite for:** revising `M1` Workstream A's Store catalogue and
  conformance, then completing Workstream B and outcomes 2, 3, and 4

## Governance Record

| Decision | Authority | Authority evidence | Bound bytes |
| --- | --- | --- | --- |
| Acceptance | — | — | — |

<a id="concept-adr-0008-context"></a>
## Context

[ADR 0006](0006-store-transaction-and-owner-epoch.md#concept) requires a dead
owner's recovery to identify the exact uncertain succession transaction, read
its status, read the durable ownership head, and submit a fresh compare-and-set
with a new transaction and incarnation ID. It deliberately makes status
non-authorizing and makes `:absent` non-terminal.

The accepted decision says that the prior succession transaction ID is
recoverable, but does not say where it survives. A live runtime can retain it in
process memory and a committed `owner_advanced` record can identify a completed
transaction. Neither identifies an acquiring candidate whose transaction is
absent or in flight when its coordinator or whole runtime VM dies. The Store
cannot be queried by an ID the successor does not know, and the ownership head
intentionally exposes no candidate identity. This is missing information, not a
retry bug.

A second gap appears if two Runtime Controls use the same Store and session at
once. Store fencing still prevents a stale owner from newly committing, but one
Control does not observe the other Control's runtime-local cache replacement.
An old reply delayed until after the other Control advances ownership can
therefore pass the first Control's local post-commit check. A read of the Store
head narrows the race but cannot atomically order a later process-memory update
with a concurrent succession.

The founding vision already assigns placement to the host and requires the
multi-runtime proof with distinct Stores. `M1` is one machine and one attached
caller, with no active-active placement or network controller in scope. The
unresolved choice is whether to make those limits explicit while giving the
Store enough private recovery identity to fulfill ADR 0006, or to widen M1 into
a public recovery-token or global coordination design.

Technical depth: [The two information and authority gaps](0008-owner-succession-recovery-and-runtime-placement-technical.md#technical-adr-0008-context).

<a id="concept-adr-0008-decision"></a>
## Decision

- **The Store owns a private durable succession-attempt index.** One entry is
  addressed by the runtime-scoped create or resume command identity and binds
  its kind, session, mutation domain, exact canonical command bytes, and digest.
  It records whether that logical command is open or completed, a monotonic
  attempt generation, the exact candidate succession transaction ID, and that
  candidate's complete canonical bytes and digest before the candidate may be
  submitted. Reusing a command identity with any changed binding conflicts.
- **Staging an attempt is a catalogued Store mutation.** It uses ADR 0006's
  three outcomes and compare-and-set semantics in the same session mutation
  domain as `advance_owner`. It mutates only private recovery identity and its
  terminal staging resolution — never the owner head, journal version, private
  session journal, outbox, or a public plane. A lost staging reply is recovered
  by exact re-presentation while the caller retains its bindings; after caller
  loss, a successor uses the index only to discover the candidate before the
  ADR 0006 status/head/fresh-CAS sequence. Contenders for the same prior attempt
  generation cannot both install candidates. Every implementation must cover
  its declared pre-linearization, post-linearization, and recovery fault points.
- **Recovery always discovers before it supersedes.** A completed logical
  succession returns its original durable command result and never stages or
  advances ownership again. An open succession reads its indexed candidate and
  queries that exact transaction status. Candidate commit atomically completes
  the logical succession; candidate absence or terminal non-commit may proceed
  through a fresh ownership-head read, staged transaction, and incarnation
  under the next attempt generation. Unavailability leaves admission fenced. A
  stale staging or ownership compare-and-set retries from durable observations
  rather than overwriting them. After a runtime is lost, learning that an older
  command completed does not recreate its dead coordinator; acquiring a live
  replacement requires a new resume command identity.
- **The index never grants owner authority.** Its read exposes only the bounded
  succession state, attempt generation, candidate transaction ID, and completed
  lifecycle result already returned by the embedded API. It exposes no
  incarnation ID, canonical mutation bytes, digest, or current-owner capability.
  A known `advance_owner` transaction is resolved and its immutable
  bindings are validated before index eligibility is considered; it always
  returns ADR 0006's retained historical outcome. Only an unknown transaction's
  first presentation must be the current staged candidate. Internally, staging
  and first presentation compare the retained exact bytes as well as the digest,
  so equal digests never make changed bytes equal. Ordinary session commits
  still require ADR 0006's atomic owner epoch, incarnation, and journal-version
  comparison.
- **`M1` supports one active Runtime Control per Store/runtime placement.** A
  Store identity means the authoritative session namespace, not an incidental
  pid or handle. A session remains bound to the `runtime_id` that created it,
  and that ID is durable placement identity that must be re-presented after
  restart. The host must quiesce or lose the old Runtime Control before starting
  its replacement with the same Store namespace and runtime identity. Two
  runtime references may coexist with distinct Store roots, as the vision and
  Outcome 1 require; `M1` makes no active-active claim for two Controls
  concurrently routing one session.
- **Cross-runtime active-active ownership is a successor decision.** Supporting
  it requires a globally ordered consequence authority — for example a durable
  claim/lease or a Store-backed routing mechanism — plus fault, migration, and
  placement evidence. A VM-global registry or process name is not an
  alternative because explicit runtime references and multiple runtimes remain
  required.

This adds no fourth product boundary behaviour: the attempt index is private
Store recovery data and the embedded API remains a direct facade. It changes no
M1 outcome, selector, evidence class, or public compatibility claim.
Acceptance is the accepted plan's required explicit disposition for this new
persistence and placement decision. It requires no plan amendment while every
locked Outcome 2 case remains required and the implementation stays inside the
existing Store behaviour and accepted one-caller, distinct-Store topology. Any
scope deferral, softened selector, or active-active expansion still requires the
ordinary plan-amendment or deferral authority.

Technical depth: [Exact index, recovery, and placement contract](0008-owner-succession-recovery-and-runtime-placement-technical.md#technical-adr-0008-decision).

<a id="concept-adr-0008-alternatives"></a>
## Alternatives

**Caller-retained recovery tokens** would make the client persist each candidate
transaction ID and return it after a crash. This avoids the Store index, but it
makes a private transaction mechanism part of the embedded public lifecycle,
turns a thin client into recovery storage, and cannot help when the process dies
before the caller durably receives the next token.

**Global consequence coordination in M1** would allow active-active Controls by
placing cache, delivery, and dispatch eligibility behind a globally ordered
claim. It is viable, but it adds a placement/coordination contract, more durable
mutations, and distributed-style races to a milestone that explicitly excludes
distribution and permits only three boundary behaviours. It should be designed
when an active-active host exists to provide real evidence.

**Relying on the last committed owner record** is insufficient because it names
the incumbent's completed transaction, not the absent or in-flight acquiring
candidate. **Retrying with a guessed ID** violates ADR 0006's exact-status and
fresh-ID sequence. **Doing nothing** leaves only two honest outcomes: keep the
session fenced forever after this crash window, failing recovery liveness, or
speculate and risk stale authority. Neither satisfies M1.

Technical depth: [Alternative analysis](0008-owner-succession-recovery-and-runtime-placement-technical.md#technical-adr-0008-alternatives).

<a id="concept-adr-0008-consequences"></a>
## Consequences

Accepting this decision makes every owner acquisition more expensive: the Store
performs an indexed staging write before `advance_owner`, retains the operation
identity needed for replay, and every future Store adapter must implement and
test the same compare-and-set and fault recovery. Attempt rows and staging
resolutions also enter backup, restore, retention, and future compaction duties;
discarding them can turn an old retry into a new succession. That cost buys a
durable answer to repeated coordinator and full-VM loss without exposing owner
capability or making the caller the recovery journal.

Command replay remains idempotent rather than a hidden restart primitive. Once
a create or resume command has completed, re-presenting it returns the historical
result without advancing the owner epoch. If its coordinator was subsequently
lost, the caller learns that result and uses a fresh resume command identity to
acquire a replacement. This makes one extra lifecycle step visible after that
crash window, but prevents an old completed command from displacing a newer
owner.

The placement limit is also durable architectural debt, but visible debt. M1
can restart or hand off only after the old runtime placement is quiescent; it
therefore accepts quiescence downtime and cannot claim split-brain or
active-active failover. Changing `runtime_id` without a governed handoff strands
the sessions bound to the old placement identity. A later distributed or highly
available runtime must replace that limit with global consequence authority and
prove the handoff, partition, delayed-result, and rollback cases. The private
attempt index remains useful in that design because remote Store and coordinator
failure make recoverable operation identity more important, not less.

Rejecting the index means ADR 0006's absent/in-flight recovery cannot be
implemented from the accepted Store observations. The safe behavior is
permanent unavailability for the affected session; any liveness-preserving
retry guesses about an unresolved transaction. Rejecting the placement limit
without authorizing global coordination leaves a stale Control able to treat a
reply-local cache as current after another Control has succeeded. In either
case M1 Outcome 2 remains open and Workstream C cannot safely start.

Technical depth: [Long-term costs and benefits](0008-owner-succession-recovery-and-runtime-placement-technical.md#technical-adr-0008-consequences).

<a id="concept-adr-0008-compatibility"></a>
## Compatibility, Migration, and Rollback

No released Store or public compatibility surface exists. M0 journals are not
migrated, and pre-closure M1 test roots may be discarded. The local Store
implementations add the index as part of their M1 format rather than migrating
installed data.

Before M1 closes, rollback removes the index transaction and the Workstream B
runtime that depends on it. After a Store implementation is published or data
is promised across versions, changing index identity, compaction, or the
exclusive-placement contract requires a successor decision and an explicit
migration or compatibility disposition. Compaction must retain each completed
command's binding and historical result so exact replay can never become a new
succession.

Technical depth: [Format, migration, and rollback mechanics](0008-owner-succession-recovery-and-runtime-placement-technical.md#technical-adr-0008-compatibility).

## Links

- [ADR 0006](0006-store-transaction-and-owner-epoch.md#concept) — the transaction
  and owner-epoch contract this decision completes without replacing
- [M1 plan](../plans/M1.md#concept) — the accepted outcomes and three-behaviour
  scope this decision preserves
- [Vision runtime supervision](../vision-technical.md#technical-vision-runtime-supervision) — explicit runtimes, distinct Stores, and host-owned placement
- [AGENTS.md](../../AGENTS.md) — one serial session owner, durable recovery
  truth, and decision authority
