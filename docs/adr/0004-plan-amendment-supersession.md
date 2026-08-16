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
That anchoring makes acceptance tamper-evident: nobody can quietly re-cut what
was agreed.

It also leaves no path for a defect found after acceptance and before closure.
`M0` was accepted with an outcome its own gate could not prove, and reverting
failed against the anchor.

Two earlier proposals were rejected in independent review. Both tried to decide
mechanically whether an amendment reduced what was promised, and both leaked:
narrowing an outcome's text, deleting a technical constraint, removing a
fixture, downgrading an evidence class, or restoring a previously replaced
command all passed as harmless. The lesson is that structural comparison cannot
decide whether a commitment was weakened. Only a reader can.

Technical depth: [What the anchor guarantees and forbids](0004-plan-amendment-supersession-technical.md#technical-adr-0004-context).

<a id="concept-adr-0004-decision"></a>
## Decision

- A Concept plan carries an append-only `## Amendments` table outside both
  normative envelopes. The original Acceptance row is never edited.
- Corrected bytes and the amendment recording them land in **one** commit. An
  amendment binds digests, so there is never an interval where changed bytes
  have no effective binding.
- **Every amendment requires the maintainer directly.** There is no delegation
  and no classification. Because no amendment can be authorised by anyone else,
  no label needs to be trusted, derived, or policed.
- Every amendment re-opens independent review of the whole corrected
  commitment. A prior review never carries forward.
- The `Reason` states what changed and, when anything is narrowed, removed, or
  relaxed, names the protection given up. That disclosure is a maintainer
  statement checked by review, not by the repository.
- The effective binding is the last complete amendment; with no amendments it is
  the Acceptance row. Closure binds whatever is effective.
- The sequence is verified: each row supersedes the previous binding's exact
  digests, is introduced by exactly one revision on the first-parent history,
  descends from the revision anchoring its predecessor, carries every earlier
  row unchanged, and adds exactly one row.
- Amendments are available only while the milestone is not Closed.
- An architecture decision is superseded **additively**: the successor declares
  `Supersedes: NNNN` and the predecessor's accepted bytes are never edited.

Technical depth: [Exact record and checker obligations](0004-plan-amendment-supersession-technical.md#technical-adr-0004-decision).

<a id="concept-adr-0004-alternatives"></a>
## Alternatives

**Deriving a class from structural comparison** was tried twice and rejected
twice. Outcome identifiers, selector names, and command counts do not express
what a commitment promises, so a classifier built on them declares safety it
cannot deliver. Its only purpose was to let a delegate sign non-weakening
amendments; removing delegation removes the need for it entirely.

**Milestone supersession** — leave the defective milestone anchored, mark it
superseded, and accept a successor plan — remains the strongest alternative. It
is equally additive and needs roughly one lifecycle state. It was rejected
because the unit of correction is a whole plan, so a one-line gate fix costs a
full re-cut, re-review, and re-acceptance. Revisit if amendments prove rare.

**History rewrite** is not impossible after publication, only disruptive and
detectable, and it cannot recall copies already fetched. Before integration it
is genuinely simplest; it loses because auditability outweighs convenience.

**Editing the accepted row** removes the anchor that proves an acceptance was
not re-cut. **Closing and reopening** cannot apply, because closure requires
every outcome proved.

Technical depth: [Alternative analysis](0004-plan-amendment-supersession-technical.md#technical-adr-0004-alternatives).

<a id="concept-adr-0004-consequences"></a>
## Consequences

What this mechanism guarantees is narrow and worth stating exactly: the record
is append-only, chained by digests, anchored across history, applied in a single
commit, and authorised by the maintainer.

It guarantees **nothing** about whether an amendment weakens the commitment.
That judgment is entirely the independent reviewer's, and the repository makes
no claim to assist it. The mechanism's protection is that the change is visible,
attributed, and re-reviewed — not that it is safe.

Every correction costs a maintainer disposition and a fresh review, which keeps
careful review before acceptance cheaper than amendment afterwards. Nobody but
the maintainer can correct an accepted plan, which is a deliberate bottleneck.

Checker complexity grows, and all of it is Python inside the seed bridge that
`M0` must migrate to Elixir.

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
