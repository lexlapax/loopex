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
- The locked current toolchain pair was wrong. ADR 0002 requires the newest
  released Elixir with its newest supported OTP; the gate had locked Elixir
  1.19.5 with OTP 28.1, which is what happened to be installed. Verified against
  the official compatibility table: Elixir 1.20.3 is current and 1.20 supports
  OTP 27-29, so the pair is now Elixir 1.20.3 with OTP 29.0.5. The floor pair
  moved from a chosen 1.17.3/26.2.5 to the derived 1.17.0/26.0, because the
  accepted rule says lowest supported and the table offers no patch selector.
- Negative-demonstration sections must be unique per outcome. Scoping fields by
  section fixed the global-count defect, but duplicate sections concatenated, so
  a populated one could cover a placeholder one.
- Detection replaced by containment where it was available: the full suite runs
  with `LOOPEX_PROVIDER_API_KEY` unset, so an untagged provider-calling test
  added anywhere cannot reach a provider, and hook registrations in
  `.claude/settings.json` are checked because a hook that still blocks is
  worthless if the client no longer invokes it. Formatter coverage must sit
  inside the `inputs` list, evidence fields must appear exactly once, and the
  bypass scan covers quoted, `exec`-, `command`-, and assignment-prefixed
  absolute invocations, with the runner excluded from its own scan since its
  digest catches drift there.
- The provider credential is removed from the environment for the whole run and
  handed only to the explicit real-provider command. Unsetting it just before
  the full suite left every earlier selector, task, and compile step holding it.
- Inherited `TMPDIR`, `MIX_HOME`, and `HEX_HOME` are validated before anything
  is allocated: pointing any of them inside the protected state directory would
  have placed the isolated root, or Mix's own writes, inside the directory the
  relocation exists to protect.
- Hook registration and formatter scope became Mix obligations rather than text
  searches. Independent greps passed with two hooks swapped between event
  blocks, and an unrelated binding containing an apps glob satisfied the
  formatter check while the effective configuration was root-only. Neither can
  stay in shell, because `jq` and `python3` are gone by outcome 8.
- Real user state is contained rather than detected. `HOME` is relocated into
  the isolated root, so a helper reaching for the real state directory resolves
  inside that root and finds nothing — the fail-before-touch property the
  contract requires. The cold-cache cost is avoided by pointing `MIX_HOME` and
  `HEX_HOME` at their persistent locations, verified to reuse them with nothing
  written to the relocated home. The before-and-after fingerprint stays as
  defense in depth and carries no claim of its own.
- The isolation fix from the previous round broke the mandatory read-only review
  lane: the runner created its temporary root before the non-writing scaffold
  check, so an enforced read-only reviewer failed on unavailable temporary
  storage instead of reaching the declared red condition. Every check that only
  reads the checkout now runs first, verified by running the gate in that lane.
- Artifact binding now propagates along parent edges and is reconciled at merges
  rather than tracked in one global set, and persistence covers the gate file,
  the declaration, and each individual bound row. Deleting the gate, removing
  the section, or dropping a single row while mutating that artifact are each
  rejected, including through a merge whose other parent is clean.
- The provider exclusion proof requires the provider file to execute no tests
  unfiltered, rather than merely reporting some exclusion, which an unrelated
  tag could have supplied while the provider test still ran.
- Hooks are executed as configured executables rather than through `bash`, so a
  lost execute bit or broken shebang is caught, and must exit exactly 2, which
  is the only status the client treats as blocking.
- The absolute-invocation scan covers any absolute path, `env` with flags and
  assignments, `command -p` and `-pv`, and assignment-prefixed runs.
- `HOME` is relocated into the isolated root while `MIX_HOME` and `HEX_HOME` stay
  persistent, so Mix keeps its caches without the run being able to reach real
  user state. The before-and-after fingerprint is defense in depth only.
- The credential is contained rather than merely unset: the runner disables
  `allexport`, holds the value in an explicitly non-exported variable, and then
  proves neither `LOOPEX_PROVIDER_API_KEY` nor the holding variable appears in a
  child process environment. An inherited export would otherwise have handed the
  value to every Mix process the run starts.
