---
name: gate
description: "Open a Loopex milestone gate-first. Use only when the maintainer or a recorded delegate explicitly asks to create or revise a milestone plan candidate and its branch-only red executable acceptance gate before implementation."
disable-model-invocation: true
---

# Open a Milestone Gate

Follow `AGENTS.md` first; read `docs/plans/README.md` for canonical status, then
use `docs/developer/agent-context-map.md` for routing and version-specific
technical guidance.

For the named milestone:

1. Verify the designated green base is a committed maintainer-designated SHA
   and run every existing required check. Treat a missing check as unavailable
   evidence.
2. For `M0`, first require structurally Accepted records in ADR 0001 and ADR
   0002. Do not create or open it for any other status. Its opening branch also
   replaces the exact seed-status guard with lifecycle-specific checks; do not
   remove or weaken the guard.
3. Map the milestone's bounded outcomes to the capability rung or rungs they
   serve; roadmap labels do not dictate its boundary or name. Create the compact
   plan candidate at `docs/plans/<name>.md` with purpose and outcomes, scope and
   non-goals including explicit deferrals, accepted and unresolved ADR
   prerequisites with their required acceptance points, ownership and rejoin
   barriers, cross-cutting evidence obligations,
   compatibility, migration, rollback, packaging, decision owners, and a
   proportional minimalism budget tying proposed abstractions to concrete
   examples or current implementations. Put those commitments inside the exact
   marked `## Normative Envelope` skeleton in `docs/plans/README.md`; keep
   workstreams, progress, resolved outcome state, and evidence links outside it.
   Include the required
   `## Governance Records` table with empty Acceptance and Closure rows. Give
   the plan a normative Outcomes table and exactly one Progress and Evidence
   row for every outcome ID; nothing closes with an open row. The filename and
   canonical register own identity and lifecycle state, so do not duplicate
   either in the plan. Update the canonical status capsule and add exact
   plan/gate links to the milestone register in `docs/plans/README.md`, then
   update README's marked derived status summary. Update `docs/roadmap.md` only
   if the opening changes its non-normative capability projection.
4. Create the branch-only executable acceptance gate at
   `docs/plans/<name>-gate.md`, separate from the plan so its digested bytes do
   not churn as plan progress is recorded. Name exact commands and protected
   tests, selectors, fixtures, vectors, canonical UTF-8/LF
   harness/configuration bytes, evidence classes, and their SHA-256 digest. The
   accepted gate remains immutable for the milestone. Do not stub missing
   behavior green.
5. Prove existing gates remain green and the new gate fails for the declared
   missing outcome. Unknown or shared scope runs the full gate.
6. Keep the red checkpoint off `main`. Commit it only when the current task
   authorizes that Git write.
7. Stop for independent gate and plan acceptance. The recorded acceptance
   authority accepts the plan's normative envelope and the gate's canonical
   UTF-8/LF text and SHA-256 digest; conforming progress is not part of the lock.
   Do not accept while an implementation-blocking ADR prerequisite is
   unresolved. Do not begin
   implementation, weaken the gate, waive evidence, merge the red tree, or
   accept your own work. A later authorized update may move the register to
   `Accepted` only after recording the accepting authority, durable evidence of
   the explicit disposition, the accepted plan-candidate SHA, and gate digest in
   the plan and updating the plans index's complete marked Current Status
   capsule plus README's derived summary. That administrative update changes no
   locked gate or product bytes. Commit it separately, then require independent
   read-only review of its exact diff against the bound candidate before
   integration.
