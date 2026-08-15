# Plans

Accepted stage plans and their gate contracts. A plan is the commitment; the
vision names questions and [docs/roadmap.md](../roadmap.md) names sequencing,
but only an accepted plan authorizes work.

**Current state: no stage is open.** The seed bootstrap closed 2026-08-15, and
nothing beyond seed scope is authorized until the maintainer explicitly opens
the next stage gate-first ([AGENTS.md](../../AGENTS.md) § Milestones and Gates).
This directory being otherwise empty is the accurate record of that, not an
oversight.

## Layout

One folder per milestone, named for the ladder rung (`M0`, `v0.1`, `1.0`):

```text
docs/plans/<milestone>/plan.md        purpose and outcomes, scope and non-goals,
                                      ADR prerequisites, workstreams and rejoin
                                      barriers, evidence mapping, compatibility,
                                      migration, rollback, packaging, owners
docs/plans/<milestone>/gate.md        locked commands, protected tests, fixtures,
                                      vectors, evidence classes, lock digest
docs/plans/<milestone>/evidence.md    retained runs, independent review,
                                      demonstrations, approved deferrals
```

The folder is the retained evidence bundle at closure. Add other files only
when they are milestone-scoped records.

Design and flow documents are not plan artifacts. They outlive the milestone
that introduced them and are corrected as code changes, so they live in
`docs/architecture/` and plans link to them. Keeping them out of here is what
lets an accepted plan stay an immutable record while the document stays true.

ADRs are not milestone-scoped either; they are flat and numbered in
[docs/adr/](../adr/).

## How a plan gets here

The `gate` skill creates the plan candidate and its branch-only red acceptance
gate together, before implementation. The red checkpoint never reaches `main`,
and an agent never accepts its own plan or gate. Accepted plan purpose, scope,
outcomes, and ownership are immutable records afterward — change their meaning
only through a versioned amendment accepted by the same authority class.
