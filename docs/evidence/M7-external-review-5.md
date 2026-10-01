# M7 external review, round 5

Date: 2026-10-01. Reviewed candidate: `a2ce04c2862d2d15e58eed317379a3b6684c4286`
on branch `m7`; previous reviewed candidate `018c271c43b10baf79adacf0adb6f76e36510d0f`.

**Identity verification, all passed before any reading.** HEAD equals the
candidate, branch `m7`, zero status lines. Hashes: readiness receipt
`0ea87858…4184`; contract manifest `11dfb0ca…5651` (matches receipt), all 53
listed files match the working tree; documentation log `d270236b…888d` (matches
receipt and result file); result file `3c43a2f4…2dc9` (matches receipt); this
round's prompt `0ee23f3e…6095` (matches receipt); retained round 4 report
`806c39d4…0573`, byte-identical to the supplied file. The log itself names the
candidate SHA, `clean_before=true`, `clean_after=true`, `head_after` equal to
the candidate, complete output and `check_exit_code=0`. That check proves
structure, compilation and formatting only.

**Constraints, labelled as they actually were.** This session's tools are not
an enforced read-only sandbox. The review used read-only commands only; no file
in the repository was edited, no branch switched, no commit, build, product
test, check, release lane or provider call made, and no credential inspected.
Six read-only advisory readers covered disjoint areas under the same
constraints; the root reviewer read the disposition and every technical diff
since round 4 directly and re-read each load-bearing claim below at the cited
path before including it. No scratch artifacts were written; the only file
created is this report. Repository state after the review: HEAD
`a2ce04c2…4286`, clean.

## Concept

**Verdict: not ready for acceptance. The packet is close, and what remains is
narrow.** Of the 55 round 4 findings, 42 are repaired, 12 partly repaired and
one was declined as recorded (the reserved command-ID namespace). The
governing vision clauses are verbatim beside every proposal, the status text is
honest, and no repair drops a required check or adds a reroll by intent. Six
families of contract gaps remain. Each is a place where an ordinary, reachable
sequence produces a wrong or undefined result under the text as written. All
are repairable in a few sentences without reopening a recorded scope choice.

**Blocking contract-gap families and smallest repairs.**

1. **A refused helper call becomes a fenced parent at the next host start.**
   Core commits the task intent before the adapter runs; the adapter refuses an
   exhausted allowance, unknown role or occupied slot without writing any ledger
   record; startup then treats every retained task intent with no ledger
   operation as lost evidence, charges a count slot, and refuses the parent's
   recovery when counts are exceeded. The plan's own V8.6 (exhaust the
   allowance, then restart and verify no reset) reaches this. Repair: define an
   expected operation as a task intent with no committed pre-effect refusal
   terminal, by adding the tool-terminal disposition to the intent read.

2. **A non-progressing or over-limit summary may be committed.** ADR 0043
   measures progress "before and after substitution" and separately says to
   commit the checkpoint after settlement, without ordering the two; the
   rendering-repair branch has no named failure when the grown summary exceeds
   a hard limit. Under the commit-first reading the larger summary is durable
   and cannot be re-summarised or dropped, so the session is permanently over
   limit. Trailing input-only units after a released newest group also have no
   release rule. Repair: evaluate progress on the pending summary before commit
   and name `compaction_no_progress` for every trigger; apply release
   oldest-first to every terminal-run unit in the minimum tail.

3. **Piped unknown admission names a resolver that does not exist.** The ADR
   says to observe "coordinator rediscovery/resolution" and never resend; in
   source an admission `commit_unknown` replies with an error after one built-in
   re-presentation and nothing rediscovers it, and no read-only command
   disposition query exists. Three of the six contract branches therefore have
   no producing path. Repair: name the resolver and the observation surface
   (owner re-presentation of the identical transaction on a bounded timer, or
   one host re-presentation of the identical command stated as idempotent
   replay).

4. **The thinking-mapping admission state machine is undecidable at the tested
   SHA, and core tests a thinking mode it is said not to interpret.** A mapping
   is deterministic-conformant, then usable only by a trusted test host with an
   "unverified" label, then admitted for ordinary use after retained live
   success. The middle state has no representation, the witness for each of
   the nine model-by-level cells is not mapped, and the only attended case that
   can supply the first success runs in the closure matrix on the tested SHA,
   after which registration would be a source change. Separately, ADR 0043 has
   core require `provider_mapping.thinking: {mode: disabled}` for maintenance
   while the §13.4 proposal and ADR 0044 say core never interprets thinking
   modes. Repair: a per-cell status table with owning witness cases and the
   composition join for the candidate resolver; one generic host-resolved
   Boolean for "thinking disabled" that core gates on instead of the variant.

5. **Closure verdict routes still have an empty cell and an unexecutable one.**
   A provider or network failure after dispatch with complete evidence is none
   of the four verdicts' definitions, and "a repaired environment alone" is
   excluded as a remedy. The same-SHA pre-dispatch repair has no resume
   mechanism: attended cases run only in the full matrix, which visits every
   case, so reaching the stopped case re-dispatches the passed ones. A blocked
   case inside a lane-granular `--only` selector has no defined runner
   behaviour. Repair: add the environment row; define a `not_dispatched` state
   and index-keyed resume; have the runner refuse a lane holding an unresolved
   prior failure.

6. **Amendment and dependency wiring.** ADR 0041's header says it preserves ADR
   0028 while its technical file adds a job-owned transfer ADR 0028 does not
   have; ADR 0043 maintenance before a run's first ordinary request has no
   stated relation to ADR 0013's deadline commitment; the "coordinated packet"
   rule rests on Depends-on lines that omit real reverse dependencies, so ADR
   0041 alone would authorize outcome 1 while writing into unaccepted ADR 0044
   and 0043 records; the rollback lane's retarget retires the v0.2-to-candidate
   pairing without recording that as a change in what the check proves. Repair:
   five header or table edits and one sentence each.

