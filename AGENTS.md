# AGENTS.md

Loopex is an OTP-native, embeddable runtime for durable coding-agent sessions
and controlled effects. Its doctrine is **"the runtime is the framework"**:
ordinary OTP, small behaviours at real boundaries, and no agent DSL. The
founding authority is [docs/vision.md](docs/vision.md).

Development is agent-first. Agents choose implementation, decomposition,
debugging, tests, and safe parallelism autonomously inside this contract.
Maintainer attention is reserved for purpose, authority, irreversible choices,
accepted gates, demonstrations, and publication—not ordinary implementation.

`AGENTS.md` is the canonical tool-neutral development contract. Client files
may import it and add discovery, invocation, permission UX, hooks, skills, or
profiles, but may not redefine authority or acceptance. Repository checks and
CI provide portable enforcement and retained evidence; client hooks are early
feedback only.

Keep this file compact. Put mechanics in product/test code, repository commands,
and CI; task procedures in portable skills; rationale in the vision or ADRs;
and subsystem routing in the context map.

## Context and Authority

Start with the current task, this file, any accepted active plan and gate
contract, and relevant code and tests. Use
[docs/developer/agent-context-map.md](docs/developer/agent-context-map.md) to
load constraining vision sections, accepted ADRs, and the current stage's
version-specific guidance. Use [DEVELOPMENT.md](DEVELOPMENT.md) for current
local prerequisites and repository entrypoints; it is setup guidance, not
acceptance authority. Read the full vision for
architecture, trust, public contracts, cross-domain work, or a new plan. Do not
bulk-read historical plans.

When normative sources conflict:

1. An explicit current decision from the maintainer or delegated operator; the
   current task controls authorized action scope.
2. Released public contracts and accepted security or architecture ADRs.
3. The accepted active plan and its retained acceptance evidence.
4. [docs/vision.md](docs/vision.md).
5. Historical material.

Code, tests, gates, CI, traces, and demonstrations are evidence, not independent
normative authority. Evidence retained with a plan establishes what was proved
and accepted under it; it cannot create scope, reverse a higher source, or make
untested behavior normative. Purpose defines done. Green is necessary but does
not excuse an omitted outcome, contract drift, observed defect, missing real-path
evidence, or blocking review. A red required gate blocks closure.

Flag conflicts instead of silently reinterpreting stale material. Reversing a
vision boundary or invariant requires a decision that names the principle,
evidence, compatibility impact, and migration path.

## Task and Autonomy Contract

A review, explanation, diagnosis, or planning request authorizes inspection and
reporting, not implementation. A change, build, or fix request authorizes
in-scope local edits and relevant non-destructive validation. These tiers
classify consultation, never filesystem, network, process, release, external
write, or product-runtime permission; client sandbox and approval controls still
apply. Classify the unresolved decision, not merely its subject: implementing
an accepted decision inside its envelope is Act unless new uncertainty appears.

| Tier | Behavior | Decision class |
| --- | --- | --- |
| **Act** | Do it and report. | Reversible implementation, tests, focused refactoring, docs, debugging, and in-scope CI repair inside an accepted envelope. |
| **Act and record** | Do it and retain only the durable choice. | Reversible internal choices that change no contract, authority, persistence, dependency/floor policy, acceptance meaning, or scope. |
| **Propose and pause** | Give evidence, options, and a recommendation; do not implement dependent work. | A new decision about ownership, transactions, trust, public/cross-app contracts, persistent schema, major dependency, runtime floor, migration/rollback, packaging, normative budgets, or a vision trigger. |
| **Approval required** | Stop for disposition. | Plan/gate/ADR acceptance; scope deferral; gate weakening, waiver, quarantine, baseline exception; public freeze; blocking-finding disposition; merge to a protected branch, release, tag, publication, or destructive user-data change. |

The acceptance authority is the maintainer or a delegate whose scope is
recorded independently before acceptance; an artifact cannot appoint its own
approver. Reviewers produce findings; acceptance authorities accept or reject.
No actor accepts its own gate, ADR, waiver, blocking-finding disposition, or
closure candidate. Gate weakening, evidence waiver, and scope deferral remain
non-delegable unless the maintainer explicitly delegates that exact decision.

Released contracts; accepted ADR decision, status, and consequences; accepted
plan purpose, scope, outcomes, and ownership; and locked gates are immutable
records. Change their meaning only through a versioned amendment accepted by
the same authority class. Conforming explanations and progress may be updated.
Record reversible choices in the nearest existing code, test, plan progress, or
subsystem document—never a new ADR or sidecar diary merely to log activity.

