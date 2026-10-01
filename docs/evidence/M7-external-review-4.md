# M7 external review, round 4

Date: 2026-09-30. Reviewed candidate: `018c271c43b10baf79adacf0adb6f76e36510d0f`
on branch `m7`; previous reviewed candidate `a4c9061ee86a7442942207aa61ec022388bd7ac9`.

Repository state before and after: HEAD equals the candidate, working tree
clean (zero status lines) at start and at finish; branch `m7`. No file was
edited, no branch switched, no commit, test, release lane, provider call or
credential inspection was made. Review constraints, labelled honestly: this
session's tools are not an enforced read-only sandbox; the review was performed
with read-only commands and no write to the repository, and the only files
written are this report under `/tmp` and nothing else. Six read-only advisory
passes over disjoint areas fed this report; every load-bearing claim used below
was re-read by the integrating reviewer at the cited path before inclusion.

Receipt, manifest and log verification: `/tmp/loopex-m7-round3-readiness.json`
names the candidate, the remote `refs/heads/m7` at the same SHA, a clean tree,
and a documentation-only PASS. The log `/tmp/loopex-m7-round3-018c271c-docs.log`
has SHA-256 `6f8100c78afa4fff188be57b5c76387ebb752ca43e94cdab5998cb13874ade2c`,
matching the receipt. The manifest `/tmp/loopex-m7-round3-contracts.json` has
SHA-256 `01027be33133fec1eb67ae94466a8e9643d6d5688700263ade4978885bdef74c`,
matching the receipt; all 51 listed files match the working tree. The round 4
prompt digest `a1b3838181f2e995b7fcb25e8081c79a783e1994090013f88eb8d15a2b2eda84`
matches the receipt. The retained round 3 report at
`docs/evidence/M7-external-review-3.md` is byte-identical to the supplied file,
SHA-256 `cbb9cd861bad099d215d0c5a2299e3d84840e8501a513435153a9afa9824b055`.
One evidence limit on the receipt itself: the documentation log contains no
candidate SHA (only a commit range ending in `HEAD`) and its bytes are identical
to a docs-check log produced at an earlier candidate, so the log digest alone
does not identify the tested commit; only the receipt binds it. The check proves
document structure, not product behaviour.

## Concept

**Verdict: not yet ready for acceptance; materially closer than round 3.** Of
the 52 round 3 findings, 40 are repaired, 9 are partly repaired and 3 were
rejected correctly (details in the reconciliation table). The nine maintainer
selections are carried into the ADR bytes and the vision pair now shows every
governing clause beside its labelled proposal. What remains are seven families
of contract gaps where a stated rule cannot be followed together with another
stated rule, or where a field or route required in prose has no owning record
or API. All are repairable in text. Two genuine maintainer decisions remain,
both narrow; nothing below asks to reopen a recorded scope choice.

**Blocking contract-gap families and smallest repairs.**

1. **Post-terminal rendering and its remedy contradict the progress rule.**
   Explicit compaction is the named remedy for
   `canonical_history_rendering_unsupported` "even when the group fits", but
   every checkpoint must strictly reduce bytes and tokens, so a small offending
   group (a cancelled run after one short tool result) produces
   `compaction_no_progress` and the session is stuck on that mapping. The
   `canonical_terminal_tool_history` value for the two pinned rows is never
   stated, yet V7.7 requires it true, and the post-terminal grouping rule leaves
   three renderings open. Repair: define progress for a rendering-triggered
   cover as "post-checkpoint projection passes rendering admission and fits";
   add a capability column to the row table with the intended value and state
   that a live rejection is a `product_failure`; write the grouping literally
   (results and adjacent text in one user message; omit empty text blocks).

2. **Incomplete summaries cannot be detected.** `maintenance_summary_incomplete`
   depends on a `max_tokens`, `length` or unknown stop that neither the closed
   adapter reply shapes nor the current adapter expose; the adapter treats
   `length` as an ordinary stop. Repair: for compaction-purpose invocations the
   adapter returns a validated reply only on a proven natural stop and maps the
   rest to a closed started-call error, or a versioned reply member carries the
   stop class.

3. **Artifact capability and the resolved read argument have no owner that core
   can consult at replay.** The revision-1 table lives in the host registry,
   which core is documented never to read at replay, yet core must validate the
   genesis binding without a host file. The executor-only `resolved_artifact`
   member cannot be expressed in the schema subset (no unions, no ranges, no
   closed properties), its ordering relative to policy identity is unstated,
   and the executor resolves tools by ID alone so two `loopex.read` generations
   cannot coexist. Repair: make the table a literal constant in core or protocol
   code keyed by `loopex.artifact_read.v1` that the host registry must match;
   state that exclusivity and range checks are owner refinements before policy,
   that policy identity uses model arguments only, that `resolved_artifact` is
   added in job construction after allow, and that executor resolution is keyed
   by ID and version.

4. **Helper registry and recovery joins.** The lifetime, non-evicting router
   registry turns ordinary tool use into a restart-only outage: after 4,096
   distinct jobs every local read, grep and bash call in every daemon session
   is refused until the whole composition restarts, coupling independent
   parents. Nothing routes `retained_receipt` for a predecessor incarnation's
   job, so the recovered no-child failure path ends the parent `outcome_unknown`
   instead of the known failure. No API produces the exact resolved genesis the
   host must retain before create, so a grace change after an ambiguous create
   leaves the parent fenced. Repair: evict local rows after settlement and keep
   classification through the ledger plus a bounded tombstone for unknown IDs;
   have the router's `retained_receipt` consult the helper index before Local;
   specify a pure core genesis resolver or a create variant that accepts the
   retained genesis.

5. **Closure verdict mechanics have holes.** The runner must write the verdict,
   but `model_nonconformance` requires a judgement only the reviewer can make.
   `evidence_unavailable` after dispatch, harness or fixture defects, and
   product refusals that are not defects (capacity, profile gate at a long
   root, oversized real capsule) have no route. Pre-merge `--only` executions
   are not classified as attempts or not, and no index of prior attempts exists.
   V9.1, V3.5, V4.5, V9.3 and V9.4 have no owning case although V9.1 is
   mandatory attended; V6.2 has two owners. Repair: the runner records a
   mechanical outcome; the reviewer's classification lives in the prior-attempt
   row; product-side refusals and harness defects follow the `product_failure`
   route; every M7 case execution appends to a retained attempts index; add
   `m7.policy-denial` and owners for the unowned steps.

6. **Governance wiring.** The §13.4 amendment is in the vision but is not a
   stated prerequisite for outcome 4 or in ADR 0044's header, and the register
   and context-map row do not link its disposition. ADR 0021's "new writers
   emit only version-2 settlements" is contradicted and unamended. ADR 0044's
   technical file commits a provider mapping descriptor into core configuration
   that neither its Concept nor the §13.4 text covers, and the plan says only
   adapters map reasoning to provider options. ADR 0049's Concept omits the
   tool profiles, automatic question-tool activation, required policy profile
   and `status.policy`. ADR 0036 plans to add a member to ADR 0049's closed
   version-1 schema. Repair: one dependency sentence in the plan and ADR 0044;
   amend ADR 0021's writer clause and add a monotonic v3 cutover rule; describe
   the committed mapping descriptor as gating data in ADR 0044's Concept and
   §13.4; add the missing ADR 0049 Concept paragraph; retarget ADR 0036 to a
   successor schema version.

