# Plans

This is where you find out what Loopex is actually committed to building, and
how you can tell when it's done.

**Right now: no milestone is open.** The seed bootstrap closed on 2026-08-15.
M0 is next, and is blocked on its two prerequisite decisions. This directory
being otherwise empty is the honest record of that, not an oversight.

| Milestone | Stage it serves | Ships | State |
| --- | --- | --- | --- |
| `M0` | Contract experiments | No | Blocked — prerequisites below |
| `v0.1` | Useful local kernel | Yes | Not started |
| `v0.2` | Durable service | Yes | Not started |
| `v0.3` | Governed extension runtime | Yes | Not started |
| `v0.4` | Isolated hands | Yes | Not started |
| `v0.5` | Remote ecosystem | Yes | Not started |
| `v1.0` | Compatibility baseline | Yes | Not started |

The ladder itself — what each stage proves and which orderings can never be
changed — is in [docs/roadmap.md](../roadmap.md).

**M0's prerequisites.** Architecture decisions belong to the milestone whose
work they unblock. M0 cannot open until both of these are accepted or rejected,
because its gate has to name a repository tree and a toolchain:

- [ADR 0001](../adr/0001-repository-and-application-layout.md) — repository and
  application layout · *proposed*
- [ADR 0002](../adr/0002-bootstrap-runtime-floor.md) — bootstrap runtime floor
  and version matrix · *proposed*

## Four words

These are used precisely throughout the repository.

- A **stage** is a capability rung. It answers one question about whether the
  architecture works. There are exactly seven and the list never grows.
- A **milestone** is one stage's bounded work: one plan, one gate, one closure.
  It is the unit that gets opened, accepted, and closed.
- A **workstream** is a parallel slice inside a milestone. It has no plan or
  gate of its own.
- A **release** is a tag, published when a milestone completes and its release
  criteria pass.

**A milestone's name tells you whether it ships.** `M0` is the only M-named
milestone, because it is the only one that produces no release — its code is
disposable contract experiments. Every milestone after it is named for the
release it produces. So the milestone after `M0` is `v0.1`, not `M1`; there is
no `M1` and there never will be.

When a milestone is large — `v0.1` genuinely is — it splits into workstreams
inside its own plan, not into sub-milestones with separate gates. More gates
would add ceremony without adding control.

## Files

```text
docs/plans/<name>.md         the plan: purpose, scope, outcomes table, state
docs/plans/<name>-gate.md    the locked acceptance contract
```

The gate is a separate file for one reason: at acceptance its bytes are
digested, and the digest is what proves the acceptance contract wasn't altered
later. Plans change constantly as work progresses. If the two shared a file,
ticking an outcome would change the gate's digest and the signal would stop
meaning anything.

There is no separate evidence file. Evidence goes in the plan's outcomes table
as links, and only earns its own file if it genuinely outgrows that.

Architecture decisions are not milestone-scoped and live flat and numbered in
[docs/adr/](../adr/).

## How a milestone runs

A gate is the executable definition of done, written **before** the work and
proven to fail first. A gate written afterward always passes, which makes it
useless as evidence.

1. **Open** — the plan and its gate are written together on a branch. Existing
   checks stay green; the new gate fails for the behavior that is missing. The
   red tree never reaches `main`.
2. **Accepted** — the maintainer accepts the exact bytes. The gate's digest is
   locked: exact commands, protected tests, fixtures, evidence classes.
3. **In progress** — implementation turns the red gate green.
4. **In review** — an independent reviewer examines the exact candidate commit.
   A blocking finding blocks closure no matter how green the gate is.
5. **Closed** — the maintainer closes it.

A green gate alone is not done. All four must hold: every outcome resolved to
evidence, a demonstration, or an approved deferral; the locked gate green at the
candidate commit; independent review with no unresolved blocking findings; and
the maintainer's closure. A failure that disappears on retry is a flake, not a
pass, until it is explicitly dispositioned.

## What a plan contains

Purpose and outcomes, scope and non-goals, ADR prerequisites, workstreams and
their rejoin barriers, evidence mapping, compatibility, migration, rollback,
packaging, and decision owners.

The outcomes table is what answers "is it done":

| # | Outcome | Evidence class | Gate selector | State |
| --- | --- | --- | --- | --- |
| 1 | `commit_unknown` resolves across a coordinator crash | fault injection | `test/fencing_test.exs` | open |

Nothing closes with an open row.

## Directing the work

The phrasing of a request selects how much authority it carries. The full rules
are in [AGENTS.md](../../AGENTS.md) § Task and Autonomy Contract; in practice:

| Ask | What happens |
| --- | --- |
| "open M0" | Plan and red gate written on a branch, then a stop for acceptance |
| "go complete M0" | Implementation until the gate is green, then a stop for review |
| "why is the fencing test failing?" | Diagnosis and a recommendation, and nothing is changed |
| "close M0" | A closure candidate is assembled; the maintainer closes it |

Asking why something is broken is not permission to fix it. Conversely, "go
complete M0" authorizes implementation inside the accepted plan but never
authorizes accepting a plan, weakening a gate, merging to `main`, or closing a
milestone — however the request is phrased.

Some decisions stop the work regardless of instruction: ownership,
transactions, trust boundaries, public contracts, persistent schema, a major
dependency, the runtime floor, migration, or packaging. "Go complete M0" does
not pre-authorize choosing a database.
