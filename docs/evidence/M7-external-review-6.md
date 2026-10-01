# M7 external review, round 6

Date: 2026-09-30 local (handoff artifacts are stamped 2026-10-01 UTC).
Reviewed candidate: `07b1a19cb7fdcab3155778f1119c043d23ba0d72` on branch `m7`;
previous reviewed candidate `a2ce04c2862d2d15e58eed317379a3b6684c4286`.

**Identity verification, all passed before any reading.** HEAD equals the
candidate, branch `m7`, zero status lines. Observed SHA-256 values:

| Artifact | SHA-256 | Check |
| --- | --- | --- |
| Readiness receipt `/tmp/loopex-m7-round5-readiness.json` | `90139c577d333a16ba58c64b1071b1dadd3f437642763fb1d39941adde0bb803` | No expected digest was supplied for the receipt itself; every digest it binds matches, below |
| Contract manifest `/tmp/loopex-m7-round5-contracts.json` | `d32129e601e0dca8a5a541bb254911eff4f468e8adfdb5512c2aa3927ff9b1f5` | Matches receipt; all 55 listed files match the working tree, 0 mismatches |
| Host documentation log `…-07b1a19c-docs-host.log` | `bf12fb9485eca3a98a4695a08ef167ea2e79345be803d2d78bc87a5d0ab7ad43` | Matches receipt and result file |
| Host result `…-docs-host-result.json` | `cd31f49e5769bd342b7f3fafc95d2d6c712980ef0c8bb792366081545b61e601` | Matches receipt |
| Blocked first log `…-07b1a19c-docs.log` | `9f01692f192790e9370fd49373a112f1e2d289be442c60bfc1a5d5aab0fa88d6` | Matches receipt and its result file |
| Blocked first result `…-docs-result.json` | `9fced4eb8c485a67beae5a4660da3753d03435537e2644843f8564c54d90c30f` | Matches receipt |
| Round 6 prompt | `c084eff2f560f41d88fefd16e21a894947a13d0a0ea157df8b5e8638a0fe7f09` | Matches receipt |
| Retained round 5 report `docs/evidence/M7-external-review-5.md` | `4a6567f11620eb3a09e8a0a7ccead61cade8e7a120c375bf3401eaa715bff74e` | Matches the stated digest |
| Round 5 disposition | `6c607ae8462d4531c4241e6b48b91c4ecd811031f80c7e24fe70058fb8158ba3` | Matches receipt |
| Remote confirmation, internal brief | `cd18d77f…c649`, `bf13ce50…ffe1` | Match receipt |

The host log names the candidate SHA, `clean_before=true`, `clean_after=true`,
`head_after` equal to the candidate, the complete step output and
`check_exit_code=0` in 15.547 s. The first log exits 1 in 0.962 s at Mix's TCP
filesystem lock (`:eperm`), before compilation; it contains no product
assertion and is evidence unavailable, not PASS. The passing check proves
structure, compilation, formatting and documentation ordering only. The remote
SHA is taken from the receipt's retained `git ls-remote` output; I made no
network call to re-confirm it.

**Constraints, labelled as they actually were.** This session's tools are not
an enforced read-only sandbox. The review used read-only commands in the
repository: no file edited, no branch switched, no commit, build, product test,
check, release lane or provider call, and no credential inspected. Six
read-only advisory readers covered disjoint areas under the same constraints;
the root reviewer read the disposition and every diff since round 5 directly
and re-read each load-bearing claim below at the cited path before including
it. Repository state after the review: HEAD `07b1a19c…0d72`, clean.

## Concept

**Verdict: not ready for acceptance yet. This is the narrowest gap of any
round, and nothing found requires reopening a recorded scope choice.** Of the
50 round 5 findings, 43 are repaired and 7 partly repaired; none was rejected.
The six round 5 blocker families are closed in their original form: a refused
helper call no longer fences its parent, pending summaries are validated before
commit, piped unknown admission has a producing resolver, the candidate
thinking state is gone, the verdict table has its fifth route, and the
amendment wiring names what it changes. Status text is honest throughout. No
repair drops a required check or adds a paid retry by intent.

This round has 37 findings: 25 contract gaps, 8 implementation obligations and
4 optional improvements. Most gaps are one- or two-sentence repairs, and most
are second-order joins exposed by the round 5 repairs themselves. Six families
still block acceptance.

1. **The post-terminal thinking witness conflicts with documented provider
   behaviour.** The plan now requires that the reply after a bound or cancelled
   tool run "used native thinking" for all seven continuation-required cells.
   The rendering it tests sends the old tool turn without its thinking blocks.
   Current provider documentation says that in manual mode the final assistant
   turn must begin with a thinking block, and that an incompatible history
   makes the API silently disable thinking for that request. On the documented
   reading the three Haiku manual witnesses cannot pass as written, and the
   contract forbids downgrading a cell and names no route for a provider
   rejection that no product correction can fix. This is documented intent, not
   a live observation.
2. **The closure procedure still has undecided joins.** Whether a new candidate
   after an outage reruns one case or the whole matrix is readable both ways.
   No rule says whether the matrix stops after a consumed failure. A ceiling
   breach is assigned a causal verdict that contradicts two rows of the verdict
   table. Rate limits, quota exhaustion and loss of the runner's own network
   have no verdict. Resume changes what "the release check runs once" means
   without a Concept sentence. The campaign-index pin does not prevent what the
   text says it prevents.
