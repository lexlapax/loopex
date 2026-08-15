---
name: gate
description: "Open a Loopex milestone gate-first. Use only when the maintainer or a recorded delegate explicitly asks to create or revise a milestone plan candidate and its branch-only red executable acceptance gate before implementation."
disable-model-invocation: true
---

# Open a Milestone Gate

Follow `AGENTS.md` first; read `docs/plans/README.md` for canonical status, then
use `docs/developer/agent-context-map.md` for routing and version-specific
technical guidance. Read the development charter pair for Concept/Technical
depth ownership, anchors, reciprocal links, and response form.

For the named milestone:

1. Verify the designated green base is a committed maintainer-designated SHA
   and run every existing required check. Treat a missing check as unavailable
   evidence.
2. For `M0`, first require structurally Accepted records in ADR 0001 and ADR
   0002. Do not create or open it for any other status. Its opening branch also
   replaces the exact seed-status guard with lifecycle-specific checks; do not
   remove or weaken the guard.
3. Map the milestone's bounded outcomes to the capability rung or rungs they
   serve; roadmap labels do not dictate its boundary or name. Create the exact
   pair from `docs/plans/README.md`:

   ```text
   docs/plans/<name>.md
   docs/plans/<name>-technical.md
   ```

   The Concept envelope owns purpose and outcomes, scope, non-goals including
   explicit deferrals, and observable constraints. The Technical depth envelope
   owns accepted and unresolved ADR prerequisites and acceptance points,
   ownership and rejoin barriers, evidence mapping, compatibility, migration,
   rollback, packaging, decision owners, and a proportional minimalism budget
   tying every proposed abstraction to concrete examples or current
   implementations. Neither may add hidden scope or contradict the other.
   Keep workstreams, progress, resolved outcome state, and evidence links
   outside both envelopes. The Concept file owns `## Governance Records` with
   empty Acceptance and Closure rows and exactly one Progress and Evidence row
   for every outcome ID; nothing closes with an open row. The filename and
   register own identity and lifecycle state. Update the canonical status
   capsule and add exact Concept/Technical depth/Gate links to the register,
   then update README's marked derived status summary. Update the roadmap pair
   only if the opening changes its non-normative capability projection; never
   change the vision pair without an explicit current request naming a vision
   change.
4. Create the branch-only executable acceptance gate at
   `docs/plans/<name>-gate.md`, separate from the plan pair so its digested bytes do
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
   authority accepts both normative envelopes and the gate's canonical UTF-8/LF
   text; conforming progress is not part of the lock.
   Do not accept while an implementation-blocking ADR prerequisite is
   unresolved. Do not begin
   implementation, weaken the gate, waive evidence, merge the red tree, or
   accept your own work. A later authorized update may move the register to
   `Accepted` only after recording the accepting authority, durable evidence of
   the explicit disposition, accepted plan-candidate SHA, Concept-envelope
   digest, Technical-depth-envelope digest, and gate digest in the Concept plan,
   then updating the plans index's complete marked Current Status capsule plus
   README's derived summary. That administrative update changes no Technical
   depth, locked gate, or product bytes. Commit it separately, then require
   independent read-only review of its exact diff against the bound candidate
   before integration.
