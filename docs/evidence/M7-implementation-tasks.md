# M7 Implementation Tasks

Execution checklist supplied by the maintainer. The accepted
[plan](../plans/M7.md#concept) and its
[technical companion](../plans/M7-technical.md#technical-depth) govern scope
and proof obligations. This checklist records work; it introduces no decisions.
Part of the [evidence index](README.md).

## Current work

- Done: reproduce cross-run conversation loss with the real session-owner path
  and a scripted model in `apps/loopex/test/agent_loop_test.exs`.
- Done: run-scoped result joins, replayed admission order, revision-1 normalized
  call identities and strict complete-lineage validation. These are projection
  foundations; the coordinator now stages the complete committed lineage.
- Done: v2 request staging, revision-4 nil-continuation receipts, exact lineage
  replay validation, and terminal-derived unknown/cancelled call results.
- Done: conversation integration candidate fast check; all 11 suites pass
  2,638 tests at `2d804649ca82ce87b58511bc0739c93e700c7559`.
- Done: pinned artifact-read generation vectors and pure capability binding;
  instruction capture/render validation preserves exact legacy staging bytes.
- Done: shared v3 genesis normalization/resolution and pure replay retain closed
  configuration, exact tools, artifact-read binding and policy-defer mode.
- Done: exact-genesis live creation and configuration-bound runtime staging;
  two prompts plus restart retain captured instructions, settings and tools.
- Done: captured-configuration runtime candidate fast check; all 11 suites pass
  2,679 tests at `d46c8d10881e6ba811b6c1d5204c9545aa785d37`.
- Next: reference-host instruction composition, then chat/configuration
  composition and non-nil continuation costs in T03/T04/T06/T08.
- Remaining: all unchecked tasks below. Closure, main integration and release
  retain their explicit maintainer decision gates.

## Development observations

- 2026-10-01: the focused second-prompt regression executed one test and failed:
  the next request contains only the new prompt. This is a development red,
  not closure evidence. No provider call was made.
- T01 added subtasks: retain admission order through replay; choose lineage
  validation by the staged record/receipt generation; join results by complete
  run/turn/call identity; preserve old staged requests and old receipt decoders.

- 2026-10-01: conversation unit tests pass (12 tests, 0.08 seconds). The full
  agent-loop file passes 103 of 104 tests (24.7 seconds); the sole failure is
  the retained second-prompt regression. Admission-order recovery and promoted
  follow-up accounting tests pass. Compiled documentation ordering passes.
- Revision-1 normalized IDs bind `Canonical.encode([run_id, turn_number,
  tool_call_id])`; fixed r1/r2 vectors retain the exact 48-hex prefix. Source
  references keep the original run/turn/call identities. Historical projection
  retains its saved call IDs. Request/receipt generation integration remains.
- 2026-10-01: the affected conversation, agent-loop, context, skill, resource
  replay and project-trust suites pass 168 tests in 30.9 seconds. Input-algebra
  passes 11 tests in 5.7 seconds. The original second-prompt regression and a
  runtime-restart regression pass. These are development checks; real-provider
  and closure evidence remain pending.
- New requests bind v2 canonical bytes to revision-4 receipts and normalized
  committed lineage. Retained v1 requests and revision-2/3 receipts retain
  their historical validation. Generation mismatches, omitted/null-cost
  violations and self-consistent substituted history are rejected.
- T01 added subtask: derive missing cancelled/unknown results from committed
  terminal facts before promoting follow-ups; an uncertain effect must remain
  explicit in later context and must not be redispatched.

- 2026-10-01: candidate `34e840c64b865efd915ccbf2675db948d094bf0c` fast
  check failed four tests: two raw-call-ID assertions, the interaction old-reader
  positive control using newly staged v2 bytes, and a Pending-cell test reading
  the filled M6 closure page. All other application suites passed. Full output:
  `/private/tmp/loopex-m7-34e840c6-fast-check.log`,
  `sha256:7769090f45a10180b644872fc8d865fa3c0c6983ba737cbe6c83972b33fdcec2`.
- Corrected assertions verify normalized call/result joins. The actual M3
  reader still evaluates both positive and negative interaction controls, using
  explicitly encoded historical v1 staging and revision-2 receipts. The M6
  scaffold test reads the exact tested candidate `4088759467ce8a3b2e7ad14b1166ae3ee923b7f3`.
  Focused checks pass: core 35 tests in 23.6 seconds and composition 10 tests
  in 10.2 seconds. No historical evidence or reader behavior was changed.

- 2026-10-01: candidate `2d804649ca82ce87b58511bc0739c93e700c7559` fast check passed in
  842 seconds: 11 application suites, 2,638 passed tests. Full output:
  `/private/tmp/loopex-m7-2d804649-fast-check.log`,
  `sha256:47eb0c4b1c6c355e896adda494e82d05f0f6f772a6912df7cbdeaf0222053f7e`.
  Its exact identity is retained separately in
  `/private/tmp/loopex-m7-2d804649-fast-check.sha`. This is current-toolchain
  development integration evidence; the M7 closure matrix remains pending.

- 2026-10-01: shared `SessionGenesis.resolve/2` and `normalize/1` now own
  v2 creation/replay validation. They retain normalized legacy transaction bytes,
  require captured cleanup and closed inputs, and refuse non-plain data and
  normalized items above 65,536 bytes. Creation preserves its legacy malformed
  option and structural refusal taxonomy. Focused genesis/lifecycle/cancellation/
  timer tests pass 37 cases (31.6 seconds; one standard long-bound exclusion);
  runtime/detailed-result/fault/conversation tests pass 119 cases (24.8 seconds),
  and ephemeral API tests pass 15 cases (7.5 seconds). Compiled documentation
  ordering passes with 925 covered entries. The coordinated v3 decoder/writer,
  configuration and exact-genesis live facade remain unchecked.

- 2026-10-01: literal artifact-read revision 1 binds both complete generation
  triples to retained canonical preimages. Four released reference revisions
  share the legacy null capability; the planned 1.1.0 range definition has an
  explicit binding. Unknown read generations, duplicate selections and modified
  bindings refuse. Focused capability/genesis tests pass 12 cases in 0.04 seconds;
  compiled documentation ordering passes with 930 covered entries. Executor
  registration, live range retrieval and v3 genesis binding remain pending.

- 2026-10-01: pure instruction capture/render validation now implements ADR 0042's
  closed four-member input, ASCII version grammar, byte-counted UTF-8 section
  bounds and exact blank-line rendering. Captured section bytes retain the
  rendered SHA-256; replay validation rejects substitutions and extra members.
  Legacy staging uses the same immutable fallback bytes. Instruction/conversation/
  context tests pass 136 cases in 25.3 seconds; compiled documentation ordering
  passes with 936 covered entries. Host configuration, complete system costs and
  configuration-bound receipt provenance remain pending.

- 2026-10-01: the shared decoder now admits v3's complete closed genesis and
  derives its artifact capability from the selected generation. Name bindings
  must bijectively match retained tool definitions. Pure replay retains initial
  configuration, selection and policy-defer mode; v2 keeps its original bytes
  and no inferred selection/configuration. The configuration validator checks
  captured instructions, declared model/output limits, known/unknown/explicit
  input-budget origins, bounded capability metadata and closed provider mapping.
  The generic default descriptor cannot enable another reasoning level.
  System admission counts exact message and model-facing tool-schema costs.
  Decoder/instruction/capability tests pass 32 cases in 0.09 seconds;
  decoder/runtime/conversation/context tests pass 153 cases in 25.3 seconds.
  A corrected metadata-boundary fixture measures its actual canonical preimage;
  tightened generic-mapping and replay tests pass 21 cases in 0.1 seconds.
  Compiled documentation ordering passes with 938 covered entries. Live v3
  creation, provider mapping conformance, frozen run/configuration binding and
  configuration-aware request/receipt staging remain pending.

- 2026-10-01: host-private exact-genesis creation now retains supplied v2/v3
  bytes and normalized original options. Historical duplicates start no owner
  and bypass changed startup defaults/registrations; fresh v3 creation checks
  admitted definitions/model route and kernel request construction. New
  prompt_admitted_v3 and configured model_request_committed_v2/resource v2
  records bind the admitted configuration version. Follow-up promotion inherits
  the captured configuration. Requests use exact captured instruction text,
  model, reply allowance, provider mapping and immutable tools. Revision-4
  instruction provenance is checked against the owning configuration, including
  a self-consistent renamed-source negative case. Captured policy-defer refusal
  denies without an interaction or executor effect. Ordinary measured numeric
  context_admission_refused_v2 retains its own estimator, scope, configuration
  and hard limits; v1 keeps its original rules. Maintenance/headroom/nonnumeric
  refusal variants remain pending with compaction. Runtime/genesis/conversation/
  context tests pass 158 cases in 25.5 seconds; configured/context tests pass
  32 cases in 2.1 seconds, interaction coverage passes 27 cases in 12.3 seconds,
  and configured/detailed-result checks pass 15 cases in 0.6 seconds. Compiled
  documentation ordering passes with 941 covered entries. Full fast integration
  verification is next; reference-host composition, public schemas, provider
  conformance and the closure matrix remain pending.

- 2026-10-01: candidate `d46c8d10881e6ba811b6c1d5204c9545aa785d37` fast
  check passed in 852 seconds: 11 application suites, 2,679 passed tests and
  33 standard exclusions. Full output:
  `/private/tmp/loopex-m7-d46c8d10-fast-check.log`,
  `sha256:36f2a0b3fd02dd092f36a77b44695158066e69aa1ec528032385cc40b35cfc45`.
  Exact identity is retained separately in
  `/private/tmp/loopex-m7-d46c8d10-fast-check.sha`. This verifies the current
  toolchain development candidate; provider conformance, floor-toolchain checks,
  independent-client proof and the M7 closure matrix remain pending.

## T00 — Prepare the specifications and test fixtures
- [ ] Inventory every affected record, API, tool generation, adapter and protocol.
- [x] Map the 22 accepted contract families to implementation owners and retained/new generations.
- [ ] Join that family inventory to exact payload schemas, path inventories and decoder vectors.
- [ ] Pin schema definitions, digests, compatibility vectors and provider mappings.
- [x] Pin legacy and planned M7 read-definition canonical preimages/digests and the revision-1 literal artifact-read capability table.
- [ ] Create the M7 fixture manifest with exact prompts, budgets, allowed changes and objective results.
- [ ] Assign every operator step and negative scenario to a named test or demonstration.
- [ ] Prepare the indexed closure-evidence scaffold with results marked Pending.
- [ ] Retain the exact historical binaries and session roots needed for migration and rollback.
- [ ] Verify manifest completeness, invalid-manifest rejection and actual instruction/tool-schema costs.
## T01 — Preserve conversation across prompts and restarts
- [x] First add a failing test reproducing the current loss of earlier conversation.
- [x] Project the complete committed conversation into subsequent model requests.
- [x] Join tool calls and results using their run, turn and call identities.
- [x] Normalize provider-facing call IDs and reject collisions or incomplete joins.
- [x] Reset each run’s accounting without deleting conversation or recovery facts.
- [x] Preserve already staged requests unchanged.
- [ ] Test multiple prompts, follow-ups, tools, cancellation, failed runs, restart and uncertain commits.
## T02 — Handle large tool output and bounded artifact reads
- [ ] Prepare bounded excerpts while retaining complete original results.
- [ ] Implement capability checks from the exact frozen tool definitions and literal capability table.
- [x] Implement and test pure exact-generation derivation and retained-binding validation; runtime selection and executor dispatch integration remain pending.
- [ ] Keep replay independent of current host-registry availability.
- [ ] Validate artifact ownership and arguments in the session owner before policy admission; add resolved executor data after approval.
- [ ] Implement 4-KiB range reads, encoded-result limits, offsets, progress and EOF.
- [ ] Add bounded preparation, aggregate excerpt allocation and job-owned transfer accounting.
- [ ] Preserve legacy inline behavior where the complete request fits.
- [ ] Test escaping, Unicode, forged references, cross-session access, digest mismatch, exhaustion, cancellation and recovery.
- [ ] Audit the existing attachment-budget baseline without silently taking on deferred M8 work.
## T03 — Implement host-composed instructions
- [ ] Replace core’s fixed instructions with the accepted host instruction map and rendering.
- [x] Implement pure closed instruction capture, exact rendering and retained-digest validation; preserve legacy fallback bytes through the shared renderer.
- [x] Stage captured v3 instructions with configuration-bound revision-4 provenance and exact system/tool costs; reject substituted configuration/source identities on replay.
- [ ] Keep project and skill resources separately typed and admitted.
- [ ] Capture workspace/environment facts and exact selected tool schemas.
- [ ] Enforce the configured system ceiling and complete serialized-request limit.
- [ ] Implement receipt revision 4, including continuation costs and source/configuration binding.
- [ ] Preserve old receipt decoding.
- [ ] Test admitted, declined, changed and oversized instructions, long paths, restart and exact staged bytes.
- [ ] Prove instructions cannot widen policy or helper authority.
## T04 — Implement configuration, genesis and provider routing
- [x] Implement the shared pure genesis resolver and validator.
- [x] Share the v2 resolver/decoder between creation and replay; pin unchanged transaction bytes and exact normalized byte boundaries.
- [x] Extend that same resolver/decoder with v3 configuration, immutable tool selection and literal artifact-read derivation.
- [x] Validate closed captured configuration, combined metadata byte limits, budget origins and complete system-class tool costs; retain v3 settings through pure replay.
- [x] Integrate v3 creation and configuration-aware live owner staging, including frozen request/receipt identities.
- [x] Support exact-genesis creation, finding duplicates before expanding changed defaults.
- [ ] Implement the closed configuration-file schema and command-line grammar.
- [ ] Implement file/flag precedence, validation and effective-value display.
- [ ] Require explicit conversation bounds in the file, including when flags override them.
- [ ] Retain committed session settings, tool selections, roles and delegation declarations.
- [ ] Allow maintenance settings to change new episodes while preserving already admitted episodes.
- [ ] Implement named provider and credential bindings through the existing custody boundaries.
- [ ] Abandon prepared owners on every post-preparation refusal; retain uncertain cleanup honestly.
- [ ] Test malformed files, duplicate keys, overrides, resume conflicts, missing bindings, changed catalogs and cleanup failures.
- [ ] Prove configuration inspection reads no credentials and starts no runtime or provider call.
## T05 — Update records, protocols and independent clients
- [ ] Implement every new record/request generation before emitting it.
- [ ] Add foreground protocol /3 and daemon protocol /4.
- [ ] Produce complete payload-schema manifests and reproducible digests.
- [ ] Update both servers and the independent Node clients together.
- [ ] Update daemon mutation, capacity, lease and succession inventories.
- [ ] Implement bounded snapshots and events with consistent replay cursors.
- [ ] Preserve numeric domains without JavaScript rounding or narrowing.
- [ ] Test negotiation order, malformed offers, digest mismatches, old clients, authority checks and replay.
- [ ] Verify private thinking, credentials and host-only data never enter public projections.
- [ ] Run the required independent-client workflows.
## T06 — Build the first complete chat workflow
- [ ] Add loopex chat through the existing session/runtime facade.
- [ ] Join explicit configuration, continuity and instructions.
- [ ] Support prompts, status, wait, abort, bounded output and truthful shutdown.
- [ ] Prove two prompts and restart through the built command.
- [ ] Preserve existing ask, durable-run and embedded workflows.
- [ ] Test startup refusal, admission failure, output and cleanup.
- [ ] Later retain the required attended multi-prompt proof.
## T07 — Implement automatic and explicit compaction
- [ ] Select complete eligible conversation groups.
- [ ] Protect open exchanges and their complete native prefixes from compaction or re-rendering.
- [ ] Have the owner select and encode bounded source excerpts; have the model produce the summary.
- [ ] Capture maintenance model, route, instructions, deadlines, origin and targets before dispatch.
- [ ] Distinguish missing summarizer configuration from invalid configuration.
- [ ] Require complete natural termination, valid output, size limits and progress before committing a checkpoint.
- [ ] Implement bounded attempts, refusal records, terminal ordering and standalone compact results.
- [ ] Resolve uncertain checkpoint commits before publication and charge usage once.
- [ ] Test oversized oldest/newest groups, small problematic groups, trailing inputs, omitted content, length stops and non-progress.
- [ ] Inject crashes around preparation, staging, settlement, checkpoint and publication.
- [ ] Prove automatic compaction, explicit compaction and restart preserve the required facts.
## T08 — Implement model selection and private thinking continuation
- [ ] Implement committed per-run model/reasoning configuration and the permitted configure fields.
- [ ] Implement the exact adapter replies, canonical replies and monotonic settlement generations.
- [ ] Implement bounded in-capsule reference expansion, with no artifact substitution or external lookup.
- [ ] Preserve expanded native blocks, strings, ordering, IDs and parsed arguments.
- [ ] Implement continuation accounting, reserves and compaction headroom targets.
- [ ] Implement all nine accepted thinking cells and the separately configured summarizer.
- [ ] Build the native transport bridge: validate final requests after hooks, capture before conversion, and preserve admitted controls and ceilings.
- [ ] Bound raw streaming/parser buffers; implement fatal-error latching, flushing and wakeup.
- [ ] Test the bridge against a local HTTP server before integrating live-provider proofs.
- [ ] Test model switching, crashes, cancellation, malformed replies, overflow, usage accounting and privacy.
- [ ] Complete the seven thinking-round subcases, nine bound subcases and cancellation witness, including their prescribed subsequent prompts.
## T09 — Implement model-originated questions
- [ ] Register the exact question-tool generation without changing old effect definitions.
- [ ] Admit questions through policy; no executor grant or job is created.
- [ ] Implement producer identity, options, text answers, decline and expiry.
- [ ] Atomically settle the interaction, original tool result, response identity and next action.
- [ ] Preserve the existing policy-defer lifecycle.
- [ ] Test denial, deferred policy, large answers, overflow, duplicate/stale responses, cancellation and expiry.
- [ ] Test crashes before and after pending-question and response commits.
- [ ] Prove recovery retains the actual pending question identity.
## T10 — Complete chat controls, pipes and tracing
- [ ] Implement steer, follow-up, answers, decline, wait, interrupt, configure, compact and exit commands.
- [ ] Implement the exact pipe grammar and closed control records.
- [ ] Enforce record limits, bounded input admission, the 256-KiB output queue and control-drain deadline.
- [ ] Implement the unknown-admission resolver using the original transaction identity and proposal.
- [ ] Preserve input ordering while admission is uncertain; do not submit duplicate commands or fenced aborts.
- [ ] Make EOF, incomplete fragments, earlier failures and uncertain cleanup produce the specified outcomes.
- [ ] Implement tracing through flags and files, including enable/disable and owner cleanup.
- [ ] Add the independently draining diagnostic consumer with drop and unconfirmed-delivery accounting.
- [ ] Test PTYs, fragmented pipes, actual question IDs, barriers, slow readers, EOF and signals.
- [ ] Test tracing isolation, redaction, stalled stderr and ask’s JSON output separation.
## T11 — Implement specialized read-only helpers
- [ ] Implement saved roles with exact instructions, models, credentials and finite allowances.
- [ ] Register the opt-in helper tool and immutable read-only tool selection.
- [ ] Add the required read-only runtime/store provenance and effect-intent queries.
- [ ] Implement exact create-result lookup and retain genesis before child creation.
- [ ] Implement parent bindings, catalogs, allowance ledgers, stop records and receipt routing.
- [ ] Implement bounded private codecs, framing checks, writer fencing and reserved completion space.
- [ ] Enforce one unresolved helper per parent while allowing independent parents to progress.
- [ ] Charge attempted reservations conservatively; only the specified pre-effect refusals consume nothing.
- [ ] Implement bounded startup classification of all committed creates, including helpers-disabled startup.
- [ ] Guard existing attachments and settled child sessions against ordinary host mutations.
- [ ] Validate cache coverage, remove refused registrations and handle interrupted publication.
- [ ] Recover completed results and stop unfinished helpers; recovery must never create or re-prompt them.
- [ ] Test read-only authority, nesting refusal, budgets, concurrent parents, cancellation and exhausted-call reopening.
- [ ] Inject faults at every binding, reserve, create, prompt, stop, settlement, receipt and cache boundary.
- [ ] Prove both role demonstrations with unchanged child workspaces and separate/combined usage.
## T12 — Complete ephemeral support
- [ ] Forward accepted instruction, model, reasoning, provider-binding, maintenance, question and trace options.
- [ ] Preserve reusable embedded sessions and buffered transport.
- [ ] Keep questions opt-in and preserve old tool selections.
- [ ] Implement tagged choice, text and decline answers.
- [ ] Consume the question responder only in the one-call API; reject unsupported combinations.
- [ ] Run one monitored responder worker outside the serial owner.
- [ ] Join responder termination before another question or successful cleanup.
- [ ] Test blocked, invalid, failed and late callbacks, cancellation, expiry and cleanup uncertainty.
- [ ] Preserve the existing credential and transport-cleanup guarantees.
- [ ] Complete the attended ephemeral-question witness.
## T13 — Complete coding fixtures and operator instructions
- [ ] Implement the repair fixture and its independent sum assertions.
- [ ] Implement the feature fixture requiring the nil-encoding question.
- [ ] Implement the review fixture with the exact duplicate-fee finding and call chain.
- [ ] Implement the long fixture preserving the required facts through compaction and restart.
- [ ] Implement the trusted fixture wrapper and exact approved test-command policy.
- [ ] Let the agent run approved tests; independently rerun immutable oracles and inspect allowed changes.
- [ ] Pin and execute the maintainer-selected external repository task.
- [ ] Make every V1–V13 instruction runnable, with one owner and evidence slot per step/subcase.
- [ ] Complete the specified human-attended steps with a named operator.
- [ ] Collect previous executions without adding extra model attempts.
## T14 — Implement attempts tracking and evidence validation
- [ ] Implement the canonical, hash-chained attempts index and fsync-before-dispatch.
- [ ] Implement single-writer ownership and safe evidence handoff between machines.
- [ ] Implement all attempt states, verdict classes and legal transitions.
- [ ] Handle missing, corrupted or incomplete evidence as unavailable.
- [ ] Implement pre-dispatch-only continuation without redispatching completed work.
- [ ] Implement suspended-lane abandonment and committed index-head barriers.
- [ ] Enforce causal corrections and independent outage review; a new SHA alone permits no reroll.
- [ ] Add the M7 evidence validator to the existing two check commands.
- [ ] Implement M7 lane selectors while preserving all legacy cases.
- [ ] Test truncation, forks, duplicate writers, interrupted handoff, resume, abandonment, redaction and every verdict route.
## T15 — Prove migration and rollback
- [ ] Upgrade exact settled and unresolved M6 roots without changing staged requests.
- [ ] Prove unknown effects are not redispatched.
- [ ] Observe the actual historical reader against disposable new-format roots.
- [ ] Preserve the existing v0.2.0↔v0.3.0 rollback proof.
- [ ] Add the separate v0.3.0↔M7 proof.
- [ ] Implement access-prevention and complete backup-restore instructions.
- [ ] Restore into an empty root and compare complete manifests.
- [ ] Restore workspace state separately from runtime state.
- [ ] Join automated rollback artifacts to attended restore inspection without rerunning the case.
## T16 — Complete integration and regression checks
- [x] Move M7 to In progress when product work begins.
- [ ] Keep outcome rows linked to actual tests and evidence.
- [ ] Update operator/developer documentation, indexes, compatibility guidance, README, roadmap and changelog.
- [ ] Update verification guidance to the accepted M7 procedures.
- [ ] Run focused unit, property, conformance, fault, security, protocol and CLI tests during development.
- [ ] Run the fast check once per clean integration candidate.
- [ ] Run required selected real-provider, Node, daemon, long-bound and cross-UID lanes.
- [ ] Run changed process-boundary cases thirty times under the prescribed pinned Linux load.
- [ ] Independently review integration changes and fix confirmed defects without weakening checks.
## T17 — Assemble and test the closure candidate
- [ ] Provision both supported toolchains, pinned Node, provider bindings and the legacy Ollama witness.
- [ ] Provision Linux cross-UID support, descriptor limits, retained evidence storage and attendance.
- [ ] Finish all source, fixtures and documentation before committing the tested candidate.
- [ ] Move the candidate to In review with complete proof mappings and Pending evidence slots.
- [ ] Verify main is an ancestor.
- [ ] Count the existing current-toolchain fast check; run the floor-toolchain check.
- [ ] Run the full logical release matrix in its fixed order.
- [ ] Complete every M7 case, subcase and operator evidence join.
- [ ] Retain outputs, manifests, usage, sizes, durations, failures and independent review with digests.
- [ ] Present the exact candidate for the maintainer’s closure decision.
## T18 — Close M7 and merge back into main
- [ ] Obtain explicit closure approval on the tested candidate and evidence.
- [ ] Create the administrative direct child confined to the five permitted paths and regions.
- [ ] Record both tested and administrative identities correctly.
- [ ] Verify confinement and status transitions.
- [ ] Fast-forward main to the administrative closure commit under the maintainer’s integration authority.
- [ ] Push and verify the resulting repository state.
- [ ] Clean up landed worker branches/worktrees; retain m7 through implementation and decide its disposition after closure.
## T19 — Prepare and publish the separately authorized release
- [ ] Select the release label before testing any version-dependent source changes.
- [ ] On the administrative SHA, prove confinement, documentation structure and documentation meaning.
- [ ] Compare tested and administrative source archives using the required complete manifests.
- [ ] Validate modes, paths, source identities and permitted exclusions.
- [ ] Create the authorized annotated tag at the administrative SHA.
- [ ] Push the authorized tag/publication and verify its target.
- [ ] Reuse unchanged-source closure evidence; do not rerun the suite or provider matrix.
The required test inventory includes 28 named M7 cases, their fixed thinking/question subcases, deterministic negative tests, all 13 operator scenarios, the retained legacy release cases, independent Node workflows, process-boundary load tests and both rollback pairs.

## T00 contract inventory

Accepted contracts mapped to implementation owners. This inventory records
required joins; exact payload vectors and fixture manifests remain separate
unchecked T00 obligations. New readers/writers must rejoin these contracts
before a provider demonstration.

| Boundary | Authority | Retained/new generation | Implementation owners | Status |
| --- | --- | --- | --- | --- |
| Conversation and result joins | ADR 0041 | Run/turn/call identity; admitted lineage order; revision-1 normalized IDs | Conversation; SessionState; SessionCoordinator | Implemented; broader boundary vectors remain |
| Tool-output preparation | ADR 0041 | Immutable receipt plus versioned prepared-reference/preparation-state facts and exact source digests | SessionState; SessionCoordinator; ArtifactStore; local executor | Pending |
| Artifact read capability | ADR 0041 | loopex.artifact_read.v1 binding from literal tool-generation table; resolved executor arguments | ToolDefinition; SessionGenesis; local read tool; SessionCoordinator | Pending |
| Instruction envelope | ADR 0042 | Closed version/base/environment/appendix map, exact rendered bytes/digest | SessionGenesis; configuration reducer; host composition | Pending |
| Context receipts | ADRs 0042–0044 | Old revisions 2/3 unchanged; new 4 has mandatory continuation_cost and frozen source bindings | SessionCoordinator; SessionState; ContextAdmission | Nil-continuation and owning-instruction bindings implemented; maintenance/continuation bindings pending |
| Context refusals and failures | ADR 0043 | Old context_admission_refused_v1 preserved; v2 configurable ceiling and new failure union | ContextAdmission; SessionState; protocol projections | Ordinary measured numeric v2 implemented; remaining variants/projections pending |
| Initial session truth | ADRs 0044/0046 | Read v2/v3 genesis; write coordinated closed v3 configuration/tool-selection/policy-defer payload | Runtime.Control; SessionGenesis; SessionState; Store conformance | Pure decoder/replay and host-private v3 creation implemented; reference-host writer and migration proof pending |
| Exact create and provenance | ADR 0046 | Pure resolve/normalize; exact-genesis create/lookup; read-only creation provenance and stable ordinals | Runtime facade; Control; Store adapters/conformance | Pure helpers and live exact create implemented; exact lookup/provenance pending |
| Atomic configuration | ADR 0044 | Settled configure command; immutable selection; captured version/model/bounds/metadata/mapping | SessionState; SessionCoordinator; composition; protocol | Pending |
| Model request | ADR 0044 | Read v1/v2; new v2 local-reference continuation with generic expansion | Model; SessionState; SessionCoordinator; model adapters | v2 nil-continuation writer/read compatibility implemented; expansion pending |
| Model reply and settlement | ADR 0044 | Bounded reply v3; model_attempt_settled_v3; atomic reply/continuation/accounting | Model; ProviderAttempt; SessionState; adapters | Pending |
| Thinking mappings | ADR 0044 | Fixed nine registered cells, native block fidelity, frozen-prefix exchange and canonical conversion | ReqLLM mapping/transport; SessionCoordinator | Pending |
| Maintenance and compaction | ADR 0043/0044 | Captured maintenance configuration, immutable checkpoint and strategy revision 3, source_excerpted | SessionState; SessionCoordinator; ContextAdmission; host startup | Pending |
| Question lifecycle | ADR 0045 | model_tool/policy_defer producer; bounded choice/text/decline; atomic disposition/result | Interaction; SessionState; SessionCoordinator; host responder | Pending |
| Helper durable ownership | ADR 0046 | Bounded role/catalog bindings; reservation/allowance/monotonic-stop facts; derived job-index v1 | Host helper adapter; Runtime queries; Store; local executor | Pending |
| Host provider bindings | ADR 0048 | Explicit admitted routes and credential references through existing custody boundaries | Composition; ReqLLM provider route/custody; helper adapter | Pending |
| Host configuration grammar | ADR 0049 | Closed file/flag grammar, exact precedence, role selections, safe inspect and trace options | CLI; composition options; host renderer | Pending |
| Foreground and daemon wire | ADR 0044 coordinated contract | Foreground /3 and daemon /4; complete schema digests/vectors and negotiation | Protocol; AppServer; daemon servers; independent Node clients | Pending |
| Public projection | ADRs 0043–0046/0049 | Versioned snapshots/events; bounded numbers/cursors; allowlisted configuration and maintenance | SessionState; protocol; AppServer; daemon; clients | Pending |
| Ephemeral entry points | ADRs 0042–0045/0048/0049 | Combined closed startup options; one-call responder consumed locally; joined termination | Ephemeral.Options/Preflight/Bootstrap/SessionOwner; facade | Pending |
| Execution evidence | M7 technical acceptance contract | Fixed fixture/operator manifest; Pending scaffold; hash-chained single-writer attempts and fsync barriers | mix loopex.m7_evidence; release runner; PTY driver; evidence files | Pending |
| Upgrade and rollback | M7 compatibility contract | Exact retained M6 artifact/root fixtures; retain old rollback pair and add distinct M7 pair | rollback lane/scripts; Store recovery; operator instructions | Pending |