**Implementation obligations** (named below, not blocking once stated): v3
closed relations and stop-reason list; Model-port eight-key break; final-request
header allowlist and Finch hooks; callback inventory; summarizer completion
capability at admission; unavailable-session exit; control-record branch table;
abandonment for every post-preparation refusal; tombstone refusal term; cancel
margin scope; derived-index mechanics; exact-genesis create wiring; startup scan
cost; attempts-index integrity; attended budget and ordering; attended V13
owner; barriers for interrupt and daemon-detach; evidence-task placement.

**Genuine remaining maintainer decisions.** Two. Neither re-raises a recorded
choice.

| Decision | Options and consequences |
| --- | --- |
| A provider or network failure after dispatch, with complete truthful evidence (for example a 529 or a dropped connection mid-run during the multi-hour matrix) | The recorded choice A covers lost recording or attendance and requires a causal fix to that path; a provider outage has no such fix. (a) Treat it as a failed attempt needing a scope or evidence amendment each time: strictest; one transient outage costs a candidate and a maintainer action. (b) Add a verdict such as `environment_failure`, decided by the independent reviewer from retained provider-side evidence, that permits the affected case to run on a new candidate without a product correction, with the attempt retained: keeps no-reroll for model misses and no same-SHA retry. (c) Leave undefined: closure can become unreachable through no fault of product or model. |
| Status of thinking rows when M7 closes | (a) The tested bytes register the pinned rows for ordinary use and the counted cases are their proof: simple, but contradicts "ordinary host resolution still refuses unverified rows" and needs that sentence changed. (b) M7 closes with candidate-only thinking rows usable through the trusted host, and ordinary registration is a named follow-up change with its own check: consistent with the current text, but outcome 4's "chosen per run" is then not available to an ordinary operator for thinking modes at closure. |

## Technical depth

Classification: **CG** contract gap (blocking), **IO** implementation
obligation, **OI** optional improvement. "Checks" says whether planned evidence
catches it. "MI" is whether maintainer input is genuinely needed. Short path
names: `0041-T`, `0043-T`, `0044-T`, `0046-T`, `0049-T` are the technical ADR
files under `docs/adr/`; `plan` is `docs/plans/M7-technical.md`. Line numbers
are at the candidate.

### Compaction and refusal records

| # | Class | Where | Conflict and reachable scenario | Checks | Smallest repair | MI |
| --- | --- | --- | --- | --- | --- | --- |
| 1 | CG, medium | `0043-T:331-345, :488-496`; concept `:72-78` | "Measure before and after substitution … otherwise stop with `compaction_no_progress`" versus "Successful settlement retains summary bytes in `checkpoint_pending` … Commit the checkpoint"; no order. For `canonical_rendering`, "resulting candidate passes all hard limits" has no named failure. Scenario (estimate): unknown-window budget 8,192, candidate about 6,300 tokens, a 300-byte offending group; the summary element can reach about 2,130 tokens, so the post-substitution candidate exceeds the budget. Commit-first reading makes the larger summary durable; it cannot be re-summarised alone or dropped, so the session is permanently over limit. | No; evidence covers growth that still fits. | "Progress is evaluated on `checkpoint_pending` before checkpoint commit; a non-progressing or over-limit summary is retained only as settlement evidence; the failure is `compaction_no_progress` for every trigger." | No |
| 2 | CG, medium-low | `0043-T:51-54, :58-68` | "Failed or cancelled runs without an assistant reply must not strand those inputs" versus "minimum tail is a contiguous suffix, including all later input-only units"; release names only the newest group. Scenario: group G1 completes, then several ~12 KiB prompts each end cancelled or `model_call_failed` with no reply; the next prompt releases G1 and still exceeds the record limit, and every later prompt and `/compact` refuses. | No; input-only units are tested only as old history. | Release applies oldest-first to every terminal-run unit in the minimum tail; only current-run inputs and unfinished groups are irreducible. | No |
| 3 | CG, low-medium | `0043-T:14-18, :61, :335-347, :424-425` | Precedence makes a size trigger win so strict decrease governs, yet `:346` continues "or still rendering-ineligible" for any trigger. Scenario: a thinking run misses headroom and its newest group is a small offending one; one reading continues past fit and ends `compaction_no_progress` after an extra paid call, the other stops at fit and refuses rendering. The enum mixes command origin and reason ("the trigger is explicit compact"). | No. | Restrict continuation-for-rendering to the `canonical_rendering` trigger; name the post-fit outcome for size triggers; say "command origin explicit"; state standalone never captures `thinking_headroom`. | No |
| 4 | CG, low-medium | `0043-T:426-460`; ADR 0011 technical `:55-68`; `0049-T:160, :195`; plan `:119, :127` | ADR 0011's exhaustive table knows only settled and run-active; standalone maintenance is neither. Unstated: durable resolution of prompt, configure or a second compact during the episode; abort's own reply; the public carrier of `{disposition, checkpoint_id, failure, usage, cleanup}` (`context.compacted` does not fire for `unchanged` or a failed episode with no checkpoint). Scenario: a client submits `session.compact`, disconnects, reattaches; nothing says whether it ended `unchanged`. | No. | A short admission table for commands during standalone maintenance with stable codes, and one named completion event or snapshot member. | No |
| 5 | CG, low | `0043-T:363-378, :384-385, :427` | `measurement_scope` exists only in the private refusal record; it is not in the closed failure object that `run.finished`, snapshots and the compact result carry; standalone emits no refusal record at all. Scenario: parent `system_class_tokens` lowered to 500, maintenance block about 705 tokens; the public failure shows system observed 705 limit 500 while the operator's prompt is 300 tokens. | No. | Carry the scope in the episode terminal or failure object; state "nonnumeric measured ⇒ ordinary". | No |
| 6 | IO, low-medium | `0044-T:263-267, :388-392`; `0043-T:118-123, :322-329`; `apps/loopex_llm_reqllm/lib/loopex/llm/req_llm/mapping.ex:143-198` | A provider-B summarizer whose adapter can emit only `unknown` (or v2 replies) passes startup, which checks the thinking-off mapping only, then fails every episode after one paid dispatch. The adapter today drops `finish_reason`. | Only as the counted `m7.cross-provider-maintenance` attempt. | A deterministic positive vector per thinking-off row (ordinary stop ⇒ `natural`) as a condition of maintenance admissibility; name the outcome for a v2 reply. | No |
| 7 | IO, low-medium | `0043-T:160-165, :569-572` | "Session unavailable" for a missing captured route or renderer admits nothing (no abort, inspect or configure) and has no stated exit; evidence `:570` still says "refuses a required dispatch". A removed provider binding while an episode awaits a permitted retry locks the session. | Vectors exist for whichever reading. | "Nothing durable changes; restoring the captured route or renderer and restarting resumes." Align `:570`. | No |
| 8 | IO, low | `0043-T:413-423, :426-427`; `session_state.ex:5798` | The "maintenance stage" has no literal or closed state set; the closed terminal shape is scoped to standalone by "Its". | Decidable by an implementer. | Name the stage; say the same terminal shape applies to run-owned episodes. | No |
| 9 | OI | `0043-T:58-62, :72-74`; concept `:53`; `0041-T:207-216` | Explicit compact always releases the newest group, so it keeps no preferred tail and one sentence is unreachable; the Concept's "keep a recent complete tail verbatim" is untrue for `/compact`. Preparation after selection relies on measuring unprepared inline sources at full size, unstated. | Not applicable. | State both plainly. | No |

