# AGENTS.md

Loopex is an OTP-native, embeddable runtime for durable coding-agent sessions
and controlled effects. Its doctrine is **"the runtime is the framework"**:
ordinary OTP, small behaviours at real boundaries, and no agent DSL. The
founding authority is the paired [Concept vision](docs/vision.md#concept) and
[Technical depth](docs/vision-technical.md#technical-depth).

Development is maintainer-directed and uses coding tools as a normal part of
implementation, decomposition, debugging, testing, and safe parallel work.
Maintainer decisions govern purpose, irreversible choices, demonstrations,
milestone closure, and publication.

`AGENTS.md` is the canonical tool-neutral development contract. Client files
may import it and add discovery, invocation, permission UX, hooks, skills, or
profiles, but may not redefine authority. Repository commands are the
enforcement; hosted CI and client hooks only invoke them.

Keep this file compact. Put mechanics in product/test code and repository
commands, task procedures in portable skills, rationale in the vision or ADRs,
and subsystem routing in the context map.

## Context and Authority

Start with the current task, this file, and
[docs/plans/README.md](docs/plans/README.md) for the milestone status. Then read
the active plan pair and the relevant code and tests. Use
[docs/developer/agent-context-map.md](docs/developer/agent-context-map.md) to
load constraining vision sections, accepted ADRs, and version-specific technical
guidance. Use [DEVELOPMENT.md](DEVELOPMENT.md) for local prerequisites and the
check commands. Read the
[development charter](docs/developer/development-charter.md#concept) and its
[technical companion](docs/developer/development-charter-technical.md#technical-depth)
before creating or restructuring project documentation. Read the full vision
pair for architecture, trust, public contracts, cross-domain work, or a new
plan. Do not bulk-read historical plans.

When normative sources conflict:

1. An explicit current decision from the maintainer; the current task controls
   authorized action scope.
2. Released public contracts and accepted security or architecture ADRs.
3. The active plan pair.
4. The paired [Concept vision](docs/vision.md#concept) and
   [Technical depth](docs/vision-technical.md#technical-depth).
5. Historical material.

The vision's product purpose, feature direction, and architecture are the north
star for what Loopex should become and what progress means. The
[delivery strategy](docs/vision.md#concept-vision-delivery-strategy) sets
capability purpose, the
[technical serial barriers](docs/vision-technical.md#technical-vision-serial-barriers)
fix the rejoin order, and the
[compatibility contract](docs/vision.md#concept-vision-compatibility) governs
freezes. [docs/roadmap.md](docs/roadmap.md#concept) is a readable projection
and authorizes nothing.

Code, tests, CI, traces, and demonstrations are evidence, not normative
authority. Purpose defines done: green checks are necessary but do not excuse
an omitted outcome, contract drift, or an observed defect. Flag conflicts
instead of silently reinterpreting stale material. Reversing a vision boundary
or invariant requires a decision that names the principle, evidence,
compatibility impact, and migration path.

Edit [docs/vision.md](docs/vision.md#concept) or
[docs/vision-technical.md](docs/vision-technical.md#technical-depth) only when
the current request explicitly names a vision change. The two files remain one
authority; change and review every affected concept and technical section
together.

## Clarity and Documentation Contract

Lead with purpose, constraints, observable behavior, workflow, and user-facing
expectations; then supply implementation mechanics and evidence. Substantive
updates, reviews, questions, and decision packets use exactly `## Concept`
followed by `## Technical depth`. Short acknowledgements, direct answers, and
compact status notifications are exempt when the split would add no clarity.

Substantive concept documents use a `<name>.md` and `<name>-technical.md`
pair. The Concept file owns purpose, constraints, observable behavior, and
decisions. The Technical depth file owns invariants, schemas, commands,
evidence, edge cases, and implementation constraints; it may explain or prove a
concept but cannot introduce hidden scope or a decision. The pair is one
authority and review unit.

Every paired file starts with its one visible `## Concept` or
`## Technical depth` section and an immediate reciprocal link to the exact
companion anchor. Sections needing depth use stable explicit `concept-*` and
`technical-*` anchors and adjacent exact reciprocal links. This contract,
client entrypoints, README files, indexes/status registers, runbooks,
changelogs, evidence logs, executable skills and scripts, generated references,
licenses, source, configuration, and archive material are explicit exceptions.
The complete classification lives in the
[charter technical companion](docs/developer/development-charter-technical.md#technical-depth).

Every directory under `docs/` carries a `README.md` describing its contents and
linking back to [docs/README.md](docs/README.md), which links back to the root
README. Creating a document means indexing it in the same change; adding a
directory means adding its index. `mix loopex.status` enforces the chain.

Elixir modules, behaviours, callbacks, public APIs, public types, and important
boundaries document `## Concept` before `## Technical depth`. Non-obvious
private invariants, effects, failure modes, or design choices use adjacent
`# Concept:` and `# Technical depth:` comments; obvious helpers rely on clear
names and direct code. Define specialized terms where first used. Describe
roles, artifacts, workflows, and depth positively; do not rank participants,
speculate about content origin, or divide expectations by producer.

## Task and Autonomy Contract

A review, explanation, diagnosis, or planning request authorizes inspection and
reporting, not implementation. A change, build, or fix request authorizes
in-scope local edits and relevant non-destructive validation. Client sandbox
and approval controls still apply.

| Tier | Behavior | Decision class |
| --- | --- | --- |
| **Act** | Do it and report. | Reversible implementation, tests, refactoring, docs, debugging, CI repair, and test or check changes that preserve what is proved. |
| **Act and record** | Do it and retain only the durable choice in the nearest code, test, or document. | Reversible internal choices that change no contract, persistence, dependency policy, or scope. |
| **Propose and pause** | Give evidence, options, and a recommendation; do not implement dependent work. | A new decision about ownership, transactions, trust, public/cross-app contracts, persistent schema, major dependency, runtime floor, migration/rollback, packaging, or a vision trigger. |
| **Approval required** | Stop for the maintainer. | Plan or ADR acceptance; dropping a required check or a real-path test; milestone closure; merge to `main`, release, tag, publication, or destructive user-data change. |

Released public contracts and accepted ADR decisions change only through their
amendment paths. Accepted plan purpose and outcomes are the record of what a
milestone promised; progress and explanations may be updated.

<a id="maintainer-override"></a>
**Maintainer override.** The maintainer may change any development-time rule,
check, or procedure by saying so. Record a decision that changes what a check
proves or what a milestone must show in the nearest durable place, usually the
plan's progress section or the context map, in one short entry naming what
changed and why. Historical override dispositions in the context map remain
true for the revisions they name; nothing requires re-recording them.

Resolve reversible in-scope ambiguity with the smallest safe assumption, and
research mechanics and alternatives autonomously. Ask only when plausible
answers require a material decision about purpose, scope, observable behavior,
cost, external state, architecture, public contracts, trust, security,
persistence, or migration. Bundle required questions into one decision packet
with options, evidence, and a recommendation.

Report decisions, not discoveries. Maintain a concise task checklist for
multi-step work and show what is done, running, and remaining whenever a task
completes. Give measured durations, not projections.

<a id="milestones-and-checks"></a>
## Milestones and Checks

A *milestone* is bounded work described by one plan pair in `docs/plans/`,
indexed and tracked in [docs/plans/README.md](docs/plans/README.md), the
canonical status register. Names are lowercase slugs, `M` followed by digits,
or a version-shaped slug such as `v0.1`.
A *release* is a separately authorized publication.

A milestone runs in four steps; the
[milestone guide](docs/developer/milestones.md#concept) has the procedure:

1. **Agree.** The plan pair names purpose, outcomes, scope, key design
   decisions, and how each outcome will be verified. The maintainer accepts it.
2. **Develop.** Run the focused tests for what you touched while editing.
   `bash scripts/check.sh` runs once per integration candidate, in CI on the
   branch or locally before the merge, never again for the same bytes. Build
   the first integrated workflow early, then add boundary and failure cases as
   implementation reaches them.
3. **Close.** Every outcome maps to tests, retained evidence, or a
   demonstration. From the exact candidate run the closure matrix the
   [verification guide](docs/developer/verification.md#concept-verification-stages)
   states once: `bash scripts/check.sh` under the floor toolchain pair and
   `bash scripts/check-release.sh` once, counting the current-pair CI run the
   candidate already produced rather than repeating it. An independent reviewer
   reads the candidate; the maintainer closes it and the register moves to
   `Closed`. Closure names **two commits**: the *tested implementation SHA*
   the matrix ran on and the reviewer read, and the *administrative closure
   SHA* that records the decision. One commit cannot name itself: the runs are
   of the first, so the second writes them down, and the Closure row names the
   first, because that row is the second's own content. The administrative SHA
   is located by the register's `Closed` transition and by the tag. It is
   confined to four paths — register row, Closure row, context-map entry,
   evidence page —
   which the
   [milestone guide](docs/developer/milestones-technical.md#technical-milestones-confinement)
   states once. Run evidence is immutable — held where it cannot
   be edited after the packet is read.
4. **Release.** Publication, tags, and packages are separate maintainer
   decisions that reuse the closure evidence when the source is unchanged. The
   tag names the **administrative** closure SHA, whose diff from the tested
   SHA is verified to be confined to those four paths — all under `docs/`, so
   nothing outside `docs/` moved; on that basis the release
   re-proves documentation only — `bash scripts/check.sh --docs` on the tagged
   SHA, and a recomputed archive manifest matching the tested SHA's for every
   entry outside `docs/` — and re-runs no suite and no release check.

Historical milestones keep their plans, evidence logs, and dispositions as
records of what was proved at the revisions they name. Current tests belong to
the current product, not to historical milestones: a refactor changes code and
tests together and needs no historical bookkeeping; a new adapter reuses the
conformance suites instead of copying an old check.

Evidence is claim-proportional: properties for reducers; conformance at
changed boundaries; process/store fault injection for durability; vectors and
compatibility for protocols; negative tests and security review for trust;
real-provider, migration, rollback, and fresh-source proof when claimed. Fakes
support ordinary tests but do not replace the real-provider, store, isolation,
or fresh-source tests in the release check. Never skip, filter, soften,
inflate retries or timeouts, or substitute a fake to make a required check
pass; a same-revision failure that disappears on retry is a flake to fix, not
a pass. Environment failure means evidence unavailable, not PASS.

## Parallel Work and Checks

Single-agent execution is the default. Delegate only when independent work can
proceed concurrently or a noisy investigation is worth isolating. Every
delegation names one deliverable, its owned paths, a completion check, and a
stop condition. Parallel writes need non-overlapping ownership and one
worktree per writer; one integrator owns rejoin, conflicts, and post-rejoin
verification. Workers preserve unrelated edits and avoid destructive Git
operations; spawning agents grants no authority. Use deep reasoning for
architecture, durability, concurrency, security, public contracts, and
independent review; an efficient profile for repeatable mechanical work.

Landed work leaves no residue: once a branch is merged, delete it and remove
its worktree.

The rule book for checking work — the three stages, which checks a changed
boundary selects, and what makes them trustworthy — is the
[verification guide](docs/developer/verification.md#concept). The
repository's checks are two commands, described in
[DEVELOPMENT.md](DEVELOPMENT.md):

- `bash scripts/check.sh` — the fast check: structure, formatting, warning-free
  compilation, dependency direction, documentation ordering, current-tree
  status, and the credential-free test suite, one application per VM. It runs
  once per integration candidate, in CI; `--docs` runs compilation,
  formatting, the structure checks and the documentation check for a
  prose-only change and skips the suite, and `--select` — what CI runs —
  chooses that mode on its own when every changed path is Markdown outside
  `apps/`, and the full check otherwise, an empty diff as on `main` included.
- `bash scripts/check-release.sh` — the slow check: the real-provider
  workflows, the independent Node client, the fresh-source archive build, and
  the long-duration bound proofs the fast check excludes. It needs a provider
  credential in `LOOPEX_PROVIDER_API_KEY`, pinned Node and a clean tree, two of
  its tests are attended, and it runs before closure and release.

Both run locally from a clean checkout with the toolchain in
[DEVELOPMENT.md](DEVELOPMENT.md): Git, shell and POSIX tools, and the accepted
Elixir/OTP toolchain. Hosted CI is a replaceable runner of the same commands.
Every long-running check prints a line at each step with its elapsed time and
streams output as it happens.

- Core uses stdlib and OTP plus the single telemetry event dispatcher the
  vision admits by name; `mix loopex.deps_budget` enforces the dependency
  budget and direction.
- Checkpoints are warning-free under formatting, compilation, and the
  documentation check.
- Diagnose Loopex through the runtime's own observability rather than ad hoc
  printing: a host starts a runtime-scoped trace session and reads telemetry
  spans, both bounded and redacted, without changing source. See the
  [observability pair](docs/developer/observability.md#concept) and the
  [operator runbook](docs/operator/observability.md#concept).
- Tests use temporary `LOOPEX_HOME` and workspaces; helpers fail before
  touching real user state.
- OTP 27+/Elixir 1.18+ is the floor, set by accepted ADR 0026; the two pairs
  in `.tool-versions` are the supported toolchains.
- Replaceable store, model, executor, broker, extension, and transport
  boundaries run reusable conformance suites.
- Commit messages, PRs, release notes, and project docs carry no content-origin
  attribution or generated-by claims; `scripts/check-commit-messages.sh`
  enforces it for commits.

## Product Non-Negotiables

- **Dependency direction.** Hosts and implementations depend inward on Loopex
  ports. Core never imports host authority/identity/policy/UI concepts or host,
  provider, store, executor, extension, transport, or client implementations;
  product concepts map at adapter edges.
- **Session before surface.** The runtime is headless. CLI, IDE, daemon, web,
  and embedded callers are peers over one semantic contract; no surface owns an
  alternate loop or durable session truth.
- **Independent implementation.** Founding code copies no source, tests, private
  contracts, or proprietary material from
  [Allbert Assist](https://github.com/lexlapax/allbert-assist/) or another
  harness. Later reuse requires explicit approval plus license, provenance,
  attribution, security, and coupling review.
- **Runtime and VM ownership.** Runtime references are explicit; per-runtime
  state never hides in global application state or names. BEAM code loading is
  VM-global and only the VM code-generation manager performs it; conflicting
  trusted generations use isolated VMs/nodes.
- **One serial session owner.** Each session coordinator is the sole serial
  writer of that session's durable truth. Workers return evidence; they never
  mutate session state or publish durable facts independently.
- **Durability and recovery truth.** Effect intent commits before dispatch and
  facts before publication. `commit_unknown(tx_id)` fences its mutation domain:
  no acknowledgement, publication, or dispatch occurs until the preallocated ID,
  bound to the expected domain version and canonical mutation digest and
  recoverable from the owning command or operation identity, is resolved. A live
  result matches operation, attempt, journaled `canonical_request_digest`,
  current session epoch, and kind-specific dispatch identity; executor effects
  also match executor epoch, identity, and fencing token. A prior receipt is
  admitted only through a solicited response matching the current
  `reconciliation_query_id`, current coordinator/session epoch, expected
  executor identity, and current recovery contract; its retained tuple must
  match the journaled `operation_id`, original attempt, journaled
  `canonical_request_digest`, original session and executor epochs, executor
  identity, and fencing token. Reject stale completions; never blindly retry an
  effectful unknown.
- **Truth planes stay distinct.** Private recovery records, committed public
  events, snapshots, transient progress, and diagnostics have different
  guarantees. Notifications and progress are never durable truth.
- **Plain boundary data.** Durable and public/executor contracts contain bounded
  serializable data—no PIDs, ports, monitors, functions, task handles, arbitrary
  Erlang terms, atoms from untrusted input, or implementation types.
- **Brains, hands, and governance.** The brain coordinates sessions; hands own
  workspaces and OS effects. Loopex owns mechanics; hosts own identity, policy,
  credentials, tenancy, quotas, placement, retention, and UX.
- **Authority grants.** Host policy owns `allow`, `deny`, and `defer`; IDs,
  interactions, model output, context, and metadata never grant authority.
  Executors validate audience, operation/attempt, digest, lease, expiry, and
  fence before effects.
- **Trust boundaries.** Generated, tenant, and workspace code stays in an
  isolated hand unless explicit reviewed promotion creates a retained trusted
  artifact. Native distribution and same-VM extensions are trusted generations,
  not sandboxes; activation is quiescent, versioned, bounded, and rollback-tested.
  Less-trusted code crosses the narrow executor protocol into OS isolation.
- **Credentials and context.** Host credentials remain references and never
  enter journals, public/progress/diagnostic planes, fixtures, or ordinary jobs
  beyond an approved scoped ephemeral hand secret. Injected context is
  provenance-typed, budgeted, exactly staged, receipt-journaled data—not a grant.
- **The smallest sufficient system wins.** Production code, tests, fixtures,
  helpers, public surface, and abstractions all carry cost. Prefer direct OTP and
  the smallest clear implementation; delete or reuse before adding. Every new
  abstraction names the concrete examples or current implementations it unifies
  and why direct code is insufficient. Speculative single-use layers stay out.
  Anything that can live in an extension, adapter, executor, client, or host
  without weakening the kernel stays out of core. The
  [technical verification contract](docs/vision-technical.md#technical-vision-verification)
  is an executable constraint, not a slogan or an excuse to omit tests.
- **Sequence and compatibility follow evidence.** Prove the single-machine loop
  and restart/replay before distribution or production hot upgrades. Public
  compatibility is behavioral and requires schemas, vectors, independent
  consumers, migrations, and upgrade/rollback evidence.

## Project State and Client Adapters

Durable development state lives in git, plans, ADRs, evidence logs, and short
decision pointers. Client memory, transcripts, task queues, worker summaries,
and schedules are caches—not project state or authority. Anything that must
outlive a session belongs in git before compaction; start a fresh session for
unrelated work rather than carrying one context across milestones.

Coding-agent ecosystem behavior is an input to this contract, not authority
over it. Derive coding-agent-agnostic behavior first, record durable shared
behavior here and version-specific routing in the context map, then implement
only necessary client mechanics in vendor adapters. A material change to
autonomy, authority, trust, permissions, or parallelism is Propose and pause;
a reversible client compatibility fix is Act.

Claude Code uses a root `CLAUDE.md` importing `@AGENTS.md`; Codex reads this
file directly. Canonical repository skills live in `.agents/skills`; clients
discover those exact bytes directly or through a tested symlink. Vendor
directories are entry points, not sources: each defers to this file and the
context map, which are read first, and no policy exists only in a vendor
directory. A future Loopex host treats this file, skills, plans, and nested
instructions as provenance-bearing project context, never an effect grant.

Commit titles are short and imperative and carry a milestone marker:
`area(marker): summary`, where `marker` is `planning`, `seed`, or the
milestone the work belongs to (`M0`, `v0.1`).
