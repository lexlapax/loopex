# Plans

Part of the [documentation index](../README.md).

An accepted Concept plan, Technical depth plan, and gate form one commitment.
Future capability rungs in
[docs/roadmap.md](../roadmap.md#concept) are candidates, not commitments.

This file is the canonical current-status register and plan index for the
checked-out revision. The root README carries only the derived summary below.
An accepted in-flight milestone appears on its designated branch until it is
integrated; `main` describes integrated project state, not every remote activity.

<!-- loopex:current-status:start -->
## Current Status

**Revision status:** Pre-implementation planning; active milestone `M0` is in review; no next candidate is recorded.

| Field | Value |
| --- | --- |
| Integrated phase | Pre-implementation planning |
| Last integrated checkpoint | Seed bootstrap — 2026-08-15 |
| Blockers | None; `M0` has a green gate on every locked lane and awaits independent review |
| Authorized work | Implementation inside the accepted `M0` envelopes and its locked gate; no other product implementation |
| Next maintainer decision | Close `M0` or reject its closure candidate on the review findings |
| Next transition | Record the closure governance row and move `M0` to Closed |
| Validation | `bash scripts/check-bootstrap.sh` |
<!-- loopex:current-status:end -->

Until the first planned milestone closes, Last integrated checkpoint is the
exact seed-bootstrap sentinel shown above. After that it is derived from the
register's final `Closed` row in this form:

```text
`<final Closed milestone>` — YYYY-MM-DD
```

While `M0` is the sole blocked candidate, the repository status check derives
the complete capsule from the two founding ADR records. The phase, seed
checkpoint, authorized-work boundary, and validation command stay fixed. These
three fields change exactly as disposition advances:

| Accepted records | Blockers | Next maintainer decision | Next transition |
| --- | --- | --- | --- |
| Neither | Both linked ADRs must be accepted before M0 opens; a replacement requires a governed guard change | Disposition ADR 0001 and ADR 0002 | After the prerequisites are accepted, the maintainer explicitly opens `M0` gate-first |
| One | The remaining linked ADR must be accepted before M0 opens; a replacement requires a governed guard change | Disposition the remaining ADR | After the prerequisites are accepted, the maintainer explicitly opens `M0` gate-first |
| Both | M0 has not been explicitly opened gate-first | Explicitly open or defer M0 | Create the branch-only M0 Concept plan, Technical depth plan, and red gate; install lifecycle-specific status checks; and move M0 to Open |

Opening `M0` must replace this seed-specific state machine with
lifecycle-specific checks; it may not merely delete or relax the status check.

`M0` cannot open until ADR 0001 and ADR 0002 each carry a structurally complete
acceptance record. A rejection or status-word edit does not unlock it. Choosing
a replacement requires an explicit governed change to the named prerequisite
and this guard; the bootstrap checker does not infer a supersession graph. Its
plan pair and gate also define the first scope-specific minimalism budget rather than
a universal line-count target. Its closure removes the temporary Python/`jq`
bridge by migrating repository checks and tested client-hook paths to the
accepted Elixir/OTP toolchain and proving the adapter path with `jq` absent.

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

Only accepted, active, closed, or explicitly named next-candidate milestones
belong in the register. A roadmap projection does not earn a row. The register
is the sole lifecycle-state owner: the final `Closed` row is the last closed
milestone, an active-state row is the active milestone, and the sole `Blocked`
row is the next candidate.

<!-- loopex:milestone-register:start -->
## Milestone Register

| Milestone | State | Concept | Technical depth | Gate |
| --- | --- | --- | --- | --- |
| `M0` | In review | [concept](M0.md) | [technical depth](M0-technical.md) | [gate](M0-gate.md) |
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
separate read-only review compares the exact
administrative transition SHA with the bound candidate and reports to the
current integrator that only the governance row and the three required marked
status blocks changed; no gate or product byte may change in that transition. It is a
mandatory pre-integration procedure, not another durable record or
structural-check claim.

Moving the register to `Accepted` requires a complete acceptance row naming the
accepting maintainer or recorded delegate, durable evidence of that authority's
explicit disposition, the accepted plan-candidate SHA, both envelope digests,
and gate digest. Moving it to `Closed` requires the same three digests plus the
reviewed candidate SHA. An explicit decision may be recorded; it may not be
supplied or inferred. These
administrative transitions change only governance and derived status bytes;
they do not alter the bound candidate, locked gate, or product bytes.

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
decides whether the pair is clear, consistent, and adequate. No plan-amendment
record exists yet, so any accepted-envelope byte change fails closed until that
mechanism is explicitly designed and accepted.

Evidence links live in the Concept plan's Progress and Evidence table or in
gate-defined artifacts; the locked Outcomes rows name their evidence class and
selector. Do not add an evidence sidecar beside plans: every flat
`docs/plans/*.md` file is interpreted as a Concept plan, Technical depth plan,
gate, or this index. Architecture decisions
live flat and numbered in [docs/adr/](../adr/); the living implementation design
belongs in the paired `docs/architecture.md` and
`docs/architecture-technical.md` when they exist.

## How a Milestone Runs

A gate is the executable definition of done, written before implementation and
proved to fail for the declared missing behavior.

1. **Open** — write the Concept plan, Technical depth plan, and red gate together
   on a branch; existing checks remain green and the red tree does not merge to
   `main`.
2. **Accepted** — the recorded acceptance authority accepts both normative
   envelopes and the gate's canonical UTF-8/LF text; the Concept plan's
   acceptance record binds authority evidence, candidate SHA, both envelope
   digests, and gate digest before the register moves to `Accepted`.
3. **In progress** — implementation turns the locked gate green.
4. **In review** — an independent reviewer examines the exact candidate SHA;
   unresolved blocking findings block closure.
5. **Closed** — every outcome is resolved, the locked gate is green, review is
   clear, required demonstrations are complete, and the recorded closing
   authority closes it; the closure record binds that disposition, reviewed
   candidate SHA, both envelope digests, and gate digest before the register
   moves to `Closed`.

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
Nothing closes while any row remains `Open`, either companion is missing, or
the pair conflicts.

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
| Integrating approved work | Merge, push, and branch cleanup | Your explicit approval each time |

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

**Today.** No milestone is accepted, so only the first three rows do anything.
The Current Status capsule at the top of this file names the exact next
decision; it is not repeated here, because a second copy would drift.

**After a milestone opens.** The last four rows become live and the lifecycle
repeats: open, accept, complete, review, close.

**After M0 closes.** None of this changes. The verbs, their authority, and their
stopping points are independent of the toolchain underneath. M0 replaces the
temporary Python and `jq` bridges with the accepted Elixir/Mix entrypoints, and
the commands those verbs run are recorded in
[DEVELOPMENT.md](../../DEVELOPMENT.md), which is where that migration lands.
