# M7 Implementation Tasks

Execution checklist supplied by the maintainer. The accepted
[plan](../plans/M7.md#concept) and its
[technical companion](../plans/M7-technical.md#technical-depth) govern scope
and proof obligations. This checklist records work; it introduces no decisions.
Part of the [evidence index](README.md).

## Current work

- Done: reproduce cross-run conversation loss with the real session-owner path
  and a scripted model in `apps/loopex/test/agent_loop_test.exs`.
- Running: T00 contract/fixture inventory and T01 continuity implementation.
- Remaining: all unchecked tasks below. Closure, main integration and release
  retain their explicit maintainer decision gates.

## Development observations

- 2026-10-01: the focused second-prompt regression executed one test and failed:
  the next request contains only the new prompt. This is a development red,
  not closure evidence. No provider call was made.
- T01 added subtasks: retain admission order through replay; choose lineage
  validation by the staged record/receipt generation; join results by complete
  run/turn/call identity; preserve old staged requests and old receipt decoders.

## T00 — Prepare the specifications and test fixtures
- [ ] Inventory every affected record, API, tool generation, adapter and protocol.
- [ ] Pin schema definitions, digests, compatibility vectors and provider mappings.
- [ ] Create the M7 fixture manifest with exact prompts, budgets, allowed changes and objective results.
- [ ] Assign every operator step and negative scenario to a named test or demonstration.
- [ ] Prepare the indexed closure-evidence scaffold with results marked Pending.
- [ ] Retain the exact historical binaries and session roots needed for migration and rollback.
- [ ] Verify manifest completeness, invalid-manifest rejection and actual instruction/tool-schema costs.
## T01 — Preserve conversation across prompts and restarts
- [x] First add a failing test reproducing the current loss of earlier conversation.
- [ ] Project the complete committed conversation into subsequent model requests.
- [ ] Join tool calls and results using their run, turn and call identities.
- [ ] Normalize provider-facing call IDs and reject collisions or incomplete joins.
- [ ] Reset each run’s accounting without deleting conversation or recovery facts.
- [ ] Preserve already staged requests unchanged.
- [ ] Test multiple prompts, follow-ups, tools, cancellation, failed runs, restart and uncertain commits.
## T02 — Handle large tool output and bounded artifact reads
- [ ] Prepare bounded excerpts while retaining complete original results.
- [ ] Implement capability checks from the exact frozen tool definitions and literal capability table.
- [ ] Keep replay independent of current host-registry availability.
- [ ] Validate artifact ownership and arguments in the session owner before policy admission; add resolved executor data after approval.
- [ ] Implement 4-KiB range reads, encoded-result limits, offsets, progress and EOF.
- [ ] Add bounded preparation, aggregate excerpt allocation and job-owned transfer accounting.
- [ ] Preserve legacy inline behavior where the complete request fits.
- [ ] Test escaping, Unicode, forged references, cross-session access, digest mismatch, exhaustion, cancellation and recovery.
- [ ] Audit the existing attachment-budget baseline without silently taking on deferred M8 work.
## T03 — Implement host-composed instructions
- [ ] Replace core’s fixed instructions with the accepted host instruction map and rendering.
- [ ] Keep project and skill resources separately typed and admitted.
- [ ] Capture workspace/environment facts and exact selected tool schemas.
- [ ] Enforce the configured system ceiling and complete serialized-request limit.
- [ ] Implement receipt revision 4, including continuation costs and source/configuration binding.
- [ ] Preserve old receipt decoding.
- [ ] Test admitted, declined, changed and oversized instructions, long paths, restart and exact staged bytes.
- [ ] Prove instructions cannot widen policy or helper authority.
## T04 — Implement configuration, genesis and provider routing
- [ ] Implement the shared pure genesis resolver and validator.
- [ ] Support exact-genesis creation, finding duplicates before expanding changed defaults.
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
