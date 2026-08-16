# 0005: Technical depth

<a id="technical-depth"></a>
## Technical depth

Concept: [Milestone supersession](0005-milestone-supersession.md#concept).

<a id="technical-adr-0005-context"></a>
## Why the Existing Mechanism Escapes the Tension

Concept: [Context](0005-milestone-supersession.md#concept-adr-0005-context).

Acceptance is two-phase. A plan candidate exists at commit `C` in state `Open`,
independent review examines `C`, and a later commit records the acceptance and
binds `C`'s SHA. The SHA is knowable when it is written because the bytes it
names already exist, and review attaches to a commit that does not change
afterwards.

In-place amendment could not reproduce that. Its corrected bytes and its record
had to be one commit, because the anchor rejects any revision whose governed
bytes lack a matching effective binding — so the record could never name its own
commit, and identity fell back to content, which cannot bind an exact-SHA
review.

Supersession introduces no new binding. A successor is an ordinary milestone
using the ordinary two-phase path, so every property already reviewed and
implemented for acceptance holds unchanged.

<a id="technical-adr-0005-decision"></a>
## Exact States, Records, and Checker Obligations

Concept: [Decision](0005-milestone-supersession.md#concept-adr-0005-decision).

`Superseded` joins the register's lifecycle states. A superseded row keeps its
Concept, Technical depth, and Gate links, because the files it names remain in
the tree exactly as accepted.

The successor's Concept plan carries a single line outside both normative
envelopes:

```markdown
## Supersedes

`<superseded milestone name>` — <reason the predecessor was replaced>
```

### Checker obligations

1. `Superseded` is terminal. A milestone recorded as `Superseded` at any
   reachable revision is `Superseded` at every later reachable revision.
2. A milestone may only become `Superseded` from a state that has a plan pair
   and gate. A `Blocked` candidate is withdrawn by removing its row, not by
   superseding it.
3. A superseded milestone's plan pair and gate remain present and byte-identical
   to their accepted bindings. Supersession preserves the record; it does not
   release the bytes.
4. A superseded row is excluded from the active, next-candidate, and last-closed
   derivations. It never contributes to the derived status summary.
5. At most one milestone in the register names a given milestone in its
   `## Supersedes` section, so a superseded milestone has exactly one successor.
6. A `## Supersedes` section names a milestone that exists in the register with
   state `Superseded`, and no milestone supersedes itself.
7. The transition to `Superseded` changes only the register state and the
   derived status blocks. No plan, gate, envelope, or governance byte changes in
   that commit.

Obligation 3 is what distinguishes supersession from abandonment: the
superseded plan stays readable and its acceptance stays provable, so the record
shows what was agreed and that it was replaced rather than erased.

### What these obligations do not decide

They do not decide whether a successor repairs the defect that caused
supersession, whether its scope matches its predecessor's, or whether the reason
given is truthful. A successor is reviewed and accepted on its own merits like
any milestone, and that review is the only control over adequacy.

They also do not prevent a milestone from being superseded repeatedly through a
chain of successors. Each link is an ordinary acceptance, so the chain carries no
special semantics and needs none.

<a id="technical-adr-0005-alternatives"></a>
## Alternative Analysis

Concept: [Alternatives](0005-milestone-supersession.md#concept-adr-0005-alternatives).

**In-place amendment.** Five revisions, five rejections, documented in
[ADR 0004](0004-plan-amendment-supersession.md#concept). Successive reviews
removed a derived classifier that could disguise a weakening, fixed a transition
that could execute only once, replaced graph-derived identity that a merge could
switch, and universally quantified a binding rule that had been existential. The
final review identified the remaining defect as structural rather than
incidental. Its correction granularity remains genuinely better than
supersession's, which is why it is parked rather than withdrawn.

**History rewrite.** Simplest before integration. Rejected as policy because
after publication it is disruptive and detectable rather than impossible, cannot
recall fetched copies, and teaches that an inconvenient record can be deleted.

**In-place edit of an accepted row.** Removes the anchor that makes acceptance
meaningful.

**Close and reopen.** Closure requires every outcome resolved, so a defective
milestone cannot legitimately close, and reopening discards proved evidence.

<a id="technical-adr-0005-consequences"></a>
## Operational Consequences

Concept: [Consequences](0005-milestone-supersession.md#concept-adr-0005-consequences).

- A defect in an accepted gate costs a full re-cut: new plan pair, new gate, new
  review, new acceptance. Expect that cost to concentrate attention on the gate
  before acceptance, which is where it belongs.
- The register accumulates terminal rows. It stays readable only if the derived
  status ignores them, which obligation 4 requires.
- Successor naming is an operator choice under the existing slug rules. A
  successor to `M0` is a new registered name, not a mutation of `M0`.
- Work already done under a superseded milestone is not automatically void; it
  is unbound. The successor's plan decides what to keep, and its gate must prove
  whatever it claims.
- This mechanism is Python inside the seed bridge and is in scope for the `M0`
  self-hosting migration's equivalence evidence.

<a id="technical-adr-0005-compatibility"></a>
## Compatibility and Rollback Mechanics

Concept: [Compatibility, migration, and rollback](0005-milestone-supersession.md#concept-adr-0005-compatibility).

No public surface exists. A register with no superseded row behaves exactly as
before, so no accepted plan requires migration.

Rollback is removing the state and its enforcement while no milestone has been
superseded anywhere in reachable history. After that, the row is anchored and
removing it fails the check that motivated this decision.

Changing the terminal property, the preservation obligation, or the one-successor
rule requires a successor ADR declaring `Supersedes: 0005`.
