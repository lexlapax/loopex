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
| Stack, dependency budget, runtime floor | [Dependency doctrine](../vision.md#concept-vision-dependency-doctrine) and [ADR 0002 decision](../adr/0002-bootstrap-runtime-floor.md#concept-adr-0002-decision) | [Exact dependency constraints](../vision-technical.md#technical-vision-dependency-doctrine) and [ADR 0002 mechanics](../adr/0002-bootstrap-runtime-floor-technical.md#technical-adr-0002-decision) | Protocol/Core/Runtime, stdlib+OTP-only core, bootstrap floor. |
| Runtime instances, supervision, reducer | [Runtime ownership](../vision.md#concept-vision-runtime-supervision) | [Supervision and reducer mechanics](../vision-technical.md#technical-vision-runtime-supervision) | Multi-instance supervision, pure reducer, bounded journal transaction. |
| Transactions, operations, recovery, cancellation | [Recovery truth](../vision.md#concept-vision-recovery-truth) | [Transaction and recovery mechanics](../vision-technical.md#technical-vision-recovery-truth) | `commit_unknown`, operation lifecycle, reconciliation, outcome algebra. |
| Agent loop, queues, tool ordering | [Loop semantics](../vision.md#concept-vision-loop-semantics) | [Loop mechanics](../vision-technical.md#technical-vision-loop-semantics) | One run per session, input classes, ordering, and split payloads. |
| Public protocol, events, attachments | [Public protocol](../vision.md#concept-vision-public-protocol) | [Protocol mechanics](../vision-technical.md#technical-vision-public-protocol) | Stream planes, envelopes, attach behavior, and authority boundaries. |
| Journal, stores, branches, compaction, artifacts | [Sessions and storage](../vision.md#concept-vision-sessions-storage) | [Storage mechanics](../vision-technical.md#technical-vision-sessions-storage) | Recovery surfaces, private adapters, store decision, protection. |
| Model boundary and continuation | [Model boundary](../vision.md#concept-vision-model-boundary) | [Model mechanics](../vision-technical.md#technical-vision-model-boundary) | Canonical types, `Loopex.LLM`, reference adapter, native sidecar. |
| Context pipeline | [Model boundary](../vision.md#concept-vision-model-boundary) | [Context-pipeline mechanics](../vision-technical.md#technical-vision-model-boundary) | The sole seam for memory, retrieval, prompts, provenance, and receipts. |
| Tools and coding surface | [Tools](../vision.md#concept-vision-tools) | [Tool mechanics](../vision-technical.md#technical-vision-tools) | Seven-tool surface, budget, and non-authority of metadata. |
| Executors, brain/hand, distribution | [Executor protocol](../vision.md#concept-vision-executor-protocol) | [Executor mechanics](../vision-technical.md#technical-vision-executor-protocol) | Job/receipt protocol, trust classes, trusted gateways. |
| Trust, resources, sensitive data | [Sensitive data](../vision.md#concept-vision-sensitive-data) | [Trust mechanics](../vision-technical.md#technical-vision-sensitive-data) | Resource admission, tenancy, credentials, and redaction. |
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

No Mix project exists yet, so there is no product test command. Until the first
accepted gate locks one, `bash scripts/check-bootstrap.sh` is the whole suite.

When product tests arrive they run against a temporary `LOOPEX_HOME`; the
affected conformance suites (`conformance/`) run for any adapter or behaviour
change; property tests own reducer/replay claims; fault injection owns
durable-transition claims. Real-provider runs are a tagged, explicitly invoked
lane — never part of the default suite.

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
  implicit, and two of those eight items change what the repository can detect or
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
  Required inspection checks must also execute in that environment: during the
  bridge period, Python assertions live in tracked scripts rather than shell
  here-documents that need ambient temporary writes.
- For development-client ecosystem changes, check current primary vendor docs
  or release notes plus installed behavior, derive shared consequences first,
  and retain version-specific facts here. Material changes
  to development behavior require an option-and-implication packet and
  maintainer approval before adapter edits.
- Maintainer decision (2026-08-15): development work uses the model-neutral
  efficient, balanced, and deep capability classes in the
  [development charter](development-charter.md#concept-capability-follows-consequence)
  and its [technical routing](development-charter-technical.md#technical-capability-follows-consequence).
  Current recommended mappings are Codex Luna/medium for efficient work,
  Terra/high for balanced work, and Sol/high for deep work; Claude Haiku/medium,
  Sonnet/high, and Opus/high respectively. A separately verified deeper setting
  is reserved for unusually demanding work whose evidence justifies the extra
  cost. These are
  dated adapter recommendations, not project authority or repository model
  pins. Profiles inherit the caller's model; the caller selects and verifies the
  current mapping before invocation. Class labels and structural checks are
  routing metadata, not capability proof. Use a separate direct invocation when
  named-role delegation is unavailable. A stronger profile may perform
  lower-class work, while missing required deep capability or effective
  read-only review is unavailable evidence. Task-shaped smoke evidence records
  the effective model and effort when observable. Primary references checked
  for this mapping are
  [OpenAI's model guidance](https://developers.openai.com/api/docs/models) and
  [Claude Code model configuration](https://code.claude.com/docs/en/model-config).
  Recheck primary documentation, installed catalogs, representative task
  behavior, and smoke evidence when a client version, model family, catalog,
  profile, or relevant adapter byte changes.
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
