# Changelog

All notable changes to Loopex are recorded here. The format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and versions follow
semantic versioning under the 0.x policy in [docs/vision.md](docs/vision.md)
§24.2 — every public surface is labeled stable, release-candidate, or
experimental, and experimental surfaces may break in a minor release with
migration notes.

Loopex is pre-implementation: nothing is released or installable. Entries below
the first release record repository and planning work only, and carry no
compatibility meaning.

Updating this file is part of a milestone closure candidate, not an optional
courtesy — see [AGENTS.md](AGENTS.md) § Milestones and Gates. Each gate locks
the exact document set its milestone must update.

## [Unreleased]

### Added

- `docs/roadmap.md` — non-normative milestone sequencing: the ladder from M0 to
  1.0, the vision §22 serial barriers, an ADR agenda mapped to the milestone
  each decision blocks, and the plan/ADR/architecture file layout.
- `docs/adr/0001-repository-and-application-layout.md` (Proposed) — Elixir
  umbrella; application boundaries carry dependency direction, and are not
  package boundaries.
- `docs/adr/0002-bootstrap-runtime-floor.md` (Proposed) — OTP 26 / Elixir 1.17
  as the development and CI floor, carrying no compatibility claim; matrix as
  two validated (Elixir, OTP) pairs.
- `scripts/check-commit-messages.sh` — portable commit-title and
  AI-attribution enforcement, wired into `scripts/check-bootstrap.sh`.
- `scripts/check-repo-hygiene.sh` — fails on branches already merged into the
  integration ref and on worktrees that are stale or sitting on landed work.
  In-flight branches and live worktrees pass untouched.
- `docs/plans/README.md` — the human entry point for what the project is
  committed to: the vocabulary, the gate lifecycle, every milestone with its
  state, and how a request's phrasing selects its authority. Git does not track
  empty directories, so `docs/plans/` did not exist in a fresh clone despite
  being referenced by README, the roadmap, and the `gate` skill.
- `scripts/check-status.sh` — asserts the README status block exists and routes
  to the plans index, that every plan file is listed there, and that no gate is
  orphaned.
- A `## Where Things Stand` block at the top of `README.md`, so the GitHub
  landing page answers what is happening and what is next.
- This changelog.

### Changed

- Commit titles now carry a milestone marker: `area(marker): summary`, with
  marker `planning`, `seed`, or a milestone name. Commits at or before
  `f19d2a6` predate the convention.
- The AI-attribution ban is now enforced by a repository check rather than only
  by `.claude/hooks/guard-bash.sh`, which left Codex and CI uncovered.
- Milestone closure now explicitly includes updating the documentation set.
- **Vocabulary defined.** *Stage*, *milestone*, *workstream*, and *release* were
  used interchangeably and never defined. Each now has one meaning and one home,
  and a milestone's name states whether it ships — `M0` is the only M-named
  milestone because it alone produces no release, so the milestone after it is
  `v0.1`, not `M1`.
- Milestone files are two flat documents, `docs/plans/<name>.md` and
  `<name>-gate.md`, replacing the three-file folder. The gate stays separate
  because its bytes are digested at acceptance; there is no evidence file until
  evidence outgrows the plan's outcomes table.
- ADR 0001 no longer conditions its own acceptance on a scaffold commit that
  cannot exist until an accepted gate authorizes it, and now requires
  `apps/loopex` to carry zero dependencies — including dev and test tooling,
  which moves to the umbrella root — matching what the dependency-budget hook
  already enforces.
- The dependency-budget command becomes repository-owned rather than living only
  in a Claude hook.
- `README.md` M0 row: operation truth "across two nodes" → "across a restart".
  The old text contradicted the vision §22 barrier requiring local
  restart-and-replay before any multi-node claim.
- `DEVELOPMENT.md` and the context map described two checks where the aggregate
  runs five, and the context map advertised `mix test` with no Mix project in
  existence.

### Removed

- The duplicated milestone ladder in `README.md`. It restated `docs/roadmap.md`
  and had already drifted from it; the README now points at the roadmap, and the
  roadmap links each rung to its plan file as milestones open.
- Landed work must leave no branch or worktree residue.
- Agents report decisions, not incidental discoveries: resolve a finding in
  scope, fold it into a decision packet, or leave it out.

## Seed bootstrap — closed 2026-08-15

Founding documents, the tool-neutral development contract, portable bootstrap
enforcement, and tested Claude Code and Codex adapters. No product code.
Evidence is retained in
[docs/developer/agent-adapter-smoke.md](docs/developer/agent-adapter-smoke.md).
