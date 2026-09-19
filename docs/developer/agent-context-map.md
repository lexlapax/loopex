# Agent Context Map

This is the lazy-loaded routing map for development work. It points to the first
documents to read when the active plan and local code are not enough. Each
paired route starts with Concept and then identifies the exact Technical depth.
Replace founding-document pointers with nearer accepted decisions as they land,
and add code and test evidence pointers without changing the authority order in
`AGENTS.md`.

## How To Use

1. Read `AGENTS.md` first.
2. Read [docs/plans/README.md](../plans/README.md) for the checked-out
   revision's canonical milestone status.
3. Read the [development charter](development-charter.md#concept), following its
   [Technical depth](development-charter-technical.md#technical-depth) when the
   task changes documentation, review form, or public code documentation.
4. Read the accepted active Concept plan, its Technical depth, and gate contract
   when they exist, plus constraining accepted ADR pairs.
5. Use the table below to read the relevant Concept anchor first and then the
   exact Technical depth anchor. Follow the authority order in `AGENTS.md`;
   treat code and tests as evidence, and flag stale or conflicting prose.
6. Flag any pair conflict; neither side silently wins.

Either member of the vision pair may be edited only under an explicit current
maintainer or developer request naming a vision change; see `AGENTS.md` for the
separate decision duty when a founding boundary or invariant would change.

## Area Routing

| Area | Concept | Technical depth | Notes |
| --- | --- | --- | --- |
| Doctrine, product definition, principles | [Product definition](../vision.md#concept-vision-product-definition) and [principles](../vision.md#concept-vision-product-principles) | [Product boundaries](../vision-technical.md#technical-vision-product-definition) and [principle mechanics](../vision-technical.md#technical-vision-product-principles) | “Runtime is the framework”; what Loopex is and is not. |
| Domain language | [Domain language](../vision.md#concept-vision-domain-language) | [Exact terms](../vision-technical.md#technical-vision-domain-language) | Session/run/turn, operation/attempt/epoch/fence, journal/public event, brain/hand. |
| Ownership and trust boundaries | [Ownership](../vision.md#concept-vision-ownership-trust) | [Ownership mechanics](../vision-technical.md#technical-vision-ownership-trust) | Loopex/host/executor ownership, policy decisions, and grants. |
| Stack, dependency budget, runtime floor | [Dependency doctrine](../vision.md#concept-vision-dependency-doctrine) and [ADR 0002 decision](../adr/0002-bootstrap-runtime-floor.md#concept-adr-0002-decision) | [Exact dependency constraints](../vision-technical.md#technical-vision-dependency-doctrine) and [ADR 0002 mechanics](../adr/0002-bootstrap-runtime-floor-technical.md#technical-adr-0002-decision) | Protocol/Core/Runtime, one admitted `:telemetry` dependency in core, bootstrap floor. Proposed [ADR 0026](../adr/0026-development-floor-refresh.md#concept) owns the M4 floor-holder decision; proposed [ADR 0030](../adr/0030-observability-tracing-and-telemetry.md#concept) owns telemetry mechanics. Neither is accepted yet. |
| Debugging a runtime, tracing, telemetry | [Observability](observability.md#concept) | [Observability contracts and inventory](observability-technical.md#technical-depth) | Diagnose through a runtime-scoped trace session and the telemetry inventory rather than inserted printing: both are bounded, both redact content, and neither changes the code under observation. Operator levels, ceilings and events are in the [runbook](../operator/observability.md#concept); accepted [ADR 0030](../adr/0030-observability-tracing-and-telemetry.md#concept) fixes the emission inventory. |
| Serving a session over the wire | [App server protocol](app-server-protocol.md#concept) | [Protocol contract, records and limits](app-server-protocol-technical.md#technical-depth) | The experimental generation `loopex.session.v1-experimental`: sixteen methods, seven record families, fifteen error codes, the wire encodings and the exact limits. Accepted [ADR 0023](../adr/0023-experimental-public-session-protocol.md#concept) is the deciding authority; the operator [runbook](../operator/app-server.md#concept) covers launching it. |
| Runtime instances, supervision, reducer | [Runtime ownership](../vision.md#concept-vision-runtime-supervision) | [Supervision and reducer mechanics](../vision-technical.md#technical-vision-runtime-supervision) | Multi-instance supervision, pure reducer, bounded journal transaction; use the [M1 runtime and embedding guide](runtime-and-embedding.md#concept) for the implemented single-machine surface. |
| Transactions, operations, recovery, cancellation | [Recovery truth](../vision.md#concept-vision-recovery-truth) | [Transaction and recovery mechanics](../vision-technical.md#technical-vision-recovery-truth) | `commit_unknown`, operation lifecycle, reconciliation, outcome algebra. |
| Agent loop, queues, tool ordering | [Loop semantics](../vision.md#concept-vision-loop-semantics) | [Loop mechanics](../vision-technical.md#technical-vision-loop-semantics) | One run per session, input classes, ordering, and split payloads. |
| Public protocol, events, attachments | [Public protocol](../vision.md#concept-vision-public-protocol) | [Protocol mechanics](../vision-technical.md#technical-vision-public-protocol) | Stream planes, envelopes, attach behavior, and authority boundaries; the headless protocol proposal is [ADR 0023](../adr/0023-experimental-public-session-protocol.md#concept); [ADR 0024](../adr/0024-durable-interaction-lifecycle-and-host-policy-authority.md#concept) places durable interactions in M4 core before wire mapping. Read the [M4 pre-acceptance choices](#disposition-m4-preacceptance-contract-choices-2026-09-13); both ADRs remain Proposed prerequisites of the Open [`M4` plan](../plans/M4.md#concept) after M3 closure. |
| Journal, stores, branches, compaction, artifacts | [Sessions and storage](../vision.md#concept-vision-sessions-storage) | [Storage mechanics](../vision-technical.md#technical-vision-sessions-storage) | Recovery surfaces, private adapters, store decision, protection. [ADR 0028](../adr/0028-bounded-artifact-retrieval.md#concept) proposes M4 transfer limits; its [selected profile](#disposition-m4-preacceptance-contract-choices-2026-09-13) is not ADR acceptance. |
| Model boundary and continuation | [Model boundary](../vision.md#concept-vision-model-boundary) | [Model mechanics](../vision-technical.md#technical-vision-model-boundary) | Canonical types, `Loopex.LLM`, reference adapter and native sidecar. Accepted [ADR 0027](../adr/0027-provider-permit-retirement.md#concept) and its [retirement mechanics](../adr/0027-provider-permit-retirement-technical.md#technical-adr-0027-decision) govern M3 provider-attempt retention. |
| Context pipeline | [Model boundary](../vision.md#concept-vision-model-boundary) | [Context-pipeline mechanics](../vision-technical.md#technical-vision-model-boundary) | The sole seam for memory, retrieval, prompts, provenance, and receipts. |
| Tools and coding surface | [Tools](../vision.md#concept-vision-tools) | [Tool mechanics](../vision-technical.md#technical-vision-tools) | Seven-tool surface, budget, and non-authority of metadata. |
| Executors, brain/hand, distribution | [Executor protocol](../vision.md#concept-vision-executor-protocol) | [Executor mechanics](../vision-technical.md#technical-vision-executor-protocol) | Job/receipt protocol, trust classes, trusted gateways. |
| Trust, resources, sensitive data | [Sensitive data](../vision.md#concept-vision-sensitive-data) | [Trust mechanics](../vision-technical.md#technical-vision-sensitive-data) | Resource admission, tenancy, credentials and redaction. Project skills implement Accepted [ADR 0025](../adr/0025-resource-packs-and-skill-admission.md#concept); use [snapshot/command guidance](runtime-and-embedding.md#technical-embedding-resources) and [staging/replay guidance](agent-loop-and-tools.md#technical-loop-skills). |
| Extensions, generations, generated code | [Extensions](../vision.md#concept-vision-extensions) | [Extension mechanics](../vision-technical.md#technical-vision-extensions) | Package classes, quiescent activation, A→B→A rollback, promotion. |
| Embedded API, transports, clients, ACP | [API and transports](../vision.md#concept-vision-api-transports) | [Transport mechanics](../vision-technical.md#technical-vision-api-transports) | One semantic contract, JSONL RPC first, reference surfaces. |
| Hosts and wrappers | [Hosts](../vision.md#concept-vision-hosts) | [Host mechanics](../vision-technical.md#technical-vision-hosts) | Expected consumers, secured sample host, independent implementation. |
| Repository layout and ADR agenda | [Repository seed](../vision.md#concept-vision-repository-seed) | [Exact seed](../vision-technical.md#technical-vision-repository-seed) | Pair with the [ADR 0001 decision](../adr/0001-repository-and-application-layout.md#concept-adr-0001-decision) and its [technical mechanics](../adr/0001-repository-and-application-layout-technical.md#technical-adr-0001-decision). |
| Delivery shape and milestones | [Delivery strategy](../vision.md#concept-vision-delivery-strategy) and [roadmap](../roadmap.md#concept-roadmap-ladder) | [Delivery mechanics](../vision-technical.md#technical-vision-delivery-strategy) and [roadmap evidence](../roadmap-technical.md#technical-roadmap-ladder) | The [plans index](../plans/README.md) owns current status; an accepted plan pair is the commitment. |
| Serial barriers | [Ordering constraint](../vision.md#concept-vision-serial-barriers) | [Exact rejoin order](../vision-technical.md#technical-vision-serial-barriers) | A milestone may add barriers but cannot weaken the founding sequence. |
| Verification, invariants, budgets | [Verification](../vision.md#concept-vision-verification) | [Exact evidence](../vision-technical.md#technical-vision-verification) | Claim-proportional tests and scope-specific minimalism budgets. |
| Compatibility and release governance | [Compatibility](../vision.md#concept-vision-compatibility) | [Compatibility mechanics](../vision-technical.md#technical-vision-compatibility) | Versioned surfaces, 0.x labels, migrations, rollback, freezes. |
| Prior-system evidence | [Sources](../vision.md#concept-vision-sources) | [Source record](../vision-technical.md#technical-vision-sources) | Consulted sources are linked; independent implementation remains mandatory. |
| Development method and portable clients | [Development charter](development-charter.md#concept-portable-development) | [Portable enforcement](development-charter-technical.md#technical-portable-development) | Also read `AGENTS.md`, [DEVELOPMENT.md](../../DEVELOPMENT.md), retained [smoke evidence](agent-adapter-smoke.md), and repository commands. |

## Test Quick Reference

Product tests run with `mix test` from the repository root. Repository checks
are Mix tasks: `mix loopex.deps_budget`, `loopex.core_only`, `loopex.matrix`,
`loopex.format_scope`, `loopex.version_train`, `loopex.docs_check`,
`loopex.hook_registration`, and `loopex.self_hosting`.
`bash scripts/check-bootstrap.sh` runs the bootstrap aggregate.
`bash scripts/check-m0-gate.sh`, `/bin/bash -p scripts/check-m1-gate.sh`,
`bash scripts/check-m2-gate.sh`, and `bash scripts/check-m3-gate.sh` run the
Closed gates. The M3 gate includes its M0–M2 predecessor aggregate.
`bash scripts/check-m4-gate.sh` runs the Open M4 gate, which must be red for
its declared missing behavior while every Closed gate stays green.
After ADR 0026's floor-holder sequence and before M4 acceptance,
`elixir -r scripts/check-m4-fixtures.exs -e 'Loopex.M4FixtureCheck.run!()'`
and `elixir scripts/check_m4_fixtures_test.exs` check the bound schema and
vectors. They do not prove client or server conformance.

Product tests run against a temporary `LOOPEX_HOME`; the
affected conformance suites (`conformance/`) run for any adapter or behaviour
change; property tests own reducer/replay claims; fault injection owns
durable-transition claims. Real-provider runs are a tagged, explicitly invoked
lane — never part of the default suite.

M3's implementation used focused checks under the reviewed
[end-only full-gate cadence](#override-disposition-m3-implementation-gate-cadence-2026-09-10),
with complete M0–M3 evidence at its final candidate. Other milestones follow
[AGENTS.md](../../AGENTS.md#milestones-and-gates) and their accepted plan.
Under the
[reviewed M3 preparation-rule ratification](#override-disposition-m3-incremental-witness-ratification-2026-09-10),
acceptance binds clauses, witness identities, runnable commands and a real
opening red; future test bodies grow with implementation. The closure command
must reject missing witnesses and unavailable evidence. Focused results never
substitute for required acceptance-base or closure evidence.

For M3's recorded plan acceptance only, the independently reviewed
[acceptance aggregate override](#override-disposition-m3-acceptance-aggregate-2026-09-10)
replaces the new acceptance-base M0–M2 aggregate with the exact-candidate
validation listed in that disposition. It does not change later aggregate
obligations or the generic rule for another milestone. The later implementation
cadence disposition above names the separate replacement timing.

An inherited test inventory may be changed under a recorded, explicitly scoped
maintainer override. Follow [the canonical override rule](../../AGENTS.md#maintainer-override),
not a new approval loop inferred from an old selector name. Preserve historical
records and unchanged guarantees. A bound artifact still needs a validated
replacement binding if the approved change reaches its bytes. The
[reviewed M3 CLI ratification](#override-disposition-m3-cli-extension-ratification-2026-09-10)
is the current example: the test file is not digest-bound, so no gate-generation
transaction is needed for the approved assertion change.

## Development Client Guidance

- `scripts/check-agent-bootstrap.sh`, `scripts/check-gitignore.sh`,
  `scripts/check-commit-messages.sh`, `scripts/check-repo-hygiene.sh`, and
  `scripts/check-status.sh` define "bootstrap green" behind the provider-neutral aggregate
  `scripts/check-bootstrap.sh`. They run from a clean checkout with the
  toolchain in [DEVELOPMENT.md](../../DEVELOPMENT.md); hosted CI may invoke only
  the aggregate as a replaceable thin wrapper.
- Maintainer decision (explicit bootstrap task, 2026-08-15): the exact-SHA,
  repository-owned local aggregate is mandatory evidence; hosted CI is
  supplementary for every development milestone. Only separately authorized
  release evidence may require a hosted provider; gate-locked real-provider,
  store, and executor lanes remain independent of hosted CI. A hosted-required
  default was rejected because it would make an open-source checkout depend on
  one provider; removing the thin hosted mirror was rejected because it remains
  useful supplementary signal. Existing GitHub automation therefore stays
  replaceable, forks need no GitHub tooling to develop, and a later material
  change requires a new option-and-implication packet and maintainer approval.
- Maintainer decision (2026-08-15), **carried out 2026-08-17**: Python 3.11 and
  `jq` were temporary seed/M0 bridges. They are now gone — repository checks run
  on Elixir standard-library and Mix entrypoints, the tested client hooks call
  them, and the aggregate completes with every interpreter shadowed. What the
  replacement dropped is recorded in
  [the self-hosting evidence](../evidence/M0-self-hosting.md) rather than left
  implicit, and three of those eight items change what the repository can detect or
  where it can run, so a reader should weigh them there. The decision as
  originally recorded read: repository checks migrate to Elixir
  standard-library or Mix entrypoints and tested client hooks migrate to them.
  Removing a tested hook instead requires the accepted M0 plan to disposition
  that behavior explicitly with equivalent protection or an explicitly
  accepted loss. Adapter behavior is proved with `jq` absent; both prerequisites
  then disappear. The enduring development baseline is Git, shell/POSIX tools,
  and the accepted Elixir/OTP toolchain.
- Client-adapter loading is proven, not assumed. Retain versions, source SHA,
  adapter digests, prompts, observed instruction/role/skill loading, and
  permission results in [agent-adapter-smoke.md](agent-adapter-smoke.md). Rerun
  relevant smokes whenever `.codex/`, `.claude/`, or `.agents/skills` bytes
  change.
- Independent review requires an effectively read-only environment. A client
  role default is not proof: if the live parent or client overrides it with a
  writable profile, the reviewer reports unavailable and stops. Retain both a
  positive read-only smoke and a negative fail-closed smoke where supported.
  Required inspection checks must also execute in that environment. The
  bridge-period rule that kept Python assertions in tracked scripts is retired
  with the bridge: assertions now live in Mix tasks and their tests, which need a
  writable build directory, so a read-only reviewer runs the gate runner's
  inspection prefix or directs the build into an explicit isolated task root.
- For development-client ecosystem changes, check current primary vendor docs
  or release notes plus installed behavior, derive shared consequences first,
  and retain version-specific facts here. Material changes
  to development behavior require an option-and-implication packet and
  maintainer approval before adapter edits.
- Maintainer decision (2026-09-14): development work keeps the model-neutral
  efficient, balanced, and deep capability classes in the
  [development charter](development-charter.md#concept-capability-follows-consequence)
  and its [technical routing](development-charter-technical.md#technical-capability-follows-consequence).
  After Claude Fable 5.1 and GPT-6 Astra were released, the maintainer
  directed that the client model-use rules in `.claude/` and `.codex/` be
  rebuilt on current vendor documentation. The repository still pins no
  model in either adapter and the roles still inherit the caller's model, so
  the rebuild is this dated mapping, the role effort settings, and the
  [adapter smoke record](agent-adapter-smoke.md). It supersedes the
  2026-08-15 mapping retained below it. Current recommended mappings,
  checked against primary vendor documentation on 2026-09-14:

  | Class | Codex | Claude Code | Effort |
  | --- | --- | --- | --- |
  | Efficient | `gpt-5.6-luna` | `haiku` (Claude Haiku 4.5) | Codex: low for scans, extraction and log triage; medium when completeness needs judgment. Claude Haiku 4.5 accepts no effort setting, so the class alone routes it |
  | Balanced | `gpt-5.6-terra` | `sonnet` (Claude Sonnet 5) | medium by default; high for multi-boundary integration or debugging |
  | Deep | `gpt-5.6-sol` | `opus` (Claude Opus 5) | high; xhigh for long-running agentic implementation or a rejoin audit |
  | Deepest, separately verified | `gpt-6-astra` | `fable` (Claude Fable 5.1) | high; max only where correctness outweighs cost, such as exact-SHA acceptance or closure review, gate design, or an ADR decision with conflicting evidence |

  The adaptive rules that go with the table: effort is the first lever and
  model the second, so raise effort within the current class before
  escalating the class; escalate on conflicting evidence, an ambiguous
  boundary, or repeated focused failure, and return settled follow-through to
  the efficient class; a delegated subagent runs no deeper than its
  delegation names, so in Claude Code the caller passes the alias per
  delegation, and because the repository role files pin no effort, a Claude
  Code subagent runs at its caller's effort: a caller at max lifts the
  reviewer it spawns, and a caller wanting a cheaper child lowers the class
  through the alias; in Codex each role's `model_reasoning_effort` applies
  unless the spawn override passes another; a deep or deepest parent never
  implicitly promotes a child, so the caller states the class at the call
  site;
  fan-out uses a lead of a higher class over workers of a lower class only
  when there is bulk to hand off; and both vendors state that the deepest
  models at low effort often match a smaller model at high effort, so a
  measured comparison may replace an escalation. Availability is checked,
  never assumed: Claude Fable 5.1 needs Claude Code 2.1.257 or later, appears
  in the model picker only when the server reports it for the organization,
  and may bill usage credits with a consent prompt; GPT-6 Astra needs
  codex-cli 0.153.0 or later, so the 0.147.0 client installed on 2026-09-14
  cannot select it and Astra is unavailable evidence there until the client
  is upgraded; Claude Mythos 5.1 is invitation-only and belongs to no mapping;
  the built-in Claude Code Explore agent is capped at Opus by the client. The
  mapping is a dated adapter recommendation, not project authority or a
  repository model pin. Class labels and structural checks are routing
  metadata, not capability proof. Use a separate direct invocation when
  named-role delegation is unavailable. A stronger profile may perform
  lower-class work, while missing required deep capability or effective
  read-only review is unavailable evidence. Task-shaped smoke evidence records
  the effective model and effort when observable. Primary references checked
  for this mapping are the
  [Claude models overview](https://platform.claude.com/docs/en/about-claude/models/overview),
  [choosing a model](https://platform.claude.com/docs/en/about-claude/models/choosing-a-model),
  [effort guidance](https://platform.claude.com/docs/en/build-with-claude/effort),
  [Claude Code subagents](https://code.claude.com/docs/en/sub-agents) and
  [model configuration](https://code.claude.com/docs/en/model-config),
  [OpenAI's model index](https://developers.openai.com/api/docs/models), the
  [GPT-6 Astra model card](https://developers.openai.com/api/docs/models/gpt-6-astra),
  the [reasoning guide](https://developers.openai.com/api/docs/guides/reasoning),
  and the [Codex models](https://developers.openai.com/codex/models) and
  [subagents](https://developers.openai.com/codex/subagents) pages.
  Recheck primary documentation, installed catalogs, representative task
  behavior, and smoke evidence when a client version, model family, catalog,
  profile, or relevant adapter byte changes.
- Maintainer decision (2026-08-15), superseded by the 2026-09-14 mapping
  above: the same three classes mapped to Codex Luna/medium, Terra/high and
  Sol/high and to Claude Haiku/medium, Sonnet/high and Opus/high, with a
  separately verified deeper setting reserved for unusually demanding work.
  Its references were
  [OpenAI's model guidance](https://developers.openai.com/api/docs/models) and
  [Claude Code model configuration](https://code.claude.com/docs/en/model-config).
- Current Codex compatibility: codex-cli 0.147.0 proves scoped-trust project
  instruction and direct skill discovery. In the current exact-source
  non-interactive smoke, named project-role delegation could not bind a child;
  that run is unavailable evidence, not a role-loading pass. The role entries
  remain statically validated configuration. `[features] multi_agent_v2` stays
  in `.codex/config.toml`; removal requires a separately reviewed compatibility
  smoke. This limitation is nonblocking because required review depends on a
  separate effectively read-only invocation, not a named client role. On that
  client, `--ignore-user-config` also
  removes persisted project trust: an isolated smoke must explicitly trust
  only its exact checkout through the invocation's `projects` table, or project
  profiles and skills are unavailable evidence.
  The `gate` and `close-milestone` skills require explicit invocation: Claude
  consumes `disable-model-invocation: true`, while Codex consumes
  `agents/openai.yaml` policy `allow_implicit_invocation: false`. Enforcement
  scripts use stock `grep -E`, never ripgrep.
- Current invocation mapping. Opening and closing a milestone are maintainer
  keystrokes because no actor may open or close its own gate. In Claude Code the
  maintainer types `/gate <milestone>` and `/close-milestone <milestone>`; in
  Codex the same skills are invoked explicitly rather than implicitly. Always
  name the milestone — an unnamed invocation cannot resolve which one is
  intended. Every other verb in
  [Directing the Work](../plans/README.md) is ordinary language in both clients
  and needs no shortcut. This row records client keystrokes only; the verbs and
  their authority live in the plans register and survive any client change.
- Mix-scaffold rider: [ADR 0001](../adr/0001-repository-and-application-layout.md#concept-adr-0001-decision)
  and its [technical companion](../adr/0001-repository-and-application-layout-technical.md#technical-adr-0001-decision)
  make the first accepted scaffold create
  a repository-owned dependency-budget/direction command and turn
  `.claude/hooks/deps-budget.sh` into a thin caller. Until the M0 gate creates
  and proves that command, the current Claude-only hook is early feedback and
  must not be described as repository enforcement.

## Version-Specific Technical Guidance

This section holds temporary technical routing while a milestone is planned and
implemented. It never owns milestone status; read the
[plans index](../plans/README.md) for that. Clear in-flight notes at milestone
closeout, including for milestones such as M0 that produce no release.

Revision-scoped milestone status is deliberately not repeated here.

## Retained Authority Dispositions

Durable records of explicit maintainer decisions that governance records cite.
Each entry is immutable once written; a later decision is a new entry.

<a id="disposition-founding-adrs-2026-08-15"></a>
### Founding ADR acceptance — 2026-08-15

The maintainer explicitly accepted
[ADR 0001](../adr/0001-repository-and-application-layout.md#concept),
[ADR 0002](../adr/0002-bootstrap-runtime-floor.md#concept), and
[ADR 0003](../adr/0003-extension-contract-boundary.md#concept) as the Proposed
pairs existing at candidate `c703a65b665a5e64159e98833c63d29ff521cd2b`, in a
direct instruction to accept all three. Acceptance binds both files of each pair
as they existed at that candidate; the digests are recorded in each Concept
file's governance record.

Accepting ADR 0001 and ADR 0002 satisfies the M0 prerequisite guard. It does not
open M0, which still requires an explicit gate-first instruction. ADR 0003
blocked nothing and unblocks nothing.

This record is written before the administrative acceptance commit so that the
pointer resolves to already-integrated bytes. It is the maintainer's disposition
evidence, not an independent review: the transition itself still requires the
read-only exact-diff review the plans register mandates.

<a id="disposition-m0-acceptance-2026-08-17"></a>
### M0 plan pair and gate acceptance — 2026-08-17

The maintainer explicitly accepted the `M0` plan pair and its locked gate as they
exist at candidate `9418ac8011528da39730a577874f300b8075dbcc`, in a direct
one-word instruction to accept. Acceptance binds the marked Concept envelope, the
marked Technical depth envelope, and the gate file's canonical text; the digests
are recorded in the Concept plan's governance record. Conforming workstream
decomposition, progress rows, resolved outcome state, and evidence links sit
outside both envelopes and may change without amendment.

The prerequisite guard was satisfied before this disposition:
[ADR 0001](../adr/0001-repository-and-application-layout.md#concept) and
[ADR 0002](../adr/0002-bootstrap-runtime-floor.md#concept) carry recorded
acceptance, as does [ADR 0003](../adr/0003-extension-contract-boundary.md#concept),
which the plan also names as a prerequisite.

**Review state at acceptance, recorded because it is not the ordinary case.** The
gate candidate went through five independent read-only review rounds. The last
recorded verdict is REJECT, issued against candidate
`5f4811cac90adf76615df4d2fd2782b58458c589`, the parent of the accepted candidate.
The accepted candidate `9418ac8` fixes the five findings from that verdict and
carries no independent review verdict of its own. The maintainer accepted with
that state known, which is the governing authority; this record exists so the
gap is durable rather than inferred from commit order. Two consequences follow
and neither is waived: the pre-integration read-only exact-diff review of the
acceptance transition against the bound candidate is still required before
`m0` reaches `main`, and closure still requires independent review of the closure
candidate, which no earlier round can supply.

The accepted gate names its own residual limits rather than claiming coverage it
does not have — search-path mutation through indirection, and interpreter
launchers outside its enumerable set. Those limits are part of what was accepted,
and closure review owns them.

<a id="disposition-m0-amendment-1-2026-08-17"></a>
#### Amendment 1 — 2026-08-17

The maintainer accepted [Amendment 1](../plans/M0-gate.md#amendment-1) to the
locked gate, in a direct instruction to proceed after being shown the defect and
the recommendation. The amendment fixes ExUnit summary parsing in the bound runner
so both locked pairs are read; the gate as accepted parsed only the floor pair's
format, which made it unsatisfiable on its own current pair.

Scope is the parsing helpers and the Protected Tests description. No locked
command, selector, minimum executed count, locked test name, fixture, toolchain
pair, evidence class, or closure document changes.

Because the runner is a bound artifact, its digest is part of the gate digest, so
the acceptance record rebinds to candidate
`45994729ea50c8e388f681dacc4d3383926ec2d6`, which carries the amended bytes. The
original acceptance of candidate `9418ac8011528da39730a577874f300b8075dbcc`
remains in the Git history and in the record above; the amendment supersedes its
bound bytes only, not its authority or its scope.

<a id="disposition-m0-amendments-2-and-3-2026-08-17"></a>
#### Amendments 2 and 3 — accepted 2026-08-17

The maintainer accepted [Amendment 2](../plans/M0-gate.md#amendment-2) and
[Amendment 3](../plans/M0-gate.md#amendment-3) together, in a direct instruction
naming both after being shown what each contains, what it changes, and what
happens if either is rejected.

**Amendment 2** corrects the executed-count arithmetic for the floor toolchain
pair. It is load-bearing: without it, an unfiltered run of the real-provider file
reads as one executed test and outcome 7 fails on the floor lane for a parsing
error that does not exist. It makes the gate stricter.

**Amendment 3** changes no executable byte — 423 executable runner lines before
and after, identical with comments stripped. It corrects Amendment 1's disproved
explanation, which survived in two runner comment blocks above code that
contradicts it, and replaces Amendment 2's acceptance heading, which had claimed a
disposition that was never given.

Neither weakens anything, waives anything, or changes a locked command, selector,
minimum executed count, locked test name, fixture, toolchain pair, evidence class,
or closure document.

**Why this record reads the way it does.** Amendment 2 was first written claiming
acceptance under a standing instruction to proceed. That instruction predated the
amendment and did not name it, and an independent review was right to reject it:
an amended artifact cannot be its own authority evidence. The heading was then
left uncorrected on purpose, because correcting a digest-bound gate is itself an
amendment operation, and granting a generation to fix a line about lacking
authority would have repeated the error. Both corrections therefore arrive here,
under an instruction that names them.

The acceptance record rebinds to candidate
`cc88d0aab0e63446aabfdbc6ef6b7adf427bafca`, whose gate carries amendment
generation 3. The full chain, computed from the repository rather than recalled:

```text
cc88d0a  gen 3  binds 19a1a93
19a1a93  gen 2  binds 4599472
4599472  gen 1  binds 9418ac8
9418ac8  gen 0  empty governance — the original acceptance
```

An earlier version of this record omitted `19a1a93` entirely and assigned
`4599472` generation 2 instead of 1. An independent review caught it. The lesson
is narrow and worth keeping: a chain written from memory drifts from the chain the
checker walks, and only one of them is authoritative. Recompute it by walking
`| Acceptance |` and the gate's amendment anchors backwards from the bound
candidate; do not transcribe it from an earlier record.

One defect in the locked runner is knowingly left in place: its absence proof
reports any aggregate failure as `the aggregate still depends on python3 or jq`,
so an unrelated failure is misattributed to outcome 8. It was named to the
maintainer and not included in either amendment, so it stands until a future
disposition covers it.

<a id="disposition-m0-amendment-4-2026-08-20"></a>
#### Amendment 4 — accepted 2026-08-20

The maintainer accepted [Amendment 4](../plans/M0-gate.md#amendment-4) after
reading its two-file diff. It changes the bound runner's interpreter scan,
search-path mutation rule, credential redaction, and summary-field extraction. No
locked command, selector, minimum executed count, locked test name, fixture,
toolchain pair, evidence class, or closure document changes.

The four gaps shared one shape, and it is the shape worth remembering: **a check
written as an enumeration has an unbounded tail.** Five launchers were stubbed but
not scanned because the stub list and the scan alternation were written
separately; the search-path rule listed syntaxes and missed a quoted export and a
reading builtin; redaction listed nothing but treated the credential as a glob;
summary extraction treated a grep failure as an absence. Where an enumeration could
be replaced by a derivation — the scan generated from the stub list — it was. Where
it could be replaced by structure — a builtin makes a binding, an operator makes an
assignment — it was. What remains enumerated is now stated as such rather than
described as complete.

The acceptance record rebinds to candidate `cdcf10b0dd3707a509769980037b9a4a06a22bba`, whose gate carries
amendment generation 4. The chain from it is computed rather than transcribed:

```text
cdcf10b  gen 4  binds cc88d0a
cc88d0a  gen 3  binds 19a1a93
19a1a93  gen 2  binds 4599472
4599472  gen 1  binds 9418ac8
9418ac8  gen 0  empty governance — the original acceptance
```

<a id="disposition-m0-closure-2026-08-21"></a>
#### M0 closure — accepted 2026-08-21

The maintainer closed `M0` at `d4d8b4d6fe8fd83eab41a0c3f1aaf6a2254d00c3`, having
approved the merge to `main` and then stated the closure decision explicitly. The
candidate was merged fast-forward with both locked lanes green on `main` after the
merge rather than only on the branch.

What the maintainer accepted, stated plainly so the record is not read as more
than it is:

* Ten outcomes proved, with the gate green on both locked pairs at the closure
  candidate and the acceptance-bound Concept, Technical depth, and gate digests
  unchanged since acceptance.
* Four recorded limitations on outcome 4 — anything across hosts, processes that
  disagree about the temporary directory, tampering with the sentinel directly,
  and durability of the truncation across power loss.
* One accepted deferral: sentinel read and mutation remain separable in
  `Loopex.Journal`, and store-level owner-epoch fencing moves to M1 with the store
  port.
* No independent review approved this exact SHA. Eight review rounds each rejected
  the candidate they saw, and the defects they found were real; the maintainer
  closed on the mechanical state and the retained evidence rather than on a
  clean review verdict. That is a maintainer judgment, recorded here because a
  reader of this closure should know it was made.

Outcome 3's evidence check was rewritten seven times during this milestone, each
version narrowing a hand-written approximation of how Markdown renders, and each
narrowing evaded. It was replaced with a verbatim fenced record and a closed
printable-ASCII domain. The lesson worth carrying to M1 is not about Markdown: a
check that compares against a model of another system will be wrong wherever the
model is, and the fix is to remove the model rather than refine it.

<a id="disposition-m0-amendment-5-2026-08-20"></a>
#### Amendment 5 — accepted 2026-08-20

The maintainer accepted [Amendment 5](../plans/M0-gate.md#amendment-5). A loop over
the search-path variable binds it with no operator on the line, so it matched
neither scan and the loop body reached a real interpreter while the absence lane
reported success. `for` and `select` join the binding constructs; ten forms are
caught and six near-misses are not, including a loop that only reads the variable.

One file changed. No locked command, selector, minimum executed count, locked test
name, fixture, toolchain pair, evidence class, or closure document moved.

**Five amendments, and the pattern is worth recording rather than repeating.** Each
one narrowed a check that had previously been described as complete: Amendment 1
parsed one toolchain's test summary, 2 got that toolchain's arithmetic wrong, 3
corrected a self-certified acceptance, 4 replaced four enumerations with
derivations and structure, and 5 showed that structural rule was still one category
short. The lesson generalises past this milestone: **a check written as an
enumeration has an unbounded tail, and calling it complete is a claim the next
reviewer disproves.** Where an enumeration can become a derivation or a structural
rule it should, and what stays enumerated should say so.

The gate now states its residual instead of claiming coverage: a textual scan of
shell cannot be proved exhaustive, indirection through a nameref, `eval`, or a
computed name leaves no token to match, and no containment available in the
development baseline closes it.

The acceptance record rebinds to candidate `3d59d001fc4526a54651e847e3e3a521881de297`, whose gate carries
amendment generation 5. The chain, computed from the repository:

```text
3d59d00  gen 5  binds cdcf10b
cdcf10b  gen 4  binds cc88d0a
cc88d0a  gen 3  binds 19a1a93
19a1a93  gen 2  binds 4599472
4599472  gen 1  binds 9418ac8
9418ac8  gen 0  empty governance — the original acceptance
```

<a id="disposition-m1-prerequisite-adrs-2026-08-21"></a>
### M1 prerequisite ADR acceptance — 2026-08-21

The maintainer explicitly accepted
[ADR 0006](../adr/0006-store-transaction-and-owner-epoch.md#concept) and
[ADR 0007](../adr/0007-local-executor-grant-job-receipt.md#concept) as the
Proposed pairs existing at candidate
`58281e34cd6233d1223579af55710642909f5a1f`, in a direct instruction to accept
both after receiving the exact candidate and four binding digests. Acceptance
binds both files of each pair as they existed at that candidate; the digests are
recorded in each Concept file's governance record.

These acceptances settle M1's store-transaction and executor-grant
prerequisites. They do not accept the rejected M1 plan pair or gate, authorize
product implementation, or imply that a revised M1 candidate exists. The next
transition is to create that revised plan-pair and gate candidate and have the
exact candidate independently reviewed before any acceptance decision.

This record is written before the administrative acceptance commit so that the
pointer resolves to already-integrated bytes. It is the maintainer's disposition
evidence, not an independent review: the transition itself still requires the
read-only exact-diff review the plans register mandates.

<a id="disposition-m1-plan-acceptance-2026-08-22"></a>
### M1 plan and gate acceptance — 2026-08-22

The maintainer explicitly accepted the `M1` plan pair and gate at candidate
`2f9559c6f638e813ce6ef5464c826ebc5f049af9` after receiving an independent
exact-candidate APPROVE verdict with no findings and the three binding digests.
Acceptance binds the Concept envelope at
`sha256:dad88ff975fd5f9a418a279c58f321d41b92cc52842775465daac190eb0bcf62`,
the Technical depth envelope at
`sha256:2373d96dfa6c397617675c496bb0f9616d991f03f36cb16482631aa1db59bf6c`,
and the gate at
`sha256:d7d0b3263e9d158cf798ccfd089cccf540c7a45e04e21a8ee4ec0f14254c7b9a`.

This disposition authorizes implementation only inside the eight accepted
outcomes and three named product boundaries. It does not itself disposition the
separate development-lifecycle question of whether an accepted, deliberately red
opening checkpoint may integrate to `main`; the maintainer requested that rule be
changed, and that material project-state decision remains a distinct governed
change rather than being inferred from plan acceptance.

This record is the maintainer's disposition evidence, not the independent
review. The administrative acceptance transition still changes only the empty
plan governance row, the plans register and capsule, and the root summary, and
it still requires its exact-diff review before integration.

<a id="disposition-governance-acceptance-integration-2026-08-22"></a>
### Governance-only acceptance integration — 2026-08-22

The maintainer explicitly approved governance-only Acceptance integration and
rejected partial implementation integration. Once the exact administrative
transition and the complete base-to-transition surface are independently
reviewed, the accepted plan/gate machinery, governance, derived status and
documentation, and portable enforcement may integrate to `main` while the exact
accepted opening gate remains red. No milestone product implementation byte may
integrate before separately approved closure, and the designated delivery branch
remains live because it owns that unintegrated work.

The maintainer also explicitly approved the generic successor rule: after the
current delivery milestone's governance checkpoint is integrated, exactly one
anticipated next milestone may become `Open` on its own branch for mutable
plan/gate construction and review. The current milestone remains the sole
implementation authority and remains `Accepted` in the lookahead branch;
`In progress` plus `Open` and `In review` plus `Open` are not authorized. The
successor cannot be accepted, integrated, or implemented until its predecessor
is Closed and integrated; it must then absorb that exact product base, re-prove
inherited gates green and its own distinct red, and receive a fresh exact-SHA
review. A second lookahead is not authorized.

This disposition authorizes the lifecycle policy but does not accept arbitrary
bytes that implement it. Because M1's accepted Migration and Rollback commitment
previously forbade the merge, M1 Amendment 1 must still receive independent
exact-candidate review and explicit binding acceptance before its governance
transition may integrate.

<a id="disposition-m1-amendments-1-and-2-2026-08-22"></a>
### M1 Amendments 1 and 2 acceptance — 2026-08-22

The maintainer explicitly accepted the `M1` amendment proposal at candidate
`83c4bfb11c09f2f54417aa2d64e6bf84958adefe` after receiving an independent
exact-candidate APPROVE verdict with no findings. Acceptance binds the unchanged
Concept envelope at
`sha256:dad88ff975fd5f9a418a279c58f321d41b92cc52842775465daac190eb0bcf62`,
the amended Technical depth envelope at
`sha256:163275593815b801ca0dd13e4b34f57cd426134ee1354695393fae6fa7b8a73b`,
and the amended gate at
`sha256:0954a5f7b492b6fe777a4a305df7da6d1cc5edb78716a1d24f98e3b87fce5c37`.

This disposition accepts the generic governance-only integration and one-gate
lookahead policy, the versioned strict proposal-to-rebind amendment transaction,
and its closed-history migration boundary as implemented by that exact
candidate. It authorizes the direct administrative rebind and governance-only
merge to `main`; it does not authorize M1 product implementation.

<a id="disposition-adr-0008-acceptance-2026-08-22"></a>
### ADR 0008 acceptance — 2026-08-22

The maintainer explicitly accepted
[ADR 0008](../adr/0008-owner-succession-recovery-and-runtime-placement.md#concept)
as the Proposed pair existing at candidate
`720b7e9007b580dd36d6592a3f22f3b6603a87e6` after receiving an independent
exact-candidate APPROVE verdict with no findings and the two binding digests.
Acceptance binds the Concept file at
`sha256:72f93bbf3fad9bc9ba88a9c8edced02355c04b2add2ccd62f01bc9658cfc047c`
and the Technical depth file at
`sha256:3ec1e35596a10890650752f04436b43168ce2d2724dd9bb2a336d85b3faddd4c`.

This acceptance settles the private durable succession-attempt index and M1's
active-passive runtime-placement prerequisite. It authorizes revising Workstream
A inside the accepted M1 envelope and then rejoining Workstream B. It does not
amend M1, weaken its gate, authorize active-active placement, authorize a merge
to `main`, or authorize a release.

This record is the maintainer's disposition evidence, not the independent
review. The administrative acceptance transition still changes only the ADR
status and governance row plus the plans register's derived status capsule, and
it still requires an independent read-only exact-diff review.

<a id="disposition-m1-amendment-3-2026-08-22"></a>
### M1 Amendment 3 acceptance — 2026-08-22

The maintainer explicitly accepted the `M1` Amendment 3 proposal at candidate
`267a771dfa888a30a6f5a303588337067415c5cb` after receiving an independent
exact-candidate APPROVE verdict with no findings. Acceptance binds the unchanged
Concept envelope at
`sha256:dad88ff975fd5f9a418a279c58f321d41b92cc52842775465daac190eb0bcf62`,
the unchanged Technical depth envelope at
`sha256:163275593815b801ca0dd13e4b34f57cd426134ee1354695393fae6fa7b8a73b`,
and the amended gate at
`sha256:64f581a1af94bc646b2a4c19a3e8c5d539a1f973643b2ed207adcd745400afa9`.

This acceptance preserves the historical opening-red proof through an isolated
no-hardlink clone while allowing the current implementation tree to advance to
later protected selectors. It changes no M1 product outcome, scope, command,
selector, minimum, evidence class, closure document, or public obligation. It
authorizes this direct administrative rebind; it does not authorize a merge to
`main`, closure, release, or any gate weakening.

<a id="disposition-m1-amendment-4-2026-08-22"></a>
### M1 Amendment 4 acceptance — 2026-08-22

The maintainer explicitly accepted the `M1` Amendment 4 proposal at candidate
`771d847ab5b186f4552f294f78ffb63e5c7fca72` after receiving an independent
exact-candidate APPROVE verdict with no findings. Acceptance binds the unchanged
Concept envelope at
`sha256:dad88ff975fd5f9a418a279c58f321d41b92cc52842775465daac190eb0bcf62`,
the unchanged Technical depth envelope at
`sha256:163275593815b801ca0dd13e4b34f57cd426134ee1354695393fae6fa7b8a73b`,
and the amended gate at
`sha256:618ab2256db05f689d7513bccde5dafa5e22f59b6d14880ddcdd6876dec8c482`.

This acceptance makes the exact seven documentation-obligation categories a
standing active-and-future milestone-gate contract, with Closed M0 as the sole
migration exception. It binds M1 to all seven named documentation outcomes and
accepts the generic portable enforcement that rejects hidden, malformed,
noncanonical, colliding, or impossible declarations. It authorizes this direct
administrative rebind and continued M1 implementation; it does not authorize a
merge to `main`, closure, release, or any gate weakening.

<a id="disposition-m1-amendment-5-2026-08-23"></a>
### M1 Amendment 5 acceptance — 2026-08-23

The maintainer's standing explicit acceptance applies to the `M1` Amendment 5
proposal at candidate `80a9bc60e44be3e8507314c7da6cda75944be885`
because its independently reviewed repair preserves Loopex's product-feature
and architecture zoom-out shape. The independent exact-candidate review
reported APPROVE with no findings. Acceptance binds the unchanged Concept
envelope at
`sha256:dad88ff975fd5f9a418a279c58f321d41b92cc52842775465daac190eb0bcf62`,
the unchanged Technical depth envelope at
`sha256:163275593815b801ca0dd13e4b34f57cd426134ee1354695393fae6fa7b8a73b`,
and the amended gate at
`sha256:9f56a94e2712baacd7b87a5b62833f79e6f4a23c38a946326d58ec1dbd86bb35`.

This acceptance makes the locked selector corpus consumable by the standalone
runner and admits OTP included applications only through the already accepted
source-derived dependency closure. It changes no M1 product outcome, scope,
public contract, command, selector identity, minimum, evidence class, or
closure obligation. It authorizes this direct administrative rebind and the
remaining M1 closure proof; it does not authorize a merge to `main`, closure,
release, or any gate weakening.

<a id="disposition-m1-amendment-6-2026-08-23"></a>
### M1 Amendment 6 acceptance — 2026-08-23

The maintainer's standing explicit acceptance applies to the `M1` Amendment 6
proposal at candidate `0ccda57f34ccaf5682987c3adc7d1638659e2f44`
because its independently reviewed portability repair preserves Loopex's
product-feature and architecture zoom-out shape. The independent exact-candidate
review reported APPROVE with no findings. Acceptance binds the unchanged Concept
envelope at
`sha256:dad88ff975fd5f9a418a279c58f321d41b92cc52842775465daac190eb0bcf62`,
the unchanged Technical depth envelope at
`sha256:163275593815b801ca0dd13e4b34f57cd426134ee1354695393fae6fa7b8a73b`,
and the amended gate at
`sha256:bfc61ad1441f997ad81dbb10bd44396a6c8912d2a996cba8c3a896ada0f4e58b`.

This acceptance makes the protected cross-VM receipt inspection portable to
the locked OTP 26 floor while retaining safe external-term decoding and every
recovery assertion. It changes no M1 product outcome, receipt schema, scope,
public contract, selector identity, role, minimum, exclusion, evidence class,
or closure obligation. It authorizes this direct administrative rebind and the
remaining M1 closure proof; it does not authorize a merge to `main`, closure,
release, or any gate weakening.

<a id="disposition-m1-gate-generation-7-2026-08-24"></a>
### M1 gate generation 7 acceptance — 2026-08-24

The maintainer explicitly accepted the `M1` gate generation 7 proposal at
candidate `cd19347dcb98495304f4d8854526035f18f108f6`. The
proposal was reviewed at that exact revision before acceptance.

Generation 7 rebinds exactly the two artifacts the accepted `M2` plan pair named
and no third: `apps/loopex/lib/mix/tasks/loopex.deps_budget.ex`, whose planned
inventory froze the repository at six applications with no `:composition` role,
and `apps/loopex/test/deps_budget_test.exs`, its adversarial corpus, whose
minimum rises from 25 to 28 for the three cases that prove the eight-application
inventory, the composition role's own rule, and the client rule that admits one
composition.

This acceptance is the separately approved baseline exception against a closed,
immutable gate, recorded on 2026-08-23 as
[`disposition-m1-gate-generation-exception-2026-08-23`](#disposition-m1-gate-generation-exception-2026-08-23),
being exercised for one specific proposal. That earlier approval authorised the
transaction; it approved no particular proposal, which is why this record exists
separately.

`M1`'s Acceptance and Closure rows are unchanged and remain byte-immutable.
Neither is made retroactively false: they record what was accepted and what was
reviewed and closed. Acceptance binds the amended gate at
`sha256:4b74e2c6df1217e955ae8757443049e1581bcff9f3ecdc22b10094ea9fabde5a`
through the append-only Gate Generations table in
[the M1 plan](../plans/M1.md), and adds no scope, changes no outcome, and reopens
no lifecycle state.

<a id="disposition-m1-gate-generation-8-2026-08-26"></a>
### M1 gate generation 8 acceptance — 2026-08-26

The maintainer explicitly accepted the `M1` gate generation 8 proposal at
candidate `3ddbf741c4175b5595920727645f2aae24ff4a73`. The proposal was reviewed
at that exact revision before acceptance.

Generation 8 rebinds exactly three artifacts and no fourth:
`scripts/m1-evidence-verifier.exs`, which asserted retained evidence against the
working tree as well as against the revision that evidence names;
`scripts/check-m1-gate.sh`, whose inline digest copies had drifted from the rows
the gate document binds; and `apps/loopex/test/m1_gate_evidence_test.exs`, the
verifier's adversarial corpus, whose case names, count, and minimum of ten are
unchanged.

This acceptance exercises the separately approved baseline exception against a
closed, immutable gate, recorded on 2026-08-23 as
[`disposition-m1-gate-generation-exception-2026-08-23`](#disposition-m1-gate-generation-exception-2026-08-23),
for one specific proposal. That earlier approval authorised the transaction and
approved no particular proposal, which is why this record exists separately.

`M1`'s Acceptance and Closure rows are unchanged and remain byte-immutable.
Neither is made retroactively false. Acceptance binds the amended gate at
`sha256:0076a8aa7602db0695a03ef12712e4bdf4d31098d8e71219c9f69e1298f852ee`
through the append-only Gate Generations table in
[the M1 plan](../plans/M1.md), and adds no scope, changes no outcome, and
reopens no lifecycle state.

**The reviewer's sandbox profile was waived for this review, and that waiver is
recorded here because it belongs to this acceptance.** On 2026-08-26 the
maintainer explicitly waived the requirement that this generation's independent
pre-integration review run under a wholly write-denied sandbox profile. The
reviewer's sandbox could permit writes, including isolated temporary roots for
executable checks and mutation experiments, and such a review could serve as the
transition evidence.

The waiver did not cover the reviewed checkout, which had to be untouched and
verified clean; the maintainer confirmed separately that this requirement stands
unchanged, so a review that modified what it reviewed would be void rather than
advisory. It concerns sandbox policy and never the integrity of the bytes under
review.

It was needed because six proposals were reviewed under this transaction and
every reviewer ran under a write-permitting profile, correctly self-declaring
advisory. Five substantive reviews, each of which found real defects, therefore
produced no usable transition evidence. The constraint was the profile, not the
reviews.

The accepted review was performed by Codex at exact
`3ddbf741c4175b5595920727645f2aae24ff4a73` under that waiver. It reported the
reviewed checkout untouched and clean, and the integrator independently
confirmed it: no tracked or staged change, every bound artifact matching its
row, and the gate document matching the digest generation 8 binds.

This waiver is specific to this generation's review and disposes of nothing
else. In particular it neither resolves nor bears on the unresolved
inherited-gate enforcement decision recorded in
[Amendment 8](../plans/M1-gate.md#amendment-8-inherited-gate-enforcement), which
remains owed before `M2` closes.

<a id="disposition-provider-recovery-proof-before-retry-2026-09-01"></a>
### Provider recovery requires proof before retry — 2026-09-01

The maintainer explicitly selected the conservative provider-recovery posture
on 2026-09-01: exact staged request bytes identify an operation but do not
authorize repeating an unsettled provider attempt. This is a recorded vision
decision, not an inference from implementation work.

**The principle.** A recovered open or otherwise unsettled provider attempt is
`dispatched_or_unknown` for accounting and is not sent again. Only durable exact
proof that transport was never invoked, or a future provider-specific
reconciliation result proving retry safe, may authorize a new attempt. Provider
ambiguity does not become executor `outcome_unknown`; it receives conservative
provider accounting and the run ends under its committed provider failure,
abort, or deadline truth.

**The evidence.** The existing recovery language made stable staged bytes serve
two different purposes: exact operation identity and permission to redispatch.
Those bytes cannot distinguish a crash before transport from a crash after the
provider accepted a possibly billed call, and M2 has no portable provider
reconciliation contract. A coordinator-side send after an ownership check also
leaves a handoff gap in which both owners can believe dispatch is theirs.

**The selected M2 mechanics.** Each provider attempt commits before dispatch.
Control validates current ownership and sends an exact one-use permit directly
to a permit-blocked model worker inside the same serialized operation. The
permit send is the provider-dispatch linearization point; later worker
consumption executes that already-linearized authorization and cannot create a
second authorization. This preserves ADR 0006's current-owner fence even if
ownership changes after the send and before the worker is scheduled. The
provider-attempt and recovery contract moves from the context-admission decision
into its own ADR. Its first record version allows exactly two total attempts for
one staged model operation: attempt one plus one retry, and attempt two is legal
only after durable exact `not_dispatched` settlement. Succession never resets
that allowance; changing it requires a new record version.

**Compatibility and migration.** No released protocol or package is widened.
`Loopex.LLM.complete/3` already admits term-shaped error detail. An adapter that
cannot provide exact pre-transport proof remains conforming, but its ambiguous
errors are non-retryable and conservatively accounted. The Control permit and
attempt records are private unreleased machinery. Existing development journals
do not migrate across the new record contract and fail closed if mixed.

**Accepted-decision impact.** The provider-attempt ADR must name the exact
clauses it partially supersedes in ADR 0010, ADR 0011, and ADR 0014. In
particular, ADR 0014's successor retry after model-owner loss becomes
non-redispatching conservative settlement unless exact `not_dispatched` proof
already exists. ADR 0006 is not superseded: its current-owner dispatch rule is
satisfied at Control's direct permit-send linearization point.

**Scope.** This record authorizes the paired vision change and the corresponding
ADR proposal only. It does not accept ADR 0015, ADR 0016, ADR 0017, or ADR 0018;
does not accept or rebind M2 Amendment 4; does not close M2; and does not
authorize integration, release, or publication.

<a id="disposition-bound-reached-vision-change-2026-08-23"></a>
### Vision terminal algebra gains `bound_reached` — 2026-08-23

The maintainer explicitly confirmed this disposition on 2026-08-23, in the
session that directed the change, after reading it in full. It is a recorded
authority decision, not an inferred one.

The maintainer decided that a run stopped by a bound its operator declared ends
in its own terminal outcome rather than as a failure, and directed that the
vision be changed to say so.

**The principle.** A run stopped by its turn ceiling, token budget, or
wall-clock deadline did what its operator configured it to do. Recording that as
`failed` put a configured stop and a genuine breakage in one bucket,
distinguishable only by reading a reason code, which is the distinction an
operator scanning a list of sessions needs most. The founding closed run
terminal algebra therefore gains one member, `bound_reached(bound, observed)`,
belonging to runs alone because only a run carries declared bounds.

**The evidence.** The defect was observable rather than theoretical: every
consumer grouping by terminal value, including any future protocol surface,
would have shown a bounded run finishing exactly as configured beside a run that
broke. The alternative considered and rejected was encoding it as a
`budget_exhausted` category of `failed`, which preserves the set at the cost of
that conflation.

**Compatibility impact.** The algebra is a founding boundary and the set stays
closed; a further member requires a decision of this same kind. Consumers and
any later protocol must carry a case for the new value.

**Migration path.** Empty. Nothing is released, no protocol carries a run
outcome, and no session record exists, so the widening migrates nothing.

**Scope.** This disposition records the vision change alone. It does not accept
ADR 0010, the `M2` plan pair, or the `M2` gate, and none of those accepts it.

<a id="disposition-m1-gate-generation-exception-2026-08-23"></a>
### M1 gate-generation baseline exception — 2026-08-23

The maintainer explicitly approved the baseline exception `M2` names but cannot
dispose: `M1`'s closed gate may gain one accepted gate generation under the
additive `amendment-transaction-v2`, so the two dependency-budget artifacts `M2`
must change can be rebound without rewriting either immutable authority row.

**Scope.** This authorizes exactly two bound artifacts —
`apps/loopex/lib/mix/tasks/loopex.deps_budget.ex` and
`apps/loopex/test/deps_budget_test.exs`. It authorizes no third artifact, no
change to `M1`'s Acceptance or Closure row, no lifecycle change, and no scope,
outcome, or evidence change to closed `M1`.

**What it does not waive.** Proposal `A` must still be one atomic revision
carrying the amended gate, its next numbered amendment section, the `v2` marker,
the pending generation row, and both rebound artifacts together; `A` must
receive its exact-SHA review; and the `A` to `R` review must still prove only
the allowed transition bytes changed. Approving the exception is not approving a
particular `A`.

**Why separately from `M2`.** The transaction is sound on its own evidence: it
preserves both authority rows byte-immutable, keeps every historical generation
enforced for the revisions it governed, exempts no `Closed` milestone from
artifact validation, and closes the substitution hole where an unreviewed
revision could be bound in place of the reviewed proposal. Holding it behind
correctable `M2` document defects would couple two independent decisions.

**Scope of this record.** It disposes the baseline exception alone. It does not
accept the `M2` plan pair, the `M2` gate, or ADRs 0009, 0010, or 0011.

<a id="disposition-m2-prerequisite-adrs-2026-08-24"></a>
### ADR 0009, ADR 0010, and ADR 0011 acceptance — 2026-08-24

The maintainer explicitly accepted
[ADR 0009](../adr/0009-tool-executor-and-grant-contracts.md#concept),
[ADR 0010](../adr/0010-provider-continuation-and-context-staging.md#concept), and
[ADR 0011](../adr/0011-session-input-algebra-and-streaming.md#concept) as the
Proposed pairs existing at candidate
`e318690b6cd0e845d6dce694e5be80dc47211d6c`, after independent review of that
exact candidate and the six binding digests. Acceptance binds each Concept file
and its Technical depth companion:

| Decision | Concept | Technical depth |
| --- | --- | --- |
| ADR 0009 | `sha256:e6998d26d19b3d89a0765dd5a08a758c49d50f6cae618a824e79f01725c57ab3` | `sha256:9716d528ddc0129b4897150fd3616aace0233b594c522db43cc84691b9317d5b` |
| ADR 0010 | `sha256:32cab87ba24ae499d5ed1f746c2c64a93cadaec0103b0dde1c17ab1722770518` | `sha256:35bce6b42bc88ae02ef7ca6592a257ee17f81e748784b7bdf074d2ff40727fe7` |
| ADR 0011 | `sha256:0705dc29298a63d6681317e9f7a672d1b32d8a97f2bff63c7d1cad43503f6a5b` | `sha256:b1b2e14fa035a2ba408ddcf68e729a90ca339e37c4dc7a373fe814797b0b56ea` |

These three decisions are `M2`'s declared prerequisites. Together they settle the
tool, executor, grant, and `Loopex.Policy` contracts; provider continuation,
committed run bounds, and project-resource context staging; and the session input
algebra with its streaming domains. Three corrections carried into the accepted
bytes and are part of what was accepted: a missing project-resource trust
decision withholds the block and journals a declined receipt rather than refusing
the run; `bound_reached` carries the bound and the observed value and nothing
else, with the declared limit and accounting source retained beside it as sibling
fields of the same terminal record; and reaching a bound makes no further
provider call, the wall-clock deadline excepted because it also bounds work
already in flight that a provider may already have billed.

`M2`'s streaming label is accepted at the strength it holds: the length-aware
canonical identity encoding is injective, and the 128-bit truncated SHA-256 label
over it is collision-resistant rather than injective. Nothing in the design
relies on the stronger property.

**Scope of this record.** It disposes the three prerequisite decisions alone. It
does not accept the `M2` plan pair or the `M2` gate, authorize product
implementation, authorize a merge to `main`, or authorize a release.

This record is the maintainer's disposition evidence, not the independent review.
The administrative acceptance transition changes only the three ADR status lines
and governance rows plus the plans register's derived status capsule.

<a id="disposition-m2-plan-acceptance-2026-08-24"></a>
### M2 plan pair and gate acceptance — 2026-08-24

The maintainer explicitly accepted the `M2`
[Concept plan](../plans/M2.md#concept), its
[Technical depth companion](../plans/M2-technical.md#technical-depth), and the
[locked gate](../plans/M2-gate.md) at candidate
`e318690b6cd0e845d6dce694e5be80dc47211d6c`, after independent review of that
exact candidate. Acceptance binds:

| Bound bytes | Digest |
| --- | --- |
| Normative Concept Envelope | `sha256:ec70503c1775c45d79f65512d6a80c82c1477b917de60268e11e2324eb2724bd` |
| Normative Technical Envelope | `sha256:7d7f0bb681c5e9755259cd438eb44c06430e0cb023b24741aa1bb2b9104dbc28` |
| Gate | `sha256:add77ffd2434c583bf84896d6cc9f823928dd5bad9dffb4c3f25f14a9ff64d93` |

`M2` is the foreground operator harness: eleven outcomes carrying multi-turn
conversation with committed history, streaming with domain-scoped loss
detection, the prompt/steer/follow-up/abort input algebra, four coding tools
against a real workspace, artifact spill and retrieval, a host `Loopex.Policy`
port with a working refusal, project-resource trust, truthful cancellation,
session listing and resume, the `loopex` command, and a shipped reference
composition. The gate is red for exactly the declared missing behaviour and
stays red until that work lands.

**Scope of this record.** It accepts the plan pair and the gate, and with them
the milestone's normative envelopes, evidence obligations, and locked
acceptance. It authorizes implementation inside those envelopes on the
designated `m2` branch. It authorizes the governance-only Acceptance checkpoint
to integrate to `main` with the gate still red and no milestone product bytes.
It does not close `M2`, weaken or amend the locked gate, authorize a merge of
product implementation, authorize a release, or open a successor milestone.

This record is the maintainer's disposition evidence, not the independent
review. The acceptance transition changes only the plan's governance row, this
record, and the three primary project records that carry derived status.

## Retained Seed Bootstrap Evidence

### Closed 2026-08-15

The maintainer explicitly authorized the final cross-client hardening pass and
its closure. The adapter-changing checkpoint is
`d1782a8d1c1c2c7f1399fe0aeebaa4a86b36f240`; the final technical candidate is
`cd8d2ae8f8347d051e6ea82fbdd5f19005e0c427`. Its repository aggregate, diff
check, and independent review are retained at that source scope in
[agent-adapter-smoke.md](agent-adapter-smoke.md); historical client-role
observations do not prove current role loading. This closure-record commit
changes evidence and bootstrap pointers only. Push
and any hosted-wrapper result are supplementary publication evidence, not
closure authority or a development dependency. Any client should derive the
closed state from these facts alone:

- The permanent Development Client Guidance above, retained smoke evidence,
  and the AGENTS.md durability paragraph (complete under the
  [repository-seed contract](../vision-technical.md#technical-vision-repository-seed)) are the
  candidate's shared memory; do not move these facts into client-only state.
- Current authorization and the next transition are recorded only in the
  [canonical plans status register](../plans/README.md).

<a id="disposition-m2-inherited-gate-enforcement-2026-08-27"></a>
### M2 inherited-gate enforcement — waived for M2, planned into M3 — 2026-08-27

The maintainer explicitly disposed the decision owed at
[M1 gate amendment 8](../plans/M1-gate.md#amendment-8-inherited-gate-enforcement),
adopting its recommendation: **Option C for `M2`, with Option B planned into
`M3` as accepted scope.**

**The constraint being waived.** `AGENTS.md` § Milestones and Gates requires that
existing gates stay green outside the bounded lookahead. No repository entrypoint
enforces it. `scripts/check-m2-gate.sh` re-proves the closed `M0` gate through two
retained matrix rows and never invokes `M1`'s gate, so an `M1` evidence,
environment-preflight, or orchestration check can go red while `M1`'s bound
artifacts and inherited selectors all still pass, and neither the status check nor
`M2`'s gate reports it.

**What the waiver admits.** For `M2` only, the requirement is met by retained
exact-SHA evidence of the complete `M1` gate green rather than by an executable
check. This is a gate-weakening decision and is non-delegable under `AGENTS.md`;
it was taken by the maintainer, not by any agent or artifact, and no artifact
appointed its own approver.

**The evidence it retains.** The complete `M1` gate was run at exact
`e513a38be3244ddbb0b15646839aed696f8d216c`, the same candidate `M2`'s three
toolchain lanes captured, and reported:

```text
M1 gate GREEN seed=12256 protected_executed=36
```

That run was possible for the first time since `cd19347` only because gate
generation 8 made the gate runnable at all. It was invoked by hand, which is
precisely the unenforced step this waiver admits.

**Why it was accepted.** `M2` neither planned nor budgeted this enforcement, and
landing novel enforcement machinery during closure is the kind of unplanned scope
a gate exists to refuse. Option A — amending `M2`'s locked gate to invoke `M1`'s —
was enumerated and remains available; its price is an `amendment-transaction-v1`
on an Accepted plan plus re-taking every real-provider evidence record, since the
gate's own bytes would change.

**What it does not dispose.** It grants nothing beyond `M2`. It does not weaken
any check, exempt any lane, move any threshold, or admit anything previously
refused. It changes no outcome, no envelope, and no lifecycle state. The rule
itself stands unchanged and unenforced, and the next milestone meets it again.

**The obligation it creates.** Option B — a governed closed-gate aggregate whose
own invocation is structurally enforced — is accepted scope for `M3` and must
appear in `M3`'s plan pair before that milestone is accepted. Amendment 8 records
why B fails unless its invocation is itself verified: an aggregate each successor
gate is merely expected to call reproduces this exact blind spot one level up.
`M3`'s form of B must therefore either place invocation in a repository entrypoint
that owns the rule, or make one mandatory call per successor gate structurally
verified by a check that fails when a milestone gate omits it. Without that, B is
Option C with more machinery.

<a id="disposition-m2-gate-amendment-1-2026-08-25"></a>
### M2 gate amendment 1 — closing the probe's standard input — 2026-08-25

The maintainer explicitly accepted amendment proposal `A` to the locked `M2`
gate at candidate `39049f02333271ac5e2e8f9971cec91ce8eff5ba`. This is the rebind revision of the
[amendment transaction](../plans/M2-gate.md#amendment-transaction-v1) that gate
declares: it records this disposition and rebinds Acceptance to exact `A`, and
changes no lifecycle state.

| Bound bytes | Digest |
| --- | --- |
| Gate | `sha256:9d61e16bf80f142d73d34fcc030fef910924b7d1353b873279f09e9d31789e19` |

**What was amended.** Two lines of `scripts/check-m2-gate.sh`. The runner reads
its provider credential from a bounded stdin frame after the opening probe,
because the probe is hoisted to the front so the declared red is an observation
rather than a file check. The probe's `mix compile` and its Elixir program both
inherited the runner's standard input, so a build tool that reads standard input
consumed the credential frame before the runner looked at it. Both invocations
now close standard input explicitly.

**Why it was accepted.** The failure it fixes is the worst shape a credential
check can take: a true refusal about a false absence. Under the floor toolchain
the probe drained the frame, and the run then reported the credential absent and
refused its real-provider roles, which is indistinguishable from an operator who
supplied nothing. On the current toolchain the same probe spawns the same class
of child and the frame survived by luck rather than by design.

**Scope of this record.** It disposes exactly this amendment. It strengthens the
credential boundary rather than relaxing it: before the amendment a child could
consume the frame, after it none can. No check is removed, no threshold moves,
no lane is exempted, and nothing that was refused before is admitted now. The
normative envelopes of the accepted plan pair are untouched, no outcome changes,
and no lifecycle state moves.

<a id="disposition-adrs-0012-and-0013-acceptance-2026-08-29"></a>
### ADR 0012 and ADR 0013 acceptance — 2026-08-29

The maintainer explicitly accepted
[ADR 0012](../adr/0012-executor-cancellation-capability.md#concept) and
[ADR 0013](../adr/0013-run-deadline-commitment-at-first-request-staging.md#concept)
as the Proposed pairs existing at candidate
`137a4105ef35aeeac3ab9486348d211cf09910cf`, after independent review of that
exact candidate and the four binding digests. Acceptance binds each Concept
file and its Technical depth companion:

| Decision | Concept | Technical depth |
| --- | --- | --- |
| ADR 0012 | `sha256:585724e32d0ee638b23deacca5a21d593d1992007fbed38537b6274fbfcb7b08` | `sha256:91187684c54de447478fe9d52f03e3c2fa680a57dce5155af2d3d3619cf14887` |
| ADR 0013 | `sha256:059b3d8cdb7ff924f2e264a7eff25d2420e6e6bb9ff3c419c0f47ead20204662` | `sha256:dcdb04d9956c3b32292a0efec4553f223110fae295d15278db40d9b64cd15637` |

ADR 0012 adds one required job-scoped cancellation callback and supersedes only
the earlier claim that progress was the whole `M2` executor-port change. ADR
0013 commits the absolute run deadline at first request staging and supersedes
only the earlier admission timing and literal promotion-record shape. Every
other accepted clause of ADR 0009, ADR 0010, and ADR 0011 remains in force.

The independent review also identified closure evidence and documentation that
the accepted decisions require. Those findings are obligations for the pending
`M2` gate amendment and closure candidate; they do not change either decision's
accepted text or broaden this disposition.

**Scope of this record.** It accepts ADR 0012 and ADR 0013 alone. It does not
accept an `M2` amendment, rebind the accepted plan pair or gate, close `M2`,
authorize product integration, or authorize a release.

This record is the maintainer's disposition evidence, not the independent
review. The administrative transition changes only the two ADR status lines and
governance rows, this disposition, and the ADR index that reports their accepted
status.

<a id="disposition-adr-0014-acceptance-2026-08-29"></a>
### ADR 0014 acceptance — 2026-08-29

The maintainer explicitly accepted
[ADR 0014](../adr/0014-stream-closure-at-owner-loss.md#concept) as the Proposed
pair existing at candidate
`788df465b9710900979a66a311573512caef7092`. Acceptance binds its Concept file
and Technical depth companion:

| Decision | Concept | Technical depth |
| --- | --- | --- |
| ADR 0014 | `sha256:c31a095dca52ac03851143bc82a0b385e14afdfa3cfd3b6525c643a2bb0ff5ae` | `sha256:67ac03b605a2b1e9758837d6a8241dbc2baae890f17154ce22c6a64b377c52c7` |

ADR 0014 narrows only ADR 0011's universal closure and
closure-before-publication promises in the owner-loss and delayed retained-fact
windows it names. ADR 0006 continues to govern durable commit, current-cache
mutation, durable public and outbox publication, and dispatch. ADR 0014 changes
no other accepted clause; the already-recorded ADR 0012 and ADR 0013
supersessions remain in force.

**Scope of this record.** It accepts ADR 0014 alone. It does not accept an
`M2` amendment, rebind the accepted plan pair or gate, close `M2`, authorize
product integration, or authorize a release.

This record is the maintainer's disposition evidence, not the independent
review. The administrative transition changes only ADR 0014's status and
governance row, this disposition, and the ADR index that reports its accepted
status and exact supersession scope.

<a id="disposition-m2-gate-amendment-2-2026-08-30"></a>
### M2 gate Amendment 2 acceptance — 2026-08-30

The maintainer explicitly accepted
[Amendment 2](../plans/M2-gate.md#amendment-2) to the accepted `M2` plan pair
and locked gate as proposed at exact candidate
`5b0d1c1f629681622ae12eadb8120d9077ba140b`, after independent review of that
exact candidate. Acceptance binds the amended normative envelopes and gate:

| Artifact | Digest |
| --- | --- |
| Concept envelope | `sha256:83ace70588d90135a4da12475a2e29f4cdbbbb6564b10d9e8a52a9ae5c468ce0` |
| Technical depth envelope | `sha256:a8c4a97e056ac3537fbebe2c580559febb17ac45c1925cb107176e4b110f67ab` |
| Gate | `sha256:1b24752f6068efaa4eada3758566ff05c0ff950e5af2a81a6cec0a0e2f8d3306` |

Amendment 2 aligns the closure contract with the delivered runtime behavior,
declares accepted ADR 0012, ADR 0013, and ADR 0014 as closure prerequisites,
and strengthens the locked evidence around cancellation, deadline commitment,
workspace containment, stream ownership, and recovery. It also repairs the two
renamed containment selectors and the retained-evidence document count without
removing a check, lowering a threshold, exempting a lane, or changing the
milestone lifecycle.

**Scope of this record.** It accepts Amendment 2 alone and rebinds the `M2`
Acceptance row to its exact proposal. It does not close `M2`, dispose of the
recorded containment limitation, authorize the race-test move or evidence
capture, accept a closure candidate, authorize product integration, or
authorize a release. The milestone remains `In review`.

This record is the maintainer's disposition evidence, not the independent
review. The administrative transition changes only the `M2` Acceptance row and
this new disposition record; the accepted amendment section, normative
envelopes, locked gate, portable enforcement, register, and product bytes are
unchanged.

<a id="disposition-m2-gate-amendment-3-2026-08-31"></a>
### M2 gate Amendment 3 acceptance — 2026-08-31

The maintainer explicitly accepted
[Amendment 3](../plans/M2-gate.md#amendment-3) to the accepted `M2` plan pair
and locked gate as proposed at exact candidate
`530baa3567fb422bef5cffcb6ac63bdb871623a6`, after independent review of that
exact candidate. Acceptance binds the amended normative envelopes and gate:

| Artifact | Digest |
| --- | --- |
| Concept envelope | `sha256:83ace70588d90135a4da12475a2e29f4cdbbbb6564b10d9e8a52a9ae5c468ce0` |
| Technical depth envelope | `sha256:b824a0b2abbdcd46303e6bfeede3413a497311216fa7007cb61d608a1af78aef` |
| Gate | `sha256:be0baf5332664e4da7b2d62855062f3ec6adc9104210b01324c31ba9972ebac5` |

Amendment 3 binds canonical model-reply evidence, schema validation before
policy or dispatch, truthful provider and tool progress, and the attended
provider audit to protected identities and raised minima. The Concept envelope
is unchanged; the Technical depth envelope and locked gate carry the accepted
changes.

**Scope of this record.** It accepts Amendment 3 alone and rebinds the `M2`
Acceptance row to its exact proposal. It does not close `M2`, accept a closure
candidate, authorize product integration, authorize a release, or dispose of
any recorded limitation. The milestone remains `In review`.

This record is the maintainer's disposition evidence, not the independent
review. The administrative transition changes only the `M2` Acceptance row and
this new disposition record; the accepted amendment sections, normative
envelopes, locked gate, portable enforcement, register, and product bytes are
unchanged.

<a id="disposition-adrs-0015-through-0018-acceptance-2026-09-01"></a>
### ADR 0015 through ADR 0018 acceptance — 2026-09-01

The maintainer explicitly accepted the four Proposed decision pairs at exact
candidate `acfdbeea5b3a7507c5510e03a10bb8b238481c88`, after independent review
of that exact candidate:

| Decision | Concept | Technical depth |
| --- | --- | --- |
| [ADR 0015](../adr/0015-artifact-object-and-use-identity.md#concept) | `sha256:71a7ae0546fee1c2eb282ca427262e7fe196329d5e122ef19b0063fd4a16d24d` | `sha256:9e4c10b05b3ef5dafb977de7036ebfa627d8124690307d1e4a678d70950ba818` |
| [ADR 0016](../adr/0016-configured-cancellation-observation.md#concept) | `sha256:0b5c536791ad2d553fb8001e896c0004d34f5b161809b0072f9ff93e7fd31caa` | `sha256:76c20b8abf4344ccda8f45cbc2df173e174f08c6b30be21d8d09c2350edf7e5b` |
| [ADR 0017](../adr/0017-durable-context-admission-budget.md#concept) | `sha256:c24af4fe32cbbb47749c3359eceb29030b67191b3ab20b33976dd271b7e4fe4b` | `sha256:d092aaa6f94c508ee05aa83e261e4117265d0270582b0936a4e0eb35edbc08ae` |
| [ADR 0018](../adr/0018-provider-attempt-authority-and-recovery.md#concept) | `sha256:c4d094e79427ab7c8403ddb3f57d992308f57b9ec44a56604a9b678ba198a67b` | `sha256:d9553fff8d05a1040c25a2b9a9c4f730cb8dec8599a508e81155d2991a49f992` |

ADR 0015 separates immutable artifact-object identity from bounded per-use
metadata. ADR 0016 derives cancellation observation, cleanup confirmation, and
the later command backstop from the committed cleanup period. ADR 0017 adds
separate durable context-token and Store-record admission ceilings. ADR 0018
makes Control's one-use permit the provider-dispatch linearization, permits
exactly one retry only after durable pretransport `not_dispatched` proof, and
forbids redispatch of recovered unresolved attempts. Their supersession scopes
are limited to the clauses each accepted pair names; ADR 0006 remains intact.

**Scope of this record.** It accepts ADR 0015, ADR 0016, ADR 0017, and ADR 0018
alone. It does not accept or rebind `M2` Amendment 4, change the milestone
lifecycle, authorize dependent implementation, close `M2`, authorize product
integration, or authorize a release.

This record is the maintainer's disposition evidence, not the independent
review. The administrative transition changes only the four ADR Concept status
lines and governance rows, this disposition, and the ADR index that reports
their accepted status and exact supersession scope. Every Technical depth file
and all decision text remain byte-identical to the reviewed Proposed candidate.

<a id="disposition-m2-gate-amendment-4-2026-09-01"></a>
### M2 gate Amendment 4 acceptance — 2026-09-01

The maintainer explicitly accepted
[Amendment 4](../plans/M2-gate.md#amendment-4) to the accepted `M2` plan pair
and locked gate as proposed at exact candidate
`fe0c008bb815a0611c73f253b94bb950e35d169b`, after three rounds of independent adversarial
review of the exact candidate, the last of which reported no blocking finding.
Acceptance binds the amended normative envelopes and gate:

| Artifact | Digest |
| --- | --- |
| Concept envelope | `sha256:d2891e3b4d24db846da01606ef64090ee3098532bd7b29540a1557de320d4a7c` |
| Technical depth envelope | `sha256:d2c1350b56e0f63a8986b38e452d2c3adc0bab26ab760764f331dd178b7628ca` |
| Gate | `sha256:deb5f257d6628bef3363bdd0f614c08eb1b0d2d8c1321daa593addbf67aff6f8` |

Amendment 4 binds the ADR 0015 through ADR 0018 contracts — artifact object
and use identity, configured cancellation observation, durable context
admission budget, and provider attempt authority — to protected identities,
raised minima, and a mandatory first-green mutation matrix. Its locked cases
are red at this candidate because the production behavior they name does not
yet exist; the gate is red for that declared absence and for nothing else.

**Decision carried by this acceptance.** The accepted Concept envelope bounded
the reference composition module at eighty effective lines; the delivered
module measured one hundred sixty-four and Outcome 11's selector was red at the
base revision. This amendment raises that ceiling to one hundred eighty, and
accepting it is the maintainer's decision on that normative budget. The
maintainer accepted with the caveat that the module still be reduced toward
eighty. That reduction was attempted before this record was written: branch
`codex/m2-composition-80` at `4025eea41210d8acba24854f4b0c881bb9eb0ce2`
brings the module to one hundred thirty-four effective lines with every locked
behavior intact, and records that eighty is not reachable while those
behaviors stay locked. Whether to take that reduction, and whether to lower the
ceiling to meet it, are product and gate decisions outside this record.

**Scope of this record.** It accepts Amendment 4 alone and rebinds the `M2`
Acceptance row to its exact proposal. It does not close `M2`, accept a closure
candidate, authorize product integration, authorize a release, integrate the
composition reduction, or dispose of any recorded limitation. The milestone
remains `In review`.

This record is the maintainer's disposition evidence, not the independent
review. The administrative transition changes only the `M2` Acceptance row and
this new disposition record; the accepted amendment sections, normative
envelopes, locked gate, portable enforcement, register, and product bytes are
unchanged.

<a id="disposition-m2-gate-amendment-5-2026-09-01"></a>
### M2 gate Amendment 5 acceptance — 2026-09-01

The maintainer explicitly accepted
[Amendment 5](../plans/M2-gate.md#amendment-5) to the accepted `M2` plan pair
and locked gate as proposed at exact candidate
`c2cf96453f11fd4ac1eff7ee37dad7b68a3e02ec`, **without the independent exact-SHA review the
ordinary amendment transaction requires**, as a recorded maintainer override.
Acceptance binds the amended normative envelopes and gate:

| Artifact | Digest |
| --- | --- |
| Concept envelope | `sha256:d2891e3b4d24db846da01606ef64090ee3098532bd7b29540a1557de320d4a7c` |
| Technical depth envelope | `sha256:d2c1350b56e0f63a8986b38e452d2c3adc0bab26ab760764f331dd178b7628ca` |
| Gate | `sha256:f15d603712beb4973016f831e626b105dfdeca9020ae7cabb92fc89087a81b86` |

Amendment 5 inserts one bounded wait between the two event reads of the
digest-bound composition case, because ADR 0017 places `run.started` in the
first staging transaction rather than the prompt admission the case read it
after, and rebinds that corpus and the runner. Both plan envelopes are
unchanged. The override rests on the change being one assertion's wait whose
correctness the corpus itself proves; it is the fifth recorded override of
this milestone and the only one applied to a digest-bound artifact.

**Scope of this record.** It accepts Amendment 5 alone and rebinds the `M2`
Acceptance row to its exact proposal. It does not close `M2`, accept a closure
candidate, authorize product integration, authorize a release, or dispose of
any recorded limitation. The milestone remains `In review`.

<a id="disposition-m2-gate-amendment-6-2026-09-02"></a>
### M2 gate Amendment 6 acceptance — 2026-09-02

The maintainer explicitly accepted
[Amendment 6](../plans/M2-gate.md#amendment-6) to the accepted `M2` plan pair
and locked gate as proposed at exact candidate
`fe422f569bee1be0811d626ed2ba809cc24ea8d2`, **without the independent exact-SHA review the
ordinary amendment transaction requires**, as a recorded maintainer override.
Acceptance binds the amended normative envelopes and gate:

| Artifact | Digest |
| --- | --- |
| Concept envelope | `sha256:d2891e3b4d24db846da01606ef64090ee3098532bd7b29540a1557de320d4a7c` |
| Technical depth envelope | `sha256:d2c1350b56e0f63a8986b38e452d2c3adc0bab26ab760764f331dd178b7628ca` |
| Gate | `sha256:bef34d6a5e5093534cd0b12ccc61c5dcd000d8e98d4ec7ec7d64f244206e46c9` |

Amendment 6 changes one value in the gate's own opening probe: its in-process
harness model reports usage as the raw token pair ADR 0018 admits at the
adapter boundary, rather than the reducer's normalized shape it had returned,
which the closed usage key set refuses. Both plan envelopes are unchanged. The
override rests on the change being one harness value whose correctness the
probe's own observation proves; it is the eleventh recorded override of this
milestone and the second applied to the gate runner.

**Scope of this record.** It accepts Amendment 6 alone and rebinds the `M2`
Acceptance row to its exact proposal. It does not close `M2`, accept a closure
candidate, authorize product integration, authorize a release, or dispose of
any recorded limitation. The milestone remains `In review`.

<a id="disposition-m2-gate-amendment-7-2026-09-02"></a>
### M2 gate Amendment 7 acceptance — 2026-09-02

The maintainer explicitly accepted
[Amendment 7](../plans/M2-gate.md#amendment-7) to the accepted `M2` plan pair
and locked gate as proposed at exact candidate
`1cd8a48440fa1cb7b519feab4ddfeb81ccec5e28`, **without the independent exact-SHA review the
ordinary amendment transaction requires**, as a recorded maintainer override.
Acceptance binds the amended normative envelopes and gate:

| Artifact | Digest |
| --- | --- |
| Concept envelope | `sha256:d2891e3b4d24db846da01606ef64090ee3098532bd7b29540a1557de320d4a7c` |
| Technical depth envelope | `sha256:d2c1350b56e0f63a8986b38e452d2c3adc0bab26ab760764f331dd178b7628ca` |
| Gate | `sha256:2effbe8eb785adc0eda40b6e24a4569e863a0008234b49559147fb9d74681051` |

Amendment 7 moves one locked case, body unchanged, from the core
project-resource-trust selector to the command selector, because the case
proves the terminal display of the trust decision through command modules a
core selector VM cannot load. Outcome 7's minimum falls to eight and the
command selector's rises to twenty-two. Both plan envelopes are unchanged. The
override rests on the change altering nothing the case proves; it is the
twelfth recorded override of this milestone.

**Scope of this record.** It accepts Amendment 7 alone and rebinds the `M2`
Acceptance row to its exact proposal. It does not close `M2`, accept a closure
candidate, authorize product integration, authorize a release, or dispose of
any recorded limitation. The milestone remains `In review`.

<a id="disposition-m2-gate-amendment-8-2026-09-02"></a>
### M2 gate Amendment 8 acceptance — 2026-09-02

The maintainer explicitly accepted
[Amendment 8](../plans/M2-gate.md#amendment-8) to the accepted `M2` plan pair
and locked gate as proposed at exact candidate
`d16b9703fbd39697bb7727eba8914c29823f3bc6`, **without the independent exact-SHA review the
ordinary amendment transaction requires**, as a recorded maintainer override.
Acceptance binds the amended normative envelopes and gate:

| Artifact | Digest |
| --- | --- |
| Concept envelope | `sha256:d2891e3b4d24db846da01606ef64090ee3098532bd7b29540a1557de320d4a7c` |
| Technical depth envelope | `sha256:d2c1350b56e0f63a8986b38e452d2c3adc0bab26ab760764f331dd178b7628ca` |
| Gate | `sha256:71bdfe69420b2798043cd5360df09ff8d53a4375086e3128278df34aae44e6c4` |

Amendment 8 adds one locked case to the provider-attempt role that drives a
duplicate permit request as the coordinator itself and asserts the exact
one-use refusal, because closure review found the existing duplicate request
refused on ownership before the spent-identity check ran. The role's minimum
rises to twenty-five. Both plan envelopes are unchanged. The override rests on
the case being the one the review specified; it is the sixteenth recorded
override of this milestone.

**Scope of this record.** It accepts Amendment 8 alone and rebinds the `M2`
Acceptance row to its exact proposal. It does not close `M2`, accept a closure
candidate, authorize product integration, authorize a release, or dispose of
any recorded limitation. The milestone remains `In review`.

<a id="disposition-m2-gate-amendment-9-2026-09-03"></a>
### M2 gate Amendment 9 acceptance — 2026-09-03

The maintainer explicitly accepted
[Amendment 9](../plans/M2-gate.md#amendment-9) to the accepted `M2` plan pair
and locked gate as proposed at exact candidate
`05ec516e399a6c1ef3c539f53cfee72d38342e34`, **without the independent exact-SHA review the
ordinary amendment transaction requires**, as a recorded maintainer override.
Acceptance binds the amended normative envelopes and gate:

| Artifact | Digest |
| --- | --- |
| Concept envelope | `sha256:d2891e3b4d24db846da01606ef64090ee3098532bd7b29540a1557de320d4a7c` |
| Technical depth envelope | `sha256:d2c1350b56e0f63a8986b38e452d2c3adc0bab26ab760764f331dd178b7628ca` |
| Gate | `sha256:bd168781cc7aea2c971f4685416524ef002bfc2ef390275f749ae2c1397361ae` |

Amendment 9 widens one pattern in the gate's evidence lifecycle validator so it
reads the register's code-formatted milestone name, which the status check
mandates; the validator had refused every evidence child as "register row
absent". Both plan envelopes are unchanged. The override rests on the change
being one character class whose intended target portable enforcement already
fixes; it is the seventeenth recorded override of this milestone.

**Scope of this record.** It accepts Amendment 9 alone and rebinds the `M2`
Acceptance row to its exact proposal. It does not close `M2`, accept a closure
candidate, authorize product integration, authorize a release, or dispose of
any recorded limitation. The milestone remains `In review`.


<a id="disposition-m2-closure-2026-09-03"></a>
### M2 closure — 2026-09-03

The maintainer explicitly closed milestone `M2` at evidence child
`2fee09ff01283758695bfc40834e4b715a6f578b`, the unique one-parent child of source
candidate `f17beef1b62116fa411b3fa496f3e8964b3af81c` that retains the toolchain
matrix, the real-call attestations, the attended demonstration, and the
thirteen negative demonstrations. Closure binds the accepted envelopes and gate:

| Artifact | Digest |
| --- | --- |
| Concept envelope | `sha256:d2891e3b4d24db846da01606ef64090ee3098532bd7b29540a1557de320d4a7c` |
| Technical depth envelope | `sha256:d2c1350b56e0f63a8986b38e452d2c3adc0bab26ab760764f331dd178b7628ca` |
| Gate | `sha256:bd168781cc7aea2c971f4685416524ef002bfc2ef390275f749ae2c1397361ae` |

The M2 gate is GREEN at that child on the current pair, and every lane the
gate requires was captured at the source candidate: three capture lanes at one
sealed identity with 493 protected cases each, the M0 gate under both locked
pairs, and the M1 gate under the current pair. Two independent exact-SHA
reviews preceded closure; the first rejected the previous candidate on a
missing one-use-permit detector and a stale progress table, both repaired
under Amendments 8 and 9 and the recorded closure-review repair set, and the
second confirmed those repairs and rejected the previous evidence child on
record misdescriptions, repaired by re-taking the attended demonstration at
the same candidate.

**Dispositions recorded with closure.**

- The composition-ceiling caveat from Amendment 4's acceptance is withdrawn:
  the module measures 173 effective lines under the locked 180-line ceiling,
  and the 134-line reduction branch is not taken.
- The technical envelope's statement that the composition module measured
  164 effective lines is stale and immutable; the executable ceiling in the
  bound corpus is what binds.
- Erratum: row 1 of the plan's progress table names capture candidate
  `a1775d02`; every retained lane names `f17beef1`. The first commit after
  this transition corrects that cell.
- The technical envelope's rollback section describes reverting product bytes
  on the milestone branch but not reverting the integration merge; reverting
  that merge uses `git revert -m 1` and a later re-landing requires reverting
  the revert. Recorded here rather than edited into the immutable envelope.
- Eighteen recorded maintainer overrides and three approved limitations
  (ADR 0017 step 5, spent-attempt retention, dispatcher Store I/O) stand as
  recorded in the milestone's evidence.

**Scope of this record.** It closes `M2` and authorizes integration of the
milestone branch to `main` by merge, preserving every bound candidate. It
authorizes no release, tag, or publication.

<a id="disposition-adrs-0019-0021-2026-09-07"></a>
## ADRs 0019–0021 Acceptance and Repair Implementation

On 2026-09-07 the maintainer explicitly accepted all three ADR pairs at candidate
`b7f97092f7b6d6661e66bc775fd88195b92b67a0` and separately directed implementation,
testing, and preparation for release review. The acceptance binds these Proposed
bytes, not a later edited decision:

| ADR | Concept SHA-256 | Technical depth SHA-256 |
| --- | --- | --- |
| 0019 | `b743931ccc7435ad4a90973ee6b623fea2afa1133ecaf8733a10a0512605f9dc` | `26ea8ac60e6f4a006018afdd4ffe24308b4e2184c67e175d9cd555a268030c6f` |
| 0020 | `cbaee4ffc0a96658e42d769f5467501ab23d5d42dd09d0ac15a7919d8d329370` | `ee44044c2daece3bc74a7f89ddf549a97f579e19d5ae16ffb630e2500239f8fb` |
| 0021 | `ce25d99eb282c732a16d938d2385a7d75dffb30a9099183a8340a03b8a607bd4` | `7041508edcaeaa53a39647cf524fc489470f46dba08c5dfff462c297e5f010d3` |

ADR 0019 accepts the separate, host-owned one-invocation provider process,
explicit companion configuration and direct-call migration, bounded credential
handoff, and lifetime/evidence requirements. ADR 0020 accepts the explicit local
prepared-handoff participant and atomic duplicate installation refusal. ADR 0021
accepts versioned compact-accounting provenance and its narrow legacy-history
refusal. These are three accepted decisions, not a claim their implementation
is already conformant.

**Accounting correction.** Override 21's blanket-conservative description does
not state ADR 0018 combination 5 correctly. A raw-admitted, validated reply
whose complete settlement does not fit preserves its complete reported usage;
prevalidation unreadable input has no such evidence and estimates the remaining
allowance. ADR 0021 preserves that policy and changes only its named record,
validation, and legacy-compatibility clauses. The historical override and accepted
ADR 0018 bytes remain unmodified; their earlier source ranges are not extended.

**Implementation scope.** The current instruction authorizes these post-closure
repairs and their documentation, conformance, mutation, and source-bound live
evidence on `codex/m2-release-repair`, notwithstanding the generic Closed-register
capsule's planning-only projection. Preserve M2's Closed state and its accepted
plan/gate history. This does not waive a required gate, authorize changing its
locked bytes, or dispose of an unresolved blocking finding. A required gate
change still needs its own holder transaction and explicit acceptance.

**Transition scope.** Within each ADR pair the acceptance commit changes only
the Concept status and governance row; Technical depth bytes are unchanged.
The same commit updates the two ADR indexes and this one new disposition, not
an earlier disposition. It changes no product, plan, gate, or lifecycle bytes.
Independent exact-diff review remains required before integration. The separate
implementation instruction grants no tag, publication, final release approval,
or approval of an unseen integration candidate. Final source and evidence must
be offered for release review before those decisions.

<a id="disposition-local-executor-bash-2026-09-07"></a>
## Local Executor Bash Requirement and Repair Instruction

On 2026-09-07, after the native Linux launch-input and helper-group failures were
presented with alternatives, the maintainer answered **Yes** to the explicit
question: may the reference local executor require `/bin/bash` for its internal
supervision scripts, keeping model commands on `/bin/sh` and Core and custom
executors independent, and may the repair and qualification be completed?

That current decision authorizes this narrowly scoped runtime dependency,
implementation, truthful documentation and serial cross-platform tests on
`codex/m2-release-repair`. Preserve the existing carrier/guard ownership,
credential boundaries, cleanup protocol and bounds. No POSIX-only fallback,
shared-group redesign, Linux exclusion, gate weakening or retry waiver was
approved. Bash in development prerequisites is not the source of this authority.

[ADR 0022](../adr/0022-local-executor-supervision-shell.md#concept) records the
choice and its technical consequences as a Proposed pair. This instruction does
not accept unseen ADR bytes or fill that pair's governance row. Exact-pair
acceptance and independent final-source review remain separate. It changes no
earlier disposition, M2 lifecycle, accepted plan/gate or integration baseline,
and grants no merge, tag, publication or release approval.

<a id="disposition-m0-gate-generation-6-2026-09-07"></a>
## M0 Gate Generation 6 Acceptance

On 2026-09-07 (America/Los_Angeles), after receiving the independent exact-SHA
review, the maintainer explicitly accepted M0 gate generation 6 at proposal
`f49be58ddfc13dae3d7cb3443363da162f90be31` and directed completion of the remaining
M2 repair and qualification work. The accepted gate digest is
`sha256:5f89d8be79c466e2b68e1660668b7a0723940c7480583c495372ddbd14f37ee8`.

The decision accepts the four occurrence-specific child-environment allowances,
their fail-closed checker, and the two real-boundary conformance observations
exactly as specified by Amendment 6. It does not broaden those allowances to
files or other constructions. The interpreter-invocation scan and shadowed
bootstrap absence proof retain their prior coverage; the amendment narrows only
the named textual search-path rule and records its limits.

The independent report, `M0-GEN6-f49be58-REVIEW.md`, has SHA-256
`0e53a408463884aad34f6419ccc83dcd0b886dd43a61af3e88006131c2d2d650`.
It recommends acceptance with no blocking or high finding. Its simulated rebind
is diagnostic evidence only, not an accepted transition or a passing result at
the proposal. The actual rebind still owes exact-transition review, status,
bootstrap and inherited-gate verification.

This disposition accepts generation 6 alone under `amendment-transaction-v2`.
Its immediate-child transition changes only the generation-6 row in
`docs/plans/M0.md` and adds this new disposition to this existing document.
M0's historical Acceptance and Closure, all earlier dispositions, the gate and
bound artifacts, normative envelopes, register and lifecycle states remain
unchanged. M0 and M2 remain Closed. This record does not accept ADR 0022, waive
required evidence or gates, approve an unseen integration or release candidate,
or authorize a tag or publication. The separate instruction to finish M2 does
not substitute for final source-bound evidence and independent release review.

<a id="disposition-adr-0022-acceptance-2026-09-08"></a>
## ADR 0022 Exact-Pair Acceptance

On 2026-09-08 (America/Los_Angeles), the maintainer answered **Yes** to the
explicit question accepting ADR 0022 at candidate
`4c75ae3f81f3caefe7745c40a5b24e9133255e57`: require Bash for the reference local
executor's internal supervision while model-supplied raw commands remain on
`/bin/sh`. Core and third-party executors acquire no Bash prerequisite. This
records exact-pair acceptance, separately from the earlier implementation-only
instruction and the M0 generation-6 disposition.

The bound Proposed pair is:

- Concept: `sha256:d76b4996903e60a99bffcc35d31a0b0226f7123ce502b7e9a54ee7a8cd303edd`.
- Technical depth: `sha256:5822d3fc93548a7d3c707fb82fc1d62d1a9932d9668c8d6e28defb28fda23467`.

The independent exact-candidate static review recommended acceptance with no
concrete text/code conflict. It distinguished existing Darwin and native Linux
qualification evidence from new execution at this candidate; acceptance does
not turn those historical results into later-source runs or universal platform
coverage.

Within the pair, this administrative transition changes only the Concept status
and Acceptance row; the Technical depth file remains byte-identical to the
candidate. It also updates ADR 0022's index status and explanation, the two
current guidance links' status labels in `DEVELOPMENT.md` and
`docs/operator/tools-and-policy.md`, and adds this one standalone disposition.
It changes no earlier disposition, product, gate, bound artifact, normative
plan envelope, register, or milestone lifecycle. Independent exact-transition
review remains required before integration.

This decision accepts ADR 0022 alone. It does not waive the unexplained M2
coding-tools gate failure, provider-account verification, or any other required
evidence; it does not approve an unseen integration or release candidate, merge,
tag, or publication. M2 remains Closed, with post-closure source qualification
and independent release review still outstanding.

<a id="disposition-m3-cli-extension-override-2026-09-09"></a>
### M3 inherited CLI restriction override — 2026-09-09

The maintainer explicitly directed that amendment procedure be overrideable
with their approval in later milestones, requested the corresponding canonical
contract and context-map changes, and approved changing the inherited CLI
restriction on the `m3` branch: “my override would modify that restriction in
m3 in cli_test.exs”. They then directed completion of the changes for review
and acceptance before product implementation.

This disposition authorizes the assertion change in
`apps/loopex_cli/test/cli_test.exs`: require the existing `artifact`, `cancel`,
`resume`, `run` and `sessions` commands, and permit the planned `skill` extension.
`skill` may remain absent while M3 is Open. Repeated clauses for a command count
as one command. Removing an inherited command or adding another unapproved
command still fails. M3 gains no protocol/wire scope from this exception; existing
facade, dependency and runtime-boundary witnesses remain required.

The test's historical string, “the command exposes exactly run sessions resume
cancel and artifact and no wire or line framing surface”, remains only its
protected selector identifier in the unchanged M2 gate and runner. Its current
assertions implement the approved successor requirement above. That old string
does not independently reimpose a five-command ceiling. This preserves the
historical gate bytes, minimum and required passing identity without requiring
a separate amendment proposal/rebind. The test file is not digest-bound.

Focused proof executed the genuine selector in disposable source trees: the
original assertion rejected two `skill` dispatch clauses; the revised assertion
passed with the unchanged CLI and with those clauses, rejected removal of
`sessions`, and rejected an added `app-server` command. Each diagnostic ran the
one selected case with 46 unrelated cases excluded and zero skipped. These are
focused diagnostics, not a full M2 gate result. Product source was restored.

This approval changes the named inherited restriction and permits the canonical
override route. It does not accept M3, ADR 0025 or ADR 0027, authorize product
implementation, waive unrelated evidence, change any bound artifact digest, or
approve a merge or release. Subsequent exceptions need their own explicit scope
and approval; historical acceptance and closure evidence remains unchanged.

<a id="disposition-m3-incremental-witness-approval-2026-09-09"></a>
### M3 incremental witness preparation approval — 2026-09-09

The maintainer explicitly approved the following separately presented change:
M3 acceptance locks outcome clauses, witness names, runnable gate commands and
a real behavioral opening red; future test bodies are written during
implementation and all must pass before closure. This followed a specific
approval request explaining that the change goes beyond the earlier CLI
exception. The maintainer answered “I wxplicitly approve it”.

Replace the draft's requirement to construct every future test body before
acceptance with that rule. Keep the two prerequisite ADR decisions, complete
contracts, executable gate routing, inherited acceptance-base evidence and
independent review. Require the thin integrated skill/tool/artifact workflow
at the first implementation checkpoint. A missing or skipped witness is never
a pass, and the declared opening red must come from actual product behavior.

This approval authorizes the preparation-rule changes in AGENTS.md, this map
and the M3 plan/gate. It does not accept the eventual M3 candidate or proposed
ADRs, authorize product implementation, waive an observed inherited regression,
or remove any closure outcome or evidence requirement.

<a id="override-disposition-m3-cli-extension-ratification-2026-09-10"></a>
### M3 CLI extension override ratification — 2026-09-10

This standalone record ratifies the still-Open M3 CLI exception under the
prospective safeguard in `AGENTS.md`. It leaves the earlier 2026-09-09 record
unchanged as history; this anchor is the authority M3 must cite before acceptance.

The maintainer's operative instructions were: “change that too”; “wherever that
is codified”; “complete all the changes so that I can review and accept it and
we can move on to implementation”; and “I wxplicitly approve it”. These are
exact transcriptions from the task. The intervening conditional sentence
identified `cli_test.exs` as the affected location; it is not the authority
record. The explicit approval answered the exact replacement packet recorded
immediately below.

The affected restriction is the assertion in
`apps/loopex_cli/test/cli_test.exs` whose historical protected name says the
command exposes exactly `run`, `sessions`, `resume`, `cancel` and `artifact`.
For M3, the replacement requires those five commands and permits only the
planned `skill` extension. Repeated and guarded literal command clauses count
once. Removing a required command, adding any other literal command, or hiding
a dynamic remap behind a dispatch clause still fails.

The historical selector's additional words “and no wire or line framing
surface” were never asserted by this case, before or after the exception. This
case owns the public command inventory. The separate facade/dependency-direction
witnesses retain their existing meaning, and M3's no-protocol scope remains a
plan and review obligation. The protected test name stays unchanged only because
the M2 runner locks its identity; it is not evidence for an assertion its body
never made.

Validation requires the focused unchanged/add-skill/remove-required/add-other
mutations, the strengthened guarded/dynamic-clause checks, and the complete M2
gate green through the inherited aggregate at the exact M3 acceptance base.
Focused diagnostics alone do not settle that forward requirement.

This override changes one continuing development-time test restriction for M3.
It changes no released public surface or accepted ADR decision, does not weaken
any other M2 witness, and does not accept M3, either prerequisite ADR, a merge,
closure, release, tag or publication. This commit adds only this disposition;
an independent exact-SHA read must approve its changed-path and authority scope
before any dependent M3 edit lands.

<a id="override-disposition-m3-incremental-witness-ratification-2026-09-10"></a>
### M3 incremental witness preparation ratification — 2026-09-10

This standalone record ratifies the still-Open M3 witness-preparation exception
under the prospective safeguard in `AGENTS.md`. It leaves the earlier 2026-09-09
record unchanged as history; this anchor is the authority M3 must cite before
acceptance.

The proposal presented for decision was: “M3 acceptance locks outcome clauses,
witness names, runnable gate commands and a real behavioral opening red; future
test bodies are written during implementation and all must pass before closure.”
The maintainer answered: “I wxplicitly approve it”. These are verbatim
transcriptions of the proposal and approval in the M3 planning task.

For M3, this replaces the draft preparation rule that required every future
test body to exist before plan acceptance. Acceptance instead binds the complete
outcome clauses, exact witness identities, executable routing and commands, and
the behavioral opening red. The implementation phase may author the named
future test bodies. Every required witness must exist, run, and pass before
closure; missing, skipped, excluded, malformed, or unavailable evidence cannot
be reported as PASS.

The first implementation checkpoint must prove the thin integrated
skill/tool/artifact workflow before breadth rejoins. The two prerequisite ADR
decisions and complete contracts, the inherited acceptance-base aggregate,
focused changed-outcome checks, later rejoin evidence, closure evidence, and
independent review remain required. The opening red must continue to arise from
observed product behavior and cannot be replaced by a missing file, compile
failure, label, stub, or inert scaffold.

This override changes one continuing development-time preparation procedure for
the still-Open M3 plan and gate. It changes no released public surface or
accepted ADR decision and does not remove an outcome, witness, real-path class,
trust negative, compatibility proof, rollback proof, or documentation duty. It
does not accept M3, ADR 0025 or ADR 0027, authorize product implementation,
waive an inherited regression, or approve a merge, closure, release, tag or
publication. This commit adds only this disposition; an independent exact-SHA
read must approve its changed-path and authority scope before any dependent M3
edit lands.

<a id="override-disposition-m3-acceptance-aggregate-2026-09-10"></a>
### M3 acceptance aggregate override — 2026-09-10

The maintainer's actual instruction was: “no need to run m0-m2 aggregate. i
override during plan acceptance”. This instruction was given after reviewing
the completion checklist for the next M3 plan-acceptance candidate.

For the M3 plan-acceptance transition only, this replaces the procedure that
requires a new full M0–M2 inherited aggregate at the exact acceptance candidate.
It specifically supersedes the forward acceptance-base aggregate requirements
recorded in the earlier M3 CLI-extension and incremental-witness ratifications;
those historical records remain unchanged for the revisions where they landed.
The transition may rely on the inherited product baseline fixed by
`b637873ddc39542ec27add71015b46a4f7c7f80e` and proceed without claiming a new
aggregate result at the candidate SHA. The acceptance record and review must
state that this evidence was explicitly waived rather than passed, unavailable,
or silently omitted.

The replacement validation remains: exact-candidate compilation, formatting,
status, documentation and bootstrap checks; the complete deterministic suite;
all applicable M3 runner roles; the accepted Elixir 1.17.0/OTP 26.0 runner
regression proof; recomputed bound-artifact digests; and independent exact-SHA
review. Any inherited regression actually observed by those checks still blocks.
The ordinary inherited aggregate obligations at a later parallel-workstream
rejoin, bound-holder rebind, closure candidate, or evidence-invalidating product
change remain in force unless separately overridden.

This override changes one development-time evidence procedure. It changes no
released public surface or accepted ADR decision, does not weaken an M3 outcome
or closure witness, and does not accept M3, ADR 0025 or ADR 0027, authorize
product implementation, approve integration, closure, release, tag or
publication, or report an unrun check as PASS. This commit adds only this
disposition; an independent exact-SHA read must approve its changed path and
authority scope before dependent M3 acceptance-plan edits land.

<a id="override-disposition-m3-review-ordering-2026-09-10"></a>
### M3 review ordering and acceptance exceptions — 2026-09-10

The maintainer was asked to confirm this bundled approval: "accept the one-time
ordering exception, assign the executor flake to M3 outcome 5 for repair before
closure, and authorize ADR 0025/0027 and M3 acceptance after a clean delta
review." The maintainer answered: "Confirm". This records that explicit
instruction, including its review condition, rather than inferring acceptance
from the reviewer's recommendation.

The ordering exception applies only to the still-Open M3 lineage reviewed at
`ec5c302928ab300128d7abe5fcc4a1b29c56fba9` and these three standalone override
commits:

- `3310c8dd80d4774da23f004a7a275f327a2e0afb`: CLI extension ratification;
- `5dbef63a7cd798f8bb5cb0b88d7c5f2bc1104bb9`: incremental witness ratification;
- `82fad5d6b7948161a2014bb29cad39f444d62e93`: acceptance aggregate override.

Their independent exact-SHA read happened after dependent planning commits,
contrary to the before-dependent-work requirement in
[AGENTS.md](../../AGENTS.md#maintainer-override) and those dispositions.
The maintainer accepts that historical ordering for this M3 plan-acceptance
lineage. The late review is not backdated, the earlier records remain unchanged,
and the rule still applies to future work. This new disposition must receive an
independent exact-SHA read before the next dependent commit and before the
acceptance transitions. It changes no bound artifact or accepted ADR decision.

The same approval dispositions the inherited executor flake reported at
`ec5c302928ab300128d7abe5fcc4a1b29c56fba9` for plan acceptance only:
`apps/loopex_executor_local/test/coding_tools_test.exs`, case
`edit applies an exact match change and names what differed on a mismatch`,
returned `{:error, {:reconciliation_required, 1}}` instead of the expected failed
outcome at seed `3107`. The review's whole-suite result remains 1,095 passed and
one failed; three subsequent file reruns, each 72 passed, are diagnostic evidence
of a flake and do not replace that failed result. The executor bytes were
unchanged by this planning candidate. M3 outcome 5 owns investigation and repair,
with stable evidence required before closure; acceptance does not mark the case
fixed or permit filtering, retries-as-PASS or weakening its guarantee.

The M0–M2 acceptance aggregate remains explicitly **waived**, under the
[existing acceptance-only override](#override-disposition-m3-acceptance-aggregate-2026-09-10).
The review's single M2 gate diagnostic was cancelled and supplies no PASS.
Its retained mitigations are the identical 47 CLI case names and green bootstrap
at the reviewed SHA. The floor-pair compile, governance and CLI files, and
behavioral opening red are evidence from that review, not newly run evidence
at this disposition. For the bounded follow-up, the reviewer requires only the
exact delta, bound-artifact inspection and status; the full lane set is not
repeated for these documentation changes.

Conditional acceptance covers only the reviewed M3 plan/gate and ADRs 0025 and
0027, after the two-sentence ADR 0025 provenance-key correction and a clean
independent delta review. The administrative transitions record their exact
candidates and digests separately. This standalone commit adds only this
disposition; it does not itself change lifecycle status, authorize a merge to
main, close M3, or grant release or publication authority.

<a id="disposition-m3-prerequisite-adrs-2026-09-10"></a>
### ADR 0025 and ADR 0027 acceptance — 2026-09-10

The maintainer's explicit "Confirm" to the
[conditional acceptance packet](#override-disposition-m3-review-ordering-2026-09-10)
accepts [ADR 0025](../adr/0025-resource-packs-and-skill-admission.md#concept) and
[ADR 0027](../adr/0027-provider-permit-retirement.md#concept) as the Proposed
pairs at `1a16033c2418bc72916a1ff86821f8420f6adbf7`. The standalone ordering
disposition received an independent exact-SHA APPROVE before that candidate's
two-sentence provenance correction was committed. The candidate's independent
delta review found no issues; its sole condition, a passing status check at
that exact source, was met before this administrative transition.

Acceptance binds the complete Proposed files:

| Decision | Concept | Technical depth |
| --- | --- | --- |
| ADR 0025 | `sha256:1ef539109e13b663cdb819b9278b23b70a4cfd889b4a62b26776b612735b83a0` | `sha256:d61a1c5bf10f9dba4fd9b6c7bada5fdf5711bfa42e80e39b2c4de5df042fd068` |
| ADR 0027 | `sha256:ae631119f412726baadbc8bda4e91030147a7853a10b0e52be7e7baba183766b` | `sha256:080c74758d2d264f139dc3dfd0b725c1c62d07e7bed5e190208bd888fa51a479` |

The acceptance aggregate is **waived**, not passed. The cancelled M2 diagnostic
is not PASS. The reported executor flake remains assigned to M3 outcome 5 for
investigation and repair before closure, exactly as dispositioned in the packet;
the prior failed suite and diagnostic reruns keep their original meanings.

Within each ADR pair this transition changes only its status and Acceptance
row. It also adds this disposition and updates the ADR index and the plans
register's derived prerequisite status. M3 remains Open until its own reviewed
acceptance transition. The ADR decision bytes, Technical companions, plan and
gate remain unchanged, and this record grants no main merge, closure or release.

<a id="disposition-m3-plan-acceptance-2026-09-10"></a>
### M3 plan pair and gate acceptance — 2026-09-10

Under the maintainer's explicit "Confirm" to the
[conditional acceptance packet](#override-disposition-m3-review-ordering-2026-09-10),
M3's [Concept plan](../plans/M3.md#concept),
[Technical depth companion](../plans/M3-technical.md#technical-depth) and
[gate](../plans/M3-gate.md) are accepted at candidate
`d6b4870da4e2306923234482f84a388aff7cb0a6`. That candidate contains the accepted
ADR 0025 and ADR 0027 records. Its independent exact-SHA review approved the ADR
transition and the Open M3 candidate; the sole condition, passing status at that
source, was met before this transition. The earlier ordering disposition was
reviewed before the provenance correction and all subsequent dependent commits.

Acceptance binds:

- Concept envelope: `sha256:9d6abe3889bc2531259b076c5233cbd8c5d7afb4df4f0435cef7c842c5d7fa7b`;
- Technical depth envelope: `sha256:82471073b4fbfb9798c3f002ebbde2453c8f8aabb72d53ad69dc65f799178a55`;
- Gate: `sha256:dd2ded0b82e303e134d9d56c7cd5a9111206eb167a95aa612fb79c5bcc310880`.

The M0–M2 acceptance aggregate is **waived**, not passed, under the approved
acceptance-only exception. The cancelled single M2 diagnostic supplies no PASS.
The retained mitigation is the review's identical 47 CLI case names and green
bootstrap at `ec5c302928ab300128d7abe5fcc4a1b29c56fba9`. The original behavioral
opening red and floor-pair results remain evidence at that reviewed source;
the bounded documentation follow-up adds exact-delta review, status and
bound-artifact inspection, without claiming another full lane run.

The inherited executor flake in `coding_tools_test.exs`, case
`edit applies an exact match change and names what differed on a mismatch`, is
assigned to M3 outcome 5 for investigation and repair before closure. The
reviewed whole-suite failure and three diagnostic file reruns retain their
original results; acceptance neither marks the flake fixed nor permits a
weaker witness. The five outcome rows remain Open and the declared opening red
remains implementation work. All unaffected evidence duties remain required.

This acceptance authorizes implementation within the accepted M3 envelopes on
`m3`. This administrative transition changes the Acceptance row, this single
disposition, the register and derived lifecycle prose; it changes no normative
envelope, gate, ADR decision or product byte. Its own independent exact-diff
review remains required before integration. M3 is not Closed, M4 remains an
unopened draft, and no main merge, release, tag or publication is authorized.

<a id="override-disposition-m4-planning-aggregate-2026-09-11"></a>
### M4 planning-revision aggregate override — 2026-09-11

The maintainer's actual instruction was: “no need to run m0 to m2 gates again
during plan creation. override.” It was given while M4 was being revised on
branch `m4` after a preliminary review, with the M0–M2 Closed aggregate already
GREEN at the M4 opening candidate `4b13fd92904603dfe8476c50b98350bd70c5d7a8`
on the integrated M3 acceptance base
`4bba8b74f5e260dc2a364fcbd3554c7badd1a09c`.

For the Open M4 planning lineage only, this replaces the procedure that would
rerun the M0–M2 Closed aggregate for every later planning-only revision of the
M4 plan pair, gate, runner, support scripts, manifest, prerequisite ADR
proposals and documentation. The lineage may rely on the aggregate result
recorded at `4b13fd9` while every later M4 planning revision changes no
milestone product bytes; each such revision still runs status, formatting,
bootstrap, runner inspection, the M4 opening probe and, separately, the M3
opening probe, and receives exact-SHA review. A revision that changes product,
portable-enforcement or bound Closed-gate bytes, the refresh of M4 onto the
integrated M3 closure, M4 acceptance, any rejoin, rebind child or closure
candidate remain under the ordinary inherited-aggregate obligations unless
separately overridden. Any inherited regression actually observed still
blocks.

This override changes one development-time evidence procedure. It changes no
released public surface or accepted ADR decision, does not weaken an M4 outcome
or witness, and does not accept M4 or ADRs 0023, 0024, 0026 or 0028, authorize
product implementation, approve integration, closure, release, tag or
publication, or report an unrun check as PASS. This commit adds only this
disposition; an independent exact-SHA read must approve its changed path and
authority scope before the M4 plan cites it.

<a id="override-disposition-m4-planning-aggregate-scope-2026-09-11"></a>
### M4 planning-revision aggregate override scope — 2026-09-11

The maintainer's actual instruction was: “I dont agree on you needing to run
m0- m2 again for plan changes for m4”. It was given after the M4 planning
revision `8fc7f5c65ba6ec3d62c69f3e9d841785bf58b59f` changed the derived
status-capsule wording in `apps/loopex/lib/mix/tasks/status/register.ex` and
its test, and the earlier
[planning-revision aggregate override](#override-disposition-m4-planning-aggregate-2026-09-11)
had been transcribed narrowly enough to exclude that change.

This widens that override's scope and changes nothing else. For the Open M4
planning lineage while M3 remains Accepted, the M0–M2 Closed aggregate proved
GREEN at the opening candidate `4b13fd92904603dfe8476c50b98350bd70c5d7a8` is
not rerun for any later M4 planning revision, including a revision that
changes repository status enforcement, its tests, plan documents, gate
documents, runner or support scripts, manifests, prerequisite ADR proposals or
documentation, provided the revision adds no milestone product implementation
and every changed enforcement check passes bootstrap at the revision. Each such
revision still runs status, formatting, bootstrap, runner inspection, the M4
opening probe and, separately, the M3 opening probe, and receives exact-SHA
review. The refresh of M4 onto the integrated M3 closure, M4 acceptance, any
rejoin, rebind child or closure candidate, and any change to a Closed gate's
bound bytes remain under the ordinary inherited-aggregate obligations unless
separately overridden. Any inherited regression actually observed still
blocks.

This override changes one development-time evidence procedure. It changes no
released public surface or accepted ADR decision, does not weaken an M4
outcome or witness, and does not accept M4 or ADRs 0023, 0024, 0026 or 0028,
authorize product implementation, approve integration, closure, release, tag
or publication, or report an unrun check as PASS. The aggregate rerun started
for `8fc7f5c` was stopped without a result and is recorded as waived, not
unavailable. This commit adds only this disposition; an independent exact-SHA
read must approve its changed path and authority scope before the M4 plan
cites it.

<a id="disposition-m4-planning-packet-approval-2026-09-11"></a>
### M4 planning packet approval — 2026-09-11

The maintainer's actual instruction was: “ok i approve m4. we'll leave it open
until m3 is done.” It was given after the independent completeness reviewer
reported the frozen ledger resolved at
`1b181f916b99556165395da0499d4dbb02a55542` on branch `m4`.

This approves the Open M4 planning packet at that exact revision as complete
for its lookahead purpose: the plan pair, gate, runner, support scripts,
outcome manifest, opening probe, prerequisite ADR proposals 0023, 0024, 0026
and 0028 as revised, and the documentation obligations. M4 stays `Open`. This
is not acceptance: no Acceptance row is recorded, no envelope or gate digest
is bound, no ADR is accepted, and no implementation, integration, release,
tag or publication is authorized. Acceptance still requires M3 to be Closed
and integrated, the refresh of M4 onto that exact base, every inherited gate
green with M4's own distinct red, a fresh exact-SHA review, and the
maintainer's explicit acceptance disposition recorded in its own transition.
Until then, planning edits to M4 remain ordinary Open-lineage work under the
recorded aggregate overrides.

<a id="disposition-m4-vision-core-telemetry-2026-09-13"></a>
### Vision change: telemetry admitted as core's one external dependency — 2026-09-13

The independent M4 review at `fa897361598467ffc53d3042a6ae7212acd2e3dc`
found that outcome 7 required `:telemetry` in core against the vision's
no-external-core-dependency rule and `AGENTS.md`, and offered two resolutions:
keep core stdlib-only and translate diagnostics to telemetry at an edge, or
an explicit maintainer vision change. Asked to choose, the maintainer selected
**"Explicit vision change to admit :telemetry in core"**, with the telemetry
adapter living in a new edge application `loopex_telemetry` and the proposed
trace limits bound.

This disposition records that vision change under the rule that reversing a
vision boundary names the principle, the evidence, the compatibility impact
and the migration path:

- **Principle changed.** Concept §7 (stack and dependency doctrine) and
  Technical §7.2 (core dependency budget) said the core depends only on Elixir
  and Erlang. They now admit exactly one external library, `:telemetry`, by
  name; every other exclusion in §7.2 stands, and reporters, exporters and
  OpenTelemetry remain edges. `AGENTS.md`'s product non-negotiable is updated
  to the same wording.
- **Evidence.** `:telemetry` is pure Erlang with no dependencies of its own; it
  dispatches events and attaches nothing in core; a Loopex-owned dispatch
  registry would re-implement it and every consumer would need a bespoke
  adapter; OTP `:logger` reports are non-standard for metrics consumers. The
  alternative edge translation was judged by the maintainer to cost more than
  the boundary it preserved.
- **Compatibility impact.** No released public surface, journal, event or
  protocol record changes. The core dependency budget check and application
  inventory change under the M1 dependency-oracle transaction the M4 plan
  names; embedding hosts gain one transitive dependency.
- **Migration and rollback.** Removing the dependency and the emission points
  restores the previous behavior without data migration; the vision sentences
  revert with it. The M4 plan carries the rollback obligation.

This is a maintainer decision on a founding boundary, transcribed here and in
the vision pair together. It accepts no ADR, plan or milestone, authorizes no
product implementation, and changes nothing about M3. ADR 0030 carries the
mechanics and remains Proposed until its own acceptance.

<a id="disposition-m4-preacceptance-contract-choices-2026-09-13"></a>
### M4 pre-acceptance contract choices — 2026-09-13

During preparation of the Open M4 candidate, the maintainer approved the
recommended scope and safety choices transcribed in Proposed ADRs 0023, 0024
and 0028:

- [ADR 0023](../adr/0023-experimental-public-session-protocol.md#concept)
  defers `session.list` because the current directory query eagerly loads its
  entries. A client resumes by a known session ID. Project-resource trust is
  fixed at host launch; no `project_resources.inspect` or
  `project_resources.decide` wire method is promised.
- [ADR 0024](../adr/0024-durable-interaction-lifecycle-and-host-policy-authority.md#concept)
  permits at most two committed answer-then-defer transitions after the first
  question, for three operator questions in total. Another defer denies.
- [ADR 0028](../adr/0028-bounded-artifact-retrieval.md#concept) uses safety
  ceilings of a 64 MiB object, 60 seconds and 128 MiB of work to open, 32 KiB
  per read with a five-second deadline, ten minutes per transfer, two concurrent
  transfers per connection and four per runtime, and 1 GiB of cumulative work
  per connection with at least 1 MiB debited per open. These are limits, not
  throughput promises.

These choices guide the proposed ADR text and bound M4 planning fixtures.
They do not accept any ADR or the M4 plan, authorize product implementation,
approve the floor-holder transactions, or authorize a merge, tag or release.
Each ADR still needs its own explicit acceptance disposition and independent
exact-SHA review before the M4 acceptance transition can rely on it.

<a id="override-disposition-m3-implementation-gate-cadence-2026-09-10"></a>
### M3 implementation gate cadence — 2026-09-10

The maintainer's current implementation instruction is:

> finish m3 implementation. do unit tests until complete. do overall m0, m1, m2 and m3 gate check after you think m3 is complete (only at the end because they take time to run). ask me questions to clarify or make architectural changes.

The explicit clarification asked:

> Do you explicitly approve replacing M3’s full-gate checks at implementation start and intermediate workstream rejoins with focused tests, while requiring the complete M0–M3 gates at the final candidate? This changes timing only; all required tests and pass criteria remain.

The maintainer answered: **"Approve end-only full gates"**.

Under [the explicit maintainer override](../../AGENTS.md#maintainer-override),
this instruction replaces the continuing full-gate timing requirements for
ordinary M3 implementation in AGENTS.md, the accepted M3 Technical envelope's
"Cheap checkpoints and full contract evidence" section and the M3 gate's
"Runner Modes and Evidence Cost" section. Focused unit, conformance, integration
and repair tests run during implementation. Full M0, M1, M2 and M3 gates run
after the implementer judges all M3 outcomes complete, rather than at the
implementation start, intermediate checkpoints or parallel-workstream rejoins.
The full M3 command already owns the M0–M2 predecessor aggregate; its retained
per-gate results may satisfy that final set without duplicate invocations.

This approval changes timing only. It changes no bound artifact, protected
witness, gate command, outcome, acceptance or closure record, ADR decision,
required real path or pass criterion. Intermediate focused evidence is not
full-gate evidence. An observed inherited regression still requires repair,
and the assigned executor flake still requires stable evidence before closure.
If final checks find a defect, repair it and rerun affected final evidence at the
resulting candidate; never carry a PASS across invalidating changes. Any needed
architectural or binding change must be raised separately under its existing
decision procedure. This disposition grants no M3 closure, product merge or
release and changes no M4 obligation.

This standalone disposition must receive independent exact-SHA read-only
review before implementation relies on its replacement schedule. Historical
acceptance evidence and the acceptance-only aggregate waiver keep their
original scope and meaning.

<a id="override-disposition-m3-workflow-evidence-2026-09-10"></a>
### M3 workflow evidence allocation — 2026-09-10

The maintainer was asked:

> Approve separating the workflow evidence this way: deterministic tests prove the complete CLI/embedding workflow with the existing isolated test provider, and the required real-provider test proves the exact source-built CLI plus production companion end to end? The packaged companion has no local test-endpoint option. This preserves both proofs without adding a production transport API solely for testing, but changes where the plan’s evidence is collected.

The maintainer answered: **"Approve the evidence split"**.

Under [the explicit maintainer override](../../AGENTS.md#maintainer-override),
this replaces only the continuing requirement that the deterministic outcome-3
selector alone prove the complete workflow through the exact production
companion. The affected sources are the accepted M3 Technical envelope's first
workflow and evidence mapping and the M3 gate's outcome-3 obligation. The
deterministic selector proves the complete admitted skill, actual authorized
tool, and full-object artifact workflow through embedding and the source-built
CLI with the existing isolated test provider. It identifies that test provider
as such. The attended real-provider selector separately proves the complete
workflow through the exact source-built CLI and production companion pair.

Both proofs remain required for closure. Preserve every protected selector
identity, actual tool/artifact operation, trusted launch and recovery check,
production package identity check, and the separate public Git import. A test
provider result is never reported as a production companion or real-provider
result. No new production transport option, dependency, public API, gate command,
bound artifact, accepted ADR or historical evidence changes. This approval does
not waive either lane or authorize M3 closure, integration to main or release.

This standalone disposition receives independent exact-SHA read-only review
before the replacement evidence allocation is relied on.

<a id="disposition-m3-implementation-completion-2026-09-11"></a>
### M3 implementation completion decisions, 2026-09-11

The maintainer received three separate recommendations:

> May I repair the published `m3` history, then push the completed fixes? Some development commits accidentally changed a protected M2 test file, so the history checker rejects the branch even though the file is now restored. The reviewed repair preserves the accepted milestones and final product files, but changes affected development commit IDs. A complete backup exists; `main` and `m4` stay unchanged. The replacement is `7995965da0de9a51ace807da4183498142c42cd9`, guarded against replacing anything newer than the last pushed `07018b93e2084bf3e4d278e677f0984bcda5fb48`.

> May I implement the accepted ADR 0027 memory fix in `Control`? The runtime currently keeps used provider-permission entries after requests finish, allowing that memory to grow. The fix removes an entry only after its completion is safely recorded, while preserving ownership checks, rejection of reused or stale permissions, and retry/accounting rules. Automatic approval review requires your explicit authorization for this exact change.

> May I add `LoopexComposition.with_runtime/2`, a shared helper that starts a temporary runtime, runs an operation, and shuts down all its processes? Recovery needs this temporary runtime to inspect a saved session before opening it with the correct configuration. The helper would report success only after orderly shutdown, and report an error if cleanup is forced or cannot be confirmed. This adds a public API while preserving existing `start/1` behavior, so the repository contract requires your architectural approval.

The maintainer answered **"Approve all recommendations"**, then
**"Approved all recommendations.  Go"**. These instructions approve the three
named changes. They grant no milestone closure, product merge to `main`, release,
gate weakening, or change to an accepted ADR decision.

The reviewed history replacement was pushed with an exact lease against
`07018b93e2084bf3e4d278e677f0984bcda5fb48`; the completed acquisition and
compatibility repairs then advanced `m3` normally to
`720d1d76a28140e69e8acbae30c7b7df36a360a4`. Accepted milestone and ADR candidates,
their bindings and their original evidence remain unchanged and reachable.
The original published lineage is retained in a verified complete Git bundle.
This repairs the unaccepted implementation lineage and creates no history-check
exception. All later pushes use ordinary fast-forwards.

Control retirement must implement accepted ADR 0027 and retain its required
durable-settlement, current-owner and current-attempt proof. The composition
helper is approved as an experimental host API for temporary use of the existing
reference stack. It must introduce no durable field, new port, dependency, or
alternative session recovery path. Exceptions must propagate after cleanup; forced or unconfirmed
cleanup cannot be reported as success. Its ownership and compatibility contract
is recorded in the [architecture pair](architecture.md#concept-arch-applications).
Focused tests must prove orderly and failed cleanup, configuration preservation
and the exact retained skill snapshot before final M0–M3 qualification.


<a id="override-disposition-m3-commit-titles-2026-09-11"></a>
### M3 published commit-title exception, 2026-09-11

The maintainer received this recommendation in the two-blocker approval dialog:

> Commit titles: eight already-pushed commits have titles that are too long or use the wrong format, so bootstrap stops. Approve an exception for only those eight commits? This preserves published history, keeps all product tests and future commit checks intact, and authorizes recording, reviewing, implementing, testing, and pushing the exception to m3.

The recommended choice was **"Approve the eight-title exception (Recommended)"**.
The maintainer answered **"Approve both recommendations."** This disposition
records the commit-title recommendation only; the other recommendation grants
fixture-specific attended-test permission and changes no repository rule.

Under [the explicit maintainer override](../../AGENTS.md#maintainer-override),
this replaces only the continuing title-format and 72-character-limit
requirements in `scripts/check-commit-messages.sh` for these eight immutable
commits in the M3 implementation lineage:

| Commit | Existing title |
| --- | --- |
| `3eaeaafb0cb1af6135dccb64d63354944cb1b301` | test(M3): use causal acquisition readiness and finalize implementation record |
| `2dc0ad4ede416da068004b14333b26441a973f2f` | fix(skills): validate contained trees and bounded pack content before publication |
| `2f2dce216cdb63c7387073d8834e756c759ba5c6` | feat(composition): bracket configured skill recovery with confirmed cleanup |
| `262ad1a04274a0b52e19484e76c621842f158676` | Merge branch 'm3' into codex/m3-cli |
| `9f742e52d32115c8dedd5c2df47d549a60e86777` | Merge branch 'm3' into codex/m3-cli |
| `3c8dcc1bc4951d35f6cdee4e695e9682e8bc53db` | M3 CLI: verify retained Git skill commands |
| `cdc086900515e1bd4d890bb7c62ab3de846ef6fa` | M3 CLI: admit selected skills before runs |
| `461d44dc004740110231a459c8359efe407d09e6` | M3 CLI: add skill command and launch wiring |

Each exception must be matched by its complete SHA and reported as waived.
Preserve the fixed baseline, complete-history requirement, commit enumeration
and stream accounting, prospective title controls, and unconditional commit-body
attribution and scan-error checks. Every other commit remains subject to the
complete policy. No history rewrite is authorized or needed. Every accepted
candidate, bound artifact, disposition, and historical evidence identity remains
unchanged. No M0–M3 gate binds this checker's bytes, so this change needs no
replacement gate binding.

Before changing the checker, independently review this standalone disposition
commit at its exact SHA. Then prove that the original check refuses only these
eight titles, the replacement reports all eight exceptions, a ninth malformed
title still fails, and attribution/error scanning remains effective. Run the
complete bootstrap check and the final M0–M3 qualification on the resulting
candidate. Commit and push the approved work to `m3` using ordinary fast-forwards.

This grants no exception to a product test or other check, no additional title
exception, and no ADR change, milestone closure, product integration to `main`,
tag, or release. The red commit-title evidence retained for
`f82fb25270ebcdecb23730d57187e9d3ac28b7ca` remains true for that revision.

<a id="override-disposition-m3-acquisition-deadline-witness-2026-09-11"></a>
### M3 acquisition deadline witness timing, 2026-09-11

The maintainer received the reviewed test-only repair proposal:

> Approve this test-only repair? The current test gives Git only 0.75 seconds to start. The proposed repair uses a 10-second import deadline and a 25-second outer watchdog, requires proof that Git actually started, then verifies that the deadline stopped it and left no published files or running process. Production limits stay unchanged; this adds about nine seconds to this test.

The proposed patch has SHA-256
`1dc8f2062ee6b94e9806b2d0e5f8363a1373a9561c2abf0a89461b35387e02eb`.
After the pending choice was restated as the test-only 10-second deadline and
25-second watchdog, the maintainer answered **"authorize test-only 10 second"**.

Under [the explicit maintainer override](../../AGENTS.md#maintainer-override),
this replaces only the existing 750-millisecond deadline allowance and its
delayed-wrapper witness in
`apps/loopex_composition/test/skill_acquisition_test.exs`, within the protected
case `import uses the authorized executor with closed configuration and bounded cancellation`.
It is the explicit exception to AGENTS.md's prohibition on increasing test
timeouts for this repair. The replacement uses a 10,000-millisecond import
deadline and a 25,000-millisecond outer watchdog, allowing the import period,
the existing cleanup period and the existing owner-stop bounds.

The witness must observe a positive process-group identity and a live Git
wrapper before awaiting expiry. The wrapper remains held throughout the test;
neither the successful path nor failure teardown releases it. A successful
witness requires the exact coordinator deadline refusal, or a matching retained
executor receipt with the reported outcome and executor-owned deadline
diagnostic. Elapsed time alone and a generic error are insufficient. Preserve
proof of an empty process group, no escaped execution, no published pack, no
provenance record and no staging residue. Failure teardown cannot supply the
successful-path proof. Retain bounded result and receipt summaries when the
deadline evidence is absent or inconsistent.

This is a test-only change. Production deadlines, cleanup bounds, APIs, accepted
ADR decisions, gate commands, protected case identity and every other witness
remain unchanged. The test file is not a digest-bound artifact of M0–M3; no gate
binding changes. The original missing-readiness failure at
`2df5eda7ba7c5e62adc9408b19e52737aa2c0ac7` remains failed evidence. Its original
cause was not established; the diagnostic pass does not erase it or waive the
replacement witness's required proof.

This standalone commit adds only this disposition. An independent reviewer
must examine its exact SHA before the test patch is applied or executed. Then
run the complete acquisition test file on the current and accepted-floor macOS
toolchains and on Linux serenity. Retain source, command, seed, result and log
identity, and diagnose any failure before another run. The complete final M0–M3
gates remain required on the resulting candidate under the existing approved
cadence. Commit and push completed work to `m3`; this approval grants no M3
closure, product integration to `main`, release or waiver of another finding.

<a id="disposition-m3-provider-diagnostics-design-2026-09-11"></a>
### M3 bounded provider failure diagnostics design, 2026-09-11

The maintainer requested the diagnostic choice in plain English. The presented
recommendation was:

> **Add limited error reporting — recommended.** Make it report categories such as connection failure, provider rejection, or response-processing error, without exposing keys or response contents. This requires a small code change, architecture approval and fresh tests.

The alternative preserved the companion and observed only its network
connections. The recommendation explicitly stated that the missing information
would be repaired first and the underlying failure would still need to be
identified and resolved. The maintainer answered **"1"**.

This selects the bounded design described by proposed
[ADR 0029](../adr/0029-bounded-provider-failure-diagnostics.md#concept) and its
[technical companion](../adr/0029-bounded-provider-failure-diagnostics-technical.md#technical-depth).
The external design packet had received independent read-only clearance at
SHA-256 `d48818d1dbdb19fe2aac8cbe24929761036be998001ff71e1eb6a2df24f00880`.
Its scope is one finite failed-stage/category pair in the companion's existing
private channel, available to bounded test-owned observation only after a
validated terminal and clean EOF. Every intervening protocol failure discards
the provisional pair. An outer fallback cannot replace the first classified
failure. No raw exception, provider message, credential, new public API,
durable record, production observer, larger frame limit or dependency is added.

Preserve the generic Model error, dispatch and retry authority, settlement,
accounting, permit retirement, same-source build checks and cleanup proof.
The named closed-schema fixtures may be proposed for the version-2 contract;
their historical identities and unaffected guarantees remain required. This
record does not itself replace a protected test restriction or accept an ADR
or M3 amendment candidate. Complete the applicable reviewed acceptance records
before dependent implementation.

The original Linux failure at source
`8e9a6c3432fd35784b52a435d12e922b5f33098d` remains unresolved. Supplemental
instrumented successes and the completed macOS gate do not assign its cause.
Retain original failures and subsequent results separately. The existing
approved final-gate cadence remains in force, including Linux serenity and
required actual provider paths. This choice waives no failed test or finding,
authorizes no additional supplemental provider calls, and grants no M3 closure,
product integration to `main`, tag or release.

<a id="override-disposition-m3-amendment1-gate-cadence-2026-09-11"></a>
### M3 Amendment 1 gate cadence — 2026-09-11

The maintainer received two questions: acceptance of the exact ADR 0029 pair at
`25fcb94de0d980c3724377670b25cbd14fe638ec`, and this timing question:

> May the upcoming documentation-only M3 amendment commits also use your “full gates only at the end” schedule? I recommend retaining focused status, binding, documentation and bootstrap checks, plus independent review, and deferring full M0–M3 runs until implementation is complete. All final tests and pass criteria stay unchanged; deferred checks are recorded as unrun. The existing exception covers ordinary implementation, while AGENTS.md separately requires full checks for formal amendments.

The offered choices were **"Extend end-only schedule (Recommended)"** and
**"Run full gates for amendment"**. After requesting and receiving the essence
of the proposed ADR, the maintainer answered **"Accept both"**. This standalone
record transcribes the timing decision; the ADR acceptance is recorded in its
own administrative transition.

Under [the explicit maintainer override](../../AGENTS.md#maintainer-override),
this replaces only the full-gate execution timing at the documentation-only
M3 Amendment 1 proposal `A` and its immediate rebind child `R` for ADR 0029.
It covers the direct gate run at `A` and inherited/full gate runs at `R` required
by AGENTS.md's v1 amendment procedure, the plans index's amendment mechanics,
the accepted M3 Technical envelope and the M3 gate's evidence-cost section.
Full M0, M1, M2 and M3 execution is deferred to the completed implementation
candidate under the existing final qualification schedule, including Linux
serenity. Deferred checks are **unrun**, never PASS; retained earlier results
remain evidence for their original source revisions.

Keep focused status, artifact and envelope binding, documentation and bootstrap
checks appropriate to each revision, plus independent exact-SHA review. At `A`,
binding-dependent checks must refuse only for the deliberately stale M3 binding;
verify binding-independent checks directly. At `R`, status, binding validation
and bootstrap must pass. The new diagnostic behavior remains explicitly unproved
until the first implementation checkpoint establishes the behavioral red and
the implementation supplies its required conformance evidence.

The one-parent direct `A` to `R` transaction and exact-candidate acceptance
remain required. No bound artifact, gate command, protected witness, required
real path, deadline, count, outcome, final pass criterion or accepted ADR decision
changes through this timing record. An observed failure still requires repair
or explicit disposition; no historical failure is waived. This grants no
amendment acceptance, M3 closure, product integration to `main`, tag or release.

This commit adds only this disposition. An independent read-only reviewer must
examine its exact SHA before dependent work relies on the timing exception.

<a id="disposition-adr-0029-acceptance-2026-09-11"></a>
### ADR 0029 acceptance — 2026-09-11

The maintainer was asked:

> Do you accept ADR 0029—the bounded provider failure diagnostics proposal—at reviewed and pushed m3 SHA 25fcb94de0d980c3724377670b25cbd14fe638ec? Your design choice is already recorded; this accepts the exact document pair.

The offered choices were **"Accept ADR 0029 (Recommended)"** and
**"Keep ADR 0029 Proposed"**. A second question concerned the amendment's
full-gate timing. After requesting and receiving the essence of the ADR, the
maintainer answered **"Accept both"**. The second decision is retained in the
separately committed
[timing disposition](#override-disposition-m3-amendment1-gate-cadence-2026-09-11).

This accepts the exact Proposed
[ADR 0029 Concept](../adr/0029-bounded-provider-failure-diagnostics.md#concept)
and [Technical depth](../adr/0029-bounded-provider-failure-diagnostics-technical.md#technical-depth)
pair at `25fcb94de0d980c3724377670b25cbd14fe638ec`, with Concept SHA-256
`12a1138603733aa7e71770b00460339569f149fc4332defc3cd60e3712d5a7d1`
and Technical SHA-256
`4cb088578dce875fe2c577282242b61bb98c6f8f9b384f1ad4be09bbb101f1e4`.
Independent exact-SHA review cleared that candidate, and its canonical status
check passed with unchanged clean source. The reviewed timing-only disposition
is its own intervening commit; it is not the ADR's bound candidate.

This administrative transition changes only the Concept status and Acceptance
row, this new disposition and derived ADR index statuses. It preserves both
decision texts and all ADR 0019 accepted bytes. The historical Proposed pair's
acceptance-pending explanation describes its preparation state; this record
and its completed Acceptance row supply the subsequent authority.

The decision permits the bounded private category contract it specifies;
implementation still requires acceptance of the exact M3 Amendment 1 proposal
and its direct rebind. This accepts no unseen amendment, waives no failure,
authorizes no additional supplemental provider call and grants no M3 closure,
product integration to `main`, tag or release.

<a id="override-disposition-m3-unaccepted-amendment-replacement-2026-09-11"></a>
### M3 unaccepted amendment replacement — 2026-09-11

The implementer identified an enforcement defect in the published, unaccepted
M3 Amendment 1 proposal at
`78610277fd102e549ed9a71e73d3ed2967fc2075`: the status checker required a prior
plan citation as well as the independently reviewed standalone approval record.
The contract requires the record to predate dependent work; the record already
exists at `397031d10353a4b3aef177943b2e4c45aef0fb0a`.

The implementer explained:

> Because the faulty proposal is already pushed, replacing it will need your approval after the repair is concrete and reviewed.

The maintainer answered **"I approve replacement"**. Under
[the explicit maintainer override](../../AGENTS.md#maintainer-override), this is
one exception to the ordinary-fast-forward requirement retained in the
[M3 implementation completion disposition](#disposition-m3-implementation-completion-2026-09-11).
It authorizes replacing that unaccepted proposal on `m3` and `origin/m3` with
the reviewed checker correction, this standalone disposition and a recreated
documentation-only Amendment 1 proposal above unchanged accepted ADR transition
`b5f9a4bf46f8e8a65b5fffd87f72327954742f4e`. All previously accepted candidates
and their evidence remain unchanged and reachable. `main` and `m4` are untouched.

The correction admits a first citation only on an already-Accepted single-parent
lineage with an unchanged Acceptance record and a unique override anchor in
that same parent. Existing missing/duplicate-anchor, same-commit authority,
initial-acceptance and split-parent laundering refusals remain required.
Focused tests must reproduce the false refusal, prove this valid case and retain
the existing negative guarantees. Independently review the exact correction
and this disposition before replacement. The recreated proposal must pass its
focused checks apart from the expected stale M3 binding; full gates retain the
approved end-only cadence and are not reported as passed here.

The original proposal and complete ancestors are retained in a verified Git
bundle, SHA-256
`eb0a3848e7c83b3cd778e593250451fb9c1f0f4dbd25eb740efe09f9450c002f`,
with the failed bootstrap and passing component evidence in the maintainer's
review archive. The original bootstrap log SHA-256 is
`c804bdf4989961ac132b1148a0153ea040dcd047a7533eaceb5fe7614acc89ee`.
Those results keep their original source attribution and are not waived.

Use an exact remote lease against
`78610277fd102e549ed9a71e73d3ed2967fc2075`; refuse the replacement if the remote
has advanced. Verify a clean local `m3` at that same original tip before moving
it. This authorizes this replacement only; later pushes use ordinary
fast-forwards. It does not accept the recreated amendment, relax the direct
proposal/rebind sequence, authorize diagnostic implementation before that
acceptance, or grant M3 closure, product integration to `main`, tag or release.

<a id="disposition-m3-amendment-1-acceptance-2026-09-11"></a>
### M3 Amendment 1 acceptance — 2026-09-11

The maintainer was asked:

> Do you accept M3 Amendment 1 at `0c796c215e1405a6dfd9330e4ff6876fdb6e09dd` so I can record acceptance and implement the already-approved provider diagnostics? The replacement is pushed and reviewed. AGENTS.md requires acceptance of this exact plan update before implementation continues.

After requesting an English explanation, the maintainer was told that this
updates M3's formal scope for the already-approved diagnostic design, permits
implementation and testing, and retains final macOS/Linux gates and separate
closure approval. The maintainer replied **"I accept"**.

This accepts the exact [M3 Concept plan](../plans/M3.md#concept),
[Technical depth plan](../plans/M3-technical.md#technical-depth) and
[Amendment 1 gate](../plans/M3-gate.md#amendment-1) at
`0c796c215e1405a6dfd9330e4ff6876fdb6e09dd`. The Acceptance row records the
candidate's Concept, Technical depth and gate digests. Independent exact-SHA
review cleared the candidate. Its canonical bootstrap ended only at the
expected stale Concept binding; 75 governance tests passed at seed 728659,
and inspection, documentation, formatting and whitespace checks passed.
This was proposal evidence, not status/bootstrap or full-gate PASS.

This immediate administrative child changes only the Acceptance row and this
fresh disposition. Both normative envelopes, the gate, product bytes, the
Accepted lifecycle and derived status records remain unchanged. The
[approved amendment cadence](#override-disposition-m3-amendment1-gate-cadence-2026-09-11)
retains focused binding/status/bootstrap checks and independent exact-SHA
review at this child before dependent implementation; full M0–M3 gates remain
deferred to the completed candidate, including Linux serenity.

The accepted scope is the bounded private diagnostics of accepted ADR 0029.
Historical failures and earlier evidence retain their original attribution;
this acceptance waives no failure and grants no additional supplemental
provider call, M3 closure, product integration to main, tag or release.

<a id="override-disposition-m3-commit-title-replacement-2026-09-12"></a>
### M3 commit-title replacement — 2026-09-12

Three unaccepted implementation commits above
`3e8ae23d74048f23faaef109c7b1eb3a7185d739` omitted the required milestone
marker from their titles. Both final gates at
`0a1b57f1ee7b89d24080a7a48e2de48d4692d2ff` stopped at the bootstrap
commit-message check after 1,196 deterministic tests passed on each platform.

The maintainer was asked:

> May I replace the last three published m3 commits with the reviewed versions that add `(M3)` to their titles? All file contents stay identical, and the original history is backed up. The replacement is e17fb2e217eedb94040277dbda5f7b02c9195ce3, followed by a separate reviewed record of this permission. The push will refuse to proceed if origin/m3 has advanced beyond 0a1b57f1ee7b89d24080a7a48e2de48d4692d2ff. This corrects my commit-message error without weakening the checker; later pushes remain ordinary fast-forwards.

The maintainer answered **"Approved"**. Under
[the explicit maintainer override](../../AGENTS.md#maintainer-override), this
authorizes one exception to the ordinary-fast-forward requirement in the
[M3 implementation completion disposition](#disposition-m3-implementation-completion-2026-09-11).
It replaces only these three published commit IDs, followed by this standalone
approval record:

| Original commit | Reviewed replacement |
| --- | --- |
| `19db12c40eca2a62ed87fb25608d065db9cbf500` | `69f06dd2cb7ae6b2019cd7be2ae2b79ef78f6dea` |
| `3625b6d3058bbe27e484534d9c08cfa5e1e2375c` | `9068461998a084bf82f811551bf33eadfa50a3a3` |
| `0a1b57f1ee7b89d24080a7a48e2de48d4692d2ff` | `e17fb2e217eedb94040277dbda5f7b02c9195ce3` |

Independent review verified that each corresponding tree is identical. Only
the three titles and their rewritten parent IDs differ; author and committer
identities, timestamps and message bodies are preserved. Every ancestor of the
unchanged base remains reachable, including all accepted and bound candidates.
The canonical commit-message check passed at the reviewed replacement. The
checker, accepted plan and ADR decisions, gate criteria and bound artifacts
remain unchanged. This exception applies only to publication of this corrected
implementation lineage; it does not add a commit-title waiver.

The original complete history is retained in a verified Git bundle, SHA-256
`01bc59f1f3bd6efa2dec239088af0edf62476fda6dd246b34a6f770db4c28c27`.
The original macOS and Linux gate results remain failures at their original
SHA. Their passing component results are retained with those runs; neither
tree equivalence nor this permission turns them into full-gate PASS or evidence
executed at a replacement SHA. The joint evidence manifest SHA-256 is
`6d7880e673df2868785b44d930d59fd08161020db593fe43955bbdfa06b7b294`.

This disposition lands alone in the immediate child of the reviewed
replacement. Independently review that exact child and its changed path before
publication. Verify clean local `m3` and the remote tip at
`0a1b57f1ee7b89d24080a7a48e2de48d4692d2ff`; use that exact remote lease and
refuse replacement if either has advanced. Run the canonical commit-message
check on the resulting candidate before publication and final qualification.
Later pushes use ordinary fast-forwards. Fresh final macOS and Linux gates
must name the resulting candidate and retain the approved end-only cadence.
This approval grants no historical-failure disposition, M3 closure, product
integration to `main`, tag or release. `main` and `m4` remain unchanged.

<a id="override-disposition-m3-selector-diagnostics-2026-09-12"></a>
### M3 shared-selector diagnostics repair — 2026-09-12

The maintainer was asked:

> Approve the reviewed diagnostics patch d2bfe33c46ff83c97fb80ff4406c78c37e1d878739854af03f26cc65a8e7c1c8, its M1/M2/M3 binding updates, and the named exception to M2’s requirement to keep the old M1 runner bytes? I recommend using focused checks during these three updates and reserving the complete M0–M3 gates for the final candidate on macOS and Linux. Authorize the independent reviewer (/root/m3_independent_review) to accept only exact commits matching this patch and the listed binding changes, with your permission recorded and independently reviewed before editing. Each milestone keeps its separate sequential update and exact-commit review; deviations stop for your decision. This does not waive any failure or authorize ADR changes, closure, merge to main, or release.

The maintainer answered **"Approve repair, final-only gates, and limited delegation (Recommended)"**.

Under [the explicit maintainer override](../../AGENTS.md#maintainer-override),
this approves the exact external patch with SHA-256
`d2bfe33c46ff83c97fb80ff4406c78c37e1d878739854af03f26cc65a8e7c1c8`
against `5c74164deb610016854a2a77ce79d650d269c669`. The reviewed decision packet
has SHA-256 `22abae8ddbbf8910e7e00c7eb559fb69cc00f809a684451808ac529b796b0ac3`.
The immutable proposal and focused evidence are retained in the maintainer's
`loopex-reviews/m3-selector-diagnostics-proposal-5c74164-ps9qhhkh` archive,
whose manifest SHA-256 is
`f1f79d054c384ea07a22818aad826ef07725ce5b4ab3ffb5af2d567abcf96e1a`.
That archive predates this approval and correctly remains labelled a proposal.

The repair changes only failure diagnostics in `scripts/m1-exunit-runner.exs`
and adds two synthetic tests in its existing
`apps/loopex/test/m1_exunit_runner_test.exs` corpus. Failure output retains the
invocation mode and seed, bounded failed-case identifiers and source locations,
and closed error categories and operand types. It retains at most eight event
records, two failure summaries per record and 4,096 bytes per detail line, with
explicit omitted counts. It excludes arbitrary messages, assertion values or
expressions, provider bodies, captured logs and stack arguments. Ambiguous
external source paths remain unavailable. The existing five corpus cases,
authoritative success output and digest inputs, required counts and exclusions,
real-provider paths and exit predicates remain unchanged.

The named holders and binding work are:

| Holder | Approved replacement bindings |
| --- | --- |
| Closed `M1` | Shared runner and corpus, their embedded digests in `scripts/check-m1-gate.sh`, and that script's own Bound Artifacts row; one additive gate generation in `M1.md` and the next amendment in `M1-gate.md`. |
| Closed `M2` | Shared runner and corpus, their embedded digests in `scripts/check-m2-gate.sh`, and that script's own Bound Artifacts row; one additive gate generation in `M2.md` and the next amendment in `M2-gate.md`. |
| Accepted `M3` | The two shared rows in `M3-gate.md`, the next amendment and its acceptance rebind in `M3.md`; only conforming explanation in the plan pair where needed to describe these diagnostics. |

The continuing requirement in [M2's gate](../plans/M2-gate.md) to retain the
exact shared runner and corpus bytes that M1 closed with is replaced, for this
M3 repair only, by the exact reviewed diagnostic bytes and these per-holder
bindings. Historical Acceptance and Closure records remain unchanged and true
for their revisions. M0 has no direct binding to either changed shared file.

This record lands alone and receives an independent exact-SHA review before
any dependent edit. Then complete M1, M2 and M3 in that order. M1 and M2 each
use their own Closed-gate generation proposal and immediate one-parent rebind;
M3 uses its own Accepted-plan amendment proposal and immediate one-parent
rebind. Every proposal and rebind retains its independent exact-SHA review
and each holder's status validation before the next holder proceeds. Binding
checks at a proposal must identify the expected pending or stale binding;
unsettled other holders are not reported as passing. Every holder must be
settled before final qualification.

For these three transactions only, focused checks replace full-gate runs at
proposal and rebind checkpoints. Validate exact patch identity, the owning
diagnostic corpus, unchanged success-report semantics, script syntax and
digests, and the applicable status and binding rules. The copied seven-case
corpus already passed at seed 3107 on Elixir 1.20.3 / OTP 29 and Elixir 1.17.0 /
OTP 26; retain its exact commands and artifact hashes with the proposal.
These focused results do not count as final-source qualification. Run the
complete M0–M3 gates once the final candidate is complete, on macOS and Linux
serenity. Required pass criteria and the obligation to resolve failures remain.

The independently recorded delegate is **`/root/m3_independent_review`**.
Its acceptance scope is only actual, exact proposal commits matching the
approved patch, the binding inventory above and this validation timing. It
must review each existing proposal SHA and explicitly accept that SHA before
its rebind; this is no advance acceptance. Each rebind records that acceptance
in one fresh disposition. The implementer may not supply the delegate's
decision. Deviations stop for the maintainer's decision.

This approval waives no historical or future failure, changes no ADR decision
or product contract, and grants no additional supplemental provider call,
M3 closure, product integration to `main`, tag or release. The lost details of
the Linux M1 failure at `5c74164deb610016854a2a77ce79d650d269c669` remain
unavailable; later diagnostic evidence cannot assign its cause retroactively.

<a id="override-disposition-m3-sequential-binding-checker-2026-09-12"></a>
### M3 sequential binding checker correction — 2026-09-12

Before the first shared-byte proposal, inspection and four synthetic controls
of the actual artifact-history validator proved a conflict with the existing
sequential-holder rule. An M1 update leaves M2/M3 temporarily bound to old
bytes; the checker rejects that historical revision even after their later
updates. No bound artifact was changed while identifying this defect.

The maintainer was asked:

> May I fix the checker so M1, M2 and M3 can be updated one at a time as you approved, and extend the independent reviewer’s limited authority to approve that correction after testing and exact-commit review? Today the checker permanently rejects the temporary old bindings for milestones waiting their turn. The correction will still reject altered bytes, invalid update order, and any unfinished sequence at final validation. The diagnostics patch stays unchanged, and all final macOS/Linux gates remain required. Your previous approval was limited to that exact patch, so this additional checker change needs approval.

The maintainer answered **"Approve checker correction (Recommended)"**.

This extends the [shared-selector diagnostics approval](#override-disposition-m3-selector-diagnostics-2026-09-12)
only to correcting the status checker and its governance tests so they enforce
the already-required per-holder sequence. The diagnostic patch remains exactly
`d2bfe33c46ff83c97fb80ff4406c78c37e1d878739854af03f26cc65a8e7c1c8`.
The scope includes the current artifact/history validation path and an explicit
internal holder scope for intermediate checks. It creates no new product API,
command-line surface, ADR, transaction marker or gate criterion.

Derive the old/new digest pairs for the shared artifacts changed by the first
proposal, and their complete holder set, from that proposal and its real
parent. Keep those shared identities fixed. Only holders still awaiting their
own update may retain their old rows while actual source bytes must match the
proposed new digests. Already-rebound holders remain strict. Holder-local
bound files may change atomically at their owning holder's valid proposal
within the previously approved inventory; these changes cannot introduce
another shared-byte change or enlarge the pending holder set.

Reuse the existing v1/v2 proposal and immediate one-parent rebind checks.
Intermediate holder-scoped validation must identify the holder checked and
the outstanding holders; it cannot claim global PASS. Normal global status
must reject an unfinished sequence. A completed, validated sequence admits
only its own temporary old rows, preserving rejection of missing or dropped
bindings, unrelated mismatches, changed proposed bytes, invalid ordering,
overlap and divergent lineage. No implementer-supplied mismatch allowlist
substitutes for those checks.

This permission lands in its own standalone commit and receives independent
exact-SHA review before correction code is edited. Focused tests must prove
the complete valid sequence and the refusal cases above against the actual
validator, including truthful intermediate scope and final global validation.
Retain commands, source attribution and results. The original four-control
reproducer result has SHA-256
`af33e5e106a6963612dd90e2623693abd38e49bf45b123376437103f6d8ea2ff`;
it demonstrates the defect, not the correction.

The independently recorded delegate remains **`/root/m3_independent_review`**.
Its scope now also includes approval of the actual checker correction commit
after focused testing and exact-commit review against these constraints.
That review must complete before the first shared-byte proposal. Its later
M1/M2/M3 acceptance scope and all separate sequential update/review obligations
remain as recorded in the original approval. No unseen commit is accepted.

Full M0–M3 gates remain required on the final candidate on macOS and Linux
serenity. This correction changes no pass criterion, waives no failure and
grants no additional supplemental provider calls, ADR changes, M3 closure,
product integration to `main`, tag or release. Further deviations require the
maintainer's decision.

<a id="disposition-m1-gate-generation-9-2026-09-12"></a>
### M1 gate generation 9 acceptance — 2026-09-12

Under the maintainer's [diagnostics delegation](#override-disposition-m3-selector-diagnostics-2026-09-12)
and [checker correction approval](#override-disposition-m3-sequential-binding-checker-2026-09-12),
delegate **`/root/m3_independent_review`** independently reviewed exact proposal
`08268e11317d0a57a95e374e7bf1f98c9aabd3ad` and explicitly stated:

> I explicitly ACCEPT M1 gate generation 9 proposal A 08268e11317d0a57a95e374e7bf1f98c9aabd3ad, with gate SHA-256 57076985b3aab41d72f26c399d0177e115198f147f9c1c8168fc65df5fd2c066.

The proposal changes exactly the five reviewed M1 paths and retains historical
Acceptance, Closure and earlier generation rows. Its immediate one-parent rebind
completes only generation 9 and adds this fresh disposition. The independently
approved checker corrections `ad5e530952d3b08ee1a8a14773789e727012f90d`
and `8abfee872c4dc2fb0e2d76680e8c4b2fb96afbeb` preceded this proposal.

At the accepted proposal, focused checks verified nine bound artifacts, document
links and pairing, unchanged historical governance records, and the exact
pending-generation-9 refusal. The command exited 1 in 9.91 seconds and explicitly
reported `global_pass=false`; its log SHA-256 is
`9db3a52d6d90bc9a0ea1ebb137dc1173eafb1e52e92212ab40fb752944456bfa`.
The seven-case diagnostics corpus remains attributed to retained, unaccepted
`2368c9daab6a709226bd0a0ecf8616b83b1aa582`, whose shared runner and corpus
bytes are identical. That earlier proposal's unexpected Closed-citation guard
refusal remains recorded; it was preserved outside the integration lineage and
was never accepted. The current and floor checker tests passed all 84 cases;
the current run used the exact correction bytes before commit, and the floor
run used exact `8abfee872c4dc2fb0e2d76680e8c4b2fb96afbeb`.

Before M2 proceeds, this rebind requires complete real-history M1-scoped status
validation identifying M2 and M3 as pending, plus independent exact-transition
review. Those results belong to the rebind, not to its proposal. Full gates at
these intermediate revisions are unrun under the recorded timing approval.
Complete M0–M3 gates remain required at the final candidate on macOS and Linux
serenity. No historical failure, later proposal, closure or release is accepted
by this disposition.

<a id="disposition-m2-gate-generation-10-2026-09-12"></a>
### M2 gate generation 10 acceptance — 2026-09-12

Under the [recorded maintainer delegation](#override-disposition-m3-selector-diagnostics-2026-09-12),
delegate **`/root/m3_independent_review`**, named `m3_independent_review` in the
generation table, independently reviewed exact proposal `1897d402a906212cc7c4118218352e4df9624591`
and explicitly stated:

> I explicitly ACCEPT M2 gate generation 10 proposal A 1897d402a906212cc7c4118218352e4df9624591, gate SHA-256 4c0ee04ab5d7838b6a38adeac81689749d9ba530cd6499c2ec3d4866f2bae864.

The proposal changes exactly the three reviewed M2 paths. The shared runner and
corpus retain the bytes settled by [M1 generation 9](#disposition-m1-gate-generation-9-2026-09-12).
Only the approved diagnostics exception replaces M2's continuing old-M1-byte
restriction. Historical Acceptance, Closure and Amendments 1–9 are preserved.
The immediate one-parent rebind completes only generation 10 and adds this fresh
disposition; it changes no gate or bound artifact.

M1's reviewed rebind `7aebf6a3ecc8237e42aa7088a04480a6751542b3` completed
its real-history status check before this proposal, with M2 and M3 explicitly
pending. Its exit was 0 in 793.108 seconds, with log SHA-256
`016762860ec9b141faea29ce89a7a08860ce2689d455ab762973352e763e704f`.
At this M2 proposal, focused checks verified six bound artifacts, links, pairing,
unchanged historical records, and the exact pending-generation-10 refusal.
They exited 1 in 9.838 seconds with `global_pass=false`; the log SHA-256 is
`047eb13baf11de2c4d2bf9566898726da83bcd2e4f1a4a18ccc54033af15edae`.
Unchanged corpus evidence retains its original source attribution.

Before M3 proceeds, this rebind requires complete real-history M2-scoped status
validation identifying M3 as pending, plus independent exact-transition review.
Full gates at these intermediate revisions are unrun under the recorded timing
approval. Complete M0–M3 gates remain required at the final candidate on macOS
and Linux serenity. This disposition waives no historical failure and accepts
no later proposal, closure or release.

<a id="disposition-m3-amendment-2-acceptance-2026-09-12"></a>
### M3 Amendment 2 acceptance — 2026-09-12

Under the [recorded diagnostics delegation](#override-disposition-m3-selector-diagnostics-2026-09-12)
and [checker correction approval](#override-disposition-m3-sequential-binding-checker-2026-09-12),
delegate **`/root/m3_independent_review`**, named `m3_independent_review` in the
Acceptance table, independently reviewed exact proposal
`89a848b6685fd2d6e7d4dfd4768b4d083dc9db36` and explicitly stated:

> I explicitly ACCEPT M3 Amendment 2 proposal A 89a848b6685fd2d6e7d4dfd4768b4d083dc9db36: Concept envelope SHA-256 9c004acd94844a9f1369ac84e6b735076c537cc5caabf4ad0e825854334352e5; Technical envelope SHA-256 433947d010b8999966a9becb9b260647f2764fa0bbc8ef4448f6b395f0b0d227; gate SHA-256 c129c26a9a7a10edc57f4dbc22e624c70001ee7a780bfef643fc826fdde5ab1f.

The proposal changes exactly the three reviewed M3 plan/gate documents. It
matches the prepared patch with SHA-256
`17c87646796a292e50c8fc6c6d330021f93f97404873ad6c17a4ca1779b8e66a`.
The shared runner and corpus remain the exact bytes settled by M1 generation 9
and M2 generation 10. Five outcomes, ADRs, product contracts, required witnesses
and final pass criteria retain their meaning. This immediate one-parent rebind
changes only the Acceptance row and adds this fresh disposition; the Accepted
lifecycle, gate, normative envelopes and product bytes remain unchanged.

M2's reviewed rebind `7320ee2093d181402e6512dc3166c719ecc4a767` completed
its real-history status check before this proposal, with only M3 pending. It
exited 0 in 735.46 seconds, with log SHA-256
`dc396ee2866becb4405069fd2de4a08616d2dcc3573a5ae3357c36b1ca343cee`.
At the M3 proposal, focused checks verified eight bound artifacts, links,
pairing, unchanged prior governance records, and the exact expected stale
Concept-digest refusal. They exited 1 in 9.45 seconds with `global_pass=false`;
the log SHA-256 is
`3f7500700adab1c2e5fb61d70d1fd1841ed6652cebb59c18a98e4bc696825b87`.
Unchanged corpus evidence retains its original source attribution.

Before final qualification, this rebind requires independent exact-transition
review, complete default global status validation with no pending holder, and
M3 gate inspection. Full gates at the intermediate revisions are unrun under
the recorded timing approval. Complete M0–M3 gates remain required at the final
candidate on macOS and Linux serenity. This disposition waives no historical
failure and grants no M3 closure, product integration to `main`, tag or release.

<a id="override-disposition-m3-checksum-portability-2026-09-12"></a>
### M3 checksum portability repair — 2026-09-12

The maintainer was asked:

> Approve the reviewed M3 checksum fix and its M3 binding update? Linux’s isolated tests lack `shasum`; the fix also accepts `sha256sum` with the same digest checks. I recommend letting the independent reviewer accept only this exact patch and matching M3 update, after your permission is recorded and reviewed. Use focused checks during the update, then complete M0–M3 gates on macOS and Linux at the final candidate. Patch: 0468bc9e55adca559d37351257076c1dbd7cbb5f491b36cf66464193e1dd5b57. This grants no failure waiver, ADR change, closure, merge to main, or release.

After the completed Linux control and the outstanding approval were reported,
the maintainer answered **"Approved"**. This records approval of that exact
packet, including its limited reviewer delegation and validation timing.

Under [the explicit maintainer override](../../AGENTS.md#maintainer-override),
this authorizes only patch SHA-256
`0468bc9e55adca559d37351257076c1dbd7cbb5f491b36cf66464193e1dd5b57`
to `scripts/check-m3-gate.sh`. At source
`6d745eda73d8aaa6e88f3627fdefd71bdac43236`, the runner digest is
`49cf9b8f7fc95846d105e045d86f73110f5de2fde80b9b6214ed30c565b87302`;
the approved replacement digest is
`d54c66098d971a9bdc0b26addb95d415db02c44e4b82ba55e325b5863cf4629b`.
The sole holder is Accepted `M3`. Its Amendment 3 proposal changes the runner,
that runner's Bound Artifacts row in `M3-gate.md`, and the appended amendment.
The immediate one-parent rebind changes only M3's Acceptance row and adds its
fresh acceptance disposition here. M1 and M2 bindings remain unchanged.

The replacement accepts a validated `shasum` or `sha256sum`, checks the known
empty-input SHA-256 digest and every returned lowercase 64-hex digest, and
refuses unavailable, malformed or failed hashing. Artifact comparisons and the
final gate digest retain their meaning. It changes no PATH isolation, role,
command, witness, count, exclusion, timeout, provider path or final report field.
A final hash failure must refuse before the authoritative PASS report.

This disposition lands alone and receives independent exact-SHA review before
dependent edits. Delegate **`/root/m3_independent_review`**, named
`m3_independent_review` in the Acceptance table, may then accept only the actual
Amendment 3 proposal SHA matching this patch and these M3 binding changes, after
focused validation and exact-commit review. Deviations require the maintainer's
decision. The delegate cannot approve another repair, failure waiver, ADR,
closure, merge to `main`, tag or release.

For this M3 proposal and rebind only, focused checksum controls, script and
artifact inspection, applicable binding/status checks and independent exact-SHA
review replace the full gates otherwise required at those intermediate
checkpoints. The proposal retains its expected stale M3 binding. Its immediate
rebind must settle that binding and pass complete default status validation
with no pending holder. The complete M0–M3 gates remain required at the final
candidate on macOS and Linux serenity. Intermediate full gates are unrun, never
reported as passing, and prior failures retain their original status.

The reviewed proposal evidence is retained in the maintainer's
`loopex-reviews/m3-checksum-proposal-6d745ed-p5e86sdi` archive with manifest
SHA-256 `8f752d5fcad0a8403098e05ab4e7766005f55545f884062ea3e05f878e0d6f14`.
It contains nine local copied-runner inspection controls, three synthetic
final-report controls and the actual Linux restricted-PATH control. On Linux,
the original runner reproduced the exact missing-`shasum` refusal with exit 2;
the proposed runner returned the unchanged inspection-only output with exit 0.
The donor remained unchanged, and only the disposable fixture's runner and
synthetic self-binding row changed. That evidence predates approval and is
proposal evidence, not an accepted binding or full-gate result. No historical
failure is waived by this instruction.

<a id="disposition-m3-amendment-3-acceptance-2026-09-12"></a>
### M3 Amendment 3 acceptance — 2026-09-12

Under the [recorded checksum delegation](#override-disposition-m3-checksum-portability-2026-09-12),
independent delegate **`/root/m3_independent_review`**, named
`m3_independent_review` in the Acceptance table, reviewed exact proposal
`887ff3733bde8f1560b23c85a4a23988072d5715` and explicitly stated:

> I accept **M3 Amendment 3 proposal `887ff3733bde8f1560b23c85a4a23988072d5715`** under the recorded limited delegation.

The delegate verified and accepted these exact bindings:

- Concept envelope: `sha256:9c004acd94844a9f1369ac84e6b735076c537cc5caabf4ad0e825854334352e5`.
- Technical envelope: `sha256:433947d010b8999966a9becb9b260647f2764fa0bbc8ef4448f6b395f0b0d227`.
- Gate: `sha256:7a0140357954e5b465e3e6f41f79893e0f1c820bf0f221c95dc9794a47b1cbcc`.

The proposal changes only the exact approved runner patch and its M3 gate
binding plus Amendment 3. Both normative envelopes, prior amendment text,
M1/M2 bindings, product bytes and the Accepted lifecycle are unchanged. This
immediate one-parent administrative rebind changes only the Acceptance row and
adds this fresh disposition. It accepts no further repair or amendment.

At exact proposal A, the gate-support file passed all 12 cases with seed 3107,
zero failures, skipped or excluded cases, in 7.585 seconds. Its log SHA-256 is
`a66d540aa49b470aa05d0381273693f1713bf579745765de4e44376c014b40ad`.
Artifact inspection exited 0 in 0.77 seconds with its unchanged inspection-only
output; log SHA-256
`ac766105a0ab0b8576719f9255b3a2c7be3cbebc528af9bf445dfc8332d88eb4`.
Focused proposal validation exited 1 in 10.115 seconds only for the expected
stale M3 gate binding. It verified all eight artifact hashes, links, pairing
and unchanged prior governance records, with `global_pass=false`; log SHA-256
`729af2ea6cdcbec98706191ab6e6f44af7d9e6e15456207bf3804874d7e5f666`.
The reviewer read those exact results and logs before acceptance. Earlier
checksum controls retain their original proposal-fixture attribution.

Before final qualification, this rebind requires independent exact-transition
review, complete default global status validation with no pending holder, and
M3 artifact inspection. Intermediate full gates remain unrun under the approved
timing exception. Complete M0–M3 gates remain required at the final candidate
on macOS and Linux serenity. This acceptance waives no historical failure and
grants no M3 closure, product integration to `main`, tag or release.

<a id="override-disposition-m3-signal-delivery-witness-2026-09-13"></a>
### M3 prepared signal-delivery witness correction — 2026-09-13

The maintainer answered **"Approved"** to this outstanding request:

> Do you approve the targeted correction: let this single test wait for confirmed delivery within the CLI’s existing **23.8-second limit**, preserving its assertions and failing promptly on refusal or process loss?

The linked decision draft, SHA-256
`ae7f97838ad2cff87b0c2fdca416ebaaf2e97e3733ddda7b3f471475055911e8`,
named only `duplicate refusal preserves signal delivery while the incumbent
presents` in `apps/loopex_cli/test/prepared_recovery_contract_test.exs`, declared
at line 2242 of source `b839284c2a5770464496dbc3f98b26587d97d024`. The approval
replaces that case's approximately three-second fixed-attempt mailbox wait
under the [explicit maintainer override](../../AGENTS.md#maintainer-override).
It permits no change to the shared `queued_abort?/1-2` helper or its other
callers.

The replacement observes actual abort enqueue at the still-suspended
coordinator, using one monotonic cutoff established immediately before the
signal. Its allowance is derived from the existing
`Loopex.Executor.cancellation_bounds(@grace).cli_backstop_ms`: with this
fixture's `@grace = 7_311`, the exact allowance is 23,828 milliseconds. It
never restarts that cutoff. It requires an initially idle incumbent, the same
handler identity and live relevant participants; observed refusal, handler
replacement, participant loss and cutoff expiry are distinct failures. It
retains the existing holder, attachment and live-backstop assertions,
coordinator release, presentation result, session identity, durable interrupt
admission and cleanup in their existing order. Diagnostic assertion output
does not expose raw private terms.

The reviewed controlled counterexample made the unchanged mailbox assertion
fail after 3,305 milliseconds while the exact signal worker's routing call
remained pending. Releasing Control let the same worker deliver the abort
within the unchanged 5,000-millisecond routing bound, and all remaining
original assertions passed. The evidence and its independent review are
retained in the maintainer's
`loopex-reviews/m3-control-counterexample-b839-xdrvevg1` archive, manifest
SHA-256 `1205cb5d986881366ed03c0712bbd9f26a396e048d9d6e9c7b427f08d3012244`.
This proves a possible false-failure schedule in the test; the original Linux
failure's cause remains unknown. The later passive Linux diagnostic's 56
passing cases at seed 243366 are diagnostic evidence only. The original
Linux full-gate failure remains failed, and the macOS full-gate pass remains
attributed to exact source `b839284c2a5770464496dbc3f98b26587d97d024`.

This disposition lands alone and receives independent exact-SHA review before
the dependent test edit. The approved validation covers normal delivery, the
reviewed delayed-Control schedule, refusal or participant loss, and a cutoff
that does not reset, followed by the owning selector's complete focused run.
The correction is independently reviewed, committed and pushed to `m3` before
final qualification. No additional broad mutation hunt is required by this
instruction.

The test file is not a digest-bound artifact of M2 or M3, so this correction
requires no binding-generation transaction. Protected case names, selectors,
exclusions and gate bindings retain their meaning. This changes only the
named test's waiting allowance; product deadlines, runtime behavior, provider
paths, ADR decisions, milestone scope and final pass criteria are unchanged.
Complete M0–M3 gates remain required at the resulting final candidate on
macOS and Linux serenity under the existing final-only cadence. The approval
waives no historical or future failure and grants no failure disposition,
M3 closure, integration to `main`, tag or release.

<a id="override-disposition-m3-final-inherited-gates-waiver-2026-09-13"></a>
### M3 final validation scope — 2026-09-13

The maintainer explicitly directed:

> i don't need you to run m0-m2 gates. just run m3 gates. that's. my decision. you've been waffling, we need to move on.

Under the [explicit maintainer override](../../AGENTS.md#maintainer-override),
this replaces the requirement to rerun M0, M1 and M2 gates for M3's final
qualification on macOS and Linux serenity. It takes precedence over the final
inherited-gate requirements in the earlier M3 cadence, diagnostics, checker,
checksum and signal-delivery dispositions. Those historical records remain
unchanged. Final M0–M2 evidence is **waived, not passed**.

Run all remaining M3 gate checks on both platforms at the same committed and
pushed candidate: bound-artifact and source/build identity checks, the opening
witness, all deterministic outcome selectors, the full deterministic suite,
formatting, documentation, dependency and bootstrap checks, and the attended
real-provider workflow with complete selector accounting. The full suite may
exercise inherited tests; do not invoke the M0, M1 or M2 gate runners or their
aggregate. Preserve all remaining assertions, credentials handling and failure
criteria.

Use an external, reviewable derivative of the bound M3 runner that removes
only its inherited-gate invocation/report requirement and labels its terminal
report as M3-only with inherited evidence waived. Retain the exact derivative,
its diff and digest with each run's evidence. The tracked runner, gate document
and bindings remain unchanged. A scoped pass must never be reported as the
unchanged full-gate PASS or as fresh M0–M2 qualification.

This standalone disposition receives independent exact-SHA review before the
dependent execution change. The instruction adds no product or ADR change,
does not convert any historical failure into a pass, and grants no M3 closure,
integration to `main`, tag or release.

<a id="disposition-m3-historical-findings-acceptance-2026-09-13"></a>
### M3 historical findings accepted for the reviewed candidate — 2026-09-13

After receiving the completed eleven-finding decision packet and its clear
independent evidence review, the maintainer explicitly directed:

> pass the eleven hittorical decision as accepted for now and pass it to reviewer.

This accepts the residual uncertainty of records 1–11 for qualified M3
candidate `7d73707dca4953f91b3244ad43e09c1545f8f123` under the explicit
finding-disposition rule in [AGENTS.md](../../AGENTS.md). The findings no longer
block review of that candidate. "For now" limits this acceptance to these named
historical occurrences and this candidate; it supplies no standing exception
for a recurrence or a future milestone. Their original causes remain unknown
where the packet says so. Failed results remain failed, and unavailable
evidence remains unavailable.

The accepted record identities are those in the retained packet:

| Record | Historical occurrence | Historical source | Seed |
| --- | --- | --- | --- |
| 1 | macOS M0 fast-command executor result | `994184d` | 906860 |
| 2 | Linux M0 provider failure after dispatch | `232df7a` | 817697 |
| 3 | Linux M0 unknown provider result | `8e9a6c3` | 906644 |
| 4 | macOS M0 repeated skill-import Git listing | `3e8ae23` | 928736 |
| 5 | macOS floor materializer setup refusal | `0a1b57f` | No test seed |
| 6 | Linux M1 recovery selector failure | `5c74164` | Unavailable |
| 7 | macOS M1 launcher second interrupt | `44533d7` | 1734 |
| 8 | macOS M3 queued-EOF deadline witness | `4372a57` | 3107 |
| 9 | Linux M1 real-model request-count assertion | `7d2b6d1` | 10195 |
| 10 | macOS M2 CLI queued-follow-up snapshot | `610671e` | 993077 |
| 11 | Linux M2 prepared-recovery signal-delivery witness | `b839284` | 243366 |

The decision packet is retained in the maintainer's
`loopex-reviews/m3-final-review-packet-7d73707-4x2lkbb8` archive. Its manifest
SHA-256 is
`b97c7d9402ecf60c3bf8d1e490081e8d1fffaae9266cb48d6d5791ef9ca6b27a`;
`packet/decision-packet.md` has SHA-256
`76ec7848a95c23ae7f3270b2c2116c3d85a6dc184133730628ae1c51fefcb4a1`.
The packet's original pending-decision state remains historical; this new
disposition records the subsequent acceptance. The retained failures, repair
reviews, causal limits and evidence map are unchanged.

Both M3-only qualifications passed at exact candidate
`7d73707dca4953f91b3244ad43e09c1545f8f123`: macOS and Linux serenity each
completed 17 checks, nine selectors, 1,207 deterministic tests with zero
failures at seed 3107, and one attended real-provider workflow. Their combined
archive is `loopex-reviews/m3-only-final-evidence-7d73707-y8c1arat`, manifest
SHA-256 `57da9db3c0cf1660abb9a0a06b089a8bc52f5fb149177d3f45648b1e8b8e96d6`.
The final independent archive review is clear, with report SHA-256
`4240044f92efe3b040207729d4850f21eb77304846e9d1ac966f252dbb316492`,
retained as `archive-review/review.md` in the decision-packet archive.

Final M0–M2 reruns remain waived under the
[separate validation-scope disposition](#override-disposition-m3-final-inherited-gates-waiver-2026-09-13).
This acceptance changes no required assertion, count, deadline, real path or
future failure criterion. Qualification results keep their exact source
attribution; this documentation-only recording commit makes no new test claim.
The record lands alone, is committed and pushed to `m3`, and is passed with
the retained evidence to an independent reviewer at its exact SHA. It grants
no M3 closure, product integration to `main`, tag or release.

<a id="override-disposition-m3-required-trust-witness-2026-09-13"></a>
### M3 required-only trust witness correction — 2026-09-13

For new finding H3 in the post-implementation review of
`f92f19ee31e7ea62cb5614a487dfb22527c13c66`, the maintainer received this proposal:

> For H3, may I keep ADR 0017’s existing promise and correct the protected test under a narrow override? Required-only failures would retain the exact reason project trust was declined. The test may observe a trust lookup, but must still prove zero optional-content reads, zero optional-inclusive measurements and zero model calls. The test name and gate bindings stay unchanged. I’ll record the approval separately before this fix.

The recommended option was “Approve the narrow witness correction”. The
maintainer answered:

> Approved recommendations

Under the [explicit maintainer override](../../AGENTS.md#maintainer-override),
this replaces only the zero-project-resolution assertion in
`apps/loopex/test/context_admission_test.exs`, in the protected witness
“required only preflight refuses before any optional inclusive measurement”.
The successor scope is the current M3 repair. A project trust lookup may occur
before required-only refusal, so an already declined project retains the exact
non-budget disposition required by ADR 0017. An eligible optional project
still records `not_evaluated_required_failure` when the required request fails.

The corrected witness must retain its name, required failure and positive
controls, and prove zero optional-content reads, zero optional-inclusive
measurements and admissions, and zero model calls on required-only failure.
Focused evidence must cover eligible and declined project decisions. No
bound-artifact bytes, gate digest, normative envelope or accepted ADR decision
change. All unaffected protected assertions remain required.

This disposition lands alone and receives independent exact-SHA review before
the dependent source or witness correction. The approval waives no failure,
changes no validation cadence, and grants no closure, main integration or
release. Final M0–M2 reruns remain governed by the existing
[separate waiver](#override-disposition-m3-final-inherited-gates-waiver-2026-09-13).

<a id="disposition-m3-checker-ordering-exception-2026-09-13"></a>
### M3 checker ordering occurrence accepted — 2026-09-13

For new finding M1 in the post-implementation review of
`f92f19ee31e7ea62cb5614a487dfb22527c13c66`, the maintainer received this proposal:

> May I record a one-time acceptance of the new historical ordering exception: checker change 571c30f landed before its authorizing record e9722e9? The prior exception covered different commits, so it does not cover this occurrence. Acceptance preserves the actual history and all future approval-order requirements; it changes no product or test requirement.

The recommended option was “Accept this named ordering exception”. The
maintainer answered:

> Approved recommendations

This accepts only the ordering breach between checker/test commit
`571c30ff9e7fa8e27da71911a21504d9dbc5de7c` and later disposition commit
`e9722e98705bc8b3f2510e2630957983a6fa027b` in the M3 implementation lineage.
The earlier planning-lineage exception did not cover this occurrence. The
actual commit order remains a historical process defect; this record does not
claim that authorization or an independent read preceded the checker change.

This finding no longer blocks the current M3 repair candidate. The approval
creates no exception for a recurrence, waives no product failure or required
test, changes no accepted ADR or gate binding, and grants no closure, main
integration or release. Future override records and exact-SHA reads must still
precede dependent work. This acceptance is recorded in its own commit and is
subject to an independent exact-SHA read.

<a id="override-disposition-m3-repair-completion-packet-2026-09-13"></a>
### M3 repair completion decisions — 2026-09-13

After the approval dialogs did not appear, the maintainer received the three
proposals again in plain text: retain the existing Git import limits, accept
four named commit-title exceptions, and replace only the malformed final
documentation commit with its reviewed correction and this approval record.
The maintainer answered:

> approve all three

The approved scopes and replacement requirements are:

1. **Git download limit.** For finding L1 in the post-implementation review of
   `f92f19ee31e7ea62cb5614a487dfb22527c13c66`, retain the existing maximum
   30-second acquisition deadline and existing pack admission limits. M3 does
   not add a separate download-byte cap. The initial Git transfer can therefore
   consume bytes beyond the admitted pack size before the existing deadline or
   subsequent size validation refuses it. This is an accepted limitation for
   this M3 repair, not evidence of a transfer-size bound or permission to relax
   the deadline, admission checks, cancellation or cleanup guarantees.
2. **Historical commit titles.** Accept only the milestone-marker naming
   exceptions in `d158989f8b3f4e423bf00bdd0f940162433d46c1`,
   `dafc42b8ded769dfe7aa6fd17875ad46ed5df32f`,
   `d11af17050aa1fe96cc67171eb41fd25e76a66c9` and
   `5e9db2edf711991b73899a78e82280d10fb39f2b`. Their titles used subsystem
   markers instead of `M3`; their history remains unchanged. Future repair
   commits use the `M3` marker. This disposition changes no checker, product
   requirement or test result and creates no naming exception for later work.
3. **Documentation-tip replacement.** Replace only
   `92fcb6184ae286b8493f0cbf71e51bc1cf58c384` with the reviewed correction
   `fde3eadc4fe90a78e8b9c0378f947a35689919c3`, followed by this standalone
   approval-record commit. Both documentation candidates have sole parent
   `873a1d759b367757aa21336babc6f4f4ff260695`. The correction places the same
   explanatory text in the existing Workstreams section, preserves table-only
   Progress and Governance sections, and wraps CHANGELOG lines. Full repository
   status must pass before publication. The push must use an exact remote lease
   expecting `92fcb6184ae286b8493f0cbf71e51bc1cf58c384`; any advancement of
   local or remote `m3`, or another checkout using local `m3`, stops replacement
   for reconciliation. The original tip is retained in the verified
   `original-documentation-tip.bundle` in the maintainer's
   `loopex-reviews/m3-review-repair-focused-92fcb61-0lob23r0` evidence archive.

The third decision is the explicit destructive-history permission for this one
unaccepted documentation tip. It does not rewrite earlier history, accepted
candidates, product, tests, gates, ADRs or either normative plan envelope. The
first two decisions accept their named limitations only; they do not relabel
failed or unrun checks as passing. This record changes only this document and
receives independent exact-SHA review before the dependent publication.

Fresh qualification remains M3-only: macOS on Elixir 1.17.0 / OTP 26.0 and Linux
serenity on the current toolchain, with exact source and retained evidence.
Final M0–M2 reruns remain waived, not passed, under the
[existing validation-scope disposition](#override-disposition-m3-final-inherited-gates-waiver-2026-09-13).
These decisions grant no M3 closure, integration to `main`, tag or release.

<a id="override-disposition-m3-formatting-evidence-carry-forward-2026-09-13"></a>
### M3 formatting evidence carry-forward — 2026-09-13

The maintainer received this exact question after the macOS floor run at
`96a138a6298fcbc0d3a7b10f191578229bbd71e5` passed eight deterministic
selectors and the 1,228-test suite, then failed `mix format --check-formatted`:

> Approve reusing the passed deterministic tests from `96a138a` across the formatting-only fix, while I run fresh build, repository and real-provider checks on both macOS and Linux?

The maintainer answered:

> Appved

This is approval to carry only those already passed deterministic results across
the formatting-only source change in
`8eafa984eda57229ba7df9d5f9cbb040aa9880c4`. The two changed files have
equal parsed Elixir syntax trees at the prior and repaired sources on Elixir
1.17.0 / OTP 26.0 and Elixir 1.20.3 / OTP 29.0.5 after removing only line and
column metadata. Both toolchains pass the formatter on the repaired source.
The earlier macOS run's overall result remains a formatting failure; its
passed tests remain attributed to `96a138a` and are not relabelled as executed
at the later source. The Linux M3-only pass at `96a138a` also keeps its own
source attribution. The original macOS test log, formatting failure and syntax
comparison are retained in the maintainer's
`loopex-reviews/m3-formatting-compatibility-8eafa98-_dfshvvy` archive.

The replacement validation at the standalone approval revision runs the M3
opening core and local Store build, opening probe, isolated test build,
formatting, documentation, dependency budget, bootstrap and attended real
provider workflow afresh on macOS floor and Linux current. It retains the
source/build identity and real-selector report checks, a real-only selector
ledger of 1/1, and the existing M0–M2 inherited-gate waiver. The external
executor emits only a `LOOPEX_M3_REMAINING_LANES_REPORT` with the exact fresh
source and `deterministic=CARRIED_NOT_RERUN`; it cannot claim a complete new
M3-only gate PASS. The original passing deterministic evidence and the fresh
remaining-lanes evidence must both be presented to the reviewer with their
separate source identities.

Approved remaining-lanes executor: sha256:fe553d8f087160b868c2a59a1955ce884b9eb431f319007fe12f9463d2d92c28
Carried deterministic evidence source: 96a138a6298fcbc0d3a7b10f191578229bbd71e5
Formatting repair source: 8eafa984eda57229ba7df9d5f9cbb040aa9880c4
Execution scope: fresh M3 opening/test builds, opening probe, format, docs, dependencies, bootstrap and attended real workflow; deterministic selectors and whole suite carried, not rerun.

This disposition changes no product bytes, accepted ADR decision, M3 gate,
protected assertion, provider requirement or deadline. It grants no M3
closure, integration to `main`, tag or release. The disposition lands in its
own commit, receives an independent exact-SHA read before the external
remaining-lanes executor runs, and is pushed to `origin/m3` with the subsequent
evidence handoff.

<a id="disposition-m3-unlogged-process-probe-2026-09-13"></a>
### M3 unlogged process-probe occurrence — 2026-09-13

The `4282d9b3ee7718fd120a7bcbf9d1d78a2aaea818` hand-off packet mentioned
one `{:process_incarnation_unavailable, :process_absent}` stop in a broad CLI
test. It retained no failing command, raw log, selector, source-bound test
report, or execution-environment record for that attempt. The original cause
cannot be established and the attempt is **not a pass**. A separate diagnostic
at that clean source, retained at
`~/loopex-reviews/m3-closure-process-probe-4282d9b/README.md`, shows the
floor-toolchain BEAM's `/bin/ps` command returning exit 1 with empty output
under restricted execution and returning its process start time under
permitted host execution. The source maps the first result to the reported
error. This proves an environmental mechanism that can produce the signature,
not what happened in the unlogged attempt.

The maintainer was offered two choices: accept this one unlogged occurrence as
unresolved historical uncertainty, conditional on final M3-only runs passing
on macOS and Linux with any recurrence blocking closure; or keep it blocking
and investigate the unrecorded attempt further. The maintainer answered:

> i accept the recommended disposition. move on.

This accepts only the first choice for this single historical occurrence.
It does not label the old attempt a flake, product regression, environmental
failure, or pass. Final M3-only qualification at the frozen candidate remains
required on both platforms, and a repeated process-probe error or any other
required failure blocks closure. M0–M2 final gate reruns remain **WAIVED**, not
passed, under the separate validation-scope override. This disposition grants
no M3 closure, integration to `main`, tag, or release.

<a id="disposition-m3-closure-2026-09-13"></a>
### M3 closure — 2026-09-13

After the independent product review at source
`f45354572840636b473ad7e40e42355fdff4fc17` found no blocking product
defect and identified the remaining governance sequence, the maintainer directed:

> Ok. Finish and let's close

This closes M3 at the evidence-only candidate
`159e7ea96826125e55b6c3dd1ce751dc1445c3f4`, the direct child of that
product source. The child marks all five outcomes Proved and identifies the
retained M3-only qualification at the product source: macOS Elixir 1.17.0 /
OTP 26.0 and Linux Elixir 1.20.3 / OTP 29.0.5 each passed 17 lanes, all nine
selector reports, the deterministic suite with zero failures, bootstrap, and
the attended Anthropic workflow. Archive paths and SHA-256 digests are in the
[source-bound evidence record](../plans/M3.md#concept-m3-final-qualification-f453545).
The M0–M2 final gate reruns remain **WAIVED**, never described as passed, under
the [recorded maintainer override](#override-disposition-m3-final-inherited-gates-waiver-2026-09-13).

Closure binds the accepted envelopes and gate:

| Artifact | Digest |
| --- | --- |
| Concept envelope | `sha256:9c004acd94844a9f1369ac84e6b735076c537cc5caabf4ad0e825854334352e5` |
| Technical depth envelope | `sha256:433947d010b8999966a9becb9b260647f2764fa0bbc8ef4448f6b395f0b0d227` |
| Gate | `sha256:7a0140357954e5b465e3e6f41f79893e0f1c820bf0f221c95dc9794a47b1cbcc` |

The [Git transfer-byte-cap limitation](#override-disposition-m3-repair-completion-packet-2026-09-13)
stands exactly as accepted: the 30-second deadline, pack caps, cancellation,
and cleanup still apply. The eleven named historical findings and the
formatting-only evidence carry-forward retain their own dispositions and
source attribution; neither becomes a new pass at closure. The maintainer's
`e17fb2e` task-checklist addition to `AGENTS.md` was their direct instruction
on this milestone branch. The In progress and In review transitions and this
closure transition receive separate exact-commit reviews. This record grants
no tag, release, or publication.

<a id="disposition-adr-0023-acceptance-2026-09-13"></a>
### ADR 0023 acceptance — 2026-09-13

On 2026-09-13, after the independent read-only review of pushed `m4` SHA
`3503992cbc0de02ef98ba261e7a19fdb7123e220` reported no blocking or high
finding for that revision's delta and every earlier finding repaired, the
maintainer directed the reviewer, in the review conversation, to record the
acceptance dispositions for all five M4 prerequisite ADRs (0023, 0024, 0026,
0028 and 0030) so that the maintainer can then accept M4.

This transcribes that direction as the maintainer's acceptance of the exact
Proposed [ADR 0023 Concept](../adr/0023-experimental-public-session-protocol.md#concept)
and [Technical depth](../adr/0023-experimental-public-session-protocol-technical.md#technical-depth)
pair at `3503992cbc0de02ef98ba261e7a19fdb7123e220`, with Concept SHA-256
`5b1340e0baafdf834e04590b06825ee3cc17e27c32349945b0495e0017e4d6f7`
and Technical SHA-256
`3332ca23318353a9068f84a3ff40411bd612bda7a142ed26ac4588c22e7b577f`.
The maintainer is the accepting authority; the reviewer who examined that
candidate transcribed the record and accepted nothing. The earlier
[pre-acceptance contract choices](#disposition-m4-preacceptance-contract-choices-2026-09-13)
guided the proposal text; this record supplies the acceptance itself. It
accepts the connection state table, the sixteen-method experimental
generation, its bound schema and vector bytes, and the negotiated
unavailability of session listing and project-trust methods as proposed.

This administrative transition changes only the Concept status and Acceptance
row, this disposition, the derived ADR index status and the derived plan
register capsule. It accepts no other ADR, does not accept the M4 plan pair or
gate, authorizes no product implementation, and grants no merge, tag or
release.

<a id="disposition-adr-0024-acceptance-2026-09-13"></a>
### ADR 0024 acceptance — 2026-09-13

Under the same maintainer direction recorded in the
[ADR 0023 acceptance](#disposition-adr-0023-acceptance-2026-09-13), given on
2026-09-13 after the independent read-only review of pushed `m4` SHA
`3503992cbc0de02ef98ba261e7a19fdb7123e220`, this transcribes the maintainer's
acceptance of the exact Proposed
[ADR 0024 Concept](../adr/0024-durable-interaction-lifecycle-and-host-policy-authority.md#concept)
and [Technical depth](../adr/0024-durable-interaction-lifecycle-and-host-policy-authority-technical.md#technical-depth)
pair at `3503992cbc0de02ef98ba261e7a19fdb7123e220`, with Concept SHA-256
`3fbc7ee6f866e76f85681f527243d79f386b8d97bb7442825f109514367951b8`
and Technical SHA-256
`482171eba55a5c86ca62e028cb6ae2368966c9cf2a0cf1e76a225d2c12544f3d`.
The maintainer is the accepting authority; the reviewer transcribed the record
and accepted nothing. It accepts the session-owned durable interaction
lifecycle, the bounded choice request, and the ceiling of two committed
answer-then-defer transitions after the first question that the
[pre-acceptance contract choices](#disposition-m4-preacceptance-contract-choices-2026-09-13)
selected; a further defer resolves as denial.

This administrative transition changes only the Concept status and Acceptance
row, this disposition, the derived ADR index status and the derived plan
register capsule. It accepts no other ADR, does not accept the M4 plan pair or
gate, authorizes no product implementation, and grants no merge, tag or
release.

<a id="disposition-adr-0026-acceptance-2026-09-13"></a>
### ADR 0026 acceptance — 2026-09-13

Under the same maintainer direction recorded in the
[ADR 0023 acceptance](#disposition-adr-0023-acceptance-2026-09-13), given on
2026-09-13 after the independent read-only review of pushed `m4` SHA
`3503992cbc0de02ef98ba261e7a19fdb7123e220`, this transcribes the maintainer's
acceptance of the exact Proposed
[ADR 0026 Concept](../adr/0026-development-floor-refresh.md#concept)
and [Technical depth](../adr/0026-development-floor-refresh-technical.md#technical-depth)
pair at `3503992cbc0de02ef98ba261e7a19fdb7123e220`, with Concept SHA-256
`ad0d3c48ee0ae9ef8ed8a713827949d32014dfb2eed8e8f2255a263bd607629c`
and Technical SHA-256
`8fb22a6cd1cdd7a5cf6b4d2da017ee4034746af9efc216f5d0f2aac221aa1d1c`.
The maintainer is the accepting authority; the reviewer transcribed the record
and accepted nothing. It accepts the explicit floor and current validation
pairs, Elixir 1.18.5 with OTP 27.3.4 and Elixir 1.20.3 with OTP 29.0.5, in
place of ADR 0002's derived pin rule. The pins in `.tool-versions` do not
move here: they change only through the phase A holder transactions the M4
technical plan names, Closed M0 through M3 in register order and then Open
M4, each with matrix evidence on both pairs. Until those settle, the
bootstrap floor sentence in `AGENTS.md` and every bound `.tool-versions`
byte remain as they are.

This administrative transition changes only the Concept status and Acceptance
row, this disposition, the derived ADR index statuses and the derived plan
register capsule. It accepts no other ADR, does not accept the M4 plan pair or
gate, approves no holder transaction, authorizes no product implementation,
and grants no merge, tag or release.

<a id="disposition-adr-0028-acceptance-2026-09-13"></a>
### ADR 0028 acceptance — 2026-09-13

Under the same maintainer direction recorded in the
[ADR 0023 acceptance](#disposition-adr-0023-acceptance-2026-09-13), given on
2026-09-13 after the independent read-only review of pushed `m4` SHA
`3503992cbc0de02ef98ba261e7a19fdb7123e220`, this transcribes the maintainer's
acceptance of the exact Proposed
[ADR 0028 Concept](../adr/0028-bounded-artifact-retrieval.md#concept)
and [Technical depth](../adr/0028-bounded-artifact-retrieval-technical.md#technical-depth)
pair at `3503992cbc0de02ef98ba261e7a19fdb7123e220`, with Concept SHA-256
`38077331060dd94e09f5989e61763fc7b0f4a43bc5ff1509292eab6907b0262e`
and Technical SHA-256
`f6a8d1e14f98467999d137db922f3a6d0eca6f7e3684588704a2114a32797ce0`.
The maintainer is the accepting authority; the reviewer transcribed the record
and accepted nothing. It accepts one authorized, verified transfer per
artifact use with distinct object and chunk digests, and the safety-ceiling
profile the
[pre-acceptance contract choices](#disposition-m4-preacceptance-contract-choices-2026-09-13)
selected. Those ceilings are limits to prove under the M4 gate, not measured
throughput promises; ADR 0015's object and use identities stay in force and
are narrowly extended, not replaced.

This administrative transition changes only the Concept status and Acceptance
row, this disposition, the derived ADR index statuses and the derived plan
register capsule. It accepts no other ADR, does not accept the M4 plan pair or
gate, authorizes no product implementation, and grants no merge, tag or
release.

<a id="disposition-adr-0030-acceptance-2026-09-13"></a>
### ADR 0030 acceptance — 2026-09-13

Under the same maintainer direction recorded in the
[ADR 0023 acceptance](#disposition-adr-0023-acceptance-2026-09-13), given on
2026-09-13 after the independent read-only review of pushed `m4` SHA
`3503992cbc0de02ef98ba261e7a19fdb7123e220`, this transcribes the maintainer's
acceptance of the exact Proposed
[ADR 0030 Concept](../adr/0030-observability-tracing-and-telemetry.md#concept)
and [Technical depth](../adr/0030-observability-tracing-and-telemetry-technical.md#technical-depth)
pair at `3503992cbc0de02ef98ba261e7a19fdb7123e220`, with Concept SHA-256
`8e81e197816afa79aa1f43d69837c9f1ed4235a5fbf64dc7588056f1a4ddb65d`
and Technical SHA-256
`f7b24467fef2d326d2eb12eece87662b775586a0813fc958d78b82e0f5735eac`.
The maintainer is the accepting authority; the reviewer transcribed the record
and accepted nothing. It accepts runtime-owned isolated trace sessions with
identity-only default capture and exact limits, telemetry spans at every port
callback and transaction cut in the bound inventory, the `loopex_telemetry`
edge owning the only Loopex-attached handler, and the dispatcher's bounded
diagnostics admission. Under the previously recorded
[vision change](#disposition-m4-vision-core-telemetry-2026-09-13) it
supersedes exactly the two ADR 0001 clauses that required an empty
`apps/loopex` dependency list; every other ADR 0001 clause stands. The
dependency itself enters core only through the M1 dependency-oracle
transaction the M4 technical plan names, after M4 acceptance.

This administrative transition changes only the Concept status and Acceptance
row, this disposition, the derived ADR index statuses and the derived plan
register capsule, which now names the M4 plan pair and gate as the next
decision. It does not accept the M4 plan pair or gate, authorizes no product
implementation, and grants no merge, tag or release.

<a id="disposition-m0-gate-generation-7-2026-09-13"></a>
### M0 gate generation 7 acceptance — 2026-09-13

The maintainer chose to accept each phase A floor-holder proposal directly in
the review conversation while the reviewer authors them. Presented with M0
gate generation 7 at pushed proposal
`08a453d59d20acfff7314b7ad9abe5bf0e65f735`, whose evidence was the single
prescribed `unfinished shared binding sequence` status stop, passing
commit-message, hygiene, gitignore and agent-bootstrap checks, and the matrix
task under both installed pairs refusing only the not-yet-recorded floor run,
the maintainer answered **"Accept"**.

That lineage was then re-created once, after the repository status checker
was repaired at `47784aa`: its governance walk had required a plan's first
acceptance to bind a gate at generation zero, which no Open holder of a
shared artifact can satisfy once the sequential holder transaction makes it
refresh that binding through an amendment. The re-created proposal
`06f9adc0b1a85bffc8a954e4e01ad2759e985f9e` has exactly the tree of
`08a453d59d20acfff7314b7ad9abe5bf0e65f735` plus that repair, verified by the
reviewer with a tree diff before this rebind. On 2026-09-14 the maintainer
approved the rebuild and accepted every re-created phase A proposal on that
basis, answering **"Approve and accept rebuild all"** to the rule that each
re-created proposal's tree equals the originally accepted tree plus the
checker repair.

The acceptance transition built on that first re-creation was refused by the
same checker for two further readings of the same assumption in its plan
validator: every generation-one candidate was read as an amendment proposal
whose rebind must keep the Open state it was proposed under, and the empty
original at the end of an acceptance chain had to sit at generation zero. The
repair was widened at `d276f325169af6ab54464648a6578da6b4e499c7` so that a
candidate whose own Acceptance row is still empty is read as a first
acceptance that may move Open to Accepted only, and an original may carry
generation one; every other shape is refused as before. The lineage was
re-created a second time on that widened repair. The proposal
`87bb87ec3ec5b86d6cf65b11fa5472a60072c5e4` has exactly the tree of
`08a453d59d20acfff7314b7ad9abe5bf0e65f735` plus the widened repair, verified
by the reviewer with a tree diff before this rebind. On 2026-09-14 the
maintainer approved the second rebuild and accepted every re-created phase A
proposal and the re-created M4 candidate on that basis, answering
**"I accept recreated proposals and candidate. i need to do a second review
after the final sha table is created"**. This row binds that proposal.

This accepts generation 7 alone under `amendment-transaction-v2`: the
`.tool-versions` floor pair Elixir 1.18.5 with OTP 27.3.4 that accepted
[ADR 0026](../adr/0026-development-floor-refresh.md#concept) chose, bound at
`fea095ecec784a4440b872ad5f53a8da2cb4e13e43b6f05add5cfd75bb352879`, and the
amended M0 gate at
`sha256:b86275a21d1041c7e72e8354367ff9036de2470abfb2f11559ed95145835dca1`.
This immediate-child rebind changes only the generation-7 row in
`docs/plans/M0.md` and adds this disposition. M0's historical Acceptance and
Closure, earlier dispositions, envelopes, register and lifecycle state remain
unchanged, and M0 remains Closed.

M1, M2, M3 and M4 still hold the previous pins in their own tables; each
settles through its own transaction in register order, and holder-scoped
validation at this rebind names them as pending rather than reporting a
global pass. A run of the M0 gate under the new floor pair, recorded in the
matrix evidence, belongs to the inherited-green proof after the final Open
M4 refresh. This record accepts no other holder, plan or ADR, waives no
evidence, and grants no integration, tag or release.

<a id="disposition-m1-gate-generation-10-2026-09-14"></a>
### M1 gate generation 10 acceptance — 2026-09-14

Continuing the phase A sequence under the maintainer's chosen route, the
reviewer authored M1 gate generation 10 at pushed proposal
`c8230d2f45c97afbaea6be3bd68a0804723d3b18` and presented its evidence: the
single prescribed `unfinished shared binding sequence` status stop, the two
M1 corpora passing on the current pair at seed 3107 with 38 cases against
their locked minima, formatter and script-syntax checks passing, and
holder-scoped validation at the M0 rebind naming M1, M2, M3 and M4 as
pending. The maintainer answered **"Accept"**.

That lineage was then re-created once after the status checker repair at
`47784aa` described in the
[M0 generation 7 record](#disposition-m0-gate-generation-7-2026-09-13). The
re-created proposal `6b758aea80f93beefa8dfefbd559403e43e319fa` carries the
same change as `c8230d2f45c97afbaea6be3bd68a0804723d3b18` on top of that
repair and the re-created M0 rebind, verified by the reviewer with a tree
diff before this rebind. On 2026-09-14 the maintainer approved the rebuild
and accepted every re-created phase A proposal on that basis, answering
**"Approve and accept rebuild all"**.

That lineage was re-created a second time after the repair was widened at
`d276f325169af6ab54464648a6578da6b4e499c7`, described in the
[M0 generation 7 record](#disposition-m0-gate-generation-7-2026-09-13). The
proposal `e3209179394a9be390abe8427ee15e97cfbef313` carries the same change
as `c8230d2f45c97afbaea6be3bd68a0804723d3b18` on top of the widened repair and
the preceding re-created rebinds, verified by the reviewer with a tree diff
before this rebind. On 2026-09-14 the maintainer approved the second rebuild
and accepted every re-created phase A proposal and the re-created M4
candidate on that basis, answering **"I accept recreated proposals and
candidate. i need to do a second review after the final sha table is
created"**. This row binds that proposal.

This accepts generation 10 alone under `amendment-transaction-v2`: the
floor-only literal changes in M1's bound evidence verifier, dependency-budget
reader and both corpora for the accepted pair Elixir 1.18.5 with OTP 27.3.4,
the six embedded digests in its gate script, and the amended M1 gate at
`sha256:a56b8279fcace125086b1b806d442ee6343ed23c44bd83b6d4abb28dc7134be5`.
This immediate-child rebind changes only the generation-10 row in
`docs/plans/M1.md` and adds this disposition. M1's historical Acceptance and
Closure, earlier dispositions and generations, envelopes, register and
lifecycle state remain unchanged, and M1 remains Closed.

M2, M3 and M4 still hold the previous pins in their own tables and settle
next in register order; holder-scoped validation at this rebind names them as
pending rather than reporting a global pass. Captures of the M1 gate under
the new floor pair belong to the inherited-green proof after the final Open
M4 refresh. This record accepts no other holder, plan or ADR, waives no
evidence, and grants no integration, tag or release.

<a id="disposition-m2-gate-generation-11-2026-09-14"></a>
### M2 gate generation 11 acceptance — 2026-09-14

Continuing the phase A sequence under the maintainer's chosen route, the
reviewer authored M2 gate generation 11 at pushed proposal
`380e064ae886e271d5931aa58f3b00dfca2614d4` and presented its evidence: the
single prescribed `unfinished shared binding sequence` status stop, the
runner's syntax passing with no earlier floor literal remaining, and
holder-scoped validation at the M1 rebind naming M2, M3 and M4 as pending.
The maintainer answered **"accept"**.

That lineage was then re-created once after the status checker repair at
`47784aa` described in the
[M0 generation 7 record](#disposition-m0-gate-generation-7-2026-09-13). The
re-created proposal `671819a5e61418e6dea65e94e887d2a25f93d7a3` carries the
same change as `380e064ae886e271d5931aa58f3b00dfca2614d4` on top of that
repair and the re-created earlier rebinds, verified by the reviewer with a
tree diff before this rebind. On 2026-09-14 the maintainer approved the
rebuild and accepted every re-created phase A proposal on that basis,
answering **"Approve and accept rebuild all"**.

That lineage was re-created a second time after the repair was widened at
`d276f325169af6ab54464648a6578da6b4e499c7`, described in the
[M0 generation 7 record](#disposition-m0-gate-generation-7-2026-09-13). The
proposal `6fdef34d959e4c2a37631c1cc6aaa18fc6de3187` carries the same change
as `380e064ae886e271d5931aa58f3b00dfca2614d4` on top of the widened repair and
the preceding re-created rebinds, verified by the reviewer with a tree diff
before this rebind. On 2026-09-14 the maintainer approved the second rebuild
and accepted every re-created phase A proposal and the re-created M4
candidate on that basis, answering **"I accept recreated proposals and
candidate. i need to do a second review after the final sha table is
created"**. This row binds that proposal.

This accepts generation 11 alone under `amendment-transaction-v2`: the
floor-only literal changes in M2's bound gate runner for the accepted pair
Elixir 1.18.5 with OTP 27.3.4, bound at
`0d1feb8324367b27250cfa3093c2dff78963115d516f4d1601be2a7e53d9110c`, the
rebound pins, and the amended M2 gate at
`sha256:5b3df5304a7b69c6e86a93829be0c77cde05fcb9ff0df0230221fc961b8b84dd`.
This immediate-child rebind changes only the generation-11 row in
`docs/plans/M2.md` and adds this disposition. M2's historical Acceptance and
Closure, earlier dispositions and generations, envelopes, register and
lifecycle state remain unchanged, and M2 remains Closed.

M3 and M4 still hold the previous pins in their own tables and settle next
in register order; holder-scoped validation at this rebind names them as
pending rather than reporting a global pass. A `darwin-floor` capture of the
M2 gate under the new pair belongs to the inherited-green proof after the
final Open M4 refresh. This record accepts no other holder, plan or ADR,
waives no evidence, and grants no integration, tag or release.

<a id="disposition-m3-gate-generation-4-2026-09-14"></a>
### M3 gate generation 4 acceptance — 2026-09-14

Completing the Closed holders of the phase A sequence under the maintainer's
chosen route, the reviewer authored M3 gate generation 4 at pushed proposal
`2f76946fa3c23e55e0f2e36103fc5dbd61bfd3fc` and presented its evidence: the
single prescribed `unfinished shared binding sequence` status stop, the M3
gate's inspection role verifying its bound artifacts against the rebound
pins, and holder-scoped validation at the M2 rebind naming M3 and M4 as
pending. The maintainer answered **"Accept"**.

That lineage was then re-created once after the status checker repair at
`47784aa` described in the
[M0 generation 7 record](#disposition-m0-gate-generation-7-2026-09-13). The
re-created proposal `77d9480c2f19c808bab5cc5d9efeac6d82a95ad3` carries the
same change as `2f76946fa3c23e55e0f2e36103fc5dbd61bfd3fc` on top of that
repair and the re-created earlier rebinds, verified by the reviewer with a
tree diff before this rebind. On 2026-09-14 the maintainer approved the
rebuild and accepted every re-created phase A proposal on that basis,
answering **"Approve and accept rebuild all"**.

That lineage was re-created a second time after the repair was widened at
`d276f325169af6ab54464648a6578da6b4e499c7`, described in the
[M0 generation 7 record](#disposition-m0-gate-generation-7-2026-09-13). The
proposal `e0dbaef134ef770316931e03fe1caf1cf81851d1` carries the same change
as `2f76946fa3c23e55e0f2e36103fc5dbd61bfd3fc` on top of the widened repair and
the preceding re-created rebinds, verified by the reviewer with a tree diff
before this rebind. On 2026-09-14 the maintainer approved the second rebuild
and accepted every re-created phase A proposal and the re-created M4
candidate on that basis, answering **"I accept recreated proposals and
candidate. i need to do a second review after the final sha table is
created"**. This row binds that proposal.

This accepts generation 4 alone under `amendment-transaction-v2`: the
rebound `.tool-versions` row for the accepted pair Elixir 1.18.5 with OTP
27.3.4 at `fea095ecec784a4440b872ad5f53a8da2cb4e13e43b6f05add5cfd75bb352879`,
the added v2 marker, and the amended M3 gate at
`sha256:30b5c87de35e739ccc5743202ac770d25aae5d1bcd4af16ba62a34649a43fcf6`.
This immediate-child rebind changes only the generation-4 row in
`docs/plans/M3.md` and adds this disposition. M3's historical Acceptance and
Closure, earlier dispositions, envelopes, register and lifecycle state remain
unchanged, and M3 remains Closed.

Open M4 is the last holder still naming the previous pins; it refreshes its
own table directly, and holder-scoped validation at this rebind names it as
pending rather than reporting a global pass. Runs of the M3 gate under the
new floor pair belong to the inherited-green proof after that refresh. This
record accepts no other holder, plan or ADR, waives no evidence, and grants
no integration, tag or release.

<a id="disposition-m4-plan-acceptance-2026-09-14"></a>
### M4 plan acceptance — 2026-09-14

With the five prerequisite ADRs accepted and every `.tool-versions` holder
settled, the reviewer presented the Open M4 refresh at pushed
`9810f308b48432b5787704a9dc6de0263afbed69` as the acceptance candidate,
with this evidence: holder-scoped validation at the M3 rebind naming only M4
as pending; the candidate's status check stopping only on the shared binding
sequence that this Acceptance row completes; M4 gate inspection verifying all
fourteen bound rows; M4 preflight reporting the compile control green and the
declared `interaction_unsupported` opening red; the bound fixture check and
its seven tests passing under both installed pairs; and the commit-message,
hygiene and agent-bootstrap checks passing. The packet stated that the
reviewer had authored the candidate and asked the maintainer to obtain an
independent exact-SHA reading before accepting. The maintainer answered
**"Accept"**.

The transition recorded against that candidate was refused by the repository
status checker, whose governance walk required a plan's first acceptance to
bind a gate at generation zero while the sequential holder transaction had
required Open M4 to refresh its shared `.tool-versions` binding through an
amendment. The checker was repaired at `47784aa` so that a first acceptance
may bind the direct proposal that advanced the gate by exactly one to
complete such a refresh, and the phase A lineage was re-created on top of
that repair, each proposal carrying the same change as its original and each
rebind carrying its re-created record forward. The re-created candidate
`34b4ac98ade7abfeac5c3709a3d6d92a7530b38d` carries the same change as
`9810f308b48432b5787704a9dc6de0263afbed69`, verified by the reviewer with a
tree diff. On 2026-09-14 the maintainer approved that rebuild and accepted
the re-created M4 candidate on the same basis, answering **"Approve and
accept rebuild all"**.

The transition recorded against `34b4ac98ade7abfeac5c3709a3d6d92a7530b38d`
was refused in turn by the plan validator, which read every generation-one
candidate as an amendment proposal that must keep its Open state and required
the original terminating an acceptance chain to sit at generation zero. The
repair was widened at `d276f325169af6ab54464648a6578da6b4e499c7` and the
phase A lineage re-created a second time on it, each proposal carrying the
same change as its original and each rebind carrying its re-created record
forward. The candidate `27e517b3391ddc7c12b5f638f66434923ab021e3` carries
the same change as `9810f308b48432b5787704a9dc6de0263afbed69`, verified by
the reviewer with a tree diff. On 2026-09-14 the maintainer approved the
second rebuild and accepted the re-created M4 candidate on that basis,
answering **"I accept recreated proposals and candidate. i need to do a
second review after the final sha table is created"**, and so stated that a
further review follows the final SHA table before integration.

This transcribes those answers as the maintainer's acceptance of the exact
[M4 Concept plan](../plans/M4.md#concept), its
[Technical depth](../plans/M4-technical.md#technical-depth) and its
[gate](../plans/M4-gate.md) at `27e517b3391ddc7c12b5f638f66434923ab021e3`,
binding Concept envelope
`940155e9a858080c88fca61df765def26b8b3dbbe45d7f54218a819d785d9263`,
Technical depth envelope
`08b59ec9514b99a97b48d8945cc10a4be414ebfaf9b007ee019359a54e7c0226`
and gate `f0163872dff3314c3cefe3ecacf7f36a0090012f00a641c8004aa81503225e56`.
The Acceptance row is also the rebind that completes the M4 floor-binding
refresh recorded as that gate's Amendment 1. This transition changes only the
Acceptance row, the register row and its derived capsule and README summary,
and adds this disposition.

Consequences and what remains owed. M4 moves to Accepted and implementation
inside its envelopes may proceed on branch `m4`. The candidate was authored
by the reviewer; the independent read-only exact-SHA review that the
development contract requires before this governance checkpoint integrates
to `main` is still owed by an actor other than the author, and this record
does not substitute for it. The inherited M0–M3 gates on both pairs, the M0
run under the new floor pair recorded in the matrix evidence, and M4's
distinct red are proved at this transition and thereafter; they require the
maintainer's provider key for the real lanes and have not yet run. This
record grants no merge to `main`, integration, tag, publication or release.

<a id="override-disposition-m4-inherited-evidence-before-integration-2026-09-14"></a>
### M4 inherited evidence deferred to before integration — 2026-09-14

The maintainer's second review of the pushed lineage at
`722677ee50efdc3cddcb900d0ff1a4e268dad8ad` found no new product or
locked-gate defect but would not integrate the checkpoint yet, because the
[acceptance disposition](#disposition-m4-plan-acceptance-2026-09-14) above
calls the inherited evidence "proved at this transition and thereafter"
while stating in the same sentence that the real-provider lanes have not run,
and because `mix loopex.matrix` exits 1 on the M0 toolchain matrix record,
which carries no run under the new floor pair Elixir 1.18.5 with OTP 27.3.4.
The review asked that the precise deferral be recorded in a standalone
override, independently reviewed before integration relies on it, and that
the deferred checks never be labelled green. The maintainer explicitly
directed:

> fix this so that some things we can do after acceptance, some things we
> need to do before m4 acceptance - i want to move on .. no big feature
> gotchas, just gate and ci/cd gotchas

Under the [explicit maintainer override](../../AGENTS.md#maintainer-override),
this names the continuing development-time requirement it moves. The
[M4 technical plan](../plans/M4-technical.md#technical-depth) and its
successor-enabling row require every inherited gate green and M4's own
distinct red to be re-proved on the refreshed base before acceptance, and the
development contract requires the full inherited set at the acceptance base.
The keyless part of that obligation was met at acceptance transition
`dcf033bc4b9c3c78462377576117aa799bbdeac6` and its candidate
`27e517b3391ddc7c12b5f638f66434923ab021e3`: the bootstrap aggregate with the
full history-aware status walk, holder-scoped binding validation at each
rebind, M4 gate inspection of every bound artifact, and the M4 preflight
reporting the compile control green and the declared
`interaction_unsupported` opening red, each from a clean clone. The part that
needs the maintainer's provider key or a floor-pair run is deferred, not
waived: the real-provider lanes of the inherited M0, M1, M2 and M3 gates on
both installed pairs, the M0 run under the new floor pair recorded in
[the matrix evidence](../evidence/M0-toolchain-matrix.md), and M4's distinct
red on its real lane. Those run at one pushed revision of this lineage after
the acceptance transition and before the governance-only acceptance
checkpoint integrates to `main`; each result is recorded against that
revision's SHA in the ordinary evidence locations, and a red result blocks
integration like any observed inherited regression.

Until they run, those checks are **unavailable, not passed**. The acceptance
disposition's sentence "are proved at this transition and thereafter" is read
as "are required from this transition onward and are unavailable until they
run"; that historical record stays unchanged and this disposition is the
precise statement of its meaning. The matrix task stays red for the missing
floor record until that run is recorded. No status capsule, register row,
plan progress row, runner report or review may present a deferred check as
green, and the M4 acceptance is not made retroactively false by this deferral.

Preserved guarantees: the accepted candidate, its bound envelopes and gate,
the M4 acceptance row and the register state are unchanged; no milestone
product bytes are added; implementation inside the accepted envelopes may
proceed on branch `m4` as the acceptance already allows; the independent
read-only exact-SHA review of the transition by an actor other than its
author remains owed before integration. This standalone disposition changes
nothing else and receives independent exact-SHA review before integration
relies on it. It grants no merge to `main`, tag, publication or release, and
implies no approval of any other restriction, plan, ADR or closure.

<a id="override-disposition-m4-m1-m2-inherited-reproof-waiver-2026-09-14"></a>
### M1 and M2 inherited re-proof waived for the M4 acceptance checkpoint — 2026-09-14

When the deferred lanes above were prepared, the reviewer found in the gate
code that the Closed M1 and M2 gates cannot be re-proved green under the
refreshed floor by running anything. The M1 evidence verifier bound at
generation 10 requires the retained capture rows to sit on the current locked
pairs, Elixir 1.18.5 with OTP 27.3.4 and Elixir 1.20.3 with OTP 29.0.5, and
in the same validation requires M1's Closure row to bind the evidence commit
those captures came from; the captures that closure bound were taken on
Elixir 1.17.0 with OTP 26.0, and a fresh capture set would need an evidence
commit that the immutable Closure row can never name. The M2 runner bound at
generation 11 has the same shape: its evidence lifecycle admits only an
evidence commit whose plan is still `In review` with an empty Closure row,
which is true of the closure-time captures alone, and those were recorded
on the old floor pair its Darwin floor lane no longer accepts. The M3 and M4
full gates invoke both closed gates through the closed-gates aggregate, so
neither can complete its inherited step while this holds. Presented with
this as a decision packet with three options, the maintainer explicitly
directed:

> 1. waive m1 m2 re-proof approved. let's do it as a baseline floor when
> implementing m4.

Under the [explicit maintainer override](../../AGENTS.md#maintainer-override),
this names the continuing development-time requirement it replaces: the
part of the
[inherited-evidence deferral](#override-disposition-m4-inherited-evidence-before-integration-2026-09-14)
that required the real-provider lanes of the inherited M1 and M2 gates on
both installed pairs to run before the governance-only M4 acceptance
checkpoint integrates to `main`. For that integration those two re-proofs are
**waived, not passed**. As a consequence the M3 full gate and the M4 full gate
cannot run their inherited step at this checkpoint, so M3's real-lane green
and M4's real-lane red are likewise unavailable evidence here, not passed and
not waived by name; M4's declared opening red is carried by its preflight
role, which runs no inherited gate. What is still required before
integration and is not waived: the M0 gate green under both pairs at a pushed
revision, with the floor-pair run recorded in
[the matrix evidence](../evidence/M0-toolchain-matrix.md), the bootstrap
aggregate green, and M4 inspection and preflight at that revision.

Successor obligation, recorded from the same instruction: repairing the two
runners is a baseline of M4 implementation, not a later milestone. Before M4
closure, M1 and M2 each gain a gate generation under
`amendment-transaction-v2` whose verifier or runner admits a post-closure
re-capture set under the currently locked pairs without touching the
immutable Closure rows, then the captures run on both hosts and the
inherited aggregate is proved green at an M4 revision; until that lands, M4
closure cannot claim inherited green and any M1 or M2 regression under the
new floor is unobserved. This override adds no product change, converts no
red into a pass, reopens no lifecycle state, and grants no merge to `main`,
tag, publication or release. It is one standalone commit and receives
independent exact-SHA review before integration relies on it.

<a id="override-disposition-m4-m0-reproof-deferred-to-implementation-2026-09-14"></a>
### M0 re-proof under the refreshed floor deferred to M4 implementation — 2026-09-14

With the M1 and M2 re-proofs waived, the M0 gate under both pairs and its
floor-pair matrix record were the last keyed evidence the
[inherited-evidence deferral](#override-disposition-m4-inherited-evidence-before-integration-2026-09-14)
still required before the governance-only M4 acceptance checkpoint
integrates. Each green M0 run now carries the full bootstrap aggregate with
its history walk, so the two runs and the record cost about an hour and a
half more. Told that, the maintainer explicitly directed:

> ok, do you need m0 runs? we can do that as part of m4 implementation as
> baseline. this is plan mode

Under the [explicit maintainer override](../../AGENTS.md#maintainer-override),
this replaces the remaining M0 requirement of that deferral for this
checkpoint's integration: the M0 gate green under both locked pairs at a
pushed revision, and the run under the floor pair Elixir 1.18.5 with OTP
27.3.4 recorded in [the matrix evidence](../evidence/M0-toolchain-matrix.md),
are deferred to M4 implementation as a baseline task, not waived and not
passed. Until they are recorded, `mix loopex.matrix` stays red for the
missing floor record, the M0 gate is red at outcome 3 under every
toolchain, and no status text may present either as green. The checkpoint
carries no product bytes, so this defers proof of an unchanged closed gate
rather than of anything the checkpoint adds. A diagnostic only, not
evidence: a floor-pair M0 run at `4048ddc9dd603365f6cc2738a0316a3f40f4a4d5`
with provisional matrix rows present cleared outcomes 1 through 7,
including the real-provider call, before it was stopped inside outcome 8's
aggregate on this instruction.

What integration still relies on, unchanged: the bootstrap aggregate green
at a pushed revision of this lineage, M4 inspection and preflight at the
tip, and the reviews the earlier dispositions name. Successor obligation:
the first M4 implementation baseline records the M0 runs under both pairs
with the floor-pair row in the matrix evidence and re-proves the M0 gate at
that revision, alongside the M1 and M2 runner repair the
[waiver](#override-disposition-m4-m1-m2-inherited-reproof-waiver-2026-09-14)
records; M4 closure cannot claim inherited green before both land. This
override adds no product change, converts no red into a pass, reopens no
lifecycle state, and grants no merge to `main`, tag, publication or release.
It is one standalone commit and receives independent exact-SHA review before
integration relies on it.

<a id="override-disposition-m4-commit-titles-2026-09-15"></a>
### M4 published commit-title exception, 2026-09-15

The maintainer received this recommendation while the Amendment 7 rebind was
being verified:

> Bootstrap fails at R on a check that has never run on this branch: six commit titles exceed the 72-character limit. All six are ancestors of proposal A, so shortening any of them changes A's hash and voids R's Acceptance binding. One of them, 2e06da1, is Amendment 6's bound candidate and cannot be rewritten at all without falsifying the durable record. The check already supports waivers — M3 recorded one covering eight commits. How do you want to proceed?

The recommended choice was **"Record the exception (Recommended)"**. The
maintainer answered by selecting it. The alternative offered was a further
history rewrite, and it was presented as unable to reach a clean state: the
Amendment 7 proposal is itself one of the six and the other five are its
ancestors, so rewriting any of them changes that proposal's hash and voids the
rebind that binds it, and
`2e06da13ee01391690c1731edbf6190ab4471f1c` would still violate the limit
afterwards because its hash is named as Amendment 6's bound candidate. A rewrite
would therefore have spent a fourth proposal, review and acceptance and still
required an exception, narrower than this one but covering that commit.

Under [the explicit maintainer override](../../AGENTS.md#maintainer-override),
this replaces only the continuing 72-character title limit in
`scripts/check-commit-messages.sh` for these six immutable commits in the M4
implementation lineage. Title *format* is not excepted: each of the six already
satisfies the `area(marker): summary` grammar and fails on length alone, and the
replacement must keep grammar enforced for them.

| Commit | Existing title |
| --- | --- |
| `18100cafaefd3b6f3fbb73757b590287908738c7` | gate(M4): shorten an outcome 7 witness identity to a name a test can carry |
| `7bb2a9bd2e33e159a3ed7441a1ad3d0445cda954` | fix(M4): name the old reader's build environment instead of inheriting it |
| `9905a870d7363e93b808459e89cd57865ffc72ee` | fix(M4): anchor the repository root to the file, not the working directory |
| `2e06da13ee01391690c1731edbf6190ab4471f1c` | plan(M4): propose Amendment 6 to finish the renames in the witness identities |
| `d2a916552209408019df8acf83ef5cc5ca3bf0a9` | feat(M4): answer the policy's question from outside and read what the tool kept |
| `20fcec3d0e499eacde3599b8fdb41a460c0a5c8b` | test(M4): write the conformance vectors an independent client checks itself against |

Why these six are immutable rather than merely inconvenient:
`18100cafaefd3b6f3fbb73757b590287908738c7` is itself the candidate whose exact
bytes the Acceptance row in `docs/plans/M4.md` binds, so changing its title
changes the bound bytes directly. The other five are its ancestors, so changing
any of their titles changes that candidate's hash and falsifies the rebind.
`2e06da13ee01391690c1731edbf6190ab4471f1c` carries a second, independent reason:
it is named as Amendment 6's bound candidate in this document, and AGENTS.md
requires a bound candidate to remain reachable from the integrated history.

This condition also bears on `amendment-transaction-v1`, and the record must not
be read as claiming more than was proved. That transaction requires bootstrap to
fail at the proposal only for the stale binding, and to pass at the rebind.
Bootstrap runs this checker, and these six titles are ancestors of the proposal,
so bootstrap was red at the proposal on two independent grounds — the stale gate
binding and this pre-existing title condition — and it could not pass at the
rebind, because the fix may not intervene between a proposal and its rebind and
the rebind may not change portable enforcement. Bootstrap at the rebind's own
bytes was therefore **red**, and no run at those bytes can ever pass, so the
`amendment-transaction-v1` requirement that bootstrap pass at the rebind is
**unmet**. It is not unavailable evidence: the check ran there and exited
non-zero. AGENTS.md classifies a later-discovered red that went unobserved at a
required contract moment as an evidence-schedule defect, and that is what this
is. Binding validation itself was measured
directly at both revisions: red at the proposal on the stale gate binding alone,
green at the rebind. Amendment 7's accepted text says binding validation,
bootstrap and every inherited gate that invokes them stop at the proposal only on
the stale binding of this gate; that sentence is accurate for binding validation
and overstates bootstrap. This disposition records the difference rather than
leaving it implicit, and it corrects no accepted bytes: the gate text stands as
accepted. This disposition claims no replacement for that requirement: its
scope remains the 72-character title limit alone, the unmet at-rebind condition is
recorded here as a defect rather than waived -- it is not self-clearing, it stays
open, and it requires explicit maintainer disposition before M4 closure, since a
red required check blocks closure -- and the remediation is a
complete green bootstrap run on the descendant that carries this exception,
retained with the SHA it ran at. That run is remediation, not substitute
evidence for the rebind's own bytes.

Each exception must be matched by its complete SHA and reported as waived, and
the report must name length rather than grammar, so that an over-grant is visible
in the output. Preserve the fixed baseline, complete-history requirement, commit
enumeration and stream accounting, prospective title controls, and unconditional
commit-body attribution and scan-error checks. Every other commit remains subject
to the complete policy, and every future commit remains subject to the
72-character limit. No history rewrite is authorized or needed. Every accepted
candidate, bound artifact, disposition and historical evidence identity remains
unchanged. No M0–M4 gate binds this checker's bytes, so this change needs no
replacement gate binding; several gates do lock the bootstrap aggregate as a
command, which the required validation below covers.

Before changing the checker, independently review this standalone disposition
commit at its exact SHA. Then prove that the original check refuses exactly these
six titles and no others; that the replacement reports all six as length-waived;
that grammar remains enforced for these six, so a malformed title among them
would still fail; that a seventh over-long title still fails; and that body
attribution and scan-error checking remain effective. Run the complete bootstrap
check on the resulting candidate and retain its result, with the SHA it ran at,
as the remediation run named above. It is not retained as evidence that the
at-rebind condition was met.

This grants no exception to a product test or other check, no additional title
exception, and no ADR change, milestone closure, product integration to `main`,
tag, or release. The red commit-title evidence retained for the revisions above
remains true for those revisions.

<a id="override-disposition-m4-bootstrap-at-rebind-2026-09-15"></a>
### M4 bootstrap at the Amendment 7 rebind, 2026-09-15

The maintainer received this question after the commit-title exception was
recorded:

> The disposition records bootstrap-at-R as an unmet v1 condition — red, not waived, not self-clearing, requiring your explicit disposition before M4 closure. I declined to waive it myself since you approved recording the state, not granting a second procedural replacement. When and how should it be dispositioned?

The recommended choice was to disposition it at closure, once the remediation
run existed. The maintainer instead selected the option labelled
**"Disposition it now, standalone"**, whose full text was:

> A separate override disposition today, reviewed at its exact SHA, closing the record before closure work begins. Cleaner if you want nothing open in the durable record, but it costs another commit plus another review round, and it would cite a remediation run that has not happened yet.

This is the explicit maintainer disposition that
[the title exception](#override-disposition-m4-commit-titles-2026-09-15)
requires before closure for the bootstrap component; that item is no longer
open. The inherited-gate component named below is the item that remains open.

Under [the explicit maintainer override](../../AGENTS.md#maintainer-override),
this names the requirement it replaces. `amendment-transaction-v1` requires
that at the rebind `R`, binding validation, bootstrap and every inherited
required gate pass. For the single rebind
`9e08a7ad748ab9bc2acafcd4b6f09207f3a5fcf9`, which binds the Amendment 7
proposal `18100cafaefd3b6f3fbb73757b590287908738c7`, the bootstrap component of
that requirement is replaced by the evidence named below. Binding validation
at that rebind was measured directly and passed and is not touched.

Why the condition could not be met at those bytes, as recorded in the title
exception: `scripts/check-bootstrap.sh` runs `scripts/check-commit-messages.sh`;
six already-published titles over 72 characters are the proposal or its
ancestors; the check ran at the rebind and exited non-zero; no commit may
intervene between a proposal and its rebind, and the rebind may not change
portable enforcement. Bootstrap at the rebind's own bytes was red on that
pre-existing condition and no run at those bytes can ever pass. The title
exception that removes the condition landed afterwards at
`08782a0873a2438fbfedb6ab5a3ecfc73c9c7217`.

**The inherited-gate component is unmet at the same rebind and is not replaced
here.** The same six titles make it so: the locked lanes of the Closed M1 and
M2 gates run the bootstrap aggregate, and M4's own inherited lane runs every
Closed gate, so at the rebind's bytes those lanes were red for exactly the
reason above. This record does not replace that component; it stays unmet and
open. No replacement evidence for it exists yet: in the full M4 gate at
`08782a0873a2438fbfedb6ab5a3ecfc73c9c7217` the inherited lane exited non-zero
on a pre-existing defect in the Closed M0 gate — outcome 8's search-path scan
matching two reader lines in the M1 evidence test — which is being repaired as
M1 gate generation 16. Its green run on a descendant, when it exists, is cited
in a later durable record and never by editing this one, and until then that
component requires its own explicit maintainer disposition before closure.

**Replacement evidence for the bootstrap component.** A complete green run of
`scripts/check-bootstrap.sh` at a descendant of the rebind that carries the
title exception, retained with the exact revision it ran at. That run
completed on 2026-09-15 inside the full M4 gate at
`08782a0873a2438fbfedb6ab5a3ecfc73c9c7217`: the aggregate exited 0 after 2342
seconds, every check green including `status check passed`, with the six
excepted titles reported as length-waived. The bootstrap segment of that gate
log is retained verbatim in
[M4 bootstrap remediation](../evidence/M4-bootstrap-remediation.md) with the
segment's digest
`sha256:c81e881ffc1a1067c7b6efb8e7b016795addbacc8d76354fd608cd99754c8b11` and
the gate's own source line naming the revision and toolchain. That retained
green run is what satisfies this disposition; recording the disposition alone
would not have.

Preserved: every other `amendment-transaction-v1` requirement, at this rebind
and at every other; the accepted Amendment 7 bytes and the gate digest the
Acceptance row binds; the title exception's own scope, which remains the
72-character limit alone; and the finding that Amendment 7's accepted text
overstates bootstrap at the proposal, which stands as recorded. This grants no
further exception, no ADR change, no closure, no integration to `main`, no tag
and no release. The red bootstrap evidence for the rebind's own bytes remains
true for that revision.

Before dependent work, independently review this standalone disposition at its
exact SHA. The result it rests on is recorded above and in the evidence file;
this record is not edited after that review. A later run of the same aggregate
that is not green leaves the requirement unmet again and is recorded on its
own.

<a id="disposition-m4-observability-rule-2026-09-15"></a>
### Observability rule directed by the maintainer, 2026-09-15

While the full M4 gate at `08782a0873a2438fbfedb6ab5a3ecfc73c9c7217` had been
silent for forty minutes inside a history walk, with progress inferable only
from the process table, the maintainer directed:

> All gates, bootstraps etc going forward must have logging or instrumentation. Put that as a hard rule in Agents.md. after this run finishes. Go add those, even if it requires amendments.

This records that direction as the authority for the observability rule in
`AGENTS.md` and for the retrofits that follow it: ordinary commits where the
script is unbound, and the amendment route where it is digest-bound. It is a
strengthening of the development contract and grants nothing.

<a id="disposition-m1-gate-generation-11-2026-09-14"></a>
### M1 gate generation 11 acceptance — 2026-09-14

Working M4's Workstream 0 baseline on branch `m4`, the implementer found that
the Closed M1 gate could not be re-proved under the refreshed floor by
running anything: its bound verifier judged the closure captures against the
working tree's `.tool-versions` while tying every capture to the evidence
commit the Closure row names. Asked in plain terms to choose between a second
evidence block, replacing the closure captures, and running lanes live, the
maintainer chose the second evidence block. The implementer then presented
proposal `A` at `192611fd8dde220bcfd75ca55ea23ee2314a0951` with this evidence: the rewritten verifier
and its bound corpus green on the current pair (eleven cases, one new),
formatting, agent-bootstrap, commit-message and hygiene checks passing, and
the full status walk at `A` stopping only on the pending generation row. The
maintainer answered **"i accept 192611f"**.

This accepts generation 11 alone under `amendment-transaction-v2`: the
verifier reads the closure block against the pairs locked at its own
candidate, admits exactly one post-closure re-capture block taken on the
current pairs at a descendant of the closure transition and retained by every
later revision, refuses a re-capture while the locked pairs are unchanged,
and declares its absence the red once they differ. The Acceptance and Closure
rows, every earlier generation and every historical revision remain exactly
as recorded. This row binds the proposal; the re-capture itself and the M0
re-proof it records follow as evidence commit `E'` and are not accepted
here. It grants no closure, integration, tag or release.

<a id="disposition-m4-gate-amendment-2-2026-09-14"></a>
### M4 gate Amendment 2 acceptance — 2026-09-14

The first M0 gate run taken for M4's Workstream 0 baseline was red at
outcome 8 on both toolchain pairs: the closed M0 gate scans every tracked byte
for an interpreter invocation shape that could bypass its retired-dependency
shadow, and the accepted M4 gate document's report grammar spelled the Python
pin as an assignment token followed by a bare `python` field, which that scan
refuses. The M0 gate is locked and its scan deliberate, so the implementer
proposed M4's Amendment 2 at `64bd3bb588ecf4db8274f8bd8369bcd8bdf034f0`: the two pin fields renamed to
`node_pin` and `python_pin` in the grammar, the runner's printed report and
the support script's grammar table, and the gate document's opening
paragraphs conformed to the recorded acceptance. Evidence presented: M4
inspection verifying the rebound runner and support bytes, the M4 preflight
reproducing the accepted opening red, the bypass scan finding no remaining
match on the branch, and formatting, agent-bootstrap, commit-message and
hygiene checks passing. The maintainer answered **"Accept 64bd3bb (Recommended)"**.

This transcribes that answer as acceptance of Amendment 2 under
`amendment-transaction-v1`. The rebind binds the Acceptance row to exact
`64bd3bb588ecf4db8274f8bd8369bcd8bdf034f0` with the unchanged Concept and Technical depth envelope
digests and the amended gate digest; it changes no lifecycle state, outcome,
selector, witness, limit or client pin, and grants no closure, integration,
tag or release.

<a id="disposition-m2-gate-generation-12-2026-09-14"></a>
### M2 gate generation 12 acceptance — 2026-09-14

Working M4's Workstream 0 baseline on branch `m4`, the implementer found that
the Closed M2 gate, like M1's, could not be re-proved under the refreshed
floor by running anything: its runner judged the closure captures against
its current lane literals while its evidence lifecycle admitted only the
evidence commit whose four blobs stay byte-identical for ever. The maintainer
had already chosen the second-evidence-block design for M1 generation 11, and
the implementer presented M2's proposal `A` at `a8be26ccd11e318a5497193bf3e3d087ead20bee` on the same
design with this evidence: the rewritten runner's syntax passing, its bound
isolation and lifecycle corpus green on the current pair (eight cases, one
new), formatting, agent-bootstrap, commit-message and hygiene checks passing,
and the full status walk at `A` stopping only on the pending generation row.
The maintainer answered **"Accept a8be26c (Recommended)"**.

This accepts generation 12 alone under `amendment-transaction-v2`: the runner
reads the pairs each evidence block answers for from `.tool-versions` at that
block's own candidate, admits exactly one post-closure re-capture block taken
on the current pairs at a descendant of the closure transition and retained
by every later revision, refuses a re-capture while the locked pairs are
unchanged, and declares its absence the red once they differ. The Acceptance
and Closure rows, every earlier generation and every historical revision
remain exactly as recorded. This row binds the proposal; the re-capture
itself and the M0 and M1 re-proofs it records follow as evidence commit `E'`
and are not accepted here. It grants no closure, integration, tag or release.

<a id="disposition-m1-gate-generation-12-2026-09-14"></a>
### M1 gate generation 12 acceptance — 2026-09-14

Taking the generation 11 re-capture exposed a defect in the M1 runner's own
environment boundary: it appended the four system directories to the isolated
toolchain path before the directories it discovered for `mix`, `elixir` and
`erl`, so on a host that also carries those entrypoints in a system directory
the system copy decided the running pair and the bound verifier refused the
lane as not one exact locked pair. The Linux current lane could not be
captured at all. Presented with three ways to scope the re-capture lanes, the
maintainer chose to keep all three lanes and allow the Linux lane to run on
the host toolchain, which requires this change to bound gate machinery. The
implementer then presented proposal `A` at `3181ad25a98360d12b47a93a82ad070d3c9851a9` with this
evidence: the runner's syntax passing; the new corpus case passing on both
hosts, exercising the unchanged order on Darwin and the reordered order on
Linux; the fixture role reporting a byte-identical path on Darwin and the
locked pair first on Linux; formatting, agent-bootstrap, commit-message and
hygiene checks passing; and the full status walk at `A` stopping only on the
pending generation row. The maintainer answered **"Accept 3181ad2 (Recommended)"**.

This accepts generation 12 alone under `amendment-transaction-v2`: the runner
places the discovered toolchain directories ahead of the system directories
only where a system directory would otherwise decide the running pair, leaves
the constructed path unchanged everywhere else, and keeps every system
directory on the path so ordinary tools keep their platform identity. The
running pair is still proved by the bound evidence verifier, which this
ordering feeds rather than replaces. The Acceptance and Closure
rows, every earlier generation and every historical revision remain exactly
as recorded. This row binds the proposal; the re-capture itself and the M0
re-proof it records follow as evidence commit `E'` and are not accepted
here. It grants no closure, integration, tag or release.

<a id="disposition-m1-gate-generation-13-2026-09-14"></a>
### M1 gate generation 13 acceptance — 2026-09-14

The first capture of the M1 gate after generation 12 failed on the Linux
current lane at the protected corpus, on the case generation 12 had added:
that witness read the path it inherited and compared the fixture role's
answer against it, so run as a protected selector it inherited the isolated
path the gate had already built, and on a host whose system directories carry
the toolchain the case failed inside the gate it protects while passing when
run directly. The implementer presented proposal `A` at `5997542d0e17079141364f760b53c63097091c46`,
which changes only that case so it supplies the incoming path explicitly and
computes its expectation from the same list, with this evidence: the
runner's ordering unchanged from generation 12; the corrected case passing
on both hosts against that runner, exercising the unchanged branch on Darwin
and the reordered branch on Linux; formatting, agent-bootstrap,
commit-message and hygiene checks passing. The full status walk at `A` was
still running when the maintainer answered **"generation 13 accepted."**; it finished
afterwards and stopped only on the pending generation row, which is the
condition this record requires before binding.

This accepts generation 13 alone under `amendment-transaction-v2`: the
toolchain-path witness supplies the path it tests instead of inheriting one,
asserts the established order where no system directory carries the
toolchain and the reordered order where one does, and refuses a supplied path
that carries no complete toolchain. The Acceptance and Closure rows, every
earlier generation and every historical revision remain exactly as recorded.
This row binds the proposal; the re-capture itself and the M0 re-proof it
records follow as evidence commit `E'` and are not accepted here. It grants
no closure, integration, tag or release.

<a id="disposition-m1-gate-generation-14-2026-09-15"></a>
### M1 gate generation 14 acceptance — 2026-09-15

The M1 gate's evidence case builds a fixture repository and runs it under the
gate's own sanitized environment, supplying the home directory that environment
provides. On a real Linux host the child refused, reporting that the supplied
home does not physically match the operating-system account home. The
implementer reproduced the refusal by hand under the gate's exact sanitized
environment before writing anything, so the cause is the witness rather than the
host: generation 13's case handed the child a home the account did not own.

Generation 14 repairs it at `994421ffe0023445926f727cdaf1a1f352f609f3`. The case
reads the account home from the passwd database and passes it to the fixture
child beside the path; the gate script's embedded corpus digest follows the
changed case bytes; and the gate and plan documents gain the amendment section
and the generation row. Nothing else in the case changes and nothing outside it
changes. Evidence presented: the full bound corpus passing on the current
toolchain pair, and the repaired case passing on Linux under the gate's own
isolated home, which is the condition that refused it.

The maintainer answered **"I already accepted generation 14 for m1. i accept."**

This transcribes that answer as acceptance under `amendment-transaction-v2`.
The rebind completes generation 14's row with the accepting authority, this
disposition and the candidate it binds, which is exact
`994421ffe0023445926f727cdaf1a1f352f609f3`. The Acceptance and Closure rows of
Closed M1 stay byte-immutable, no earlier generation stops being enforced for
the revisions it governed, and this adds no scope, changes no outcome and
reopens no lifecycle state. It grants no closure, integration, tag or release.

<a id="disposition-m1-gate-generation-15-2026-09-15"></a>
### M1 gate generation 15 acceptance — 2026-09-15

The closed M1 gate binds `apps/loopex/lib/mix/tasks/loopex.deps_budget.ex` and
`apps/loopex/test/deps_budget_test.exs`, because that oracle is the whole surface
keeping core on the standard library and the single event dispatcher the vision's
dependency doctrine admits by name. M4's Phase B rewrote both, which is how the
oracle learned about `loopex_telemetry` and `loopex_app_server`, and no M1
transaction rebound them. The oracle has read `7f5dfc6c` since that work landed
while this gate went on naming `2c62019c`.

It was found by a repository status walk rather than by any gate run, and only
because two unrelated M4 amendment faults were being repaired ahead of it: the
walk had never reached this far before, stopping earlier on those. Every revision
from `03d0ed6c3e0241c6a7e7df85e208ea44f167fd23` to the branch tip failed the
binding check, so the defect was not historical at all — it was the state of the
branch.

A later generation cannot repair it, because each revision is judged against the
gate table as it stood at that revision. The repair therefore rewrites the two
Phase B revisions: the first now adds the applications and leaves the bound
artifacts alone, so the binding holds there, and the second is this generation's
proposal, carrying the new oracle bytes, the new test bytes, both rebound rows,
the amendment section and the generation row in one atomic revision. Between the
two the budget check is red, because an oracle written for the exact M1 inventory
cannot admit applications that did not exist then; that is an intermediate red in
a two-step change and it is named in both commit messages rather than hidden.

Generation 15 is proposed at `e5f87fda567cae616247a8e990514c145c03d452`. What the
oracle now admits is what the M4 plan pair names and no more: two applications
with their roles, one external dependency in core at its pinned requirement, and
the same one in the edge application that forwards telemetry. Direction is
unchanged, and the bound test moves with the oracle, still refusing an unplanned
application, a second external dependency and a reversed edge. Evidence presented
at that exact revision: `mix loopex.deps_budget` reporting that the budget and
direction hold, which neither neighbouring revision can do, and the bound test
passing with 28 cases.

The maintainer answered **"e5f87fd accepted."**

This transcribes that answer as acceptance under `amendment-transaction-v2`. The
rebind completes generation 15's row with the accepting authority, this
disposition and the candidate it binds, which is exact
`e5f87fda567cae616247a8e990514c145c03d452`. The Acceptance and Closure rows of
Closed M1 stay byte-immutable, no earlier generation stops being enforced for the
revisions it governed, and this adds no scope, changes no outcome and reopens no
lifecycle state. It grants no closure, integration, tag or release.

<a id="override-disposition-m1-generation-15-inherited-red-2026-09-15"></a>
### M1 gate red at its own generation-15 rebind, 2026-09-15

Found while preparing M1 gate generation 16, by hashing rather than by a run:
`scripts/check-m1-gate.sh` embeds each bound artifact's digest as a literal and
refuses at `require_bound_artifact` when a file's digest differs. Generation 15
(proposal `e5f87fda567cae616247a8e990514c145c03d452`, rebind
`8361efb546e7f3e72fd199ad45ad2ab487604961`) rebound
`apps/loopex/lib/mix/tasks/loopex.deps_budget.ex` and
`apps/loopex/test/deps_budget_test.exs` in the gate's Bound Artifacts table
and did not touch the runner, so the runner kept the generation-14 literals
`2c62019c…` and `bc4d5544…` for files whose digests became `7f5dfc6c…` and
`fe801bfc…`. From that rebind onward any run of the M1 gate refuses at
`bound dependency-direction reader changed after gate acceptance`. Nothing
observed it: the status walk validates the table side, which is consistent,
and the M4 gate's inherited lane stopped at a Closed M0 defect before reaching
M1. No run of the M1 gate at that rebind was made; the red is established by
the two tracked byte sets disagreeing, and at most one of them can match the
files.

The maintainer received this with the generation-16 proposal and selected
**"Fix all three, and disposition gen 15's red"**, whose full text was:

> Amend A so the runner is rebound with all three literals corrected and the prose says plainly that two were stale since generation 15. Separately, a standalone disposition records generation 15's rebind as having carried an unmet inherited-gate condition — the M1 gate red at its own rebind, unobserved — remediated by the M1 gate green at generation 16's rebind. Same treatment the bootstrap condition got, so the record stays consistent.

Under [the explicit maintainer override](../../AGENTS.md#maintainer-override),
this names the requirement it replaces. At a generation's rebind, binding
validation, bootstrap and every inherited required gate must pass; the M1 gate
is one of them, and for the single rebind
`8361efb546e7f3e72fd199ad45ad2ab487604961` it could not have. For that rebind
only, that component of the requirement is replaced by the evidence named
below. AGENTS.md calls a later-discovered red that went unobserved at a
required contract moment an evidence-schedule defect, and that is what this
is. Two things are true at once: the required run at that rebind is missing,
which AGENTS.md treats as evidence unavailable, and the tracked bytes prove
that any such run would have been red.

**Replacement evidence.** The M1 gate green at generation 16's rebind, which
carries the runner rebound with all three literals corrected, retained with
the exact revision it ran at. Until such a run is retained, the replaced
requirement stands unmet and this disposition is not satisfied; when it is
retained it is recorded on its own, never by editing this record.

Preserved: generation 15's Acceptance, Closure and generation rows, which stay
byte-immutable and true for the revisions they name; every other requirement
at that rebind and at every other; and the generation-16 proposal's own
obligations, which are not lightened by this record. This grants no further
exception, no ADR change, no closure, no integration to `main`, no tag and no
release. The runner's stale literals at
`8361efb546e7f3e72fd199ad45ad2ab487604961` remain true for that revision.

Before dependent work, independently review this standalone disposition at
its exact SHA. This record is not edited after that review.

<a id="disposition-m1-gate-generation-16-2026-09-15"></a>
### M1 gate generation 16 acceptance — 2026-09-15

The closed M1 gate binds `apps/loopex/test/m1_gate_evidence_test.exs`, whose
generation-12 witness runs the environment preflight and checks the search path
it reports. Two lines of that witness read the `PATH=` line out of the
preflight's output by literal prefix. The Closed M0 gate's outcome 8 scans
every tracked byte for the token `PATH` in any shape a shell could bind it and
admits only reviewed constructor occurrences, so the first time anything ran
M0's gate after those lines landed — the full M4 gate's inherited lane at
`08782a0873a2438fbfedb6ab5a3ecfc73c9c7217` — it refused them as an unregistered
search-path construction. They construct nothing; they read.

The maintainer chose to rewrite the reader rather than teach M0's registry,
which pins constructor definitions by their parsed form, about readers. The
reader now splits each output line at its first `=` and keeps the value only
when the key is exactly `PATH`, which selects exactly the lines the old form
selected and yields the same value for each.

Preparing the rebind found that `scripts/check-m1-gate.sh` embeds every other
bound artifact's digest as a literal and refuses when a file differs, so the
runner is rebound with the witness, as generation 14 recorded. Correcting that
literal found two more: generation 15 rebound the dependency oracle and its
test in the gate's table without touching the runner, so the runner's literals
have disagreed with the table since that rebind. Those two literals are
corrected in this generation as well, and the unmet condition at generation
15's own rebind is recorded in
[its own disposition](#override-disposition-m1-generation-15-inherited-red-2026-09-15)
rather than absorbed here.

Generation 16 is proposed at `3e1a4fdfe74e01ed057b7cf3f79ed3cddbfd4667`, in
four files: the witness, the runner, the gate with both rows rebound and its
amendment section, and the plan with the pending row. Evidence presented at
that exact revision: the rewritten witness matching M0's search-path scan zero
times where the old form matched twice; M0's own scan and checker run over the
whole tree reporting `M0 child-environment occurrences OK: 4`; the M1 evidence
test passing its twelve cases; and every one of the runner's eight embedded
literals equal to its file's digest and to the gate table. An earlier proposal
of this generation, `8e2b146`, was blocked in independent review for leaving
the runner unbound and was replaced; the review of the replacement recorded no
finding requiring action.

The maintainer answered **"3e1a4fd accepted."**

This transcribes that answer as acceptance under `amendment-transaction-v2`.
The rebind completes generation 16's row with the accepting authority, this
disposition and the candidate it binds, which is exact
`3e1a4fdfe74e01ed057b7cf3f79ed3cddbfd4667`. At this rebind the M1 gate must
pass, and that run is the evidence the generation-15 disposition names; it is
retained on its own when it is made. The Acceptance and Closure rows of Closed
M1 stay byte-immutable, no earlier generation stops being enforced for the
revisions it governed, and this adds no scope, changes no outcome and reopens
no lifecycle state. It grants no closure, integration, tag or release.

<a id="disposition-m4-plan-amendment-node-consumer-2026-09-15"></a>
### M4 plan amendment acceptance, the Node consumer — 2026-09-15

Accepted M4's plan pair described the outcome 5 consumer as a TypeScript one.
Building it raised a question the pair could not answer: a TypeScript client
needs either a compiler and a lockfile, or a runtime new enough to strip types,
and both add a second package manager or a version floor to a repository that
carries neither. The implementer put three options to the maintainer with their
costs, and the maintainer answered **"Plain Node, no build step"**, together
with **"A new top-level clients directory"** and **"Build everything else,
leave the demo for you"**. Asked afterwards how the record should read, the
maintainer answered **"Amend the outcome text to say Node"**.

The implementer first proposed an amendment to the Concept envelope alone. The
repository status check refused it: the plan pair is one authority unit, and an
amendment that moves one envelope without the other would leave the two
describing different programs. That proposal was discarded unpushed and rebuilt
to move both, which is half of what the checker admits; the other half, that
the gate must declare the amendment, went unnoticed.

That second proposal was accepted at
`9c54456de24a1be6bb909ad57eb0a80f84c088f3` and was itself invalid, for a reason
neither the implementer nor the maintainer saw at the time. It moved both
envelopes while leaving the gate untouched, and an amendment is declared in the
gate: the generation never advanced, so the repository status check reads such a
revision as a silent envelope edit and refuses it. Nothing had run the check
between that acceptance and the next day's, so the refusal surfaced only later,
by which time the revision and its rebind were pushed. The same walk showed two
further faults in that lineage: the bound candidate was left naming a revision
no ref reached, so a fresh clone could not resolve it at all, and the gate's own
text still named the consumer the pair had stopped naming.

The implementer put the repair to the maintainer on 2026-09-15 with three
options — rewrite the affected revisions, repair additively on top, or override
the rule that caught it — and the costs of each. Additive repair cannot work,
because history validation walks every reachable revision and the invalid ones
stay reachable. Overriding removes the protection that found the fault. The
maintainer answered **"Rewrite, fix everything"** and then **"Agreed with
rewrite. Go."**

The rewritten proposal is `62ad8188a658fb739d2144ac1a982beb44953708`. It carries
the same seven envelope lines, whose Concept digest is byte-identical to the one
the discarded lineage recorded, and adds what that lineage lacked: an anchored
`## Amendment 3` section that advances the gate to generation three, the same
rename carried through the gate's own readiness step, opening-probe scope
sentence, real-workflow lane, fresh-source paragraph, client pin sentence,
outcome 5 and outcome 6 obligations and operator documentation row, and the
repair of a botched replacement in outcome 5's evidence row that had left the
word "cript" standing where the old name had been.

Which languages check themselves against the conformance vectors is a different
commitment from which language the outcome 5 consumer is written in, and
narrowing it was not asked for here. Evidence presented: the exact diff, the
four faults named above with the status output that found the first, and the
client at `clients/node` with
`apps/loopex_app_server/test/external_workflow_test.exs` asserting what it
observed over the wire. The maintainer answered **"accept ce23031 proposal A"**.

That revision no longer exists. A third fault came to light while this one was
being repaired: the closed M1 gate binds the dependency oracle, and M4 Phase B
rewrote it without M1's own transaction, leaving every revision from that work to
the branch tip naming a digest no authority accepted. Repairing it meant
restructuring the two Phase B revisions beneath this proposal, which moved every
later identity. The content did not move: this proposal's Concept, Technical depth
and gate digests are byte-identical to the ones accepted at the discarded
identity. Presented with that, the maintainer answered **"62ad818 accepted"**.

This transcribes that answer as acceptance under `amendment-transaction-v1`. The
rebind binds the Acceptance row to exact
`62ad8188a658fb739d2144ac1a982beb44953708` with both amended envelope digests
and the amended gate digest. It changes no lifecycle state, outcome count, gate
selector, witness, limit, client pin, bound artifact or evidence class, and
grants no closure, integration, tag or release.

<a id="disposition-m4-drop-python-client-2026-09-15"></a>
### M4 drops the Python conformance client — 2026-09-15

The maintainer asked what Python was being used for. The answer had two halves
that pull against each other. Python was a seed and M0 bridge dependency and was
removed: repository checks run on Elixir and Mix entrypoints, and the closed M0
gate holds that boundary actively, shadowing every interpreter name it can reach
and scanning every tracked byte for an invocation shape that could slip past
those stubs. But accepted M4's outcome 6 committed to Elixir, Python and
TypeScript clients executing the same conformance vectors, and the M4 gate
pinned a Python interpreter to run one of them. A client lane requiring that
interpreter reopened exactly the hole the M0 scan exists to close.

The implementer reported the tension rather than leaving it, and noted that two
independent implementations already prove the wire contract is bytes rather than
an Elixir interface, so a third adds breadth rather than proof. The maintainer
answered **"yes, drop python from outcome 6, we can introduce additional clients
later in m6, m7 etc.. based on vision and roadmap"**, and then, of the change
itself, **"go do the change. this is my acceptance of the change."**

The revision that first carried it, `fdaa8d8a43ba8f2161e69d383ec118806b667ccf`,
was invalid in three ways nobody saw until the status walk ran the next day. It
headed a gate section "Amendment 3" without the anchor that declares one, so the
gate stayed at the generation Amendment 2 had set and the envelope change read
as a silent edit. It recorded the three new artifact digests only inside that
section, leaving the authoritative Bound Artifacts table still naming the bytes
it had just replaced. And it left the gate's own text naming a Python client and
a plural set of pinned interpreters, so outcome 6's locked obligation still
demanded evidence the amended envelopes said would not exist. The maintainer
chose to rewrite that lineage rather than override the rule that caught it.

The rewritten proposal is `72a8d3f2efdc5490ddd87e40a8192f20ba6564d6`. Its
Concept envelope digest is byte-identical to the one the discarded revision
recorded, so the accepted change itself is unaltered; what moves is the anchor,
the Bound Artifacts rows and the four cleared sentences. Presented with that,
the maintainer answered **"accept 2800eaf"**.

That revision no longer exists either, and for the same reason as its
predecessor: repairing the closed M1 gate's bound dependency oracle, which M4's
Phase B had rewritten without M1's own transaction, moved every identity after
it. The content is unchanged and its three digests are byte-identical to the
ones accepted at the discarded identity. Presented with that, the maintainer
answered **"accept 72a8d3f"**.

Both envelopes move together, because the pair is one authority unit. Outcome 6
now names Elixir and Node clients. Three bound artifacts change and no fourth:
the pin file loses its `python=` line, the runner loses the Python verification
and the `python_pin` field it printed, and the support script's report grammar
loses that field's rule. The gate's own report grammar loses it too, its Bound
Artifacts rows move to the new digests, and the gate's Amendment 4 records the
same rebinding under its generation. Amendment 2's text still
describes renaming a Python pin field and stays exactly as written, because it
records what was true when it was accepted.

This transcribes that answer as acceptance under `amendment-transaction-v1`. The
rebind binds the Acceptance row to exact
`72a8d3f2efdc5490ddd87e40a8192f20ba6564d6` with both amended envelope digests
and the amended gate digest. It adds no outcome, removes none, changes no
selector, witness, limit or evidence class beyond outcome 6's client list,
reopens no lifecycle state, and grants no closure, integration, tag or release.

<a id="disposition-m4-gate-runnable-2026-09-15"></a>
### M4 gate amendment acceptance, making the gate runnable — 2026-09-15

The maintainer asked for the gate to be run, and for problems to be caught
before they cost a full lane. Running it found that the gate could not run at
all, in any role that compiles, and that every cause was one of its own bound
artifacts left behind by a change M4 itself had accepted.

The isolated compile lane builds core and the local Store under an isolated home,
Hex home and Mix home with `HEX_OFFLINE=1`. An empty Mix home holds no Hex
archive, so Mix could not resolve what kind of dependency `:telemetry` is. Every
earlier milestone passed the lane because core declared no external dependency;
Phase B admits the one the dependency doctrine names. The runner already copies
the operator's Hex archive and per-Elixir Rebar into that isolated home and
validates the copied tree against the protected-file inventory, but only on the
full path, after the compile. The call moves to just after the isolated
directories exist.

The opening probe then failed four times in succession, each for its own reason.
It composed a runtime with a policy and no policy identity, which the maintainer
made a requirement on 2026-09-15, so the runtime refused the launch. Its
hand-built code path omitted the telemetry beams, so the first span crashed the
runtime control process; the same fault had been repaired for the CLI probe path
and never carried here. Its deferred question used the string `"choice"` where
accepted ADR 0024 fixes the atom and converts nothing, so the runtime denied it
as `policy_unavailable` rather than as the declared red. And its pending-question
predicate read a list called `pending_interactions` with atom keys and a
`turn_id`, which the implementation never published: session status carries one
`open_interaction` with string keys and a `turn`. That last was diagnosed by
running an instrumented copy of the probe against a real build and reading the
actual status map and durable record, not by guessing.

Two bound artifacts change: `scripts/check-m4-gate.sh` and
`scripts/m4-opening-probe.exs`. No outcome, selector, witness identity, limit,
client pin, evidence class, credential rule or lane changes, neither envelope
moves, and no lifecycle state reopens. What the opening witness asserts is what
it asserted before: exactly one question, unsettled, after exactly one model
call, carrying the same identity, run and tool call as its durable record.

Evidence presented at the proposal: `--inspect` passing, and `--preflight`
reporting `M4 opening GREEN: policy defer commits a pending interaction and
suspends the run` with `defer_interaction_records=1` and `defer_settled=false`.
The maintainer answered **"Accept f8b0511"**.

This transcribes that answer as acceptance under `amendment-transaction-v1`. The
rebind binds the Acceptance row to exact
`f8b0511774e4a6d9bcc00867f5b3357e084290c5` with the amended gate digest and both
envelope digests unchanged, since neither envelope moved. It grants no closure,
integration, tag or release.

<a id="disposition-m4-witness-identities-2026-09-15"></a>
### M4 gate amendment acceptance, the witness identities — 2026-09-15

Amendment 3 renamed outcome 5's consumer from TypeScript to Node and listed
seven places it had done so. Amendment 4 dropped Python from outcome 6. Neither
reached `scripts/m4-outcomes.exs`, the bound artifact holding the locked witness
identities the selector runner matches by exact string. Two of outcome 5's still
named a TypeScript consumer and outcome 6's first still named Elixir, Python and
TypeScript clients.

Both omissions were found the same way: by writing the tests those identities
name. Satisfying the lock verbatim would have produced a case called "the
TypeScript consumer completes skill answer reevaluation..." exercising a plain
JavaScript client with no build step, and another promising a Python client this
milestone had decided not to have. A milestone's evidence cannot quietly
disagree with its own accepted decisions, and witness identities are locked at
acceptance, so correcting them is an amendment rather than an edit.

The general lesson is recorded in the amendment itself rather than left implicit:
a rename must reach the file that names the evidence, not only the documents that
describe it. Two amendments made the same mistake in the same file.

Three strings change and no others. The proposal is
`2e06da13ee01391690c1731edbf6190ab4471f1c`. No outcome, selector path, count,
limit, client pin, evidence class or credential rule changes, neither envelope
moves, and no lifecycle state reopens. Evidence presented: the two stale strings
in outcome 5 and the one in outcome 6, each quoted against the decision that
superseded it. The maintainer answered **"Accept 2e06da1"**.

This transcribes that answer as acceptance under `amendment-transaction-v1`. The
rebind binds the Acceptance row to exact
`2e06da13ee01391690c1731edbf6190ab4471f1c` with the amended gate digest and both
envelope digests unchanged, since neither envelope moved. It grants no closure,
integration, tag or release.
<a id="disposition-m4-witness-name-length-2026-09-15"></a>
### M4 gate amendment acceptance, an oversized witness identity — 2026-09-15

One of outcome 7's locked witness identities could not be satisfied by any
test. The identity is 300 bytes, which ExUnit registers as the atom `test `
followed by that name: 305 bytes. Atoms are capped at 255, so the name that file
registers is truncated in the middle and given a short hash, and the selector
runner compares locked identities to reported names exactly. The lane refused
with `a locked test did not appear` while all ten of that file's cases passed.
A locked name no test can carry is an unsatisfiable lock, and it would have
blocked this gate however the implementation went.

Amendment 7 shortens the identity to 196 bytes and renames the case to match.
The claim is unchanged: what a sender killed at each crash cut holds afterwards,
that a concurrent sender's slot stays live and admits, and that a release frees
only the claim it names. What leaves the name is the enumeration of the four
cuts, which the test body drives and asserts rather than describes. The other 66
locked identities are unaffected; the next longest is 161 bytes.

The proposal is `18100cafaefd3b6f3fbb73757b590287908738c7`. Two earlier proposals of the same three-byte-identical
change, `cb01f63` and `c5c9fc3`, were accepted and then replaced: the first to
act on review findings, the second because the history beneath it was rewritten.
That rewrite repaired a separate defect this amendment did not cause — M4
Amendment 6's rebind did not directly follow its proposal, four commits having
intervened, and a Markdown link wrapped across two lines in `AGENTS.md` had been
crashing the document checker before it could report that. Neither SHA survives;
this disposition names only the proposal that does.

No outcome, selector path, count, limit, client pin, evidence class or credential
rule changes, neither envelope moves, and no lifecycle state reopens. Evidence
presented: the truncated atom the runner reports against the locked string, the
byte counts for the oversized identity and the next longest, an independent
exact-SHA review recording no blocking or high findings, the amended gate's own
selector passing at the proposal, and binding validation failing there on the
stale gate binding alone. The maintainer answered **"Accept 18100ca"**.

This transcribes that answer as acceptance under `amendment-transaction-v1`. The
rebind binds the Acceptance row to exact `18100cafaefd3b6f3fbb73757b590287908738c7` with the amended gate digest and
both envelope digests unchanged, since neither envelope moved. It grants no
closure, integration, tag or release.


<a id="override-disposition-closed-gate-repair-chain-2026-09-17"></a>
### Closed-gate repair and instrumentation chain, 2026-09-17

Found while re-capturing M2's toolchain evidence at
`afb80ec94a3062099062ff132009af1613793cce`: two accepted M4 changes broke the
closed M2 and M3 gates. Requiring a named policy identity
(`51a989c09d120aba095f388fea89d9aa2598a48b`, accepted ADR 0024) makes the
opening probe of each gate fail to start a runtime, because both probes set a
policy and name no identity. Telemetry in core (accepted ADR 0030) is missing
from the code path the M3 runner gives its probe, so that probe also fails once
it names an identity. With both repaired in scratch copies, the M2 probe
reports its working loop and the M3 probe its observation. Both probes are
digest-bound, and the maintainer had already directed that every closed-gate
runner gain step, elapsed-time and streaming instrumentation.

The maintainer received both findings as one decision and selected
**"Fold into instrumentation, one chain (Recommended)"**, whose full text was:

> Four generations, in order: M0 (instrument), M1 gen 17 (instrument), M2 gen 13 (probe identity + instrument), M3 (probe identity + telemetry path + instrument runner and check-closed-gates). Then the M2 re-capture, then closed gates, which should be green. Each rebind in the chain still has some closed gate red until the chain finishes, so one standalone override disposition up front replaces the green-at-rebind condition at those four rebinds with one closed-gates green run at the end. Cost: 1 override review + 4 acceptances. Each runner is edited once, and the captures run on instrumented runners.

Under [the explicit maintainer override](../../AGENTS.md#maintainer-override),
this names the requirement it replaces. At a generation's rebind, binding
validation, bootstrap and every inherited required gate must pass. For the
four rebinds of this chain only — M0 gate generation 8, M1 gate generation 17,
M2 gate generation 13 and M3 gate generation 5, taken in that order — the
component "every inherited required gate must pass" is replaced by the
evidence named below. At each of those rebinds some closed gate is known to
be red for a cause the chain itself removes: the M2 and M3 probes until their
own generations land, and M2's retained matrix until its post-closure
re-capture exists, which can only be taken on the repaired runner.
Binding validation and bootstrap at each of those rebinds are not replaced
and must pass there. Every other requirement of each generation's
`amendment-transaction-v2` transaction stands: its own proposal, its own
exact-SHA review, the maintainer's acceptance of that exact proposal, and a
rebind that is the proposal's immediate child.

`scripts/check-closed-gates.sh` is bound by both the M3 and the M4 gate. The
M3 generation rebinds it first; the M4 gate's rebind of the same bytes follows
in M4's own next amendment, in sequence, and until that amendment settles no
M4 revision is a closure candidate.

**Replacement evidence.** One run of
`bash scripts/check-closed-gates.sh --before M4` with the provider frame on
standard input, green for M0, M1, M2 and M3, on the instrumented runners, at the
evidence-only commit that retains M2's post-closure re-capture after the
chain, retained with the exact revision it ran at. Until such a run is
retained, the replaced requirement stands unmet for all four rebinds and this
disposition is not satisfied; when it is retained it is recorded on its own,
never by editing this record.

Preserved: every closed milestone's Acceptance, Closure and existing generation
rows, which stay byte-immutable and true for the revisions they name; ADR 0024's
required policy identity and ADR 0030's telemetry, which the runtime keeps; and
every other requirement at every other rebind. This grants no further
exception, no ADR change, no closure, no integration to `main`, no tag and no
release.

Before dependent work, independently review this standalone disposition at
its exact SHA. This record is not edited after that review.

<a id="override-disposition-closed-gate-repair-chain-v2-2026-09-17"></a>
### Closed-gate repair and instrumentation chain, corrected, 2026-09-17

This record supersedes
[the first record of this chain](#override-disposition-closed-gate-repair-chain-2026-09-17),
which its exact-SHA review rejected and which no transition may cite. That
review found one requirement the first record kept that cannot be met: the M3
generation rebinds `scripts/check-closed-gates.sh`, which the M4 gate also
binds, so from that proposal until M4's own rebind of the same bytes the
repository status check stops at `unfinished shared binding sequence`.
Bootstrap runs that check, and so does every closed gate that runs bootstrap,
so none of them can pass at the M3 rebind. The review also found that the
first record waived the M0 and M1 gates at rebinds where nothing makes them
red. The facts the first record states about the breakage were each confirmed
by that review and are not repeated here.

The maintainer's decision is unchanged: the answer
**"Fold into instrumentation, one chain (Recommended)"**, recorded in full in
the first record. This record carries out that decision in an order the
repository's shared-holder rule can meet, keeping the runner repairs, the
instrumentation, one override and the captures on repaired runners.

**Order.** M0 gate generation 8; M1 gate generation 17; M2 gate generation 13;
the M2 post-closure re-capture, taken at M2 generation 13's rebind with its
evidence-only child after it; M3 gate generation 5; then the M4 gate's next
amendment, which rebinds the M4 holder of `scripts/check-closed-gates.sh` and
so completes that shared sequence. Each is its own transaction with its own
proposal, its own exact-SHA review, the maintainer's acceptance of that exact
proposal, and a rebind that is the proposal's immediate child.

Under [the explicit maintainer override](../../AGENTS.md#maintainer-override),
this names the requirement it replaces: at a rebind, every inherited required
gate must pass. It is replaced only as follows.

- At the rebinds of M0 generation 8, M1 generation 17 and M2 generation 13,
  the M2 and M3 gates are not required to pass. The M2 gate is red until its
  re-capture exists and the M3 gate until its probe is repaired. The M0 and M1
  gates must pass at each of these three rebinds, and binding validation and
  bootstrap must pass there.
- At the M3 generation 5 rebind no closed gate is required to pass. Binding
  validation there is holder-scoped: it proves the M3 holder's own bindings
  and names the M4 gate as the pending holder of
  `scripts/check-closed-gates.sh`. Bootstrap and global status are not
  reported green there. That is the repository's rule for an unfinished
  shared sequence, which the M4 gate's own ordered steps restate. Bootstrap's
  other checks must pass there: agent bootstrap, gitignore, commit messages
  and repository hygiene.
- At the rebind of the M4 amendment that completes the sequence, nothing is
  replaced.

**Replacement evidence.** One run of
`bash scripts/check-closed-gates.sh --before M4` with the provider frame on
standard input, green for M0, M1, M2 and M3 on the instrumented runners, at the
rebind of the M4 amendment that completes the shared sequence, retained with
the exact revision it ran at. Until such a run is retained, the replaced
requirement stands unmet for every rebind named above, and this disposition is
not satisfied. When the run is retained it is recorded on its own, never by
editing this record.

Preserved: every closed milestone's Acceptance, Closure and existing generation
rows, which stay byte-immutable and true for the revisions they name; ADR
0024's required policy identity and ADR 0030's telemetry, which the runtime
keeps; the shared-holder rule that no revision is a closure candidate until
every holder is rebound; and every other requirement at every other rebind.
This grants no further exception, no ADR change, no closure, no integration to
`main`, no tag and no release.

Before dependent work, independently review this standalone disposition at
its exact SHA. This record is not edited after that review.

<a id="disposition-m0-gate-generation-8-2026-09-17"></a>
### M0 gate generation 8 acceptance — 2026-09-17

Generation 8 is the first transaction of
[the closed-gate repair and instrumentation chain](#override-disposition-closed-gate-repair-chain-v2-2026-09-17).
It makes `scripts/check-m0-gate.sh` print each step and protected selector
with its elapsed seconds on standard error, with a heartbeat every 30 seconds,
and states a 60-second silence bound in the runner's header. Nothing the gate
checks, prints on standard output or reports on failure changes.

A first proposal, `85025dd98e74ca235c8424ebdbdbc8af5a934961`, passed its
exact-SHA review with two medium findings: its heartbeat could outlive a
killed gate and hold standard error open for up to 30 seconds after a normal
exit, and one sentence of its amendment misstated the search-path scan's
exclusions. Presented with that, the maintainer chose to replace it before
acceptance, and it was removed from the branch unaccepted. The replacement,
`408b8de48d468a86228348d699af81fd7438a266`, checks every second that the gate
is alive and corrects the sentence. Evidence at that exact revision: the status
check red only on the pending generation; a gate run with the provider
credential that streamed its steps and 90 heartbeat lines, passed the
real-provider lane, and stopped in the bootstrap step on the pending generation;
its standard error closed within one second of its last line; no credential
bytes in either stream. Its exact-SHA review accepted it with two low findings
recorded for later work: a gate process left unreaped by a non-shell caller
still looks alive to the heartbeat, and the evidence paragraph does not say
that the M1 gate, which also runs bootstrap, is red at the proposal as well.

Presented with that proposal, its evidence and its review, the maintainer
answered **"Accept 408b8de (Recommended)"**.

This transcribes that answer as acceptance under `amendment-transaction-v2`.
The rebind completes generation 8's row with the accepting authority, this
disposition and the candidate it binds, which is exact
`408b8de48d468a86228348d699af81fd7438a266`. At this rebind binding
validation, bootstrap and the M0 and M1 gates must pass; the M2 and M3 gates
are covered by the chain disposition. The Acceptance and Closure rows of Closed
M0 stay byte-immutable, no earlier generation stops being enforced for the
revisions it governed, and this adds no scope, changes no outcome and reopens
no lifecycle state. It grants no closure, integration, tag or release.

<a id="disposition-m1-gate-generation-17-2026-09-17"></a>
### M1 gate generation 17 acceptance — 2026-09-17

Generation 17 is the second transaction of
[the closed-gate repair and instrumentation chain](#override-disposition-closed-gate-repair-chain-v2-2026-09-17).
A capture run of the M1 gate took between 92 and 139 minutes and printed
nothing until it exited, because its outer launch proves the whole sealed
stream free of credential and NUL bytes before printing any of it.

That guarantee is kept. The sealed stream now passes through `tee`: every byte
still reaches the same capture unchanged, and a copy reaches a reader that
prints only this runner's own `M1 progress:` lines, and only lines free of
credential bytes, to the operator's standard error as they arrive. The inner
runner names each step and each protected selector with its elapsed seconds and
adds a heartbeat every 30 seconds once its isolated task root exists; the
heartbeat checks every second that the gate is alive and is stopped by that
root's EXIT trap. Progress never passes through the OTP launcher's
standard-output relay, so that relay's one-hour silence limit still bounds a
hung gate. No command, selector, minimum, exclusion policy, embedded literal,
credential rule, preflight output or failure message changes.

Evidence at `6766209a0916cb7122e8905eb75b7ccd9c0fe0e9`: the status check red
only on the pending generation; a gate run with the provider frame that printed
212 progress lines as it went — steps with their elapsed seconds and 30-second
heartbeats — and stopped at the repository status check on that same pending
generation, with its standard error closing at its last line and no credential
bytes in either stream; and the M1 evidence, gate isolation and M3 gate support
suites passing together, 32 cases. Its exact-SHA review accepted it, having
verified that every byte still reaches the capture unchanged, that the relay
prints only gate-authored key-free lines, and that the launcher's silence limit
is untouched. Three low findings stand unrepaired: a child line beginning with
the progress prefix would be relayed as progress, a heartbeat line can interleave
with a large block of output, and a stalled or closed consumer of standard error
now blocks the gate or fails it with a malformed-status result.

Presented with that proposal, its evidence and its review, the maintainer
answered **"Accept 6766209 (Recommended)"**.

This transcribes that answer as acceptance under `amendment-transaction-v2`.
The rebind completes generation 17's row with the accepting authority, this
disposition and the candidate it binds, which is exact
`6766209a0916cb7122e8905eb75b7ccd9c0fe0e9`. At this rebind binding validation,
bootstrap and the M0 and M1 gates must pass; the M2 and M3 gates are covered by
the chain disposition. The Acceptance and Closure rows of Closed M1 stay
byte-immutable, no earlier generation stops being enforced for the revisions it
governed, and this adds no scope, changes no outcome and reopens no lifecycle
state. It grants no closure, integration, tag or release.

<a id="disposition-m2-gate-generation-13-2026-09-18"></a>
### M2 gate generation 13 acceptance — 2026-09-18

Generation 13 is the third transaction of
[the closed-gate repair and instrumentation chain](#override-disposition-closed-gate-repair-chain-v2-2026-09-17).
Accepted ADR 0024 makes policy selection a launch argument carrying a bounded
identity, and the runtime refuses a launch that sets a policy without one. The
M2 gate's opening probe set a policy and named no identity, so the gate stopped
at its opening condition before observing anything.

The probe now names the fixed identity `loopex-m2-probe` at revision `1`, which
the runtime ignores for the launch shapes that set no policy; nothing the probe
observes or reports changes. The runner also prints a progress line on standard
error when each section, locked command and protected selector begins and ends,
with its own and the run's elapsed seconds, and a heartbeat every 30 seconds
from the start of the run that checks every second that the gate is alive and
is stopped at exit. Once the provider credential has been read, a step line that
would contain it is left out rather than printed; heartbeat lines carry only
fixed text and elapsed seconds. No command, selector, minimum, exclusion policy,
credential rule, evidence check, standard-output line or failure message
changes.

The first proposal, `367c69574a37ea2e115a46094adb833bfe0d4302`, claimed that
every progress line passes the same credential check as other gate-owned lines.
Its exact-SHA review found that untrue, and the maintainer answered
**"Replace with corrected A' (Recommended)"**. It was replaced by a sibling
proposal with the same parent whose text says what the runner does, and which
changes no executable line of the runner; the first proposal is not part of the
integrated history.

Evidence at `f816f99b96647a67a437df946f908d4e079dd789`: the status check red
only on the pending generation; a gate run with the provider frame whose
opening behavioural probe passed in 34 seconds, which it could not do at the
previous generation, and which then stopped at the locked repository status
command on that same pending generation, printing its steps and 16 heartbeats
with no silence longer than 31 seconds and no credential bytes in either
stream; and the gate isolation tests passing, 8 cases. Its exact-SHA review
accepted it with one low finding carried from M0 generation 8: after the gate
is killed and before it is reaped, the heartbeat's liveness check still
succeeds, so a caller that reads the gate's output to its end before reaping it
waits on the heartbeat.

Presented with that proposal, its evidence and its review, the maintainer
answered **"Accept f816f99 (Recommended)"**.

This transcribes that answer as acceptance under `amendment-transaction-v2`.
The rebind completes generation 13's row with the accepting authority, this
disposition and the candidate it binds, which is exact
`f816f99b96647a67a437df946f908d4e079dd789`. At this rebind binding validation,
bootstrap and the M0 and M1 gates must pass; the M2 and M3 gates are covered by
the chain disposition, and the M2 post-closure re-capture is taken here. The
Acceptance and Closure rows of Closed M2 stay byte-immutable, no earlier
generation stops being enforced for the revisions it governed, and this adds no
scope, changes no outcome and reopens no lifecycle state. It grants no closure,
integration, tag or release.

<a id="override-disposition-m2-recapture-candidate-2026-09-18"></a>
### M2 re-capture candidate after an order-dependent test, 2026-09-18

[The corrected closed-gate chain](#override-disposition-closed-gate-repair-chain-v2-2026-09-17)
places the M2 post-closure re-capture at M2 gate generation 13's rebind, with its
evidence-only child after it. Under
[the explicit maintainer override](../../AGENTS.md#maintainer-override), this
record replaces only that placement.

The re-capture was taken at that rebind,
`4751a6dfcda8212844bc07631b607378f16ac284`. Four of its six lanes passed:
linux-current and darwin-current captured, and the M0 floor and M1 current gates
were green. Two were red. The darwin-floor lane failed
`opening an absent artifact root durably publishes every new directory component`
in `apps/loopex_store_local/test/artifact_store_conformance_test.exs`. That test
expects exactly three directory syncs, which holds only while `LOOPEX_HOME`
already exists; the gate's selector runner does not create it, so the result
depended on whether an earlier test in the seed's order had. With `LOOPEX_HOME`
absent the test fails for that lane's seed and passes for the other lanes' seeds,
on either toolchain pair. The product then makes four syncs, one reconfirming
the nearest existing directory and one after each of the three directories it
creates, which is the durable behaviour the test names. The M0 current lane
failed once in its full suite, in
`apps/loopex_composition/test/skill_acquisition_test.exs`, with the refusal
`{:git_identity_mismatch, "exported Git blob did not match"}`. That refusal
comes from the blob export in `apps/loopex_composition/lib/resource_packs.ex`,
where it reports two different checks, the name of the file Git wrote and the
bytes read from it, with one message. It did not recur in 53 attempts under
the same `HOME` relocation, sequential and under parallel load. Neither failure
depends on the environment the lanes were launched from: both tests pass in
isolation with and without it.

A test known to depend on ordering cannot be carried to a green lane by drawing
another seed. The maintainer answered
**"Fix, split the error, retake at C (Recommended)"**. A first record of this
decision, `4eebaeace8b6bfc58a19a21920cfeac886428a2d`, did not quote the observed
refusal, described C without its paths and miscounted the syncs; its review
found those faults, the maintainer answered
**"Replace with a corrected D' (Recommended)"**, and this record replaces it.
That first record is not part of the integrated history.

**Replacement.** The M2 post-closure re-capture is taken instead at candidate C,
the immediate child of this record. C changes exactly two paths and no other:
`apps/loopex_store_local/test/artifact_store_conformance_test.exs`, where the
test creates `LOOPEX_HOME` as its stated precondition under its unchanged name,
and `apps/loopex_composition/lib/resource_packs.ex`, where the blob export's
identity refusal names which of its two checks failed with the observed sizes,
keeping its `git_identity_mismatch` reason. No gate binds either path's bytes,
so C needs no gate generation. All six lanes are taken at C, and the
evidence-only child that records them is C's immediate child. Nothing taken at
the rebind is carried into that record. If the Git identity failure recurs at C,
its split refusal is reported with the lanes; if it does not, that single
unreproduced failure is dispositioned on its own before the record is accepted.

Preserved: M2 gate generation 13 and its rebind, which remain accepted and
settled; the chain's order after the re-capture, its holder-scoped rule at the
M3 generation 5 rebind, and its replacement evidence; every closed milestone's
Acceptance, Closure and generation rows; and every other requirement. This
grants no further exception, no closure, no integration to `main`, no tag and
no release.

Before dependent work, independently review this standalone disposition at its
exact SHA. This record is not edited after that review.

<a id="disposition-m2-recapture-git-identity-2026-09-18"></a>
### One unreproduced Git identity refusal at the M2 re-capture, 2026-09-18

[The M2 re-capture disposition](#override-disposition-m2-recapture-candidate-2026-09-18)
requires this failure to be dispositioned on its own before the re-capture is
relied on. This records that disposition; it replaces no requirement.

At `4751a6dfcda8212844bc07631b607378f16ac284` the M0 gate's full suite, run on the
current pair on the macOS lane host, failed once in
`apps/loopex_composition/test/skill_acquisition_test.exs` with
`{:git_identity_mismatch, "exported Git blob did not match"}`. The M0 gate on the
floor pair at that revision, on the same host, passed. The failure did not recur:

- in 53 targeted attempts: 38 under the M0 gate's relocation of `HOME`, 20 of
  them sequential and 18 as six concurrent runs, and 15 without it, 10 of the
  test alone and 5 of its application's whole suite;
- in the M0 floor and M0 current lanes at candidate
  `d4d6699c327d866a115b6895c3ccb5413fe5c017`, both green.

Ruled out: the environment and resource limits of the process that launched the
lanes, since the test passes in isolation with and without them; the Git binary
and its configuration, which were the same `/usr/bin/git` in both lanes; the
name of the temporary file Git writes, which matched the expected pattern in
3,000 attempts on the same host; and the killed-process lines printed near the
failure, which come from a different test that kills process groups on purpose.

The refusal covered two checks with one message. Candidate
`d4d6699c327d866a115b6895c3ccb5413fe5c017` makes each check name itself with the
sizes it observed, so a recurrence reports its cause.

The maintainer answered **"Record as unreproduced, now diagnosable
(Recommended)"**. This is recorded as one unreproduced failure. It waives
nothing: any recurrence of this refusal, on any lane, is a new finding that
blocks the run it occurs in until its reported cause is fixed or dispositioned.
It grants no exception, no closure, no integration, tag or release.

<a id="disposition-m3-gate-generation-5-2026-09-18"></a>
### M3 gate generation 5 acceptance — 2026-09-18

Generation 5 is the fourth transaction of
[the closed-gate repair and instrumentation chain](#override-disposition-closed-gate-repair-chain-v2-2026-09-17).
Three defects each stopped the M3 gate before it observed anything. The opening
probe set a policy and named no identity, which accepted ADR 0024 requires. The
runner left the telemetry dispatcher, which accepted ADR 0030 admits into core,
off the probe's code path. And the sealed opening build had no Hex archive, so
Mix could not resolve that dispatcher at all.

The probe now names the fixed identity `loopex-m3-probe` at revision `1`, the
runner puts `telemetry` on the probe's code path, and the runner's existing
validated preparation of the sealed home now runs once, before the opening
build, instead of only before the later test build. The runner also prints a
progress line at each step and a heartbeat every 30 seconds, passes the
inherited lane's output through as it runs, and states its silence bound of 60
seconds in its header; `scripts/check-closed-gates.sh` prints each gate's
elapsed seconds when it ends. No command, selector, minimum, witness identity,
exclusion, provider path, credential contract, exit predicate or report line
changes.

The first proposal, `357c36be93c4705415d62c899592367ec879bbb2`, repaired the
missing Hex archive with a copy of its own. Its exact-SHA review found that the
copy could report a successful copy as red and bypassed the checks the existing
preparation applies to what it copies, and the maintainer answered
**"Replace with corrected A' (Recommended)"**. It was replaced by a sibling
proposal with the same parent that moves the existing preparation instead of
adding a copy; the first proposal is not part of the integrated history.

Evidence at `e79ba2c5bb1bfe691dcb81e5cff53fc49df3ff76`, on macOS: the status
check red only with `unfinished shared binding sequence`, because the M4 gate
also binds `scripts/check-closed-gates.sh` and has not yet taken its own
transaction. A gate run with the provider frame in which the opening build,
the opening probe, the isolated test build, all eight protected selectors and
the four locked Mix commands exited 0, the probe reporting its observation
where at the previous generation it could not start a runtime; the gate then
stopped at bootstrap, whose four structural checks and 88-case adversarial
status suite passed, on that same shared binding sequence. The run printed 57
heartbeats, no silence exceeded 31 seconds, and neither stream carried
credential bytes. The same runner bytes passed every M3 lane on Linux. Its
exact-SHA review accepted it, finding every issue raised against the first
proposal resolved.

Presented with that proposal, its evidence and its review, the maintainer
answered **"Accept e79ba2c (Recommended)"**.

This transcribes that answer as acceptance under `amendment-transaction-v2`.
The rebind completes generation 5's row with the accepting authority, this
disposition and the candidate it binds, which is exact
`e79ba2c5bb1bfe691dcb81e5cff53fc49df3ff76`. Binding validation at this rebind
is judged over M3's own bindings: the M4 gate's binding of
`scripts/check-closed-gates.sh` is stale until its own next amendment rebinds
it, and until then bootstrap, the repository status check and the gates that
run them are not reported green and no such rebind is a closure candidate. As
the chain disposition orders, no closed gate is required to pass at this
rebind, and bootstrap's agent bootstrap, gitignore, commit message and
repository hygiene checks must pass here. The Acceptance and Closure rows of
Closed M3 stay byte-immutable, no earlier generation stops being enforced for
the revisions it governed, and this adds no scope, changes no outcome and
reopens no lifecycle state. It grants no closure, integration, tag or release.
