# 0004: Technical depth

<a id="technical-depth"></a>
## Technical depth

Concept: [Plan amendment and supersession](0004-plan-amendment-supersession.md#concept).

<a id="technical-adr-0004-context"></a>
## What the Anchor Guarantees and Forbids

Concept: [Context](0004-plan-amendment-supersession.md#concept-adr-0004-context).

The status checker walks every revision reachable from `HEAD`. The first time a
completed governance row appears it is captured as an anchor, and any later
revision whose row differs or is absent fails. The observed failure is
`completed Acceptance governance record changed at <revision>`.

Three consequences follow and this decision must respect all of them:

1. A recorded acceptance cannot be edited, reverted, or removed by any operation
   that leaves the commit reachable.
2. Erasure is therefore only possible by rewriting history, which is available
   exactly until someone else depends on the branch.
3. Correction must be additive. Anything else is either a rewrite or a lie.

<a id="technical-adr-0004-decision"></a>
## Exact Record, Digests, and Checker Obligations

Concept: [Decision](0004-plan-amendment-supersession.md#concept-adr-0004-decision).

The Concept plan carries this table after `## Governance Records`, outside both
normative envelopes:

```markdown
## Amendments

| # | Class | Authority | Authority evidence | Superseded candidate | Bound bytes | Reason |
| --- | --- | --- | --- | --- | --- | --- |
```

Field rules:

- `#` is consecutive from 1 with no gaps or reordering.
- `Class` is exactly `Correction`, `Strengthening`, or `Weakening`.
- `Authority` is `Maintainer`, or `Delegate: <recorded identity>` only when the
  class is not `Weakening`.
- `Authority evidence` is `[disposition](<durable-pointer>)`.
- `Superseded candidate` is the 40-hex candidate this amendment replaces: the
  Acceptance candidate for amendment 1, and amendment N−1's candidate after
  that.
- `Bound bytes` uses the plan form:
  `candidate <40-hex>; concept sha256:<64-hex>; technical sha256:<64-hex>; gate sha256:<64-hex>`.
- `Reason` is a non-empty statement of the defect or improvement. For
  `Weakening` it names the protection being given up.

Checker obligations:

1. The effective binding is the highest-numbered complete amendment, otherwise
   the Acceptance row. Current envelope and gate digests are verified against
   the effective binding, not the Acceptance row.
2. Every amendment row is either exactly empty or structurally complete, matching
   the existing governance-row rule.
3. Each amendment's digests verify against its own historical candidate exactly
   as acceptance digests do, and its candidate must remain reachable.
4. Each amendment's `Superseded candidate` equals the candidate of the binding it
   replaces, so the chain is verifiable end to end and cannot skip a link.
5. A completed amendment row is anchored across reachable history exactly like a
   completed governance row.
6. No amendment may be recorded once Closure is complete.
7. The amendment's candidate must itself carry the same completed Acceptance row
   as current history, so an amendment cannot smuggle in a different acceptance.

An amendment commit is administrative: it changes the Amendments table, the
plan and gate bytes it binds, and nothing else. Because the new envelope and
gate bytes are part of the amendment candidate, the amendment is recorded in a
commit after the corrected bytes exist, mirroring acceptance.

<a id="technical-adr-0004-alternatives"></a>
## Alternative Analysis

Concept: [Alternatives](0004-plan-amendment-supersession.md#concept-adr-0004-alternatives).

**History rewrite.** Cheap while a branch is private and impossible once it is
not. It also removes the audit trail precisely when the audit trail matters,
and it teaches that an uncomfortable record can be deleted.

**In-place edit of the accepted row.** Requires removing the anchor, which is
the only mechanism proving an acceptance was not re-cut afterwards.

**Close and reopen.** Closure requires every outcome resolved, so a defective
milestone cannot legitimately close, and reopening discards evidence already
proved.

**A second acceptance row.** Rejected: two complete Acceptance rows leave the
effective binding ambiguous, and the anchor would have to permit a shape it
currently forbids. A separate, ordered, classified table keeps one answer.

<a id="technical-adr-0004-consequences"></a>
## Operational Consequences

Concept: [Consequences](0004-plan-amendment-supersession.md#concept-adr-0004-consequences).

- Reading the current commitment means reading the effective binding, not the
  Acceptance row. Tooling and reviewers must follow the chain.
- An amendment invalidates prior review of the affected candidate. The review
  obligation is on the new candidate as a whole, not on the diff, because a
  corrected envelope changes what the gate must prove.
- `Weakening` is the class that matters. A reviewer should treat any amendment
  labelled `Correction` that reduces coverage as mislabelled, and mislabelling
  is a blocking finding.
- The chain rule in obligation 4 means an amendment cannot be inserted or
  reordered later; the sequence is verifiable rather than declared.
- This mechanism is Python in the seed bridge and is therefore part of what `M0`
  migrates to Elixir. Its behavior is in scope for that migration's equivalence
  evidence.

<a id="technical-adr-0004-compatibility"></a>
## Compatibility and Rollback Mechanics

Concept: [Compatibility, migration, and rollback](0004-plan-amendment-supersession.md#concept-adr-0004-compatibility).

No public surface exists. A plan with no `## Amendments` table behaves exactly
as before, so no accepted plan requires migration.

Rollback is removing the table and its enforcement while no amendment row is
complete anywhere in reachable history. Once one is complete it is anchored, and
removing it would fail the same check that motivated this decision.

Changing the class vocabulary, the chain rule, the non-delegable status of
`Weakening`, or the re-review obligation changes this decision and requires an
amendment to this ADR through a new numbered ADR marking this one `Superseded`.
