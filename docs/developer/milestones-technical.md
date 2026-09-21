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
   the affected `docs/` pages and their indexes.
3. The closure matrix, run **from** that commit: `bash scripts/check.sh` under
   the floor pair
   (`mise exec erlang@27.3.4 elixir@1.18.5-otp-27 -- bash scripts/check.sh`,
   with its own `MIX_BUILD_ROOT`), and `bash scripts/check-release.sh` once on
   the current pair with the credential and pinned Node; CI already holds the
   current-pair fast check for the candidate. Each run's revision, platform,
   toolchain, result and measured duration is **recorded on
   `docs/evidence/NAME-closure-runs.md`** (indexed in
   `docs/evidence/README.md`) **by the administrative commit, not by this
   one** — the runs are *of* the tested commit, and a commit cannot carry runs
   of itself. That page is one of the four paths below.
4. An independent reviewer reads the candidate for outcome compliance,
   correctness, test honesty, public impact, security and rollback; blocking
   findings are fixed first.
5. The packet to the maintainer: outcomes and their proof, the runs, the
   review, what remains. On their decision, the **administrative closure
   commit** moves the register row to `Closed`, fills the plan's Closure row,
   records the maintainer's words in
   `docs/developer/agent-context-map.md`, and writes the evidence page with
   the runs of step 3. `mix loopex.status` derives the
   `Closed` capsule; run it and copy what it expects.

**The two SHAs, and what each one carries.**

| | Tested implementation SHA | Administrative closure SHA |
| --- | --- | --- |
| What it is | The candidate the checks ran on and the reviewer read | The commit that records the decision |
| What it changes | Everything the milestone implemented | The four paths below, and nothing else |
| What names it | Every run on the evidence page, and the review | The register, once `Closed` |
| Its evidence | The runs of step 3, taken from it | None of its own; it is a record, not a claim |

The plan's **Closure row carries both**: the tested implementation SHA the
packet was assembled from, and the administrative SHA that closed it. A
reviewer checking the milestone reads the first; a reader tracing the decision
reads the second. Recording only one leaves either the evidence or the
decision unlocatable.

<a id="technical-milestones-confinement"></a>
**The confinement, stated once and referenced everywhere else.** The
administrative closure commit touches **exactly these four paths**:

| Path | What it carries |
| --- | --- |
| `docs/plans/README.md` | The register row, moved to `Closed` |
| `docs/plans/<NAME>.md` | The plan's Closure row, naming both SHAs |
| `docs/developer/agent-context-map.md` | The maintainer's closure disposition |
| `docs/evidence/<NAME>-closure-runs.md` | The run identities, results and measured durations of step 3, the archive manifest's digest, and the security review |

and **nothing else**. That is the whole rule; every other passage in this
repository that bounds the administrative commit refers here rather than
restating it, because three different formulations of it — "changes nothing
the runs covered", "the register row, the Closure row and the context-map
entry", "nothing outside `docs/`" — coexisted in five documents and disagreed
about whether the evidence page had a home.

All four are under `docs/`, so "the administrative commit touches nothing
outside `docs/`" is a **consequence** of this rule rather than a second rule,
and that is how the release step states it. `git diff --name-only
<tested>..<administrative>` against those four paths is the check; anything
else in that diff means the evidence no longer covers the tree, and the packet
is reassembled from a new implementation SHA.

**The closure matrix runs once, from the tested implementation SHA**, and the
administrative commit re-runs nothing. What the tag re-proves, and how it is
confined so that two documentation checks are enough, is in
[Tags](#technical-milestones-release) — it belongs to the release decision,
which is what creates a tag at all, and an earlier revision of this section
put it here and made closure depend on a tag that closure authorizes.

<a id="technical-milestones-release"></a>
### Tags

Concept: [Release](milestones.md#concept-milestones-release).

`COMMIT` is the **administrative closure SHA**, not the tested implementation
SHA: it is the commit that carries the closure record, so it is the tree a
reader who fetches the tag gets. Before tagging:

| Step | Command | What a failure means |
| --- | --- | --- |
| Confine the administrative diff | `git diff --name-only <tested>..<administrative>`, against [the four paths](#technical-milestones-confinement) | Any other path means the tag would publish source the closure evidence does not cover; the release stops and the packet is reassembled from a new implementation SHA. Because all four are under `docs/`, a passing check also establishes that nothing outside `docs/` moved, which is what makes the two re-proofs below sufficient |
| Re-prove the documentation | `bash scripts/check.sh --docs` on the tagged SHA | The administrative commit's own documentation changes are not green; fix and re-tag |
| Re-prove the archive identity | Recompute the archive manifest from the tagged SHA and compare every entry **outside `docs/`** with the manifest recorded on the evidence page for the tested SHA | The published bytes are not the closed bytes outside `docs/`. The entries under `docs/` are expected to differ and are not compared; comparing the whole manifest would be a check that can never pass. What this catches beyond step 1 is an archive that includes or excludes differently from the tree — `.gitattributes` moves bytes into and out of an archive without appearing in a `git diff` |

Nothing else is re-run. There is no second suite, no second release check and
no second provider credential: the tested tree and the tagged tree differ only
in documentation, which is exactly the property the first step establishes and
the reason two documentation-scoped checks suffice. The documentation gate's
scope is unchanged — `docs/operator` and `docs/developer`, as the verification
guide fixes it — and widening it to all of `docs/` was a claim an earlier
revision of the closure section made and nothing implements.

`git tag -a vVERSION COMMIT -m "NAME closure"` and `git push
origin vVERSION`, on the maintainer's explicit decision. The source version
in `VERSION` changes in an ordinary reviewed commit before closure when the
milestone's plan calls for it; every application reads it at compile time.
