# Plans

An accepted plan is a commitment. Future capability rungs in
[docs/roadmap.md](../roadmap.md) are candidates, not commitments.

This file is the canonical current-status register and plan index for the
checked-out revision. The root README carries only the derived summary below.
An accepted in-flight milestone appears on its designated branch until it is
integrated; `main` describes integrated project state, not every remote activity.

<!-- loopex:current-status:start -->
## Current Status

**Revision status:** Pre-implementation planning; no milestone is active; next candidate `M0` is blocked.

| Field | Value |
| --- | --- |
| Integrated phase | Pre-implementation planning |
| Last integrated checkpoint | Seed bootstrap — 2026-08-15 |
| Blockers | [ADR 0001](../adr/0001-repository-and-application-layout.md) and [ADR 0002](../adr/0002-bootstrap-runtime-floor.md) must be accepted before M0 opens; a replacement requires a governed guard change |
| Authorized work | Explicitly authorized planning, ADR, bootstrap, and review work only; no product implementation |
| Next maintainer decision | Disposition ADR 0001 and ADR 0002 |
| Next transition | After the prerequisites are accepted, the maintainer explicitly opens `M0` gate-first |
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
| Both | M0 has not been explicitly opened gate-first | Explicitly open or defer M0 | Create the branch-only M0 plan and red gate, install lifecycle-specific status checks, and move M0 to Open |

Opening `M0` must replace this seed-specific state machine with
lifecycle-specific checks; it may not merely delete or relax the status check.

`M0` cannot open until ADR 0001 and ADR 0002 each carry a structurally complete
acceptance record. A rejection or status-word edit does not unlock it. Choosing
a replacement requires an explicit governed change to the named prerequisite
and this guard; the bootstrap checker does not infer a supersession graph. Its
plan and gate also define the first scope-specific minimalism budget rather than
a universal line-count target. Its closure removes the temporary Python/`jq`
bridge by migrating repository checks and tested client-hook paths to the
accepted Elixir/OTP toolchain and proving the adapter path with `jq` absent.
Each founding ADR's Acceptance row uses the same authority and disposition
syntax as a plan, with Bound bytes in this exact form:

```text
candidate `<40-hex>`; document `sha256:<64-hex>`
```

The candidate must be the reachable historical Proposed ADR. Within that ADR,
acceptance changes only its status and empty governance row; the same
administrative commit updates the derived Current Status capsule.

Only accepted, active, closed, or explicitly named next-candidate milestones
belong in the register. A roadmap projection does not earn a row. The register
is the sole lifecycle-state owner: the final `Closed` row is the last closed
milestone, an active-state row is the active milestone, and the sole `Blocked`
row is the next candidate.

<!-- loopex:milestone-register:start -->
## Milestone Register

| Milestone | State | Plan | Gate |
| --- | --- | --- | --- |
| `M0` | Blocked | — | — |
<!-- loopex:milestone-register:end -->

When a plan exists, the plan and gate columns link their exact files and the
register is its only lifecycle-state record. Valid states are `Blocked`, `Open`,
`Accepted`, `In progress`, `In review`, and `Closed`. `Blocked` has no plan or
gate. Every other state has both. Every state transition atomically updates the
register, the complete marked Current Status capsule above, and README's marked
derived summary.

## Vocabulary

- A **capability rung** is one of the non-normative questions in vision §21. It
  guides decomposition but does not dictate milestone or release boundaries.
- A **milestone** is bounded work governed by one accepted plan, one gate, and
  one closure. It may prove part or all of one or more capability rungs while
  respecting the capability prerequisites and serial barriers in vision
  §21–§22 and, for compatibility claims, the freeze rules in §24.
- A **workstream** is a parallel slice inside a milestone. It has no independent
  plan or gate.
- A **release** is a separately authorized publication. A milestone may or may
  not produce one; only its accepted plan may couple the two.

Milestone names are stable operator-chosen slugs. They are either lowercase
ASCII letters/digits separated by single hyphens, an `M` followed by digits, or
a version-shaped numeric slug such as `1.0` or `v0.1`; names are at most 64
ASCII bytes and unique under case folding. `planning`, `seed`, `readme`, Windows
device basenames (`con`, `prn`, `aux`, `nul`, `com1`–`com9`, and
`lpt1`–`lpt9`), and names ending in `-gate` are reserved in any letter case. A
release-shaped name grants no release authority, and the roadmap does not
prohibit a future `M1`, `v0.1`, `kernel-a`, or another accepted name.

## Files

```text
docs/plans/<name>.md         plan, progress, outcomes, and evidence links
docs/plans/<name>-gate.md    locked executable acceptance contract
```

The gate is separate because its canonical UTF-8/LF text and SHA-256 digest are
locked at acceptance and remain immutable for the milestone. The filename and
canonical register own plan identity and lifecycle state; plans do not repeat
either. Conforming progress and evidence links may change without changing the
accepted normative envelope. Empty governance slots may be filled only from an
explicit disposition; a completed governance row is an immutable authority
record.

Every plan contains a `## Governance Records` table outside that envelope:

| Decision | Authority | Authority evidence | Bound bytes |
| --- | --- | --- | --- |
| Acceptance | — | — | — |
| Closure | — | — | — |

A complete row uses `Maintainer` or `Delegate: <recorded identity>` for
Authority and `[disposition](<durable-pointer>)` for Authority evidence. Bound
bytes uses exact lowercase digests in this form:

```text
candidate `<40-hex>`; gate `sha256:<64-hex>`
```

