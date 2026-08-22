---
name: gate
description: "Open a Loopex milestone gate-first, including the single permitted planning lookahead after current-governance integration. Use only when the maintainer or a recorded delegate explicitly asks to create or revise a milestone plan candidate and its branch-only red executable acceptance gate before implementation."
disable-model-invocation: true
---

# Open a Milestone Gate

Follow `AGENTS.md` first; read `docs/plans/README.md` for canonical status, then
use `docs/developer/agent-context-map.md` for routing and version-specific
technical guidance. Read the development charter pair for Concept/Technical
depth ownership, anchors, reciprocal links, and response form.

For the named milestone:

1. Read the whole milestone register and classify the request before choosing a
   base.

   - For an ordinary opening, use the exact integrated final-Closed product base,
     require every inherited gate green, and treat any missing check as
     unavailable evidence.
   - For the one permitted planning lookahead, require exactly one current
     delivery milestone recorded as `Accepted`, no other `Open` or `Blocked`
     successor, and the current milestone's accepted governance checkpoint
     already integrated to `main`. A new successor
     branches from that exact `main` SHA; a revision of the already registered
     Open successor must retain that base and remain planning-only. Keep the
     bootstrap aggregate and every Closed gate green; reproduce the current
     milestone's exact accepted opening red separately so it cannot mask the
     successor's own declared red. The current milestone remains the sole
     product implementation authority.

   - To refresh an existing Open successor after its predecessor closes, require
     that closure integrated to `main`, absorb that exact SHA before review, and
     use the ordinary posture: every inherited gate green and the successor's own
     distinct declared red.

   A second successor, two delivery milestones, an uncommitted base, or an
   inherited failure without the same command and signature at the base stops
   the opening.
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
5. Prove the opening posture that step 1 selected. For an ordinary opening,
   existing gates remain green and the new gate fails for the declared missing
   outcome. For a planning lookahead, Closed gates remain green, the current
   accepted red is reproduced in isolation, and the successor gate separately
   fails for its own declared missing outcome. Unknown or shared scope runs the
   full gate; one red may never stand in for another.
6. Keep the red checkpoint off `main`. Commit it only when the current task
   authorizes that Git write.
7. Stop for independent gate and plan acceptance. The recorded acceptance
   authority accepts both normative envelopes and the gate's canonical UTF-8/LF
   text; conforming progress is not part of the lock.
   Do not accept while an implementation-blocking ADR prerequisite is
   unresolved. A planning-lookahead successor cannot be accepted until its
   current predecessor is Closed and integrated; first absorb that exact closed
   product base, re-prove every inherited gate green and the successor's own
   distinct red, and obtain a fresh exact-SHA review. Do not begin implementation,
   weaken the gate, waive evidence, merge an Open red tree, or accept your own
   work.

   A later authorized update may move an eligible register row to `Accepted`
   only after recording the accepting authority, durable evidence of the
   explicit disposition, accepted plan-candidate SHA, Concept-envelope digest,
   Technical-depth-envelope digest, and gate digest in the Concept plan, then
   updating the plans index's complete marked Current Status capsule plus
   README's derived summary. That administrative update changes no Technical
   depth, locked gate, or product bytes. Commit it separately, then require
   independent read-only review of its exact diff against the bound candidate.
   With explicit protected-branch approval, the complete governance checkpoint
   may then integrate to `main` while its exact accepted opening gate remains
   red, provided the base-to-transition review confirms it contains no milestone
   product implementation bytes. Product work remains on the designated branch
   and does not integrate until separately approved closure.

   For an amendment to an already Accepted plan, use the repository's generic
   two-revision, direct one-parent transaction. Number Amendment sections
   consecutively in physical document order. Put the single visible
   `<a id="amendment-transaction-v1"></a>` marker in every active or future
   amended gate; closed pre-v1 amendment history remains valid. Proposal `A` is the first revision
   that advances the generation and retains the prior Acceptance row and
   lifecycle state:
   require its binding-dependent commands to fail only for that stale binding,
   run every binding-independent check, and reproduce the amended gate's
   truthful product state directly. After exact-SHA review and explicit
   acceptance, create immediate-child administrative rebind `R`; it binds exact
   `A`, preserves lifecycle state, changes only the Acceptance row, adds one new
   amendment-specific authority-disposition anchor to an existing durable
   document; the anchor was absent at `A`. Update only conforming derived status
   blocks. Never reuse, complete, or edit an earlier disposition, interpose a
   commit, overlap another proposal, or begin the next amendment before `R`. At
   `R`, require status, bootstrap, and every inherited gate green, and reproduce
   the same direct product-gate state. Review both `A` to `R` and the integration
   base to `R`. Never attribute an `R` result to `A`, treat `A` as a product
   candidate, or let either proof substitute for later same-source closure
   evidence.