7. **Refusal union and record joins.** Episode-terminal ordering relative to
   the v2 refusal and run terminal is unspecified against ADR 0017's
   refusal-tail rule; standalone compact has no closed result shape and an
   undefined size candidate; the unconfigured-summarizer warning has no status
   slot and ADR 0049's Concept still says ordinary work remains available;
   several refusal paths (episode admission window checks, recovery
   unavailability, revision-4 receipt refusals, a lowered parent ceiling) have
   no member. Repair: pin the transaction order, define the compact result and
   candidate, add one bounded warning member and fix the wording, map the four
   paths.

**Implementation obligations** that do not block acceptance once named, listed
in Technical depth: bridge header and adapter validation, drain-process
separation and wrapper export completeness, the model-request writer revision,
the eight-key v2 reply leniency, the `effect_intents` byte measure,
cross-release deterministic ETF fixture, child genesis object form, cancel
deadline alignment, the new Store callback in the inventory and ADR 0036,
derived-ID prefix, resume without a parent binding, resume conflicts through
ADR 0016 abandonment, bounded wait after admission `commit_unknown`, wording of
"artifact-capable generations", the `session.create` forbidden list,
`loopex.read` identity, ADR 0036/M9 ledger carve-out in the Concept, §13.4
evidence and migration sentences, transitive prerequisites, attended-block
ordering and cost disclosure, the manifest/scaffold key check as a command,
V4 wrapper and observer channel, the three-tree lane mechanism, external-pin
input and timing. **Optional improvements** are listed separately.

**Genuine remaining maintainer decisions.**

| Decision | Options and consequences |
| --- | --- |
| Post-dispatch evidence loss that is not a model miss (operator absent, PTY or harness crash after the model was dispatched) | (a) Treat as a failed attempt requiring a new candidate with a causal correction: strictest; a single harness crash costs a full matrix rerun on a new SHA. (b) Permit one re-execution on the same SHA when the incomplete record proves the loss occurred before any verdict-bearing observation and no model action was judged: keeps strict no-reroll for model misses; needs the incomplete record retained and a named reviewer check. The recorded strictness covers model misses and rerolls; it does not say which applies here. |
| One non-closure live calibration of real capsule sizes before pinning thinking rows (optional) | (a) Accept that the first real size observation is a counted closure attempt; an oversized real capsule becomes a failed attempt with only the scope-amendment route open. (b) Authorize one retained, non-closure live run per pinned row to record capsule sizes as provenance before the row is pinned: spends provider money outside closure evidence, buys an early signal. |

The router-registry lifetime rule is treated here as a contract gap because the
round 3 disposition selected "register every routed job", which the eviction
repair preserves; if the lead considers lifetime retention itself a selected
choice, the maintainer should confirm the availability consequence instead.

## Technical depth

Classification: **CG** blocking contract gap, **IO** implementation obligation,
**OI** optional improvement. "Checks" says whether the plan's planned evidence
would catch the defect. "MI" is whether maintainer input is genuinely needed.

### Compaction, context admission, refusal records

| # | Class | Where | Conflicting contracts and reachable scenario | Checks | Smallest repair | MI |
| --- | --- | --- | --- | --- | --- | --- |
| 1 | CG, high | `docs/adr/0043-context-compaction-checkpoint-technical.md:53-56, :311-315`; `docs/adr/0044-...-technical.md:574-583, :697-701` | Release of the newest group on rendering failure or explicit compact; strict decrease in bytes and tokens else `compaction_no_progress`; explicit compaction named as the remedy "even when it otherwise fits". Scenario: run cancelled after a ~300-byte tool result on a mapping with `canonical_terminal_tool_history: false`; next prompt refuses `canonical_history_rendering_unsupported`; `/compact` covers the group but the summary element (digest, checkpoint ID, carry-forward, summary text) is larger, so `compaction_no_progress`; session stuck on that mapping. | The 0044 vector would fail against the contract, not flag it. | For a rendering-triggered cover, define progress as "post-checkpoint projection passes rendering admission and fits applicable limits"; keep strict decrease for size triggers; let explicit compact continue while rendering admission fails. | No |
| 2 | CG, medium | `0043-technical.md:300-302`; ADR 0018 tech `:175`; `0044-technical.md:240-241`; `apps/loopex_llm_reqllm/lib/loopex/llm/req_llm/mapping.ex:143-198`; `session_state.ex:3589` | `maintenance_summary_incomplete` on `max_tokens`/`length`/unknown stop, but the closed reply shapes carry no stop member; the adapter treats `length` as a stop and drops `finish_reason`; core synthesizes `stop_reason`. Scenario: Haiku thinking-off summarizer hits 1,024 tokens mid-JSON; truncated but parseable JSON is accepted as a valid summary. | Evidence names "invalid summary" only. | Compaction-purpose invocations return a validated reply only on a proven natural stop; other stops become a closed started-call error mapped to `maintenance_summary_incomplete` under ADR 0021 accounting; or add a versioned reply member. | No |
| 3 | CG, medium-low | `0043-technical.md:138, :145-148, :179-180, :247-249, :291`; `0042-technical.md:23-26` | Unmapped refusal paths: episode admission needs a positive input allowance and compatible output limit with no cause; recovery with missing capture, route or renderer has no stated failure path (session unsupported recovery versus run terminal); revision-4 source-reference refusals unmapped; a ~705-token maintenance block against an explicitly lowered parent `system_class_tokens` falls to a misleading `compaction_excerpt_budget_too_small`. | No. | Validate window > 1,024 and output ≥ 1,024 at startup; declare recovery cases session unavailability with no run record; map receipt refusals to `context_projection_invalid`; pre-check the ceiling at episode admission. | No |
| 4 | IO with ambiguity, medium | `0043-technical.md:340-343, :377-379`; `session_state.ex:2065-2082, :2133-2135, :5795-5810, :5868-5898` | A completed maintenance failure records its cause in the episode terminal and ends the run, but ADR 0017 and code forbid rows between a refusal and its terminal and require stage `model_pending` or `turn_settled`; record order and run stage during maintenance are unspecified; disposition under `projection_state: unavailable` unspecified. v1 validators are not reachable by v2 records (dispatch by kind), but the coded 1,000 ceiling must stay v1-only. | No. | Pin `[episode_terminal, context_admission_refused_v2, run_terminal_committed]`; admit the maintenance stage in the v2 validator only; fix the unavailable disposition. | No |
| 5 | CG, low-medium | `0043-technical.md:74-76, :380-382`; plan `:117, :125` | Standalone compact "unchanged only if the current request also fits" has no staging identity or prompt on a settled session, so the candidate is undefined; no closed compact-completion shape exists. | No. | Candidate is retained history plus fixed content under current hard limits; result `{disposition: checkpointed|unchanged|failed, checkpoint_id|null, failure|null, usage}`. | No |
| 6 | CG, low | `0043-technical.md:118-119, :123-125`; `0049-...-technical.md:137-138, :194-197`; `0049` concept `:46`; plan `:122` | Startup and `/status` must warn for a continuation-required conversation without summarizer, but status `maintenance` is closed to two members and `continuation_required` is excluded from projections; ADR 0049 Concept still says "ordinary work remains available"; the condition is decidable at session open/resume, not daemon startup. | No. | Add one bounded warning member or derived Boolean; say "at session open/resume"; fix both wordings. | No |
| 7 | IO, low | `0041-technical.md:176-179, :190-201` | Preparation deadline shortened by run or caller cutoff but the origin is not retained, so precedence between `bound_reached` and `artifact_preparation_deadline` is undecidable; preparation-versus-selection order unstated (a 17th old inline source that compaction would cover can still fail on count). | No. | Record the deadline origin; prepare only sources in the post-selection projection. | No |
| 8 | OI | `0043-technical.md:49-53, :94-95` | Define "minimum tail" as the contiguous suffix from the newest complete group including later input-only units; state that rendering failure alone never opens an automatic episode; name which failure members travel as decimal strings. A small summarizer window can make a maximal prior checkpoint plus minimum excerpts irreducible (disclosed); a startup floor on the summarizer window would avoid a recurring refusal. | Not applicable. | Wording and an optional startup floor. | No |

