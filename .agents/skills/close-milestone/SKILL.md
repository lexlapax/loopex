---
name: close-milestone
description: "Assemble a Loopex milestone closure candidate from exact-SHA repository gates, retained evidence, independent review, demonstrations, and Purpose outcomes. Use when asked to assess or prepare closure; never use it to self-accept, waive evidence, tag, release, or publish."
disable-model-invocation: true
---

# Assemble Milestone Closure

Follow `AGENTS.md` first; read `docs/plans/README.md` for canonical status, then
use `docs/developer/agent-context-map.md` for routing and version-specific
technical guidance.

For the named milestone:

1. Assemble the tracked candidate first. Update only conforming plan
   progress/evidence fields, the canonical plans register to `In review`, and
   the plans index's complete marked Current Status capsule and README's marked
   derived summary, plus the exact documentation set locked by the gate. Do not
   set `Closed`.
2. Resolve the resulting exact candidate SHA and accepted gate-lock digest.
   Stop if the working tree or evidence refers to different bytes.
3. Verify every locked repository command is green from a clean checkout at
   that SHA with the required seed, counts, timing, toolchain, platform, limits,
   and non-secret adapter/provider identity. Hosted CI remains supplementary for
   development milestones; only separately authorized release evidence may
   require a hosted provider. Real-provider, store, or executor evidence remains
   gate-lockable and need not run in hosted CI. A retry is diagnostic; a
   disappearing failure is a blocking flake until independently dispositioned.
4. Require independent exact-SHA review. Any unresolved blocking or high-severity
   finding blocks closure regardless of green gates.
5. Reproduce the required demonstration, map every accepted Purpose outcome to
   evidence, demonstration, or an explicitly approved limitation or deferral,
   and assemble a concise closure packet in the task response or an
   already-bound CI artifact. The packet proposes the post-acceptance `Closed`
   transition; it does not record it. After exact-SHA evidence begins, do not
   change tracked candidate bytes merely to paste run links or closure prose.
6. Pause for the recorded closing authority. Do not close the milestone, accept
   your own review, merge, tag, release, or publish. Only that authority's
   explicit disposition authorizes a subsequent update. That update first
   records the closing authority, durable disposition evidence, reviewed
   candidate SHA, and gate digest in the plan's Closure governance row, then
   moves the canonical register to `Closed` and updates the plans index's
   complete marked Current Status capsule plus README's derived summary. That
   administrative transition changes no bound candidate, locked gate, or
   product bytes. Commit it separately, then require independent read-only review
   of its exact diff against the bound candidate before integration.
