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
| Runtime instances, supervision, reducer | [Runtime ownership](../vision.md#concept-vision-runtime-supervision) | [Supervision and reducer mechanics](../vision-technical.md#technical-vision-runtime-supervision) | Multi-instance supervision, pure reducer, bounded journal transaction; use the [M1 runtime and embedding guide](runtime-and-embedding.md#concept) for the implemented single-machine surface. |
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

The umbrella exists. Product tests run with `mix test` from the repository root, and the repository's own checks are Mix tasks: `mix loopex.deps_budget`, `loopex.core_only`, `loopex.matrix`, `loopex.format_scope`, `loopex.version_train`, `loopex.docs_check`, `loopex.hook_registration`, and `loopex.self_hosting`. `bash scripts/check-bootstrap.sh` runs the aggregate, `bash scripts/check-m0-gate.sh` runs the closed M0 gate, and `/bin/bash -p scripts/check-m1-gate.sh` runs the active M1 gate.

Product tests run against a temporary `LOOPEX_HOME`; the
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