Walk-through results that hold: terminal-tail release is decidable and total for
a cancelled run with a 14 KiB write, a bound-ended run preceded by another large
run, an input-only newest unit (given the contiguous reading), a session whose
only history is the terminal group plus the current prompt, and explicit compact
before a smaller-model configure (measured against the current configuration,
disclosed as eligibility not a promise).

### Thinking continuation, settlement, bridge, wire

| # | Class | Where | Conflicting contracts and reachable scenario | Checks | Smallest repair | MI |
| --- | --- | --- | --- | --- | --- | --- |
| 9 | CG, high | `0044-technical.md:113-120, :149-156, :583-585, :694-702`; plan `:512, :748-754` | `canonical_terminal_tool_history` is "true only when verified; unverified is false", the row table has no column for it, and V7.7 (`m7.thinking-bound`, `m7.thinking-cancel`) requires accepted rendering on the same model. If the pinned rows ship false, both cases refuse before dispatch and fail as product failures; if they ship true on documented intent, the live case is the only verification. A test is standing where a contract value is required. | Only the closure live case. | Add a capability column with the intended value per row (true for Haiku manual and Fable adaptive/default on documented intent); state that a live rejection is a `product_failure` through the disposition menu, not a flip of the Boolean; or make V7.7 conditional on the declared value. | No; a contract value the lead can pin |
| 10 | CG, medium | `0044-technical.md:569-574`; `deps/req_llm/lib/req_llm/providers/anthropic/context.ex:74-101, :255`; `0044-technical.md:270` | "One native user content array, followed by any adjacent admitted user text" does not say whether the text joins the array or forms consecutive user messages (ReqLLM merges only all-tool_result messages); steer placement between results and prompt unstated for the post-terminal case; empty canonical assistant text alongside tool calls unaddressed (API rejects empty text blocks, ReqLLM drops them, the in-exchange rule preserves zero-length native blocks). | A vector can only pin whatever is chosen. | One sentence: merge results then every adjacent steer or prompt text in canonical order into one user message; omit empty text blocks in post-terminal rendering; add a vector. | No |
| 11 | CG (governance), low | ADR 0021 concept `:43, :64`, technical `:138-139, :149-150`; `0044` concept `:9`; `0044-technical.md:354-357` | ADR 0021: "New writers emit only version-2 settlements"; ADR 0044 writes v3 for every settlement and says only "extends ... preserving v2 meaning". No monotonic "no v1/v2 after the first v3" rule exists, so replay can accept interleaved kinds. | Evidence tests writers, not ordering. | Add "amends ADR 0021's v2-only writer clause and compaction measurement" to the Supersedes line; state the monotonic v3 cutover rule. | No |
| 12 | IO, medium | `provider_attempt.ex:766-776`; ADR 0018 tech `:175`; `0044-technical.md:358-362, :237-239`; `model.ex:52` | Code accepts an eight-key v2 reply (`provider_response_id` optional) while ADR 0044 discriminates v2 from v3 by an exact 9 versus 10 count; an eight-key reply plus `continuation` is ambiguous. ADR 0044 also does not name whether new non-continuation requests are written as `model_request.v1` or `v2`. | Only if a vector covers the missing key. | Require the key in both shapes (nil allowed); name the request writer revision. | No |
| 13 | IO, medium | `0044-technical.md:172-173, :460-462, :728-733`; `deps/req_llm/lib/req_llm/providers/anthropic.ex:763-764, :917-922, :970-978`; `finch_client.ex:102-107, :248-263`; `generation.ex:241-251` | Replacing only the body at the wrapper boundary leaves ReqLLM-derived headers in place; manual thinking options add the interleaved-thinking beta header, which the ADR forbids; a global Finch request adapter or callback can alter the installed body after attach; `stream_text`'s cache hit path returns without HTTP. | The bridge test asserts body only. | Validate the exact header set and absence of adapters/callbacks in the final request; forbid the cache. Optionally render and validate before `start_stream/4` so a renderer defect is `not_dispatched`. | No |
| 14 | IO, low | `deps/req_llm/lib/req_llm/stream_server.ex:990-999, :1057-1065, :1082-1086`; `streaming.ex:109, :193-194, :286-289`; `req_llm.ex:310, :429-437, :485-513`; `0044-technical.md:486-496` | Feasible without forking: `start_stream/4` takes a provider module; the parser closure receives opts so it can carry an owner or latch. Obligations: run the drain in a separate process from the owner (today `drain/5` runs inline with infinite `next`); export every callback StreamServer probes with `function_exported?` or defaults silently apply. | Export-completeness vector not listed. | Name both obligations and the vector. | No |
| 15 | IO, medium; MI optional | `0044-technical.md:751-761`; plan `:425-470` | Deterministic conformance uses synthetic signatures; the first real capsule size observation is the first execution of `m7.thinking-rounds` in some candidate, a counted attempt. An oversized real capsule is a failed attempt with only the scope-amendment route. | None before the counted attempt. | Accept explicitly, or authorize one retained non-closure calibration run per pinned row (Concept table). | Optional |
| 16 | OI | `0044-technical.md:158-166, :199-206` | Haiku manual eligibility is a literal mapping property, enforceable. Say eligibility is (row) plus (`message_start.message.model` equals the pinned literal) plus (`thinking_delta` inside a `thinking` block); `redacted_thinking` and `signature_delta` never eligible. Whether Fable returns exactly `claude-fable-5-1` is unverifiable before dispatch. | Partly. | Pin the expected response-model literal per row. | No |
| 17 | OI | `0044-technical.md:402-405, :421-425`; `0043-technical.md:118-129` | Precedence between `maintenance_model_unconfigured` and `thinking_exchange_headroom` when both apply is not fixed. | No. | Name the order. | No |
| 18 | OI | `0044-technical.md:779-784`; `apps/loopex_protocol/lib/loopex_protocol/canonical.ex:40, :98-99`; `priv/schema/loopex-experimental-{1,2}.json` | `Canonical.digest/1` and revision `loopex.canonical.v1` exist; the version string is not added to the preimage automatically; "complete payload definitions" is not a defined artifact. | Pinning the preimage makes the digest deterministic, not the manifest scope. | Name the included manifest sections, whether the version string is a member, and strict integer-only JSON decoding. | No |

