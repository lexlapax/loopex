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
`M0` was accepted with an outcome its own gate could not prove, and the attempt
to revert failed against the anchor.

A first proposal for this decision was rejected in independent review. It let a
coverage reduction pass as a correction, and its two-phase transition could not
execute at all: corrected bytes had to exist in a commit before the row binding
them, but at that commit the original acceptance was still effective, so the
anchor rejected the very bytes the amendment existed to introduce. Both failures
came from treating classification and sequencing as things a record declares
rather than things a check derives.

Technical depth: [What the anchor guarantees and forbids](0004-plan-amendment-supersession-technical.md#technical-adr-0004-context).

<a id="concept-adr-0004-decision"></a>
## Decision

- A Concept plan carries an append-only `## Amendments` table outside both
  normative envelopes. The original Acceptance row is never edited.
- Corrected bytes and the amendment recording them land in **one** commit. An
  amendment binds digests, not a separate candidate commit, so there is never an
  interval where changed bytes have no effective binding.
- The effective binding is the last complete amendment; with no amendments it is
  the Acceptance row. Closure binds whatever is effective.
- An amendment is classified **Correction**, **Strengthening**, or
  **Weakening**, and the check **derives a minimum class** by comparing the
  superseded commitment with the new one. A declared class weaker than the
  derived minimum is rejected.
- Any removed outcome, removed protected selector, reduced count of locked gate
  commands, or changed evidence class forces at least the derived floor. A
  reduction can therefore never be recorded as a correction.
- Weakening requires the maintainer directly and must state the protection lost.
- The amendment sequence is verified, not declared: each row supersedes the
  previous binding's exact digests, appears in a revision descending from the one
  that anchored its predecessor, carries every earlier row unchanged, and adds
  exactly one row.
- Every amendment re-opens independent review of the whole corrected commitment.
- Amendments are available only while the milestone is not Closed.
- An architecture decision is superseded **additively**: the successor declares
  `Supersedes: NNNN` and the predecessor's accepted bytes are never edited.

Technical depth: [Exact record, derivation, and checker obligations](0004-plan-amendment-supersession-technical.md#technical-adr-0004-decision).

<a id="concept-adr-0004-alternatives"></a>
## Alternatives

**Milestone supersession** — leave the defective milestone's acceptance
anchored, mark it superseded, and accept a successor plan and gate — was
seriously weighed. It is equally additive and needs far less machinery. It was
rejected because it re-cuts an entire plan, its review, and its acceptance for
any defect, including a one-line gate correction, which makes the cheap fix
expensive and therefore discourages fixing.

**History rewrite** was rejected. It is not impossible after publication, only
disruptive and detectable, and it cannot recall copies already held. Before
integration it is genuinely the simplest option; it loses because auditability
of what was agreed is worth more than the convenience of erasing it.

**Editing the accepted row** was rejected: the anchor is the mechanism, not an
obstacle to it. **Closing and reopening** was rejected: closure requires every
outcome proved, so a defective milestone cannot legitimately close.

Technical depth: [Alternative analysis](0004-plan-amendment-supersession-technical.md#technical-adr-0004-alternatives).

<a id="concept-adr-0004-consequences"></a>
## Consequences

Acceptance stays permanent and auditable, and a correction becomes a visible,
attributed, derived-and-reviewed event.

The derived class is a **floor, not a proof**. It catches structural reduction —
a dropped outcome, a dropped selector, fewer locked commands, a changed evidence
class. It cannot catch semantic gutting, such as replacing real commands with
trivially passing ones at equal count. Independent review still owns that
judgment; the derivation removes the easy abuse rather than all abuse, and this
ADR does not claim otherwise.

Every correction costs a disposition, a re-review, and a verified record, which
should keep careful review before acceptance cheaper than amendment after it.

Checker complexity grows materially, and all of it is Python inside the seed
bridge that `M0` must migrate to Elixir.

Technical depth: [Operational consequences](0004-plan-amendment-supersession-technical.md#technical-adr-0004-consequences).

<a id="concept-adr-0004-compatibility"></a>
## Compatibility, Migration, and Rollback

No released surface exists. A plan with no Amendments table behaves exactly as
before, so no accepted plan needs migration.

Rollback is removing the table and its enforcement while no amendment row is
complete anywhere in reachable history. Once one is complete it is anchored.

Technical depth: [Compatibility and rollback mechanics](0004-plan-amendment-supersession-technical.md#technical-adr-0004-compatibility).

## Links

- [Plans register](../plans/README.md) — governance records and digests
- [AGENTS.md](../../AGENTS.md) — acceptance, gate locks, non-delegable decisions
- [Vision: verification](../vision.md#concept-vision-verification) — evidence
  proportional to claim
