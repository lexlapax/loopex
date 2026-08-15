# 0004. Plan amendment and supersession

<a id="concept"></a>
## Concept

Technical depth: [Amendment mechanics](0004-plan-amendment-supersession-technical.md#technical-depth).

- **Status:** Proposed
- **Date:** 2026-08-15
- **Decision owner:** Maintainer
- **Prerequisite for:** correcting an accepted plan or gate before closure

## Governance Record

| Decision | Authority | Authority evidence | Bound bytes |
| --- | --- | --- | --- |
| Acceptance | — | — | — |

<a id="concept-adr-0004-context"></a>
## Context

An accepted plan binds two normative envelopes and a gate, and the repository
anchors every completed governance row across all history reachable from `HEAD`.
That anchoring is deliberate: it makes acceptance tamper-evident, so nobody can
quietly re-cut what was agreed.

It also leaves no path for a defect found after acceptance and before closure.
The record cannot be reverted, and the plans register states that no amendment
mechanism exists, so any accepted-envelope byte change fails closed.

The first accepted milestone reached that state within hours. `M0` was accepted
with an outcome whose gate selector could not prove it: the outcome required
repository validation to run without Python or `jq`, and no locked command
checked any part of that. The choices available were to erase the acceptance by
rewriting published history, or to leave a locked gate that cannot prove one of
its own outcomes. Both are worse than admitting that correction needs a governed
path.

Technical depth: [What the anchor guarantees and forbids](0004-plan-amendment-supersession-technical.md#technical-adr-0004-context).

<a id="concept-adr-0004-decision"></a>
## Decision

- A Concept plan carries an append-only `## Amendments` table outside both
  normative envelopes. The original Acceptance row is never edited.
- A complete amendment records its sequence, class, authority, authority
  evidence, the superseded candidate, the new bound bytes, and the reason.
- The effective binding is the last complete amendment; with no amendments it is
  the Acceptance row. Closure binds whatever is effective, not the original.
- An amendment is classified as **Correction**, **Strengthening**, or
  **Weakening**. The class is recorded, not inferred.
- Weakening reduces scope, coverage, or evidence. It requires the maintainer
  directly, is never delegated, and must state what protection is lost.
- Every amendment requires a fresh independent review of the new candidate. A
  prior review never carries forward.
- Amendments are available only while the milestone is not Closed.
- Architecture decisions are out of scope: an ADR is superseded by a new
  numbered ADR that marks the prior one `Superseded`.

Technical depth: [Exact record, digests, and checker obligations](0004-plan-amendment-supersession-technical.md#technical-adr-0004-decision).

<a id="concept-adr-0004-alternatives"></a>
## Alternatives

Rewriting history to erase a defective acceptance was rejected. It works only
until someone depends on the branch, and it destroys the property that makes
acceptance meaningful: if a bad acceptance can be erased, an inconvenient one
can be erased too.

Editing the accepted row in place was rejected for the same reason. The anchor
is the mechanism, not an obstacle to it.

Closing and reopening the milestone was rejected. Closure requires every outcome
proved, so a milestone cannot close to escape a defect, and reopening would
discard accumulated evidence.

Leaving the defect and relying on review at closure was rejected. It produces a
locked gate that cannot prove its own outcome, which is what gate-first
discipline exists to prevent.

Technical depth: [Alternative analysis](0004-plan-amendment-supersession-technical.md#technical-adr-0004-alternatives).

<a id="concept-adr-0004-consequences"></a>
## Consequences

Acceptance stays permanent and auditable. A correction becomes a visible,
attributed, reviewed event rather than a silent edit or an erased branch, and
the full sequence of what was agreed and how it changed is readable from the
plan itself.

Every correction costs a disposition, a re-review, and a checker-verified
record. That expense is intentional: it should stay cheaper to review carefully
before accepting than to amend afterwards.

The real risk is that amendments become a routine escape from careful review.
Three properties resist that: the class is recorded so weakening cannot hide
inside a correction, weakening is non-delegable, and every amendment re-opens
review rather than inheriting the previous one.

Checker complexity grows, and this mechanism is itself part of the Python bridge
that `M0` must migrate.

Technical depth: [Operational consequences](0004-plan-amendment-supersession-technical.md#technical-adr-0004-consequences).

<a id="concept-adr-0004-compatibility"></a>
## Compatibility, Migration, and Rollback

No released surface exists. Plans accepted before this mechanism need no
migration: an absent Amendments table means the Acceptance row is effective.

Rollback is removing the table and its enforcement while no amendment has been
recorded. After an amendment exists, its row is anchored like any completed
governance record and rollback is no longer available.

Technical depth: [Compatibility and rollback mechanics](0004-plan-amendment-supersession-technical.md#technical-adr-0004-compatibility).

## Links

- [Plans register](../plans/README.md) — governance records, digests, and the
  statement that no amendment mechanism existed
- [AGENTS.md](../../AGENTS.md) — acceptance, gate locks, and non-delegable
  decisions
- [Vision: verification](../vision.md#concept-vision-verification) — evidence
  proportional to claim
