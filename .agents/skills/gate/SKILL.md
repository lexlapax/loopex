---
name: gate
description: "Open a Loopex milestone: write its plan pair, its outcomes and how each will be verified, and register it. Use only when the maintainer explicitly asks to start or revise a milestone plan."
disable-model-invocation: true
---

# Open a Milestone

Follow `AGENTS.md` first; read `docs/plans/README.md` for the register, then
use `docs/developer/agent-context-map.md` for routing and version-specific
technical guidance. Read the development
charter pair for Concept/Technical depth ownership and anchors.

1. Write `docs/plans/<name>.md` (purpose, outcomes, scope and non-goals, key
   design decisions) and `docs/plans/<name>-technical.md` (ADR prerequisites,
   how each outcome is verified: which tests, which real-path or fresh-source
   proof, which demonstration). Link the pair reciprocally.
2. Add the milestone to the register in `docs/plans/README.md` as `Open`, and
   index the pair there.
3. Run `bash scripts/check.sh`; `mix loopex.status` inside it validates the
   pair, the register, and the indexes.
4. Present the plan to the maintainer for acceptance. Acceptance is the
   maintainer's decision; record it in the register as `Accepted`.

Do not lock test names, digests, or commands in advance, and do not create a
gate script: verification is the current test suite plus the two check
commands in `DEVELOPMENT.md`.