- Inherited-root refusal compares physical paths, so `..`, a relative path, and
  a symlink can no longer alias `TMPDIR`, `MIX_HOME`, or `HEX_HOME` past the
  check. Symlinks are followed before any walk up the path, including one whose
  target does not exist yet: a link aimed at a protected directory that has not
  been created would otherwise have been walked past and the alias lost.
- Both Mix obligations introduced for hook registration and formatter scope
  carry protected selectors with locked names, so neither can be a successful
  no-op, and `.claude/hooks/deps-budget.sh` is checked for its execute bit —
  without it the hook exits 126 and the `|| exit 2` around it reads as a block.
- Credential containment moved ahead of the runner's first child process, which
  is the `git rev-parse` that locates the repository root, not the first Mix
  command. Scrubbing after any child had already handed the value to every
  process started before it, and the assertion that followed could not detect
  that it had.
- Path resolution became component-wise against an already-physical prefix.
  Resolving the assembled string at the end could not work: `cd` without `-P`
  collapses `..` lexically, so an existing symlink such as
  `~/.swiftpm/cache/../../../.loopex` was reduced by text before the kernel saw
  it, the intermediate link was discarded, and a `MIX_HOME` that really did
  target protected state was admitted.
- The shadow-bypass scan covers the whole tracked tree rather than a list of
  top-level directories, since an absolute invocation in a directory nobody
  thought to add would evade both the stub and the scan. Quoted absolute forms
  are matched, and a `PATH` assignment that discards the existing value is
  rejected on its own line, because replacing `PATH` defeats the stubs whether
  or not the interpreter is named nearby.
- The scan distinguishes `git grep` exit 1 from exit 128, so a broken
  invocation or unreadable object is unavailable evidence rather than a pass.
- A populated evidence field must contain an alphanumeric character. Rejecting
  only the template's em dash left `-` and `?` reading as filled.
- The read-only ordering claim is corrected to what the runner guarantees:
  everything before the first allocation is checkout-only, so the review lane
  reaches the declared red condition. Checkout-only checks also appear after
  allocation, beside the outcome they belong to.
- Path containment now compares device and inode across every prefix of a
  candidate, and folds case, because resolved text alone is not enough on a real
  macOS host: the data volume carries a firmlink to the user's home sharing its
  device and inode, and the default filesystem is case-insensitive, so an
  uppercase spelling named the same directory. The resolver's budget counts
  symlink expansions rather than components, since a path padded with dot
  segments exhausted it and the resolver then returned a partial prefix that
  compared as outside; an exhausted budget and an unresolvable path are now both
  refused.
- Prose is no longer excluded from the interpreter scan. Excluding by file type
  was unsafe, since a non-executable file is still executable as an argument to
  a shell or by being sourced, and the execute-bit assertion guarding the
  exclusion could not see that. The documents describing these forms avoid
  spelling them literally instead.
- The interpreter stub set covers a fixed core plus every python-like name
  reachable on the current search path, and each stub is proved effective rather
  than only the first. Stubbing two names left `python`, versioned interpreters,
  and Xcode's toolchain wrapper all usable.
- Any assignment to the search-path variable outside the runner is rejected
  outright. Requiring the value to carry the old one forward failed in both
  directions: prepending a real interpreter directory preserves the variable and
  defeats the stub, and a substring removal deletes the stub root while still
  naming it.
- Provider-lane diagnostics are redacted before printing. The lane captures
  stdout and stderr together, so a provider or test echoing the key into an
  error would have put it straight into operator and CI output.
- `AGENTS.md` joins the closure document set, since outcome 8 makes its
  bootstrap-prerequisite text stale.
- Formatter coverage must appear outside a comment; evidence fields reject
  whitespace-only content; bare outcome headings are counted consistently; and
  the gate now states the evidence field names, hook exit semantics, and
  dependency-hook requirements the runner enforces.