3. **Compaction has three reachable states without a rule.** The new fixed
   60-second preparation cutoff has no terminal cause. Ordinary explicit
   compaction has no stopping rule, so one `/compact` is one paid call or four.
   A small unit ahead of an oversized one makes strict progress impossible and
   charges one call per episode with no way forward.
4. **Helper recovery has four residual holes.** A refusal that was not yet
   committed when the host died, or a call cancelled after its intent, still
   fences a parent already at its allowance. The startup classification
   deadline has no value, scope or exit. Most adapter refusals have no named
   term. Cancelling a registered job before its reservation has no rule.
5. **Thinking configuration joins.** An unregistered model at `default` is
   both admitted and refused. The reference default is an alias with no stated
   commit rule. The header allowlist excludes a header the buffered transport
   always sends. The plan's scenario still describes one thinking mode where
   the decision record requires seven attended subcases.
6. **Records and hidden scope.** The recorded section 13.4 drafting
   authorization is narrower than the drafted text. ADR 0041 changes ADR 0009's
   per-call order without naming it. Four observable behaviours live only in
   Technical files. The vision header omits its section 25 note.

**Smallest necessary repairs.** Families 2 to 6 need text only: about thirty
sentences across the plan pair, five ADR pairs, the vision header and the
context map. Family 1 needs one decision first.

**Genuine maintainer decisions.** Three, none re-raising a recorded choice.

- **What the post-terminal witness must prove.**
  - *Option A (recommended):* the witness asserts provider acceptance, correct
    facts, exact outgoing mapping and no resurrected native state; native
    thinking is then asserted on the next exchange that follows a completed
    assistant turn. This keeps nine cells and all counted cases.
  - *Option B:* keep the strict oracle. If the documented behaviour holds, the
    manual cells cannot close and each failure costs a candidate plus a scope
    amendment.
  - *Option C:* register the manual cells with post-terminal rendering
    unsupported, so those sessions need explicit compaction after a cut run.
    This narrows the ordinary-availability choice for three cells.
- **Whether a rate limit, quota exhaustion or loss of the runner's own network
  counts as the reviewed outage.** Including them keeps closure from depending
  on account limits; excluding them leaves only a scope amendment as the route.
  Either is consistent with choice A; the text must say which.
- **The exit when helper-history classification cannot finish at startup.**
  Today every start rescans from zero and a root that exceeds the unnamed
  deadline is unusable with no remedy. Options: a named fixed bound with
  resumable scan progress (recommended), a bounded configuration key, or a
  recorded limitation with backup restore as the only exit.

## Technical depth

Abbreviations: `P` is `docs/plans/M7-technical.md`; `PC` is `docs/plans/M7.md`;
`NNNN-T` and `NNNN-C` are the technical and concept files of that ADR; `SC` is
`apps/loopex/lib/loopex/runtime/session_coordinator.ex`; `SS` is
`apps/loopex/lib/loopex/runtime/session_state.ex`; `RL` is
`deps/req_llm/lib/req_llm`. CG is contract gap, IO implementation obligation,
OI optional improvement. "Caught" states whether a planned check catches it.
"M" states whether maintainer input is needed.

### Compaction (ADR 0043)

| # | Class, severity | Path and conflicting contracts | Reachable scenario | Caught | Smallest repair | M |
| --- | --- | --- | --- | --- | --- | --- |
| 1 | CG, medium-low | `0043-T:40-42` "fixed pre-staging preparation deadline of admission_time + 60,000 ms … recovery cannot renew it"; closed causes `0043-T:429-436` contain no compaction-preparation deadline; `0043-T:467-470` copies "the owning run's exact bound measurements"; ADR 0013 concept `:75-76` "Before the first staged-request commit, the run has no absolute deadline to expire". ADR 0041 names its equivalent (`0041-T:219-220`, `artifact_preparation_deadline`). | A prompt on an over-limit settled session admits an episode; the owner dies before the first maintenance request is staged; restart 61 s later. The cutoff has elapsed, no run instant exists to copy, and no cause names the condition. Slow bounded traversal reaches the same state live. | No. `0043-T:616-617` fixes no outcome. | Add one closed cause, worded like ADR 0041's; say which episode failure accompanies the existing deadline-staging failure; one Concept sentence and one vector. | No |
| 2 | CG, low-medium | `0043-T:97-98` "may produce a useful bounded checkpoint even if the current model window already fits"; `:349-352` "the bounded episode then consumes another prefix"; `:362` "For size/headroom triggers, stop once the applicable limits/targets fit"; rendering has its own rule at `:355-356`; ordinary `explicit` has none. | `/compact` at 4/60,000/32,768 on a fitting session with about 50 KiB of eligible history. One reading stops after the first checkpoint (`checkpointed`, one call). The other continues until attempts run out (`failed`, `bound_reached`, four calls). | No. `:585-587` uses a sole group; `:624-625` presupposes a missed target. | "Ordinary `explicit` stops after its first committed checkpoint", or the alternative stated as plainly. | No; the first reading matches "a useful bounded checkpoint" |
| 3 | CG, medium-low | `0043-T:85-90` "select the largest contiguous prefix … that fits … the 16,384-byte encoded source envelope"; `:104-105` the excerpt form applies only "If no complete prefix fits" and covers "exactly the oldest eligible unit"; `:349-350` strict decrease in bytes and tokens; `:358-359` failure ends `compaction_no_progress`. | The oldest eligible unit is a short greeting exchange; the next is one of the ADR's own profiles (`:577-578`, "a 14-KiB write or four 4-KiB range results") that cannot join it under the cap. The largest fitting prefix is the small unit alone, so the excerpt form is unavailable. Its summary cannot be strictly smaller than the unit. The episode ends after a paid call, and each later prompt opens a new episode with the same deterministic selection. The size estimate of summary framing is the reader's, not measured. | No. `:568-571, :577-581` place the large unit oldest or newest. `m7.long` and `m7.oversized-source` are exposed unless their fixtures avoid the shape. | When the unit after the largest fitting prefix cannot join it, extend selection through that unit using the excerpt form; bump the strategy revision. Alternatively record the limitation and add the vector. | No for the repair; the limitation alternative would need acceptance |
| 4 | IO, low | `0043-T:131-133` requires "deterministic adapter evidence" at maintenance admission, but core receives only `{model, reasoning, model_capabilities, provider_mapping}` (`:125`) and no cause names the refusal. | A direct embedder with a v2-only adapter passes core validation, pays one dispatch, then fails `maintenance_summary_incomplete`. | The post-dispatch half is (`:601-602`). | Say the gate is a host registration condition and core's guarantee is the post-dispatch failure. | No |
| 5 | IO, low | Literal pins owed: the refusal code for `compact` during an active run (`0043-C:30-31`; ADR 0011 technical `:59`); the bound literal, since the existing run terminal uses `"deadline"` (`SS:1203-1205`) and `0043-T:468` says `deadline_ms`; `0043-T:501-502` "Exhausted attempts/usage/deadline retain the existing bound outcome" reads against `:471-472`; which transaction reads the standalone cutoff clock (`:44-47, :475`); whether episode and run terminals share a transaction for non-refusal endings (`:440-443`); the category for an adapter-unreadable summary reply (`:341-342`). | Each is decidable by an implementer but yields two shapes. | Vectors will expose them. | One clause each; prefix `:501` with "Standalone". | No |

