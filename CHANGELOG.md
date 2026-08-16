# Changelog

All notable changes to Loopex are recorded here. The format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and versions follow
semantic versioning under the
[0.x compatibility policy](docs/vision.md#concept-vision-compatibility) — every
public surface is labeled stable, release-candidate, or
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

- Model-neutral development routing now matches capability to consequence:
  efficient profiles own objective repeatable work, balanced profiles own
  bounded implementation, and deep reasoning owns architecture, durability,
  security, public contracts, gate/rejoin judgment, and independent review.
  Current client mappings remain dated context guidance; repository profiles
  inherit the caller model rather than pinning account-specific aliases.
- A paired documentation model: Concept documents state purpose, constraints,
  observable behavior, and decisions; Technical depth companions carry
  invariants, commands, evidence, edge cases, and implementation constraints.
  `docs/README.md` indexes active pairs and routes to the exception rules.
- `docs/developer/development-charter.md` and its technical companion establish
  clarity-before-mechanism, exact anchored traceability, proportional code
  documentation, and structural plus independent semantic review.
- Technical companions for the founding vision, roadmap, and both Proposed
  founding ADRs. Each pair is one authority and is changed, reviewed, and—where
  governed—digested together.
- `docs/roadmap.md` — non-normative capability guidance: revisable working
  labels, the vision's serial barriers, and an ADR agenda mapped to the first
  capability each decision blocks.
- `docs/adr/0001-repository-and-application-layout.md` (Proposed) — Elixir
  umbrella; application boundaries carry dependency direction, and are not
  package boundaries. Revised to split `apps/loopex_protocol` — the versioned
  protocol types and extension contract, with no dependencies — out of
  `apps/loopex`, because an out-of-repository extension author can only compile
  against something published, and shipping the extension API inside the runtime
  package would weld two separately versioned compatibility surfaces to one
  version. The deviation from the vision's singular protocol/core/runtime
  application is stated in the ADR rather than left to be discovered.
- Vision: an extension manifest now records the exact Erlang/OTP and Elixir
  versions its retained bytes were compiled with, and activation verifies that
  record against the running runtime; installation sources (in-repository,
  host-admitted filesystem location, package registry) are named as acquisition
  inputs to the builder or validation distribution rather than load paths, with
  the configuration naming them owned by the host; and released package names
  and version constraints are recorded as a seventh compatibility surface,
  inert until first publication.
- `docs/adr/0003-extension-contract-boundary.md` (Proposed) and its technical
  companion — a contributor compiles against the extension contract, never the
  runtime; only contract and runtime are candidate published units; publication
  waits for a consumer; first-party extensions get no shortcut past the
  manifest, sealing, and activation path; a filesystem location is an
  acquisition source rather than a load path; and the host owns the
  configuration naming sources. It blocks nothing and defers the installation
  pipeline, closure conflict resolution, signing formats, host config schema,
  and registry acquisition to the milestone that builds extensions.
- `docs/adr/0002-bootstrap-runtime-floor.md` (Proposed) — OTP 26 / Elixir 1.17
  as the development and locally runnable validation floor, carrying no
  compatibility claim; matrix as two validated (Elixir, OTP) pairs.
- `scripts/check-commit-messages.sh` — portable commit-title and prohibited
  content-origin-claim enforcement, wired into `scripts/check-bootstrap.sh`.
- `scripts/check-repo-hygiene.sh` — fails on branches already merged into the
  integration ref and on worktrees that are stale or sitting on landed work.
  In-flight branches and live worktrees pass untouched.
- `docs/plans/README.md` — the canonical revision-scoped status register,
  accepted/active/closed plan index, milestone lifecycle, and request-authority
  guide. Future roadmap rungs remain candidates rather than commitments.
- `scripts/check-status.sh` and its tracked Python bridge — validate exact marked
  status, register, and rejoin blocks; plan/gate/governance correspondence; and
  the derived README summary, with in-memory adversarial controls rather than a
  general Markdown parser. M0 replaces the bridge with Elixir/Mix.
- A `## Where Things Stand` block at the top of `README.md`, so the GitHub
  landing page answers what is happening and what is next.
- `docs/developer/README.md` — the directory index and the start-here reading
  order for someone new to the repository. It routes to setup, status, contract,
  and charter rather than restating them, so there is no separate quickstart to
  drift.
- `docs/adr/README.md` — the decision index, how a decision is recorded, and
  what distinguishes an ADR from a reversible implementation choice.
- A required documentation index chain: every directory under `docs/` carries a
  `README.md` describing its contents and linking back to `docs/README.md`,
  which links back to the root README. `scripts/check_status.py` enforces the
  chain — missing index, missing forward link, and missing back-link each fail —
  so a document cannot be reachable only by knowing it exists.
- The current per-client milestone invocation is recorded in the context map:
  opening and closing are maintainer keystrokes, because no actor may open or
  close its own gate. Keystrokes live with the version-specific client facts;
  the verbs and their authority stay in the plans register.
- A developer workflow guide in `docs/plans/README.md` § Directing the Work:
  what to ask for, where each request stops, what stops regardless of phrasing,
  and what changes when a milestone opens. The verbs belong to the repository,
  so client shortcuts and the seed-to-Mix migration leave them unchanged;
  `DEVELOPMENT.md` owns the commands they run.
- This changelog.

### Changed

- Substantive development updates, reviews, questions, and decision packets now
  lead with `Concept` and then `Technical depth`; short acknowledgements and
  compact status notifications remain exempt.
- Future milestones now use `<name>.md`, `<name>-technical.md`, and
  `<name>-gate.md`. Acceptance and closure bind the concept envelope, technical
  envelope, and immutable gate digest as one milestone commitment.
- Vision changes now require an explicit request naming either member of the
  vision pair; the authorization and decision duties apply to both files.
- Commit titles now carry a milestone marker: `area(marker): summary`, with
  marker `planning`, `seed`, or a milestone name. Commits at or before
  `f19d2a6` predate the convention.
- The content-origin attribution ban is now enforced by a repository check rather than only
  by `.claude/hooks/guard-bash.sh`, which left Codex and CI uncovered.
- Milestone closure now explicitly includes updating the documentation set.
- Accepted and Closed register transitions now require immutable governance
  records binding the explicit authority disposition, candidate SHA, Concept
  envelope digest, Technical-depth envelope digest, and gate digest; the check
  requires candidates to remain reachable, anchors each completed row plus both
  accepted envelopes and gate bytes across all history reachable from `HEAD`,
  and verifies canonical UTF-8/LF gate text, while a separate independent
  exact-diff review proves the later administrative transition changed only its
  governance row and marked status blocks.
- Accepted plan candidates now bind exact marked Concept and Technical depth
  envelopes plus the gate digest. Structural validation rejects missing,
  reordered, or changed commitments and history rewrites while leaving
  conforming workstream, progress, outcome-state, and evidence-link updates
  outside the locks.
- `docs/adr/0005-milestone-supersession.md` (Proposed, parked) and its technical
  companion — a `Superseded` terminal lifecycle state. An accepted milestone
  found defective keeps its plan pair, gate, and governance rows exactly as
  accepted, and correction is a successor milestone opened gate-first, reviewed
  at its exact candidate SHA, and accepted binding it. No new binding, identity,
  or chain semantics are introduced, because the existing two-phase acceptance
  path already has the properties an amendment chain could not obtain.
  Supersession is not a standalone act: a milestone becomes `Superseded` only in
  the revision that opens its successor, and that successor can never be
  withdrawn from the register afterwards, so a superseded milestone can never be
  stranded without one. Eligibility is judged against every parent of the
  superseding revision, so a merge cannot launder a `Closed` or `Open` state by
  pairing it with an eligible one. Only a milestone with a completed acceptance record may be superseded,
  and never one that has closed. The successor's anchored `## Supersedes` row
  carries the maintainer authority, its durable evidence, and the reason, so the
  relationship cannot be retargeted or reworded afterwards. Parked before
  acceptance: the defect that motivated it was an acceptance recorded on an
  unmerged branch, so nothing was integrated and no correction mechanism was
  needed — the branch was abandoned and the milestone reopened from `main`. Both
  0004 and 0005 become relevant the first time such a defect is found after
  integration.
- `docs/adr/0004-plan-amendment-supersession.md` (Proposed, parked) and its
  companion — the in-place amendment approach, retained as the record of a
  rejected design. Five revisions were rejected in independent review, which
  successively removed a derived classifier that could disguise a weakening,
  fixed a transition that could execute only once, replaced graph-derived
  identity a merge could switch, and universally quantified a binding rule that
  had been existential. The final formal review identified the remaining defect
  as structural: content identity is required because commit identity is
  defeated by re-parenting, commit identity is required because exact-SHA review
  does not transfer, and a single-commit amendment cannot record its own SHA.
  Parked rather than withdrawn because its correction granularity remains better
  than supersession's.
- `scripts/check-bootstrap.sh` drops the benign macOS `DARWIN_USER_TEMP_DIR`
  git warning that a restricted sandbox emits once per git process. It appeared
  132 times in a review run and buried the output a reviewer must read. Only
  that exact line is filtered; every other stderr line and each check's exit
  status are preserved, verified against both a green run and a forced failure.
- `scripts/check-commit-messages.sh` reads the whole range in one `git log`
  instead of two calls per commit, cutting its git process count from 76 to 6,
  with a completeness guard that fails closed if the stream is short.
- Read-only review-lane evidence in `docs/developer/agent-adapter-smoke.md`.
  Four consecutive reviews had run workspace-write and were advisory rather than
  formal evidence; the enforced lane is now proven with a positive smoke and a
  negative smoke in which a write is rejected by the sandbox rather than
  declined by the agent.
- The ADR index recorded 0001 through 0003 as Proposed after they were accepted.
  The acceptance transition may change only governance rows and marked status
  blocks, so the index correction lands separately here. The index also claimed
  `Rejected` and `Superseded` were valid ADR statuses; the check accepts only
  `Proposed` and `Accepted`, and a decision is replaced additively by a
  successor declaring `Supersedes: NNNN`.
- ADR 0001, ADR 0002, and ADR 0003 are **Accepted**, bound to candidate
  `c703a65` with concept and technical digests recorded in each governance row.
  The maintainer's disposition is retained in the context map under
  Retained Authority Dispositions, written before the administrative transition
  so the pointer resolves to integrated bytes. The transition changed nine
  lines — three statuses, three governance rows, three derived capsule fields —
  and was independently reviewed before integration.
- M0 is no longer blocked on decisions. The derived status capsule now reports
  that M0 has not been explicitly opened gate-first, and the next maintainer
  decision is to open or defer it.
- ADR 0002 names two events that trigger its amendment: publishing
  any package, which declares a language requirement to consumers, and retaining
  a prebuilt extension artifact, whose declared build toolchain is verified
  against the running runtime before activation. Validated pairs therefore bound
  what may be built and loaded, not only what this repository tests.
- Proposed ADR 0001 and ADR 0002 now carry empty governance records. The seed
  checker requires both exact records to be accepted before `M0` can leave
  Blocked and keeps the seed guard fail-closed until the opening branch installs
  lifecycle-specific status checks.
- **Vocabulary defined without freezing the roadmap.** A capability rung is a
  non-normative question; a milestone is one bounded plan/gate/closure that may
  serve part or all of one or more rungs; a workstream is an internal parallel
  slice; and a release remains separately authorized.
- Plans now carry scope-specific minimalism budgets. Raw line count remains a
  review signal rather than a universal gate; every abstraction must name the
  concrete examples or current implementations it serves, and test code counts
  as system cost without making required evidence optional.
- Milestone files are three flat documents: `docs/plans/<name>.md`,
  `<name>-technical.md`, and `<name>-gate.md`. The concept and technical
  envelopes are accepted together; the gate stays separate because its bytes
  are executable and immutable. Evidence links stay in mutable progress or in
  gate-defined artifacts rather than an extra lifecycle sidecar.
- ADR 0001 no longer conditions its own acceptance on a scaffold commit that
  cannot exist until an accepted gate authorizes it, and now requires
  `apps/loopex` to carry zero dependencies — including dev and test tooling,
  while repository/development checks use standard Elixir/OTP/Mix only by M0
  closure; accepted adapter runtime dependencies remain separate. A separately
  accepted project-wide tool would live at the umbrella root.
- Proposed ADR 0001 requires the first accepted scaffold to create a
  repository-owned dependency-budget/direction command and adversarial fixture;
  the current Claude hook remains early feedback until then.
- The roadmap's M0 candidate proof now uses operation truth across a restart,
  not two nodes, and limits VM-code work to a feasibility spike with no
  extension-activation claim. The public-protocol release-candidate decision
  now follows activation proof. All three changes repair the vision's serial
  barriers.
- `DEVELOPMENT.md` and the context map now describe all five aggregate checks and
  no longer advertise `mix test` before a Mix project exists.
- `AGENTS.md` now names where sequence authority lives — the vision pair for
  capability prerequisites, rejoin, compatibility, and freezes, and
  § Milestones and Gates for a milestone's lifecycle.
- Vision edits now require an explicit current maintainer or developer request;
  broad documentation or implementation scope no longer implies permission to
  change the founding authority.
- The status check verifies that the complete rejoin-order fence in the roadmap
  matches the unique source fence inside the vision, rather than comparing a
  loose line range.
- While M0 remains blocked with no active milestone, the status check derives
  the complete authority-bearing seed capsule from the two founding ADR
  records, including the partial-acceptance and accepted-but-not-open postures;
  synchronized phase or authorization drift cannot pass merely because the
  table shape and README agree.
- Isolated Codex 0.147 smokes now pair `--ignore-user-config` with trust scoped
  to the exact checkout. They establish project instruction and direct skill
  discovery; the current exact-source named-role attempt could not bind a child
  and is unavailable evidence, not a role-loading pass. Earlier no-trust runs
  cannot establish project profile or skill loading because that flag also
  removes persisted project trust.
- Landed work leaves no branch or worktree residue after integration.
- Detached exact-SHA checkouts are no longer mistaken for merged local branches
  by the repository-hygiene check.
- Development reports state decisions, not incidental discoveries: resolve a finding in
  scope, fold it into a decision packet, or leave it out.
- Python 3.11 and `jq` are explicitly temporary seed/M0 bridges. Before M0
  closes, checks and tested client-hook paths migrate to the accepted Elixir/OTP
  toolchain and prove behavior with `jq` absent, so the enduring development
  baseline is Git, shell/POSIX tools, and Elixir/OTP. The register now records
  why that migration belongs to M0 — self-hosting the checks exercises ADR 0001
  boundaries and ADR 0002 version pairs, making it evidence rather than
  incidental tooling — and constrains it to a separate workstream whose
  minimalism budget requires the replacement to be materially smaller than the
  bridge it retires and to name what it drops.
- M0 also installs the repository-owned compiled-documentation check for the
  dual-depth public-code contract; semantic usefulness and proportional private
  comments remain review obligations.
- Active Markdown under `docs/` now defaults to a Concept/Technical-depth pair.
  The status check requires every pair in the documentation index and resolves
  visible local Markdown paths and explicit fragments; reserved runbook,
  generated, evidence, schema, fixture, and archive paths remain unpaired.
- Portable enforcement and toolchain coverage now live in repository-owned
  local commands; hosted CI may mirror them but remains supplementary for
  development and cannot become the project's only evidence path.

### Removed

- The paraphrase of the vision's serial barriers in `docs/roadmap.md`. Restating
  a normative constraint inside a document that declares itself non-normative
  makes the restatement read as authority while answering to nothing. The
  verbatim quotation stays and is now checked against its source.
- The duplicated milestone ladder in `README.md`. It restated `docs/roadmap.md`
  and had already drifted from it; the README now points at the roadmap and the
  canonical plans status register.

## Seed bootstrap — closed 2026-08-15

Founding documents, the tool-neutral development contract, portable bootstrap
enforcement, and tested Claude Code and Codex adapters. No product code.
Evidence is retained in
[docs/developer/agent-adapter-smoke.md](docs/developer/agent-adapter-smoke.md).