- Six bounded corrections inside that boundary: a named hook that disappears now
  fails rather than skipping its check, since removing a tested hook is
  behaviour loss ADR 0002 permits only by disposition; retained inline budget
  logic is rejected again; the history-preservation cases are executed tests
  with locked names rather than files that merely exist; negative-demonstration
  fields are counted inside each outcome section instead of globally; the
  self-hosting baseline is corrected from a stale 3,990 to the measured 4,313
  lines, and later re-measured at 4,462 as the checker grew; the toolchain pins
  are derived from accepted ADR 0002 rather than
  chosen, so the floor is the lowest supported pair in the 1.17 family; and the
  executed-test arithmetic subtracts skipped tests only, since
  ExUnit reports excluded ones outside its total and subtracting them again
  would have falsely rejected a file holding both tagged and ordinary tests.
- The M0 gate stopped trying to defeat a dishonest implementer. Five review
  rounds found a bypass for every mechanical anti-faking control, because a
  script cannot tell whether a test asserts anything, whether a fixture is real,
  or whether a report is truthful. The runner now defends against accident and
  drift — a command that stops passing, a protected test renamed or skipped, a
  dependency creeping back, an evidence record never filled in — and the gate
  assigns the remaining judgments explicitly to independent review of the
  implementation at closure.
- Real defects fixed in the same pass: the provider lane subtracts skipped tests
  like every other selector; the compiled-documentation check the
  development contract requires at M0 is restored as outcome 10; the absence
  scan covers `apps/**` where the replacement lives; evidence records must be
  populated rather than merely present; each named hook is executed against its
  own fixture; the replacement must carry mutation-restore, merge-divergence,
  and missing-artifact fixtures so retiring the checker does not drop the
  history guarantee; and the plan's stale "two dependency-free applications"
  wording and workstream A rejoin barrier are corrected.
- Bound artifacts are anchored across reachable history, not only the current
  tree. A commit could previously change the runner and a later commit restore
  it with final validation passing; merge divergence had the same shape. Every
  reachable revision must now match the digest its gate declares there. Proved
  in an isolated clone and covered by mutate-restore, merge-divergence, and
  missing-artifact tests.
- The M0 gate was rejected and hardened again: provider evidence moved to
  `docs/evidence/` because any `docs/plans/*.md` is read as another milestone and
  broke the aggregate; outcome 1 now says "no external dependencies" and
  preserves the `:loopex_protocol` edge that ADR 0001 requires; ADR 0001's
  mandatory proofs are locked as outcome 9 and additional named tests; skipped
  tests no longer satisfy an executed-test minimum, since ExUnit counts them in
  its total; `command -p` and inline-`PATH` bypasses of the absence proof are
  scanned for; hook behavior is proved by executing locked fixtures rather than
  by a task exit code; negative demonstrations are a required record; and the
  provider lane moved to the adapter application, since `apps/loopex` may carry
  no external dependency.
- Milestone `M0` is **Open** on its branch, with the plan pair and locked gate
  in `docs/plans/` and `scripts/check-m0-gate.sh` as its runner. Ten outcomes
  cover the scaffold, the toolchain matrix, journal replay, `commit_unknown`
  fencing and reconciliation across a restart, the isolated VM code-load and
  rollback spike, one real-provider slice, the self-hosting migration, and the
  compiled-documentation check.
- Every gate command form was executed against a disposable umbrella scaffold
  before the gate was written. That check exists because an earlier version
  locked repository-root test paths: an umbrella root runs no tests of its own,
  so `mix test test/x_test.exs` produced no output and exited zero, leaving four
  outcomes permanently unprovable. Selectors are now application-relative, and
  the tagged provider lane is path-scoped because `mix test --only <tag>` at the
  root recurses into applications with no tagged tests and exits zero having run
  nothing.
- The gate binds its own runner and `.tool-versions` by SHA-256, verified by the
  status check at every validation, so replacing the runner with a command that
  exits zero fails immediately. Verified by tampering with both.
- The seed-specific status guard is replaced by lifecycle enforcement: every
  registered state derives its exact status capsule, and a state without a
  derivation fails closed.
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