### Artifacts, configuration and piped chat (ADRs 0041, 0049)

| # | Class, severity | Path and conflicting contracts | Reachable scenario | Caught | Smallest repair | M |
| --- | --- | --- | --- | --- | --- | --- |
| 6 | CG, low | `0049-T:195` `wait` carries "`run_id` or null … `outcome` or null"; `:202-203` outcomes "use the public outcome object"; `:287-288` "Use settled with run/outcome null only if no admitted foreground operation exists"; `:322-326` exit counts "every admitted run/maintenance operation"; `0043-T:505-508` gives standalone compaction its own result payload with no run outcome. | A piped script sends `/compact` then `/wait` and the compaction fails. The closed record fits null/null, the last run's outcome, or the compact result, which is not the public outcome object. The same hole affects the unknown-admission table when the unknown command was `/configure`, `/compact` or `/answer`. | No oracle is fixed (`0049-T:398-401`). | One sentence: for maintenance and configure, `run_id` and `outcome` are null and the result appears in the transcript and exit code; or add a closed `operation` member. | No |
| 7 | IO, low-medium | `0049-T:263-271` "retains the original unknown proposal … No competing mutation is permitted"; source stops the coordinator when an internal commit meets the fence (`SC:2884`, `SC:7372-7373`). | Piped `/steer` during a live run, admission unknown; the model worker returns before a timer tick resolves it. One implementation stops the owner and loses the preimage; another defers the result. Both land on a documented table row, so the contract is decidable, but which row depends on an unstated choice. | No; the vectors can be met from a settled session. | One sentence: the owner defers internal proposals while an admission proposal is pending, or stops and reports owner loss. | No |
| 8 | IO, low | `0049-T:274-281` closed result has three states plus `owner_unavailable`; "Absence from a command index or timeout cannot produce not_committed"; `:298-299` "fences further mutations until ordinary resolution". | A live successor owner has neither the preimage nor a committed fact for the ID; a never-submitted ID hits the same state. In interactive chat, once the resolver deadline passes nothing produces "ordinary resolution". | No. | Say that state returns pending/`commit_unknown`; say that after the deadline only quit, EOF or interrupt remain. | No |
| 9 | IO, low | `0049-T:198` `error.code` is "a stable host error code" while table row `:312` emits "the original stable refusal code"; `P:1031-1033` V12.4 omits workspace mismatch, pending-policy mismatch and missing route, which `0049-T:128-130` now names. | A validator with a closed host enum rejects the row's value; three abandonment paths have no assertion. | Partly. | Widen the `code` domain sentence; add the three cases to V12.4. | No |
| 10 | OI | `0041-T:118-126` and `P:131` name new read, grep, find and ls generations only; `loopex.bash` keeps a 16,384-byte inline ceiling (`apps/loopex_executor_local/lib/coding_tools.ex:134-135`), so its output above 2,048 bytes takes the preparation path capped at 16 sources (`0041-T:184-186`). `0049-T:25` does not say whether `config validate` accepts ADR 0048's `{none: true}`. | Seventeen 3-KiB bash results in one turn refuse the next staging by count. Decidable and named. | Not applicable. | State that bash, write and edit keep their generations and use the preparation path. | No |

### Thinking continuation, settlement and bridge (ADR 0044)

