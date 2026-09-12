<a id="technical-depth"></a>
## Technical depth

Concept: [Extensible local foundations](M3.md#concept).

<!-- loopex:plan-technical-envelope:start -->
## Normative Technical Envelope

<a id="technical-plan-prerequisites"></a>
### Prerequisites and Acceptance Points

Concept: [Scope](M3.md#concept-plan-scope).

Concept: [Non-goals](M3.md#concept-plan-non-goals).

The integrated M2 base is `b637873ddc39542ec27add71015b46a4f7c7f80e`, retained
as an ancestor without rebasing or squashing bound history. Before acceptance,
prove bootstrap, the complete deterministic suite, the distinct behavioral red,
every applicable runner mode, the accepted-floor runner regression, exact
bindings and independent review on the exact candidate. The independently
reviewed
[acceptance aggregate override](../developer/agent-context-map.md#override-disposition-m3-acceptance-aggregate-2026-09-10)
waives only the new M0–M2 aggregate at this plan-acceptance transition. Record
that evidence as waived, not green or unavailable.
M3 stays Open until explicit acceptance of the reviewed plan pair and gate.

The original M3 acceptance had two new ADR prerequisites; Amendment 1 adds
ADR 0029 as an explicit prerequisite before its proposal revision A:

| Decision | Owner and acceptance point | Effect |
| --- | --- | --- |
| [**ADR 0025**](../adr/0025-resource-packs-and-skill-admission.md#concept) | Maintainer, before M3 acceptance | Fixed project-skill class, Git import, trust, pre-run selection, retention and optional-block admission |
| [**ADR 0027**](../adr/0027-provider-permit-retirement.md#concept) | Maintainer, before M3 acceptance | Safe retirement of whole-generation in-memory spent references under unchanged fencing and accounting |
| [**ADR 0029**](../adr/0029-bounded-provider-failure-diagnostics.md#concept) | Maintainer, accepted before Amendment 1 proposal A is committed | Finite invocation-local companion failure categories through the existing private codec/channel, with unchanged public outcomes and cleanup |

ADR 0029 follows the ordinary proposal/acceptance pair P/T before the M3
amendment proposal/rebind pair A/R. This draft is A after T: the historical
prerequisite guard checks every revision retaining the Accepted lifecycle,
so ADR 0029 acceptance cannot be postponed until implementation. A retains the
old Acceptance row; R alone rebinds to the reviewed, explicitly accepted A.
Neither A nor R contains or proves the diagnostic implementation.

Accepted M2 ADRs remain inherited constraints. ADRs 0023, 0024, 0026 and 0028
belong to M4: protocol, durable interactions, floor and artifact ranges. No floor
change or Closed-gate transaction is an M3 opening prerequisite. An
inherited restriction changes through its holder's transaction or an explicitly
scoped maintainer override under AGENTS.md. M4 must derive its own holder inventory, including
M3 if M3's accepted gate binds a file it changes. Deferral moves transaction cost;
it does not prove that only three holders will exist later.

**Approved CLI exception.** The maintainer's
[reviewed override](../developer/agent-context-map.md#override-disposition-m3-cli-extension-ratification-2026-09-10)
changes the continuing assertion in `cli_test.exs`: preserve the five inherited
commands and permit `skill` in M3. The old protected test name remains a
historical selector identity, not a permanent command ceiling. No Closed gate,
runner or bound-artifact bytes change and no additional amendment transaction
blocks the CLI workstream. Existing facade, dependency and no-wire scope
constraints remain required. This exception accepts no M3 product implementation.

**Complete readiness packet**

The current opening probe exercises required-only admission through real session
staging and retained Store receipts. It proves that one missing repair; it does
not prove skills work. Under the maintainer's
[reviewed preparation-rule ratification](../developer/agent-context-map.md#override-disposition-m3-incremental-witness-ratification-2026-09-10),
acceptance binds complete outcome clauses, exact contracts, witness identities,
checkpoint routing and executable closure commands. Test bodies and feature
fixtures are developed with implementation; they need not all exist before
acceptance. The first implementation checkpoint must demonstrate the integrated
skill workflow before feature breadth. A harness cannot supply missing product
behavior. Undefined helpers, compile failures and absent witnesses never supply
the opening red or a passing closure lane.

Each obligation row settles operator result, entrypoint, owner, authority input,
durable identity, transaction cuts, bounds, refusal, witness, compatibility and
rollback before implementation. Exact accepted commands and witness identities
are completed while Open. No unresolved contract is delegated to an implementer.

<a id="technical-plan-ownership"></a>
### Ownership, Decision Owners, and Rejoin Barriers

Concept: [Scope](M3.md#concept-plan-scope).

| Slice | Owned boundary and paths | Rejoin evidence |
| --- | --- | --- |
| Resources | `loopex_composition` resolver/importer; core admission/staging; CLI resource commands | Project-only discovery, executor-owned Git effects, exact admitted bytes, no core paths/network |
| Repairs | Context staging/admission, dispatcher and Control | Required-only properties, held-Store availability, retirement and succession negatives |
| Integration | Composition and CLI using existing policy, executor and ArtifactStore | Same configured skill/tool/artifact result through embedding and built CLI |
| Gate protection | Repository entrypoints, governance-history guard and behavioral witness manifest | Override authority predating acceptance, focused checkpoint selection, acyclic inherited calls and truthful failure propagation |

One integrator owns rejoin and the exact candidate. Sequence: decisions and gate
readiness → one thin workflow → bounded expansion and independent repairs →
integrated self-audit → independent closure review. Parallel work follows the
repository isolation/ownership rules; workstreams have no separate gate.

The first workflow imports one tiny pinned project skill, admits its full
manifest, selects its instructions and one already manifested supporting label,
uses one existing tool under allow/deny policy, and inspects the real artifact
through the existing full-object fetch. Capture actual staged model input and
reconstruct retained state in a fresh process. Exercise direct embedding and
the source-built CLI/provider companion outside the checkout before breadth.
No policy defer, range API or wire implementation enters this M3 workflow.

**Transaction and failure matrix**

| Boundary | Required state cuts and negatives |
| --- | --- |
| Git/import | Allow/deny, deadline/cancel, exact-commit mismatch, truncated tree, size/count cap, links/special files, interrupted publication and existing destination; no hook/filter/script execution |
| Trust/context | Missing/stale decision, changed bytes, catalog change, unsupported metadata, pre-run-only commands, manifested-label selection, whole-block withholding, all four admission dimensions, one-runtime/one-workspace snapshot residency and no per-session copies |
| Authority | Hostile allowed-tools/hooks/script pack; compare canonical tool registry, same-request policy result and grant set before/after activation; no effect from resource commands |
| Provider | Exact staged bytes vs dispatch authority, permit spend, ambiguous attempt, settled old identity after retirement, owner succession and settlement-v2 preservation |
| Dispatcher | Held Store, late result after detach/replacement, stale owner/cursor, overflow, unrelated-session acknowledgements and ordered publication |
| Existing artifact/host paths | Authorized full-object use and integrity checks; CLI/embedding launch equivalence, abrupt loss vs graceful cancel, prepared transfer, provider companion/process cleanup |

Resource commands require settled state before the next run and freeze a per-run
selection. Late model output cannot mutate it. Supporting requests choose only
existing manifest labels. Replay uses retained exact request bytes without
refetch or inferred permission to redispatch an ambiguous provider attempt.

<a id="technical-plan-evidence"></a>
### Evidence Obligations and Mapping

Concept: [Outcomes](M3.md#concept-plan-outcomes).

The Concept outcomes and gate obligation table use the same exact selector
paths. Lock one named decisive witness per required clause; one integrated case
may prove multiple clauses only when each has its own observed assertion.
Keep additional negatives in the ordinary required suite without freezing their
names, whole-file counts or exclusions. Adding or renaming an unprotected test
is not a gate amendment. Changing a protected obligation needs its amendment or
an explicit maintainer override. Existing Closed locks remain fully enforced
with the recorded CLI assertion exception and Amendment 2's
[approved diagnostic replacement bindings](../developer/agent-context-map.md#override-disposition-m3-selector-diagnostics-2026-09-12) at required contract
moments.

Do not freeze test-file bytes that M3 must extend. Bind canonical gate/harness,
fixture/vector and result-channel bytes present at acceptance; lock the
declared future protected tests by identity and
required runnable state. Deterministic and real-provider cases live in separate
files so no mutable mixed-file exclusion inventory becomes a lock. A protected
case that is missing, skipped or excluded fails. Counts are not a delivery
objective. Before acceptance refresh repaired-path clause witnesses against
`b637873ddc39542ec27add71015b46a4f7c7f80e`; do not inherit the obsolete 79-case
snapshot or freeze every test added since a moving historical revision.

1. **Acquisition:** actual local Git fixture and executor job, exact tree/file
   identities, retained-provenance reattachment only after current-byte match,
   deadlines/cleanup and interrupted atomic installation. An attended public Git
   import separately proves the real network path.
2. **Context:** catalog/instruction/supporting stages, hostile-pack invariance,
   ADR 0017 step-5 ordering at the 38-element receipt shape, generated structures
   through cardinality 1,024 and maximal receipts, single-workspace host/core
   residency without per-session copies, actual staged request capture and fresh-
   process replay with no source reread.
3. **Workflow:** both entries and source-built CLI/companion, actual tool result,
   existing full-object artifact inspection, trusted launch/recovery configuration;
   an attended real-provider task in
   `apps/loopex_cli/test/foundation_workflow_real_test.exs`.
4. **Repairs:** required-only fixed-point lower-bound/first-failure properties and
   historical refusal replay; held-Store unrelated-session latency; long-history
   retention with delayed requests and owner succession. Use ADR 0017's existing
   refusal members and meanings, not a new inferred lower-bound receipt field.
5. **Gate protection:** override citation and standalone-anchor ancestry across
   ordinary integration merges; synthetic register invocation and M3-Closed
   transition; missing/red/omitted predecessor; bootstrap recursion refusal;
   cross-VM scratch allocation; and mutations of repaired-path clauses and
   sibling transitions.

**Amendment 1: bounded private provider diagnostics**

ADR 0029 owns the exact finite schema, classifier precedence and lifetime.
Advance the existing private codec/handshake to version 2; only the ambiguous
failure terminal adds the required stage/class map. Its encoded map is capped
at 256 bytes within the unchanged terminal/frame caps. The worker normalizes
one first unsuccessful stage and drops raw reasons. The bridge discards its
provisional pair on every protocol failure and exposes it only after the
single terminal is sealed by terminal_end and clean EOF. The existing test
observer may retain one validated pair using static labels; cleanup proof is
independent. No automatic production observer or raw-argument trace is added.

Use the existing codec, bridge, adapter-contract, credential-plane and phase-
diagnostic tests and support fixtures. Their ordinary required deterministic
suite proves finite types/enums/keys/caps, first-failure precedence, secret
exclusion, unavailable-on-invalid-protocol behavior, owner/collector lifetime,
and unchanged public errors/retry classification. Prove positive single-
terminal-plus-EOF observation and rejection after duplicate/additional/malformed
or partial final frames. Preserve historical protected case identities and all
unaffected assertions. Codec version fixtures are ordinary tests, not locked
version-1 guarantees; update only their approved schema/version expectations.
In particular, preserve the actual M2 pre-transport refusal and generic-
ambiguity witness and its public Model/retry assertions. No new locked selector
or test name is introduced here.

Mixed host/worker versions and build-manifest mismatches must refuse before
credential delivery, without dual decoding or downgrade. Existing real-
companion deterministic fixtures prove failure categories; unchanged required
real-provider and attended source-built CLI paths prove deployment fidelity.
Keep their model, prompt, deadlines, cleanup grace, invocation counts and
assertions unchanged. No live-provider failure need be forced. Renew affected
same-source build, startup/deadline/retainer/backpressure/launcher and full
candidate evidence under the existing approved cadence. Supplemental diagnostic
clones and earlier-source passes do not replace required candidate evidence.

The new diagnostic implementation and evidence are unavailable at A and R,
regardless of the unchanged runner's result. No earlier S PASS establishes the
addition. The first implementation checkpoint after R must establish a
positive-control-backed behavioral failure against retained baseline production
at the existing codec boundary, before adding the implementation. Missing APIs,
undefined tests and environment failures do not constitute that red. Then add
real-companion conformance cases to the existing required suite and prove the
accepted diagnostic contract without inventing new locked witness names.

**Amendment 2: shared selector diagnostics and binding validation**

The [approved exact patch](../developer/agent-context-map.md#override-disposition-m3-selector-diagnostics-2026-09-12) changes only
`scripts/m1-exunit-runner.exs` and its existing
`apps/loopex/test/m1_exunit_runner_test.exs` corpus. Failure output retains the
mode/seed, bounded case/location identifiers and finite category/type summaries,
excluding arbitrary runtime values. Two synthetic cases extend the corpus;
its original five cases, success reports/digest inputs, required counts,
exclusions, real-provider paths and exit predicates remain unchanged.

The [separately approved checker correction](../developer/agent-context-map.md#override-disposition-m3-sequential-binding-checker-2026-09-12) makes current/history
validation enforce M1 generation 9, then M2 generation 10, then M3 Amendment 2.
Each holder retains its own proposal, exact-SHA acceptance and immediate rebind;
Closed-holder Acceptance and Closure remain historical. The checker derives
shared identities from the first proposal and its parent, permits only pending
holders' exact old rows, keeps settled holders strict and rejects an unfinished
sequence globally. Internal scoped results identify outstanding holders.
Focused testing and independent correction review precede the first proposal.
This adds no outcome, ADR, public command or product contract.

**Cheap checkpoints and full contract evidence**

The locked default command is the complete closure gate. `--checkpoint` is
explicitly focused diagnostic evidence: inspection, isolated compile/opening
probe, and changed-outcome deterministic witnesses selected by a digest-bound
path-to-outcome map. Shared or unclassified product paths select all outcomes;
unknown acceptance impact requires the full gate. Selection starts from an
explicit retained comparison SHA, includes tracked/untracked relevant work,
and cannot interpret an empty/invalid comparison as no work. The exact mapping
and role grammar must exist and be negatively tested before acceptance.

The reviewed M3 acceptance override waives a new full inherited aggregate only
at this plan-acceptance transition. Run it at every parallel-workstream rejoin,
every amendment rebind child, closure candidate and after changes that invalidate
later evidence. A missed required run is a process defect and leaves inherited
evidence unavailable. A later-discovered inherited red left unobserved between
those moments is an evidence-schedule defect, not conforming behavior. Focused
results do not replace required full evidence or excuse an observed inherited
failure.

For the documentation-only Amendment 1 proposal A and immediate rebind child R,
the approved [Amendment 1 gate-cadence override](../developer/agent-context-map.md#override-disposition-m3-amendment1-gate-cadence-2026-09-11)
replaces the full-gate timing requirement above. Full M0–M3 commands at A/R are
**unrun and deferred** to the completed implementation candidate, including
Linux serenity. Retain focused status, artifact/envelope binding, documentation
and bootstrap checks appropriate to each revision, plus independent exact-SHA
review. At A, binding-dependent checks must refuse only for the deliberately
stale M3 binding; verify binding-independent checks directly. At R, focused
status, bindings, documentation and bootstrap must be green. Deferred commands
are never reported PASS, and earlier results retain their original source
identities. All final commands, tests and pass/failure criteria remain unchanged.

For the three Amendment 2 holder transactions only, the
[approved final-only cadence](../developer/agent-context-map.md#override-disposition-m3-selector-diagnostics-2026-09-12) replaces full-gate execution at A/R
with focused exact-patch identity, owning diagnostic corpus, unchanged success
semantics, script syntax/digests and applicable status/binding checks. Each
holder's exact-SHA review and status validation precede the next. Pending/stale
bindings remain explicit; M3 R must settle every holder. Complete M0–M3 gates
remain required at the final candidate on macOS and Linux serenity. Deferred
commands are unrun, never PASS; historical failures keep their source and result.

Do not put the aggregate inside protected-selector execution or bootstrap.
Record per-lane duration so cost is observable; no promised minute count.

**Review and closure evidence**

Every negative proves it reached its intended boundary. Source regexes, literal
configuration, startup failure and short silence cannot witness behavior.
Preserve inherited assertions. Before amendment/closure handoff, use mutant-hunt
on changed obligations and sibling paths, then independent review. Repeated
finding classes trigger an all-entrypoint root-cause audit, not another narrow
patch/reviewer loop. The implementer self-audits composition, lifetime, trust,
rollback, packaging and docs before final review.

Freeze source S for required evidence. Bind source/gate/commands/seed, limits,
actual toolchains/platforms and non-secret build identities. Run real build and
platform paths early and at closure; retained old-reader positive controls,
new-format refusal and every documentation row remain mandatory. Relevant byte
changes invalidate affected evidence/review; unknown scope means the full gate.
A same-source disappearing failure is a blocking flake, not a successful retry.

**Acyclic gate ownership**

`scripts/check-closed-gates.sh` reads the canonical register and runs the exact
required commands. Bootstrap is a leaf. The full M3 runner owns the inherited
aggregate call; checkpoint mode cannot claim full-gate completion. Once M3 is
Closed its inherited call selects only its predecessor prefix, excluding itself.
Prove that synthetic transition and reject missing invocation/back-edges before
acceptance. No environment skip or authority bypass is permitted.

<a id="technical-plan-compatibility"></a>
### Compatibility

Concept: [Scope](M3.md#concept-plan-scope).

Resource queries and admission/activation commands are experimental additions.
Core receives canonical data; Git, paths and parsing stay at the edge. Version
new resource records/receipts and preserve genuine M2 replay, root AGENTS and
historical refusals. ADR 0025 explicitly narrows its supersession of 0010/0017.
ADR 0027 changes in-memory retention, not attempt/accounting algebra. Existing
allow/deny policy and full-object ArtifactStore contracts remain unchanged.

Amendment 1 changes only the matched host/companion private codec pair under
ADR 0029. It changes no session format or durable data and adds no migration.
Rollback restores a matching prior pair with diagnostics absent; it never
authorizes retry of an uncertain invocation. The public Model error remains
`{:error, {:dispatched_or_unknown, "model_call_failed"}}`.

<a id="technical-plan-migration"></a>
### Migration and Rollback

Concept: [Scope](M3.md#concept-plan-scope).

Use fresh M3 evidence roots. Prove new readers on genuine M2 history and old
readers refusing unknown M3 records before dispatch, with an old-format positive
control. Roll back with retained old root/binary pairs; never rewrite operator
history or promise in-place downgrade. Import validates in task-owned staging
then atomically publishes the project pack; interruption preserves the previous
installation. Retained staging bytes survive later pack removal. Cleanup touches
only task-owned temporary state. No floor or artifact format migration is added.

<a id="technical-plan-packaging"></a>
### Packaging

Concept: [Scope](M3.md#concept-plan-scope).

Keep eight apps and existing roles, versions and toolchain pins. Core/protocol
remain stdlib/OTP only. Git import uses an existing executor command job with
explicit executable, closed environment/configuration, probed Git prerequisite,
bounded deadline/output and normal cancellation. No HTTPS fetch, new executor
kind, production library or generic YAML runtime. Parse a declared bounded
frontmatter subset and diagnose unsupported constructs. The CLI gains skill
add/list/show and explicit pre-run selection. No publication or service install.

<a id="technical-plan-minimalism"></a>
### Proportional Minimalism Budget

Concept: [Scope](M3.md#concept-plan-scope).

Justified growth is one fixed ResourcePack boundary, resource catalog/read
queries, admit/activate commands, host resolver/importer and CLI adapters, three
direct core repairs and repository verification. One admission owner, manifest
and selection path serve both hosts. No new app/dependency/job kind, second
policy evaluator, interaction family, range port, default tool, plugin loader,
generic pipeline, worker pool or second reducer. Review growth against actual
boundary reuse; arbitrary line ceilings do not replace complete evidence.

Amendment 1 additionally permits finite normalization inside the existing
adapter, one codec terminal member, provisional guardian state and one private
side-effect-free observation call after sealing. Keep the existing launcher,
build task/configuration and BuildFixture unchanged. No generic diagnostic
framework, event history, extra transport or new retained resource is justified.
If a bound artifact, cap increase or broader boundary change becomes necessary,
stop for a new decision rather than extend this allowance.

Amendment 2 separately permits only the exact shared diagnostic patch, its
M1/M2/M3 binding replacements and the
[approved checker correction](../developer/agent-context-map.md#override-disposition-m3-sequential-binding-checker-2026-09-12) with focused governance tests. These are test and
repository-check changes under the [new scoped decision](../developer/agent-context-map.md#override-disposition-m3-selector-diagnostics-2026-09-12); they do
not extend Amendment 1's product-diagnostic allowance or add an acceptance
criterion.
<!-- loopex:plan-technical-envelope:end -->
