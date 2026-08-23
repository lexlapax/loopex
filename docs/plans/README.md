# Plans

Part of the [documentation index](../README.md).

An accepted Concept plan, Technical depth plan, and gate form one commitment.
Future capability rungs in
[docs/roadmap.md](../roadmap.md#concept) are candidates, not commitments.

This file is the canonical current-status register and plan index for the
checked-out revision. The root README carries only the derived summary below.
An accepted governance checkpoint may be integrated to `main`; its product work
remains on the designated milestone branch until closure. `main` therefore
describes integrated governance while its last Closed row identifies the
integrated product baseline.

<!-- loopex:current-status:start -->
## Current Status

**Revision status:** Closed milestone product baseline; active milestone `M2` is open; no next candidate is recorded.

| Field | Value |
| --- | --- |
| Integrated phase | Closed milestone product baseline |
| Last closed product checkpoint | `M1` — 2026-08-23 |
| Blockers | `M2` is open and not accepted; the recorded acceptance authority must accept both normative envelopes and the gate |
| Authorized work | Explicitly authorized planning, ADR, bootstrap, and review work only; no product implementation |
| Next maintainer decision | Accept or reject the `M2` plan pair and gate |
| Next transition | Record the acceptance governance row and move `M2` to Accepted |
| Validation | `bash scripts/check-bootstrap.sh` |
<!-- loopex:current-status:end -->

Until the first planned milestone closes, `Last closed product checkpoint` is the
exact seed-bootstrap sentinel shown above. After that it is derived from the
register's final `Closed` row in this form:

```text
`<final Closed milestone>` — YYYY-MM-DD
```

The status checker deliberately does not claim that accepted governance was
merged: identical bytes on a topic branch and on `main` are indistinguishable.
The gate-opening procedure verifies the exact base, and the mandatory
base-to-transition review verifies integration eligibility. This field states
only the product fact the register can derive.

`Integrated phase` is derived from the same rows by the same standard, and has
exactly two values. It reads `Pre-implementation planning` while the register
records no `Closed` milestone, and `Closed milestone product baseline` once one
exists. It names the kind of state, never the milestone: the checkpoint above
already identifies that row, and neither field claims a merge the checked-out
bytes cannot prove.

While `M0` was the sole blocked candidate, the repository status check derived
the complete capsule from the two founding ADR records. The seed checkpoint,
authorized-work boundary, and validation command stayed fixed, and these three
fields changed exactly as disposition advanced:

| Accepted records | Blockers | Next maintainer decision | Next transition |
| --- | --- | --- | --- |
| Neither | Both linked ADRs must be accepted before M0 opens; a replacement requires a governed guard change | Disposition ADR 0001 and ADR 0002 | After the prerequisites are accepted, the maintainer explicitly opens `M0` gate-first |
| One | The remaining linked ADR must be accepted before M0 opens; a replacement requires a governed guard change | Disposition the remaining ADR | After the prerequisites are accepted, the maintainer explicitly opens `M0` gate-first |
| Both | M0 has not been explicitly opened gate-first | Explicitly open or defer M0 | Create the branch-only M0 Concept plan, Technical depth plan, and red gate; install lifecycle-specific status checks; and move M0 to Open |

The paragraphs below record the conditions M0's opening had to satisfy. They are
kept in the past tense now that it has opened, because what they constrained is
still what a reader checks the opening against; the row above is the seed-era
transition they belonged to.

Opening `M0` had to replace the seed-specific state machine with
lifecycle-specific checks rather than merely deleting or relaxing the status
check, and it did.

`M0` could not open until ADR 0001 and ADR 0002 each carried a structurally
complete acceptance record; a rejection or status-word edit would not have
unlocked it, and choosing a replacement would have required an explicit governed
change to the named prerequisite and that guard, because the bootstrap checker
does not infer a supersession graph. Its plan pair and gate define the first
scope-specific minimalism budget rather than a universal line-count target. Its
closure candidate removes the temporary Python/`jq` bridge: repository checks and
tested client-hook paths run on the accepted Elixir/OTP toolchain, and the adapter
path is proved with `jq` absent.

That migration belongs to M0 rather than a later milestone because M0 is the
first milestone to produce an accepted Elixir/OTP toolchain and application
layout, and hosting the repository's own checks on it is the cheapest real
exercise of [ADR 0001](../adr/0001-repository-and-application-layout.md#concept)
application boundaries and
[ADR 0002](../adr/0002-bootstrap-runtime-floor.md#concept) validated version
pairs. Self-hosting the checks is evidence about the accepted decisions, not
incidental tooling. Two constraints keep it from displacing the durability,
effect-truth, and code-evolution questions M0 exists to answer: the plan carries
it as its own workstream with a declared rejoin barrier, and its minimalism
budget requires the replacement to measure and report its own size against the
bridge it retires and to name what it drops and why.

That budget sets no threshold, and this index previously said the replacement must
be "materially smaller", which contradicted the accepted technical envelope. The
envelope governs: size is a review signal weighed against the dropped-behaviour
list, never a pass condition, because a ceiling rewards compressed code, hidden
complexity, and deleted coverage. The replacement is in fact larger, and whether
that is proportionate is a judgment recorded with the evidence.
Each founding ADR's Acceptance row uses the same authority and disposition
syntax as a plan, with Bound bytes in this exact form:

```text
candidate `<40-hex>`; concept `sha256:<64-hex>`; technical `sha256:<64-hex>`
```

The candidate must be the reachable historical Proposed ADR pair. Acceptance
binds both files as they existed at that candidate. Within the pair, acceptance
changes only the Concept file's status and empty governance row; the same
administrative commit updates the derived Current Status capsule. A mismatch or
missing companion blocks acceptance.

Only accepted, delivering, closed, or explicitly named next-candidate milestones
belong in the register. A roadmap projection does not earn a row. The register
is the sole lifecycle-state owner. Zero or more `Closed` rows come first. They
may be followed by at most one delivery row (`Accepted`, `In progress`, or
`In review`). Only an `Accepted` delivery row may be followed by one `Open`
successor: the lookahead branches from integrated governance, never from the
product branch. Without a delivery row, one `Open` candidate may follow the
Closed history. The founding `Blocked` form is a single next candidate with no
plan triple. No second delivery authority or second planning lookahead is
representable.

<!-- loopex:milestone-register:start -->
## Milestone Register

| Milestone | State | Concept | Technical depth | Gate |
| --- | --- | --- | --- | --- |
| `M0` | Closed | [concept](M0.md) | [technical depth](M0-technical.md) | [gate](M0-gate.md) |
| `M1` | Closed | [concept](M1.md) | [technical depth](M1-technical.md) | [gate](M1-gate.md) |
| `M2` | Open | [concept](M2.md) | [technical depth](M2-technical.md) | [gate](M2-gate.md) |
<!-- loopex:milestone-register:end -->

When a plan exists, the Concept, Technical depth, and Gate columns link their
exact files and the register is its only lifecycle-state record. Valid states
are `Blocked`, `Open`, `Accepted`, `In progress`, `In review`, and `Closed`.
`Blocked` has no plan pair or gate. Every other state has all three. Every state
transition atomically updates the register, the complete marked Current Status
capsule above, and README's marked derived summary.

## Vocabulary

- A **capability rung** is one of the non-normative questions in the
  [vision's delivery strategy](../vision.md#concept-vision-delivery-strategy). It
  guides decomposition but does not dictate milestone or release boundaries.
- A **milestone** is bounded work governed by one accepted plan pair, one gate, and
  one closure. It may prove part or all of one or more capability rungs while
  respecting the vision's
  [delivery strategy](../vision.md#concept-vision-delivery-strategy),
  [serial barriers](../vision-technical.md#technical-vision-serial-barriers),
  and, for compatibility claims,
  [freeze rules](../vision-technical.md#technical-vision-compatibility).
- A **workstream** is a parallel slice inside a milestone. It has no independent
  plan or gate.
- A **release** is a separately authorized publication. A milestone may or may
  not produce one; only its accepted plan pair may couple the two.

Milestone names are stable operator-chosen slugs. They are either lowercase
ASCII letters/digits separated by single hyphens, an `M` followed by digits, or
a version-shaped numeric slug such as `1.0` or `v0.1`; names are at most 64
ASCII bytes and unique under case folding. `planning`, `seed`, `readme`, Windows
device basenames (`con`, `prn`, `aux`, `nul`, `com1`–`com9`, and
`lpt1`–`lpt9`), and names ending in `-gate` or `-technical` are reserved in any
letter case. A
release-shaped name grants no release authority, and the roadmap does not
prohibit a future `M1`, `v0.1`, `kernel-a`, or another accepted name.

## Files

```text
docs/plans/<name>.md              Concept plan and visible outcome progress
docs/plans/<name>-technical.md    technical constraints and evidence obligations
docs/plans/<name>-gate.md         locked executable acceptance contract
```

The Concept plan owns purpose, observable outcomes, scope, non-goals, and
visible constraints, including observable compatibility and rollout
expectations. The Technical depth plan owns prerequisites, invariants,
ownership and rejoin mechanics, evidence mapping, implementation constraints,
failure cases, migration, rollback, packaging, and exact minimalism constraints.
The companion may prove or refine the Concept plan but cannot add scope or a
decision.

The gate is separate because its canonical UTF-8/LF text and SHA-256 digest are
locked at acceptance and remain immutable for the milestone. The filename and
canonical register own plan identity and lifecycle state; neither plan repeats
them. Conforming progress and evidence links may change without changing either
accepted normative envelope. Empty governance slots may be filled only from an
explicit disposition; a completed governance row is an immutable authority
record. A conflict between the pair blocks acceptance and closure.

Every Concept plan contains a `## Governance Records` table outside its
envelope:

| Decision | Authority | Authority evidence | Bound bytes |
| --- | --- | --- | --- |
| Acceptance | — | — | — |
| Closure | — | — | — |

A complete row uses `Maintainer` or `Delegate: <recorded identity>` for
Authority and `[disposition](<durable-pointer>)` for Authority evidence. Bound
bytes uses exact lowercase digests in this form:

```text
candidate `<40-hex>`; concept `sha256:<64-hex>`; technical `sha256:<64-hex>`; gate `sha256:<64-hex>`
```

The structural check proves the record is complete, anchors each completed row
to its first form across the repository history reachable from `HEAD`, requires
the candidate SHA to remain reachable there, and verifies all three digests
against the historical candidate's Concept envelope, Technical depth envelope,
and gate plus the current canonical bytes. Once Acceptance completes, it anchors
both accepted envelopes and exact gate bytes through every reachable descendant
and merge. Independent review proves pair consistency, candidate compliance,
and that the pointer identifies the named authority's actual disposition. A
separate read-only review compares the exact administrative transition SHA with
the bound candidate and reports to the current integrator that only the
governance row, the single durable authority-disposition record named by that
row, and any lifecycle-derived status blocks changed; no envelope, gate,
portable-enforcement, or product byte may change in that transition. Before a
governance-only Acceptance checkpoint integrates, the review also compares it
with `main` and confirms the
complete integration surface contains planning, governance, documentation, and
portable-enforcement bytes but no milestone product implementation. It is a
mandatory pre-integration procedure, not another durable record or
structural-check claim.

Moving the register to `Accepted` requires a complete acceptance row naming the
accepting maintainer or recorded delegate, durable evidence of that authority's
explicit disposition, the accepted plan-candidate SHA, both envelope digests,
and gate digest. Moving it to `Closed` requires the same three digests plus the
reviewed candidate SHA. An explicit decision may be recorded; it may not be
supplied or inferred. These administrative transitions change only that bounded
governance and derived status surface; they do not alter the bound candidate,
normative envelopes, locked gate, portable enforcement, or product bytes.

The exact skeletons are below. Neither file has an H1 because the filename and
register own identity. Replace `<name>` with the registered milestone name.

Concept plan, `docs/plans/<name>.md`:

```markdown
<a id="concept"></a>
## Concept

Technical depth: [Milestone mechanics](<name>-technical.md#technical-depth).

<!-- loopex:plan-concept-envelope:start -->
## Normative Concept Envelope

<a id="concept-plan-purpose"></a>
### Purpose

<one bounded purpose>

<a id="concept-plan-outcomes"></a>
### Outcomes

| # | Outcome | Evidence class | Gate selector |
| --- | --- | --- | --- |
| 1 | <observable outcome> | <required evidence> | <exact selector> |

Technical depth: [Evidence obligations and mapping](<name>-technical.md#technical-plan-evidence).

<a id="concept-plan-scope"></a>
### Scope

<included work and observable constraints, including compatibility or rollout expectations>

Technical depth: [Prerequisites and acceptance points](<name>-technical.md#technical-plan-prerequisites).

Technical depth: [Ownership and rejoin barriers](<name>-technical.md#technical-plan-ownership).

Technical depth: [Packaging mechanics](<name>-technical.md#technical-plan-packaging).

Technical depth: [Proportional minimalism budget](<name>-technical.md#technical-plan-minimalism).

Technical depth: [Compatibility mechanics](<name>-technical.md#technical-plan-compatibility).

Technical depth: [Migration and rollback](<name>-technical.md#technical-plan-migration).

<a id="concept-plan-non-goals"></a>
### Non-Goals

<explicit exclusions and any explicitly accepted deferrals>

Technical depth: [Deferral acceptance points](<name>-technical.md#technical-plan-prerequisites).
<!-- loopex:plan-concept-envelope:end -->

## Workstreams

<mutable decomposition that respects both envelopes>

## Progress and Evidence

| # | State | Evidence |
| --- | --- | --- |
| 1 | Open | — |

## Governance Records

| Decision | Authority | Authority evidence | Bound bytes |
| --- | --- | --- | --- |
| Acceptance | — | — | — |
| Closure | — | — | — |
```

Technical depth plan, `docs/plans/<name>-technical.md`:

```markdown
<a id="technical-depth"></a>
## Technical depth

Concept: [Milestone purpose and outcomes](<name>.md#concept).

<!-- loopex:plan-technical-envelope:start -->
## Normative Technical Envelope

<a id="technical-plan-prerequisites"></a>
### Prerequisites and Acceptance Points

Concept: [Milestone scope](<name>.md#concept-plan-scope).

Concept: [Milestone non-goals](<name>.md#concept-plan-non-goals).

<accepted decisions and unresolved decisions with their stop points>

<a id="technical-plan-ownership"></a>
### Ownership, Decision Owners, and Rejoin Barriers

Concept: [Milestone scope](<name>.md#concept-plan-scope).

<ownership, decision authority, and rejoin conditions>

<a id="technical-plan-evidence"></a>
### Evidence Obligations and Mapping

Concept: [Milestone outcomes](<name>.md#concept-plan-outcomes).

<cross-cutting evidence obligations and exact outcome mapping>

<a id="technical-plan-compatibility"></a>
### Compatibility

Concept: [Milestone scope](<name>.md#concept-plan-scope).

<compatibility effect or none>

<a id="technical-plan-migration"></a>
### Migration and Rollback

Concept: [Milestone scope](<name>.md#concept-plan-scope).

<migration and rollback obligations>

<a id="technical-plan-packaging"></a>
### Packaging

Concept: [Milestone scope](<name>.md#concept-plan-scope).

<packaging effect or none>

<a id="technical-plan-minimalism"></a>
### Proportional Minimalism Budget

Concept: [Milestone scope](<name>.md#concept-plan-scope).

<justified abstractions and scope-specific ceilings or negative constraints>
<!-- loopex:plan-technical-envelope:end -->
```

Both marked normative envelopes are bound to the accepted candidate SHA.
Change either meaning only through an accepted amendment. Workstreams,
progress, resolved outcome state, and evidence links stay outside them and may
be updated only when they conform to both envelopes and the locked gate.
Structural validation checks presence and byte identity; independent review
decides whether the pair is clear, consistent, and adequate. A plan amendment is
declared by the next consecutively numbered visible Amendment section in
physical document order. Its candidate may change the accepted gate and either
envelope while retaining the prior Acceptance row and lifecycle state; this
intentionally fails current binding
until an independent exact-SHA review and explicit maintainer acceptance. A
separate administrative transition then rebinds Acceptance to that candidate
and its new digests.

That amendment is one generic two-revision, direct one-parent transaction. `A`
is the first revision to advance the generation. The strict transaction is
versioned by one visible `<a id="amendment-transaction-v1"></a>` gate marker:
closed pre-v1 amendment history remains valid, and every active or future
amended gate must carry the marker and obey v1 from its first marked proposal.
At proposal `A`, exact binding
validation, bootstrap, and any inherited gate that invokes them fail only
because the retained Acceptance row still names the prior bytes. Run every
binding-independent check and run the amended milestone gate directly at `A`,
where it must report the truthful product state the amendment declares. After
an exact-SHA review and explicit acceptance of `A`, its immediate-child
administrative transition `R` rebinds Acceptance to exact `A`, preserves the
lifecycle state, adds one new amendment-specific authority-disposition anchor to
an existing durable document where that anchor was absent at `A`, and updates
only conforming derived status blocks.
It may not reuse, complete, or edit an earlier disposition. No commit may
intervene, overlap `R` with another proposal, or begin a later amendment before
`R` settles this one. At `R`, binding validation, bootstrap, and all inherited
required gates must pass, and the amended milestone gate must reproduce the same
product state as at `A`. The exact `A` to `R` review proves that no envelope, gate, portable
enforcement, or product byte changed. Evidence always names the SHA where it
ran; green results from `R` are neither claims about `A` nor substitutes for
later same-source product-candidate evidence. Only `R` may integrate.

Reachable history admits only a strictly later amendment
generation whose candidate lineage contains the exact prior accepted chain;
same-generation edits, higher-numbered sibling forks, interposed or overlapping
transactions, lifecycle changes during A-to-R, rollback, divergent merges, and
any Closure rewrite fail closed.

Evidence links live in the Concept plan's Progress and Evidence table or in
gate-defined artifacts; the locked Outcomes rows name their evidence class and
selector. Do not add an evidence sidecar beside plans: every flat
`docs/plans/*.md` file is interpreted as a Concept plan, Technical depth plan,
gate, or this index. Architecture decisions
live flat and numbered in [docs/adr/](../adr/); the living implementation design
belongs in the paired `docs/architecture.md` and
`docs/architecture-technical.md` when they exist.

Every active and future gate includes this exact ordered documentation table.
The disposition cell names one or more exact canonical repository-relative
POSIX Markdown paths separated by comma and space; absolute, dotted, traversing,
empty-component, backslash, control-byte, case-colliding, and
file/ancestor-conflicting spellings are invalid. The table is one visibly
governed contiguous structure; fenced, commented, fragmented, or malformed-list
content does not count. The first four rows may use `N/A — <reason>` only when
the accepted gate makes that absence an explicit maintainer-approved limitation.
The final three rows never use `N/A`. Closed M0 predates this rule and is the
sole migration exception.

```markdown
## Documentation Obligations

| Category | Required closure disposition |
| --- | --- |
| Operator-facing documentation | <exact `docs/operator/` paths, excluding its README, or explicit N/A> |
| Operator README | `docs/operator/README.md` or explicit N/A |
| Developer-facing documentation | <exact `docs/developer/` paths, excluding its README, or explicit N/A> |
| Developer README | `docs/developer/README.md` or explicit N/A |
| Documentation README | `docs/README.md` |
| Root README | `README.md` |
| Changelog | `CHANGELOG.md` |
```

## How a Milestone Runs

A gate is the executable definition of done, written before implementation and
proved to fail for the declared missing behavior.

1. **Open** — write the Concept plan, Technical depth plan, and red gate together
   on a branch. The unaccepted red tree does not merge to `main`. Normally every
   inherited gate is green. Once the current delivery milestone's accepted
   governance checkpoint is integrated, one generic successor may instead Open
   as a planning-only lookahead: Closed gates stay green, the current gate's
   exact accepted red and the successor's distinct red are proved separately,
   the predecessor remains `Accepted` in that branch, and no second lookahead is
   allowed.
2. **Accepted** — the recorded acceptance authority accepts both normative
   envelopes and the gate's canonical UTF-8/LF text; the Concept plan's
   acceptance record binds authority evidence, candidate SHA, both envelope
   digests, and gate digest before the register moves to `Accepted`. After an
   exact transition review and explicit protected-branch approval, this
   governance checkpoint may integrate to `main` with no milestone product
   implementation bytes, even though its exact accepted opening gate is red.
3. **In progress** — implementation turns the locked gate green.
4. **In review** — an independent reviewer examines the exact candidate SHA;
   unresolved blocking findings block closure.
5. **Closed** — every outcome is resolved, the locked gate is green, review is
   clear, required demonstrations are complete, and the recorded closing
   authority closes it; the closure record binds that disposition, reviewed
   candidate SHA, both envelope digests, and gate digest before the register
   moves to `Closed`. Product bytes integrate only through this separately
   approved closure transition.

The one Open successor cannot be accepted, integrated, or implemented before
the current delivery milestone is Closed and integrated. It then absorbs that
exact product base, re-proves all inherited gates green and its own distinct red,
and receives a fresh exact-SHA review before acceptance. The current milestone
remains the sole product implementation authority throughout the overlap.

A retry is diagnostic, not a pass. A failure that disappears is a blocking
flake until fixed or explicitly dispositioned.

## What a Plan Contains

A candidate may expose unresolved ADR prerequisites so the maintainer can
review the whole decision boundary. Every implementation-blocking prerequisite
must be accepted before the plan pair and gate are accepted or implementation
begins. The skeletons above are complete; do not add a third normative plan
surface. Progress and Evidence has exactly one uniquely numbered row for every
normative Outcome and no other rows. Its states are `Open`, `Proved`, `Accepted
limitation`, or `Accepted deferral`; the latter two require disposition evidence.
Every row remains `Open` while the register state is Open, so a planning
lookahead cannot claim product progress. Nothing closes while any row remains
`Open`, either companion is missing, or the pair conflicts.

## Directing the Work

The full authority rules live in [AGENTS.md](../../AGENTS.md) § Task and
Autonomy Contract. This section is the practical view: what to ask for, and
where each request stops.

Ask for the outcome in ordinary words. These verbs belong to the repository, not
to any tool. A development client may offer a shortcut for one — a named skill,
a menu entry, a slash command — and those shortcuts are adapter conveniences
recorded in
[the adapter smoke evidence](../developer/agent-adapter-smoke.md). A shortcut
never changes what a request authorizes, and a client that has no shortcut
changes nothing about how the work is directed.

| Ask for | What happens | Where it stops |
| --- | --- | --- |
| An explanation, diagnosis, or review | Findings and a recommendation | Before any edit |
| A proposal for an unsettled decision | Options, evidence, and a recommendation | Before dependent work begins |
| Dispositioning a named ADR or plan | Your explicit decision is recorded against the exact candidate bytes | A disposition is recorded, never inferred |
| Opening a named milestone | Concept plan, Technical depth plan, and red gate written together on a branch | Acceptance by the recorded authority |
| Completing an accepted milestone | Implementation inside the accepted envelopes until the locked gate is green | Independent review |
| Closing a reviewed milestone | A closure candidate is assembled from evidence, review, and demonstrations | Closure by the recorded authority |
| Integrating accepted governance | Merge the reviewed governance checkpoint without milestone product bytes; retain the delivery branch | Your explicit protected-branch approval |
| Integrating closed product work | Merge, push, and branch cleanup | Your explicit protected-branch approval |

Opening and closing a milestone are the two rows the maintainer invokes
directly, because no actor may open or close its own gate. Both clients require
that invocation to be explicit; the current per-client keystrokes are recorded
in the
[context map](../developer/agent-context-map.md). Every other row is ordinary
language.

Some things stop regardless of how a request is phrased: self-acceptance, gate
weakening, evidence waiver, scope deferral, a protected-branch merge, release
publication, and any unrecorded ADR-class decision. So does a new decision about
ownership, transactions, trust, public contracts, persistent schema, a major
dependency, the runtime floor, migration, or packaging — asking to complete a
milestone does not pre-authorize choosing a database.

Two habits save a round trip. Asking why something is broken authorizes
diagnosis only, so ask for the fix when you want the fix. Naming a workstream or
file bounds the work to it, which is usually faster than correcting scope
afterward.

The Current Status capsule at the top of this file names the exact next
decision; it is not repeated here, because a second copy would drift.

**After a milestone opens.** The last four rows become live and the lifecycle
repeats: open, accept, complete, review, close. After its governance checkpoint
is integrated, one anticipated successor may be opened for planning without
widening product authority.

**After M0 closes.** None of this changes. The verbs, their authority, and their
stopping points are independent of the toolchain underneath. M0 replaces the
temporary Python and `jq` bridges with the accepted Elixir/Mix entrypoints, and
the commands those verbs run are recorded in
[DEVELOPMENT.md](../../DEVELOPMENT.md), which is where that migration lands.
