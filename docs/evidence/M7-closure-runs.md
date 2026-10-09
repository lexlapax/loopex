# M7 closure runs

This indexed scaffold reserves evidence for the M7 coding-agent proof. Every
future identity, result and retained-output digest is `Pending`. It claims no
candidate, successful run, review, acceptance or closure. Back to the
[evidence index](README.md).

The [accepted plan](../plans/M7.md#concept) and its
[evidence requirements](../plans/M7-technical.md#technical-plan-evidence)
own scope. The [milestone guide](../developer/milestones.md#concept-milestones-close)
and [verification stages](../developer/verification.md#concept-verification-stages)
own the closure procedure. Complete immutable outputs remain outside the
repository. Record measured durations and actual source identities, including
failed attempts; unavailable evidence is never PASS.

The committed execution manifest in `test/fixtures/m7/manifest.json` fixes
the step and case keys below, one row each; `mix loopex.m7_evidence` fails
when a key is missing here. Profile rows and known earlier-attempt rows are
still to be enumerated before the tested candidate, as an ordinary
implementation change, not an administrative fill.

## Candidate and source identity

| Field | Value |
| --- | --- |
| Tested implementation SHA | Pending |
| Clean source and milestone-branch identity | Pending |
| `main` ancestry before matrix, packet presentation and administrative child | Pending |
| Source `VERSION` and source identity | Pending |
| Candidate inventory and digest | Pending |
| Retained-output root reference | Pending |
| Logical matrix identity and complete invocation/attempts-index references and SHA-256 | Pending |
| Pre-dispatch continuation validation and unchanged archive-manifest digest, if used | Pending |
| Run platform, architecture and complete toolchain pins | Pending |
| Maintainer closure disposition reference | Pending |
| Administrative closure identity locator | Pending |

The tested implementation commit is the source the matrix and independent
review inspect. Its administrative direct child records the maintainer's
decision and fills only predeclared values, within the
[five-path confinement rule](../developer/milestones-technical.md#technical-milestones-confinement).
The administrative identity is located through the register's Closed
transition and any separately authorized tag; this page cannot name its own
commit. This scaffold changes neither milestone status nor progress rows.

## Closure matrix

Run the matrix once from the clean tested implementation SHA. The current-pair
fast check may be its existing CI run or a retained complete local run on that
exact SHA. Do not run it again for the same bytes. The full release check
includes attendance and Linux cross-UID proof; a selection-only or
closure-incomplete result cannot satisfy it. Use the existing
[commands and build isolation](../developer/milestones-technical.md#technical-milestones-close).
No release label, provider budget or new execution command is selected here.
M7's accepted pre-dispatch continuation rule preserves one logical matrix;
it does not retry a started case. Record every invocation and its complete
attempts index under the plan's fixed disposition rules.

| Required run | Source/run identity | Platform, architecture and toolchain | Result and measured duration | Complete retained-output reference | SHA-256 |
| --- | --- | --- | --- | --- | --- |
| Current-pair `bash scripts/check.sh`, existing exact-candidate CI or local evidence | Pending | Pending | Pending | Pending | Pending |
| Floor-pair `bash scripts/check.sh`, absolute pair-specific build root and `MIX_BUILD_PATH` removed | Pending | Pending | Pending | Pending | Pending |
| Current-pair full `bash scripts/check-release.sh`, including attended and Linux cross-UID lanes | Pending | Pending | Pending | Pending | Pending |

## Fresh-source archive and build

Retain the exact NUL-delimited tested archive manifest outside its fresh
extraction, using the
[canonical archive-extraction rule](../developer/milestones-technical.md#technical-milestones-archive-extraction)
and repository-owned `scripts/source-archive-manifest.sh`. Reject malformed
or duplicate records and verify the complete unexcluded kind/mode/path
projection against the independent source tree. This is tested-source
evidence. Administrative archive comparison and other pre-tag proofs run
later under separate release authorization and belong to retained tag proof,
not a second closure matrix or an extra evidence-page commit.

| Field | Value |
| --- | --- |
| Tested archive source SHA, extraction identity and source identity | Pending |
| Exact tested manifest retained-output reference | Pending |
| Exact tested manifest SHA-256 | Pending |
| Manifest grammar, duplicate/path/mode and independent source-tree comparison result | Pending |
| Comparison report retained-output reference and SHA-256 | Pending |
| Fresh build platform/toolchain/dependency and artifact identities | Pending |
| Fresh build result and measured duration | Pending |
| Fresh build complete output reference and SHA-256 | Pending |

## Required release lanes and additional platform proof

The [verification selection contract](../developer/verification.md#concept-verification-selection)
retains the eleven existing provider cases and Node, long-bound and Linux
cross-UID lanes. M7 adds its plan-required provider and operator cases; their
complete fixed ownership map is pending below. Shared case evidence is
referenced once and is never re-executed merely to populate another row.

| Required evidence | Exact case/run/source identity and population | Platform/toolchain/provider pins | Verdict and measured duration | Retained-output reference | SHA-256 |
| --- | --- | --- | --- | --- | --- |
| Provider 1, attended pinned Git skill workflow | Pending | Pending | Pending | Pending | Pending |
| Provider 2, attended coding task | Pending | Pending | Pending | Pending | Pending |
| Provider 3, response identity and usage | Pending | Pending | Pending | Pending | Pending |
| Provider 4, app-server workflow | Pending | Pending | Pending | Pending | Pending |
| Provider 5, model boundary | Pending | Pending | Pending | Pending | Pending |
| Provider 6, killed-tree receipt recovery | Pending | Pending | Pending | Pending | Pending |
| Provider 7, canonical session request | Pending | Pending | Pending | Pending | Pending |
| Provider 8, daemon socket workflow | Pending | Pending | Pending | Pending | Pending |
| Provider 9, Node takeover | Pending | Pending | Pending | Pending | Pending |
| Provider 10, local Ollama one-shot | Pending | Pending | Pending | Pending | Pending |
| Provider 11, hosted ephemeral embedding | Pending | Pending | Pending | Pending | Pending |
| Independent Node clients and both complete current protocol manifests/vectors | Pending | Pending | Pending | Pending | Pending |
| Long-bound proofs, including provider transport drain | Pending | Pending | Pending | Pending | Pending |
| Linux cross-UID proof with actual distinct-user identity | Pending | Pending | Pending | Pending | Pending |
| M7 unattended real-provider cases, owning lane `m7-provider` | Pending | Pending | Pending | Pending | Pending |
| M7 attended cases, owning lane `m7-operator` | Pending | Pending | Pending | Pending | Pending |
| Current-format backup/restore and unknown-effect nonredispatch | Pending | Pending | Pending | Pending | Pending |
| Darwin physical progress/output ownership, both supported pairs | Pending | Pending | Pending | Pending | Pending |
| Linux physical progress/output ownership, both supported pairs | Pending | Pending | Pending | Pending | Pending |
| Linux touched executor OS-boundary cases under pinned load, thirty runs/four cores | Pending | Pending | Pending | Pending | Pending |
| Linux touched provider OS-boundary cases under pinned load, thirty runs/four cores | Pending | Pending | Pending | Pending | Pending |

Pinned-load selection must identify the actually touched cases and preserve
the existing load, run deadlines and no-failure/no-hang criteria. Record full
case populations, exclusions, skips and invalid cases with their governing
dispositions. Preserve failed originals and first-failure records. No retry,
filter, fake real-path substitute or timeout increase is authorized here.
The [pre-1.0 disposition](../developer/agent-context-map.md#disposition-pre1-current-contract-2026-10-02)
retires old-client/old-root migration and cross-version rollback evidence;
it preserves current-format restart/replay, authority, cleanup and restore.

## Outcome-to-evidence map

Each result must name the tested source, actual execution records and exact
proof. These slots do not replace the plan's final Proved progress rows.

| Outcome | Implementation/test and execution identities | Objective verdict, measurements and limits | Retained-output references | SHA-256 digests |
| --- | --- | --- | --- | --- |
| 1, continuity across prompts and restart | Pending | Pending | Pending | Pending |
| 2, staged host instructions, provenance and authority negatives | Pending | Pending | Pending | Pending |
| 3, automatic/standalone compaction, raw history and fault truth | Pending | Pending | Pending | Pending |
| 4, provider/model/reasoning, thinking continuation and A→B→A | Pending | Pending | Pending | Pending |
| 5, model questions, exact answers, recovery and ephemeral host answer | Pending | Pending | Pending | Pending |
| 6, terminal/piped conversation and explicit configuration | Pending | Pending | Pending | Pending |
| 7, serial read-only helpers, accounting, policy and recovery | Pending | Pending | Pending | Pending |
| 8, repair/feature/review/long/external coding tasks | Pending | Pending | Pending | Pending |
| 9, named operator validation and retained objective observations | Pending | Pending | Pending | Pending |

## Fixture, profile and provider pins

| Field | Value |
| --- | --- |
| Complete execution manifest path, bytes and SHA-256 | Pending |
| Literal case IDs, owning lanes, ordered prompts/actions and oracle inventory | Pending |
| Fixture/workspace source inventories and digests | Pending |
| Immutable prompt, runner, oracle and allowed-diff digests | Pending |
| Case-specific declared bounds and counted execution-record slots | Pending |
| Immutable A/B provider/model/mode and mapping/renderer pins | Pending |
| Registered thinking-cell witness inventory and owning execution slots | Pending |
| Credential-variable-name-set pin and credential-free routing metadata | Pending |
| Selected-name redaction self-test result, retained output and SHA-256 | Pending |
| External task immutable pre-attempt specification, base SHA and allowed paths | Pending |
| External pin UTC timestamp, complete bytes/reference and SHA-256 | Pending |
| Ordered pre-dispatch pin log, completion recheck, reference and SHA-256 | Pending |
| Final demonstrated profile-key inventory | Pending |

The current catalog is `test/fixtures/m7/manifest.json`; its source verifier
explicitly distinguishes four base fixtures from the pending complete
execution manifest. Before candidate commitment, enumerate every demonstrated
profile key here with exact resolved roots/catalogs, full instruction/tool/
environment/role preimages and digests, and measured system-class estimate
strictly below 1,000 tokens. All post-run values remain Pending until observed.
Generic profile placeholders cannot prove that literal inventory complete.
Never store credential values in this record.

## operator_step_evidence

| Required inventory or join | Value |
| --- | --- |
| Complete V1–V13 step/subcase key set from committed execution manifest | Pending |
| Per-key owning case, lane/test ID, oracle, profile and execution-record slot | Pending |
| Exact mandatory attended/automated classification validation | Pending |
| Per-key operator identity, attendance authority and recorded answers | Pending |
| Per-key source, session/run/child/attempt identities and pin digests | Pending |
| Per-key expected/actual result, objective assertion and cleanup result | Pending |
| Per-key complete execution record/transcript reference and SHA-256 | Pending |
| One-to-one coverage and no duplicate/conflicting attempt-reference result | Pending |

The [accepted operator evidence specification](../plans/M7-technical.md#technical-plan-operator-validation)
requires one final row per manifest step/subcase key, including trace flag/file/
JSON subcases and separately classified positive/fault paths. The rows below
are the committed manifest's exact keys and owners; only their Pending cells
are filled from retained execution records. The mandatory attended subset remains governed by the plan.
Automated answers cannot stand in for a named person's validation. Retired
cross-version steps are not passes; preserve current-format restore coverage.

<!-- generated: step rows -->

| Key | Owner | Operator and attendance authority | Source, attempt and session identities | Expected/actual result and objective assertion | Retained record reference | SHA-256 |
| --- | --- | --- | --- | --- | --- | --- |
| `V1.1` | `case:m7.baseline.ask` | Pending | Pending | Pending | Pending | Pending |
| `V1.2` | `case:m7.baseline.ask` | Pending | Pending | Pending | Pending | Pending |
| `V1.3.ask` | `case:m7.baseline.ask` | Pending | Pending | Pending | Pending | Pending |
| `V1.3.durable` | `case:m7.baseline.durable` | Pending | Pending | Pending | Pending | Pending |
| `V1.4` | `case:m7.baseline.durable` | Pending | Pending | Pending | Pending | Pending |
| `V1.5` | `case:m7.baseline.durable` | Pending | Pending | Pending | Pending | Pending |
| `V2.1` | `case:m7.repair` | Pending | Pending | Pending | Pending | Pending |
| `V2.2` | `case:m7.repair` | Pending | Pending | Pending | Pending | Pending |
| `V2.3` | `case:m7.repair` | Pending | Pending | Pending | Pending | Pending |
| `V2.4` | `case:m7.repair` | Pending | Pending | Pending | Pending | Pending |
| `V2.5` | `case:m7.repair` | Pending | Pending | Pending | Pending | Pending |
| `V2.6.answer` | `case:m7.pipe-answer` | Pending | Pending | Pending | Pending | Pending |
| `V2.6.decline` | `case:m7.pipe-answer` | Pending | Pending | Pending | Pending | Pending |
| `V3.1` | `case:m7.instructions.admitted` | Pending | Pending | Pending | Pending | Pending |
| `V3.2` | `case:m7.instructions.admitted` | Pending | Pending | Pending | Pending | Pending |
| `V3.3` | `case:m7.instructions.declined` | Pending | Pending | Pending | Pending | Pending |
| `V3.4` | `case:m7.instructions.changed` | Pending | Pending | Pending | Pending | Pending |
| `V3.5` | `test:apps/loopex/test/configured_session_test.exs#captured host sections cannot replace a denying policy with model-declared permission` | Pending | Pending | Pending | Pending | Pending |
| `V4.1` | `case:m7.steer-barrier` | Pending | Pending | Pending | Pending | Pending |
| `V4.2` | `case:m7.steer-barrier` | Pending | Pending | Pending | Pending | Pending |
| `V4.3` | `case:m7.steer-barrier` | Pending | Pending | Pending | Pending | Pending |
| `V4.4` | `case:m7.steer-barrier` | Pending | Pending | Pending | Pending | Pending |
| `V4.5` | `test:apps/loopex/test/input_algebra_test.exs#a steer that arrives after its run is terminal commits unapplied with a reason and is never promoted` | Pending | Pending | Pending | Pending | Pending |
| `V5.1` | `case:m7.feature` | Pending | Pending | Pending | Pending | Pending |
| `V5.2` | `case:m7.feature` | Pending | Pending | Pending | Pending | Pending |
| `V5.3` | `case:m7.question-restart` | Pending | Pending | Pending | Pending | Pending |
| `V5.4.cancel` | `test:apps/loopex/test/configured_session_test.exs#aborting a pending model question settles its slot and preserves a cancelled result` | Pending | Pending | Pending | Pending | Pending |
| `V5.4.decline` | `test:apps/loopex_cli/test/chat_pty_test.exs#terminal declines the actual pending question without dispatching an executor effect` | Pending | Pending | Pending | Pending | Pending |
| `V5.4.denied` | `test:apps/loopex/test/configured_session_test.exs#the admitted question generation never dispatches an executor effect` | Pending | Pending | Pending | Pending | Pending |
| `V5.4.expiry` | `test:apps/loopex/test/configured_session_test.exs#a live question deadline settles once and rejects a late answer after recovery` | Pending | Pending | Pending | Pending | Pending |
| `V5.5.authority` | `test:apps/loopex/test/interaction_lifecycle_test.exs#a committed answer re-enters host policy and only an allow result mints a grant before dispatch` | Pending | Pending | Pending | Pending | Pending |
| `V5.5.inactivity` | `test:apps/loopex/test/configured_session_test.exs#model questions settle exact text, choice and decline in one transaction` | Pending | Pending | Pending | Pending | Pending |
| `V5.6.absent` | `test:apps/loopex_composition/test/ephemeral_model_integration_test.exs#one-shot questions without a responder deny before waiting and preserve ordinary effects` | Pending | Pending | Pending | Pending | Pending |
| `V5.6.cancel` | `test:apps/loopex_composition/test/ephemeral_api_test.exs#stop aborts an unanswered interaction and proves its terminal` | Pending | Pending | Pending | Pending | Pending |
| `V5.6.positive` | `case:m7.ephemeral-question` | Pending | Pending | Pending | Pending | Pending |
| `V6.1` | `case:m7.long` | Pending | Pending | Pending | Pending | Pending |
| `V6.2.long` | `case:m7.long` | Pending | Pending | Pending | Pending | Pending |
| `V6.2.range` | `test:apps/loopex_composition/test/artifact_range_executor_test.exs#a mixed source of at least 16 KiB reads exactly through EOF in 4 KiB ranges` | Pending | Pending | Pending | Pending | Pending |
| `V6.3` | `case:m7.long` | Pending | Pending | Pending | Pending | Pending |
| `V6.4` | `case:m7.long` | Pending | Pending | Pending | Pending | Pending |
| `V6.5.input-only` | `test:apps/loopex/test/conversation_test.exs#terminal input-only runs keep failed and cancelled prompts eligible` | Pending | Pending | Pending | Pending | Pending |
| `V6.5.metadata` | `test:apps/loopex/test/compaction_source_test.exs#an oversized assistant and all its results remain one covered unit` | Pending | Pending | Pending | Pending | Pending |
| `V6.5.positive` | `case:m7.oversized-source` | Pending | Pending | Pending | Pending | Pending |
| `V6.5.size` | `test:apps/loopex/test/maintenance_episode_recovery_test.exs#an automatic episode with no fitting excerpt ends durably before dispatch` | Pending | Pending | Pending | Pending | Pending |
| `V6.6.ambiguous` | `test:apps/loopex/test/maintenance_request_staging_test.exs#only a proven not-dispatched first attempt permits the exact retained retry` | Pending | Pending | Pending | Pending | Pending |
| `V6.6.atomic-commit` | `test:apps/loopex/test/maintenance_request_staging_test.exs#checkpoint and event commit together while exact raw facts remain readable` | Pending | Pending | Pending | Pending | Pending |
| `V6.6.missing-route` | `test:apps/loopex_composition/test/durable_bindings_startup_test.exs#missing ordinary or maintenance routes and local bindings refuse before consumption` | Pending | Pending | Pending | Pending | Pending |
| `V6.6.positive` | `case:m7.long` | Pending | Pending | Pending | Pending | Pending |
| `V6.6.summarizer-change` | `test:apps/loopex/test/standalone_compact_projection_test.exs#standalone succession reuses capture before consulting new settings, clock or work` | Pending | Pending | Pending | Pending | Pending |
| `V6.7` | `case:m7.cross-provider-maintenance` | Pending | Pending | Pending | Pending | Pending |
| `V7.1` | `case:m7.provider-switch` | Pending | Pending | Pending | Pending | Pending |
| `V7.2` | `case:m7.provider-switch` | Pending | Pending | Pending | Pending | Pending |
| `V7.3.barriers` | `test:apps/loopex_cli/test/chat_workflow_test.exs#actual model progress reaches both channels before settlement without releasing wait` | Pending | Pending | Pending | Pending | Pending |
| `V7.3.near-limit` | `test:apps/loopex/test/maintenance_episode_recovery_test.exs#thinking preparation continues past a hard-limit fit until the captured targets fit` | Pending | Pending | Pending | Pending | Pending |
| `V7.3.open-exchange-restart` | `test:apps/loopex/test/configured_session_test.exs#owner recovery reuses frozen project content without the original host manifest` | Pending | Pending | Pending | Pending | Pending |
| `V7.3.positive` | `case:m7.thinking-rounds` | Pending | Pending | Pending | Pending | Pending |
| `V7.3.split-events` | `test:apps/loopex_llm_reqllm/test/native_stream_test.exs#every byte boundary uses the pinned parser and exact native stop establishes completion` | Pending | Pending | Pending | Pending | Pending |
| `V7.4` | `case:m7.provider-switch` | Pending | Pending | Pending | Pending | Pending |
| `V7.5.in-run-change` | `test:apps/loopex/test/configured_session_test.exs#live configure refusal while a provider is active remains stable after it settles` | Pending | Pending | Pending | Pending | Pending |
| `V7.5.missing-binding` | `test:apps/loopex_cli/test/chat_resume_configuration_test.exs#missing retained model route refuses and abandons, without credential reads` | Pending | Pending | Pending | Pending | Pending |
| `V7.5.unsupported-level` | `test:apps/loopex_cli/test/chat_configuration_test.exs#configure preparation refuses host metadata, missing routes and unsupported reasoning` | Pending | Pending | Pending | Pending | Pending |
| `V7.6.canaries` | `test:apps/loopex_composition/test/native_model_switch_test.exs#native private continuation stays out of a real tool-created artifact across reopen` | Pending | Pending | Pending | Pending | Pending |
| `V7.6.conflicting-limits` | `test:apps/loopex_llm_reqllm/test/native_request_test.exs#each manual thinking budget must fit strictly below the committed output limit` | Pending | Pending | Pending | Pending | Pending |
| `V7.6.limits` | `test:apps/loopex/test/configured_session_test.exs#aggregate continuation overflow records an unavailable projection before another attempt` | Pending | Pending | Pending | Pending | Pending |
| `V7.6.missing-state` | `test:apps/loopex/test/configured_session_test.exs#required continuation refuses v2 and malformed v3 before tools or reported accounting` | Pending | Pending | Pending | Pending | Pending |
| `V7.6.open-exchange-compaction` | `test:apps/loopex/test/maintenance_episode_admission_test.exs#no episode overlaps an open exchange, interaction, abort or provider/effect stage` | Pending | Pending | Pending | Pending | Pending |
| `V7.6.summary-progress` | `test:apps/loopex_composition/test/native_model_switch_test.exs#verified native summary stays progress and out of the next canonical request after reopen` | Pending | Pending | Pending | Pending | Pending |
| `V7.7.bound` | `case:m7.thinking-bound` | Pending | Pending | Pending | Pending | Pending |
| `V7.7.cancel` | `case:m7.thinking-cancel` | Pending | Pending | Pending | Pending | Pending |
| `V8.1` | `case:m7.review` | Pending | Pending | Pending | Pending | Pending |
| `V8.2` | `case:m7.review` | Pending | Pending | Pending | Pending | Pending |
| `V8.3` | `case:m7.review` | Pending | Pending | Pending | Pending | Pending |
| `V8.4` | `case:m7.review` | Pending | Pending | Pending | Pending | Pending |
| `V8.5.failure` | `test:apps/loopex_composition/test/delegation_run_ledger_test.exs#a created child never prompted settles failed at zero and refunds its reservation` | Pending | Pending | Pending | Pending | Pending |
| `V8.5.bound` | `test:apps/loopex_composition/test/delegation_helper_test.exs#count and token exhaustion refuse before any reservation and a new run reopens` | Pending | Pending | Pending | Pending | Pending |
| `V8.5.cancel` | `test:apps/loopex_composition/test/delegation_helper_test.exs#cancelling the parent stops its child and confirms cleanup` | Pending | Pending | Pending | Pending | Pending |
| `V8.6` | `test:apps/loopex_composition/test/delegation_recovery_test.exs#an exhausted serial child allowance survives restart and the parent reopens` | Pending | Pending | Pending | Pending | Pending |
| `V8.7` | `test:apps/loopex_composition/test/delegation_child_creation_test.exs#only authored enabled roles in the retained catalog admit` | Pending | Pending | Pending | Pending | Pending |
| `V9.1` | `case:m7.policy-denial` | Pending | Pending | Pending | Pending | Pending |
| `V9.2` | `case:m7.interrupt` | Pending | Pending | Pending | Pending | Pending |
| `V9.3` | `test:apps/loopex_reference_client/test/end_to_end_recovery_test.exs#every acknowledged fact survives the restart` | Pending | Pending | Pending | Pending | Pending |
| `V9.4` | `case:m7.daemon-detach` | Pending | Pending | Pending | Pending | Pending |
| `V9.5` | `test:apps/loopex_reference_client/test/end_to_end_recovery_test.exs#an effect without a durable receipt becomes outcome_unknown and is not blindly retried` | Pending | Pending | Pending | Pending | Pending |
| `V10.1` | `case:m7.external` | Pending | Pending | Pending | Pending | Pending |
| `V10.2` | `case:m7.external` | Pending | Pending | Pending | Pending | Pending |
| `V10.3` | `case:m7.external` | Pending | Pending | Pending | Pending | Pending |
| `V10.4` | `case:m7.external` | Pending | Pending | Pending | Pending | Pending |
| `V10.5` | `case:m7.external` | Pending | Pending | Pending | Pending | Pending |
| `V11.1.file` | `case:m7.trace.file` | Pending | Pending | Pending | Pending | Pending |
| `V11.1.flag` | `case:m7.trace.flag` | Pending | Pending | Pending | Pending | Pending |
| `V11.2.file` | `case:m7.trace.file` | Pending | Pending | Pending | Pending | Pending |
| `V11.2.flag` | `case:m7.trace.flag` | Pending | Pending | Pending | Pending | Pending |
| `V11.3.invalid` | `test:apps/loopex_cli/test/ask_options_test.exs#trace controls reject conflicts, unsupported selectors and limits even when disabled` | Pending | Pending | Pending | Pending | Pending |
| `V11.3.override` | `test:apps/loopex_cli/test/chat_workflow_test.exs#no-trace overrides an enabled file through actual chat startup` | Pending | Pending | Pending | Pending | Pending |
| `V11.4.json` | `test:apps/loopex_cli/test/ask_integration_test.exs#startup trace reaches stderr while a real command keeps JSON stdout clean` | Pending | Pending | Pending | Pending | Pending |
| `V11.5.file` | `case:m7.trace.file` | Pending | Pending | Pending | Pending | Pending |
| `V11.5.flag` | `case:m7.trace.flag` | Pending | Pending | Pending | Pending | Pending |
| `V11.5.json` | `case:m7.trace.json` | Pending | Pending | Pending | Pending | Pending |
| `V12.1` | `case:m7.trace.file` | Pending | Pending | Pending | Pending | Pending |
| `V12.2` | `case:m7.trace.flag` | Pending | Pending | Pending | Pending | Pending |
| `V12.3` | `test:apps/loopex_cli/test/config_file_test.exs#JSON and authored schema refusals happen before relative resolution` | Pending | Pending | Pending | Pending | Pending |
| `V12.4` | `test:apps/loopex_cli/test/chat_resume_configuration_test.exs#restart preserves exact settings and ignores changed file instructions, tools and helper defaults` | Pending | Pending | Pending | Pending | Pending |
| `V12.5.in-flight` | `test:apps/loopex/test/session_configuration_admission_test.exs#active work, interactions, aborts and unresolved effects cannot be configured` | Pending | Pending | Pending | Pending | Pending |
| `V12.5.legacy-defaults` | `test:apps/loopex_cli/test/ask_ephemeral_test.exs#legacy one-shot defaults leave model, bounds and questions to the ephemeral profile` | Pending | Pending | Pending | Pending | Pending |
| `V13.1` | `case:m7.restore` | Pending | Pending | Pending | Pending | Pending |
| `V13.2` | `case:m7.rollback` | Pending | Pending | Pending | Pending | Pending |
| `V13.3` | `retired:docs/developer/agent-context-map.md#disposition-pre1-current-contract-2026-10-02` | Pending | Pending | Pending | Pending | Pending |
| `V13.4` | `case:m7.restore` | Pending | Pending | Pending | Pending | Pending |
| `V13.5` | `case:m7.restore` | Pending | Pending | Pending | Pending | Pending |
| `V13.6` | `case:m7.restore` | Pending | Pending | Pending | Pending | Pending |

<!-- end generated: step rows -->

## Case results and earlier attempts

| Required inventory or observation | Value |
| --- | --- |
| Final case-key set, execution-record slots and manifest digest | Pending |
| Per-case attempt/session/run/child identities and actual provider witnesses | Pending |
| Per-case objective outcome, allowed diff and independent oracle result | Pending |
| Per-case measured duration/turns/tokens/maximum reply and maintenance/helper totals | Pending |
| Per-case verdict, failed assertion, cause classification and cleanup | Pending |
| Per-case complete record/transcript/diff/check references and SHA-256 | Pending |
| Enumerated known earlier candidate/case/attempt identities and verdicts | Pending |
| Per-earlier-attempt diagnosis, disposition, causal correction and independent review | Pending |
| Complete earlier-attempt records/reports and SHA-256 digests | Pending |

Before commitment enumerate every known prior attempt and final case in
literal rows. Preserve the plan's distinct `product_failure`,
`model_nonconformance`, `evidence_unavailable` and `environment_failure`
dispositions, separate from its mechanical results. A new candidate
alone does not authorize replacement of a dispatched case. References shared
by multiple outcomes or operator steps denote the same execution, not an
additional paid attempt. This scaffold supplies no spending authorization.

<!-- generated: case rows -->

| Case | Lane | Attempt, session, run and child identities | Mechanical result and verdict | Retained record reference | SHA-256 |
| --- | --- | --- | --- | --- | --- |
| `m7.baseline.ask` | `m7-operator` | Pending | Pending | Pending | Pending |
| `m7.baseline.durable` | `m7-operator` | Pending | Pending | Pending | Pending |
| `m7.trace.flag` | `m7-operator` | Pending | Pending | Pending | Pending |
| `m7.trace.file` | `m7-operator` | Pending | Pending | Pending | Pending |
| `m7.trace.json` | `m7-operator` | Pending | Pending | Pending | Pending |
| `m7.repair` | `m7-operator` | Pending | Pending | Pending | Pending |
| `m7.instructions.admitted` | `m7-operator` | Pending | Pending | Pending | Pending |
| `m7.steer-barrier` | `m7-operator` | Pending | Pending | Pending | Pending |
| `m7.feature` | `m7-operator` | Pending | Pending | Pending | Pending |
| `m7.question-restart` | `m7-operator` | Pending | Pending | Pending | Pending |
| `m7.ephemeral-question` | `m7-operator` | Pending | Pending | Pending | Pending |
| `m7.long` | `m7-operator` | Pending | Pending | Pending | Pending |
| `m7.oversized-source` | `m7-operator` | Pending | Pending | Pending | Pending |
| `m7.provider-switch` | `m7-operator` | Pending | Pending | Pending | Pending |
| `m7.thinking-rounds` | `m7-operator` | Pending | Pending | Pending | Pending |
| `m7.review` | `m7-operator` | Pending | Pending | Pending | Pending |
| `m7.policy-denial` | `m7-operator` | Pending | Pending | Pending | Pending |
| `m7.interrupt` | `m7-operator` | Pending | Pending | Pending | Pending |
| `m7.external` | `m7-operator` | Pending | Pending | Pending | Pending |
| `m7.restore` | `m7-operator` | Pending | Pending | Pending | Pending |
| `m7.pipe-answer` | `m7-provider` | Pending | Pending | Pending | Pending |
| `m7.instructions.declined` | `m7-provider` | Pending | Pending | Pending | Pending |
| `m7.instructions.changed` | `m7-provider` | Pending | Pending | Pending | Pending |
| `m7.cross-provider-maintenance` | `m7-provider` | Pending | Pending | Pending | Pending |
| `m7.thinking-bound` | `m7-provider` | Pending | Pending | Pending | Pending |
| `m7.thinking-cancel` | `m7-provider` | Pending | Pending | Pending | Pending |
| `m7.daemon-detach` | `m7-provider` | Pending | Pending | Pending | Pending |
| `m7.rollback` | `m7-rollback` | Pending | Pending | Pending | Pending |

<!-- end generated: case rows -->

## Security, independent and documentation reviews

| Review | Exact candidate/reviewer identity and scope | Conclusion and unresolved findings | Complete retained-report reference | SHA-256 |
| --- | --- | --- | --- | --- |
| Security, authority, credential/privacy and output/cleanup boundaries | Pending | Pending | Pending | Pending |
| Independent candidate review against all M7 outcomes and failure evidence | Pending | Pending | Pending | Pending |
| Operator/developer documentation meaning, examples and current command agreement | Pending | Pending | Pending | Pending |
| Fixture/manifest/profile/operator/attempt inventory completeness | Pending | Pending | Pending | Pending |

All labels and literal row keys must be final in the tested candidate.
The administrative child fills only the designated Pending cells; it adds no
heading, prose, row or proof obligation. Blocking review findings or missing
required evidence keep closure pending. Release/tag/publication remains a
separate maintainer decision.