| # | Class, severity | Path and conflicting contracts | Reachable scenario | Caught | Smallest repair | M |
| --- | --- | --- | --- | --- | --- | --- |
| 11 | CG, medium-high | `P:908-909` "Assert from bounded native-capture classification that the later reply used native thinking for each continuation-required cell"; `0044-T:672-680` renders the old tool turn "without old private blocks" and puts results and the new prompt in one user array; `0044-T:163-169` proposes `canonical_terminal_tool_history: true` for every row and "A failed positive case cannot silently change the value to false"; `0044-T:188-189` "cannot downgrade the descriptor, omit a cell"; `P:484-486` routes only "A legal refusal" to a scope amendment. Provider documentation retrieved 2026-09-30 through Context7 (`/llmstxt/platform_claude_llms_txt`; pages `build-with-claude/thinking` and `thinking-tool-workflows`): "in manual extended mode, the final assistant turn must begin with a thinking block, whereas adaptive mode does not have this requirement" and "If thinking is toggled mid-turn, the API will silently disable thinking for that request". | `m7.thinking-bound.haiku.low`, `.medium` and `.high`: the one-turn bound cuts after the first tool group; the later prompt renders a tool turn with no thinking block under manual thinking. On the documented reading the API disables thinking for that request or rejects it, the witness fails, and the cell may neither be downgraded nor routed. The four adaptive cells are not covered by that documented rule. Whether results plus new text in one user array counts as the same turn is unverified; no provider was called. This oracle was tightened in response to round 5 finding 24. | It is the check. It first runs in the pre-merge `m7-provider` lane, inside the counted campaign. | Decide the oracle (Concept, first decision), then one sentence in V7.7 and one in the route: a `product_failure` with no assertion-preserving correction, including provider rejection of a registered cell, goes to the named scope amendment. | Yes |
| 12 | CG, medium-low | `0044-T:133-134` "Unknown capability permits `default` only"; `:245-246` "an unknown default that may need private continuation cannot bypass that rule"; `:212-214`; the closed `provider_mapping` (`:112-116`) has no stated values for an unregistered model. | An operator configures an unregistered model, or a legacy session's model, with `default`. One sentence admits it; the other refuses it on a property the host cannot decide. If admitted, the revision strings and three Booleans are unspecified. | No. | Give the literal generic descriptor and choose the outcome: admitted with all three Booleans false, and an observed native thinking block under `continuation_required: false` fails the attempt. Align `:245`. | No |
| 13 | CG, low-medium | `0044-T:150-151` "The Haiku alias in the current reference default resolves to the dated identity below"; `:11` "exact `model` string"; `:262-263` "Exact aliases need an admitted literal mapping revision, never an inferred fallback"; source default `anthropic:claude-haiku-4-5` (`apps/loopex_llm_reqllm/lib/loopex/llm/req_llm.ex:60`). | Ordinary chat with no `--model`, and every legacy session whose last request names the alias. The text does not say whether the host commits the alias or the dated literal. Committing the alias leaves it without a table row; `m7.baseline.durable` then does not witness the Haiku default cell. | No; `P:1232` pins the dated ID for matrix cases only. | One rule: either the reference default becomes the dated literal, or host resolution canonicalises a pinned-catalog alias and commits the literal, legacy requests included. | No |
| 14 | CG, medium-low | `0044-T:230-232` header-name allowlist; `:563-564` buffered validation "immediately before OneShotHTTP1 issues the HTTP request"; source always adds `accept-encoding: identity` (`apps/loopex_llm_reqllm/lib/loopex/llm/req_llm/one_shot_http1.ex:219-222`, admitted at `:139`). | Every buffered ephemeral Anthropic request: validating final headers refuses all of them, or validation precedes the last header and is not final. | At implementation, by forcing a deviation from the literal list. | Add `accept-encoding` with the single admitted value `identity` for the buffered path. | No |
| 15 | CG, low | `P:875` "Select a pinned supported Claude thinking mode" (singular) and one `m7.thinking-rounds` row (`P:580`); `0044-T:191-201` requires seven `m7.thinking-rounds.*` and nine `m7.thinking-bound.*` subcases plus `m7.provider-switch.haiku.none` and `m7.maintenance.haiku.none`, neither named in the plan. | An operator following V7.3 runs one mode; the seven attended subcases exist only in the ADR table. | Partly, through the manifest validator. | Say "each of the seven continuation-required cells, as fixed subcases" in V7.3 and the case table; note the Haiku-none leg in V7.1 and the tool round in V1.3. | No |
| 16 | CG, low | `0044-T:374-376`: row 4 is keyed on "every other stop", so `tool_use` with zero calls and `end_turn` with calls are unlisted; `:675-686` omits an empty assistant message but applies the capability gate only when there is "no assistant completion". | A run ends naturally with an empty, no-call reply after tool results. Canonically a completion exists, the gate is skipped, and the rendered request has the unverified post-terminal shape. | No. | Row 4 becomes "every other stop/call combination"; an omitted empty completion counts as absent for grouping and the gate. | No |
| 17 | IO, low-medium | `0044-T:554-556` "disable external versions of those hooks"; pinned source reads the application-environment adapter unconditionally (`RL/streaming/finch_client.ex:254-259`) and adds the interleaved-thinking beta for any non-adaptive `thinking` option (`RL/providers/anthropic.ex:917-921, :970-978`), which `0044-T:234-235` refuses. | An implementer passes manual thinking through dependency options; every such request carries the forbidden beta and refuses after handoff, charged as `dispatched_or_unknown`. | Yes (`0044-T:797`, bridge test). | Say the invocation-owned per-request hook runs last and refuses any altered request, and that manual values are installed in the native body by the wrapper. | No |
| 18 | OI | `0044-T:183` "have status `ordinary`" beside `:185` "no … status member"; `:948` "candidate rows"; `:119-120` "either fact" now refers to three Booleans. | Wording only. | Not applicable. | Reword. | No |

