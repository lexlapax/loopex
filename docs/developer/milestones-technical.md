# Milestones — Technical Depth

<a id="technical-depth"></a>
## Technical depth

Concept: [Milestones](milestones.md#concept).

<a id="technical-milestones-agree"></a>
### Plan pair contents

Concept: [Agree](milestones.md#concept-milestones-agree).

`docs/plans/NAME.md` starts with its `concept` anchor and `## Concept`,
links to `NAME-technical.md#technical-depth`, and carries these sections:
Purpose; Outcomes (a numbered table: number, outcome, the evidence class that
will prove it); Scope and Non-Goals; Design Decisions (with the ADR each
needs); Progress and Evidence (the numbered table, initially `Open` per row);
Governance Records (Acceptance and Closure rows, `—` until decided).

`docs/plans/NAME-technical.md` starts with its `technical-depth` anchor
and `## Technical depth`, links back to `#concept`, and carries: Prerequisites
(one `### Prerequisites and Acceptance Points` section naming, as links, the
ADRs the milestone waits on and which outcome each blocks — the status check
reads that section's ADR links, so a decision named only in prose declares
nothing, and each one is accepted before the implementation that depends on it
rather than before unrelated work); Verification (for each
outcome, the test files or real-path proof, and whether the release check is
needed); Ownership and Rejoin (only if workstreams run in parallel);
Compatibility, Migration and Rollback; Packaging if any.

Register: add `| \`NAME\` | Open | [concept](NAME.md) | [technical depth](NAME-technical.md) | — |`
to the Milestone Register table in `docs/plans/README.md`. The register's Gate
column is history: a milestone run under the retired gate machinery links its
gate file, and a new milestone's entry is `—`. That row is the pair's index —
the index's Files section states the naming convention and indexes nothing.
Then construct the Current Status capsule from the register under the status
contract and run `mix loopex.status`; it refuses until the capsule holds the
derived values for an `Open` milestone. The task reports pass or failure; it
does not print replacement bytes.

Names: lowercase ASCII letters and digits separated by single hyphens, `M`
followed by digits, or a version-shaped numeric slug such as `1.0` or `v0.1`;
at most 64 ASCII bytes; unique under case folding; none of the reserved names
the index lists.

<a id="technical-milestones-develop"></a>
### Branches, worktrees and progress

Concept: [Develop](milestones.md#concept-milestones-develop).

- Branch per change, off `main`; commit titles `area(NAME): summary`, at
  most 72 characters, no attribution trailers (`scripts/check-commit-messages.sh`
  enforces both over `merge-base(origin/main, HEAD)..HEAD`).
- A feature branch lives only while its pull request is open: nothing reaches
  `main` without a green CI run on the candidate and an independent review, and
  the branch and its worktree go once the merge lands.
  `scripts/check-repo-hygiene.sh` reports every merged branch and stale
  worktree except `main` and the branches the register's milestone names claim,
  which are kept as durable state.
- Before opening the merge: `bash scripts/check.sh` locally or in CI on the
  branch, plus the extra checks the verification guide's selection table names
  for the boundary touched; an independent read of `git diff main..BRANCH`.
- Parallel workstreams: `git worktree add -b BRANCH DIR origin/main` per
  writer; declared non-overlapping paths; the integrator rebases and merges.
  Delete the branch and remove the worktree once merged; the hygiene check
  reports merged branches and stale worktrees that survive.
- Progress: update the outcome's row in the plan's Progress and Evidence table
  in the same change that adds its tests, naming the files. The status check
  validates the pair's links and the register, nothing about the row's prose.
- Amending the plan: edit the pair, and add one line to the progress section
  saying what changed and why. The maintainer decides scope changes; record
  their words there.

<a id="technical-milestones-close"></a>
### The closure packet

Concept: [Close](milestones.md#concept-milestones-close).

At the **tested implementation commit**, which is the closure candidate:

1. The candidate commit itself moves the register row from `In progress` to
   `In review` and supplies the corresponding complete marked status blocks in
   `docs/plans/README.md` and the root `README.md`. `mix loopex.status`
   validates those supplied bytes against the register. The independent
   reviewer then reads that exact commit. The administrative commit, its direct
   child, later makes only the `In review` to `Closed` transition.
2. Every Progress and Evidence row reads `Proved` and names its tests, retained
   evidence or demonstration; an outcome the maintainer deferred says so and
   cites their decision. `Proved` means the implementation is complete and the
   row maps it to a specific proof obligation. It does not claim that a
   post-commit closure run or review has already happened. A field predeclared
   `Pending` in the evidence scaffold is the result or identity of such a proof
   taken *of* this commit after it exists; the administrative commit records
   that later fact.
3. Documentation the milestone changed is updated: `CHANGELOG.md`, `README.md`,
   the affected `docs/` pages and their indexes. The candidate also contains
   `docs/evidence/NAME-closure-runs.md` as an unfilled closure scaffold, indexed
   in `docs/evidence/README.md`. The scaffold has the final headings and fields,
   marks results pending, and claims no run that has not happened.
4. The closure matrix, run **from** that commit: `bash scripts/check.sh` under
   the floor pair with an absolute, pair-specific build root and the
   higher-priority build-path variable removed
   (replace `NAME` with the milestone name in
   `env -u MIX_BUILD_PATH MIX_BUILD_ROOT="/absolute/retained-work/NAME-otp27-build"
   mise exec erlang@27.3.4 elixir@1.18.5-otp-27 -- bash scripts/check.sh`), and
   `bash scripts/check-release.sh` once on
   the current pair with the credential and pinned Node; CI already holds the
   current-pair fast check for the candidate. Each run's revision, platform,
   toolchain, result and measured duration is retained outside the repository
   under a stable retained-output reference with a SHA-256 digest. For M5 and
   later, the release check's fresh-source lane stages the tested SHA
   with `git archive` into an empty extraction and runs the M5-delivered producer
   `bash "$tree/scripts/source-archive-manifest.sh" "$tree" >"$retained_manifest"`
   before the build, with `retained_manifest` outside `tree`. The
   command writes only the canonical NUL-delimited manifest bytes to standard
   output; the runner retains those exact bytes under their own stable
   retained-output reference and SHA-256 digest. The
   administrative commit fills the existing
   `docs/evidence/NAME-closure-runs.md` scaffold with those identities and
   digests, including the tested archive manifest's retained-output reference
   and SHA-256 digest, and every plan-required outcome value whose final field
   or row was predeclared `Pending` in the tested scaffold. The runs are *of* the tested commit, and that commit
   cannot carry its own later results.
5. An independent reviewer reads the candidate for outcome compliance,
   correctness, test honesty, public impact, security and rollback; blocking
   findings are fixed first. Retain the review report outside the repository
   under a retained-output reference with its SHA-256 digest.
6. The packet to the maintainer: outcomes and their proof, the runs, the
   review, what remains. On their decision, the **administrative closure
   commit** moves the register row to `Closed`, fills the plan's Closure row,
   records the maintainer's words in
   `docs/developer/agent-context-map.md`, and fills the evidence-page scaffold
   with the runs of step 4, the review of step 5 and every predeclared
   plan-required outcome value. Supply both complete `Closed` marked blocks,
   using the date of the maintainer's recorded closure disposition for the
   checkpoint date, and run `mix loopex.status` to validate them against the
   register; the task does not print replacement bytes.

**The two SHAs, and what each one carries.**

| | Tested implementation SHA | Administrative closure SHA |
| --- | --- | --- |
| What it is | The candidate the checks ran on and the reviewer read | The commit that records the decision |
| What it changes | Everything the milestone implemented, including the `In review` transition and its two marked status blocks | Only the five paths and the allowed regions within them below |
| What names it | Every run on the evidence page, and the review | The register, once `Closed` |
| Its evidence | The runs of step 4, taken from it | None of its own; it is a record, not a claim |

The administrative closure commit has the tested implementation commit as its
sole parent. An intermediate or merge commit would add a third revision to the
closure and could hide changed-then-restored paths from an endpoint diff.

The plan's **Closure row names the tested implementation SHA** — the candidate
the packet was assembled from — with the exact Bound-bytes syntax defined by
the plans register: for a gate-less milestone,
`candidate <40-hex>; concept sha256:<64-hex>; technical sha256:<64-hex>`.
It does **not** name the administrative SHA, for the reason
the whole split exists: that row *is* the administrative commit's content, and
a commit cannot contain its own hash. An earlier revision asked the row to
name both, which is the same impossibility as asking one commit to carry runs
of itself, one level down.

**The administrative SHA is located rather than written.** Two things point at
it and neither is inside it: the register's transition to `Closed`, whose
commit is that commit, and — once a release happens — the annotated tag, which
names it. A reader tracing the decision follows either; a reviewer checking
the evidence reads the tested SHA out of the Closure row, where it is.

<a id="technical-milestones-confinement"></a>
**The confinement, stated once and referenced everywhere else.** The
administrative closure commit touches **exactly these five paths, and only the
named region within each path**:

| Path | What it carries |
| --- | --- |
| `docs/plans/README.md` | The exact `<NAME>` register-table row, moved from `In review` to `Closed`, and the bytes between `<!-- loopex:current-status:start -->` and `<!-- loopex:current-status:end -->`, replaced by the complete block the administrative commit supplies. Its `Last closed product checkpoint` date is the date of the maintainer's recorded closure disposition. `mix loopex.status` validates the supplied block against the register; it does not generate it |
| `docs/plans/<NAME>.md` | Only the plan's Closure governance-table row, naming the tested implementation SHA and the content digests |
| `docs/developer/agent-context-map.md` | One newly appended, dated subsection recording the maintainer's closure disposition; every pre-existing byte remains unchanged |
| `docs/evidence/<NAME>-closure-runs.md` | Only the scaffold's designated `Pending` value fields and placeholder rows. The tested candidate predeclares every label, heading and row slot that closure will fill, including the generic run identities, results, measured durations, retained-output references and SHA-256 digests of step 4; the tested archive manifest's retained-output reference and SHA-256 digest; the independent review result, retained-output reference and SHA-256 digest; and any plan-required outcome fact, review, demonstration identity, source inventory or measured observation. The administrative commit replaces only those `Pending` values or placeholder cells; it adds no label, heading, row or prose. Every non-placeholder byte remains unchanged |
| `README.md` | Only the bytes between `<!-- loopex:readme-status:start -->` and `<!-- loopex:readme-status:end -->`, replaced by the complete `Closed` summary block the administrative commit supplies; `mix loopex.status` validates its semantic agreement with the register, and every byte outside the markers remains unchanged |

and **nothing else in those files or the tree**. That is the whole rule; every other passage in this
repository that bounds the administrative commit refers here rather than
restating it, because three different formulations of it — "changes nothing
the runs covered", "the register row, the Closure row and the context-map
entry", "nothing outside `docs/`" — coexisted in five documents and disagreed
about whether the evidence page had a home. The tested candidate creates and
indexes that page; the administrative commit only fills it.

Path membership is only the first half of confinement. Inspect the complete
`git diff --no-ext-diff --unified=0 <tested>..<administrative> -- <the five
paths>` and map every changed byte to the table above. Reconstruct
`docs/plans/README.md` from its tested bytes by replacing both its exact
`<NAME>` register row and its marked Current Status block with the corresponding
administrative bytes. Reconstruct the root `README.md` from its tested bytes by
replacing only its marked status block. Require each reconstruction to equal
its administrative file byte for byte. The same review requires the Closure
row, appended context-map subsection and scaffold placeholders to be the only
other changed regions. Retain the full
patch and that five-row content-confinement result outside the repository under
a stable reference and SHA-256 digest. `mix loopex.status` inside
`check.sh --docs` separately validates the supplied status values against the
register; it is not a
substitute for proving that bytes outside their markers did not change.

Content confinement does not cover Git tree metadata. Compare the five paths'
entries with `git ls-tree <tested> -- <the five paths>` and
`git ls-tree <administrative> -- <the five paths>`, and inspect
`git diff --raw --no-renames <tested>..<administrative> -- <the five paths>`.
Every path must remain an ordinary blob with the same file mode at both SHAs;
an object-type or mode change fails confinement even when the changed bytes and
hunks are otherwise allowed. Object IDs may differ because the administrative
regions change.

`git diff --name-only <tested>..<administrative>` must name exactly the five
paths, and `git rev-list --parents -n 1 <administrative>` must show exactly
`<administrative> <tested>`. Any extra parent, path, hunk or byte outside an
allowed region means the evidence no longer covers the tree, and the packet is
reassembled from a new implementation SHA.

**The closure matrix runs once, from the tested implementation SHA**, and the
administrative commit re-runs nothing. The pre-tag release proofs and their
retention are in
[Tags](#technical-milestones-release) — it belongs to the release decision,
which is what creates a tag at all, and an earlier revision of this section
put it here and made closure depend on a tag that closure authorizes.

<a id="technical-milestones-release"></a>
### Tags

Concept: [Release](milestones.md#concept-milestones-release).

This two-commit closure and tag procedure governs M5 and later milestones.
Earlier closures and tags remain governed by their recorded procedures;
`v0.1.0` names M4's integrated source commit and is not retrofitted to this
later rule.

`COMMIT` is the **administrative closure SHA**, not the tested implementation
SHA: it is the commit that carries the closure record, so it is the tree a
reader who fetches the tag gets. Run every row below against `COMMIT` before
creating the tag:

| Step | Command | What a failure means |
| --- | --- | --- |
| Confine the administrative commit | Require `git rev-list --parents -n 1 <administrative>` to return exactly `<administrative> <tested>`; compare `git diff --name-only <tested>..<administrative>` with [the five paths](#technical-milestones-confinement); compare their `git ls-tree` entries and inspect `git diff --raw --no-renames` to require ordinary blobs with unchanged modes; inspect and retain the complete zero-context patch; map every changed byte to its one allowed region; reconstruct `docs/plans/README.md` from its tested bytes plus the administrative register row and marked Current Status block; and reconstruct the root `README.md` from its tested bytes plus the administrative marked status block, requiring byte equality for both files | An extra parent, intermediate commit, missing or extra path, changed object type or mode, hunk outside a named region, changed pre-existing context-map byte, changed scaffold structure, or changed byte outside any permitted region means the tag would publish a tree outside the two-commit closure contract. `mix loopex.status` proving the values does not prove this metadata and byte confinement. The release stops and the packet is reassembled |
| Re-prove the documentation structure | `bash scripts/check.sh --docs` on `COMMIT` | The administrative commit's own documentation changes are not green; fix the candidate and assemble a replacement administrative commit |
| Re-prove documentation meaning | Run the milestone's final semantic documentation gate on the relevant `docs/operator/` and `docs/developer/` pages at `COMMIT` | The operator and developer accounts disagree with each other, the plan, the accepted ADRs, or the implemented behavior; fix the candidate and assemble a replacement administrative commit |
| Re-prove the archive identity | For M5 and later, stage `COMMIT` with `git archive` into a fresh empty extraction, then run the M5-delivered producer as `bash "$tree/scripts/source-archive-manifest.sh" "$tree" >"$retained_manifest"` with `retained_manifest` outside `tree`. Retain those exact bytes. A NUL-aware parser rejects malformed or duplicate records, removes `docs` and its descendants plus exact root `README.md` and the M5-delivered `SOURCE_IDENTITY`, and compares every remaining complete tuple with the manifest bytes retained for the tested SHA. Require exactly one root `SOURCE_IDENTITY` in each archive and validate it against that archive's own commit and source identity | The command or source identity is absent, fails validation, emits a malformed or duplicate record stream, or the published bytes are not the closed bytes outside the confined regions. Entries under `docs/`, the supplied root README and the two `SOURCE_IDENTITY` payloads are expected to differ. The preceding content-confinement proof covers every permitted documentation hunk and the README's exact marked-block replacement. This comparison catches archive inclusion or exclusion changes that `.gitattributes` can cause without a path appearing in `git diff` |

Nothing else is re-run. There is no second suite, no second release check and
no second provider credential: the tested tree and the administrative tree
differ only in documentation, which is exactly the property the first step
establishes. The semantic gate reads `docs/operator` and `docs/developer`; the
structural check still covers the documentation paths that `check.sh --docs`
selects.

The semantic gate starts with a complete file inventory of `docs/operator/`
and `docs/developer/`. It identifies every page affected by the milestone and
accounts for new, renamed and removed pages. For each relevant page, it checks
the administrative SHA against the implemented behavior, the plan, accepted
ADRs and the other relevant pages. The retained checklist names every file and
records either the comparison result or why the file is not relevant.

Retain the complete output and the compared manifests from these release
proofs outside the repository in immutable, content-addressed storage. Create
the annotated tag only after every row passes. At creation, its annotation
names both SHAs and records each proof's result, retained-output reference, and
SHA-256 digest. It also records both archive-manifest retained-output references
and SHA-256 digests and both validated `SOURCE_IDENTITY` values. The evidence
page remains the closure record and is not amended with release proofs. This
sequence adds no third commit, and no proof named by the tag can postdate the
tag.

A **retained-output reference** is the maintainer-controlled stable locator or
object name for one immutable complete output. Every retained-output reference
is paired with the SHA-256 digest of that object. The evidence page is the
reference carrier for closure outputs; the tag annotation is the reference
carrier for release outputs.

Create `git tag -a vVERSION COMMIT` with that complete annotation, then push
the tag on the maintainer's explicit decision. The source version
in `VERSION` changes in an ordinary reviewed commit before closure when the
milestone's plan calls for it; every application reads it at compile time.
