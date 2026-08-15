---
name: gate
description: "Open a Loopex milestone or contract-experiment stage gate-first. Use only when the maintainer explicitly asks to create or revise a stage plan candidate and its branch-only red executable acceptance gate before implementation."
disable-model-invocation: true
---

# Open a Stage Gate

For the named stage:

1. Verify the seed base is a committed maintainer-designated SHA and run every
   existing required check. Treat a missing check as unavailable evidence.
2. Create a compact plan candidate under `docs/plans/` containing the purpose and
   outcomes, scope and non-goals, ADR prerequisites, workstreams and rejoin
   barriers, evidence mapping, compatibility, migration, rollback, packaging,
   and decision owners required by `AGENTS.md`.
3. Create the branch-only executable acceptance gate. Name exact commands and
   protected tests, selectors, fixtures, vectors, harness/configuration bytes,
   evidence classes, and their digest. Do not stub missing behavior green.
4. Prove existing gates remain green and the new gate fails for the declared
   missing outcome. Unknown or shared scope runs the full gate.
5. Keep the red checkpoint off `main`. Commit it only when the current task
   authorizes that Git write.
6. Stop for independent gate and plan acceptance. Do not begin implementation,
   weaken the gate, waive evidence, merge the red tree, or accept your own work.
