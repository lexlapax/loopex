---
name: close-milestone
description: "Assemble a Loopex milestone closure candidate from exact-SHA gates, CI, independent review, demonstrations, and Purpose outcomes. Use when asked to assess or prepare closure; never use it to self-accept, waive evidence, tag, release, or publish."
disable-model-invocation: true
---

# Assemble Milestone Closure

Follow `AGENTS.md` first; route additional context, including current stage
guidance, via `docs/developer/agent-context-map.md`.

For the named milestone:

1. Resolve the exact candidate SHA and accepted gate-lock digest. Stop if the
   working tree or evidence refers to different bytes.
2. Verify every locked command is green locally and in CI for that SHA with the
   required seed, counts, timing, toolchain, platform, limits, and non-secret
   adapter/provider identity. A retry is diagnostic; a disappearing failure is a
   blocking flake until independently dispositioned.
3. Require independent exact-SHA review. Any unresolved blocking or high-severity
   finding blocks closure regardless of green gates.
4. Reproduce the required demonstration and map every accepted Purpose outcome
   to evidence, demonstration, or an explicitly approved limitation or deferral.
5. Assemble a concise closure packet in the task response or an already-bound CI
   artifact. Do not change tracked candidate bytes merely to paste run links or
   closure prose after collecting evidence.
6. Pause for the recorded acceptance authority. Do not close the milestone,
   accept your own review, merge, tag, release, or publish.
