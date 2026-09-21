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
Then run
`mix loopex.status`; it refuses until the Current Status capsule holds the
values it derives for an `Open` milestone and prints what it expects.

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

1. Every Progress and Evidence row reads `Proved` and names its tests, retained
   evidence or demonstration; an outcome the maintainer deferred says so and
   cites their decision.
2. Documentation the milestone changed is updated: `CHANGELOG.md`, `README.md`,
   the affected `docs/` pages and their indexes. The candidate also contains
   `docs/evidence/NAME-closure-runs.md` as an unfilled closure scaffold, indexed
   in `docs/evidence/README.md`. The scaffold has the final headings and fields,
   marks results pending, and claims no run that has not happened.
3. The closure matrix, run **from** that commit: `bash scripts/check.sh` under
   the floor pair
   (`mise exec erlang@27.3.4 elixir@1.18.5-otp-27 -- bash scripts/check.sh`,
   with its own `MIX_BUILD_ROOT`), and `bash scripts/check-release.sh` once on
   the current pair with the credential and pinned Node; CI already holds the
   current-pair fast check for the candidate. Each run's revision, platform,
   toolchain, result and measured duration is retained outside the repository
   under a stable retained-output reference with a SHA-256 digest. The
   administrative commit fills the existing
   `docs/evidence/NAME-closure-runs.md` scaffold with those identities and
   digests, including the tested archive manifest's retained-output reference
   and SHA-256 digest. The runs are *of* the tested commit, and that commit
   cannot carry its own later results.
4. An independent reviewer reads the candidate for outcome compliance,
   correctness, test honesty, public impact, security and rollback; blocking
   findings are fixed first. Retain the review report outside the repository
   under a retained-output reference with its SHA-256 digest.
5. The packet to the maintainer: outcomes and their proof, the runs, the
   review, what remains. On their decision, the **administrative closure
   commit** moves the register row to `Closed`, fills the plan's Closure row,
   records the maintainer's words in
   `docs/developer/agent-context-map.md`, and fills the evidence-page scaffold
   with the runs of step 3 and the review of step 4. `mix loopex.status` derives the
   `Closed` capsule; run it and copy what it expects.

**The two SHAs, and what each one carries.**

| | Tested implementation SHA | Administrative closure SHA |
| --- | --- | --- |
| What it is | The candidate the checks ran on and the reviewer read | The commit that records the decision |
| What it changes | Everything the milestone implemented | The four paths below, and nothing else |
| What names it | Every run on the evidence page, and the review | The register, once `Closed` |
| Its evidence | The runs of step 3, taken from it | None of its own; it is a record, not a claim |

The administrative closure commit has the tested implementation commit as its
sole parent. An intermediate or merge commit would add a third revision to the
closure and could hide changed-then-restored paths from an endpoint diff.

The plan's **Closure row names the tested implementation SHA** — the candidate
the packet was assembled from — with the content digests closure rows have
always carried. It does **not** name the administrative SHA, for the reason
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
administrative closure commit touches **exactly these four paths**:

| Path | What it carries |
| --- | --- |
| `docs/plans/README.md` | The register row, moved to `Closed` |
| `docs/plans/<NAME>.md` | The plan's Closure row, naming the tested implementation SHA and the content digests |
| `docs/developer/agent-context-map.md` | The maintainer's closure disposition |
| `docs/evidence/<NAME>-closure-runs.md` | The existing scaffold, filled with the run identities, results, measured durations, retained-output references and SHA-256 digests of step 3; the tested archive manifest's retained-output reference and SHA-256 digest; and the independent review result, retained-output reference and SHA-256 digest |

and **nothing else**. That is the whole rule; every other passage in this
repository that bounds the administrative commit refers here rather than
restating it, because three different formulations of it — "changes nothing
the runs covered", "the register row, the Closure row and the context-map
entry", "nothing outside `docs/`" — coexisted in five documents and disagreed
about whether the evidence page had a home. The tested candidate creates and
indexes that page; the administrative commit only fills it.

All four are under `docs/`, so "the administrative commit touches nothing
outside `docs/`" is a **consequence** of this rule rather than a second rule,
and that is how the release step states it. `git diff --name-only
<tested>..<administrative>` against those four paths is the content check;
`git rev-list --parents -n 1 <administrative>` must show exactly
`<administrative> <tested>`. Anything else in the parent line or the diff means
the evidence no longer covers the tree, and the packet is reassembled from a
new implementation SHA.

**The closure matrix runs once, from the tested implementation SHA**, and the
administrative commit re-runs nothing. The pre-tag release proofs and their
retention are in
[Tags](#technical-milestones-release) — it belongs to the release decision,
which is what creates a tag at all, and an earlier revision of this section
put it here and made closure depend on a tag that closure authorizes.

<a id="technical-milestones-release"></a>
### Tags

Concept: [Release](milestones.md#concept-milestones-release).

`COMMIT` is the **administrative closure SHA**, not the tested implementation
SHA: it is the commit that carries the closure record, so it is the tree a
reader who fetches the tag gets. Run every row below against `COMMIT` before
creating the tag:

| Step | Command | What a failure means |
| --- | --- | --- |
| Confine the administrative commit | Require `git rev-list --parents -n 1 <administrative>` to return exactly `<administrative> <tested>`, then compare `git diff --name-only <tested>..<administrative>` with [the four paths](#technical-milestones-confinement) | An extra parent, an intermediate commit, a missing path or any other path means the tag would publish a tree outside the two-commit closure contract; the release stops and the packet is reassembled. Because all four paths are under `docs/`, a passing check also establishes that nothing outside `docs/` moved, which is what makes the three re-proofs below sufficient |
| Re-prove the documentation structure | `bash scripts/check.sh --docs` on `COMMIT` | The administrative commit's own documentation changes are not green; fix the candidate and assemble a replacement administrative commit |
| Re-prove documentation meaning | Run the milestone's final semantic documentation gate on the relevant `docs/operator/` and `docs/developer/` pages at `COMMIT` | The operator and developer accounts disagree with each other, the plan, the accepted ADRs, or the implemented behavior; fix the candidate and assemble a replacement administrative commit |
| Re-prove the archive identity | Recompute the archive manifest from `COMMIT`. Compare every entry outside `docs/`, except `SOURCE_IDENTITY`, with the manifest retained for the tested SHA. Require exactly one root `SOURCE_IDENTITY` in each archive and validate it against that archive's own commit and source identity | The published bytes are not the closed bytes outside `docs/`, or an archive identifies the wrong source. The entries under `docs/` and the two `SOURCE_IDENTITY` payloads are expected to differ. What this catches beyond step 1 is an archive that includes or excludes differently from the tree; `.gitattributes` can make that change without a path appearing in `git diff` |

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
