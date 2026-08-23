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

The umbrella exists. Product tests run with `mix test` from the repository root, and the repository's own checks are Mix tasks: `mix loopex.deps_budget`, `loopex.core_only`, `loopex.matrix`, `loopex.format_scope`, `loopex.version_train`, `loopex.docs_check`, `loopex.hook_registration`, and `loopex.self_hosting`. `bash scripts/check-bootstrap.sh` runs the aggregate and `bash scripts/check-m0-gate.sh` runs the milestone gate.

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
