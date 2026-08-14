---
name: gate
description: Open a milestone gate-first — scaffold the plan candidate and the red acceptance gate.
disable-model-invocation: true
---

Open milestone $1 gate-first (AGENTS.md § Milestones and Gates):

1. Create `docs/plans/$1-plan.md` as a compact plan candidate naming what
   AGENTS.md requires of an accepted plan: purpose and outcomes; scope and
   non-goals; ADR prerequisites; workstreams and rejoin barriers; evidence
   mapping, including the gate test path and `mix loopex.gate $1`;
   compatibility, migration, rollback, and packaging; decision owners; and
   expected stop-and-ask items.
2. Create `test/gates/$1_gate_test.exs` tagged `:gate_$1`, expressing the
   milestone's acceptance from the vision as failing tests: named invariant
   checks (vision §23.3), conformance-suite invocations, and golden-vector
   assertions. Do not stub them green.
3. Wire `mix loopex.gate $1` to run exactly that tag plus affected
   conformance suites.
4. Commit red with `gates: open $1`. Then stop — the maintainer reviews the
   gate before implementation begins (that review is the leverage point).
