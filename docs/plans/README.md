# Plans

Part of the [documentation index](../README.md).

An accepted Concept plan and Technical depth plan form one commitment.
Future capability rungs in
[docs/roadmap.md](../roadmap.md#concept) are candidates, not commitments.

This file is the canonical current-status register and plan index for the
checked-out revision. The root README carries only the derived summary below.
A milestone's work lands on `main` in small reviewed changes as the
[milestone guide](../developer/milestones.md#concept-milestones-develop)
describes, so the register states one product fact the checked-out bytes carry:
its last `Closed` row identifies the last closed product baseline.

<!-- loopex:current-status:start -->
## Current Status

**Revision status:** Closed milestone product baseline; active milestone `M5` is open; no next candidate is recorded.

| Field | Value |
| --- | --- |
| Integrated phase | Closed milestone product baseline |
| Last closed product checkpoint | `M4` — 2026-09-19 |
| Blockers | `M5` is open and not accepted; the maintainer must accept its plan pair; `M5` waits on ADR 0031, ADR 0032, and ADR 0033 before the outcomes that depend on them |
| Authorized work | Explicitly authorized planning, ADR, bootstrap, and review work only; no product implementation |
| Next maintainer decision | Accept or reject the `M5` plan pair; disposition [ADR 0031](../adr/0031-daemon-grade-store-selection-and-migration.md#concept), [ADR 0032](../adr/0032-daemon-attachment-residency-and-replay.md#concept), and [ADR 0033](../adr/0033-collaboration-controller-lease-and-takeover.md#concept) |
| Next transition | Record the acceptance governance row and move `M5` to Accepted |
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
The integrator verifies the exact base, and the pre-integration review verifies
integration eligibility. This field states only the product fact the register
can derive.

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
successor, which is a planning candidate and not a second implementation
authority. Without a delivery row, one `Open` candidate may follow the
Closed history. The founding `Blocked` form is a single next candidate with no
plan files. No second delivery authority or second planning lookahead is
representable.

<!-- loopex:milestone-register:start -->
## Milestone Register

| Milestone | State | Concept | Technical depth | Gate |
| --- | --- | --- | --- | --- |
| `M0` | Closed | [concept](M0.md) | [technical depth](M0-technical.md) | [gate](M0-gate.md) |
| `M1` | Closed | [concept](M1.md) | [technical depth](M1-technical.md) | [gate](M1-gate.md) |
| `M2` | Closed | [concept](M2.md) | [technical depth](M2-technical.md) | [gate](M2-gate.md) |
| `M3` | Closed | [concept](M3.md) | [technical depth](M3-technical.md) | [gate](M3-gate.md) |
| `M4` | Closed | [concept](M4.md) | [technical depth](M4-technical.md) | [gate](M4-gate.md) |
| `M5` | Open | [concept](M5.md) | [technical depth](M5-technical.md) | — |
<!-- loopex:milestone-register:end -->

When a plan exists, the Concept and Technical depth columns link their exact
files and the register is its only lifecycle-state record. Valid states are
`Blocked`, `Open`, `Accepted`, `In progress`, `In review`, and `Closed`.
`Blocked` has no plan files; every other state has both. The Gate column is
history: a milestone run under the retired gate machinery keeps its gate file
and links it, and a milestone without one carries an em dash. Every state
transition atomically updates the register, the complete marked Current Status
capsule above, and README's marked derived summary.

## Vocabulary

- A **capability rung** is one of the non-normative questions in the
  [vision's delivery strategy](../vision.md#concept-vision-delivery-strategy). It
  guides decomposition but does not dictate milestone or release boundaries.
- A **milestone** is bounded work described by one accepted plan pair and ended
  by one closure. It may prove part or all of one or more capability rungs while
  respecting the vision's
  [delivery strategy](../vision.md#concept-vision-delivery-strategy),
  [serial barriers](../vision-technical.md#technical-vision-serial-barriers),
  and, for compatibility claims,
  [freeze rules](../vision-technical.md#technical-vision-compatibility).
- A **workstream** is a parallel slice inside a milestone. It has no independent
  plan.
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
```

The Concept plan owns purpose, observable outcomes, scope, non-goals, and
visible constraints, including observable compatibility and rollout
expectations. The Technical depth plan owns prerequisites, invariants,
ownership and rejoin mechanics, evidence mapping, implementation constraints,
failure cases, migration, rollback, packaging, and exact minimalism constraints.
The companion may prove or refine the Concept plan but cannot add scope or a
decision.

A milestone run under the retired gate machinery also carries
`docs/plans/<name>-gate.md`. Those files are historical records of what was
locked and proved at the revisions they name; a new milestone has none. The
filename and canonical register own plan identity and lifecycle state; neither
plan repeats them. Progress and evidence links change as the work proceeds.
Empty governance slots may be filled only from an explicit disposition; a
completed governance row is a record of a decision that was made. A conflict
between the pair blocks acceptance and closure.

Every Concept plan contains a `## Governance Records` table outside its
envelope:

| Decision | Authority | Authority evidence | Bound bytes |
| --- | --- | --- | --- |
| Acceptance | — | — | — |
| Closure | — | — | — |

A complete row uses `Maintainer` or `Delegate: <recorded identity>` for
Authority, `[disposition](<durable-pointer>)` for Authority evidence, and the
accepted or reviewed candidate SHA for Bound bytes. Closed milestones bind
envelope and gate digests there as well, because that is what their acceptance
and closure covered; those rows are read as written and are not rewritten.

Moving the register to `Accepted` requires a complete acceptance row naming the
maintainer or a recorded delegate, durable evidence of that authority's explicit
disposition, and the accepted candidate SHA. Moving it to `Closed` requires the
same for the reviewed closure candidate. An explicit decision may be recorded;
it may not be supplied or inferred. An independent reviewer reads the exact
candidate before either transition, and the transition itself changes only the
governance row, the disposition it names, and the derived status blocks.

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

| # | Outcome | Evidence class | Verification |
| --- | --- | --- | --- |
| 1 | <observable outcome> | <required evidence> | <exact test or command> |

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

Both marked normative envelopes record what the maintainer accepted: purpose,
outcomes, scope, and the constraints the work runs under. Workstreams, progress,
resolved outcome state, and evidence links stay outside them and are updated as
the work proceeds. Changing an accepted purpose, outcome, or scope is a new
maintainer decision, recorded in the plan where the change lands; independent
review decides whether the pair is clear, consistent, and adequate.

Evidence links live in the Concept plan's Progress and Evidence table, and the
Outcomes rows name how each outcome is verified. Do not add an evidence sidecar
beside plans: every flat `docs/plans/*.md` file is interpreted as a Concept
plan, a Technical depth plan, a historical gate, or this index. Architecture
decisions live flat and numbered in [docs/adr/](../adr/); the living
implementation design belongs in the paired `docs/developer/architecture.md`
and `docs/developer/architecture-technical.md`.

A closure candidate also updates the documentation its milestone changed:
`CHANGELOG.md`, the root `README.md`, this register, the affected `docs/`
indexes, and any operator or developer guidance the work made wrong.
Documentation drift blocks closure like any other unmet outcome.

## How a Milestone Runs

The four steps are named in [AGENTS.md](../../AGENTS.md#milestones-and-checks)
and carried out by the [milestone guide](../developer/milestones.md#concept)
and its
[technical companion](../developer/milestones-technical.md#technical-depth);
which checks a change must pass is the
[verification guide](../developer/verification.md#concept). That procedure is
written once, there. This register owns the lifecycle alone, and each
transition records exactly this:

| Transition | What the transition records |
| --- | --- |
| → `Open` | The plan pair exists, is indexed below, and every Progress and Evidence row reads `Open` |
| `Open` → `Accepted` | The maintainer's disposition in the plan's Acceptance row: authority, durable authority evidence, and the accepted candidate |
| `Accepted` → `In progress` | Implementation has begun against the accepted pair; evidence rows change as outcomes are proved |
| `In progress` → `In review` | A closure candidate exists and an independent reviewer is reading that exact candidate |
| `In review` → `Closed` | The maintainer's closure disposition in the plan's Closure row, naming the reviewed candidate, with every Progress row resolved |

Every transition updates the register row, the complete Current Status capsule
above, and README's derived summary in one change. `mix loopex.status` derives
the capsule and the summary from the register and prints the exact values it
expects, for any milestone name; nothing about a new name is written in code.

A retry is diagnostic, not a pass. A same-revision failure that disappears on
retry is a flake to fix, not a pass.

## What a Plan Contains

A plan may expose unresolved ADR prerequisites so the maintainer can review the
whole decision boundary. Each one is accepted before the implementation that
depends on it, not before unrelated work; by closure none is outstanding. The
plan companion's `Prerequisites and Acceptance Points` section is where they are
declared, and the status check reads the ADRs that section links, so the
declaration and the derived status cannot disagree. The
skeletons above are complete: do not add a third normative plan surface, and do
not add a gate file. Progress and Evidence has exactly one uniquely numbered row
for every normative Outcome and no other rows. Its states are `Open`, `Proved`,
`Accepted limitation`, or `Accepted deferral`; the latter two require
disposition evidence. Every row remains `Open` while the register state is Open,
so a planning candidate cannot claim product progress. Nothing closes while any
row remains `Open`, either companion is missing, or the pair conflicts.

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
| Opening a named milestone | Concept plan and Technical depth plan written together and registered as `Open` | Acceptance by the maintainer |
| Completing an accepted milestone | Implementation inside the accepted plan pair until every outcome is proved and the checks are green | Independent review |
| Closing a reviewed milestone | A closure candidate is assembled from evidence, review, and demonstrations | Closure by the maintainer |
| Integrating a reviewed change | Merge, push, and branch cleanup | Your explicit protected-branch approval |

Opening and closing a milestone are the two rows the maintainer invokes
directly, because no actor may accept or close its own work. Both clients
require that invocation to be explicit; the current per-client keystrokes are
recorded in the
[context map](../developer/agent-context-map.md). Every other row is ordinary
language.

Some things stop regardless of how a request is phrased: self-acceptance,
dropping a required check, evidence waiver, scope deferral, a protected-branch
merge, release publication, and any unrecorded ADR-class decision. So does a new
decision about ownership, transactions, trust, public contracts, persistent
schema, a major
dependency, the runtime floor, migration, or packaging — asking to complete a
milestone does not pre-authorize choosing a database.

Two habits save a round trip. Asking why something is broken authorizes
diagnosis only, so ask for the fix when you want the fix. Naming a workstream or
file bounds the work to it, which is usually faster than correcting scope
afterward.

The Current Status capsule at the top of this file names the exact next
decision; it is not repeated here, because a second copy would drift.

**After a milestone opens.** The last three rows become live and the lifecycle
repeats: agree, develop, review, close. One anticipated successor may be opened
for planning alongside it without widening product authority.

**M0's closure changed none of this.** The verbs, their authority, and their
stopping points are independent of the toolchain underneath. M0 replaced the
temporary Python and `jq` bridges with the accepted Elixir/Mix entrypoints, and
the commands those verbs run are recorded in
[DEVELOPMENT.md](../../DEVELOPMENT.md).