### Helper registry, index and recovery (ADR 0046)

| # | Class, severity | Path and conflicting contracts | Reachable scenario | Caught | Smallest repair | M |
| --- | --- | --- | --- | --- | --- | --- |
| 19 | CG, low-medium | `0046-T:548-549` "no terminal or an unknown terminal is never proof of refusal"; `:576-580` "charge one conservative count slot … If expected operations exceed the retained count or storage bounds, refuse that parent's recovery"; the refusal's scope has three wordings: `:247` "helper admission", `:348-349` "affected activation", `:622-623` "before activating its affected parent"; `:442-443` maps a non-failed terminal without receipt to `outcome_unknown`; source commits `cancelled` after the intent when the deadline passes during the intent commit (`SC:5638-5645`). | `max_children: 2`, two settled. The third call's intent commits and the host dies before the exhaustion refusal is committed; or, with no crash, the run deadline passes during the intent commit. Restart sees three expected operations against two and refuses the parent's recovery, with no operator exit. The committed-refusal path of round 5 finding 25 is repaired; this is its uncommitted and cancelled remainder. | No. `0046-T:718-721` and V8.6 cover below the limit and the committed refusal. | One sentence fixing the scope: an over-limit expected operation with conclusively absent creation stays unresolved, helper admission for that parent is refused, and ordinary activation proceeds, consistent with `:232`. Classify the cancelled-after-intent terminal as pre-effect. | No; `:232` and `0046-C:95-97` already point this way |
| 20 | CG, low-medium | `0046-T:460-461` "Composition's startup recovery deadline applies between pages; timeout never means complete"; `:514-521` durable hosts "complete the scan below even when new delegation is disabled … deadline exhaustion that refuses incomplete classification"; `:646-647` full rebuild at startup; no value, owner, key, refusal scope or exit; no Concept sentence (`0046-C:99-107`). | An upgraded root with a long history and no helpers exceeds the deadline; every later start rescans from zero at 16 records per call and fails the same way. | Only that exhaustion refuses (`0046-T:689-690`). | Name the bound, state what is refused, state one exit, add a Concept sentence. | Yes, the third decision |
| 21 | CG, low | Named terms exist only for `router_registration_capacity` (`0046-T:341-342`), `cancelled_before_registration` (`:372`) and `helper_index_unavailable` (`:649-650`); unknown role, exhausted count or tokens, occupied slot, ledger capacity, closed admission and incomplete classification have none; core reads only the exact tagged tuple as a refusal (`SC:7147-7149`). | An adapter returns an untagged error for an exhausted allowance. Core commits `outcome_unknown`, ending the parent run, and restart charges a slot, against `0046-T:232`. Conversely a tagged refusal returned after the reserve append excludes an intent whose ledger holds a reservation. | Partly; `0046-T:686-688` names three reasons. | One sentence and a closed reason list: every definite refusal before the first ledger append returns the tagged tuple; after it, only a receipt or an untagged unresolved error. | No |
| 22 | CG, low-medium | `0046-T:351-352` "Known helper cancellation uses only its durable operation stop"; `:408-412` the stop relies on "reserved closing-record credit"; `:641` allows an index entry with `frame_offset` null. | Core aborts while `execute/5` is registered but not reserved. There is no reservation and no credit; a stop-only operation's effect on slot and count is undefined, and on restart the operation is neither absent nor reserved. An index write failure after reserve and before create also has no route. | No; `:701-702` is generic. | State that such a cancel appends nothing, the pending execute returns a tagged pre-effect refusal and the cancel answers cleaned; add the missing index-failure route. | No |
| 23 | CG, low | `0046-T:438` terminal rows require `tool_call_id`; `:444-446` "Conflicting or unsupported joins are invalid_history"; ordinary sessions hold terminals with no intent (policy denial `SC:6375, :6523`; invalid arguments `SC:5610-5615`), and `outcome_unknown_committed` carries only `run_id` and `reconciliation_ref` (`SS:1477-1481`). | If an unmatched terminal reads as an unsupported join, any session with a policy denial (V9.1) fails classification. The reconciliation terminal cannot fill a required member. | No. | "Emit terminal rows only for calls with an earlier intent in the captured prefix; for `outcome_unknown_committed`, join by run and allow a null call ID." | No |
| 24 | OI | `0046-T:339-340` says receipts "remain in the validated durable helper index" while `:636, :644` call it a disposable cache with "no independent receipt facts"; `:654-655` a transient cache fault and a truly unknown ID return the same error. | Wording. | Not applicable. | Reword; consider distinct errors. | No |

### Operator validation, verdicts and evidence (plan pair)