Accounting check: no inconsistency found between the 32,768-byte record target
measured on the complete record with both header variants and ADR 0043's
"continue until both targets fit"; the fresh-session large-prompt refusal is
disclosed. A maximal 16 KiB compact envelope appears twice in the record and can
fill the byte reserve alone, consistent with "no round guarantee".

### Artifacts, configuration, ephemeral, pipe, fixture wrapper

| # | Class | Where | Conflicting contracts and reachable scenario | Checks | Smallest repair | MI |
| --- | --- | --- | --- | --- | --- | --- |
| 19 | CG, high | `0041-technical.md:70-87`; `0044-technical.md:26-37`; `0046-technical.md:172-183`; `apps/loopex/lib/loopex/tool_registry.ex:36-41`; `coding_tools.ex:65-85` | Table "is part of the versioned host tool registry" yet core validates the binding "at admission and replay without looking up a changed host file"; `Loopex.ToolRegistry` is configuration that projection and replay never read; read definitions live in host code. Composition submits the full genesis including `artifact_read` while "no caller can supply or edit it". Scenario: a later host build changes the `loopex.read` 1.0.0 entry; replaying a v3 genesis fails or depends on which host runs. | Row 9 items do not prove replay without the host registry. | Make the revision-1 table a literal constant in core or `loopex_protocol` keyed by `loopex.artifact_read.v1` that the host registry must match; core derives `artifact_read` at create and refuses a supplied mismatch. | Only if host ownership is preferred |
| 20 | CG, high | `0041-technical.md:205-223`; `apps/loopex_protocol/lib/loopex_protocol/tool_definition.ex:37-42, :322-328`; `session_coordinator.ex:6399-6400, :6451-6461, :6794-6800, :6939`; `apps/loopex_executor_local/lib/executor.ex:1209-1223, :2927-2955` | Schema subset has only `type`/`properties`/`required`; no unions, ranges or closed properties; undeclared members pass. So "path XOR artifact_use+offset+length", `length <= 4,096` and "model-supplied copies refuse" cannot live in the schema and no text names them as owner refinements or their failure class. Policy request and defer digest are built from `call.arguments` before re-validation; the ADR does not say whether `resolved_artifact` is added before or after policy. Executor `tool/1` returns the first definition by ID then compares version, so two `loopex.read` generations cannot coexist, and the `%{"path" => _}` clause matches supersets. Scenario: model sends `{path, artifact_use, offset, length, resolved_artifact}`; behaviour is unspecified. | Evidence covers injected resolution, not both-branch or superset arguments or version coexistence. | One paragraph: exclusivity and range checks are owner refinements before policy with a named failure; policy and interaction identity use model arguments only; `resolved_artifact` is added in job construction after allow; executor resolution and validation keyed by ID and version. | No |
| 21 | CG, medium | `0049-...-technical.md:108`; plan `:557-558`; `session_state.ex:1509`; `session_coordinator.ex:6592-6593`; `loopex_composition.ex:259-263` | Resume "requires matching policy identity", but core retains `policy_identity` only on interactions; a settled session created through the harness wrapper has nothing to compare, so a registry-origin chat can resume it. `origin` and `fixture_manifest_digest` are not in core's `{id, revision}` map. | No. | Limit the check to ADR 0024 interaction identity, or retain host policy identity in the parent binding or ledger and compare before activation. | No; either repair is in scope |
| 22 | CG (unstated case), medium | `0049-...-technical.md:91-100`; `0046-technical.md:80-100`; plan V12.4 | `chat --resume` of a session with no ADR 0046 parent binding (created by `run`, daemon or M6 roots) with a helper-enabled file: fence as unresolved, treat as disabled, or refuse? No consistency rule between the declaration's `enabled` and whether `loopex.task` is in the genesis. | No. | One sentence: absent binding means delegation disabled and no fence; add a V12/V13 subcase. | No |
| 23 | IO, medium | `0049-...-technical.md:98-107` vs `:111-118`; ADR 0016 tech `:354-357` | Cleanup-grace conflict uses prepared-owner abandonment; `--no-helpers` and `--max-tokens` conflicts only "refuse before activation", though detection may need the committed configuration available only after preparation. | No. | Every resume conflict detected after preparation uses ADR 0016 abandonment with unconfirmed failure; extend V12.4. | No |
| 24 | IO, low-medium | `0049-...-technical.md:237-245`; `session_coordinator.ex:1458-1462, :1791-1795` | After admission `commit_unknown` no bound on waiting for the `uncertain` barrier; what is emitted if resolution arrives within the window; whether `/quit` or abort counts as a fenced mutation. Coordinator rediscovery is the resolver but is not cited. Exit code is nonzero, covered. | No. | Bound the wait by owner cleanup grace or the existing drain; name rediscovery; `/quit` proceeds to bounded abort reporting `cleanup: unknown` if uncertain. | No |
| 25 | OI | plan `:126`; `0041-technical.md:70-73, :78-79` | "New artifact-capable read/search generations" but only `read` is artifact-capable; the new read generation's version and digest literal is deferred with no owner or step. | Not applicable. | Reword; add a pin step with an owner. | No |
| 26 | OI | plan `:115`; `0041-technical.md:79-80`; `0044-technical.md:36-37` | `session.create` row does not forbid remote `tool_selection` or `artifact_read`. | Not applicable. | Add derived tool-selection capability bindings to the forbidden list. | No |
| 27 | OI | `0041-technical.md:77-84` | "The one selected read definition" does not say tool_id `loopex.read` versus model-visible name `read`; an embedder registering `acme.read` named `read` would refuse under the name reading. | Not applicable. | Say "the selected `loopex.read` generation, if any". | No |

Checked and consistent: the closed ephemeral option list matches
`ephemeral/options.ex` exactly and each added option has one owning ADR with
grammar and default; `ask/3` accepts only `timeout`; credential bootstrap
ordering is stated precisely with the legacy name resolved once (the CLI
exemption versus moving the discard is an implementation choice); the
delegation declaration is a host binding object readable before activation; the
fixture wrapper is a trusted host under AGENTS.md authority rules and needs no
new ADR; the bypass of `main/1` is disclosed and closed by the escript cases.