Walks that hold: single small offending group; three non-offending groups then
the offending one over the source cap (cut always advances, exhaustion gives
`bound_reached` with a partial checkpoint, a new `/compact` is a new episode);
four full attempts are about 29,400 estimated tokens, under 32,768; v1 refusal
shape stays exact; `[episode terminal, refusal v2, run terminal]` satisfies the
existing refusal-tail rule; startup floors are consistent with ADR 0041.

### Artifacts, configuration and piped chat

| # | Class | Where | Conflict and reachable scenario | Checks | Smallest repair | MI |
| --- | --- | --- | --- | --- | --- | --- |
| 10 | CG, medium | `0041-T:221-234`; ADR 0009 technical `:185-193`; `session_coordinator.ex:6399-6461` | Shape, exclusivity and range checks are placed before policy with `invalid_tool_arguments`; the membership check ("unknown, orphan, other-session and forged uses refuse") has no position in ADR 0009's sequence and no reason code, while `resolved_artifact` is added "after allow". Scenario: the model sends a well-formed `artifact_use` for another session's use; if resolution follows allow, a deferring policy opens an operator question for a call that then fails at job construction with an unnamed reason, and the before/after difference acts as an existence oracle. | No. | Resolve membership before policy with one named failed disposition identical for all four cases; job construction only attaches the already-resolved reference. | No |
| 11 | CG, low | `0041-T:238-242`; `apps/loopex/lib/loopex/executor/job_request.ex:31-57` | "Executor lookup selects by exact (tool_id, tool_version), then checks the digest", but the job and grant carry no definition digest and "no top-level executor protocol field is added". | No. | Say the core literal table and registration match guarantee the digest, or carry it inside `resolved_artifact`. | No |
| 12 | IO, low | `0041-T:72-85`; `0046-T:190-196`; `0044-T:36-38` | "A literal constant in core" names no module; nothing says who enforces "registered reference definitions must match it"; `SessionGenesis.resolve/2` does not say whether `artifact_read` is absent and derived or present and compared. | No. | Name the module; `resolve/2` input omits the member and `normalize/1` compares. | No |
| 13 | CG, medium | `0049-T:259-260, :277-278, :359`; `session_coordinator.ex:2609-2613` (admission `commit_unknown` replies an error and keeps the owner after `resolve_transaction`'s single re-presentation at `:2623-2640`); `apps/loopex/lib/loopex/runtime.ex` facade | "Observe coordinator rediscovery/resolution … never resend the command." Nothing in source rediscovers an unknown admission; the lane fence clears only when the identical transaction is presented again; no read-only command-disposition query exists; evidence still lists "idempotent resubmission". Scenario: a settled session takes a piped prompt whose admission is unknown; no internal commit will touch the fence and the host may not re-present, so every case lands in "unresolved at deadline" and the three resolved branches have no producing path. | Vectors are required for the resolved branches with no way to drive them. | Name the resolver and observation surface, and what makes non-admission conclusive. | No |
| 14 | IO, low-medium | `0049-T:193-206, :227-229, :258-276`; ADR 0016 technical `:58-69` | Undetermined: the record carrying the "stable refusal/error code"; precedence when admission is unresolved and an earlier run is still active; `run_id` on the `commit_unknown` branch; `input_sequence` of a host-initiated barrier; `closing.cleanup` per branch; which ADR 0016 bound "the ordinary host shutdown deadline" is. Two implementers produce different `wait` records for `/steer` unknown during an active run. | Vectors would pin them; the text does not decide them. | A six-row branch table giving record sequence and fields, and the named bound. | No |
| 15 | IO, low-medium | `0049-T:94-97, :112-113, :128-130`; plan `:912-914` | Abandonment covers "every conflicting resume flag"; a missing delegation binding, a pending-interaction policy mismatch, a workspace mismatch and a missing route are also found only after preparation and are not flags. | V12.4 lists the missing-binding case without an abandonment assertion. | Change "every conflicting resume flag" to "every refusal". | No |
| 16 | OI | `0041-T:70-72, :119-122`; plan `:128`; `coding_tools.ex:203` | New grep/find/ls generations have no pin owner and "sufficient" artifact allowances have no number; `offset` has no ceiling; the paragraph still opens "The reference host registers … as artifact-capable" beside the core-literal sentence. | Not applicable. | Pin step and wording. | No |

Checked and consistent: `tool_selection.artifact_read` is a member of genesis
v3 and therefore of ADR 0046's retained genesis; public callers are refused;
superset arguments on the new generation fail before policy; closed ephemeral
options match `ephemeral/options.ex`; credential ordering is consistent with
`loopex_cli.ex:80-82`; a registry-origin chat can resume a harness-created
settled session and the ADR discloses that as a host authority choice.

### Thinking continuation, settlement and bridge

| # | Class | Where | Conflict and reachable scenario | Checks | Smallest repair | MI |
| --- | --- | --- | --- | --- | --- | --- |
| 17 | CG, medium-high | `0044-T:118-121, :131-132, :160-164, :177-185, :209`; concept `:100-105`; plan `:354, :519, :546-547, :604-606, :612-613, :1106-1110` | The candidate state has no representation: the text forbids "a public flag, new core field" and `provider_mapping` has no status member, so a candidate session commits a mapping identical to an ordinary one; the only named trusted join covers policy injection, not capability resolution. Granularity is undefined: two revisions cover nine dispatchable cells and the counted cases witness three or four. `m7.thinking-rounds` is `m7-operator`, which refuses `--only`, so its first success can occur only in the closure matrix on the tested SHA; registration afterwards is a source change the closure commit cannot make. "Ordinary host resolution still refuses unverified rows" also conflicts with "unknown capability permits `default` only", reachable in the mandated ordinary escript prompt on the dated Haiku model. Resume of a candidate-mapped session by an ordinary host is unstated. | None. | A per-cell table: status in the tested bytes and owning witness case IDs for continuation, post-terminal rendering and summary; the composition join carrying the candidate resolver; the ordinary host's result for candidate cells and for resume; when and under which SHA registration happens. | Yes (Concept table) |
| 18 | CG, medium-high | `0043-T:115-126, :305-306`; `0044-T:117, :134-135`; `docs/vision-technical.md:1672-1675`; `docs/vision.md:320-322`; `0044` concept `:54-56` | Vision proposal: "core validates declared limits and flags without interpreting thinking modes"; ADR 0044: "Core uses them without interpreting the provider's thinking mode"; ADR 0043: core startup "receives only the closed resolved map … Maintenance requires … `provider_mapping.thinking: {mode: disabled}` … direct core startup rejects invalid resolved data". "Require `max_tokens > budget_tokens`" names no owner. Gating on the two generic Booleans is consistent; the variant test is not. | No evidence asserts core never reads `thinking`. | Add one generic host-resolved Boolean (for example `thinking_disabled`) that core gates on, and assign the budget relation to host resolution or the adapter; or reword the three sentences. | No |
| 19 | IO, low-medium | `0044-T:263-267, :323-329, :391-394`; `deps/req_llm/lib/req_llm/providers/anthropic/response.ex:363-372` | `completion` is a closed enum but its relation to capsule `status`, `tool_calls` and `continuation_required` is not stated; `model_context_window_exceeded`, `refusal` and `pause_turn` have no listed value. Haiku manual-low hitting the limit with no calls can be an adapter error or a v3 reply that core turns into `unreadable_model_answer`; the durable category differs. | Mixed-shape vectors do not cover relation cells. | A four-row relation table and a literal stop-reason list. | No |
| 20 | IO, medium-low | `0044-T:388-390`; `apps/loopex/lib/loopex/model.ex:133`; `provider_attempt.ex:766-776` | The port type declares `optional(:provider_response_id)` and several in-tree Model fakes omit it; under the new rule their replies refuse with an unnamed category, possibly charging the whole remaining allowance. Not recorded as a port break. | No. | Discriminate v2 from v3 by exact key names; state the refusal category; record the type change and fixture migration. | No |
| 21 | IO, medium | `0044-T:198-209, :491-494`; `deps/req_llm/lib/req_llm/streaming/finch_client.ex:105-106, :248-266`; `providers/anthropic.ex:173, :910-914` | After `attach_stream/4`, the app-env `:finch_request_adapter` and `opts[:on_finch_request]` can still alter the request; neither is named. ReqLLM injects `anthropic-beta: tools-2024-05-16` whenever tools exist; the ADR forbids only the interleaved-thinking header, so the allowlist must admit or strip it explicitly. A refusal raised in the build path is logged by the dependency with `inspect`. The buffered path's validation point is unnamed. | The bridge test names the body only. | Name the two hooks, the exact header allowlist, a fixed literal refusal term and the buffered validation point. | No |
| 22 | CG, low | `0044-T:219-223` versus `:541-544` | A response-model mismatch "cannot inherit summary classification" (suppress) versus "provider fallback is not silently interpreted as the selected model" (fail). If Fable answers with a dated snapshot ID, either every Fable call fails after dispatch or only the summary is hidden. | No. | One sentence choosing the outcome. | No |
| 23 | IO, low | `0044-T:528-530`; `deps/req_llm/lib/req_llm/streaming.ex:279, :287`; `stream_server.ex:163, :423, :984, :1071-1075, :1327, :1339` | Two probes live in `ReqLLM.Streaming`, not StreamServer; the final protocol flush is not a callback and no-ops for a non-`Parser` state. | Inventory is to be recorded. | Widen "StreamServer" to the pinned streaming path and pin the protocol-state type. | No |
| 24 | OI | plan `:547, :805-817`; `0044-T:603-610` | V7.7's oracle ("provider acceptance and correct facts") passes if the provider silently disables thinking for the post-terminal request (provider behaviour unverified, reviewer recollection). An assistant message with empty text and no calls becomes an empty content array. | No. | Assert on native capture whether the post-terminal reply carried a thinking block; state drop-or-refuse for the empty message. | No |

Confirmed consistent: every dispatchable row pins mode, display, continuation,
summary eligibility and terminal-history capability; v3 counts are right
(adapter 11, canonical 10, outer 12) against `provider_attempt.ex`; v2
normalises to `completion: unknown`, consistent with maintenance rejecting v2;
the monotonic cutover is a replay rule and an open attempt at upgrade settles
as v3; grouping is complete for a steer between results and prompt and for
several terminal groups; post-handoff validation failure as
`dispatched_or_unknown` is a stated cost; the schema-digest manifest is
decidable once vectors pin the preimage.

### Helper registry, index and recovery

| # | Class | Where | Conflict and reachable scenario | Checks | Smallest repair | MI |
| --- | --- | --- | --- | --- | --- | --- |
| 25 | CG, medium-high | `0046-T:13, :57-58, :107-111, :221-230, :238-244, :424-429, :511-517, :534-541`; plan `:845-851` | Core commits the `loopex.task` intent before `execute/5`. The adapter may refuse before any ledger append (unknown role, exhausted count or tokens, occupied slot, ledger capacity, registration capacity, tombstone, closed admission); no mutation kind records a refusal. Startup builds expected operations from all retained task intents; intent rows are exactly `{journal_version, job}` with no tool-terminal disposition; an expected operation absent from the log gets `recover_uncreated` with `count_charge: 1`, and "if expected operations exceed the retained count … refuse that parent's recovery". Scenario, which is V8.6: `max_children: 2`, two children settle, a third call is refused for exhaustion, the run completes, the operator quits and runs `chat --resume` (a host start): three intents against two operations and a limit of two, so that parent's recovery is refused. An unknown-role typo with headroom silently consumes a slot after restart. | No; `0046-T:689-690` and V8.6 would fail against the contract. | Add the committed tool-terminal disposition to the intent query (or a companion read) and define an expected operation as a task intent with no committed pre-effect refusal terminal; add a witness: refuse, restart, no count change, parent activatable. | No (yes only if a new `refuse` ledger record is preferred) |
| 26 | CG, low | `0046-T:253-256`; plan `:843` | "The existing incarnation-wide unknown-cancel fence … still apply" survives beside the per-ID tombstone rule at `:360-368`; the plan still says "registry exhaustion/restart". | No. | Reword both. | No |
| 27 | CG, low | `0046-T:360-370`; `session_coordinator.ex:7147-7149` | "Every later registration of that ID refuses launch" names no result term; an untagged error makes the coordinator commit an unknown terminal for a job that provably never started. Tombstones have no removal rule and are inserted before the Local conclusive-receipt check, so a late cancel of a settled local job consumes one. Overflow closes only helper admission and is disclosed; practically slow. | Evidence covers the block and overflow, not the term. | Name the term (for example `refused_before_effect: cancelled_before_registration`); check a conclusive Local receipt before inserting. | No |
| 28 | IO, low | `0046-T:348-355`; `apps/loopex/lib/loopex/executor.ex:327-332, :497-512`; Local `executor.ex:391-396` | If the router's entry-plus-observe-minus-250 ms deadline also governs the forwarded Local call, it times out just before a boundary Local `cleaned` when grace exceeds 7,000 ms. | Queueing is tested, not margin stacking. | State that local forwarding is a pass-through bounded only by core; add a conformance case comparing direct and routed answers. | No |
| 29 | IO, low-medium | `0046-T:342-344, :426-428` | "Recovery registers only unresolved jobs" has no discriminator for local jobs, since the intent read returns no terminals; registering every historical local intent can exceed the row cap. | No. | Say predecessor local jobs are not registered and take the unknown path, or share finding 25's terminal read. | No |
| 30 | IO, low | `0046-T:593-611`; concept `:73-74`; plan `:1234` | Index entries "contain … frame offset" but live registration precedes any frame; no rule for an index-write failure; no version field; the directory is not in the compatibility inventory; full rebuild at every start. | Partly. | Declare it a disposable derived cache with a versioned entry and a no-frame state; define the write-failure outcome. | No |
| 31 | IO, low | `0046-T:82-84, :185-207`; concept `:9`; plan `:40-41, :1204` | `Runtime.create_session_with_genesis/4` is a new core mutation API; the plan's ADR 0008 row still says "no activation or mutation authority" and ADR 0016's amendment is "only" lookup, yet the variant commits a session whose grace differs from the running option. Result union (`create_session/3` or the detailed one) unnamed. | No. | Update the two plan rows and the "only"; name the union. | No |
| 32 | IO, low | `0046-T:432-436, :477-490`; `store.ex:624, :1638-1640`; ADR 0036 technical `:95-97` | The page measure names `external_size/1` "as the Store does"; the Store uses the two-argument deterministic form. `/4` and the provenance digest join still rebuild a transaction with deterministic encoding and compare bytes across toolchains. "Unsupported callback is unavailable" appears only in ADR 0036. | Ledger-object fixtures only. | Name the function; add a cross-pair `/4` and provenance fixture; one sentence in ADR 0046. | No |
| 33 | IO, low-medium | `0046-T:423-424, :492-497, :562-569` | Before admission opens the host enumerates every create mapping and scans every session's whole journal at most 16 records per call; a timeout "never means complete" and incomplete classification refuses mutations, including on ordinary sessions. Whether a helper-disabled host composes the router and runs the scan is unstated. | None measure startup. | State the helper-disabled case; add a measured startup bound or a persisted coverage watermark as a named obligation. | Possibly, on whether an operational bound belongs in M7 |

Confirmed consistent: active-row reclamation at settlement; caps of 4,096 rows
and 8,388,608 bytes for each table; the derived index answers the recovered
no-child failure receipt on the coordinator's single `retained_receipt` call;
an ID in neither table yields `effect_unresolved`, never Local absence; the
ambiguous-create-then-changed-grace walk re-presents the same genesis and
binds; mandatory child objects and post-encoding frame credit; evidence bullets
no longer describe the lifetime registry.

### Operator validation, verdicts and evidence

| # | Class | Where | Conflict and reachable scenario | Checks | Smallest repair | MI |
| --- | --- | --- | --- | --- | --- | --- |
| 34 | CG, high | plan `:451-456, :474-481`; `AGENTS.md` ("Environment failure means evidence unavailable, not PASS"); `docs/developer/agent-context-map.md` evidence-loss disposition | `product_failure` is "a product, fixture or harness path fails a required assertion"; `model_nonconformance` is a model omission; `evidence_unavailable` is "missing evidence, prerequisites, attendance or unconfirmed fixture cleanup"; choice A needs "a causal fix to the recording/attendance path" and excludes "a repaired environment alone". Scenario: provider A returns 529 or the network drops mid-run in `m7.long`; the product records a truthful provider failure with complete evidence. No class fits and no correction exists. | Detected; nothing classifies or routes it. | Add an explicit row and route. | Yes (Concept table) |
| 35 | CG, medium-high | plan `:472-474, :518-522, :582-593, :1055-1058` | Pre-dispatch missing prerequisites "may be repaired on the same SHA … no attempt was consumed", but attended cases run only in the full matrix, `m7-operator` refuses `--only`, the runner "visits each manifest case once" with no resume, and the index says "interruption leaves a consumed unresolved entry". Scenario: cases 1–6 of the attended block pass, case 7 stops pre-dispatch; the only way to reach it is a second full invocation that pays for and re-rolls cases 1–6. The scaffold has no slot for a second same-candidate invocation. | None. | A `not_dispatched` index state; full-matrix resume keyed by the index that never re-dispatches completed cases; one Pending scaffold value for the index reference, head digest and count. | No |
| 36 | CG, medium | plan `:475-481` | "Source/configuration changes must address that cause" beside the exclusion of a repaired environment or newly available attendance. Scenario: the operator's SSH session drops after `m7.feature` dispatched; no source defect exists. Whether a committed runner or runbook procedure change qualifies is unstated: if not, closure is unreachable; if any documentation edit does, the rule is hollow. | No. | State that a committed, reviewed change to the runner or attendance procedure qualifies when the reviewer judges it would have prevented the loss; otherwise route to menu item 3. | No; stays inside choice A |
| 37 | IO with CG, medium-high | plan `:582-590, :1055-1058`; `scripts/check-release.sh:176-198` | The attempts index has no path, format, writer, integrity mechanism or cross-machine story; the runner's retain directory is a fresh `mktemp` per invocation. A pre-merge `--only m7-provider` miss on another machine is invisible to the candidate author, making the closure run a reroll. | No. | Mandatory index path for any paid M7 dispatch; hash-chained entries; the scaffold commits head digest and count; the runner refuses unless the supplied index extends that head. | No |
| 38 | CG, medium-high | plan `:468-469, :519-521, :588`; `AGENTS.md` pre-merge lane rule | `--only` takes lane IDs; a failed unchanged case may not run again without disposition; the selected unattended lanes are required before a provider change merges. Scenario: a pre-merge `m7-provider` run records a model omission in `m7.pipe-answer`; the next provider change must skip the case (forbidden), run it (a reroll) or refuse the lane. "After declaring a closure candidate, no extra paid --only" uses an undefined event. | No. | The runner refuses a lane holding a case with an unresolved prior failure and reports evidence unavailable for that merge; bind "declaration" to the tested implementation SHA. | No |
| 39 | IO, medium | plan `:522-530, :939-940` | Case ceilings are "pinned in the manifest" with no numbers; the mechanical result for an exceeded ceiling and the state of later undispatched cases are unstated; lane order is unstated, so a late `long_bound` flake after about eighteen attended provider cases costs a candidate. | No. | State the exceed mapping; mark later cases `not_dispatched`; run fresh-source build, rollback, `node_client`, `long_bound` and legacy unattended lanes before the first paid M7 dispatch; print the summed ceiling first. | No |
| 40 | IO, medium | plan `:550, :943-944, :994, :1013-1017` | The mandatory attended table lists V13.1 and V13.4–6; the only V13 owner is `m7.rollback` in the credential-free, `--only`-eligible lane; the evidence task must fail "a reduced attended classification". | The validator would reject the manifest or the steps are silently automated. | Add an operator-lane row (for example `m7.restore`) keyed to `m7.rollback`'s execution record. | No |
| 41 | IO, medium | plan `:549, :557, :703-715, :855-861` | `m7.interrupt` and `m7.daemon-detach` require an active run; a provider answering in two seconds settles the run first and the case fails as a harness-caused `product_failure`. V4 has a barrier; these do not. The daemon case has no stated fixture-policy injection point. | No. | Reuse the FIFO and observer-join barrier for both. | No |
| 42 | CG, low-medium | plan `:1083-1085, :1096-1097` versus `:519-520`; `scripts/lib/release-lane.sh:11` | "Required new selectors cover coding tasks, piped/attended chat, thinking/tool continuation, A→B→A …" contradicts the lane-ID-only rule; the relation of `m7-rollback` to the existing `rollback` selector is undefined. | No. | Reword as coverage; state the relation. | No |
| 43 | CG, low-medium | plan `:928-947, :1253-1260`; `docs/developer/verification.md:102-103`; `scripts/check-release.sh:200-218`; `AGENTS.md` maintainer-override rule | Today the lane crosses v0.2.0 with the candidate; the plan freezes v0.2.0↔v0.3.0 and adds v0.3.0↔candidate, so the candidate is no longer crossed with v0.2.0 and the frozen pair cannot fail from any candidate change. That changes what the check proves and is not recorded as such. Feasible as specified. | Not applicable. | One sentence naming the retired pairing and why, and the verification-guide update with the implementation. | Covered by plan acceptance if stated |
| 44 | IO, low-medium | plan `:711-714, :812-817, :869-871, :1007-1011, :1064-1065`; `scripts/check.sh:170-173` | `mix loopex.m7_evidence` runs "once a manifest exists" (silently skips if renamed), placement relative to the `--docs` exit is unstated, and the release preflight does not call it. V10.1 reads as selecting the external task inside the attended block while `:1064` requires selection before the invocation. The "independent observer attachment" names no channel; the Model-port cancel gate is a second trusted override not listed with the policy injection, and the cancel case proves a pre-transport hold, not in-flight cancellation. V11.1, V11.2 and V11.5 need subkeys. | Partly. | Run the task unconditionally before the `--docs` exit and from release preflight; reword V10.1; name the channel and add the gate to the override list. | One sentence of intent on pre-pin trials of the external task |

Step-by-owner coverage: every provider-backed step now has exactly one owner;
no step has two. Weak owners are V9.2 and V9.4 (precondition not enforceable,
finding 41), V13's attended steps (finding 40) and `m7.external` (oracle exists
only once pinned). No repair adds a paid retry by intent or drops a check; the
reachable paid repeat is finding 35 and the only change in check meaning is
finding 43.