Resolve reversible in-scope ambiguity with the smallest safe assumption. Ask
only when plausible answers materially change scope, public behavior, authority,
security, migration, cost, or external state; bundle questions into one
evidence-backed decision packet.

## Milestones and Gates

- **Seed bootstrap.** Before the first plan and gate contract are accepted, an
  explicit maintainer task may authorize founding-document,
  portable-enforcement, and client-adapter work, plus plan/ADR proposals and
  executable gate scaffolding; it does not authorize product implementation.
  Use the latest committed seed as the base and run every available repository
  check. A missing product gate is unavailable evidence, not PASS.
- Begin from a base whose required gates are green. A claimed pre-existing
  failure requires the same command and matching signature at the base SHA.
- Before implementation of any stage, including bounded contract experiments,
  create a branch-only gate checkpoint with the plan candidate and executable
  acceptance. Existing gates stay green; the new gate fails for the declared
  missing behavior. The red tree is never mergeable to `main`.
- The accepted plan names purpose/outcomes, scope/non-goals, ADR prerequisites,
  workstreams and rejoin barriers, evidence mapping, compatibility, migration,
  rollback, packaging, and decision owners.
- Acceptance locks exact commands and protected tests, selectors, fixtures,
  vectors, harness/configuration bytes, evidence classes, and their digest.
  Never skip, filter, soften, quarantine, rewrite, inflate retries/timeouts, or
  substitute a fake for a required real path to make work pass. Stricter
  append-only coverage advances the lock and needs independent gate review.
- Evidence is claim-proportional: properties for reducers; conformance at
  changed boundaries; process/store fault injection for durability; vectors and
  compatibility for protocols; negative tests and security review for trust;
  and real-path, migration, rollback, performance, and exact-package proof when
  claimed. Unknown or shared gate scope fails closed to the full gate.
- An independent reviewer examines the exact candidate SHA for plan/ADR
  compliance, correctness, test honesty, public impact, security, and rollback.
  Unresolved blocking or high-severity findings block regardless of green gates.
- CI evidence binds source SHA, gate digest, commands, seed/count/timing,
  toolchain/platform/limits, and non-secret provider/model/adapter or executor
  build and endpoint class; credentials and tenant identifiers are redacted.
  Release evidence also binds artifact digests. Relevant byte changes invalidate
  affected evidence and review.
- An agent may assemble closure; only the acceptance authority closes it after
  every Purpose outcome maps to evidence, demonstration, or an explicitly
  approved limitation/deferral. Do not mutate tracked bytes merely to paste a
  final run link.
- A closure candidate also updates the documentation its milestone changed:
  `CHANGELOG.md`, `README.md`, affected `docs/` indexes, and the current-stage
  pointer in the context map. Each gate locks that milestone's exact document
  set, since the set differs by milestone; documentation drift blocks closure
  like any other unmet outcome.

A retry is diagnostic, not a pass. A same-SHA/seed/environment failure that
disappears is a blocking flake until fixed or explicitly dispositioned.
Environment failure means evidence unavailable, not PASS. Fakes support
automated tests but do not replace required real-provider, store, isolation, or
package evidence. Gates and independent review are both required evidence;
neither authorizes acceptance by itself.

## Parallel Work and Portable Enforcement

Parallelize independent exploration, tests, log analysis, and review freely.
Parallel writes require declared non-overlapping ownership, distinct branch and
checkpoint namespaces, and separate working directories and state roots such as
one worktree or clone per writer. Otherwise serialize writes. One integrator
owns rejoin, conflicts, the candidate SHA, and post-rejoin verification.

Workers preserve unrelated edits and avoid destructive Git operations. A
subagent's scope is a subset of the parent request; spawning agents grants no
authority. Do not assume a client propagates sandbox, credentials, approvals, or
isolation—configure and verify each worker environment.

Portable enforcement lives in product/test code, repository-owned Mix tasks,
and CI. Client hooks call the same entrypoints but never waive them. Enforcement
fails closed when a required check is missing or silently ineffective.