### Helper ledger, registry, recovery

| # | Class | Where | Conflicting contracts and reachable scenario | Checks | Smallest repair | MI |
| --- | --- | --- | --- | --- | --- | --- |
| 28 | CG plus disclosure, high | `0046-technical.md:301-321`; `0046` concept `:70-76`; plan `:778-779`; `apps/loopex/lib/loopex/executor.ex:25, :176, :181`; `apps/loopex_executor_local/lib/executor.ex:423-424` | Every forwarded job, local or helper, gets a row retained until the incarnation ends; 4,096 rows or 8 MiB then `refused_before_effect: router_registration_capacity` for every read, grep, bash and helper call in every session until a full composition restart, which forces stop-only recovery of unfinished helpers. A daemon at ~50 tool calls per run over ~100 runs a day exceeds it. One busy parent exhausts capacity for all independent parents, which "independent parents concurrent" does not disclose. Local already answers a late cancel for a settled job with `unconfirmed`, so local retention only prevents a late local cancel closing helper admission. | The "fill each registry bound" test asserts the behaviour as correct. | Classify by live row, else by ledger lookup on job ID (helpers are durably reserved before launch); evict a local row once execute returns; a cancel for an unknown ID gets a bounded tombstone refusing later registration of that ID and forwards to Local; only tombstone overflow closes helper admission. Disclose the router's existence when delegation is disabled. | Only if lifetime retention was itself a selected choice; otherwise a contract fix |
| 29 | CG, medium | `0046-technical.md:321-324, :508-511, :560-566`; `session_coordinator.ex:7650-7665, :7680-7705` | Crash after core commits the `loopex.task` intent, before `initialize`; startup writes `initialize` and `recover_uncreated` and binds a failure receipt. On parent activation the coordinator calls `retained_receipt` once; the new router incarnation has no row for that job and, forwarding to Local, gets `:absent` or `effect_unresolved`, so the parent ends `outcome_unknown` instead of the known no-child failure. | Evidence asserts ledger state, not activation outcome. | Router `retained_receipt` consults a validated helper index by job ID before Local; answers `:absent` only when the route is proven local; unknown route after reconciliation answers `effect_unresolved`; add an activation test expecting the known failure receipt. | No |
| 30 | CG, medium | `0046-technical.md:80-92, :173-185, :446-452`; `runtime/control.ex:2186-2189, :2405-2410`; `store.ex:786-797` | Host must retain "the exact fully resolved v2/v3 genesis submitted at creation" before `prepare_parent`, but core create builds the genesis itself and inserts the runtime's cleanup grace; ADR 0044 v3 also resolves tool defaults. Scenario: ambiguous parent create, restart with a different grace; "proven absent → re-present retained creation" passes options to core which writes the new grace; `/4` against the retained genesis conflicts permanently; `bind_parent` never completes. `Store.create_session/3` is confirmed a pure constructor. | No. | Specify a pure core `SessionGenesis.resolve/2` with explicit inputs shared with Control's writer, or a create variant accepting the complete retained genesis validated by `normalize/1`; re-present refuses when the resolved genesis differs. State `normalize/1`'s input shape. | No |
| 31 | IO, low-medium | `0046-technical.md:405-407`; `store.ex:603, :624, :1087, :1122`; `canonical.ex:84, :125-130` | The `effect_intents` cap of 1,114,112 bytes uses `Canonical.encode/1` (a tagged tree) while the Store's 65,536 bound is plain `external_size`; a record with many small nested entries can exceed the per-call cap; no rule for a page or single row over the cap. `ownership_head/3` and `load_records/4` exist with those arities. | No. | Measure with the Store's plain size or define an early-stop rule. | No |
| 32 | IO, low-medium | `0046-technical.md:116-125`; `canonical.ex:84`; `state.ex:638`; `.tool-versions` | Re-encode equality with `term_to_binary(.., [:deterministic])` of a plain map; the option exists on both supported OTP pairs and the repo uses it, but this codec encodes maps directly without sorting, and deterministic output stability across OTP major releases could not be verified locally (no local OTP docs; reviewer recollection only). A 27→29 toolchain change could make every retained creation object unreadable. | No. | Integrity is SHA-256 over retained bytes plus closed-schema validation; drop re-encode equality or require sorted-list canonicalization; add a cross-pair fixture. | No |
| 33 | IO, low | `0046-technical.md:105-106, :127-128, :173-178`; `0042-technical.md:15-18` | Inline child genesis in a frame: role instructions may reach ~50 KB, base64 expands to ~67 KB, exceeding the 65,536-byte frame cap; a false but safe capacity refusal. Parent genesis lives in the 1 MiB object and fits. | No. | Mandate the object form for child creation input. | No |
| 34 | IO, low | `apps/loopex/lib/loopex/executor.ex:327-331, :497-512`; `0046-technical.md:328-331`; local `executor.ex` cancel margin notes | Core `cancel/4` starts its observation bound before the router's entry; the router derives the same bound from its own later entry, so its final answer can arrive after core has killed the caller; router queueing turns a direct-Local `cleaned` into `unconfirmed`. | No. | Router deadline = entry plus observe minus a fixed margin; never queue local cancel forwarding behind ledger work; add conformance comparing cancel answers through the router during a concurrent helper stop. | No |
| 35 | IO, low | plan `:1132-1146`; `0036-technical.md:87-95`; `loopex_store_local/.../state.ex:13, :36-46, :169-211, :683-685` | The new `creation_provenance/3` Store callback and ordinal semantics are absent from the M7 inventory and ADR 0036, so the M8 engine has no recorded obligation. The local store has no create ordinal today but creates are ordered frames in one append-only log, so a derived replay index needs no format change (avoiding the ADR 0036 marker gate). Watermark/live-create catch-up is race-free as long as every create route is behind host admission. | No. | List the callback; consider optional with "missing" meaning `unavailable`. | No |
| 36 | OI | `0046-technical.md` derived child-create IDs; wire create rules unverified | If a client-supplied `session.create` command ID can equal a derived child-create ID, either the helper create conflicts (safe) or the client's session is classified as a helper and its mutations refused. | No. | Reserved derived-ID prefix that client creates refuse. | No |

Checked and consistent: the adapter-wide `commit_unknown` fence and its
settlement coupling are now disclosed in the concept file; stop-only recovery,
one helper per parent conversation and independent-parent concurrency remain
internally consistent apart from finding 28's registry coupling.

### Operator validation, closure, evidence