### Vision, amendment paths and successors

| # | Class | Where | Conflict | Checks | Smallest repair | MI |
| --- | --- | --- | --- | --- | --- | --- |
| 45 | CG, medium | ADR 0013 concept `:60-72`; `0043` concept `:9, :25-30, :80`; `0043-T:34-35, :168-169`; plan `:39` | ADR 0013: the first staged model request commits the absolute deadline and none exists before it; ADR 0043: automatic compaction "runs at initial … model staging" and "consumes the run's … deadline budgets". A summary request before the first ordinary request is either ADR 0013's first request or runs with no committed deadline. ADR 0041 handles its own pre-staging bound explicitly; ADR 0043 and the plan row do not. | No cut at pre-first-staging. | One sentence saying which request commits the deadline; add ADR 0013 to the header and plan row. | No |
| 46 | CG, medium | `0041` concept `:9`; `0041-T:248-249`; ADR 0028 technical `:22-31, :60-70`; plan `:34-51` | Header "Preserves … ADR 0028 … transfer guarantees"; technical "one job-owned verified transfer window per read"; ADR 0028 ties transfers to an attachment with per-connection and per-runtime ceilings and a cumulative work allowance. Whether job transfers count toward the four-per-runtime limit, and what bounds verification of up to 64 MiB per 4 KiB read, is undefined. | Ceilings untested. | "Extends ADR 0028 with a job-owned transfer", its accounting in one paragraph, and a plan row. | Only if a new budget number is introduced |
| 47 | CG, medium | `docs/plans/M7.md:338-340`; plan `:14-18, :1186`; ADR headers | The packet rule relies on Depends-on lines that omit real reliance: 0041 writes into ADR 0044's genesis member and ADR 0043's failure union; 0044's genesis embeds ADR 0046 and 0041 members; 0045 uses 0044's option union; 0049 activates 0043, 0045 and 0046 features (an undeclared 0046↔0049 cycle). By the letter, ADR 0041 alone authorizes outcome 1. The §13.4 amendment is stated as a prerequisite for outcomes 4 and 7 while ADRs 0042, 0043 and 0049 depend on ADR 0044, so 2, 3 and 6 are gated too. Technical drops the Concept's "no partially accepted set" clause. | None. | State that ADRs 0041–0049 and both vision amendments are one coordinated exact-byte packet in both plan files, and correct the outcome list. | No |
| 48 | CG, low-medium | plan `:37-43`; `docs/plans/M7.md:361-364`; ADR headers | Missing from headers or the plan table: ADR 0008 (create variant and resolver, row says "no activation or mutation authority"); ADR 0011 (standalone-maintenance abort); ADR 0016 (abandonment for all conflicting resume flags; supplied runtime configuration in live create); ADR 0017 (refusal v2 with `measurement_scope`); ADR 0018 (reply `completion` member); ADR 0021 (header says "extends", technical says "explicitly amends" the writer clause). | No. | Six short row or header edits. | No |
| 49 | CG (hidden scope), low-medium | `0049` concept `:47-49, :66`; `0049-T:94-97, :128-130, :187-198, :274, :280-284`; `0043-T:161-165` | Concept: "Chat has text output only"; Technical defines a versioned machine-readable `@loopex` control-line surface, the exit-status rule, abandonment for every conflicting flag and task-binding refusal. ADR 0043's unavailable session is Technical only. | No. | One Concept sentence each. | No |
| 50 | OI | `docs/developer/agent-context-map.md:59`; `docs/vision.md:554-556`; `docs/evidence/README.md:45`; `docs/vision-technical.md:3084`; M8/M9 drafts | The routing row still omits the continuation disposition although the disposition record says it names it; the second Concept sentence on the prompt target still counts only question and helper definitions; a blank line splits the evidence index table so the round 4 rows render without a header; the §25 risk row "opaque … sidecar" is touched by §13.4 and unlabelled; neither successor draft schedules the configuration-schema successor and M9's Concept is silent on the ledger. | Not applicable. | Five one-line edits. | No |