The structural check proves the record is complete, anchors each completed row
to its first form across the repository history reachable from `HEAD`, requires
the candidate SHA to remain reachable there, and verifies its digest against
both the historical candidate's gate and current canonical gate text. Once
Acceptance completes, it likewise anchors the accepted envelope and exact gate
bytes through every reachable descendant and merge. Independent review proves
candidate compliance and that the pointer identifies the named authority's
actual disposition. A separate read-only review compares the exact
administrative transition SHA with the bound candidate and reports to the
current integrator that only the governance row and two marked status blocks
changed; no gate or product byte may change in that transition. It is a
mandatory pre-integration procedure, not another durable record or
structural-check claim.

Moving the register to `Accepted` requires a complete acceptance row naming the
accepting maintainer or recorded delegate, durable evidence of that authority's
explicit disposition, the accepted plan-candidate SHA, and gate digest. Moving
it to `Closed` likewise requires a complete closure row naming the authority,
disposition evidence, reviewed candidate SHA, and gate digest. An agent may
record an explicit decision; it may not supply or infer one. These
administrative transitions change only governance and derived status bytes;
they do not alter the bound candidate, locked gate, or product bytes.

The exact plan skeleton is below. The file starts with the envelope marker; it
has no H1 because the filename and register own identity, contains no sections
beyond those shown below, and has no unmarked preamble.

```markdown
<!-- loopex:plan-envelope:start -->
## Normative Envelope

### Purpose

<one bounded purpose>

### Outcomes

| # | Outcome | Evidence class | Gate selector |
| --- | --- | --- | --- |
| 1 | <observable outcome> | <required evidence> | <exact selector> |

### Scope

<included work>

### Non-Goals

<explicit exclusions and any explicitly accepted deferrals>

### Prerequisites and Acceptance Points

<accepted decisions and unresolved decisions with their stop points>

### Ownership, Decision Owners, and Rejoin Barriers

<ownership, decision authority, and rejoin conditions>

### Evidence Obligations and Mapping

<cross-cutting evidence obligations, or none beyond the outcome rows>

### Compatibility

<compatibility effect or none>

### Migration and Rollback

<migration and rollback obligations>

### Packaging

<packaging effect or none>

### Proportional Minimalism Budget

<justified abstractions and scope-specific ceilings or negative constraints>
<!-- loopex:plan-envelope:end -->

## Workstreams

<mutable decomposition that respects the envelope>

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

The marked normative envelope is bound to the accepted candidate SHA and
comprises the exact commitments above. Change its meaning only through an
accepted amendment. Workstream decomposition, progress, resolved outcome state,
and evidence links stay outside it and may be updated only when they conform to
the envelope and locked gate. Structural validation checks presence and byte
identity; independent review decides whether its contents are adequate. No plan
amendment record exists yet, so any accepted-envelope byte change fails closed
until that mechanism is explicitly designed and accepted.

Evidence links live in Progress and Evidence or in gate-defined artifacts; the
locked Outcomes rows name their evidence class and selector. Do not add an
evidence sidecar beside plans: every other flat
`docs/plans/*.md` file is interpreted as a plan or gate. Architecture decisions
live flat and numbered in [docs/adr/](../adr/); the living implementation design
belongs in `docs/architecture.md` when one exists.

## How a Milestone Runs

A gate is the executable definition of done, written before implementation and
proved to fail for the declared missing behavior.

1. **Open** — write the plan and red gate together on a branch; existing checks
   remain green and the red tree does not merge to `main`.
2. **Accepted** — the recorded acceptance authority accepts the plan's normative
   envelope and the gate's canonical UTF-8/LF text and SHA-256 digest; the
   plan's acceptance record binds the authority evidence, plan-candidate SHA,
   and gate digest before the register moves to `Accepted`.
3. **In progress** — implementation turns the locked gate green.
4. **In review** — an independent reviewer examines the exact candidate SHA;
   unresolved blocking findings block closure.
5. **Closed** — every outcome is resolved, the locked gate is green, review is
   clear, required demonstrations are complete, and the recorded closing
   authority closes it; the closure record binds that disposition, reviewed
   candidate SHA, and gate digest before the register moves to `Closed`.

A retry is diagnostic, not a pass. A failure that disappears is a blocking
flake until fixed or explicitly dispositioned.

## What a Plan Contains

A candidate may expose unresolved ADR prerequisites so the maintainer can
review the whole decision boundary. Every implementation-blocking prerequisite
must be accepted before the plan and gate are accepted or implementation begins.
The skeleton above is complete; do not add a second normative plan surface.
Progress and Evidence has exactly one uniquely numbered row for every normative
Outcome and no other rows. Its states are `Open`, `Proved`, `Accepted
limitation`, or `Accepted deferral`; the latter two require disposition evidence.
Nothing closes while any row remains `Open`.

## Directing the Work

The full authority rules live in [AGENTS.md](../../AGENTS.md) § Task and
Autonomy Contract. In practice:

| Ask | What happens |
| --- | --- |
| "open M0" | Plan and red gate are written on a branch, then work stops for acceptance |
| "go complete M0" | Implementation proceeds inside an accepted plan until ready for review |
| "why is the fencing test failing?" | Diagnosis and recommendation only |
| "close M0" | A closure candidate is assembled; the recorded closing authority decides closure |

No phrasing authorizes an agent to accept its own plan, weaken a gate, merge to
a protected branch, publish a release, or silently decide an ADR-class question.