| # | Class | Where | Conflicting contracts and reachable scenario | Checks | Smallest repair | MI |
| --- | --- | --- | --- | --- | --- | --- |
| 37 | CG, medium-high | plan `:440-470` (esp. `:441-443, :447-454, :458-459, :469-470`); `AGENTS.md:236-242`; `verification.md:123-125` | "The runner writes one verdict", but `model_nonconformance` requires "without a demonstrated product defect", which only the reviewer can judge. Scenario 1: operator steps away or PTY crashes after `m7.feature` dispatched; `evidence_unavailable`; restart "still obeys the same attempt rule", a new SHA alone authorizes nothing, the menu covers only `model_nonconformance`; nothing permits re-execution, candidate dead with no route. Scenario 2: the model calls the required tool but the product refuses it (fixture policy misconfiguration, profile gate at a long temp root, router capacity, real capsule over 16 KiB); neither a product defect nor a model omission; no class fits. | Detect the failure; nothing classifies it. | Runner records a mechanical outcome (pass; prescribed action absent; assertion failed after action; evidence incomplete, before or after first dispatch); reviewer classification lives in the prior-attempt row; product-side refusals, bound failures and harness or fixture defects follow the `product_failure` route; `evidence_unavailable` before first dispatch may rerun on the same SHA after repair; after dispatch, see the Concept decision. | Yes, narrowly (Concept table) |
| 38 | CG/IO, medium | plan `:454-458, :489-492, :978-981`; `verification.md:61-63`; `milestones-technical.md:226` | Whether a paid `--only m7.thinking-bound` pre-merge run counts as a prior attempt is undefined: if yes, every pre-merge variance needs a disposition; if no, the closure run is a reroll; an `--only` run on the tested SHA creates a row the closure child cannot add. Nothing indexes retained execution records, so "known rows" depend on memory. | No. | Define which executions count; the runner appends every M7 case execution reference and digest to a retained attempts index; forbid M7 case runs on the tested SHA other than the one full matrix. | Optional default statement |
| 39 | IO, medium | plan `:532-534, :645-646, :663-664, :790-797, :919`; case table `:139-150` | No owning case for V9.1 policy-denied effect (mandatory attended), V3.5, V4.5 late steer, V9.3 recovery, V9.4 daemon detach; V6.2 owned by both `m7.long` and `m7.range-read`; V11.5 cleanup not bound to the trace cases; V1.3 two cases need subcase keys; V12.4 owner unnamed. | No. | Add `m7.policy-denial` (operator lane; oracle: committed denied result, no effect intent or receipt, unchanged workspace); name owners for the others; split V6.2; bind V11.5. | No |
| 40 | IO, medium | plan `:480-497, :996-1012`; `check-release.sh:62-65, :117-121, :282-326`; `release-lane.sh:10-16, :36-42, :156-164, :169-213`; `attended-release.sh:202-211`; `foundation_workflow_real_test.exs:190-222, :311-321` | Fixed eleven-row ExUnit manifest with hard-coded count; `lane()` counts ExUnit tests through `suite-summary`, which multi-run wrappers do not fit; one credential; four-name redactor; about seventeen attended provider cases plus V10 and V13 restore in one invocation with two credentials, Node, Linux and a human present throughout, with no bound on order or duration. Three selector namespaces (lanes, `m7.*` IDs, functional list) and several functional selectors are attended. Stdin preservation for attended rows is verified true (manifest on fd 3; lanes inherit stdin; chat mode by TTY), with the caveat that today's attended witness reads `/dev/tty` because `System.cmd` children do not get the terminal. | No. | Run the attended block first and contiguously with a duration budget; say what human absence means (finding 37); fix the selector namespace; run M7 wrappers as non-ExUnit executables with a case-ID/manifest-digest sidecar. | Acknowledge the multi-hour two-credential attended run |
| 41 | IO, low-medium | plan `:933-941` | The manifest/scaffold key agreement check is prose only; a missing row (e.g. V8.6) surfaces at the administrative commit where adding a row is forbidden. Five-path confinement otherwise holds. | Only at closure. | Name a repository command (mix task run by `check.sh`) comparing `test/fixtures/m7/manifest.json` with `M7-closure-runs.md` at the tested SHA. | No |
| 42 | IO, low | plan `:650-658, :548-551, :566-567, :748-753`; `executor.ex:13-14, :229-230, :5893-5905`; `coding_tools.ex:158` | Barrier feasible (`env -i`, fixed PATH, argv passed unchanged, absolute runner can open a FIFO). Unstated: that `m7.steer-barrier` runs through the fixture wrapper (only route where the fixture policy replaces shell-allowlist); how the harness observes committed steer and follow-up events; the same barrier for `m7.thinking-cancel`'s cut. | No. | State the wrapper, name the observer channel, reuse the FIFO for the cancel cut. | No |
| 43 | IO, low | plan `:862-874, :1161-1168`; `check-release.sh:91, :200-218, :271`; `rollback-lane.sh:15-18, :53` | Published v0.3.0 contains the rollback scripts byte-identical to HEAD, so running v0.3.0's own extracted lane with old=v0.2.0 and new=v0.3.0 keeps historical bytes. Changes needed: third archive staging plus SHA guard, the hard-coded old SHA for the new pair, candidate-worker use, the VERSION check, toolchain choice for historical trees. `m7.rollback` has no oracle row; M7→M6 is observational. | Not until the lane runs. | Name the mechanism and the oracle row. | No |
| 44 | OI/IO, low | plan `:983-995`; `release-lane.sh:4-24` | Runner accepts only `--only`; no input for the pin path; "first dispatch" ambiguous between case and matrix; immutability is digest plus no-clobber, not read-only mode. | No. | Name the input; log the digest before the matrix's first provider dispatch; apply to A/B pins. | No |
| 45 | IO, low | plan `:955-981` | "The complete demonstrated profile set" is itself a Pending value, so per-profile rows cannot be predeclared unless derived from the manifest. | Only at closure. | Derive profile rows from committed manifest keys. | No |

Step-by-case coverage: V1 by `baseline.ask`/`baseline.durable`; V2.1–5 `repair`,
V2.6 `pipe-answer`; V3.1–4 by the three `instructions.*` cases, V3.5 none;
V4.1–4 `steer-barrier`, V4.5 none; V5 complete; V6.2 two owners, rest owned;
V7 complete; V8.1–4 `review`, 5–7 tests; V9.1 none (attended), V9.2 `interrupt`,
V9.3–4 none, V9.5 tests; V10 collection plus `external`; V11.1–4 owned, V11.5
unbound; V12.1–2 reuse trace cases, 3–5 tests; V13 `m7.rollback` plus attended
restore with no oracle row.

### Vision, successors, pair consistency