Verified as consistent: every governing vision clause is present verbatim
against `20ff082a` and the header names every section touched; the AGENTS
reversal rule is satisfied for both amendments; ADR 0036's successor-schema
sentence agrees with ADR 0049's closed version 1; M9 row 2, ADR 0036 and M8
agree on Store-record migration with the ledger unchanged in place and in
whole-root backup; the new Store callback is in the inventory; roadmap,
register, evidence index and ADR README make no claim that a check, review,
probe or receipt proves product behaviour or acceptance.

### Reconciliation of the 55 round 4 findings

**R** repaired, **P** partly repaired, **X** declined as recorded. Finding
numbers in "residue" refer to this report.

| # | Verdict | Evidence at the candidate, and residue |
| --- | --- | --- |
| 1 | R | `0043-T:14-18, :73-74, :336-347, :537-540`; residue 1, 3 |
| 2 | R | `0044-T:263-267, :388-392`; `0043-T:322-329`; residue 6 |
| 3 | R | `0043-T:118-119, :151-152, :161-165, :267-269`; residue 7 |
| 4 | R | `0043-T:413-417, :380-382`; residue 8 |
| 5 | R | `0043-T:424-456`; concept `:9`; residue 4 |
| 6 | R | `0049-T:210-214`; `0049` concept `:56-58` |
| 7 | R | `0041-T:211-216` |
| 8 | R | `0043-T:67-68, :391-393`; residue 2 |
| 9 | P | values pinned `0044-T:160-164`; bootstrap `:177-185`; admission state machine undecidable (17) |
| 10 | R | `0044-T:603-610` |
| 11 | R | `0044` concept `:9`; `0044-T:383-387`; header wording (48) |
| 12 | R | `0044-T:259-260, :388-394`; new obligation 20 |
| 13 | P | `0044-T:198-209`; Finch hooks and header allowlist unnamed (21) |
| 14 | R | `0044-T:520-530`; residue 23 |
| 15 | R | `0044-T:177-185, :791-797`; plan `:1106-1110`; not selected, as recorded |
| 16 | R | `0044-T:219-222`; residue 22 |
| 17 | R | `0043-T:15, :84-87` |
| 18 | R | `0044-T:816-825` |
| 19 | R | `0041-T:72-93`; `0044-T:36-38`; residue 12 |
| 20 | P | `0041-T:227-246, :321-324`; membership position and executor digest open (10, 11) |
| 21 | R | `0049-T:112-119`; plan `:609-611` |
| 22 | R | `0049-T:94-97, :360-361`; plan `:912-914` |
| 23 | R | `0049-T:128-130`; residue 15 |
| 24 | P | `0049-T:255-278, :352-355`; resolver unnamed, records under-determined (13, 14) |
| 25 | R | `0041-T:75-77`; plan `:128` |
| 26 | R | plan `:117` |
| 27 | R | `0041-T:81-83, :89-90` |
| 28 | P | `0046-T:334-344, :360-370`; concept `:67-74`; stale sentence, unnamed term, no expiry (26, 27) |
| 29 | R | `0046-T:593-611, :629-630`; residue 30 |
| 30 | R | `0046-T:82-84, :185-207`; concept `:9`; residue 31 |
| 31 | R | `0046-T:432-436, :468-469`; residue 32 |
| 32 | R | `0046-T:125-129, :632-634`; residue 32 |
| 33 | R | `0046-T:178-182` |
| 34 | P | `0046-T:348-355`; margin stacking and scope ambiguous (28) |
| 35 | R | plan `:1203, :1234-1235`; ADR 0036 technical `:95-97` |
| 36 | X | `0046-T:503-507`; namespace not selected, digest join present; not re-raised |
| 37 | P | plan `:442-481`; environment cell, non-code correction, pre-dispatch resume (34, 35, 36) |
| 38 | P | plan `:582-593`; index integrity, declaration scope, blocked-lane behaviour (37, 38) |
| 39 | R | plan `:548-549, :560-562, :571-577` |
| 40 | P | plan `:511-532`; no numbers, exceed route or order; selector list survives (39, 42) |
| 41 | R | plan `:1007-1011`; residue 44 |
| 42 | P | plan `:710-714, :810-817`; observer channel unnamed, cancel uses a Model-port gate (44) |
| 43 | R | plan `:928-947, :550`; residue 40, 43 |
| 44 | R | plan `:1060-1065` |
| 45 | R | plan `:1044-1046` |
| 46 | P | plan `:14-16`; `M7.md:44-47, :356-360`; `0044` concept `:10`; ADR and plans READMEs; context-map row `:59` unchanged (50), scope understated (47) |
| 47 | R | `0044` concept `:53-57`; `vision.md:320-322`; `vision-technical.md:1672-1676`; plan `:1166`; new residue 18 |
| 48 | R | ADR 0036 technical `:138-142` |
| 49 | R | `0049` concept `:30-38`; residue 49 |
| 50 | R | ADR 0036 concept `:64-66`, technical `:89-94`; M9 technical `:30` |
| 51 | R | `vision.md:326-330`; `vision-technical.md:1686-1691` |
| 52 | R | `M7.md:338-340`; plan `:16-18, :1186`; residue 47 |
| 53 | P | `vision.md:356-357` repaired; `:554-556` not (50) |
| 54 | R | header and notes at `vision-technical.md:12-19, :330-332, :1121-1123, :1465-1468` |
| 55 | R | `docs/plans/README.md:32-38` |

