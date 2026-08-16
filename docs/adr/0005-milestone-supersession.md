# 0005. Milestone supersession

<a id="concept"></a>
## Concept

Technical depth: [Supersession mechanics](0005-milestone-supersession-technical.md#technical-depth).

- **Status:** Proposed
- **Date:** 2026-08-16
- **Decision owner:** Maintainer
- **Prerequisite for:** correcting an accepted plan or gate before implementation

## Governance Record

| Decision | Authority | Authority evidence | Bound bytes |
| --- | --- | --- | --- |
| Acceptance | — | — | — |

<a id="concept-adr-0005-context"></a>
## Context

An accepted milestone's governance record is anchored permanently across
reachable history, which is what makes acceptance tamper-evident. A defect found
after acceptance therefore has no correction path: `M0` was accepted with an
outcome its own gate could not prove, and reverting failed against the anchor.

[ADR 0004](0004-plan-amendment-supersession.md#concept) proposed correcting an
accepted plan in place through an append-only amendment chain. Five revisions
were rejected in independent review. The final review named the reason as a
three-way tension rather than a defect: content identity is required because
commit identity is defeated by re-parenting; commit identity is required because
exact-SHA review does not transfer between commits; and a single-commit
amendment cannot record its own SHA, while a two-commit amendment leaves an
interval the anchor rejects. Any two can hold; the third fails.

Acceptance itself never had this problem, because it is already two-phase: a
candidate exists, and a later commit binds its SHA. This decision reuses that
property instead of inventing a second one.

Technical depth: [Why the existing mechanism escapes the tension](0005-milestone-supersession-technical.md#technical-adr-0005-context).

<a id="concept-adr-0005-decision"></a>
## Decision

- A milestone may be marked `Superseded` in the register. Its plan pair, gate,
  and governance rows are never edited and remain exactly as accepted.
- `Superseded` is terminal. A superseded milestone never moves to any other
  state, and its outcomes are neither proved nor waived — they are abandoned
  with the plan that declared them.
- **Supersession is not a standalone act.** A milestone becomes `Superseded`
  only in the commit that opens its successor, so a superseded milestone always
  has exactly one successor and can never be left abandoned by a register edit.
- Correction is therefore a **successor milestone**: an ordinary milestone
  opened gate-first, reviewed at its exact candidate SHA, and accepted binding
  that candidate. No new binding, identity, or chain semantics are introduced.
- Only a milestone with a **completed acceptance record** may be superseded, and
  only from `Accepted`, `In progress`, or `In review`. A milestone that is
  merely `Open` is withdrawn by removing its row, and a `Closed` milestone is
  history that proved its outcomes and is never replaced. Eligibility is judged
  against every parent of the superseding revision, so a merge cannot launder an
  ineligible state by pairing it with an eligible one.
- A successor that has superseded something can never be withdrawn from the
  register. It may advance, and it may itself be superseded later, but removing
  it would strand its predecessor with no successor.
- The successor's Concept plan records the relationship: which milestone it
  replaces, why, the maintainer authority, and durable evidence of that
  disposition. Once complete that record is anchored and immutable, like any
  governance record.
- A superseded milestone is not the active milestone, the next candidate, or the
  last integrated checkpoint. It is history.

Technical depth: [Exact states, records, and checker obligations](0005-milestone-supersession-technical.md#technical-adr-0005-decision).

<a id="concept-adr-0005-alternatives"></a>
## Alternatives

**In-place amendment** is [ADR 0004](0004-plan-amendment-supersession.md#concept),
parked after five rejections. It offered a genuinely better correction unit — a
one-line gate defect stays a one-line fix — and it is worth revisiting if
supersession proves too coarse in practice. It is not adopted now because no
revision resolved the identity tension, and each attempt enlarged the surface
that review had to check.

**History rewrite** erases the acceptance instead of recording its replacement.
Available while a branch is private, disruptive and detectable afterwards, and
it normalises deleting an uncomfortable record.

**Editing the accepted row** removes the anchor that proves an acceptance was
not re-cut. **Closing and reopening** cannot apply, because closure requires
every outcome proved and a defective milestone cannot legitimately close.

Technical depth: [Alternative analysis](0005-milestone-supersession-technical.md#technical-adr-0005-alternatives).

<a id="concept-adr-0005-consequences"></a>
## Consequences

The correction unit is a whole milestone. A one-line gate defect costs a re-cut
plan pair, a fresh review, and a fresh acceptance. That is the deliberate price
of using only the two-phase mechanism that already works, and it makes careful
review before acceptance cheaper than correction after it.

Milestone names accumulate, and the register grows a terminal state whose rows
are never removed. Reading history means reading past superseded rows.

Nothing verifies that a successor actually repairs the defect that caused
supersession. The reason is recorded and the successor is reviewed; adequacy is
a review judgment, as it is for any milestone.

Technical depth: [Operational consequences](0005-milestone-supersession-technical.md#technical-adr-0005-consequences).

<a id="concept-adr-0005-compatibility"></a>
## Compatibility, Migration, and Rollback

No released surface exists. A register with no superseded row behaves exactly as
before, so nothing requires migration.

Rollback is removing the state and its enforcement while no milestone is
superseded. Once a milestone is superseded, its row is anchored like any
completed governance record.

Technical depth: [Compatibility and rollback mechanics](0005-milestone-supersession-technical.md#technical-adr-0005-compatibility).

## Links

- [ADR 0004](0004-plan-amendment-supersession.md#concept) — the parked in-place
  amendment approach and why it was not adopted
- [Plans register](../plans/README.md) — lifecycle states and governance records
- [AGENTS.md](../../AGENTS.md) — acceptance, gate locks, non-delegable decisions