| # | Class | Where | Conflicting contracts and reachable scenario | Checks | Smallest repair | MI |
| --- | --- | --- | --- | --- | --- | --- |
| 46 | CG, high | plan `:13-15`; `M7.md:42-47, :351-354`; `0044` concept `:5-12`; `docs/adr/README.md:237-238`; `docs/plans/README.md:32-34`; context map `:59`; `vision-technical.md:1647-1648` | Only the tool-budget amendment is stated as a prerequisite; ADR 0044 carries no vision-amendment dependency; the register and context-map row do not link the continuation disposition. Without the §13.4 amendment the governing clause says the sidecar is "never interpreted by core" while ADR 0044 has core validate and expand it. | Grep would show only 0045/0046 cite the vision. | State in the plan that the §13.4 amendment is a prerequisite for outcome 4 (and 7's model settings); add the dependency sentence to ADR 0044; mention 0044 in the ADR README paragraph; link the disposition from the register and context map. | No |
| 47 | CG (concept/technical and vision), medium-high | `0044-technical.md:12-15, :112-124`; `0044` concept `:47-51`; plan `:1076`; `vision-technical.md:1656-1659` | Technical commits "the resolved `model_capabilities` envelope and resolved provider mapping" with `thinking` variants into genesis v3; Concept commits only model identity, reasoning, instruction envelope and limits; the plan says "only adapters map that setting to provider-specific options"; the §13.4 proposal limits core to envelope, identity bindings, references and expansion. | No. | Name the host-resolved mapping descriptor in ADR 0044's Concept and the §13.4 proposal as committed gating data core never interprets; fix plan line 1076; or move `thinking` into adapter-private data. | Only if relocation is preferred |
| 48 | CG, medium | `0036-technical.md:134-137`; `0049-...-technical.md:12-13, :342-345` | ADR 0036 says the capacity key goes in "ADR 0049's version-1 schema once this pair names the key"; ADR 0049 declares version 1 closed at every level and requires successors to reuse it or propose an explicit migration; an added v1 member would be rejected by M7 readers and change what v1 means. | No. | "A successor schema version or explicit ADR 0049 amendment carries it". | No |
| 49 | CG (hidden scope), medium | `0049-...-technical.md:26, :44-49, :201-208`; `vision-technical.md:3161` | ADR 0049's Concept never mentions tool profiles, automatic `loopex.ask` activation in nonempty chat profiles (a default-activation decision beside ADR 0045's opt-in), the required file `policy`, or `status.policy` harness origin; the vision says "ADR 0049 proposes explicit reference profiles". | No. | Add a Concept paragraph covering profiles, question/helper tool activation, required policy profile and harness-origin inspection. | No |
| 50 | IO, medium | `m9-store-engine-successor-technical.md:30`; plan `:1142`; `0036-technical.md:89-94`; ADR 0036 concept decision 3 | M9 row 2 says the complete inventory, which includes the host ledger, migrates "with identical bytes/order", while ADR 0036 technical leaves the ledger in place outside the Store; ADR 0036's Concept is silent on the ledger (hidden scope). Paths are otherwise consistent. | Not in M7. | M9 row 2: "Store records migrate; host ledger verified unchanged in place"; one sentence in ADR 0036's Concept. | No |
| 51 | IO, medium-low | `vision.md:317-323, :351-357`; `vision-technical.md:1669-1671`; `AGENTS.md:61-63` | The §14 amendment names principle, evidence, compatibility and migration; the §13.4 amendment gives principle and compatibility gates, cites future proof as evidence, and omits migration and rollback (legacy empty-continuation sessions; backup rollback). | No. | One sentence each: evidence is the selected Claude thinking modes needing exact blocks; legacy sessions keep empty continuation and rollback uses a pre-upgrade backup. | No |
| 52 | IO, low-medium | `M7.md:337-347`; plan `:18-28`; ADR headers `0042:13`, `0043:10`, `0049` | The three prerequisite inventories match directly, but ADR 0042 depends on 0044, 0043 on 0041/0042/0044/0048, 0049 on 0042/0044/0047/0048; so 0044 is needed before outcomes 2, 3 and 6 although listed only before outcome 4; phase 1 builds instructions on 0044's configuration record. | No. | State that Depends-on predecessors must be accepted first, or widen the lines. | No |
| 53 | OI | `vision-technical.md:1812-1815`; `vision.md:348-349, :546-548`; `0042-technical.md:99` | Technical counts "all rendered host environment facts" in the target; the Concept says only tools and question/helper definitions. | Not applicable. | Add "and rendered environment facts, including workspace paths" to both Concept sentences. | No |
| 54 | OI | `vision-technical.md:312, :1035 vs :1027, :1113-1114, :1454` | Unlabelled clauses touched by the proposals: §10.3 answers "with host decision context" while a model-question answer is user data; glossary Tool includes "executor requirements"; §12.3 "opaque provider-continuation sidecars"; the 10.1 note adds "bound reached" not present in the governing transition; §23.4 governing bullets changed punctuation and gained a prefix (words verbatim). | Not applicable. | Labelled notes, or add §5, §10.3 and §12.3 to the header scope. | No |
| 55 | OI | `docs/plans/README.md:27-28, :32` | Next-decision row names the plan pair and nine ADRs but omits the vision-pair acceptance and the external re-audit; "Next transition" is honest. | Not applicable. | Extend the row. | No |

Verified as consistent: every labelled proposal in both vision files now sits
beside its governing clause verbatim (the §14 sentence without "workspace", the
unchanged 10.1 diagram, 14.2 "seven conformance-tested implementations",
founding decision 8, the §26 summary, the §27 rows); the header scope list
covers every labelled edit; §12.5 permits a separate summarizer; ADR 0046's
Concept covers the read-only queries and Store callback; ADR 0043's Concept
covers versioned failures and terminal-newest release; ADR 0044's Concept names
the rendering refusal and ephemeral startup choices; roadmap M10 "version
unselected" and the M7/M8/M9 projection agree with the drafts; ADR 0038's lines
match M8; the evidence and ADR READMEs index round 3 accurately; no document
claims a check, review or probe proves product behaviour.

### Reconciliation of the 52 round 3 findings

Verdicts: **R** repaired, **P** partly repaired, **RC** rejected correctly.
No round 3 finding was rejected incorrectly or left unaddressed. "Where" gives
the repairing text at the candidate or the residue (finding numbers refer to this
report).

