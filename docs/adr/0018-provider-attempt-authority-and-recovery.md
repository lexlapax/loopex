# 0018. Provider attempt authority and recovery

<a id="concept"></a>
## Concept

Technical depth: [Attempt records, dispatch linearization, settlement, and evidence](0018-provider-attempt-authority-and-recovery-technical.md#technical-depth).

- **Status:** Proposed
- **Date:** 2026-09-01
- **Decision owner:** Maintainer
- **Prerequisite for:** proposed `M2` Amendment 4
- **Supersedes:** 0010
- **Supersedes:** 0011
- **Supersedes:** 0014

The ADR 0010 supersession is limited to its rule that recovery of an unresolved
staged model intent dispatches the same bytes, its general provider-retry rule,
and its deadline/cancellation attempt-evidence and provider-usage fallback rows.
Exact staged context, canonical request identity, continuation binding,
committed-journal ordering, and the context pipeline remain in force. Staged
bytes are recovery identity, never redispatch authority.

The ADR 0011 supersession is limited to the `{:error, term()}` side of the Model
callback, the claim that model-call occurrence is never unknown, the general
availability of provider retry, the associated attempt-domain opening rule, and
the provider result/accounting projection replaced here. Successful streaming,
complete-reply reconstruction, attempt-derived stream identity, and closure
algebra remain in force. A second model stream domain exists only for the one
retry this decision permits.

The ADR 0014 supersession is limited to its requirement that a successor retry
the same staged model request after model-owner loss. The successor still owns
durable recovery, never closes the dead predecessor's transient stream, and
cannot let stale-originator output enter canonical or public truth. It now
settles an open predecessor attempt as dispatched-or-unknown and does not
redispatch it unless exact durable `not_dispatched` proof was already committed.

ADR 0006 is not superseded. Control's direct send of a one-use dispatch permit
is the current-owner provider-dispatch linearization point. Later consumption by
the blocked worker executes that already-linearized authorization and cannot
create another. All durable attempt and settlement transactions retain ADR
0006's ordinary owner-epoch, incarnation, version, and commit-unknown fences.

## Governance Record

| Decision | Authority | Authority evidence | Bound bytes |
| --- | --- | --- | --- |
| Acceptance | — | — | — |

<a id="concept-adr-0018-context"></a>
## Context

The same staged request digest cannot answer whether a provider transport was
never invoked or accepted a possibly billed request before the caller crashed.
Treating byte availability as retry permission can therefore duplicate cost and
assistant effects after recovery.

Durable attempt-open alone does not remove that ambiguity. It proves which
request may be sent, but a crash can occur before or after the transport handoff.
M2 has no portable provider reconciliation contract able to distinguish those
states. The safe default must conserve the possible bill and refuse to repeat
the call.

Ownership adds a second race. If the coordinator checks current ownership and
then separately wakes a provider worker, succession can occur in the gap. The
authorization must linearize inside the same Control operation that validates
the current owner.

Technical depth: [Why identity is not authority](0018-provider-attempt-authority-and-recovery-technical.md#technical-adr-0018-context).

<a id="concept-adr-0018-decision"></a>
## Decision

**Every provider attempt commits before dispatch and receives exactly one
current-owner dispatch permit. An unsettled attempt is never redispatched.**

For one staged model operation, M2 permits exactly two total provider attempts:
attempt one plus one retry. Attempt two is legal only after attempt one has a
durable exact settlement whose transport classification is `not_dispatched`.
Succession never resets the allowance. The attempt-open record version carries
this policy: version 1 admits only attempts one and two and requires the exact
prior settlement before two. A different allowance requires a new record
version and decision.

The coordinator durably opens an attempt, starts a provider worker blocked on a
fresh permit reference, and asks Control to authorize the exact worker,
operation, attempt, journal position, owner, and deadline. Control validates all
of them against its serialized current state and sends the matching one-use
permit directly to the worker before replying. That send is provider dispatch.
The worker accepts the matching permit once and invokes the adapter at most
once. A duplicate, wrong, or stale permit does nothing.

Before the permit is sent, an exact local refusal may settle
`not_dispatched` and consumes no provider usage. After a possible permit send,
every timeout, process death, malformed reply, ambiguous Control result,
unclassified adapter error, or recovered open attempt is
`dispatched_or_unknown`. It receives conservative accounting and cannot retry.
A future provider-specific reconciliation contract may prove another result,
but no generic heuristic or staged-byte comparison may do so.

Complete valid provider usage is retained as reported. Missing, partial,
malformed, or overflowing usage after possible dispatch consumes the exact
remaining cumulative run allowance as estimated accounting. This conservative
charge is run-control truth, not a claim about the provider invoice, and does
not manufacture executor `outcome_unknown` or `bound_reached`.

Reply/error classification, accounting, conversation admission, next action,
and terminal selection commit as one durable settlement verdict. A late valid
reply after a committed abort or deadline is evidence-only. A recovered open
attempt with neither earlier winner settles terminal provider failure with
owner-loss evidence and no second call.

Technical depth: [The exact provider-attempt protocol](0018-provider-attempt-authority-and-recovery-technical.md#technical-adr-0018-decision).

<a id="concept-adr-0018-alternatives"></a>
## Alternatives

**Redispatch the same staged bytes after owner loss.** This preserves request
identity but cannot prove the first transport did not accept the call. It can
duplicate a bill and assistant effect. Not taken.

**Let the worker ask Control immediately before adapter invocation.** The
worker's call can overtake coordinator ownership-readiness messages and makes
Control ordering depend on scheduler arrival. Not taken.

**Return authorization to the coordinator, then let it wake the worker.**
Ownership can change between Control's reply and the send. Direct Control-to-
worker delivery closes that gap. Not taken.

**Persist the permit.** A durable permit would still not prove whether network
transport happened after it committed and would invite replay to mistake
authority history for effect truth. The durable facts are attempt open and
settlement; the permit is an ephemeral linearization. Not taken.

**Use a finite permit timeout as a verdict.** A timeout proves no ordering fact:
Control may have sent the permit or a reply may be delayed. Ambiguity is
dispatched-or-unknown, never `not_dispatched`. Not taken.

**Allow an unbounded or configurable retry count in M2.** That makes replay
authority depend on current process configuration. Version 1 fixes exactly two
total attempts; future policy is additive and versioned. Not taken.

Technical depth: [Alternative costs](0018-provider-attempt-authority-and-recovery-technical.md#technical-adr-0018-alternatives).

<a id="concept-adr-0018-consequences"></a>
## Consequences

`Loopex.LLM.complete/3` remains source-compatible because its error detail was
already `term()`. Behavior becomes deliberately stricter: an adapter that cannot
prove an exact pre-transport refusal still conforms, but its errors are
classified dispatched-or-unknown, consume conservative allowance, and cannot
retry. Raw provider errors, credentials, and tenant identifiers enter no
durable, public, progress, diagnostic, fixture, or rendered plane.

Control gains an internal provider-dispatch operation and the model worker
blocks until its exact permit. Neither is public API. A permit sent immediately
before succession remains valid for that one attempt; the successor conserves
the ambiguity and never creates a competing call.

The private attempt, termination, settlement, usage, and pending-state records
are unreleased. Development journals produced under a different attempt policy
fail closed; there is no migration. Rollback restores the attempt schemas,
Control permit path, Model normalization, accounting, stream-domain behavior,
recovery reducer, and tests atomically.

Acceptance of this ADR changes no M2 plan or gate byte. M2 Amendment 4 must
declare it as a closure prerequisite, replace every conflicting provider
retry/recovery clause, and lock the permit, attempt-limit, settlement,
accounting, termination-order, crash-recovery, and no-leak evidence before
dependent implementation or closure.

Technical depth: [Compatibility, rollback, and evidence](0018-provider-attempt-authority-and-recovery-technical.md#technical-adr-0018-consequences).

## Links

- [Provider recovery vision disposition](../developer/agent-context-map.md#disposition-provider-recovery-proof-before-retry-2026-09-01)
- [ADR 0010 — Provider continuation and exact context staging](0010-provider-continuation-and-context-staging.md#concept)
- [ADR 0011 — Session input algebra and streaming progress](0011-session-input-algebra-and-streaming.md#concept)
- [ADR 0014 — Stream closure at owner loss](0014-stream-closure-at-owner-loss.md#concept)
- [ADR 0017 — Durable context and record admission budgets](0017-durable-context-admission-budget.md#concept)
- [M2 technical plan](../plans/M2-technical.md#technical-depth)
