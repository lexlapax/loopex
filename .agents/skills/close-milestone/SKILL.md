---
name: close-milestone
description: "Assemble a Loopex milestone closure candidate: map every outcome to evidence, run the fast and release checks from the exact candidate, and prepare the closure record. Use when asked to assess or prepare closure; never use it to self-accept, tag, release, or publish."
disable-model-invocation: true
---

# Close a Milestone

Follow `AGENTS.md` first; read `docs/plans/README.md` for the register, then
use `docs/developer/agent-context-map.md` for routing and version-specific
technical guidance. The process is the
[milestone guide](../../../docs/developer/milestones.md); the checks are the
[verification guide](../../../docs/developer/verification.md).

1. In the plan's progress section, map every purpose outcome to the tests,
   retained evidence, or demonstration that proves it. An outcome with no proof
   is open; say so.
2. Update the documentation the milestone changed: `CHANGELOG.md`, `README.md`,
   the affected `docs/` pages and indexes.
3. From the exact committed candidate, run `bash scripts/check.sh` on each
   supported platform and `bash scripts/check-release.sh` once. Retain each
   run's complete output with the candidate SHA, platform, and toolchain.
4. Ask an independent reviewer to read the candidate for outcome compliance,
   correctness, test honesty, public impact, security, and rollback.
5. Present the packet to the maintainer: outcomes and their proof, check
   results, review findings, and what remains. The maintainer closes it; then
   move the register row to `Closed` and record the candidate SHA in the plan.

Tags, packages, and publication are separate maintainer decisions.