| # | Claimed | Verdict | Where |
| --- | --- | --- | --- |
| 1 | Repair in ADR 0043 | R | `0043-technical.md:50-60, :448-452`; new residue is finding 1 (rendering remedy versus strict decrease), a different rule |
| 2 | Repair in ADRs 0042–0044 | R | `0043-technical.md:322-360`; plan `:125`; ordering and stage residue is finding 4 |
| 3 | Obligation | R | `0043-technical.md:63-66, :452-453`; `0044-technical.md:403-404` |
| 4 | Disclosure | R | `0044.md:94-97`; `0044-technical.md:406-407, :681-682` |
| 5 | Repair in ADR 0043 | P | `0043-technical.md:118-126`; residue: `0049.md:46` and `0049-technical.md:137-138` unqualified; no status slot (finding 6) |
| 6 | Repair in ADR 0043 | P | `0043-technical.md:295-304`; residue: incomplete stop undetectable by closed reply shapes and adapter (finding 2) |
| 7 | Obligation | R | `0042-technical.md:98-100`; plan `:240-248`; temp-root refusals feed finding 37 |
| 8 | Repair in M7 | R | plan `:511, :730-733` |
| 9 | Repair in ADR 0041 | P | `0041-technical.md:74-84`; residue: table ownership versus replay without host file (finding 19) |
| 10 | Simplify | R | `0043-technical.md:91, :272` |
| 11 | Repair in ADR 0044 | P | `0044-technical.md:568-580, :694-700`; residue: capability value per row undecided; grouping ambiguous (findings 9, 10) |
| 12 | Repair | R | `0044-technical.md:153` literal Yes; eligibility pinning is optional finding 16 |
| 13 | Repair in ADR 0043 | R | `0043-technical.md:105-110` |
| 14 | Obligation | P | `0044-technical.md:752-760`; residue: no pre-integration gate; a real oversized capsule has no verdict class (findings 15, 37) |
| 15 | Repair in ADR 0044 | R | `0044-technical.md:450-466, :729-730`; header/adapter validation residue is finding 13 |
| 16 | Repair in ADR 0044 | P | `0044-technical.md:350-356`; residue: ADR 0021 writer clause unamended, no v3 cutover rule, eight-key leniency (findings 11, 12) |
| 17 | Obligation | R | `0044-technical.md:286-289, :375` |
| 18 | Repair | R | `0044-technical.md:222-226` |
| 19 | Repair | R | `0044.md:155-157`; `0044-technical.md:783-784`; scope of "complete payload definitions" is optional finding 18 |
| 20 | Repair in ADR 0046 | P | `0046-technical.md:300-330`; `0046.md:67-73`; `M7.md:214-218`; residue: lifetime registry makes ordinary tool use a restart-only outage (finding 28) |
| 21 | Repair in ADR 0046 | P | `0046-technical.md:393, :469, :504`; `0046.md:77-80`; residue: `retained_receipt` routing for predecessor jobs (finding 29) |
| 22 | Repair in ADR 0046 | R | `0046-technical.md:413-416, :531-533` |
| 23 | Repair in ADR 0046 | P | `0046-technical.md:523`; plan `:40`; residue: no API yields the retained resolved genesis (finding 30) |
| 24 | Preserve uncertainty | RC | disclosed at `0046.md:64-65`, `0046-technical.md:327-333`, plan `:776-777, :792-793`; deadline alignment is optional finding 34 |
| 25 | Disclose fence | RC | `0046.md:74-75`; plan `:779` |
| 26 | Clarify | R | `0046.md:60-63`; plan `:777-778` |
| 27 | Repair promotion join | R | `0046-technical.md:263-266` |
| 28 | Reject as repair | RC | `0046-technical.md:133-136`; `M7.md:217-218`; 128 is a ceiling, disclosed |
| 29 | Repair and reject | R | `0049-technical.md:88-99`; `0046-technical.md:639`; plan `:783-786, :841-845`; retaining allowances matches the committed-resume wording; residue: no-binding resume unstated (finding 22) |
| 30 | Repair | R | `0049-technical.md:180-184, :234`; wait bound is finding 24 |
| 31 | Repair | R | `0048-technical.md:76-79, :87-109` |
| 32 | Repair | R | plan `:505, :617-622, :633-636` |
| 33 | Reject vendor exclusion | RC | `0044-technical.md:175-181` defines route identity and disclaims vendor diversity; consistent with the recorded provider choice; B owner at plan `:1098` |
| 34 | Repair | R (text) | plan `:862-874, :1161-1168`; mechanism residue is finding 43 |
| 35 | Repair | R | plan `:552-561`; policy-identity match residue is finding 21 |
| 36 | Repair | R | `0044-technical.md:52-65`; `0049-technical.md:259, :267` |
| 37 | Clarify | R | plan `:872-874` |
| 38 | Repair | P | plan `:440-470`; residue: verdict routes and attempts index (findings 37, 38) |
| 39 | Repair and reject | R | plan `:489-497`; stdin claim verified at `check-release.sh:303-305`, `release-lane.sh:181`; runner cost residue is finding 40 |
| 40 | Repair | P | plan `:927-941`; residue: key check has no named command (finding 41) |
| 41 | Repair | R | plan `:511-512, :528-531, :689-694, :748-753, :870-871, :889-892`; new unowned steps are finding 39 |
| 42 | Repair | R | plan `:650-658`; joins residue is finding 42 |
| 43 | Repair | R | plan `:983-995, :1004-1009`; input and timing residue is finding 44 |
| 44 | Repair | P | plan `:955-981`; residue: profile set is itself Pending (finding 45) |
| 45 | Via 20 | R | `0046.md:67-73` |
| 46 | Restore governing clauses | R | `vision.md:12-18, :335, :602`; `vision-technical.md:1032, :1641, :1805, :2929-2936` |
| 47 | Approved A | R | `vision.md:12-18, :317`; `vision-technical.md:1635-1660`; context map continuation disposition; wiring residue is finding 46 |
| 48 | Repair | R | `0042.md:11`; `0044.md:9`; `0044-technical.md:52-65, :665`; plan `:46` |
| 49 | Align | R | `M7.md:339-348`; plan `:21-28`; ADR headers; transitive residue is finding 52 |
| 50 | Repair | R | `m9-...-technical.md:30`; `0036-technical.md:87-92`; plan `:1140`; Concept residue is finding 50 |
| 51 | Repair | R | `0044.md:9` |
| 52 | Repair | R | `0036-technical.md:136`; `0038.md:13-14`; `roadmap.md:136-148`; `m8-...-technical.md:104`; new schema conflict is finding 48 |

### Limits of review

- No product tests, release lanes, provider calls, credential inspection or
  dependency installs. No scratch artifacts were written; every size figure
  in this report is an estimate from contract text and prior retained probes
  (verified by hash in round 3), labelled as such.
- Provider behaviour (Haiku's default display being summarized; acceptance of
  an assistant `tool_use` without thinking followed by results and text while
  thinking is enabled; the exact response-model string for Fable; real
  signature and summary sizes) is unverified. Where the packet cites the
  provider documentation as checked on 2026-09-30, this review accepted the
  citation as documented API intent, not as proof of the pinned ReqLLM
  behaviour.
- The OTP guarantee on deterministic `term_to_binary` stability across major
  releases could not be checked locally (no OTP documentation installed; OTP 29
  present); finding 32 rests on reviewer recollection and is stated as a risk.
- Wire rules for client `session.create` command IDs, the daemon lease owner's
  visibility of adapter-created child sessions, and whether v0.3.0 still builds
  under a changed M7 toolchain were not verified.
- Planned artifacts (`test/fixtures/m7`, `scripts/m7-fixture-chat.exs`,
  `scripts/m7-ephemeral-question-demo.exs`, `LoopexCli.Chat`) do not exist, as
  expected for a planning candidate.
- Reconciliation rows marked R were checked at the cited passages and their
  surroundings, not by a complete reread of every file; the technical ADR files
  were read in full by the area reviewers and by header, diff and targeted
  passage by the integrator.
- The documentation-check log is content-identical across candidates and names
  no SHA; the receipt is the only binding of that PASS to `018c271c`.