| # | Class, severity | Path and conflicting contracts | Reachable scenario | Caught | Smallest repair | M |
| --- | --- | --- | --- | --- | --- | --- |
| 25 | CG, medium | `P:463-468` "permit only that affected case again on a new candidate under the normal matrix rules … The new candidate records this diagnosis/authorization"; `P:492` "run the affected checks on a new candidate"; `P:509-510` no "cross-candidate evidence reuse"; `P:519-521` "executes each owning case once in the full closure invocation"; `AGENTS.md:171-176`. | An outage hits `m7.long` two hours into the closure matrix. One reading dispatches one case on the next candidate and carries the rest over, which `P:509` forbids; the other reruns about 26 provider cases, 18 attended. Pre-merge, an outage in `--only m7-provider` has no scaffold, so what the "new candidate" must contain is undefined. | No. | "A new candidate always runs its own complete closure matrix; no earlier result is reused. 'Only the affected case' means this verdict lifts the prior-failure fence for that case alone." Name the pre-merge carrier. | No for the first sentence; it follows from recorded choices |
| 26 | CG, medium-low | `P:555-557` stops the matrix only for a ceiling breach; `P:562-564` "Retain failures before entering the attended block; resume never repeats them"; today's runner stops at the first red lane (`scripts/check-release.sh:17, :320`). | `long_bound` fails, or the second attended case records `required_action_absent`. Under "continue", some twenty further paid cases run on a candidate that cannot close, their passes are unusable, and each later miss becomes a retained prior failure: an unapproved paid look-ahead in effect. | No. | "Any consumed non-pass mechanical result stops the logical matrix before the next dispatch; later cases are not_dispatched and that matrix is not resumable." | No |
| 27 | CG, low-medium | `P:555-556` "A ceiling breach is assertion_failed and product_failure unless missing evidence prevents classification"; `P:450-452` the reviewer assigns the cause; `P:461` outage row; `P:460` attendance row. | A degraded provider streams slowly past the ceiling with complete evidence: the sentence says `product_failure`, which needs a correction that does not exist; the table says `environment_failure`. An operator slower than the hold: `product_failure` against `evidence_unavailable`. | No. | "A ceiling breach is mechanical `assertion_failed`; the reviewer assigns the cause verdict under the table." | No |
| 28 | CG, low-medium | `P:461` "external provider/network outage after dispatch"; `P:469-470` excludes only invalid credentials or routes, local harness faults and unconfirmed cleanup; `P:662-668` a paid case is `started` before its first call. | HTTP 429 or quota exhaustion across some sixty calls; loss of the runner host's connectivity; a first call whose connection never completes after `started`. None is a model miss, a product fault or missing evidence, and "dispatch" means both case start and transport. | No. | One sentence enumerating the class and defining "after dispatch" as after the case's `started` record. | Yes, the second decision |
| 29 | CG, low-medium | `P:541-547` adds `--resume-matrix`, a second invocation on the same SHA, as "one logical closure matrix, not a second full check"; `AGENTS.md:174` "`bash scripts/check-release.sh` once"; `docs/developer/verification.md:37, :110`; `PC:308` has only the word "logical" and no mention of the attempts index, campaign, resume or `--pins`; the context map records the rollback retarget (`:6376-6386`) but not this. | The same standard that round 5 finding 43 applied to the rollback retarget: a change to what a check proves, accepted without a Concept sentence. | No. | One Concept bullet beside "Rollback proof" and a matching context-map line marked proposed. | Covered by plan acceptance once stated |
| 30 | CG, low-medium | `P:620-622` "A fresh unrelated index cannot hide an earlier attempt", but `P:649-652` makes genesis a function of committed data ("genesis binds only the campaign ID and codec version"), so a regenerated genesis passes the pin; the only committed anchor is the scaffold head at candidate commitment (`P:642-644`). `P:644` "missing history or a mismatch refuses dispatch" with no rule for a lost index. `P:627-628, :632` a host that relinquished keeps a marker that refuses it after a correct handoff back. | A truncated or recreated index during the pre-merge paid period is undetectable; a lost index after candidate commitment makes closure unreachable; an A→B→A handoff leaves A refused. This is round 5 finding 37 with one more step. | The phase-0 handoff tests cover none. | Commit the head digest and count with each change a paid pre-merge run gates, or soften `P:621-622` to the trusted-procedure claim; state the lost-index rule; a marker is superseded only by a verified later acceptance naming that host. | Only if a successor campaign is to be allowed |
| 31 | IO, low | One mechanical result must be emitted (`P:446-449`) with no precedence or criterion for `provider_environment_failure`; the closed case event (`P:652-655`) has no matrix ID although resume keys on one (`P:541, :671-672`); "logical-matrix invocation-log references" (`P:676`) is a variable-length list in a closure child that may add no row (`docs/developer/milestones-technical.md:226`); `P:642` and `P:675-677` name two head slots as one. | A 5xx before the first byte in `m7.feature` is three results at once, and the label enters an immutable index. | Vectors will expose them. | State precedence and criterion; give the matrix ID a member; predeclare one digest cell; separate the committed and Pending heads. | No |
| 32 | IO, low | `P:594-595` gives no decidable lane for `m7.trace.json`, which owns unattended V11.4 and attended V11.5 (`P:1116`); `P:1134-1135` requires canonical paths "after M7 implementation lands", which is not a mechanical predicate; V9.4 names no observer channel for the daemon host (`P:973-976`); the position of the two legacy attended rows is unstated (`P:562-563`). | The validator fails "a reduced attended classification" for the trace case. | Partly. | State the lane; add both files in the commit that adds the task; name the observer connection; state the legacy attended position. | No |

### Vision, amendment paths and records

