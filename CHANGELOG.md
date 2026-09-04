# Changelog

All notable changes to Loopex are recorded here. The format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and versions follow
semantic versioning under the
[0.x compatibility policy](docs/vision.md#concept-vision-compatibility). That
policy labels public surfaces stable, release-candidate, or experimental once
there are public surfaces to label. Nothing is labelled yet — see
[compatibility surfaces](docs/developer/compatibility-surfaces.md#concept).

Nothing is released or installable yet. Entries below the first release record
repository, planning, and milestone implementation work, and carry no
compatibility meaning: M0's product code is disposable experiment and scaffold,
and no public surface is labelled.

Updating this file is part of a milestone closure candidate, not an optional
courtesy — see [AGENTS.md](AGENTS.md) § Milestones and Gates. Each gate locks
the exact document set its milestone must update.

## [Unreleased]

### Planned

- `M3`, kernel consolidation, is Open: its plan pair and red gate exist and
  await maintainer acceptance. It adds no operator capability and no public
  surface. It locks in a gate the seventy-three regression cases the
  post-closure override sets produced, implements ADR 0017 evaluation step 5,
  moves the event dispatcher off synchronous Store reads inside its own call
  handler, bounds spent provider-attempt retention, makes a repository-owned
  aggregate run every Closed gate with its own invocation structurally
  verified, repairs the test-honesty weaknesses two independent reviews froze,
  and raises the bootstrap runtime floor by amendment to ADR 0002.
- The headless stdio JSONL app-server milestone drafted on this branch is now
  `M4` rather than `M3`. Its plan pair and gate are retained unopened in
  the [retained `M4` draft](docs/archive/M4.md), its proposed decisions were renumbered
  to ADR 0019 and ADR 0020, and the projected `0.1.0` tag moves with it to the
  end of that milestone.

### Added

- `loopex`, a command an operator runs from their own terminal. `run` submits a
  prompt into a durable session and prints the answer as the model writes it;
  `--steer` joins the run already going and `--follow-up` queues the next one;
  `sessions` lists the sessions in a state root and `resume` continues one;
  `cancel` reconciles a session a dead process left behind; `artifact` reads back
  a spilled tool output. Argument parsing and terminal output use the standard
  library only, and the command drives only the public facade: it owns no loop,
  no durable session truth, no cursor truth, no store access, and no authority
  decision.
- A real agent loop. A prompt runs until the model stops asking for tools rather
  than for a fixed number of turns, every request carries the committed
  conversation including the original prompt and the real result of every tool
  that ran, and three declared bounds — maximum turns, cumulative token budget,
  and a committed absolute deadline — end a run truthfully rather than silently.
- Streaming, as transient progress rather than durable truth. The shipped model
  adapter emits an answer as the provider produces it and the terminal prints it
  as it arrives, while the committed assistant message is built from the
  adapter's return value and never assembled from what was displayed. Model and
  executor progress are separate gapless sequences within one stream domain,
  each closed by its own content-free item carrying its total, so a coalesced,
  dropped, or truncated tail is detectable rather than silent — and a missing
  closure sends a consumer to the durable record instead of a timer. A closure
  is emitted only while its process-local owner can state it truthfully: abrupt
  owner death and executor owner loss without a retained terminal fact end that
  plane without inventing abandonment, and recovery uses the durable operation
  record. An adapter that does not stream is equally conformant and says so.
- Four coding tools against a real workspace: `read`, `write`, `edit`, and
  `bash`, sharing one conformance suite for bounded output, workspace-root
  resolution, symlink and traversal containment, exact edit preconditions, and
  ownership and termination of the child process group a job's captured kill
  identity names.
- A `Loopex.Policy` port that replaces M1's literal allow term. Every
  executor-backed tool call including a read-only one requires a host decision;
  a denial issues no grant, starts no process, and commits a truthful denied
  outcome the operator reads; failure, timeout, and a malformed response fail
  closed into denial. Omitting the `:policy` start option refuses runtime start,
  and each shipped permissive policy says out loud what it is. `--policy`
  selects between `allow-all`, which permits everything and says so, and
  `shell-allowlist`, which permits the filesystem tools and only the shell
  commands it names, refusing the rest while the run carries on. The second is
  scope and not a sandbox: it matches a command's leading word, a compound
  command reaches past it, and it says that in its own notice.
- An `ArtifactStore` port and local adapter. Tool output beyond a declared bound
  spills rather than poisoning the conversation: Core derives an immutable
  object identity from the exact bytes and a separate immutable use identity
  from the closed retention provenance, the adapter durably publishes object
  then use before reporting success, and the compact eight-member reference
  carries both identities without exposing that private provenance. The
  model-facing result stays bounded and says what was truncated; the operator
  retrieves byte-exact content by opaque object locator through validated
  `stat` and `fetch`, while authorized runtime code resolves the use through
  `describe`.
- Cancellation that reports what happened. One positive cleanup period is
  committed with the session and drives executor observation, receipt
  retention, terminal reserve, command liveness, and prepared recovery without
  substituting a later process default. An interrupt uses the public facade and
  a prepared attachment whose one-use activation capability remains paused
  until configuration is reconciled. `cancelled` commits only where every owned
  operation reached a validated terminal fact and every captured executor
  process group associated with those operations was confirmed quiescent;
  anything less ends `outcome_unknown` carrying its
  reconciliation reference. The local executor admits effects under one
  prepared, fenced ledger generation and quarantines unresolved authority
  across restart; its trusted-root and host-rollback limits are recorded rather
  than presented as exactly-once behavior outside that boundary.
- A session directory. A fresh operating-system process lists the sessions in a
  state root resolved from `LOOPEX_HOME`, resumes one under the durable runtime
  placement identity that created it, and refuses a resume through a different
  identity with an explicit reason.
- Behaviour-shaping project resources enter the model's context only by an
  operator's explicit decision, and a run without one fails closed toward
  withholding the content rather than toward refusing the runtime.
- Context admission measures the exact final provider-visible messages and
  active model-facing tool projections separately from the exact normalized
  Store record. The direct runtime host commits a positive context-token budget;
  the reference composition and command resolve their documented default, and
  recovery reuses retained truth rather than the current process default.
- Provider attempts consume one durable permit before dispatch. Every admitted
  terminal answer settles that permit with bounded provider-neutral identity,
  usage, and classification; incomplete usage charges the committed remaining
  allowance, post-effect uncertainty stops the run, and recovery never invents
  a second billable attempt or a clean answer from silence.
- Public event delivery is fenced by resolution as well as by commit. An
  attached reader is handed rows only up to the position the runtime has
  acknowledged as resolved, so a durably linearized row whose owner still holds
  an unresolved transaction stays invisible until re-presentation settles it.
  Cursors and gap semantics are unchanged; the fence delays a read rather than
  reordering or dropping one, and it lifts when the runtime stops owning the
  session.
- `loopex_composition`, a shipped reference stack an embedder depends on rather
  than copies: one module under a one-hundred-eighty-effective-line ceiling that starts the
  application tree and a runtime, names the concrete Store, Model, Executor, and
  ArtifactStore, resolves its state root explicitly, and refuses to start unless
  the host supplies the policy that governs the run.
- Operator and developer documentation for the command, the tools and the
  authority in front of them, the loop and its contracts, and every surface M2
  touches — all unstable, none labelled or frozen. An M1-era session data root is
  not readable by M2.

- The M1 single-machine working loop: explicit supervised runtime references,
  Store-backed session creation and owner succession, one serial active run,
  committed canonical model requests, host-granted controlled effects, durable
  public events, and a direct embedded API.
- A durable local Store edge with reusable ADR 0006 conformance, transaction
  resolution, owner/version fencing, consecutive journal and outbox positions,
  replay, torn-tail repair, corruption visibility, and deliberate stale-writer
  recovery after the prior runtime tree is known dead.
- Provider-neutral Model and Executor behaviours. The ReqLLM edge maps canonical
  committed requests and provider-supported forced tool selection; the
  trusted-local executor independently validates the complete ADR 0007 grant and
  JobRequest binding, holds a workspace lease, starts a fixed OS tool with only
  `PATH`, and durably retains a terminal receipt.
- A thin reference client and two-process recovery demonstration. The real
  Anthropic trace kills the first BEAM process with `SIGKILL` after executor
  receipt retention but before the session fact, resumes under fresh ownership,
  reconciles the retained receipt without redispatch, preserves acknowledged
  events, completes a second real model call, and reaches a durable terminal
  result. Missing receipt evidence ends `outcome_unknown` and never retries.
- Operator and developer guides for the M1 source-tree runtime, including
  the explicit feature boundary, credential-free and real-provider working-loop
  commands, composition, credential boundaries, event truth, shutdown, and
  crash recovery. M1 remains unreleased and carries no public compatibility
  freeze.
- First product code. An Elixir umbrella with two applications per ADR 0001:
  `loopex_protocol` carries no dependency and `loopex` depends on it and nothing
  else. Both read one version from the root `VERSION` file at compile time, so
  drift is prevented by construction rather than detected.
- Repository checks became Mix tasks: dependency budget and direction, version
  train, formatter scope, toolchain matrix, core-only lane, compiled-documentation
  check, hook registration, and self-hosting measurement. Each keeps its logic in
  a function a test can call directly rather than behind the task's `run/1`, so a
  test exercises the real code path. How much of that is locked varies: dependency
  budget, core-only and hook registration are driven by protected selectors;
  toolchain matrix and compiled documentation are covered by tests that are not
  protected selectors; version train and self-hosting measurement have no test and
  rest on the gate running the command. That spread is stated rather than implied
  by "each", which read as uniform coverage the gate does not lock.
- Durable-truth experiments for M0's constitutional core. A session journal
  replays across an induced restart, checked by properties over generated
  histories against an independent model, by process kills at every durable
  transition, and by truncation at every byte offset with the intact-record count
  derived from the frame layout. An effect committed with an unknown outcome is
  fenced: a counting collector proves exactly one dispatch ever carried it across
  both coordinator incarnations, and the fence refuses dispatch, publication, and
  acknowledgement without lifting across a restart.
- A trusted code generation loads and rolls back in an isolated VM. Artifacts are
  built inert with `:compile.forms/2` so nothing loads into the manager VM, and
  absence in the test VM is proved two ways. This claims nothing about quiescent
  activation or extension semantics.
- The ReqLLM reference model adapter and its explicitly invoked lane. The tagged
  lane is excluded by default so the full suite cannot reach a provider, and it
  fails as evidence unavailable rather than skipping when the credential is
  absent.
- Repository validation now runs on Elixir. `check_status.py`,
  `test_check_status.py`, and `check-agent-bootstrap.py` are retired and no hook
  invokes `jq`, so the seed's two bridge prerequisites disappear. The replacement is
  larger than the bridge and names the eight behaviours it dropped; both the
  measurement and the list are produced by `mix loopex.self_hosting` and recorded
  with the milestone's evidence as audit material, not as a pass condition.

### Fixed

- A completed run could not be resumed or cancelled from a fresh process. The
  store's writer marker survives its holder's death by design, and every later
  `resume` or `cancel` was refused by a marker the previous run left behind. The
  marker now records its holder's operating-system pid and start identity
  (`loopex_store_writer_v2`), and a recovery request is honoured only once the
  operating system says that holder is gone: a live holder is refused whoever
  asks, so a fresh command can no longer evict an embedded runtime that never
  held the command's placement lock; a marker carrying no identity, including
  one written by an earlier version, is never recovered automatically. The store
  also releases the marker on an orderly stop. `resume` installs its interrupt
  owner before it spends the activation, so a signal landing in that window
  submits the ordinary abort instead of stopping the process with recovered
  work live.
- Prepared recovery kept its one-use capability with the process that prepared
  the owner, so the acknowledged holder transfer ADR 0016 requires did not
  exist and a preparer's death left nothing any process could present. The
  interrupt handler's own process is now the capability's acknowledged holder
  from installation: activation and abandonment go through it
  (`activate_prepared/1`, `abandon_prepared/1`; `abandon_resume/2` is removed),
  a signal's abort and the command's activation serialize inside one process,
  and a preparer that dies after the acknowledgement leaves a live holder. The
  facade gains `transfer_resume/2`, which only the current holder may call.
- The coordinator waited for a cancelled job's own answer inside its own
  message loop, so a status read or a command queued behind that reserve for up
  to the whole derived window. The reserve is now a timer the coordinator
  answers around. Every timer derived from an admitted period or deadline is
  armed in slices below the VM's ceiling against one absolute instant, so the
  largest admitted cleanup period and a near-maximum run deadline no longer
  crash the coordinator after a provider dispatch; the run deadline's domain is
  now the same positive unsigned 64-bit range as the cleanup period, refused at
  declaration and at admission before anything durable is written, and an
  over-domain cleanup period is refused at runtime start and at session
  creation rather than committed into a genesis no owner can recover.
- Command identifiers were a per-process counter, so a second `loopex` process
  against the same state root replayed the first one's identifiers and was
  refused as a conflict. They are now random.
- A second interrupt during an admitted stop orphaned a signal-ignoring tool
  child and ended the process with no terminal recorded. The launcher now waits
  through interrupted waits while its child is alive, and the backstop kills
  every process group this run owns before it halts and says so. `run` sizes
  that backstop from the session's committed cleanup period, as `resume` already
  did, so a run whose period exceeds ten seconds can still report `cancelled`.
- A session whose process was killed mid-command resumed into a run nothing
  would settle, and the terminal waited on its idle limit. The executor port
  gains an optional `retained_receipt/2`; at activation of a prepared resume the
  coordinator asks for the retained receipt, validates it exactly as it
  validates a host's, and settles the run as completed or `outcome_unknown`. An
  executor that cannot say leaves reconciliation host-driven.
- The local executor decided a cancellation from process-local state, so an
  instance with no record of a job open on its own root reported it cleaned;
  absence is now decided from the shared root and answers `unconfirmed`, and so
  does an identity the root has never admitted. Every cleanup window derives
  from the period the job committed rather than the executor's start default.
  The open entry's disposition is now decided under the root claim before the
  receipt is published, so no reader ever sees a confirmed receipt that later
  reverses to `outcome_unknown`; a removal that fails or runs past the
  settlement allowance publishes the quarantined form instead. Open-entry
  removal shares the settlement allowance with every other retention phase; a
  root claim the ledger could not release is reported to the caller rather than
  swallowed; every level of a ledger directory is synced into its own parent;
  the open record is published before the marker so an interrupted admission
  fails closed; and every executor wait derived from an admitted period is
  sliced below the VM's timer ceiling. One residual is stated rather than
  hidden: a removal that succeeds followed by a receipt that cannot be retained
  leaves the root without its standing quarantine; the caller receives
  `{:receipt_not_retained, reason}` and a later reader gets `:absent`.
- Mint 1.9.3 carried two published HTTP/1 advisories (an unbounded status-line
  and chunk-extension buffer, and a quadratic chunk-size parser) reachable
  through the shipped provider chain; it is raised to 1.10.0.
- A completed create replayed into a restarted runtime started a new owner
  generation; a replay now answers from the durable result and starts nothing.
  Store items are measured without encoding them first, so an oversized binary
  is refused without an allocated copy. Adapter replies are admitted against
  plain-data, depth, member, and byte ceilings before any projection, so a reply
  with a million tool calls, a thousand calls each carrying a megabyte, or a
  ten-thousand-level nesting is refused as unreadable in bounded time. The
  one-use provider permit is authorized only where the binding equals the one
  rebuilt from the committed attempt-open row at that journal position, so a
  fabricated first binding is refused rather than recorded. Settlement validation
  computes the single admissible combination for each cell of the ADR 0018 table
  rather than refusing an enumerated list.
- An artifact use's `uses/<xx>` directory entry was never synced, so a crash
  after a successful put could lose the use; every directory a put creates is
  now synced into its parent. Competing publishers of one use were shown to
  write identical bytes by construction, since the sidecar's name is the digest
  of its bytes.

- The durable store followed a path rather than holding a file. A log deleted
  underneath a live session was answered by opening a new, empty one at the same
  name, and the session went on writing into a history that had lost everything
  before it; a removal that raced the open slipped through a check made only
  beforehand. The store now records the log's device and inode at start-up and
  re-reads the path once its append handle is held, creates nothing on the
  append path, and reports a log that was removed or replaced as an ambiguous
  commit — which stops the store for recovery and leaves the caller to
  re-present its exact transaction.
- A store that could not be opened or replayed refused in no words. One refusal
  reached an operator as the runtime tuple `{:invalid_history, 0,
  :frame_does_not_match_transition}` — an internal replay audit addressed to
  nobody who could act on it, carrying durable bytes into a terminal on the way.
  Reconciliation now names the session and the class of the failure: its history
  could not be replayed, its store could not be opened or read, or another
  process is already writing that state root. Refusals that already arrived in
  words keep them.
- A failed run reached the terminal as the bare word `failed`. One category was
  projected and every other dropped, so the one ending where the reason is the
  only thing that tells an operator what to do next told them nothing. The
  ending now names the category and whether it is retryable, plus the dimension,
  observation, and limit where a declared ceiling decided it. The projection is
  a fixed whitelist rather than the failure map, so private descriptors and
  provider text still reach no terminal.
- Every provider call was bounded by an undeclared thirty-second transport
  timeout the streaming client applies when a caller supplies none, instead of
  by the run's own committed absolute deadline. Under concurrent load it fired
  with minutes of the declared deadline remaining, and a second occurrence
  exhausted the retry allowance and stopped the run's owner — roughly one run in
  twelve, while runs in isolation were clean. The transport now receives the
  remaining time on the committed deadline, so there is one bound and it is the
  one the run declared. It became visible only because an interrupted stream is
  now an error rather than the partial text already emitted; the same timeout
  previously produced a truncated answer indistinguishable from a short one.
- The core-only lane measured the ambient VM, which made outcomes 7 and 9 appear
  mutually exclusive: at an umbrella root every compiled child is on the load
  path, so any adapter failed the check by existing. That was an instance of the
  anti-pattern the gate names, "root suite standing for core". The lane now runs
  core's own project in a separate VM and asserts core is started, so an empty
  lane cannot satisfy every absence vacuously.
- The dependency budget rejected every adapter `mix.exs` as an unknown
  application, blocking adapter work through the client hook. Per ADR 0003 an
  adapter compiles against the contract, so it may carry the contract plus the
  external dependencies its edge needs and may not carry the runtime.
- The agent bootstrap check scanned the working directory recursively, so a Git
  worktree created under `.claude/` made it read a second copy of the repository
  and fail a commit that was clean from a fresh clone. Its scans read tracked
  files only.
- The documentation check flagged `child_spec/1`, which `use GenServer` injects
  with OTP's own docstring. Entries with no authored source location are excluded;
  an authored omission is still rejected.

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
- The credential reaches the provider lane through a shell assignment prefix
  rather than as an argument to `env`. The argument form placed it in that
  process's argv, readable by any user on the host until `env` replaced itself
  with Mix — a separate exposure that output redaction does not address.
- Identity lookup distinguishes a path that does not exist, which legitimately
  has no identity, from one that exists but cannot be read, which is unavailable
  evidence. The latter now refuses instead of skipping the comparison and
  falling back to text.
- The search-path scan covers every textual mutation, not only assignment:
  `unset`, `printf -v`, an array-element write, a declaration naming the
  variable, and a quoted assignment handed to `env`. The absoluteness claim is
  withdrawn — indirection through a nameref or a computed name leaves no token
  to match, and an allowlist search path cannot close it because `/usr/bin`
  holds both the interpreter and `git`, `sed`, and `awk`. The gate states that
  residual instead of claiming coverage it does not have.
- Interpreter enumeration reads entries with `:` as the only separator, so a
  directory containing a space is no longer split and an empty entry is treated
  as the working directory. The fixed stub core adds the launchers whose names
  are not python-shaped, and the coverage claim is narrowed to that core plus
  python-shaped names rather than every conceivable entrypoint.
- `AGENTS.md` joins the closure document set, since outcome 8 makes its
  bootstrap-prerequisite text stale.
- Formatter coverage must appear outside a comment; evidence fields reject
  whitespace-only content; bare outcome headings are counted consistently; and
  the gate now states the evidence field names, hook exit semantics, and
  dependency-hook requirements the runner enforces.
- Seven bounded corrections inside that boundary: a named hook that disappears now
  fails rather than skipping its check, since removing a tested hook is
  behaviour loss ADR 0002 permits only by disposition; retained inline budget
  logic is rejected again; the history-preservation cases are executed tests
  with locked names rather than files that merely exist; negative-demonstration
  fields are counted inside each outcome section instead of globally; the
  self-hosting baseline is corrected from a stale 3,990 to the measured 4,313
  lines, and later re-measured at 4,462 as the checker grew; the toolchain pins
  are derived from accepted ADR 0002 rather than
  chosen, so the floor is the lowest supported pair in the 1.17 family; and the
  executed-test arithmetic subtracts both skipped and excluded tests from the
  reported total. Amendment 1 asserted the opposite -- that ExUnit reports
  excluded tests outside its total, so subtracting them again would falsely
  reject a file holding both tagged and ordinary tests -- and the floor lane
  disproved it: on 1.17 the total includes both. Amendment 2 corrected the
  arithmetic, Amendment 3 corrected Amendment 2's self-certified acceptance
  heading, and Amendment 5 closed an absence-lane bypass where a `for` or
  `select` loop binding the search-path variable left the lane reporting success.
  Those three amendments had no entry here; this is it. A governed artifact
  carrying a disproved explanation is a defect even when the code below it is
  right, because the comment is what the next reader believes.
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

- The ReqLLM adapter sent only the most recent user message rather than the
  committed conversation. Every test passed, because fixtures read
  `request.messages` directly, while the real path had the model seeing its
  original instruction again on every turn.

- A provider library that crashed inside the streaming call left its error
  uncaught, and the argument list of the frame it crashed on carried the
  credential, so the VM's own crash report could print it. Every raise, throw,
  and exit under that call is now caught and reported as the same bounded
  classification the ordinary failure branches produce. An interrupted stream is
  likewise an error for all three endings rather than only for a raise, so a
  progress function or a lazy stream that threw or exited no longer escapes the
  byte bound, the credential substitution, and the declared return. Reading a
  reply from a stream opened elsewhere now scrubs against the credential this
  adapter would itself call with instead of against nothing, which is what makes
  the scrubbed errors that path documents true for a caller that has one set.
- A model attempt settlement could carry combinations the attempt contract
  excludes, and the run then crashed on history it had accepted rather than
  refusing history it cannot accept. Choosing a retry at the attempt limit is
  refused, so no owner installs permission for an attempt that can never open.
  A reply that carries a termination is admitted only as evidence-only, so a
  late answer is either the conversation or evidence retained beside it and
  never a retained answer the run has no record of having received.
- An abort or a deadline that arrived after this owner opened a model attempt
  and before it asked for the permit that dispatches one settled the attempt as
  possibly dispatched, charging the run's whole remaining token allowance for a
  call nothing could have made. That window settles `not_dispatched` and charges
  nothing. It is claimed only where this owner opened the attempt itself and has
  not yet reached the permit request: an attempt inherited from a dead
  predecessor, and one whose permit request lost its reply, both stay ambiguous
  for the reason they always did.
- Spent provider-attempt identities are released at the one moment a runtime
  stops holding a session, so a host that resumes and finishes many sessions no
  longer keeps one entry per attempt of every session it has finished with.
  Replacing a coordinator or a worker still releases nothing, because a
  successor must go on being refused the identity its predecessor spent. The
  retention that remains is recorded at
  [M2 recorded limitations](docs/evidence/M2-recorded-limitations.md#spent-attempt-retention).
- `Loopex.activate_resume/1` and `Loopex.abandon_resume/1` wait for the
  coordinator's answer rather than expiring after five seconds. The message
  carrying either call is not withdrawn when its caller stops waiting, so an
  expired call could report the session unavailable while the coordinator went
  on to spend the very activation the caller was told it had not got — and a
  prepared owner spends it by starting the recovered run. Neither call proposes
  a durable mutation, so waiting commits nothing, and a coordinator that has
  died still refuses, because its exit is the true answer.
- A deadline admission whose commit was refused or left unknown was discarded,
  and the settlement that followed read an unset termination — selecting a retry
  and a model-call failure for a run that had actually reached its declared
  deadline. A refusal that only says ownership moved now leaves the owner to its
  successor, which rereads the deadline and admits it. Every other refusal makes
  the session unavailable rather than manufacturing the settlement, accounting,
  conversation, or terminal that a commit which did not happen would have
  produced.
- The wait a coordinator spends on an executor result when the committed cleanup
  period cannot be read is derived from the one formula that derives every other
  cleanup bound, applied to the shortest period that formula admits. It was a
  restated literal, so a change to the formula would have moved every production
  wait except that one and nothing would have said so.
- A context refusal on a dimension that withholding optional content cannot cure
  — the strict system-class ceiling, record depth, record cardinality — was
  built from the descriptor set that still included optional project content
  while the four counts it publishes described only the required one, and its
  project disposition claimed the project had never been evaluated. Such a
  refusal is now decided on and built from a required-only candidate before
  anything is retained, so the counts partition the exact sequence behind the
  receipt's ordered descriptor digest and the disposition is true. A staged
  request's source list likewise names the blocks the request actually carries
  rather than the ones its resolution would imply, so a required-only candidate
  measured under an eligible project resolution no longer describes a message it
  does not contain. The residual gap this leaves is recorded at
  [M2 recorded limitations](docs/evidence/M2-recorded-limitations.md#adr-0017-step-five).
- A durable record whose own byte size did not converge to a fixed point
  continued as though it had, staging a request whose receipt stated a byte cost
  of zero. Non-convergence is now the Store-unavailable reason it is, and the
  session becomes unavailable rather than reporting a dimension, terminal, or
  dispatch behind a measurement that was never taken. A record that breaches the
  Store's depth or cardinality still reaches the admission boundary unresolved,
  because that is where it is refused by its exact structural dimension.
- An attaching caller's snapshot scan is fenced by resolution the way delivery
  already was. The scan ran to the durable tail, so an attachment installed
  while an owner held an unresolved transaction anchored on rows no consumer
  could yet read and set its cursor past them — and those rows were then never
  delivered on the event plane. The scan stops at the same acknowledged position
  the delivery pump stops at, and a session this runtime does not own carries no
  fence and scans to the end, exactly as its delivery does.
- A durable command record naming a refusal this version does not know is
  refused as invalid history instead of ending recovery with an error. The token
  was converted to an existing atom with no rescue, so whether replay raised
  depended on which atoms the VM happened to have loaded and one durable history
  could replay on a warm node and abort on a colder one.
- Reconciliation and receipt matching require a field to be present before it
  can match. An absent key read as nothing satisfied any expected value that was
  legitimately nothing — a job with no tool call or no tool version, among
  others — so an answer that simply omitted every such field was admitted as
  though it had stated them. Only a field the responder actually carries can
  match.
- The Local executor decides its quarantine when it reserves a job, inside the
  same root-wide claim that reads the root's retained terminal truth, rather
  than once at start-up. A ledger root is shared, so a verdict frozen at
  start-up was wrong in both directions: a peer instance that stranded an open
  entry never stopped an already running executor, and a root an operator had
  reconciled could not admit again without restarting the executor. The request
  being decided and the jobs this instance holds reserved are live entries
  rather than abandoned ones, so a root carrying two concurrent jobs stays
  usable and the second instance of a joined operation still joins. A claim a
  peer holds for the length of its own admission is ordinary contention: it is
  waited for out of the requester's own remaining allowance, never past it, and
  never past the ceiling one contended root is worth.
- The reserve the lease-lost path gives a receipt write comes from the one
  formula that fixes receipt retention, which rounds up and never yields less
  than a millisecond. A second local derivation by integer division disagreed
  with it below four milliseconds, so a committed cleanup period of three
  declared one millisecond of retention in every receipt and reserved none for
  writing it.
- A refusal the Local executor writes no longer renames over an admission marker
  another instance published for the same job — "no effect began" written across
  the exact record proving one had. An admission found at the marker path is
  reported as `{:ledger_conflict, :admission_marker_present}` and left exactly
  as it is; an absent marker and an existing refusal both still admit the write,
  because neither of them claims an effect began.
- A `loopex` placement lock record this version cannot decode is probed for
  liveness rather than reclaimed outright. A lock written by a newer record
  version is undecodable and names a live process, so reclaiming it put two
  runtime controls on one placement key — the outcome the lock exists to
  prevent, reached by the one input an operator running two Loopex versions is
  most likely to produce. The process identifier is salvaged from the record's
  bytes and probed: an absent process is the stale lock the reclaim path was
  written for, a live one refuses and names the process holding it, and bytes
  naming no process at all refuse as unattributable. Both refusals are
  recoverable by hand, and reclaiming a live owner is not.

### Changed

- The Store answers one refusal taxonomy for every path that admits an item.
  Building a transaction, preflighting a record through
  `Loopex.Store.normalize_and_measure_item/2`, and validating a transaction all
  run the same normalizer and the same measurement, so the same bytes get the
  same answer whichever way a caller reaches the boundary. An item that is not
  bounded plain data refuses as `:invalid_item` for a private record and
  `:invalid_event` for a public event, in place of `:not_plain_data`,
  `:not_plain_event_data`, `:invalid_record`, and `:reserved_event_field`. A
  depth or cardinality breach refuses as
  `{:item_structure_exceeded, dimension, observed, limit}` and an oversized item
  as `{:item_too_large, observed, limit}`, and both now survive a list's own
  refusal instead of collapsing into `:invalid_records` or `:invalid_events`, so
  a preflight and a commit can no longer disagree about one item. The builder's
  separate traversal is gone along with the disagreements it carried: a scalar
  at depth thirteen was admitted where the shared normalizer refuses it, an
  atom key nested inside an event was admitted where the normalizer rewrites it,
  and an untrusted list's length was taken by walking a spine the shared counter
  refuses to walk.
- An executor that refused a job before its effect started now says so in the
  answer, by returning `{:error, {:refused_before_effect, reason}}`. The runtime
  commits that as an ordinary terminal `failed` carrying `reason`; every other
  `{:error, _}` is read as unproven and ends the run `outcome_unknown` with a
  reconciliation reference. It previously recognised a list of error *names*
  copied from the shipped local executor and applied to every implementation, so
  a conforming executor that lost its lease halfway through a write and returned
  `{:error, :workspace_lease_lost}` had that effect committed as `failed` and the
  loop carried on past an effect nobody could account for. An executor that
  adopts nothing keeps compiling and stays conforming, and sees errors that used
  to end a call `failed` now end the run `outcome_unknown` — failing closed, and
  a behaviour change rather than an addition.
- Stopping a tool draws grace, forced termination and confirmation from one
  declared period rather than from a fresh allowance at each step, and every
  instant in that period is measured with `System.monotonic_time/1` so a clock
  adjustment cannot lengthen a grace mid-termination. Writing the receipt is
  bounded by a declared share of the period instead of by whatever the earlier
  steps left, which was nothing after a forcibly killed process group — so the
  job whose durable record matters most produced none. Each receipt records the
  period it ran under and the bound its own write ran under.
- The program the local executor asks whether a process group still has members
  is a start option, `process_probe`, defaulting to `/bin/ps` and recorded on
  every receipt. An image that ships `ps` elsewhere previously had every command
  reported `outcome_unknown` with nothing to say which program was missing.
- Cancelling a job through the shipped local executor now spends the period its
  host configured. `cancel/2` runs in its caller so it is not queued behind the
  job it is ending, and it read the period from a process dictionary the caller
  does not have, so it spent the compiled-in default instead.
- The cleanup period is a declared session configuration value with a default,
  as ADR 0009 requires. `Loopex.start_link(cleanup_grace_ms: …)` declares it,
  `loopex run --cleanup-grace-ms …` is the operator's way to name it, and
  `LoopexComposition.start/1` hands the same number to the session and to the
  executor so the ending cannot report a period the cleanup did not run under.
  Every run terminal and every `run.finished` reports it, from the session's own
  declaration rather than from whatever receipt happened to arrive — a run that
  dispatched no tool, an abort admitted before any executor answered, and every
  recovery previously reported nothing at all. The one default lives on the port
  as `Loopex.Executor.default_cleanup_grace_ms/0`, because the session and the
  hand both need the same number. The program that confirms a process group
  remains executor configuration, recorded at
  [M2 recorded limitations](docs/evidence/M2-recorded-limitations.md#process-probe-not-session-visible).
- A tool's declared wall-time budget is carried on the job it is dispatched
  with, as `resource_budgets["max_wall_time_ms"]`, beside the output ceiling
  that was already declared there. The local executor bounds a job by the
  smallest of the run's committed instant, that declared budget, and the budget
  its own copy of the definition names, so a caller can neither widen a tool's
  budget nor outlast the run. The budget was previously read only from the
  executor's own registry, which made the bound a fact about the hand rather
  than about the dispatch and left nothing durable naming it.
- An abort accepted through `Loopex.command/2` is an *admission*, not an ending.
  The run stays active until its cleanup commits a terminal, which is ADR 0009's
  order and is a real consequence for callers: a prompt submitted between the
  two is queued as a follow-up on the still-active run rather than starting a
  new one. A caller that needs the run over waits for its `run.finished`.
- Every item of a stream domain that receives a closing item is emitted by one
  process that ends when it closes. ADR 0011 requires a closure to be the last
  item of its domain, and a producer and a closer in two processes order nothing
  between them: a producer preempted between taking a sequence and emitting it
  could put a delta on the plane after its own closure. A delta handed to a
  closed domain now reaches a process that no longer exists. ADR 0014 separately
  governs owner loss, where the transient plane may end without a closure rather
  than letting another owner fabricate one.
- A closure states what ADR 0011 assigns it: a complete domain states its
  producer's own `delta_count` or `progress_count`, and an abandoned one states
  the count this runtime published. An earlier revision of this milestone
  substituted the published count on both, which erased the only live evidence a
  refusal leaves — the refusal record is durable and private, so a consumer
  comparing the stated total against what reached it is the only way a refused
  item is visible at all.
- A canonical model delta must carry exactly the fields its kind declares.
  Carrying a name nobody declared was already refused; omitting one everybody
  declares now is too, so a `text_delta` with no text and a `tool_call_delta`
  naming no call are no longer sequenced, published, and counted. The payload
  ceiling measures every field, including ones whose type the measurement does
  not otherwise know: an unbounded integer previously measured as nothing.
- Accepted milestone governance may integrate to `main` after exact review and
  explicit protected-branch approval while product implementation remains on
  the milestone branch until closure. Once that governance checkpoint is
  integrated, one generic successor may be Open for planning and gate review;
  it cannot be accepted or implemented before its predecessor closes and it is
  refreshed on that exact product base.
- Accepted-plan amendments now use one generic proposal/rebind transaction.
  Proposal `A` is reviewed with its deliberately stale prior binding; transition
  `R` records the exact acceptance and is where binding-dependent inherited gates
  must pass before governance integration. Results remain attributed to the SHA
  where they ran and cannot stand in for later product-candidate evidence.
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
  minimalism budget requires it to name what it drops. This entry previously said
  the budget required the replacement to be "materially smaller" than the bridge
  it retires. That contradicted the accepted technical envelope and was retracted
  in the plans index: size is a review signal, never a pass condition. The
  replacement measures larger, and the report states why.
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

- The model reply carries the provider's own identifier for the response. It is
  the one field a deterministic adapter cannot invent, and it is what a person
  looks up in the provider account when confirming that a real call happened.
- A tool that completed and produced no output now says so rather than
  committing an empty result. An empty result is indistinguishable to a model
  from a call that failed silently, and a real provider answered it by making the
  same call again.
- The public tool events carry the tool's generation alongside the call
  identifier, so a terminal reading the public plane can name what is running and
  what was refused.

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
