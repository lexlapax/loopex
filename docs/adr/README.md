# Architecture Decisions

Decisions that refine the vision, recorded where evidence had to choose among
valid designs. Part of the [documentation index](../README.md).

An ADR is not milestone-scoped. It is numbered, flat, and permanent: superseding
a decision adds a new record rather than rewriting the old one.

## Decisions

| # | Decision | Status | Concept | Technical depth |
| --- | --- | --- | --- | --- |
| 0001 | Repository and application layout | Accepted (partially superseded by 0030) | [Decision](0001-repository-and-application-layout.md#concept) | [Technical depth](0001-repository-and-application-layout-technical.md#technical-depth) |
| 0002 | Bootstrap runtime floor and version matrix | Accepted (partially superseded by 0026) | [Decision](0002-bootstrap-runtime-floor.md#concept) | [Technical depth](0002-bootstrap-runtime-floor-technical.md#technical-depth) |
| 0003 | Extension contract boundary and distribution constraints | Accepted (home reading and its no-real-home test rule (the attended `m8-operator` opt-in, D87), and the no-compiler sentence, amended by Proposed 0037 and 0038 on their acceptance, M8) | [Decision](0003-extension-contract-boundary.md#concept) | [Technical depth](0003-extension-contract-boundary-technical.md#technical-depth) |
| 0004 | Plan amendment and supersession | Proposed (parked) | [Decision](0004-plan-amendment-supersession.md#concept) | [Technical depth](0004-plan-amendment-supersession-technical.md#technical-depth) |
| 0005 | Milestone supersession | Proposed (parked) | [Decision](0005-milestone-supersession.md#concept) | [Technical depth](0005-milestone-supersession-technical.md#technical-depth) |
| 0006 | Store transaction contract and owner epoch | Accepted (creation-domain transaction catalogue and durable custody amended by 0059) | [Decision](0006-store-transaction-and-owner-epoch.md#concept) | [Technical depth](0006-store-transaction-and-owner-epoch-technical.md#technical-depth) |
| 0007 | Local executor grant, job, and receipt | Accepted | [Decision](0007-local-executor-grant-job-receipt.md#concept) | [Technical depth](0007-local-executor-grant-job-receipt-technical.md#technical-depth) |
| 0008 | Owner succession recovery and runtime placement | Accepted (M7 read-only recovery queries and exact-genesis creation extended by 0046) | [Decision](0008-owner-succession-recovery-and-runtime-placement.md#concept) | [Technical depth](0008-owner-succession-recovery-and-runtime-placement-technical.md#technical-depth) |
| 0009 | Tool, executor, and grant contracts | Accepted (partially superseded by 0012, 0015, and 0016; M7 artifact arguments, interaction dispatch and tool selection amended by 0041, 0045 and 0046) | [Decision](0009-tool-executor-and-grant-contracts.md#concept) | [Technical depth](0009-tool-executor-and-grant-contracts-technical.md#technical-depth) |
| 0010 | Provider continuation and exact context staging | Accepted (partially superseded by 0013, 0017, 0018, and 0025; M7 lineage, instructions, compaction and model continuation amended by 0041–0044) | [Decision](0010-provider-continuation-and-context-staging.md#concept) | [Technical depth](0010-provider-continuation-and-context-staging-technical.md#technical-depth) |
| 0011 | Session input algebra and streaming progress | Accepted (partially superseded by 0012, 0013, 0014, 0016, 0017, and 0018; M7 compact/configure, maintenance, reasoning summaries and deadline bounds amended by 0043–0046; compaction domain and single activity observation closure exception amended by 0054) | [Decision](0011-session-input-algebra-and-streaming.md#concept) | [Technical depth](0011-session-input-algebra-and-streaming-technical.md#technical-depth) |
| 0012 | Executor cancellation capability | Accepted (partially superseded by 0016) | [Decision](0012-executor-cancellation-capability.md#concept) | [Technical depth](0012-executor-cancellation-capability-technical.md#technical-depth) |
| 0013 | Run-deadline commitment at first request staging | Accepted (partially superseded by 0017; M7 maintenance staging and absolute deadline ceiling amended by 0043 and 0046) | [Decision](0013-run-deadline-commitment-at-first-request-staging.md#concept) | [Technical depth](0013-run-deadline-commitment-at-first-request-staging-technical.md#technical-depth) |
| 0014 | Stream closure at owner loss | Accepted (partially superseded by 0018) | [Decision](0014-stream-closure-at-owner-loss.md#concept) | [Technical depth](0014-stream-closure-at-owner-loss-technical.md#technical-depth) |
| 0015 | Artifact object and use identity | Accepted (partially superseded by 0028) | [Decision](0015-artifact-object-and-use-identity.md#concept) | [Technical depth](0015-artifact-object-and-use-identity-technical.md#technical-depth) |
| 0016 | Configured cancellation observation | Accepted (M7 genesis, recovery lookup and prepared-owner abandonment amended by 0044, 0046 and 0049; physical restore transition superseded by 0051; migration of an alias-bound ledger generation narrowly amended by Proposed 0072 on its acceptance, M8 D45, D48, D55 and D59) | [Decision](0016-configured-cancellation-observation.md#concept) | [Technical depth](0016-configured-cancellation-observation-technical.md#technical-depth) |
| 0017 | Durable context and record admission budgets | Accepted (partially superseded by 0025; M7 context, receipt, refusal, genesis and deadline bounds amended by 0041–0044 and 0046) | [Decision](0017-durable-context-admission-budget.md#concept) | [Technical depth](0017-durable-context-admission-budget-technical.md#technical-depth) |
| 0018 | Provider attempt authority and recovery | Accepted (partially superseded by 0021 and 0027; M7 maintenance and closed Model/reply contracts extended by 0043 and 0044; Model callback boundary, settlement categories and terminal precedence amended by Proposed 0073 on its acceptance, M8) | [Decision](0018-provider-attempt-authority-and-recovery.md#concept) | [Technical depth](0018-provider-attempt-authority-and-recovery-technical.md#technical-depth) |
| 0019 | Host-owned provider protection | Accepted (partially superseded by 0029 and 0034; scoped to the durable profile by 0039; sole durable credential source amended by 0048; private-protocol kinds and the host-held access token amended by Proposed 0073 on its acceptance, M8) | [Decision](0019-host-owned-provider-protection.md#concept) | [Technical depth](0019-host-owned-provider-protection-technical.md#technical-depth) |
| 0020 | Explicit prepared handoff | Accepted | [Decision](0020-explicit-prepared-handoff.md#concept) | [Technical depth](0020-explicit-prepared-handoff-technical.md#technical-depth) |
| 0021 | Compacted provider-accounting provenance | Accepted (v2-only writer clause superseded by 0044's monotonic v3 cutover; settled-attempt result schema amended by Proposed 0073 on its acceptance, M8) | [Decision](0021-compacted-provider-accounting-provenance.md#concept) | [Technical depth](0021-compacted-provider-accounting-provenance-technical.md#technical-depth) |
| 0022 | Local executor supervision shell | Accepted | [Decision](0022-local-executor-supervision-shell.md#concept) | [Technical depth](0022-local-executor-supervision-shell-technical.md#technical-depth) |
| 0023 | Experimental public session protocol | Accepted (served generations and schema-digest inputs superseded by 0044) | [Decision](0023-experimental-public-session-protocol.md#concept) | [Technical depth](0023-experimental-public-session-protocol-technical.md#technical-depth) |
| 0024 | Durable interaction lifecycle and host-policy authority | Accepted (model interactions and immutable defer refusal amended by 0045 and 0046; policy public payload and answer provenance amended by 0052) | [Decision](0024-durable-interaction-lifecycle-and-host-policy-authority.md#concept) | [Technical depth](0024-durable-interaction-lifecycle-and-host-policy-authority-technical.md#technical-depth) |
| 0025 | Resource packs and skill admission | Accepted (source and name-order clauses superseded by 0039 for named skill directories; M7 provenance, maintenance and continuation receipts amended by 0042–0044) | [Decision](0025-resource-packs-and-skill-admission.md#concept) | [Technical depth](0025-resource-packs-and-skill-admission-technical.md#technical-depth) |
| 0026 | Development floor refresh | Accepted | [Decision](0026-development-floor-refresh.md#concept) | [Technical depth](0026-development-floor-refresh-technical.md#technical-depth) |
| 0027 | Provider permit retirement | Accepted | [Decision](0027-provider-permit-retirement.md#concept) | [Technical depth](0027-provider-permit-retirement-technical.md#technical-depth) |
| 0028 | Bounded artifact retrieval | Accepted (job-owned range reads and shared capacity extended by 0041; transfer opening, custody and accounting amended by 0066) | [Decision](0028-bounded-artifact-retrieval.md#concept) | [Technical depth](0028-bounded-artifact-retrieval-technical.md#technical-depth) |
| 0029 | Bounded provider failure diagnostics | Accepted (public failure vocabulary amended by Proposed 0073 on its acceptance, M8) | [Decision](0029-bounded-provider-failure-diagnostics.md#concept) | [Technical depth](0029-bounded-provider-failure-diagnostics-technical.md#technical-depth) |
| 0030 | Observability: tracing and telemetry | Accepted (tracing guarantees reused unchanged by 0049) | [Decision](0030-observability-tracing-and-telemetry.md#concept) | [Technical depth](0030-observability-tracing-and-telemetry-technical.md#technical-depth) |
| 0031 | Daemon store selection for `0.2.0` | Accepted | [Decision](0031-daemon-grade-store-selection-and-migration.md#concept) | [Technical depth](0031-daemon-grade-store-selection-and-migration-technical.md#technical-depth) |
| 0032 | Daemon attachment residency and replay | Accepted (served generations and schema-digest inputs superseded by 0044; activation ceiling amended by Proposed 0071 on its acceptance, M8; closed `daemon.stopping` reasons amended by Proposed 0073 on its acceptance, M8 D42) | [Decision](0032-daemon-attachment-residency-and-replay.md#concept) | [Technical depth](0032-daemon-attachment-residency-and-replay-technical.md#technical-depth) |
| 0033 | Collaboration: controller lease and takeover | Accepted | [Decision](0033-collaboration-controller-lease-and-takeover.md#concept) | [Technical depth](0033-collaboration-controller-lease-and-takeover-technical.md#technical-depth) |
| 0034 | Provider credential handoff over the bootstrap channel | Accepted (scoped to the durable profile by 0039; single-provider restriction amended by 0048; the custody-refusal row and the `:expired` reason amended by Proposed 0073 on its acceptance, M8; the Direct marker scoped to `complete_prompt/3` extended to 0073's sign-in requests by Proposed 0073 on its acceptance, M8 D62) | [Decision](0034-provider-credential-handoff-over-bootstrap-channel.md#concept) | [Technical depth](0034-provider-credential-handoff-over-bootstrap-channel-technical.md#technical-depth) |
| 0035 | Typed decision models as policy inputs | Proposed | [Decision](0035-typed-decision-models-as-policy-inputs.md#concept) | [Technical depth](0035-typed-decision-models-as-policy-inputs-technical.md#technical-depth) |
| 0036 | Daemon-grade store engine and migration | Proposed | [Decision](0036-daemon-grade-store-engine-and-migration.md#concept) | [Technical depth](0036-daemon-grade-store-engine-and-migration-technical.md#technical-depth) |
| 0037 | Host configuration and path discovery | Proposed | [Decision](0037-host-configuration-and-path-discovery.md#concept) | [Technical depth](0037-host-configuration-and-path-discovery-technical.md#technical-depth) |
| 0038 | Installed distribution and release artifact | Proposed | [Decision](0038-installed-distribution-and-release-artifact.md#concept) | [Technical depth](0038-installed-distribution-and-release-artifact-technical.md#technical-depth) |
| 0039 | Ephemeral embedded profile | Accepted (startup-handler order, named-root and unknown-ownership clauses narrowly superseded by 0040; M7 startup options and provider bindings narrowly amended by 0042–0045, 0048 and 0049; host-opened sign-in custody, the fixed provider prefix and in-process route tables gaining `chatgpt` and `vertex` with `claude` still refused, the ephemeral startup option `:sign_in_routes` in its closed option set, the pre-call refusal, `ask`'s status-1 codes, ephemeral `ask`'s `provider_credential_required` for a sign-in model whose route has no binding, a code M6 gave only durable `ask`, and the host-VM credential audience amended by Proposed 0073 on its acceptance, M8 D37, D38, D40, D50, D56, D61 and D73) | [Decision](0039-ephemeral-embedded-profile.md#concept) | [Technical depth](0039-ephemeral-embedded-profile-technical.md#technical-depth) |
| 0040 | Ephemeral startup interrupt and unnamed root | Accepted | [Decision](0040-ephemeral-startup-interrupt-and-unnamed-root.md#concept) | [Technical depth](0040-ephemeral-startup-interrupt-and-unnamed-root-technical.md#technical-depth) |
| 0041 | Session lineage projection and context budget | Accepted | [Decision](0041-session-lineage-projection-and-context-budget.md#concept) | [Technical depth](0041-session-lineage-projection-and-context-budget-technical.md#technical-depth) |
| 0042 | Host-composed instructions | Accepted | [Decision](0042-host-composed-instructions.md#concept) | [Technical depth](0042-host-composed-instructions-technical.md#technical-depth) |
| 0043 | Context compaction checkpoint | Accepted (transient compaction activity projection amended by 0054; episode failure union amended by Proposed 0073 on its acceptance, M8) | [Decision](0043-context-compaction-checkpoint.md#concept) | [Technical depth](0043-context-compaction-checkpoint-technical.md#technical-depth) |
| 0044 | Run model and reasoning configuration | Accepted (host configuration preparation and authored-to-canonical alias binding amended by 0050; coordinated policy event payloads amended by 0052; current configure request grammar amended by 0053; remote creation options amended by 0055) | [Decision](0044-run-model-and-reasoning-configuration.md#concept) | [Technical depth](0044-run-model-and-reasoning-configuration-technical.md#technical-depth) |
| 0045 | Model-originated questions | Accepted | [Decision](0045-model-originated-questions.md#concept) | [Technical depth](0045-model-originated-questions-technical.md#technical-depth) |
| 0046 | Child-session tool | Accepted (private host ledger recipe completed by 0056; fixed refusal order amended by Proposed 0071 on its acceptance, M8) | [Decision](0046-child-session-tool.md#concept) | [Technical depth](0046-child-session-tool-technical.md#technical-depth) |
| 0047 | Reference host run defaults | Accepted | [Decision](0047-reference-host-run-defaults.md#concept) | [Technical depth](0047-reference-host-run-defaults-technical.md#technical-depth) |
| 0048 | Host provider routing and credential bindings | Accepted (credential forms, the binding plane's closed member set, which gains the optional `sign_in_routes` member with `model_options` unchanged, ephemeral clause, live rotation and durable `ask`'s resolution of only the bindings its models use, an unused binding's unset value not failing it and every merged name staying in the exclusion set (D60), amended by Proposed 0073 on its acceptance, M8) | [Decision](0048-host-provider-routing-and-credential-bindings.md#concept) | [Technical depth](0048-host-provider-routing-and-credential-bindings-technical.md#technical-depth) |
| 0049 | Explicit host configuration | Accepted (policy terminal public-event encoding amended by 0052; immutable creation selections amended by 0055; `--config` requirement and `ask`'s `--config` (M8 D54, D57), status record, schema members, durable chat's credential form and failed-terminal reason amended by Proposed 0037, 0071 and 0073 on their acceptance, M8) | [Decision](0049-explicit-host-configuration.md#concept) | [Technical depth](0049-explicit-host-configuration-technical.md#technical-depth) |
| 0050 | Model-port configuration preparation | Accepted (initial-creation invocation and custody amended by 0055) | [Decision](0050-host-configuration-preparation.md#concept) | [Technical depth](0050-host-configuration-preparation-technical.md#technical-depth) |
| 0051 | Current-format physical restore | Accepted (backup-CLI, latest-backup, stranded owner-less claim and persisted intent temporary clauses amended by Proposed 0072 on its acceptance, M8, the last two by D68 and D70) | [Decision](0051-current-format-physical-restore.md#concept) | [Technical depth](0051-current-format-physical-restore-technical.md#technical-depth) |
| 0052 | Policy interaction public events | Accepted | [Decision](0052-policy-interaction-public-events.md#concept) | [Technical depth](0052-policy-interaction-public-events-technical.md#technical-depth) |
| 0053 | Current configure request | Accepted | [Decision](0053-current-configure-request.md#concept) | [Technical depth](0053-current-configure-request-technical.md#technical-depth) |
| 0054 | Compaction activity progress | Accepted | [Decision](0054-compaction-activity-progress.md#concept) | [Technical depth](0054-compaction-activity-progress-technical.md#technical-depth) |
| 0055 | Remote session creation options | Accepted (creation carrier, recovery and eligibility amended by 0059; creation options on a helper-enabled service amended by Proposed 0071 on its acceptance, M8) | [Decision](0055-remote-session-creation-options.md#concept) | [Technical depth](0055-remote-session-creation-options-technical.md#technical-depth) |
| 0056 | Host helper ledger byte recipe | Accepted (offline audit of the derived job index narrowly amended by Proposed 0072 on its acceptance, M8 D35) | [Decision](0056-host-helper-ledger-recipe.md#concept) | [Technical depth](0056-host-helper-ledger-recipe-technical.md#technical-depth) |
| 0057 | Attempts event bodies | Accepted (reviewed and authorized-next-candidate records omitted and the successor manifest pin replaced by `--campaign` and the committed anchor line, with D30, D47 and D49 as standing authorization, for M8 only by M8 D30 and D47) | [Decision](0057-attempts-event-bodies.md#concept) | [Technical depth](0057-attempts-event-bodies-technical.md#technical-depth) |
| 0058 | Bounded progress delivery | Accepted | [Decision](0058-bounded-progress-delivery.md#concept) | [Technical depth](0058-bounded-progress-delivery-technical.md#technical-depth) |
| 0059 | Responsive creation transactions and durable custody | Accepted (remote cancellation envelope clarified by 0061) | [Decision](0059-responsive-creation-transactions.md#concept) | [Technical depth](0059-responsive-creation-transactions-technical.md#technical-depth) |
| 0060 | Restore full-mode helper | Proposed | [Decision](0060-restore-full-mode-helper.md#concept) | [Technical depth](0060-restore-full-mode-helper-technical.md#technical-depth) |
| 0061 | Creation cancellation admission envelope | Accepted | [Decision](0061-creation-cancellation-admission-envelope.md#concept) | [Technical depth](0061-creation-cancellation-admission-envelope-technical.md#technical-depth) |
| 0063 | Runtime creation startup status | Accepted | [Decision](0063-runtime-creation-startup-status.md#concept) | [Technical depth](0063-runtime-creation-startup-status-technical.md#technical-depth) |
| 0065 | Private attempts IO prerequisite | Accepted (no-replacement-on-lost-acknowledgement clause amended for M8 only by M8 D30, and its refuse-until-resolved rule for a torn index by M8 D49; ADR 0057's reviewed and authorized-next-candidate records omitted and its successor manifest pin replaced, M8 D30 and D47) | [Decision](0065-private-attempts-io-prerequisite.md#concept) | [Technical depth](0065-private-attempts-io-prerequisite-technical.md#technical-depth) |
| 0066 | Owned artifact transfer opening | Accepted | [Decision](0066-owned-artifact-transfer-opening.md#concept) | [Technical depth](0066-owned-artifact-transfer-opening-technical.md#technical-depth) |
| 0067 | Tool-result event projections | Accepted | [Decision](0067-tool-result-event-projections.md#concept) | [Technical depth](0067-tool-result-event-projections-technical.md#technical-depth) |
| 0068 | CLI-owned output | Accepted | [Decision](0068-cli-owned-output.md#concept) | [Technical depth](0068-cli-owned-output-technical.md#technical-depth) |
| 0069 | Helper run evidence and route guard | Accepted | [Decision](0069-helper-run-evidence-and-route-guard.md#concept) | [Technical depth](0069-helper-run-evidence-and-route-guard-technical.md#technical-depth) |
| 0070 | Pre-1.0 superseded surface retirement | Accepted | [Decision](0070-pre-1-superseded-surface-retirement.md#concept) | [Technical depth](0070-pre-1-superseded-surface-retirement-technical.md#technical-depth) |
| 0071 | Daemon-attached conversation | Proposed | [Decision](0071-daemon-attached-conversation.md#concept) | [Technical depth](0071-daemon-attached-conversation-technical.md#technical-depth) |
| 0072 | Store readiness: current-format marker and operator backup and restore | Proposed | [Decision](0072-store-readiness-marker-backup-and-restore.md#concept) | [Technical depth](0072-store-readiness-marker-backup-and-restore-technical.md#technical-depth) |
| 0073 | Provider OAuth sign-in | Proposed | [Decision](0073-provider-oauth-sign-in.md#concept) | [Technical depth](0073-provider-oauth-sign-in-technical.md#technical-depth) |

0001 and 0002 were the prerequisites that unblocked the first milestone
candidate; the [plans register](../plans/README.md) records current status.
0003 blocks nothing — it settles the questions a first publication would
foreclose, so that they stay open until there is evidence to decide them.
0006 and 0007 are the prerequisites for accepting `M1`. 0006 decides how a
store refuses a stale session owner; 0007 decides what a local executor validates
before an effect. Both must be dispositioned before `M1` is accepted, not merely
before the outcomes they govern are implemented.

0008 is an implementation-time prerequisite for revising `M1` Workstream A and
then completing Workstream B. It supplies the durable identity ADR 0006's
dead-owner recovery requires and makes M1's active-passive runtime-placement
boundary explicit without adding an active-active coordination claim.

0009, 0010, and 0011 are the prerequisites for accepting `M2`. 0009 decides what
a tool definition is, how a runtime-scoped registry resolves one, which built-in
tools ship, how oversized tool output leaves through an artifact port, and how a
host says no; 0010 decides what a turn's canonical model request contains, how
the durable conversation is journaled and replayed, which project resources may
enter it, and when a run stops; 0011 decides which inputs a running session
admits, how steering and queued follow-up work are ordered and journaled, and
how a turn streams without letting transient progress become durable truth. All
three must be dispositioned before `M2` is accepted, not merely before the loop
they govern is implemented.

0012 supersedes only ADR 0009's `execute/4` exclusivity and ADR 0011's claim
that `execute/5` was the whole executor-boundary change; the remaining decisions
in both ADRs stay in force. 0013 supersedes only ADR 0010's and ADR 0011's
absolute-deadline-at-admission or promotion clauses; their remaining provider,
staging, input, and streaming decisions stay in force. 0014 supersedes only ADR
0011's universal stream-closure obligation where the transient plane's owner
dies or loses authority before it can state a truthful disposition and count,
and its rule that every closure precedes the attempt outcome's publication,
solely where a terminal fact commits before handoff and its reply reaches the
originating coordinator afterwards. ADR 0011's domain, sequencing,
loss-detection, and durable-fallback rules stay in force.

0015 separates immutable artifact-object identity from the bounded metadata of
each use, so content deduplication cannot erase durable provenance. It narrowly
supersedes ADR 0009's conflated object/use reference and callback shapes. 0016
derives core cancellation observation and the later command backstop from the
one configured cleanup period, narrowly superseding the executor-boundary and
cleanup clauses it names in ADR 0009, ADR 0011, and ADR 0012. 0017 establishes
distinct durable context-token and Store-record admission ceilings and narrowly
supersedes the staging, prompt-admission, and terminal-projection clauses it
names in ADR 0010, ADR 0011, and ADR 0013. 0018 establishes one-use
current-owner provider dispatch, an exact two-attempt version-1 allowance, and
conservative non-redispatching recovery, narrowly superseding the provider
attempt and owner-loss retry clauses it names in ADR 0010, ADR 0011, and ADR
0014. All four are accepted prerequisites for proposed `M2` Amendment 4;
acceptance does not itself amend the M2 plan pair or gate, authorize dependent
implementation, close M2, or authorize integration or release.

0019, 0020, and 0021 are accepted post-closure repair decisions, not retroactive
M2 prerequisites. 0019 selects a host-owned, one-invocation provider process and private companion
build so the adapter no longer changes parent VM diagnostic machinery. Its
explicit worker configuration and new credential-size ceiling are accepted
compatibility changes; implementation and conformance evidence remain separate.
0020 makes the local prepared-handoff participant explicit and replaces unused
handler replacement with atomic duplicate refusal. 0021 defines versioned
compact accounting evidence while preserving ADR 0018's reported-usage rule and
explicitly refusing ambiguous legacy records. None changes M2's Closed state,
locked gate, or integration authority. The
[repair follow-up](../evidence/M2-ff17990-review-followup.md#provider-protection-choice)
records implementation progress and outstanding evidence. ADR 0021 supersedes
only ADR 0018's settlement version, compact representation/validation, and
legacy-compatibility clauses, preserving its reported-usage accounting policy.

0022 records the maintainer-approved fixed Bash prerequisite for the reference
local executor's internal supervision, preserving raw command semantics and
the current cleanup topology. Its exact-pair acceptance is recorded separately
from the earlier implementation instruction. It is not
a retroactive M2 prerequisite and changes no Closed plan or locked gate.

0004 and 0005 are both parked. They designed correction paths for a defect
found in an accepted plan, then the defect that prompted them turned out to be
on an unmerged branch that could simply be abandoned. They become relevant the
first time such a defect is found after integration.

## How a Decision Is Recorded

Each ADR is a Concept and Technical depth pair that forms one decision. The
Concept file owns context, the decision, alternatives, consequences,
compatibility, and the governance record; its companion owns invariants,
mechanics, and evidence. Acceptance binds both files as they existed at the
recorded candidate.

Status is `Proposed` or `Accepted` and lives in the Concept file. Those are the
only two values the repository check accepts, because an accepted pair is
anchored across history and its bytes are never edited afterwards. A decision is
replaced additively: the successor declares `Supersedes: NNNN` and the
predecessor stays exactly as accepted. No actor accepts its own decision: acceptance is an explicit
maintainer or recorded-delegate disposition, captured in the governance record
rather than inferred from a status word.

The [`adr` skill](../../.agents/skills/adr/SKILL.md) carries the procedure for
preparing or revising one. A reversible implementation choice is recorded in the
nearest code, test, or plan progress instead — an ADR is for a decision among
valid designs, never an activity log.

## Related

- [Vision](../vision.md#concept) — the founding authority these decisions refine.
- [Developer documentation](../developer/README.md) — method and routing.
- [Plans](../plans/README.md) — milestone register and lifecycle.

0025 and 0027 are the two accepted M3 prerequisites: project-skill admission and
safe permit retirement. M4 owns 0023/0024/0026/0028/0030: protocol, durable
interactions, floor refresh, bounded artifact retrieval and observability. The
floor transaction inventory must include every holder on integrated M3, rather
than assume three. All five were accepted on 2026-09-13 at candidate
`3503992cbc0de02ef98ba261e7a19fdb7123e220`; their acceptance changes no Closed
gate record and does not accept the M4 plan pair or gate.
The protocol/interaction proposals were renumbered from the old draft's 0019/0020
because those numbers are now accepted M2 decisions.

0031 to 0034 are the four accepted M5 prerequisites: the daemon's store
selection for `0.2.0`, which is the existing local adapter with its documented
limits, its capacity-as-store-loss consequence and its retirement procedure,
leaving a daemon-grade adapter and its Store/journal-format migration open for
a separate decision while ADR 0032 owns the daemon-index compatibility import;
daemon
attachment residency and at-least-once replay over the generation-2-only
Unix-domain-socket transport with bounded session pages; the collaboration
rule of one in-memory controller lease with fresh per-grant epochs, observers
and takeover; and the provider adapter's credential resolution, moved from the
parent VM's process-wide environment to a composition-bound opaque token and
host-owned custody before the sender writes the bytes over the unchanged
per-invocation private channel the launcher already opens. The first three were proposed with the Open M5
plan on 2026-09-14 and revised twice that day on independent review; 0034
follows the maintainer's outcome of 2026-09-19. The maintainer accepted all
four with the M5 plan pair on 2026-09-21 at candidate `1e1b33bfbf83953463e6abcdaebd52dc12735d8f`;
the [disposition](../process/agent-context-map.md#disposition-m5-acceptance-2026-09-21)
records it.

0035 is Proposed for the milestone after M5 and is not an M5 prerequisite: it
decides that a typed decision model — one that returns probabilities and
confidences rather than text — may be an input to a host's policy decision and
a journaled plain-data fact, and may never be the decision. It depends on 0034
and on a prerequisite amendment to it, because a second provider needs one
credential token per provider where 0034 fixes one per **composed model
configuration** — bound at composition, resolved per call. No part of it
runs inside M5.

0036 to 0038 were proposed for the earlier installed-operator plan. The current
sequence places their work in M8 installation/readiness and M9 store migration,
after M7 coding-agent proof. ADR 0037 extends M7's explicit configuration with
installed discovery, writers, lifecycle commands, start on demand and the
`daemon.readiness` report; it introduces no separate role/provider schema. On
acceptance it narrowly amends ADR 0003's ban on reading a user home, for the
installed reference host's home discovery only, with the attended `m8-operator`
record as the opt-in of its no-real-home test rule (D87), and ADR 0049's grammar so that
`--config` is optional when a home is selected and `loopex ask` accepts it,
taking only `providers` for the providers they name (D54, D57); it applies ADR 0044's
`loopex.experimental/4` manifest recipe to add `daemon.readiness` to that
generation's method inventory. ADR 0038 records M8's `0.5.0`
label, its two hosts, their build environments and the macOS quarantine-removal
path; on acceptance it clarifies ADR 0003's "a minimal runtime distribution
carries no compiler" as "carries no build toolchain", so the OTP `compiler`
application ships as Elixir's runtime dependency. Before 1.0 no retained
rollback artifact is required. All three remain Proposed; the engine version
remains M9's to select.

0071 and 0072 were proposed on 2026-09-30 with the
[M8 plan](../plans/M8.md#concept), numbered 0050 and 0051 on its planning
branch and renumbered when that branch was rebased onto the closed M7 baseline.
0071 lets the conversation command attach to the running service, makes the
service read ADR 0049's configuration file at startup, and makes the service
host M7's read-only helper roles, with helper children counted toward the
daemon's activation limit. On acceptance it narrowly amends ADR 0049's
conversation status record, ADR 0032's activation ceiling, ADR 0046's fixed
refusal order with one new refusal, `helper_activation_limit`, and ADR 0055's
creation options on a helper-enabled service. 0072 takes the operator backup
and restore work out of 0036, so the installed release does not wait on the
engine experiment; 0036 keeps the engine selection, migration and capacity
refusal for the M9 draft. The maintainer accepted that split, the M8 plan's
proposal P2, on 2026-10-13. 0072 adds the current-format root marker,
`store adopt`, `store backup` and `store restore`, and on acceptance amends
exactly four clauses of accepted ADR 0051: its statement that no backup CLI
is added; its latest-backup-only restriction, which `--discard-later-work`
relaxes for a lost source; its rule that an owner-less claim is
stranded, which `store restore --abandon` relaxes for a claim directory
holding nothing or only `owner.tmp` (D68); and its rule that a persisted
intent temporary counts as possible intent, which `--abandon` alone relaxes
for an `intent.tmp` that does not decode beside an absent `intent` (D70)
(the intent check `--abandon` shares with `--resume` writes nothing, and
on `--resume` only chooses its printed command and the `restore_abandoned`
refusal; D71, D74, D77, D78). M8 changes `restore/2` to leave the disposable
helper job index out of its audit index, as adopt and backup do, while still
copying it (D29); no ADR 0051 sentence governs that, and it narrowly amends
ADR 0056's complete helper-namespace audit (D35). It also narrowly amends ADR
0016's migration rule: `store adopt` may rebind an executor ledger bound
through an alias path to a fresh-epoch generation bound to the physical path,
carrying its open authority unchanged (D45, D48), and rebinds the
resource-pack receipts ledger only when it holds neither an open entry nor a
receipt (D55, D59).
Credential separation is
ADR 0037's path rule, applied before the transition is called (D27). 0072
also states the format-number rule (D28): any durable change needs a new
number, held in the fast check by a retained format-1 root and the M7 root
through the full audit, exact pure-codec re-encoding and five named limits,
and otherwise by review. ADR 0051's other decisions, ADR 0070 and the
pre-1.0 rule settle the rest.

0073 was proposed on 2026-10-13 when the maintainer added provider sign-in to
M8 as outcome 8. It lets a provider binding name an `oauth` credential on
three new routes: `chatgpt:` for Sign in with ChatGPT, `vertex:` for Gemini on
Google Cloud, and `claude:`, reserved until Anthropic sanctions a client
registration for Loopex. Tokens are host-held in the operating system's
keyring or an owner-only file outside the state root, and Loopex uses only its
own client identities, except that its `adc` source presents the client of
gcloud's Application Default Credentials file. On acceptance it amends named
clauses of accepted ADRs 0018, 0019, 0021, 0029, 0032, 0034, 0039, 0043, 0048 and
0049, including ADR 0032's closed `daemon.stopping` reasons (D42), ADR 0019's closed private-protocol kinds, ADR 0034's
custody-refusal row and `:expired` reason, ADR 0039's provider prefix and in-process route tables, its pre-call refusal, `ask`
status-1 diagnostics, with ephemeral `ask`'s `provider_credential_required` (D73), and, by D37, its host-VM
credential audience, whose one common exception text replaces at acceptance the seven copies ADR 0039 requires in the vision pair and `AGENTS.md` (D40), with the vision's other credential passages and `AGENTS.md`'s credential sentence qualified (D56, D61), ADR 0034's Direct marker extended to the sign-in requests (D62), ADR 0048's binding plane's closed member set, which gains the optional `sign_in_routes` member with `model_options` unchanged, its ephemeral clause and its resolution of every configured binding, which durable `ask` narrows to its models' bindings (D60), ADR 0049's closed terminal schema and durable chat's `env`-only credential, the new public failure reason `provider_sign_in_required` in ADR
0029's bounded vocabulary, ADR 0018's Model callback boundary, settlement
categories and valid-combination table and terminal precedence, ADR 0021's settled-attempt result
schema and ADR 0043's episode failure union; adds the `oauth`
binding form and `vertex` members to ADR 0049's schema version 1 as additive
members; and amends one sentence of Proposed ADR 0037. M8's daemon exit statuses are 111 to 115 for 0071 (114
retired), 116 to 119 and 124 (`root_adopting`) for 0072, 120 to 123 for
0073 and 125 (`service_record_write_failed`) for 0037, landing as 111 to
115, then 116 to 119, then 120 to 125. All five M8
prerequisites remain Proposed.

0039 is the accepted M6 prerequisite, accepted with the M6 plan pair on
2026-09-27. It adds an ephemeral composition profile beside the durable one,
over the same kernel: a memory store, one in-process ReqLLM model path for
local and hosted providers, and the local executor on a temporary root.
0019 and 0034 are scoped to the durable profile by 0039; 0025's source and
name-order clauses are superseded for named skill directories. Its scoped
host-VM credential exposure, host-authorized tool audience and host-selected
catalog effects are applied in all seven affected vision/AGENTS placements.
The [acceptance disposition](../process/agent-context-map.md#disposition-m6-adr-0039-acceptance-2026-09-27)
binds the exact reviewed candidate and both pairs' digests.

0040 is the accepted narrow correction to 0039's startup-handler order,
unproved-startup root naming and unknown-ownership cases. It also requires
plain-English stderr recovery guidance after the fixed `ask` diagnostic. The
[acceptance disposition](../process/agent-context-map.md#disposition-m6-adr-0040-acceptance-2026-09-28)
binds its exact Proposed pair and leaves 0039's other decisions unchanged.

0041–0049 are Accepted with the M7 plan and both paired vision amendments at
`2986150b878151524ecdd9bac5a9779e69e196b4` on 2026-09-30. The
[acceptance disposition](../process/agent-context-map.md#disposition-m7-acceptance-2026-09-30)
binds each historical pair and records implementation/integration authority.
The clauses annotated above are the complete accepted-ADR prerequisite-table
joins; unrelated guarantees remain unchanged. Their original accepted files
are preserved, with the newer records governing only their named amendments.

The accepted M7 decisions cover lineage, instructions, compaction, model
configuration and bounded private continuation, model questions, serial
read-only helpers, explicit limits, provider custody and host configuration.
All nine were accepted together, with the vision's bounded question/helper
and section 13.4 amendments. Within each newly accepted ADR pair only its
Concept status and empty governance row change. Proposal-era preparation text
is read at its bound historical revision; current acceptance is recorded by
its status and governance row. ADRs 0035–0038 remain Proposed for successor work.

Eight external planning reports and the final lead-and-advisory round-9 review
remain indexed in the [evidence register](../evidence/README.md). The
[round-9 disposition](../evidence/M7-round-9-disposition.md) retains the final
planning repairs and their review limits. Their earlier status statements
apply to their named candidates; they are not rewritten as implementation or
closure evidence. M7 is Accepted with all nine outcome rows still Open.
