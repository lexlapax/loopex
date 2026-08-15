---
name: gate
description: "Open a Loopex milestone gate-first. Use only when the maintainer explicitly asks to create or revise a milestone plan candidate and its branch-only red executable acceptance gate before implementation."
disable-model-invocation: true
---

# Open a Milestone Gate

Follow `AGENTS.md` first; route additional context, including current milestone
guidance, via `docs/developer/agent-context-map.md`.

For the named milestone:

1. Verify the seed base is a committed maintainer-designated SHA and run every
   existing required check. Treat a missing check as unavailable evidence.
2. Create a compact plan candidate at `docs/plans/<name>.md` containing the
   purpose and outcomes, scope and non-goals, ADR prerequisites, workstreams and
   rejoin barriers, evidence mapping, compatibility, migration, rollback,
   packaging, and decision owners required by `AGENTS.md`. Give it an outcomes
   table; nothing closes with an open row. Add the milestone to the table in
   `docs/plans/README.md`, and link its rung in the `docs/roadmap.md` ladder to
   the new plan file.
3. Create the branch-only executable acceptance gate at
   `docs/plans/<name>-gate.md`, separate from the plan so its digested bytes do
   not churn as plan progress is recorded. Name exact commands and protected
   tests, selectors, fixtures, vectors, harness/configuration bytes, evidence
   classes, and their digest. Do not stub missing behavior green.
4. Prove existing gates remain green and the new gate fails for the declared
   missing outcome. Unknown or shared scope runs the full gate.
5. Keep the red checkpoint off `main`. Commit it only when the current task
   authorizes that Git write.
6. Stop for independent gate and plan acceptance. Do not begin implementation,
   weaken the gate, waive evidence, merge the red tree, or accept your own work.