### Review limits

- No build, product test, check, release lane or provider call was run and no
  credential was inspected. Every behavioural statement is from reading text
  and source at the candidate.
- Provider behaviour is unverified: Haiku 4.5's default display being
  summarized, the provider's handling of an assistant `tool_use` without
  thinking followed by results and text, the exact response-model string for
  Fable, acceptance of the tools beta header with these models, and real
  signature and summary sizes. The packet's cited provider documentation was
  taken as documented intent, not as proof of pinned ReqLLM behaviour; pinned
  dependency facts above were read from `deps/req_llm`. No new provider
  research was fetched this round.
- Cross-OTP byte stability of deterministic term encoding was not verified.
- Token and byte figures in findings 1 and the compaction walks are estimates
  at the bytes-over-three estimator; no scratch calculation was retained
  because none was written to disk.
- The advisory readers read their owning ADR pairs in full and adjacent
  accepted ADRs by targeted section; the root reviewer read the disposition and
  all technical diffs since `018c271c` in full and spot-verified the claims
  behind findings 1, 2, 13, 17, 18, 25, 26, 34, 42, 46 and 50 at the cited
  lines. Rows marked R were checked at the cited passages and surroundings,
  not by a complete reread of every file.
- Planned artifacts (`test/fixtures/m7`, the two M7 scripts, `LoopexCli.Chat`,
  `mix loopex.m7_evidence`, the attempts index) do not exist, as expected.
- Scratch artifacts: none. Repository state before and after: HEAD
  `a2ce04c2862d2d15e58eed317379a3b6684c4286`, branch `m7`, clean.
