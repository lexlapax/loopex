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
   complete row's `Authority` is the literal `Maintainer`.
3. Each row's `Bound bytes` equals the concept envelope, technical envelope, and
   gate digests **at a revision that introduced that row**, not at current
   `HEAD`. A superseded row keeps describing the bytes it bound.
4. `Supersedes` equals the previous binding's exact triple, so the chain is
   verifiable end to end and cannot skip a link.
5. At any revision introducing row N, rows 1 through N−1 are present and
   byte-identical to their anchors, and exactly one new complete row appears.
6. A completed amendment row is anchored across reachable history exactly like a
   completed governance row.
7. The Closure candidate carries the exact amendment table present at closure,
   byte-identical. A closure prepared against an earlier commitment therefore
   cannot be merged in afterwards, even when its digest triple coincides with
   the current one.
8. No amendment may be recorded once Closure is complete.

### Why identity is content, not a commit

An earlier revision tried to make a row's candidate the unique revision
introducing it on first-parent history. Review demonstrated the defeat: two
siblings introduce identical rows and identical governed bytes, then a merge
taking the unreviewed sibling as first parent fast-forwards the reviewed ref and
silently changes the selected candidate. Every obligation still passed. The same
ambiguity applies to the revision completing Acceptance, which can also occur on
siblings whose equal values the anchor collapses.

Graph position is not durable: commits can be re-parented, merged, and
fast-forwarded while governed bytes stay identical. So no obligation depends on
it. A row's identity is its bound digests plus its disposition pointer, and two
commits carrying identical governed bytes represent the same commitment because
they promise the same thing.

Obligation 7 exists because that reasoning fails for closure. Digest equality
alone permits an A→B→A amendment sequence on one branch and a closure prepared
against the original A on another, merging to a Closed milestone whose digests
match but whose closure candidate never contained or reviewed the amendments.
Requiring the closure candidate to carry the exact amendment table closes it by
content rather than by ancestry.

### What these obligations do not decide

They verify that the record is append-only, single-commit, digest-chained,
ordered, carried intact into closure, and textually marked as a maintainer
decision.

They decide nothing about content. Narrowing an outcome's text, deleting a
technical constraint, removing a fixture or vector, downgrading an evidence
class, or substituting a trivially passing command all satisfy every obligation.
No structural rule distinguishes them from a genuine correction, which is why
this design does not attempt one and why authority is not delegable.

They also decide nothing about identity or signature. `Authority` is matched as
literal text and `Authority evidence` as link syntax; neither the signer nor the
content of the disposition pointer is verified. The maintainer's disposition and
the independent review of the corrected commitment are both governance controls,
and reviewers produce findings while the maintainer accepts or rejects.

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
- No obligation depends on branch shape, so rebase, merge, and fast-forward
  integration are all safe. That is the point of content-based identity: a
  workflow cannot break the record by re-parenting it.
- Two commits may legitimately carry the same amendment. Attribution to a person
  runs through the disposition pointer, not the commit SHA, and a reviewer
  checking attribution should follow the pointer rather than the graph.
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