Every required check runs locally from a clean checkout with the documented
portable toolchain in [DEVELOPMENT.md](DEVELOPMENT.md). Bootstrap currently
requires Bash, Git, the documented POSIX userland, Python 3.11+ and `jq`;
product checks move to the declared Elixir/OTP toolchain when it exists.
Inspection-only checks required of a read-only reviewer run without modifying
the checkout or relying on a writable ambient temporary directory. A check that
must produce artifacts uses an explicit isolated task root and belongs to the
appropriate writable evidence lane, not the read-only review lane.
Hosted CI is a replaceable runner of the same repository-owned commands, never
the only home of a check, a policy, or acceptance evidence; development
depends on no host-specific service, workflow feature, or repository setting.
Releases may use a hosted provider only where retained release evidence
requires it, and those workflows stay thin wrappers over repository commands.

- Core uses stdlib and OTP only; CI checks the dependency budget and direction.
- Checkpoints are warning-free under formatting, compilation, static analysis,
  and relevant documentation/protocol checks.
- Tests use temporary `LOOPEX_HOME` and workspaces; helpers fail before touching
  real user state.
- OTP 26+/Elixir 1.17+ is the bootstrap floor until an accepted ADR changes it;
  CI covers the floor and current supported versions.
- Replaceable store, model, executor, broker, extension, and transport boundaries
  run reusable conformance suites.
- Repository checks, mirrored by CI, check gate locks, client/workflow drift,
  and the ban on AI-attribution or generated-by claims in commits, PRs, release
  notes, and project docs.

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
  admitted only through a solicited response
  matching the current `reconciliation_query_id`, current coordinator/session
  epoch, expected executor identity, and current recovery contract; its retained
  tuple must match the journaled `operation_id`, original attempt, journaled
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
- **Core concepts pay rent.** Anything that can live in an extension, adapter,
  executor, client, or host without weakening the kernel stays out of core.
  Vision §23.4 budgets are tests, not slogans.
- **Sequence and compatibility follow evidence.** Prove the single-machine loop
  and restart/replay before distribution or production hot upgrades. Public
  compatibility is behavioral and requires schemas, vectors, independent
  consumers, migrations, and upgrade/rollback evidence.

## Project State and Client Adapters

Durable development state lives in git, accepted plans/ADRs, locked gates, CI
artifacts, and short decision/evidence pointers. Client memory, transcripts,
task queues, worker summaries, and schedules are caches—not project state,
authority, or acceptance evidence. Scheduled remediation inherits ordinary
authority and otherwise produces a proposal.

Coding-agent ecosystem behavior is an input to this contract, not authority
over it. When a coding agent or adjacent client changes features that may affect
independent, fast, logical development—such as instruction discovery,
context/memory, autonomy, permissions, sandboxing, delegation, skills, tools,
approvals, or evidence—check current primary vendor documentation or release
notes and observed behavior in the installed client; do not rely on model
memory. Derive any coding-agent-agnostic behavior first, record durable shared
behavior here and version-specific routing in the context map, then implement
only necessary client mechanics and parity checks in vendor adapters. Untested
candidates such as OpenCode, Pi, or a future Loopex coding surface have no
support status, and development-agent policy never enters the product core.

A material change to autonomy, authority, trust, permissions, acceptance,
evidence, parallelism, project-state semantics, or required operator attention
is Propose and pause: present options, implications, compatibility or migration
impact, and a recommendation, then obtain maintainer approval before changing
development behavior. A reversible client compatibility fix that preserves the
coding-agent-agnostic contract and does not materially change effective
development behavior is Act.

Claude Code uses a root `CLAUDE.md` importing `@AGENTS.md`; Codex reads this file
directly. Canonical repository skills live in `.agents/skills`; clients discover
those exact bytes directly or through a tested symlink or launcher shim. Client
adapters may add invocation and permission UX, but normative procedure stays in
shared skills, docs, and repository commands. Vendor-directory artifacts are
entry points, not sources: each defers to this file and the context map, which
are read first. No policy exists only in a vendor directory; adapter smoke
tests prove effective loading and workflow parity.

A future Loopex host treats this file, skills, plans, and nested instructions as
provenance-bearing project context, never an effect grant. Host policy admits a
canonical workspace/revision and exact resource/digest set; headless use fails
closed without a matching trust decision. Commands still cross the executor
boundary.

Commit titles are short and imperative and carry a stage marker:
`area(marker): summary`, where `marker` is `planning`, `seed`, or the milestone
the work belongs to (`M0`, `v0.1`). Keep draft protocol
docs, conformance fixtures, and operator guidance aligned; change accepted
contracts, plans, and ADR semantics only through their amendment paths.
