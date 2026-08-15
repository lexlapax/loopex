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
- This changelog.

### Changed

- Commit titles now carry a stage marker: `area(marker): summary`, with marker
  `planning`, `seed`, or a milestone name. Commits at or before `f19d2a6`
  predate the convention.
- The AI-attribution ban is now enforced by a repository check rather than only
  by `.claude/hooks/guard-bash.sh`, which left Codex and CI uncovered.
- Milestone closure now explicitly includes updating the documentation set.

## Seed bootstrap — closed 2026-08-15

Founding documents, the tool-neutral development contract, portable bootstrap
enforcement, and tested Claude Code and Codex adapters. No product code.
Evidence is retained in
[docs/developer/agent-adapter-smoke.md](docs/developer/agent-adapter-smoke.md).
