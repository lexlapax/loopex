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
   is open; say so. `Proved` means completed implementation is mapped to that
   named proof obligation. A closure-run or review result produced only after
   the candidate exists remains `Pending` in a predeclared scaffold field until
   the administrative commit records the result of running it against that
   candidate.
2. Update the documentation the milestone changed: `CHANGELOG.md`, `README.md`,
   the affected `docs/` pages and indexes. Create
   `docs/evidence/<NAME>-closure-runs.md` as an unfilled scaffold with its final
   headings and fields, mark its results pending, and index it in
   `docs/evidence/README.md`. Both files belong to the tested candidate.
3. Make the exact closure-candidate commit itself move the register and both
   complete marked status blocks from `In progress` to `In review`; supply the
   block bytes and run `mix loopex.status` to validate them. From that **tested
   implementation SHA** —
   run the closure matrix in the
   [verification guide](../../../docs/developer/verification.md#concept-verification-stages):
   `bash scripts/check.sh` under the floor toolchain pair and
   `bash scripts/check-release.sh` once. The current pair's fast check is the
   CI run the candidate already produced; count it rather than repeating it.
   Retain each run's complete output outside the repository, with its stable
   retained-output reference, SHA-256 digest, tested implementation SHA,
   platform, and toolchain. The release check's M5-delivered fresh-source lane runs
   `bash "$tree/scripts/source-archive-manifest.sh" "$tree" >"$retained_manifest"`
   before building, with the retained output outside
   the extraction, and retains those exact NUL-delimited bytes under their own
   stable reference and SHA-256 digest. Step 5 writes those identities, references, and
   digests into the existing evidence-page scaffold, together with every
   plan-required outcome field or placeholder that scaffold predeclared: the
   runs are of the candidate, and the candidate cannot carry its own later
   results.
4. Ask an independent reviewer to read the candidate for outcome compliance,
   correctness, test honesty, public impact, security, and rollback. Retain the
   complete review report outside the repository under a retained-output
   reference with its SHA-256 digest.
5. Present the packet to the maintainer: outcomes and their proof, check
   results, review findings, and what remains. The maintainer closes it; then
   make the **administrative closure commit**, which is
   [confined to five paths and the exact allowed region in each](../../../docs/developer/milestones-technical.md#technical-milestones-confinement):
   the register row moved only from `In review` to `Closed` together with the
   complete supplied Current Status block in `docs/plans/README.md`, the plan's
   Closure row naming the
   **tested implementation SHA** and the content digests — not this commit,
   which cannot contain its own hash and is located by the register transition
   instead — the context-map disposition, the existing evidence page filled
   with step 3's runs, step 4's review and every predeclared plan-required
   outcome value, and the root `README.md` updated only
   between its status markers to the complete `Closed` block supplied by the
   administrative commit. Use the date of the maintainer's recorded closure
   disposition for `Last closed product checkpoint`. Run `mix loopex.status`
   to validate the supplied blocks against the register; the task reports pass
   or failure rather than printing replacement bytes. Retain and inspect the complete patch, mapping every
   changed byte to the guide's allowed-region table. Nothing
   else belongs in it; in particular, `docs/evidence/README.md` does not change
   in the administrative commit.

Tags, packages, and publication are separate maintainer decisions. The
two-commit closure and tag procedure applies from M5 onward; historical
closures and tags keep their recorded procedure. If the maintainer later
authorizes a tag, follow the milestone guide's release sequence. Re-prove the
five-path and allowed-region confinement, then run
the documentation check, the final semantic operator/developer
documentation gate, and the archive comparison on the administrative SHA.
For that comparison, stage a fresh `git archive` extraction, run the
M5-delivered producer
`bash "$tree/scripts/source-archive-manifest.sh" "$tree" >"$retained_manifest"`
with the output outside the extraction, retain those
exact NUL-delimited bytes, reject malformed or duplicate records, and compare
complete tuples after removing `docs` and its descendants plus exact root
`README.md` and the M5-delivered `SOURCE_IDENTITY`
before creating the tag. Retain those outputs outside the repository and put
their results, retained-output references, and SHA-256 digests in the
annotation at creation. Do not amend the evidence page or create a third
commit.
