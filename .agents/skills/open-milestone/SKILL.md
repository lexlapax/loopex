---
name: open-milestone
description: "Open a Loopex milestone: write its plan pair (purpose, outcomes, scope, decisions, and how each outcome will be verified), register it as Open, and present it for acceptance. Use only when the maintainer explicitly asks to start or revise a milestone plan."
disable-model-invocation: true
---

# Open a Milestone

Follow `AGENTS.md` first; read `docs/plans/README.md` for the register, then
use `docs/developer/agent-context-map.md` for routing and version-specific
technical guidance. The process is the
[milestone guide](../../../docs/developer/milestones.md); the checks are the
[verification guide](../../../docs/developer/verification.md).

1. Name it: a lowercase slug or `M` followed by digits, not already in the
   register.
2. Write `docs/plans/<name>.md` — Concept: purpose, numbered outcomes, scope
   and non-goals, the key design decisions and the ADRs they need — and
   `docs/plans/<name>-technical.md` — Technical depth: for every outcome, the
   tests, real-path proof or demonstration that will prove it; ownership and
   rejoin order if workstreams will run in parallel; compatibility, migration
   and rollback expectations. Link the pair reciprocally through the `concept`
   and `technical-depth` anchors.
3. Add the row to the register in `docs/plans/README.md` as `Open` and index
   the pair there. Run `mix loopex.status`: it derives the Current Status
   capsule and prints the exact values it expects.
4. Run `bash scripts/check.sh --docs`.
5. Present the plan to the maintainer with every decision it needs.
   Acceptance is theirs; record it by moving the row to `Accepted`.

No gate script, no locked test names or digests: verification is the current
suite plus the two check commands, and the plan says which tests prove which
outcome.