| # | Class, severity | Path and conflicting contracts | Consequence | Caught | Smallest repair | M |
| --- | --- | --- | --- | --- | --- | --- |
| 33 | CG, low-medium | `docs/developer/agent-context-map.md:6325-6336` records the 13.4 authorization as "core validates bounded envelopes/local references and adapters interpret provider blocks; private plaintext continuation stays with raw history"; the words "descriptor" and "gating" appear nowhere in that file; `PC:45-47`, `docs/vision.md:320-322`, `docs/vision-technical.md:1672-1673` and `0044-C:10` cite that anchor for the retained host-resolved descriptor. | The repository's authority record shows a narrower grant than the drafted proposal. This round's prompt states the fuller authorization, so the gap is in the record, not the scope. | No. | One sentence in that disposition recording the retained closed descriptor as gating data. | The maintainer's own words are needed for the record; no new decision |
| 34 | CG, low | ADR 0009 technical `:180-191` fixes validation, then policy, then intent; `0041-T:227-241` inserts owner refinement and committed-membership resolution before policy and attaches `resolved_artifact` after allow; `0041-C:9` and `P:45` name only "validated-argument construction" and "read ranges/resolved arguments". | An implementer reading ADR 0009 as governing step order has no named authority for the inserted step. | No. | Add the clause to the header and plan row; one "amends ADR 0009" clause at `0041-T:227`. | No |
| 35 | CG, low-medium | Technical-only observable behaviour: `0044-T:445-450` makes all nine v2 Model-port keys mandatory while `0044-C:167-168` says "Old requests and settlements keep their original meanings" (source type `apps/loopex/lib/loopex/model.ex:133` is optional); `0046-T:514-521` helper-disabled durable hosts pay the full scan while `0046-C:19` calls the helper opt-in; `0043-T:493-495` `maintenance_active` refusals; `0043-T:40-41` the 60-second cutoff. | An embedding caller's own Model adapter starts failing every reply after M7 with nothing in a Concept file disclosing it; an operator meets a refusal or cutoff no Concept sentence predicts. | No. | One Concept sentence each; add "mandatory nine-key v2 replies" to the 0044 header's ADR 0018 clause. | No |
| 36 | CG, low | `docs/vision.md:12-19` and `docs/vision-technical.md:12-19` enumerate sections 6, 10, 14, 23, 26, 5, 12.3, 13.4 and 27 and end "Other vision boundaries are unchanged"; the technical file carries a labelled proposal in section 25 (`:3106-3110`). | A maintainer using the list to locate every proposed byte misses that note. | No. | Add 25 to both header lists. | No |
| 37 | OI | Depends-on lines omit ADR 0043 and 0045 from 0044, 0044 from 0047 and 0043 from 0042, neutralised by `P:15`; the M7 row at `agent-context-map.md:369` is separated from its table by a blank line and the rollback-proposal anchor has no inbound link; accepted-ADR changes use six header labels while the ADR index names one amendment path; `docs/plans/README.md:25` keeps per-outcome wording. | No authority consequence. | Not applicable. | Add the names; remove the blank line; say the plan's prerequisite rows are the annotation set at acceptance. | No |

### Reconciliation of the 50 round 5 findings

R is repaired, P partly repaired. None was rejected. Evidence is a current
path and line; "residue" points to a finding above.

| ID | Status | Evidence |
| --- | --- | --- |
| 1 | R | `0043-T:346-347, :358-361, :549-551`; `0043-C:81-82` |
| 2 | R | `0043-T:66-71, :580-581` |
| 3 | R | `0043-T:15-16, :355-356, :362-365`; residue 2 |
| 4 | R | `0043-T:492-498, :505-509`; `P:127`; residue 35 |
| 5 | R | `0043-T:383-384, :412-415, :426-428, :514-515`; v1 kept `:378-380` |
| 6 | R | `0043-T:131-133, :337-341`; `0044-T:309-311`; residue 4 |
| 7 | R | `0043-T:177-180, :641-643`; `0043-C:41-43` |
| 8 | R | `0043-T:443-445, :454-455` |
| 9 | R | `0043-T:68-70`; `0043-C:55-57` |
| 10 | R | `0041-T:227-230, :239-241, :342-345` |
| 11 | R | `0041-T:75-76, :248-251` |
| 12 | R | `0041-T:72, :84-86`; `0046-T:195` |
| 13 | R | `0049-T:261-281`; `P:1338-1339`; residue 7, 8 |
| 14 | R | `0049-T:258-260, :302-320`; residue 6, 9 |
| 15 | R | `0049-T:128-130`; `0049-C:11, :70-71`; residue 9 |
| 16 | R | `0041-T:124-126, :223` |
| 17 | P | `0044-T:123, :182-201`; `PC:372-375`; unknown-default clause still two-valued (12) |
| 18 | R | `0044-T:116-117, :136-138`; `0043-T:128-131` |
| 19 | R | `0044-T:305-307, :371-381`; residue 16 |
| 20 | R | `0044-T:444-450`; `P:44`; residue 35 |
| 21 | P | `0044-T:230-235, :552-558, :563-564`; allowlist not final for the buffered path (14); hook wording (17) |
| 22 | R | `0044-T:255-256, :260-263`; residue 13 |
| 23 | R | `0044-T:595-600` |
| 24 | P | `P:908-912`; `0044-T:675-677`; the tightened oracle conflicts with documented provider behaviour (11) |
| 25 | P | `0046-T:544-548`; `0046-C:95-97`; `P:952-953`; uncommitted and cancelled variants remain (19) |
| 26 | R | `0046-T:256-257`; `P:946-948` |
| 27 | R | `0046-T:368-377`; residue 21 |
| 28 | R | `0046-T:357-360, :675-676` |
| 29 | R | `0046-T:344-347` |
| 30 | R | `0046-T:636-653`; `P:1368-1369`; residue 22 |
| 31 | R | `0046-T:205-207, :508-511`; `P:42-43` |
| 32 | R | `0046-T:451-452, :480-481, :681-684` |
| 33 | P | `0046-T:513-521`; deadline still undefined with no exit (20) |
| 34 | R | `P:461, :463-470`; `PC:310, :368-371`; context map `:6353-6363`; residue 25, 27, 28 |
| 35 | R | `P:486-489, :540-547, :672-673`; residue 29 |
| 36 | R | `P:493-496` |
| 37 | P | `P:617-659`; genesis pin, lost index and return handoff open (30) |
| 38 | R | `P:679-684` |
| 39 | P | `P:555-564`; fixed verdict and stop rule open (26, 27) |
| 40 | R | `P:584-585, :1118` |
| 41 | R | `P:962-965, :970-978`; residue 32 |
| 42 | R | `P:537-538, :1063-1065, :1213-1215` |
| 43 | R | `P:1058-1063`; `PC:376-379`; context map `:6376-6386` |
| 44 | R | `P:810-813, :986-988, :1132-1135, :1190-1192`; residue 32 |
| 45 | R | `0043-T:38-43, :616-617`; `0043-C:9`; `P:41`; residue 1 |
| 46 | R | `0041-C:9`; `0041-T:257-268`; `P:48` |
| 47 | R | `PC:338-341, :359-363`; `P:13-21`; residue 37 |
| 48 | R | `0043-C:9`; `0046-C:9`; `0049-C:11`; `0044-C:9`; `P:38-44`; residue 34, 35 |
| 49 | R | `0049-C:67-72`; `0043-C:41-43` |
| 50 | R | context map `:59`; `docs/vision.md:554-557`; `docs/evidence/README.md:44-48`; `docs/vision-technical.md:3106-3110`; residue 36, 37 |

