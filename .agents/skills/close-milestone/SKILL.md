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
   the affected `docs/` pages and indexes. Create
   `docs/evidence/<NAME>-closure-runs.md` as an unfilled scaffold with its final
   headings and fields, mark its results pending, and index it in
   `docs/evidence/README.md`. Both files belong to the tested candidate.
3. From the exact committed candidate — the **tested implementation SHA** —
   run the closure matrix in the
   [verification guide](../../../docs/developer/verification.md#concept-verification-stages):
   `bash scripts/check.sh` under the floor toolchain pair and
   `bash scripts/check-release.sh` once. The current pair's fast check is the
   CI run the candidate already produced; count it rather than repeating it.
   Retain each run's complete output outside the repository, with its stable
   retained-output reference, SHA-256 digest, tested implementation SHA,
   platform, and toolchain. Step 5 writes those identities, references, and
   digests into the existing evidence-page scaffold: the runs are of the
   candidate, and the candidate cannot carry its own later results.
4. Ask an independent reviewer to read the candidate for outcome compliance,
   correctness, test honesty, public impact, security, and rollback. Retain the
   complete review report outside the repository under a retained-output
   reference with its SHA-256 digest.
5. Present the packet to the maintainer: outcomes and their proof, check
   results, review findings, and what remains. The maintainer closes it; then
   make the **administrative closure commit**, which is
   [confined to four paths](../../../docs/developer/milestones-technical.md#technical-milestones-confinement):
   the register row moved to `Closed`, the plan's Closure row naming the
   **tested implementation SHA** and the content digests — not this commit,
   which cannot contain its own hash and is located by the register transition
   instead — the context-map disposition, and the existing evidence page filled
   with step 3's runs and step 4's review. Nothing else belongs in it; in particular,
   `docs/evidence/README.md` does not change in the administrative commit.

Tags, packages, and publication are separate maintainer decisions. If the
maintainer later authorizes a tag, follow the milestone guide's release
sequence. Run the documentation check, the final semantic operator/developer
documentation gate, and the archive comparison on the administrative SHA
before creating the tag. Retain those outputs outside the repository and put
their results, retained-output references, and SHA-256 digests in the
annotation at creation. Do not amend the evidence page or create a third
commit.
