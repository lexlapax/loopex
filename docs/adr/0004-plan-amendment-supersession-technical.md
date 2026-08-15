# 0004: Technical depth

<a id="technical-depth"></a>
## Technical depth

Concept: [Plan amendment and supersession](0004-plan-amendment-supersession.md#concept).

<a id="technical-adr-0004-context"></a>
## What the Anchor Guarantees and Forbids

Concept: [Context](0004-plan-amendment-supersession.md#concept-adr-0004-context).

The status checker walks every revision reachable from `HEAD`. The first time a
completed governance row appears it becomes an anchor, and any later revision
whose row differs or is absent fails with
`completed Acceptance governance record changed at <revision>`.

Two consequences bound this design:

1. A recorded acceptance cannot be edited, reverted, or removed by any operation
   that leaves the commit reachable. Correction must be additive.
2. **The anchor also validates intermediate revisions.** Current envelope and
   gate digests are checked against the effective binding at every revision, so
   a commit that changes plan bytes without simultaneously changing the
   effective binding is invalid — and stays invalid forever, because history is
   re-walked. This is what made a two-phase amendment unrealizable, and it is
   why corrected bytes and their amendment row must be one commit.

<a id="technical-adr-0004-decision"></a>
## Exact Record, Derivation, and Checker Obligations

Concept: [Decision](0004-plan-amendment-supersession.md#concept-adr-0004-decision).

The Concept plan carries this table after `## Governance Records`, outside both
normative envelopes:

```markdown
## Amendments

| # | Class | Authority | Authority evidence | Supersedes | Bound bytes | Reason |
| --- | --- | --- | --- | --- | --- | --- |
```

Field rules:

- `#` is consecutive from 1, with no gaps or reordering.
- `Class` is exactly `Correction`, `Strengthening`, or `Weakening`.
- `Authority` is `Maintainer`, or `Delegate: <recorded identity>` only when the
  derived class is not `Weakening`.
- `Authority evidence` is `[disposition](<durable-pointer>)`.
- `Supersedes` carries the exact digest triple of the binding being replaced:
  `concept sha256:<64-hex>; technical sha256:<64-hex>; gate sha256:<64-hex>`.
  For row 1 that is the Acceptance row's triple.
- `Bound bytes` carries the new triple in the same form. It has **no candidate
  SHA**: the revision where the row first appears is its candidate, discovered
  by the history walk rather than declared.
- `Reason` is non-empty. For `Weakening` it names the protection given up.

### Derived minimum class

Comparing the superseded commitment against the new one yields a floor. A
declared class weaker than the floor is rejected; a stronger one is permitted,
because over-declaring is never the abuse.

| Observed difference | Derived floor |
| --- | --- |
| An outcome ID present before is absent after | `Weakening` |
| A protected selector present before is absent after | `Weakening` |
| The count of locked gate commands decreases | `Weakening` |
| An outcome's evidence class cell changes | `Strengthening` |
| Only additions | `Strengthening` |
| Byte changes with none of the above | `Correction` |

Ordering is `Correction` < `Strengthening` < `Weakening`. The evidence-class row
resolves to `Strengthening` rather than `Weakening` because a changed class may
strengthen or weaken and the check cannot tell; forcing it above `Correction`
denies the quiet path while leaving the judgment to review.

### Checker obligations

1. The effective binding is the highest-numbered complete amendment, otherwise
   the Acceptance row. Current digests verify against the effective binding.
2. Every amendment row is exactly empty or structurally complete.
3. `Bound bytes` equals the current concept envelope, technical envelope, and
   gate digests at every revision where the row is present.
4. `Supersedes` equals the previous binding's exact triple, so the chain is
   verifiable end to end and cannot skip a link.
5. At the revision where row N first appears, rows 1 through N−1 are present and
   byte-identical to their anchors, and exactly one new complete row appears.
6. The revision anchoring row N descends from the revision anchoring row N−1,
   and is distinct from it.
7. A completed amendment row is anchored across reachable history exactly like a
   completed governance row.
8. No amendment may be recorded once Closure is complete.

Obligations 4, 5, and 6 together defeat a verified rewind: re-binding older
bytes is representable, but it is a new row whose derived floor is `Weakening`
because the corrections it removes are missing outcomes, selectors, or commands.

### Additive ADR supersession

`check_status.py` accepts only `Proposed` and `Accepted`, and an accepted ADR
pair is anchored, so marking a predecessor `Superseded` fails both parsing and
history validation. A successor therefore declares `Supersedes: NNNN` in its own
Concept file and the predecessor's bytes are never touched. Its status stays
`Accepted`, which remains true: it was accepted, and a later decision replaced
it.

<a id="technical-adr-0004-alternatives"></a>
## Alternative Analysis

Concept: [Alternatives](0004-plan-amendment-supersession.md#concept-adr-0004-alternatives).

**Milestone supersession.** A `Superseded` lifecycle state, the defective
milestone left anchored, and a successor plan accepted fresh. Equally additive,
and roughly one state plus its derived capsule against a class taxonomy, a
derivation table, and eight obligations. Rejected because the unit of correction
is the whole plan: a one-line gate defect costs a full re-cut, re-review, and
re-acceptance, which prices the cheap fix out and encourages living with
defects. Worth revisiting if amendments prove rarer than expected.

**History rewrite.** Simplest before integration and genuinely available while a
branch is private. Rejected as a policy because it is only disruptive and
detectable after publication rather than impossible, cannot recall copies
already fetched, and normalises deleting an uncomfortable record.

**In-place edit of the accepted row.** Requires removing the anchor that proves
an acceptance was not re-cut.

**Close and reopen.** Closure requires every outcome resolved, so a defective
milestone cannot legitimately close, and reopening discards proved evidence.

**A second Acceptance row.** Leaves the effective binding ambiguous and requires
the anchor to permit a shape it forbids.

<a id="technical-adr-0004-consequences"></a>
## Operational Consequences

Concept: [Consequences](0004-plan-amendment-supersession.md#concept-adr-0004-consequences).

- The derived class is a structural floor. Equal-count substitution of real
  commands with trivially passing ones satisfies every obligation, so review
  still owns semantic adequacy. The derivation removes the easy abuse; it does
  not remove the need for a reviewer who reads the commands.
- Reading the current commitment means following the chain to the effective
  binding, not reading the Acceptance row.
- Review obligation attaches to the whole corrected commitment, not the diff: a
  corrected envelope changes what the gate must prove.
- One commit carries both corrected bytes and the row, so an amendment is not a
  two-step transition and cannot be half-applied.
- This mechanism is Python inside the seed bridge and is in scope for the `M0`
  self-hosting migration's equivalence evidence.

<a id="technical-adr-0004-compatibility"></a>
## Compatibility and Rollback Mechanics

Concept: [Compatibility, migration, and rollback](0004-plan-amendment-supersession.md#concept-adr-0004-compatibility).

No public surface exists. A plan with no `## Amendments` table behaves exactly as
before, so no accepted plan requires migration.

Rollback is removing the table and its enforcement while no amendment row is
complete anywhere in reachable history. Once one is complete it is anchored, and
removing it would fail the check that motivated this decision.

Changing the class vocabulary, the derivation table, the chain obligations, the
non-delegable status of `Weakening`, or the re-review obligation requires a
successor ADR declaring `Supersedes: 0004`.