Totals: 43 repaired, 7 partly repaired (17, 21, 24, 25, 33, 37, 39), 0 rejected.

**On the internal review.** The disposition's seven advisory findings were
real and their repairs hold: owner-specific bound domains
(`0043-T:467-474`), the four-summary and one-turn vectors (`:618-625`), the
driver-recorded daemon join (`P:970-978`), the designated-writer procedure and
the credential-free `started` boundary (`P:662-670`). Its conclusion that no
contradiction remains in the repaired clauses is accurate for those clauses.
The findings above sit mostly beside them, in joins the repairs created.

### Review limits

- No provider was called. Finding 11 rests on provider documentation retrieved
  2026-09-30 through Context7 and on the pinned ADR text; it is documented
  intent, not live evidence. Whether the provider echoes `claude-fable-5-1`
  literally in the response model, and whether adaptive cells emit thinking on
  the fixed prompts, are unverified live capacity and are not findings.
- Pinned dependency facts were read from `deps/req_llm` 1.24.0 source and
  `deps/llm_db` data in the working tree, not from documentation. Catalog
  presence was not used as proof of adapter behaviour.
- No test, build or check ran. Cross-toolchain encoding stability and every
  size estimate, including the summary-framing estimate in finding 3, are
  unmeasured.
- Accepted ADRs 0006, 0008, 0009, 0011, 0013, 0016, 0018, 0021 and 0028 were
  read at the clauses each amendment touches, not end to end. ADR pairs 0042,
  0045 and 0047 were read for joins only.
- The advisory readers' claims were sampled, not exhaustively re-derived. Each
  one cited in a finding was re-read at its line by the root reviewer.

### Scratch artifacts

Per-file diffs `a2ce04c2..07b1a19c`, produced with `git diff` and written
outside the repository under
`/private/tmp/claude-501/-Users-spuri-projects-lexlapax-loopex/f997f309-a64d-4296-b5d0-f750058fc3de/scratchpad/r6/`:

| File | SHA-256 |
| --- | --- |
| `0041-session-lineage-projection-and-context-budget-technical.diff` | `b6f2a37144fe3833dea9e1015074a8a5b667b94c08e75ebf237b6497b64206cd` |
| `0043-context-compaction-checkpoint-technical.diff` | `294ff5e5d154e1f5ef0c5a7f984f2fc3d8e6d5c84fa42cf813fed5a2d803cea9` |
| `0044-run-model-and-reasoning-configuration-technical.diff` | `45f4505234faabd409716aa796fdae72a5120ac944db00b8feb269568420c7f3` |
| `0046-child-session-tool-technical.diff` | `67388069a8ec687b8bda805c78e7342ac4e337e6c26a2edc1ac0ee04563b1239` |
| `0049-explicit-host-configuration-technical.diff` | `faedf0ebdd6389b2d3dcf2d54b95a2946c7c64675ac8da7e5117d3b499a9ed63` |
| `concept-and-other.diff` | `a8332e19af3216448604d7a89b06d9bbf50272c340235a1baa5c4c180fbc1228` |
| `M7-technical.diff` | `c80f0ba030a308039943304c7b7d5e83c40e6c0c4d8f2b6b1b2d038511f38dec` |

They are reading aids with no calculation or estimate in them. No synthetic
arithmetic was produced.

### Repository state

Before: HEAD `07b1a19cb7fdcab3155778f1119c043d23ba0d72`, branch `m7`, clean.
After: the same HEAD and branch, clean. This review accepts nothing and changes
no governance record; the verdict is advisory and the maintainer alone accepts
exact bytes.
