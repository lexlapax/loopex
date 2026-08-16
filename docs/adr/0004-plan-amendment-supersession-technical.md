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

Three consequences bound this design:

1. A recorded acceptance cannot be edited, reverted, or removed by any operation
   that leaves the commit reachable. Correction must be additive.
2. The anchor validates intermediate revisions. A commit that changes plan bytes
   without simultaneously establishing the matching binding is invalid, and
   stays invalid because history is re-walked. Corrected bytes and their row are
   therefore one commit.
3. A binding that must equal *current* bytes can only ever describe the latest
   state. Historical rows must therefore be validated against the bytes at their
   own introducing revision, or the second amendment invalidates the first.

<a id="technical-adr-0004-decision"></a>
## Exact Record and Checker Obligations

Concept: [Decision](0004-plan-amendment-supersession.md#concept-adr-0004-decision).

The Concept plan carries this table after `## Governance Records`, outside both
normative envelopes:

```markdown
## Amendments

| # | Authority | Authority evidence | Supersedes | Bound bytes | Reason |
| --- | --- | --- | --- | --- | --- |
```

Field rules:

- `#` is consecutive from 1, with no gaps or reordering.
- `Authority` is exactly `Maintainer`. No delegate value exists, so the field is
  a constant that the check enforces rather than an authority decision it
  evaluates.
- `Authority evidence` is `[disposition](<durable-pointer>)`.
- `Supersedes` carries the exact digest triple of the binding being replaced:
  `concept sha256:<64-hex>; technical sha256:<64-hex>; gate sha256:<64-hex>`.
  For row 1 that is the Acceptance row's triple.
- `Bound bytes` carries the new triple in the same form, with no candidate SHA.
- `Reason` is non-empty, and names any protection given up.

### Checker obligations

1. The effective binding is the highest-numbered complete amendment, otherwise
   the Acceptance row. Only the effective binding is verified against current
   envelope and gate digests.
2. Every amendment row is exactly empty or structurally complete, and every
   complete row's `Authority` is `Maintainer`.
3. Each row's `Bound bytes` equals the concept envelope, technical envelope, and
   gate digests **at the revision that introduced that row**, not at current
   `HEAD`. A superseded row keeps describing the bytes it bound.
4. `Supersedes` equals the previous binding's exact triple, so the chain is
   verifiable end to end and cannot skip a link.
5. Row N is introduced by exactly one revision on the first-parent history from
   `HEAD`. That revision is row N's candidate, and candidate identity is
   therefore unique even when a sibling branch introduces identical bytes.
6. Row N's candidate descends from row N−1's candidate and is distinct from it.
   Row 1's candidate descends from the revision that completed Acceptance.
7. At row N's candidate, rows 1 through N−1 are present and byte-identical to
   their anchors, and exactly one new complete row appears.
8. A completed amendment row is anchored across reachable history exactly like a
   completed governance row.
9. No amendment may be recorded once Closure is complete.

### What these obligations do not decide

They verify that the record is append-only, single-commit, uniquely
attributable, digest-chained, chronologically ordered, and maintainer-signed.

They decide nothing about content. Narrowing an outcome's text, deleting a
technical constraint, removing a fixture or vector, downgrading an evidence
class, or substituting a trivially passing command all satisfy every obligation.
No structural rule distinguishes them from a genuine correction, which is why
this design does not attempt one and why authority is not delegable. The
independent review of the corrected commitment is the only control over content,
and it is not a formality.

### Additive ADR supersession

`check_status.py` accepts only `Proposed` and `Accepted`, and an accepted ADR
pair is anchored, so marking a predecessor `Superseded` fails both parsing and
history validation. A successor declares `Supersedes: NNNN` in its own Concept
file and the predecessor is never touched. Its status stays `Accepted`, which
remains true: it was accepted, and a later decision replaced it. Validating that
the target exists and that no cycle forms is not yet implemented and is named
here as a known gap rather than an implied guarantee.

<a id="technical-adr-0004-alternatives"></a>
## Alternative Analysis

Concept: [Alternatives](0004-plan-amendment-supersession.md#concept-adr-0004-alternatives).

**Derived classification.** Two rejected attempts. The second compared outcome
identifiers, protected selectors, locked-command counts, and evidence-class
cells. Review demonstrated passing sequences that reduced coverage anyway: an
outcome kept by identifier while narrowed in text, a constraint deleted from the
technical envelope, an equal-count substitution of a real command by a trivial
one, and a two-step replace-then-restore whose steps each classified as benign.
The approach was abandoned because its only beneficiary was delegated
amendments, and delegation is not needed.

**Milestone supersession.** A `Superseded` lifecycle state with the defective
milestone left anchored and a successor accepted fresh. Equally additive and far
smaller. Rejected because the unit of correction is the whole plan, so the cheap
fix becomes expensive and defects get tolerated instead. Worth revisiting with
evidence about amendment frequency.

**History rewrite.** Simplest before integration, genuinely available while a
branch is private. Rejected as policy: after publication it is disruptive and
detectable rather than impossible, cannot recall fetched copies, and normalises
deleting an uncomfortable record.

**In-place edit** removes the anchor. **Close and reopen** cannot apply, since
closure requires every outcome resolved. **A second Acceptance row** leaves the
effective binding ambiguous.

<a id="technical-adr-0004-consequences"></a>
## Operational Consequences

Concept: [Consequences](0004-plan-amendment-supersession.md#concept-adr-0004-consequences).

- Reading the current commitment means following the chain to the effective
  binding, not reading the Acceptance row.
- Review attaches to the whole corrected commitment, not the diff: a corrected
  envelope changes what the gate must prove.
- Every amendment is a maintainer bottleneck by design. If that becomes painful,
  the correct response is fewer defects reaching acceptance, not delegation.
- Obligation 5 makes first-parent history load-bearing. A workflow that
  integrates amendments by rebase or fast-forward is fine; one that buries an
  amendment on a non-first-parent side of a merge breaks candidate identity.
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

Changing the maintainer-only rule, the chain obligations, the re-review
obligation, or the single-commit rule requires a successor ADR declaring
`Supersedes: 0004`.
