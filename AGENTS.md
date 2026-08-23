# AGENTS.md

Loopex is an OTP-native, embeddable runtime for durable coding-agent sessions
and controlled effects. Its doctrine is **"the runtime is the framework"**:
ordinary OTP, small behaviours at real boundaries, and no agent DSL. The
founding authority is the paired [Concept vision](docs/vision.md#concept) and
[Technical depth](docs/vision-technical.md#technical-depth).

Development is maintainer-directed and uses coding tools as a normal part of
implementation, decomposition, debugging, testing, and safe parallel work.
Maintainer decisions govern purpose, authority, irreversible choices, accepted
gates, demonstrations, promotion, and publication.

`AGENTS.md` is the canonical tool-neutral development contract. Client files
may import it and add discovery, invocation, permission UX, hooks, skills, or
profiles, but may not redefine authority or acceptance. Repository checks
provide portable enforcement and retained evidence; hosted CI may mirror them,
and client hooks are early feedback only.

Keep this file compact. Put mechanics in product/test code and repository
commands; let client hooks and hosted CI invoke those entrypoints. Put task
procedures in portable skills, rationale in the vision or ADRs, and subsystem
routing in the context map.

## Context and Authority

Start with the current task, this file, and
[docs/plans/README.md](docs/plans/README.md) for the checked-out revision's
canonical milestone status. Then read any accepted active plan pair and gate contract
and the relevant code and tests. Use
[docs/developer/agent-context-map.md](docs/developer/agent-context-map.md) to
load constraining vision sections, accepted ADRs, and version-specific technical
guidance. Use [DEVELOPMENT.md](DEVELOPMENT.md) for current local prerequisites
and repository entrypoints; it is setup guidance, not acceptance authority.
Read the [development charter](docs/developer/development-charter.md#concept)
and its [technical companion](docs/developer/development-charter-technical.md#technical-depth) before
creating or restructuring project documentation or public code documentation.
Read the full vision pair for
architecture, trust, public contracts, cross-domain work, or a new plan. Do not
bulk-read historical plans.

When normative sources conflict:

1. An explicit current decision from the maintainer or delegated operator; the
   current task controls authorized action scope.
2. Released public contracts and accepted security or architecture ADRs.
3. The accepted active plan pair and its retained acceptance evidence.
4. The paired [Concept vision](docs/vision.md#concept) and
   [Technical depth](docs/vision-technical.md#technical-depth).
5. Historical material.

The vision's product purpose, feature direction, and architecture are the
zoom-out north star for what Loopex should become and what progress means.
Governance remains binding, but serves as the guardrail that keeps delivery
aligned, evidenced, and authorized; it is not a substitute product objective.

Sequence authority lives in the vision pair and this contract, never the
roadmap. The [delivery strategy](docs/vision.md#concept-vision-delivery-strategy)
sets capability purpose, the
[technical serial barriers](docs/vision-technical.md#technical-vision-serial-barriers)
fix the enduring rejoin order, and the
[compatibility contract](docs/vision.md#concept-vision-compatibility) governs
freezes. The order a
milestone itself runs — green base, red gate before implementation, acceptance,
work, independent review, closure — is fixed by § Milestones and Gates below.
An accepted plan pair adds its own prerequisites and rejoin barriers within those.
[docs/roadmap.md](docs/roadmap.md#concept) is a readable projection and authorizes
nothing.

Code, tests, gates, CI, traces, and demonstrations are evidence, not independent
normative authority. Evidence retained with a plan establishes what was proved
and accepted under it; it cannot create scope, reverse a higher source, or make
untested behavior normative. Purpose defines done. Green is necessary but does
not excuse an omitted outcome, contract drift, observed defect, missing real-path
evidence, or blocking review. A red required gate blocks closure.

Flag conflicts instead of silently reinterpreting stale material. Reversing a
vision boundary or invariant requires a decision that names the principle,
evidence, compatibility impact, and migration path.

Edit either [docs/vision.md](docs/vision.md#concept) or
[docs/vision-technical.md](docs/vision-technical.md#technical-depth) only when the current
maintainer or developer request explicitly names a vision change. A general
documentation, alignment, refactoring, or implementation request does not grant
that scope. Explicit edit scope does not waive the decision and evidence
required to change a founding boundary or invariant. The two files remain one
authority; change and review every affected concept and technical section
together.

## Clarity and Documentation Contract

Lead with purpose, constraints, observable behavior, workflow, and user-facing
expectations; then supply implementation mechanics and evidence. Substantive
updates, reviews, questions, and decision packets use exactly `## Concept`
followed by `## Technical depth`. Short acknowledgements, direct answers, and
compact status notifications are exempt when the split would add no clarity.

Substantive concept documents use a `<name>.md` and
`<name>-technical.md` pair. The Concept file owns purpose, constraints,
observable behavior, and decisions. The Technical depth file owns invariants,
schemas, commands, evidence, edge cases, and implementation constraints. It may
explain or prove a concept but cannot introduce hidden scope or a decision. The
pair is one authority and review unit; a conflict blocks dependent work and
acceptance.

Every paired file starts with its one visible `## Concept` or
`## Technical depth` section and an immediate reciprocal link to the exact
companion anchor. Sections needing depth use stable explicit `concept-*` and
`technical-*` anchors and adjacent exact reciprocal links. This canonical
development contract, client entrypoints, README files, indexes/status
registers, setup or operator runbooks, changelogs, evidence logs, executable
skills and gates, generated references, licenses, source, configuration, and
immutable archive material are explicit exceptions. They
may route to both depths but may not hide a decision. The complete classification
and mechanics live in the
[charter technical companion](docs/developer/development-charter-technical.md#technical-depth).

Every directory under `docs/` carries a `README.md` describing its contents and
linking back to [docs/README.md](docs/README.md), which links back to the root
README. Creating a document in a directory means indexing it there in the same
change; a document reachable only by knowing it exists is not documented. Adding
a directory means adding its index. The repository status check enforces the
chain, not the prose.

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

Released contracts; accepted ADR-pair decision, status, and consequences;
accepted plan-pair purpose, scope, outcomes, ownership, rejoin barriers, and evidence
obligations; and locked gates are immutable records. Change their meaning only
through a versioned amendment accepted by the same authority class. Conforming
explanations and progress may be updated.
Record reversible choices in the nearest existing code, test, plan progress, or
subsystem document—never a new ADR or sidecar diary merely to log activity.

Resolve reversible in-scope ambiguity with the smallest safe assumption, and
research mechanics, evidence, and safe alternatives autonomously. Ask only when
plausible answers require a material operator decision about purpose, scope,
observable behavior, cost, or external state; a material developer decision
about architecture, public contracts, trust, security, persistence, or
migration; or authority or execution permission that policy requires. Bundle
required questions into one evidence-backed decision packet. Concise questions
and status lead with operator consequence, developer consequence, the achievable
current-milestone outcome and non-normative roadmap implication, and an honest
wall-clock or remaining-iteration range; then give only the governance and
technical facts needed to act.

Report decisions, not discoveries. A report states what was decided and done, or
puts a decision the maintainer owns in front of them with options, evidence, and
a recommendation. An incidental finding is not a report: resolve it within the
current scope, fold it into a decision packet, or leave it out. Never hand over
an unresolved observation for the maintainer to triage.

## Milestones and Gates

**Vocabulary.** A *capability rung* is one of the non-normative questions in the
[delivery strategy](docs/vision.md#concept-vision-delivery-strategy); it guides
decomposition but does not dictate milestone or release
boundaries. A *milestone* is bounded work governed by one accepted plan pair, one
gate, and one closure. It may prove part or all of one or more rungs while
respecting the vision's delivery strategy and serial barriers and, for
compatibility claims, its compatibility contract. A *workstream* is
a parallel slice inside a milestone and has no independent plan or gate. A
*release* is a separately authorized publication; a milestone may or may not
produce one, and only its accepted plan pair may couple the two. Milestone names are
stable operator-chosen slugs and grant no release authority. They use lowercase
ASCII letters/digits separated by single hyphens, an `M` followed by digits, or
a version-shaped numeric slug;
names are at most 64 ASCII bytes and unique under case folding. `planning`,
`seed`, `readme`, Windows
device basenames (`con`, `prn`, `aux`, `nul`, `com1`–`com9`, and
`lpt1`–`lpt9`), and names ending in `-gate` are reserved in any letter case.
Names ending in `-technical` are also reserved because that suffix identifies a
plan companion.
Plans live in paired `docs/plans/<name>.md` and
`docs/plans/<name>-technical.md` files, with the locked gate beside them in
`<name>-gate.md`;
[docs/plans/README.md](docs/plans/README.md) is the canonical current-status
register and plan index.

- **Seed bootstrap.** Before the first plan and gate contract are accepted, an
  explicit maintainer task may authorize founding-document,
  portable-enforcement, and client-adapter work, plus plan/ADR proposals and
  executable gate scaffolding; it does not authorize product implementation.
  Use the latest committed seed as the base and run every available repository
  check. A missing product gate is unavailable evidence, not PASS. `M0` remains
  blocked until ADR 0001 and ADR 0002 carry recorded acceptance; its future
  opening branch must replace the seed-specific status guard with exact
  lifecycle checks rather than delete or relax it.
- Begin acceptance and implementation from a closed product base whose required
  gates are green. A claimed pre-existing failure requires the same command and
  matching signature at the base SHA.
- One bounded planning lookahead is permitted after the current delivery
  milestone's accepted governance checkpoint is integrated to `main`. Exactly
  one successor may be `Open` on its own branch for mutable plan/gate construction
  and review while the current milestone remains the sole implementation
  authority. That branch records the predecessor as `Accepted`; `In progress`
  plus `Open` and `In review` plus `Open` are refused because those shapes imply
  a product-branch base. The lookahead base must keep the bootstrap aggregate and every
  Closed gate green, reproduce the current milestone's exact accepted opening
  red independently, and fail the successor gate for its own declared missing
  behavior. The successor cannot be accepted, integrated, or implemented until
  the current milestone is Closed and integrated; it must then absorb that exact
  product base, re-prove inherited gates green and its own distinct red, and
  receive a fresh exact-SHA review. No second lookahead is permitted.
- Before implementation of any milestone, including bounded contract experiments,
  create a branch-only gate checkpoint with the plan candidate and executable
  acceptance. Outside the bounded lookahead, existing gates stay green; under
  the lookahead, the independently checked predecessor and successor reds above
  apply. The new gate fails for the declared missing behavior. An unaccepted
  Open tree never merges to `main`.
- The accepted Concept plan's marked normative envelope names purpose/outcomes,
  scope/non-goals, and observable constraints including compatibility and
  rollout expectations. Its Technical depth
  envelope names ADR prerequisites and acceptance points, ownership and rejoin
  barriers, evidence obligations and mapping, implementation constraints,
  migration, rollback, packaging, decision owners, and exact minimalism
  constraints. The accepted candidate SHA binds both envelope digests and the
  gate digest. Workstream decomposition, progress, resolved outcome state, and
  evidence links stay outside the envelopes and may change only in conformance
  with the pair.
  The budget states what code and abstraction growth is justified and which
  measurable ceilings or negative constraints the gate locks. Raw line count is
  a review signal unless the accepted plan pair makes a scope-specific cap; never
  trade clarity or required evidence for a smaller number.
- Lifecycle transitions retain their authority. Before the canonical register
  moves to `Accepted`, the plan records the accepting maintainer or previously
  delegated authority, durable evidence of the explicit disposition, the
  accepted plan-candidate SHA, Concept digest, Technical depth digest, and gate
  digest. A bound candidate must remain
  reachable from the integrated Git history. Before the register moves to
  `Closed`, the plan records the closing authority and disposition, reviewed
  candidate SHA, Concept digest, Technical depth digest, and gate digest.
  Explicit decisions may be transcribed; they may not be inferred or supplied.
  A transition-only commit may update the governance row, the single durable
  authority-disposition record that row names, and derived status bytes, but not
  the bound candidate, locked gate, normative envelopes, portable enforcement,
  or product bytes. Before
  integration, an independent read-only review compares that exact transition
  SHA with the bound candidate and reports its changed paths and verdict to the
  current integrator; structural validation does not substitute for this
  one-time pre-integration review or make its task output durable project state.
  An amendment to an already accepted plan uses two direct, one-parent revisions.
  This strict transaction is versioned by the visible
  `<a id="amendment-transaction-v1"></a>` gate marker. Closed pre-v1 amendment
  history remains valid; every active or future amended gate must carry exactly
  one marker and obey v1 from its first marked proposal forward.
  Amendment sections appear in physical document order with consecutive numbers.
  The amendment proposal `A` is the first revision that advances the generation;
  it retains both the prior Acceptance row and lifecycle state, so binding
  validation, bootstrap, and any inherited gate that invokes them must fail there
  only for the stale binding. Binding-independent checks and the amended
  milestone gate's truthful product state are still proved directly at `A`.
  After exact-SHA review and explicit acceptance of `A`, its immediate child `R`
  records that disposition and rebinds Acceptance to exact `A`, without changing
  lifecycle state. `R` adds one new amendment-specific disposition anchor to an
  existing durable document; that anchor did not exist at `A`, and `R` never
  reuses, completes, or edits an earlier
  disposition. No commit may intervene, overlap the rebind with another proposal,
  or begin the next amendment before `R` settles this one. At `R`, binding
  validation, bootstrap, and every inherited required gate must pass, while the
  amended milestone gate must reproduce the same truthful product state proved at
  `A`. Evidence names the revision where it ran: an `R` result is never
  back-projected onto `A` and does not replace later same-source product-candidate
  evidence. The exact `A` to `R` review also proves that only the allowed
  transition bytes changed. Only `R` is eligible for integration.
  After that review, an explicitly approved governance-only Acceptance checkpoint
  may integrate to `main` while its exact accepted opening gate remains red. It
  may contain the accepted plan/gate machinery, governance, derived status and
  documentation, and portable enforcement, but no milestone product
  implementation bytes. `main`'s product baseline remains its final Closed row;
  product implementation stays on the designated milestone branch and integrates
  only through separately approved closure. Preserve every bound candidate in
  integrated history; do not squash or rebase it away. Acceptance integration is
  neither partial product integration nor release authority.
- Every lifecycle transition atomically updates the canonical register, the
  plans index's complete marked Current Status capsule, and README's derived
  summary. No client-specific memory or prose elsewhere substitutes for those
  three primary project records.
- Acceptance locks exact commands and protected tests, selectors, fixtures,
  vectors, canonical UTF-8/LF harness/configuration bytes, evidence classes, and
  their digest. The accepted gate file and digest remain immutable for that
  milestone; stricter supplementary checks may inform a later milestone but do
  not silently advance the lock.
  Never skip, filter, soften, quarantine, rewrite, inflate retries/timeouts, or
  substitute a fake for a required real path to make work pass.
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
- A closure candidate may be assembled; only the acceptance authority closes it after
  every Purpose outcome maps to evidence, demonstration, or an explicitly
  approved limitation/deferral. Do not mutate tracked bytes merely to paste a
  final run link.
- A closure candidate also updates the documentation its milestone changed:
  `CHANGELOG.md`, `README.md`, the canonical plans status register, affected
  `docs/` indexes, and any technical guidance that must be changed or cleared.
  Each gate locks that milestone's exact document set, since the set differs by
  milestone; documentation drift blocks closure like any other unmet outcome.
  Every active and future milestone gate carries one exact seven-row
  Documentation Obligations table covering operator-facing documentation,
  `docs/operator/README.md`, developer-facing documentation,
  `docs/developer/README.md`, `docs/README.md`, root `README.md`, and
  `CHANGELOG.md`. Each row names the exact files created or materially updated.
  Only the first four rows may instead state an explicit `N/A` limitation, and
  accepting the gate is the maintainer approval of that limitation. The last
  three repository-wide summaries are always named. Closed M0 predates this
  contract and is the sole migration exception.

A retry is diagnostic, not a pass. A same-SHA/seed/environment failure that
disappears is a blocking flake until fixed or explicitly dispositioned.
Environment failure means evidence unavailable, not PASS. Fakes support
automated tests but do not replace required real-provider, store, isolation, or
package evidence. Gates and independent review are both required evidence;
neither authorizes acceptance by itself.

## Parallel Work and Portable Enforcement

Single-agent execution is the default. Delegate only when independent work can
proceed concurrently, or when a bounded, noisy investigation is worth isolating
from the parent context. Do not delegate sequential work, status checks, or work
the parent can finish in one focused pass. Reuse a live child for follow-up
instead of spawning another, and prefer a named specialized role over a
general-purpose worker. Every delegation names one deliverable, its owned paths
and state root, the required capability class, a completion check, and a stop or
escalation condition. Ordinary fan-out stays at three live children besides the
integrator, and a child creates no descendants unless the parent assigned
multilevel decomposition explicitly.

Within those limits, parallelize independent exploration, tests, log analysis,
and review freely. Parallel writes require declared non-overlapping ownership,
distinct branch and checkpoint namespaces, and separate working directories and
state roots such as one worktree or clone per writer. Otherwise serialize
writes. One integrator owns rejoin, conflicts, the candidate SHA, and
post-rejoin verification.

Workers preserve unrelated edits and avoid destructive Git operations. A
subagent's scope is a subset of the parent request; spawning agents grants no
authority. Do not assume a client propagates sandbox, credentials, approvals, or
isolation—configure and verify each worker environment.

Match capability to consequence as defined by the
[development charter](docs/developer/development-charter.md#concept-capability-follows-consequence)
and its [technical routing](docs/developer/development-charter-technical.md#technical-capability-follows-consequence).
Use an efficient profile for objective repeatable work, a balanced profile for
bounded implementation, and deep reasoning for architecture, durability,
concurrency, security, public contracts, gates, rejoin judgment, and independent
review. Escalate on ambiguity or conflicting evidence; return settled
follow-through to an efficient profile. Model choice never changes authority,
scope, permissions, or acceptance. Current client mappings live in the context
map; the caller selects and verifies the required class before invocation,
because a role label is not proof of effective capability. Missing required
deep capability is unavailable evidence. Shared policy never depends on a
provider name or account-specific alias.

A deep parent never implicitly promotes an unrelated child. Capability is
selected per delegation by the caller, not inherited by default, because
inheritance silently spends a deep profile on scans, inventories, and extraction
that an efficient one answers as well. Repository role definitions stay
model-neutral and pin no account-specific alias; where a client resolves a
child's profile only by inheritance, the caller states the class at the call
site. Escalate the decision-bearing workstream alone, and de-escalate once the
decision is recorded.

Landed work leaves no residue. Once a change is pushed and contained in the
integration branch, the integrator deletes its branch and removes its worktree;
a branch or worktree that survives its merge is stale state a later agent or
client can misread as in-flight work. The designated current-milestone branch is
the explicit exception after governance-only Acceptance integration: it owns
unintegrated product implementation until closure and therefore remains live.
Unmerged branches and live worktrees are ordinary parallel work and stay.

Portable enforcement lives in repository-owned commands and product/test code.
Hosted CI calls those entrypoints. Client hooks call them where the repository
entrypoint exists; M0 must migrate or explicitly disposition the remaining
tested client-local behavior. Hooks and CI never waive repository checks, which
fail closed when missing or silently ineffective.

Every required check runs locally from a clean checkout with the documented
portable toolchain in [DEVELOPMENT.md](DEVELOPMENT.md). The development baseline
is Git, shell and POSIX tools, and the accepted Elixir/OTP toolchain. Adding
another development dependency requires the ordinary dependency decision.

Python and `jq` were seed and M0 bridge dependencies and are gone. Repository
checks run on Elixir standard-library and Mix entrypoints, and the tested client
hooks call them; the no-`jq` adapter path was proved rather than silently
disabling feedback, and the behaviours the replacement dropped are recorded with
the milestone's evidence rather than left implicit. Removing a tested hook still
requires an explicit accepted behavior disposition with equivalent protection or
an accepted loss.
The M0 gate also installs a repository-owned Elixir/Mix documentation check over
compiled docs. It enforces the ordered Concept and Technical depth sections on
covered public code; the accepted plan pair names any additional important
boundaries, while semantic usefulness and proportional private comments remain
review obligations.
Inspection-only checks required of a read-only reviewer run without modifying
the checkout or relying on a writable ambient temporary directory. A check that
must produce artifacts uses an explicit isolated task root and belongs to the
appropriate writable evidence lane, not the read-only review lane.
Hosted CI is a replaceable runner of the same repository-owned commands, never
the only home of a check, a policy, or acceptance evidence; development
depends on no host-specific service, workflow feature, or repository setting.
Releases may use a hosted provider only where retained release evidence
requires it, and those workflows stay thin wrappers over repository commands.

- Core uses stdlib and OTP only; repository checks, mirrored by CI, enforce the
  dependency budget and direction.
- Checkpoints are warning-free under formatting, compilation, static analysis,
  and relevant documentation/protocol checks.
- Tests use temporary `LOOPEX_HOME` and workspaces; helpers fail before touching
  real user state.
- OTP 26+/Elixir 1.17+ is the bootstrap floor until an accepted ADR changes it;
  repository validation, mirrored by CI, covers the floor and current supported
  versions.
- Replaceable store, model, executor, broker, extension, and transport boundaries
  run reusable conformance suites.
- Repository checks, mirrored by CI, check gate locks, client/workflow drift,
  and the ban on content-origin attribution or generated-by claims. Commit
  messages are enforced today; PRs, release notes, and project docs come under
  the same check as each surface appears. The ban applies to all of them now
  regardless of what is mechanically enforced.

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
- **The smallest sufficient system wins.** Production code, tests, fixtures,
  helpers, public surface, and abstractions all carry cost. Prefer direct OTP and
  the smallest clear implementation; delete or reuse before adding. Every new
  abstraction names the concrete examples or current implementations it unifies
  and why direct code is insufficient. Speculative single-use layers stay out.
  Anything that can live in an extension, adapter, executor, client, or host
  without weakening the kernel stays out of core. The
  [technical verification contract](docs/vision-technical.md#technical-vision-verification)
  and accepted-plan
  budgets are executable constraints, not slogans or excuses to omit tests.
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

Because that context is a cache, compacting or restarting it loses nothing that
was recorded properly. Compaction preserves the objective and acceptance
criteria, exact base and candidate SHAs, the active plan, gate, and ADR
references, authority and lifecycle state, owned and changed paths, and the
decisions, blockers, commands, seeds, and evidence results reached so far. It
discards raw logs, repeated policy prose, completed exploration, and historical
plan material. Anything that must outlive the session belongs in git before
compaction, not in a longer transcript; start a fresh session for unrelated
work rather than carrying one context across milestones.

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
tests prove effective loading of exercised shared behavior, claim parity only
for that exercised behavior, and retain client-specific limitations.

A future Loopex host treats this file, skills, plans, and nested instructions as
provenance-bearing project context, never an effect grant. Host policy admits a
canonical workspace/revision and exact resource/digest set; headless use fails
closed without a matching trust decision. Commands still cross the executor
boundary.

Commit titles are short and imperative and carry a milestone marker:
`area(marker): summary`, where `marker` is `planning`, `seed`, or the milestone
the work belongs to (`M0`, `v0.1`). Keep draft protocol
docs, conformance fixtures, and operator guidance aligned; change accepted
contracts, plans, and ADR semantics only through their amendment paths.
