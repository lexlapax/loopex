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
(ADRs and what must be accepted before which outcome); Verification (for each
outcome, the test files or real-path proof, and whether the release check is
needed); Ownership and Rejoin (only if workstreams run in parallel);
Compatibility, Migration and Rollback; Packaging if any.

Register: add `| \`NAME\` | Open | [concept](NAME.md) | [technical depth](NAME-technical.md) | — |`
to the Milestone Register table in `docs/plans/README.md` and index the pair
in its Files section; a gate column entry is `—` for a new milestone. Then run
`mix loopex.status`; it refuses until the Current Status capsule holds the
values it derives for an `Open` milestone and prints what it expects.

Names: lowercase ASCII letters and digits separated by single hyphens, or `M`
followed by digits; at most 64 bytes; unique under case folding.

<a id="technical-milestones-develop"></a>
### Branches, worktrees and progress

Concept: [Develop](milestones.md#concept-milestones-develop).

- Branch per change, off `main`; commit titles `area(NAME): summary`, at
  most 72 characters, no attribution trailers (`scripts/check-commit-messages.sh`
  enforces both).
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

At the candidate commit:

1. Every Progress and Evidence row reads `Proved` and names its tests, retained
   evidence or demonstration; an outcome the maintainer deferred says so and
   cites their decision.
2. Documentation the milestone changed is updated: `CHANGELOG.md`, `README.md`,
   the affected `docs/` pages and their indexes.
3. Runs from the exact candidate, retained on `docs/evidence/NAME-closure-runs.md`
   (indexed in `docs/evidence/README.md`) with revision, platform, toolchain,
   result and measured duration: `bash scripts/check.sh` under the floor pair
   (`mise exec erlang@27.3.4 elixir@1.18.5-otp-27 -- bash scripts/check.sh`,
   with its own `MIX_BUILD_ROOT`), and `bash scripts/check-release.sh` once on
   the current pair with the credential and pinned Node; CI already holds the
   current-pair fast check for the candidate.
4. An independent reviewer reads the candidate for outcome compliance,
   correctness, test honesty, public impact, security and rollback; blocking
   findings are fixed first.
5. The packet to the maintainer: outcomes and their proof, the runs, the
   review, what remains. On their decision, the closure commit moves the
   register row to `Closed`, fills the plan's Closure row with the candidate
   SHA and the digests of the pair, and records the maintainer's words in
   `docs/developer/agent-context-map.md`. `mix loopex.status` derives the
   `Closed` capsule; run it and copy what it expects.

<a id="technical-milestones-release"></a>
### Tags

Concept: [Release](milestones.md#concept-milestones-release).

`git tag -a vVERSION COMMIT -m "NAME closure"` and `git push
origin vVERSION`, on the maintainer's explicit decision. The source version
in `VERSION` changes in an ordinary reviewed commit before closure when the
milestone's plan calls for it; every application reads it at compile time.
