# M7 external review, round 3

Date: 2026-09-30. Reviewed candidate: `a4c9061ee86a7442942207aa61ec022388bd7ac9`
on branch `m7`. HEAD equals the candidate, the tree was clean before and after
the review, and the retained readiness receipt's remote SHA, log digest and
contract manifest (37 files) all match the working tree. Repository treated as
read-only: no edit, checkout, commit, push, provider call, credential access,
dependency install or release lane. The retained round 2 report
(`docs/evidence/M7-external-review-2.md`) matches its recorded digest
`7f445b36…`. Every scratch artifact this review relies on was verified against
the hashes in `docs/evidence/M7-round-2-disposition.md`; `shasum -c` passed for
the source-v2, thinking-refs, mapping, stream-bridge and profile-margin
directories. Provider behaviour is taken from the Anthropic reference bundled
with the review tooling, dated 2026-09-25, not from live calls.

## Concept

**Verdict: not yet ready for acceptance, but the gap has narrowed to repairable
text.** The round 2 blockers are genuinely repaired: marked excerpts with
retained originals, the separately configured summarizer, local-reference
continuation with an initial reserve, live streaming, verified summaries,
4 KiB ranges, legacy inline reuse, new-generation-only wire clients, one helper
per conversation, explicit supersession lines, and a closure rule for model
misses that is at least stated. The nine maintainer selections are recorded in
the context map and carried into the ADR bytes. Most of the remaining findings
are implementation obligations that the packet can name without new decisions.
Eight contract gaps still block acceptance because, as written, two of them
leave ordinary sessions permanently stuck, two leave safety or availability
holes in helper recovery, and four leave closure or governance undecidable.
None requires changing a recorded scope choice; one requires the maintainer to
extend the vision amendment's authorized scope.

**Blocking contract gaps.**

1. **A terminal run's oversized newest group can never be compacted.** ADR 0043
   always protects the newest complete assistant group, and ADR 0044 refuses
   the thinking reserve when input plus protected tail alone exceed a target.
   After a cancelled or bound-ended run whose last group is large, every later
   prompt and every explicit compact refuses forever. The excerpt repair fixed
   the oldest group but not the newest one. Repair: once a run is terminal, let
   maintenance cover its newest complete group under the same marked-excerpt
   rule. No decision needed.

2. **New refusal causes have no durable or public failure schema, and the
   accepted failure validation pins the system ceiling to exactly 1,000.**
   ADR 0042 makes the ceiling host-configurable, but ADR 0017's closed failure
   union and current code require `limit == 1_000`. Headroom, no-progress and
   maintenance-unconfigured refusals have no valid record shape at all. Repair:
   a revised failure projection owned by ADRs 0043/0044 with added dimensions,
   the captured ceiling as `limit`, preserved v1 validation and vectors.

3. **Every ordinary local-tool cancel closes helper admission host-wide.** The
   concept limits the global close to cancels "before a job can be identified",
   but the technical text registers only helper jobs, so a plain interrupt of a
   `bash` job is unclassified and disables helpers for every daemon session
   until restart. The round 2 rejection of this finding was incorrect. Repair:
   the router records every forwarded job ID in volatile state; the global
   flag remains only for the true pre-registration race.

4. **Helper slot reconstruction and session classification have no defined
   source, and the grace-bound create lookup cannot honour retained input.**
   The set of expected parent-run logs, the creating command ID of an arbitrary
   session, and a create lookup that preserves the retained cleanup grace all
   require read-only core queries that neither exist nor are named as joins.
   Without them a routine crash either lets a client prompt an unknown child
   outside the allowance or refuses the parent forever. Repair: name three core
   joins (intent query, creating-command query, lookup variant taking retained
   runtime configuration and v3 genesis) and map `conflict` explicitly.

5. **Three thinking-contract cells are undecidable before dispatch.** What the
   next run sends after an exchange ended on bound or cancel is specified only
   as a test, with "unsupported rendering" undefined; the Haiku manual row hedges
   whether reasoning text is public; ADR 0043's maintenance `default` rule
   cannot be expressed in ADR 0044's closed mapping. Repair: specify the rendered
   grouping and a mapping-level flag plus named refusal; write a literal Yes or
   No; restrict maintenance to `{mode: disabled}`.

6. **Closure mechanics remain undecidable.** The model-miss rule names no judge,
   no verdict class, no slot for prior candidates' failures and no route for
   the disposition it says is required. Attended cases sit inside the release
   check while the release lane refuses attended selectors. The fixed manifest
   must carry post-execution identities yet is committed before demonstrations.
   Several provider-backed attended steps (V7.3 thinking rounds, V6.2 range
   reads, ADR 0044's bound/cancel continuation, V13.5 baseline, the bidirectional
   pipe case) have no owning case or oracle. The maintainer's strict no-reroll
   choice is preserved by the repair: a predeclared verdict class computed from
   committed facts, recorded in the scaffold, with `model_nonconformance`
   routed to maintainer disposition on a fixed menu.

7. **The vision amendment overwrites clauses it says still govern, and omits
   §13.4.** The header promises the prior seven-tool and no-sub-agent clauses
   remain governing, but §14, §23.4 and founding decision 8 were replaced in
   place, so the governing text exists only in Git history. §13.4 still says the
   continuation sidecar is opaque, never interpreted by core, encrypted when
   sensitive and retained for a declared lifetime; ADR 0044 stores it inside
   core records, validates and expands it in core, keeps plaintext, and retains
   it with raw history. The plan lists §13.4 as binding. This needs the
   maintainer (decision below).

8. **Plan scope promises ephemeral host instructions and reasoning selection
   that no ADR authorizes.** ADR 0039's closed option set is amended by 0043,
   0045, 0048 and 0049, but not by 0042 or 0044, and the prerequisite table's
   ADR 0039 row omits both. Repair: add the amendment to both ADR headers and
   the table, or drop the claim from scope.

**Maintainer decisions.** Only one is required; the second is offered because
the smallest repair without it is disclosure rather than a fix.

| Decision | Plain-English options and consequences |
| --- | --- |
| Required: extend the vision amendment to §13.4 | (a) Label §13.4 to match ADR 0044: core validates the private envelope but not native block types, storage is plaintext under the private store, retention lasts as long as raw history. Keeps every selected thinking choice; changes vision bytes the current authorization does not name. (b) Keep §13.4 and revise ADR 0044 toward an opaque adapter-owned sidecar with declared lifetime: materially changes the selected local-reference and core-expansion design and the accounting contract. Recommend (a). Either way, restore the prior governing clauses verbatim beside the labelled proposals so the header is true. |
| Optional: prompt-target measurement scope | Helper-enabled chat measures 990 tokens at this checkout's 36-byte path and 1,010 at a 96-byte path, with a default ceiling of 1,000 and strict less-than admission. Ordinary operators with longer workspace paths get helper chat refused at startup. (a) Keep the target as counted: pin short demonstration roots, disclose the refusal, name `system_class_tokens` as the remedy. No choice changes. (b) Exclude the workspace path from the measured reference class or count environment facts separately: keeps the 1,000 target meaningful for real repositories but redefines what ADR 0017's system class counts. |

## Technical depth

Classification: **CG** blocking contract gap, **IO** implementation obligation
(must be named or repaired in text; does not block acceptance once named),
**OI** optional improvement. "Checks" says whether the plan's planned evidence
would catch the defect. "MD" is whether a maintainer decision is required.

### Context, artifacts, compaction, budgets

| # | Class | Where | Concrete failure and conflicting clauses | Checks | Smallest repair | MD |
| --- | --- | --- | --- | --- | --- | --- |
| 1 | CG, high | `docs/adr/0043-context-compaction-checkpoint-technical.md:47-52`; `docs/adr/0044-...-technical.md:345-350`; `0041-technical.md:152-153` | Newest complete group always protected; reserve refusal when input plus tail exceed a target. A cancelled run after four 4 KiB range reads or a 14 KiB write leaves a group above the 32,768-byte target; every new thinking run refuses `thinking_exchange_headroom`; a many-call reply whose metadata alone exceeds the record makes every later prompt and explicit compact refuse. No fork exists. | No. ADR 0043 `:345-346` and ADR 0041 `:263-266` treat irreducible overflow as a correct refusal and never test a later prompt. | Once the run is terminal, allow automatic and explicit compaction to cover its newest complete group when the mandatory tail alone cannot fit the hard limits or the reserve; reuse the marked-excerpt form. | No |
| 2 | CG, medium-high | `docs/adr/0017-...-technical.md:770-783, 864-871`; `apps/loopex/lib/loopex/runtime/session_state.ex:5869-5875`; `context_admission.ex:47,122`; ADR 0044 tech `:363-366`; ADR 0043 tech `:79, :101, :166, :265, :284`; ADR 0042 `:9`, tech `:25-26`; `0049-technical.md:33` | Closed five-key failure with `observed > limit` and `limit == 1_000`; new causes `thinking_exchange_headroom` (observed at or under the hard limit), `compaction_no_progress`, `compaction_excerpt_budget_too_small`, `maintenance_model_unconfigured`, `maintenance_instructions_unconfigured`, `maintenance_reasoning_unsupported` have no record shape; a raised `system_class_tokens` produces a refusal record that fails replay or public-schema validation. No ADR header amends ADR 0017's failure projection or `run.finished`. | No. No evidence bullet names terminal or event shapes. | Revised failure projection in ADRs 0043/0044: added dimensions or categories, `target` member for headroom, captured ceiling as `limit`, preserved v1 validation, Node vectors. | No |
| 3 | IO, medium | ADR 0043 tech `:50-51, :271-276, :307-310`; ADR 0044 tech `:334-338`; `M7-technical.md:592` | Minimum post-compaction projection (maximal 6,144-byte summary rendered once, 2,048-token tail, largest profile, both headers, stored twice) is roughly 31 to 35 KB and about 5,100 tokens, at or above the 32,768-byte target; a V6 "small context budget" below about 5.5k tokens cannot converge; strict decrease then depends on the summarizer shrinking its output. Estimated, not measured. | Only by luck. | One sizing obligation pairing a maximal summary, full tail and largest demonstrated profile against 32,768 bytes and the fixture budget; make tail growth target-aware under the headroom trigger or pin the V6 budget above the measured floor. | No |
| 4 | IO, medium | ADR 0044 tech `:344-351`; ADR 0044 concept; `M7-technical.md:218-231, 371-379`; `ephemeral.ex:21` | The 32,768-byte record target applies to a first request with no history. A fresh session with a pasted ~12 KiB log refuses `thinking_exchange_headroom` although the request fits 65,536 and prompts up to 32,768 bytes are otherwise admitted. Not disclosed in concept or plan. | No. Checks test "initially fitting requests that require earlier compaction". | Disclose in ADR 0044 concept and plan; add a boundary witness. | Only if the maintainer wants a no-history first request exempted, which changes the reserve choice |
| 5 | IO, medium | ADR 0049 concept `:46`; `M7-technical.md:231`; ADR 0043 tech `:100-101, :169-170`; ADR 0044 tech `:364-366`; thinking-refs measurements | With `continuation_required: true` and no summarizer, maintenance becomes mandatory once the minimum projection passes 32,768 bytes, about two tool rounds; every new prompt then fails `maintenance_model_unconfigured` until restart with `maintenance.model`. "Ordinary work remains available" overstates it. | No. | Startup and `/status` warn when the mapping requires continuation and no summarizer is configured; the refusal names the remedy; adjust ADR 0049 wording. | No |
| 6 | IO, low-medium | ADR 0043 tech `:260, :271-276`; ADR 0044 tech `:259-261` | A 1,024-token reply reserve yields about 3.5 to 4 KB, so the 6,144-byte envelope is normally unreachable; a verbose summarizer hits `max_tokens`, returns truncated JSON, the episode ends without a named cause. | No. | State that the reply reserve binds and byte caps are upper bounds; classify `max_tokens` or unknown stop as a named invalid-summary failure consuming the attempt; have the reference instruction ask for a byte target under about 3 KB. | No |
| 7 | IO, medium | `M7-technical.md:234-247`; ADR 0042 tech `:23-26, :64-66, :90-94`; `0049-technical.md:33, :39`; disposition `:146-152` | The system class counts the rendered workspace path; 990 at 36 bytes, 1,010 at 96 bytes, 1,339 with sixteen roles; default ceiling 1,000 with strict less-than. Helper-enabled chat refuses at creation once the path passes about 64 bytes, including likely temp checkouts for V10. The gate runs "before integrating" and may use a different path from the demonstration. | Only demonstrated profiles are asserted; operator paths are not. | Pin short demonstration roots and re-assert the gate at demonstration time; state in ADRs 0042/0049 that the default ceiling refuses helper profiles for longer paths or catalogs with `system_class_tokens` as the remedy. | Optional decision above |
| 8 | IO, low | ADR 0044 `:481-484`; measurements `:333-343` | Each round adds about 16.4 KB of record and 3,230 tokens; the reserve covers about two rounds; under the 8,192 fallback (reserve 4,096) about 1.3 rounds, so round 2 fails with the named bound failure. Contract-consistent and disclosed as "no round count", but the outcome 4 release row proves "multiple rounds" only if the fixture is sized for it. | Partly. | Pin the outcome 4 case's captured ceiling (at least about 16k) and require at least two continuation requests recorded. | No |
| 9 | IO, low | ADR 0041 tech `:70-72`; `session_coordinator.ex:3322-3333`; `coding_tools.ex:65-66` | "Frozen read generation does not support `artifact_use`" is not decidable from `{tool_id, tool_version, definition_digest}` without a rule. Wording is otherwise consistent across concept, technical, plan and V13.2. | No. | Define a closed list of artifact-capable `loopex.read` identities matched on exact frozen identity. | No |
| 10 | OI | ADR 0043 tech `:71, :213-214, :251` | Two 8,192-byte fragments already reach the 16,384-byte source cap before framing, so the first candidate quota is unreachable and its end buffers exist only for it. | Not applicable. | Drop it or note it unreachable. | No |

Survived review without a finding: oversized-source selection is deterministic
and total for the oldest unit (nested prefixes; a unit too small to excerpt
fits as a complete prefix; worst-case prior checkpoint plus minimum excerpts
is about 12.7 KB); aggregate allocation with one shared quota and both header
variants needs no tie-breaks; second-provider routing, parent-ceiling cap and
helper maintenance charging agree across ADRs 0043/0046/0048; preparation
episode ordering is consistent with ADR 0010 and the executor's
spill-before-receipt order.

### Thinking continuation and wire amendment

| # | Class | Where | Concrete failure and conflicting clauses | Checks | Smallest repair | MD |
| --- | --- | --- | --- | --- | --- | --- |
| 11 | CG, medium-high | ADR 0044 tech `:594-599` (Evidence only), `:488-489`; disposition row 14 | After a run ends on bound or cancel mid-exchange, canonical history holds an assistant tool_use with no thinking; the next run's rendering (one or two user messages, what "unsupported rendering" means before dispatch) is unspecified and `provider_mapping` has no field for it, so the failure surfaces as a dispatched 400. If Haiku rejects it, every mid-exchange-ended session is stuck on that row. | Only as a late real-provider test. | Specify the rendered grouping; add a mapping-level flag decidable before dispatch; name the fallback: refuse the prompt by name and point to compaction or a model switch. | No, if the fallback is the named refusal |
| 12 | CG, medium | ADR 0044 tech `:128` vs `:133-135, :169-171` | "Only verified native summary text under this default display" for Haiku manual rows hedges whether `thinking_delta` becomes public `reasoning_delta`; the mapping revision is the only classification source, so conformance cannot decide. | No. | Write a literal Yes or No with its evidence source. | No |
| 13 | CG, low | ADR 0043 tech `:89-93` vs ADR 0044 tech `:100-107` | ADR 0043 allows maintenance `default` "only when its retained mapping proves omission disables thinking"; ADR 0044 says omission is not disabling and the closed variants carry no "off by default" fact; `continuation_required: false` does not prove thinking off. The mapping probe confirms ReqLLM `none` drops the option rather than disabling. | Partly (final encoded-request checks). | Limit maintenance to `{mode: disabled}` (the Haiku `none` row) or add an explicit "thinking off by default" field. | No |
| 14 | IO, high | ADR 0044 tech `:295-299, :312-315, :98-99, :130`; `/tmp/loopex-m7-thinking-refs-ff08713c/fixture-input.json` | Only sizing fixture uses 212-byte signatures and 236-byte thinking; real signatures and summarized thinking at medium/high effort are likely far larger and Fable can emit several blocks per reply. One ordinary `high` reply exceeding 16 KiB ends the attempt terminally after dispatch at full cost. | Only late, via the multi-round fixture. | Pre-integration gate measuring real capsule sizes per matrix row with a stated fallback (row refusal, or `display: omitted` for continuation-only rows). | Only if the fallback changes caps or the verified-summary choice |
| 15 | IO, medium | ADR 0044 tech `:414-441`; `deps/req_llm/lib/req_llm/generation.ex:232-252`; `stream_server.ex:996-999, 1082-1086`; `req_llm.ex:360-371, 403-437`; `providers/anthropic/context.ex:416-437` | The probe injected SSE into StreamServer with a custom provider and never exercised `start_http`, `stream_text`, request building or rendering. `stream_text` resolves providers globally, so a per-invocation bridge must call `start_stream/4` with a wrapper provider and redo normalization; parser errors are logged and parsing continues; `message_stop` finalizes regardless; with infinite timeouts a latched stream hangs the drain unless the owner watches the private failure message; pinned rendering regroups blocks and maps invalid JSON to `%{}`, so a body-level override is mandatory. The ADR says "preserve" the handoff point without naming the new one. | No. | Name the handoff point and require a pre-integration probe of native rendering and actual HTTP wiring before any row is admitted. | No |
| 16 | IO, low-medium | ADR 0044 tech `:198-202, :306-311`; ADR 0021 `:43, :64-65`; `provider_attempt.ex:298-303, 477-478, 500-515` | Readers accept v1/v2 only and a v2 reply has exactly eight keys, so v2/v3 discrimination works. Unstated: whether M7 writes v3 for every settlement (error-only, `model_call_failed`, maintenance, nil continuation), whether nine-key v2 replies from non-continuation adapters are accepted, and the kind for unreadable or compact settlements. Receipt revision 4 has no double counting. | No. | Add "M7 writes `model_attempt_settled_v3` for all new settlements; v2 is read-only" plus the adapter reply-version acceptance rule. | No |
| 17 | IO, low-medium | ADR 0044 tech `:241-246, :251` | Strict native templates (`{type: text}`, `{type, id, name}`) fail closed on any extra provider field, leaving a row unusable; unverifiable without live responses. | No. | Fold into finding 14's live gate; decide in advance whether a new field means a new renderer revision. | No |
| 18 | OI | ADR 0044 tech `:186-187` vs `:179-181, :615`; `req_llm.ex:696-701, 500-501` | "Terminal-sanitized" versus existing terminal-control rejection that fails the whole attempt on an unsafe fragment. For model-generated summaries, state whether an unsafe fragment is suppressed (capsule kept) or aborts the attempt. | Partly. | State which. | No |
| 19 | OI | ADR 0044 concept `:144-146`; plan `:67-125` | Member inventory lives in one place and the negotiation rules match `session.ex` and `v2.ex`. The concept list omits ADR 0042 instructions and ADR 0046 create-time selections; the digest canonicalization recipe is not pinned. | Not applicable. | Complete the list; pin the recipe. | No |

Checked and consistent: local-reference expansion is total for interleaved,
empty and redacted blocks with decoded-value equality (byte-identical tool_use
input is not reconstructable and not needed since the signature binds thinking
and prefix); streaming covers signature joining, text between tool_use blocks
and several assistant entries per exchange; hidden events consuming no public
sequence number is consistent with ADRs 0011/0023; explicit adaptive rows
resolve the earlier `provider_default` contradiction and match the mapping probe
(23 rows, 7 literal mismatches, 2 manual-budget relation violations); the
retained probe hashes match.

### Helper ledger, cancellation and recovery

| # | Class | Where | Concrete failure and conflicting clauses | Checks | Smallest repair | MD |
| --- | --- | --- | --- | --- | --- | --- |
| 20 | CG, high | ADR 0046 tech `:245-255, :369-370` vs concept `:61-63`; `executor.ex:211`; `session_coordinator.ex:6925, 5942-5951, 6907-6911`; disposition `:474` | `cancel/2` receives only an opaque job ID; execute and cancel run in separate tasks; the router registers only helper jobs. Every Ctrl-C on a local job is "unclassified", sets `helper_admission_closed` for the incarnation, and in a daemon disables helpers for every parent session until restart. The evidence line locks this in. Undermines the selected independent-parent concurrency. | No; evidence `:369` expects it. | The router records, in volatile state, every job ID it forwards (local or helper) before forwarding and drops it at settlement; "unclassified" then means only a cancel that arrives before its execute registered; keep the global flag for that race and disclose daemon-wide effect. | Only if the round 2 rejection really meant all local cancels; the concept wording supports the narrow reading |
| 21 | CG, medium-high | ADR 0046 tech `:170-177, :313, :397-399`; plan `:948-956`; `loopex.ex` facade; `session_coordinator.ex:7645` | "Retained parent delegation intents" that establish the expected log set are undefined; the only candidate source is each parent's core journal, and no read-only core query exposes a dormant session's historical executor intents across runs. A crash after core commits the intent but before the adapter's `initialize` fsync looks exactly like the "removed log" tampering witness, so a routine crash permanently refuses the parent (or host admission; the scope is unstated). | The `:397` witness makes it worse. | Name a read-only core intent query as a join; resolve an intent with no log by read-only lookup of the derived create command once the predecessor is gone (`:absent` proves no child; write `initialize` plus `stop(adapter_recovery)`); treat a missing log as tampering only when lookup returns `:historical`; scope refusal per parent. | No |
| 22 | CG, medium | ADR 0046 tech `:304, :310-328`; `runtime.ex:251-262` | Helper identity derives from binding/operation records plus create-result resolution, which maps command to session only; nothing maps a session back to its creating command. While a reserved create is unresolved, an arbitrary session cannot be classified: defaulting to ordinary lets a client prompt the unknown child outside the allowance; refusing unclassified sessions refuses every session on the host, possibly forever. | No. | A session is a helper iff its creating command ID matches a derived child-create ID in any retained reservation; obtain the creating command ID via a new read-only core query over the create row or genesis, named as a join; hold classification of unknown sessions during a live in-flight create. | No |
| 23 | CG, medium | ADR 0046 tech `:304, :84-85`; `control.ex:2363-2366, 2399-2404`; ADR 0049 `:103-104`; plan `:948-956` | The ADR requires lookup "with the exact retained original creation input, preserve cleanup grace", but `lookup_create_result/3` always takes the grace from the current runtime and builds v2 genesis, not v3. After a crash with lost create acknowledgement plus an ordinary grace edit, lookup returns `:conflict` (stays unknown, slot occupied forever), classification stays incomplete, and the parent-binding replay conflicts, fencing the parent. The only remedy (restart with the old grace) is undocumented; the join is unnamed. | Evidence `:371` checks only that the result stays unknown. | Add a core lookup variant taking retained `runtime_configuration` (or genesis digest) and v3, named in the joins; at minimum a diagnostic naming the retained grace and a runbook step. | No |
| 24 | IO plus disclosure, medium | ADR 0046 concept `:49-50`; `executor.ex:456-471`; `control.ex:2365`; ADR 0049 `:103-107`; plan `:659-664, :678` | Child grace comes from the runtime's current value, not the parent's committed one, so it can exceed the parent's; the parent observation window is max(10 s, grace+2 s). A confirmed child cleanup can outlast it, yielding `outcome_unknown` after a clean stop. Ordinary with default 5 s grace only when cleanup actually uses most of it or child grace exceeds the parent's. | No. | Refuse delegation before reservation when the child's observation bound plus adapter overhead exceeds the parent's window (spends nothing extra), or require child grace ≤ parent grace via a core create option; disclose `outcome_unknown` after clean stop in V8.5, V9.2 and the runbook; the adapter's `cancel/2` takes its reply deadline from the registered job. | Yes for the refusal or grace rule; disclosure is an obligation regardless |
| 25 | OI plus disclosure | ADR 0046 tech `:127-129, :274-280, :290-292, :382-383`; disposition 23 | Crash between `stop` append and fsync ack replays correctly and consumes credit once; abort proceeds during an unknown stop. But an fsync error in parent A's run log fences `settle`, `bind_receipt` and slot release for parent B until restart; no live resolution. | No. | Disclose next to finding 20; optionally scope the fence to the affected log. | No |
| 26 | OI | ADR 0046 concept `:58-60` vs tech `:318-321` | Concept lists reconfigure, compact and starting work; technical also refuses client abort, steer and interaction response, so an operator cannot abort a runaway helper directly and must cancel the parent; the runbook does not say so. | No. | Add "including abort; cancel the parent" to concept and runbook. | No |
| 27 | IO, low | `session_state.ex:3270-3290`; ADR 0046 tech `:194-196` | Promotion copies the predecessor's declared bounds map wholesale; if `deadline_at_ms` lives in that map the promoted run inherits its predecessor's ceiling, contradicting "absent means no inherited ceiling". | Yes, the follow-up inheritance vector. | Store the follow-up's own ceiling separately from inherited bounds. | No |
| 28 | OI | ADR 0046 tech `:104-110, :379-380`; `0049-technical.md:39` | 128 conceded unreachable under 16 MiB with worst-case frames; ownership now composition. `max_children` up to 128 still admitted at validation without a capacity check. | Partly. | Reject `max_children` above the capacity-derived figure at validation, or state per-kind frame maxima. | No |

Checked and consistent: write-once stop/settlement/receipt; closing credit;
stop-only recovery; prepared abort without activation (`loopex.ex:486-495`);
observational receipt lookup (`session_coordinator.ex:7697-7720`); receipt
causation decidable from stop reason plus child terminal and permitted by ADR
0009; authored-bound identity scope consistent across ADR 0046, plan and ADR
0011 amendment, with the current `normalize_command` omitting bounds as ADRs
0011/0017 specify; replay before clock and idempotent expiry refusals; child
maintenance charged to delegation; direct child prompting recorded as refuse.

### Configuration, credentials, ephemeral, protocol, rollback

| # | Class | Where | Concrete failure and conflicting clauses | Checks | Smallest repair | MD |
| --- | --- | --- | --- | --- | --- | --- |
| 29 | CG, medium | ADR 0049 tech `:90-97`; ADR 0046 tech `:152, :163`; ADR 0047 concept `:49-50` | Resume commits model, reasoning, instructions, budgets, tools, resources and role catalog, and says only turns, deadline and token budget are new-run values; the delegation allowance (`max_children`, delegation `token_budget`, `child_bounds`, child limits) is initialised per parent run from ADR 0049 but has no stated resume source. A file edit could silently raise helper spending, or the "Only" wording forbids it. `--no-helpers` conflict behaviour unstated. | No; V12.4 and V8.7 check role snapshots and catalog only. | Add the allowance fields to the resume paragraph as new-run values from invocation configuration; say a conflicting `--no-helpers` refuses; add a V12.4 subcase. | No |
| 30 | CG, low-medium | ADR 0049 tech `:172, :159-160, :195-197, :224-228`; `session_coordinator.ex:2609-2613, 7370-7373` | The pipe `input` record allows only admitted/refused; core can return `commit_unknown` on admission. A prompt reported refused with `commit_unknown` could be followed by a `settled` barrier while its run actually committed; exit-code rules cannot count it. | No; evidence lists idempotent resubmission only. | Add an `unknown` disposition; `/wait` reports `uncertain`; pipe mode stops input and cleans up. | No |
| 31 | IO, low-medium | ADR 0048 tech `:76-83, :104-109`; `edges.ex:48`; `loopex_composition.ex:214`; `credential_host.ex`; `service.ex:361-387`; `daemon.ex:225-236`; `loopex_cli.ex:82, 187-192` | Custody opens in three places with no shared validator (name exclusions, dedupe, all-or-nothing cleanup); daemon Service's value-bearing `:credential` combined with `:provider_bindings` is unaddressed; the CLI deletes `LOOPEX_PROVIDER_API_KEY` before dispatch for every command except run/resume/cancel/ask, so a chat file referencing the legacy name has it deleted unread and startup fails. | No. | Name one private resolver used by all three openers; make `:credential` and `:provider_bindings` exclusive in the daemon Service; add chat to the discard exemption. | No |
| 32 | IO, low-medium | `M7-technical.md:424-425, :534-537, :450-455, :777-787`; ADR 0049 tech `:173-174` | Strict pipe failure on an unrequested question is the recorded choice and is not accidental. But the fixed repair prompts are pre-attempt deliverables and nothing says they state that requirements are complete and no clarifying question is needed; the "separate bidirectional-pipe case" has no step number, class, case ID or lane, so step-evidence validation can miss it. The grammar itself is adequate (`question` and `wait` carry `interaction_id`). | No. | Number the bidirectional case (e.g. V2.6) with a case ID and lane; add the prompt-wording rule. Neither changes the oracle or strictness. | No |
| 33 | IO, medium | `M7-technical.md:850-867`; ADR 0044 tech `:143-146, :157-159`; ADR 0043 tech `:92`; `durable_options.ex:52`; `check-release.sh:62-65, 300-321`; `release-lane.sh:156-162`; `attended-pty.py:36-39` | Provider B is pinned "before runs"; two Anthropic models cannot prove routing; `openrouter` is an admitted durable provider that can route Claude, so whether OpenRouter-hosted Claude counts as another provider is unresolved. V6.7 needs a verified thinking-off mapping and renderer for a B model with vectors before integration; no workstream owns it. Each full closure run needs two paid credentials. | No. | Record B as a maintainer selection made at testing time like the external repository; exclude OpenRouter-routed Anthropic models; give the B conformance row an owner in phase 2. | Light: confirm the OpenRouter exclusion |
| 34 | IO, low-medium | `rollback-lane.sh:9-22, 28, 38, 53, 102, 109-115`; `check-release.sh:91, 200-217, 271`; `M7-technical.md:983, :997-999`; ADR 0036 `:13-14` | Keeping the v0.2.0↔v0.3.0 pair with original assertions means three archives and three builds; drivers load from the candidate tree, so M7 edits to shared drivers silently change the historical pair's assertions; both candidate and old binary report VERSION 0.3.0, so V13.4's block-the-old-binary precondition must identify binaries by digest; "bump private format metadata" sits close to ADR 0036's format-marker gate and should say record-level versions only. | Not until the lane runs. | State the three-tree structure, driver pinning per pair, digest-based binary identity, and the record-level meaning. | No |
| 35 | IO, low-medium | `M7-technical.md:469-490, :949-954`; `loopex_composition.ex:173, 225-226, 263`; ADR 0049 concept `:19`, tech `:100`; `loopex_cli.ex:53-85` | The wrapper uses existing `:policy` and `:policy_identity` composition options and is a trusted embedding host, so it does not contradict ADR 0049. Unnamed: a new internal CLI driver entry accepting a policy module; effective and `/status` output shows the file's registry profile while a different policy decides (no "harness" origin); resume requires a matching policy identity so V2.4 and V5.3 reopen only through the wrapper; the attended flows never pass through `LoopexCli.main/1` (stdio mode, live signals, credential discard). | No. | Name the driver entry; report policy origin `harness` with the fixture identity; require at least V12.1–2 and one chat prompt through the built escript. | No |
| 36 | OI | ADR 0043 `:11`, 0045 `:9`, 0048 `:9`, 0049 `:9`; plan `:45`; `options.ex:4-17`; ADR 0045 tech `:70-74`; ADR 0049 tech `:236`; `trace/config.ex:20, 55` | Labels differ ("extends" versus "supersedes") for the same ADR 0039 option-set amendment; no document lists the final closed ephemeral option set; ADR 0049 calls the default trace modules "Loopex-only" while config defaults to `:loopex` and `:loopex_protocol`. | Not applicable. | Align labels; list the final set; align wording. | No |
| 37 | OI | `M7-technical.md:179-180, :104`; `check-release.sh:284-295, 331-335` | "Keep the pinned historical release/rollback lanes unchanged" versus rows 4, 8, 9 and the node_client lanes talking to candidate servers that will serve only `/3` and `/4`. | Not applicable. | Say "historical rollback pair unchanged; rows 4/8/9 and node_client lanes migrate to the updated clients". | No |

Checked and consistent: the negotiation table matches `session.ex:221-233`
(server generation selected from anywhere in the offer) and both servers' error
codes; Node clients store or check only generation, as the plan says; cleanup
grace on resume agrees across ADR 0049, ADR 0016 and V12.4; `--compaction-model`
on resume is stated; ephemeral trace contradicts neither ADR 0030 nor ADR 0039;
legacy receipt field meaning holds; single-provider `ask` and the legacy plane
remain valid; V13 needs nothing from ADR 0036/0038's M8 commands; ADR 0038's
conditional switch-back matches the plan.

### Operator validation, oracles, closure

| # | Class | Where | Concrete failure and conflicting clauses | Checks | Smallest repair | MD |
| --- | --- | --- | --- | --- | --- | --- |
| 38 | CG, high | `M7-technical.md:424-436`; `verification.md:123-125`; `plans/README.md:306-307`; `milestones-technical.md:224-229`; `agent-context-map.md:6054-6133` | The rule names no judge for "substantive correction" and "causal diagnosis", no field for the cause label, no scaffold slot for earlier candidates' failures, and no route for the disposition it requires. In the `feature` task the product works and the model never calls `loopex.ask`; the only corrections left are prompt rewording (near the "no optimized prompts" non-goal and inside the 1,000-token gate) or a task change needing disposition. At least twelve single-shot verdicts depend on model behaviour (ask in V5.1/V5.3/V5.6; not ask in V2's static pipe; delegate twice in V8; call the V4 barrier tool; several rounds in V7.3). A candidate created for an unrelated fix that happens to pass `feature` is undecidable under "retrying into green". M6 needed four such dispositions. The strictness itself is the maintainer's recorded choice; its mechanics are not. | Checks detect the miss; nothing classifies it. | Predeclared verdict class per manifest case (`pass`, `product_failure`, `model_nonconformance`, `evidence_unavailable`) computed from committed facts; every candidate's scaffold predeclares a section listing earlier candidates' attempts and verdicts; the independent reviewer judges causal diagnoses for `product_failure`; `model_nonconformance` always routes to maintainer disposition on a fixed menu (pinned model or witness change with assertions unchanged, Accepted limitation, evidence-reuse exception); state that rerunning an unchanged case on a new candidate counts only under that disposition. Strict retention and no reroll are preserved. | Only if cross-candidate evidence reuse is wanted; not required to make the rule decidable |
| 39 | CG, medium-high | `M7-technical.md:443-447, :846`; `M7.md:420-421` vs `M7-technical.md:384-385`; `release-lane.sh:12-14`; `check-release.sh:262-310` | The attended workflow sits inside the release check while the lane refuses attended selectors and rows are single ExUnit tests with an identity formatter; an operator typing runbook commands does not fit that row model; whether V10's external task, V11, V12 and V13's M6-artifact steps run inside the one invocation is unstated; a coding-task `--only repair` (attended V2.1–5) must either run unattended or refuse, unstated. | No. | Attended M7 cases run only in the full matrix, once, through the PTY driver inside the single invocation; `--only` variants are non-closure evidence and never owning executions; the existing attended-row refusal stays; the selector union deduplicates by case ID. | No |
| 40 | CG, medium | `M7-technical.md:791-797, :404-407, :823-824`; `milestones-technical.md:221-229` | The fixed manifest committed before demonstrations must hold "actual attempt and session/run identities after execution"; filling it afterwards needs a commit outside the five administrative paths or a new candidate (rerun). No rule ties scaffold step rows to manifest keys. | Only at closure via confinement. | Manifest holds case IDs and slot keys only; the runner writes identities to retained output; the scaffold predeclares one Pending row per manifest step or subcase; a candidate-time check requires scaffold rows to equal manifest keys. | No |
| 41 | CG (V7.3) plus IO, medium | `M7-technical.md:596-599, :623-635, :350, :857-858`; ADR 0044 tech `:593-597`; V13.5 | V6.2's range-read evidence is "automated" yet "reuses the owning fixture run", so it is either a model-dependent requirement the `long` oracle omits or a deterministic test with no owner; the V7.3 thinking fixture is not in the catalog, has no case ID and no objective oracle for "multiple tool rounds"; ADR 0044's real-provider bound/cancel continuation appears in no V step or case list; V13.5's "pinned baseline" with the M6 artifact has no owner if it calls a provider; "the compaction lane" is ambiguous between `long` and V6.7. | No. | Add a case ID, fixture and oracle for every provider-backed attended step; declare V6.2's source a deterministic test; add the bound/cancel case with an owner; define V13.5 as inspection only or give it an owner; disambiguate the compaction lane. | No |
| 42 | IO, medium | `M7-technical.md:561-564`; `coding_tools.ex:158`; ADR 0016 tech `:56` | The V4 barrier tool is unnamed; holding "that tool's completion" requires the model to call one exact approved invocation (another model-dependent verdict); release trigger, hold bound and timeout outcome undefined. No contradiction if bounded below the 120,000 ms bash wall time, the 600,000 ms run deadline and the cleanup grace. | No. | Fixture-approved invocation blocking on a harness-controlled FIFO; release on committed steer-admitted and follow-up-queued events; hold at most tool wall time minus margin; timeout is a classified failure, never a retry; a missing call is `model_nonconformance`. | No |
| 43 | IO, low-medium | `M7-technical.md:834-841, :851-853, :464-467`; `milestones-technical.md:13-17` | The operator-written UTC timestamp proves nothing; the real timing proof is the runner logging the pin digest before its first dispatch in the same digested log. Destination named only as "immutable retained record". "Changing the pin creates a new recorded attempt" conflicts with the no-replacement rule inside one release run. A/B model and credential-name pins have no immutability mechanism or slot. | No. | Make the pre-dispatch logged digest the timing proof; allow a changed pin only on a new candidate under finding 38; commit the A/B pins in the manifest or treat them identically. | No |
| 44 | IO, low-medium | `M7-technical.md:815-832`; `milestones-technical.md:155, :174-177, :226`; `M7-technical.md:853-855, :866` | Present: floor/current pair, archive manifest, reviewer identities, Node results, per-profile and per-task measurements. Missing: retained-output reference and digest per review report (only "identities and conclusions"); run platform (cross_uid gives closure-incomplete on macOS); earlier-candidate failures and verdicts; A/B pins; mapping and renderer revisions per case; the redaction self-test result for the selected name set; the demonstrated profile set must be listed so row counts can be predeclared. | Only at closure. | Add the slots. | No |
| 45 | OI | ADR 0046 tech `:246-255, :369-370`; V9.2 and V8 ordering | Any Ctrl-C of a local job closes helper admission for the incarnation; if attended V9.2 runs in a helper-enabled runtime before V8, V8 refuses. | No. | Runbook uses a fresh runtime for V8, or fix finding 20. | No |

### Vision amendment, successors, pair consistency

| # | Class | Where | Concrete failure and conflicting clauses | Checks | Smallest repair | MD |
| --- | --- | --- | --- | --- | --- | --- |
| 46 | CG (governance), medium | `docs/vision.md:12-17, :326-343, :583`; `docs/vision-technical.md:12-17, :1025-1026, :1752, :2901-2909, :3074-3077` | The header says the prior seven-tool and no-sub-agent clauses remain governing until acceptance, but the §14 paragraph, the §23.4 bullets and founding decision 8 were deleted or rewritten in place; the §10.1 diagram transitions changed in place with only a trailing note; "workspace" was inserted into a governing clause at `:1752` without a label. A reader cannot find the governing text without `git show 20ff082a`. | No. | Keep each prior clause verbatim, marked "governing until acceptance", beside its labelled proposal, or cite `20ff082a` with exact prior lines in the header; label the `:1752` edit. | No (editorial) |
| 47 | CG, medium | `docs/vision.md:12-17, :618-621`; `docs/vision-technical.md:1631-1652, :3124-3129`; ADR 0044 tech `:198-226`; ADR 0044 concept `:101-107`; `M7-technical.md:50-52` | The header scopes the amendment to "tool budget and its interaction-flow consequences", but the §27 dispositions concern ADRs 0041, 0044 and 0049, and §13.4 is unlabelled while ADR 0044 departs from it: continuation stored inside core reply/request records, core validates format, provider, model and nodes and runs the expansion rule, plaintext retention for the life of raw history. The plan lists §13.4 as binding. "Other vision boundaries are unchanged" is therefore not true. | No. | Widen the header to name §13.4 and the §27 dispositions; add a labelled note at §13.4 in both files stating what core validates, plaintext storage under the private store, and retention with raw history. | Yes (required decision above) |
| 48 | CG, medium | `M7.md:72-74`; ADR 0039 tech `:1206-1207`; ADR 0042 `:9`, 0044 `:9`; `M7-technical.md:45` | Scope promises ephemeral host instructions and reasoning selection in `run/2`; ADR 0039's closed option set has no such options; ADRs 0043/0045/0048/0049 amend that set explicitly, 0042 and 0044 do not; the table row omits both; no V step covers them. | No. | Add "also extends ADR 0039's closed startup options" to ADRs 0042 and 0044 and the table row, plus an evidence step; or remove the claim from scope. | No; scope already selected 2026-09-29 |
| 49 | IO, low-medium | `M7.md:327-337` vs `M7-technical.md:18-28` vs ADR "Prerequisite for" lines | Outcome mappings disagree: 0042 (2,7 / 2 / 2,7), 0044 (4 / 4,7 / 4), 0045 (5,6 / 5 / 5), 0048 (4,7 / 3,4,7 / 3,4,7). Under the concept, outcome 3's summarizer route could be built without ADR 0048 although ADR 0043 depends on it. | Link checks only. | Align all three to the union. | No |
| 50 | IO, medium | `docs/drafts/m9-*-technical.md:30`; ADR 0036 tech `:61-73, :87-88`; ADR 0046 tech `:67-90`; `M7-technical.md:970-985` | M9 lists only "configuration/compaction/question records"; ADR 0036 lists "configuration, compaction, interactions and host ledger state". Missing from both: v3 genesis and immutable selections, `model_request.v2` with continuation, reply v3 and `model_attempt_settled_v3`, receipt revision 4, prepared references and resolved read arguments, the authored-bound command revision, child sessions. The delegation ledger lives outside `Loopex.Store` yet ADR 0036's migrate reads "through the corresponding adapter reader" and retires the source; ledger handling during migration is undefined. M7's own inventory omits receipt revision 4. | Not in M7. | Have M9 evidence row 2 and ADR 0036 cite M7's inventory as a whole; state whether the ledger stays untouched or migrates and that backup includes it; add receipt revision 4 to the M7 inventory. | No |
| 51 | OI | ADR 0044 `:9` vs `M7-technical.md:35`; `docs/adr/README.md:239` | The table says ADR 0044 qualifies ADR 0011's continuation exclusion (body `:43` says so) but the header does not; the header mentions receipt revision 4 against ADR 0025 without a link or "amends"; the README claims all revised pairs name their exact amendments. | Not applicable. | Add both to the ADR 0044 header. | No |
| 52 | OI | ADR 0036 tech `:130-131`; ADR 0037 `:23-25`; ADR 0049 tech `:318-321`; ADR 0038 `:13, :86-89`; `roadmap.md:140`; `roadmap-technical.md:27`; M8 technical | ADR 0036 points at "ADR 0037's schema", which no longer exists (ADR 0049 owns the version-1 schema); ADR 0038 names M8 outcomes 1 and 5 but its decision 7 governs outcome 6 and it uses `bin/loopex init` from ADR 0037 without a Depends line; the roadmap ladder has no M7/M8/M9 rung and describes the amendment only as "question/helper"; M8 warns not to assume 0.4.0 after M7 while the roadmap assigns v0.4 to M10. | Not applicable. | Retarget ADR 0036; complete ADR 0038's lines; extend the ladder and amendment description. | No |

Checked and consistent: ADR 0037 and ADR 0049 agree on precedence and one
schema; ADR 0036's backup-command ownership versus V13's quiescent copies;
M8's helper boundary matches ADR 0046; §12.5 matches ADR 0043's checkpoint
fields; §3.2 "built-in sub-agent scheduler" still true; the amendment names
principle, compatibility and migration at `vision.md:337-343` (its evidence is
governance-procedural; citing the 2026-09-29 scope decision and the prompt-cost
probe would be stronger); ADR README rows 0036–0049 all Proposed; the evidence
index lists all six M7 records.

### Reconciliation of the 44 round 2 findings

Verdicts: repaired (R), repaired with residue (RR), partial (P), re-worded only
(W), rejected correctly (RC), rejected incorrectly (RI). "Where" gives the
repairing text or the residue.

| # | Claimed | Verdict | Where |
| --- | --- | --- | --- |
| 1 | A incorporated | R | `0043-technical.md:68-82`; context map excerpt disposition. Residue is the new finding 1 (newest group), a different unit |
| 2 | A drafted | RR | `0044-technical.md:328, 363`; three rounds measured, five fail; V7.3 has no rounds oracle (finding 41); no-history first request undisclosed (finding 4) |
| 3 | Summarizer and matrix | RR | `0044-technical.md:126-131`; probe confirms 7 of 23 rows mismatch; Haiku summary cell hedged (finding 12); maintenance `default` inexpressible (finding 13) |
| 4 | Example measured | P | `0043-technical.md:260-277`; 1,024-token reserve versus 6,144-byte envelope still unrelated; truncation has no named cause (finding 6) |
| 5 | Join repaired | R | `0041-technical.md:92-95` |
| 6 | Aggregate repaired | R | `0041-technical.md:115-127`; finite metadata overflow disclosed; residue is finding 1's later-prompt consequence |
| 7 | 4 KiB A | R | `0041-technical.md:176, 196, 255`; context map range disposition |
| 8 | Legacy A | R | `0041-technical.md:70-81`; context map inline disposition; artifact-capable rule undecided (finding 9) |
| 9 | Margin narrow | P | `M7-technical.md:234-246` makes the gate a failing check; nine tokens of slack at a 36-byte path, 1,010 at 96 bytes; ordinary paths refuse (finding 7) |
| 10 | Subtraction rejected | RR | `0041-technical.md:231-235` states 8,192 is the input budget; no configuration-time minimum-budget refusal; V6 budget unconstrained (finding 3) |
| 11 | Repaired | R | `0044-technical.md:307`; writer rule and adapter version acceptance still unstated (finding 16) |
| 12 | Streaming A | R | `0044-technical.md:389`; context map streaming disposition; handoff point and rendering unprobed (finding 15) |
| 13 | Summary A | R | `0044-technical.md:181`; context map summary disposition |
| 14 | Evidence gap | RR | `0044-technical.md:593-597` is evidence only; rendering and fallback unspecified, no owning case (findings 11, 41) |
| 15 | Clarified | R | `0041-technical.md:18-29` |
| 16 | Clarified | R | `0044-technical.md:602-603` |
| 17 | Limit retained | RI | `0046-technical.md:243-255` registers only helper jobs, so every local cancel is unclassified, not only races; concept `:61-63` says otherwise; only a witness was added (`:369-370`); no maintainer disposition (finding 20) |
| 18 | Uncertainty retained | RC, with obligation | `0046-technical.md:185, 384`; default 5 s grace fits the 10 s window; unknown arises when child grace exceeds the parent's or cleanup uses most of the grace; disclosure and a no-spend refusal remain open (finding 24) |
| 19 | Safety | RR | `0046-technical.md:137, 304, 371`; the stated lookup shape cannot exist in core and is not named as a join (finding 23) |
| 20 | Repaired | RR | `0046-technical.md:310-328`; classification source undefined while a create is unresolved (finding 22) |
| 21 | Repaired | R | `0046-technical.md:229-236` |
| 22 | Claim rejected | RR | `0046-technical.md:104-110, 379-380` concede 128 unreachable; owner named; `0049-technical.md:39` still admits 128 without a capacity check (finding 28) |
| 23 | Repaired | RR | `0046-technical.md:286-292`; fence still adapter-wide (finding 25) |
| 24 | Repaired | R | `0046-technical.md:256-265` |
| 25 | Repaired | R | `0046-technical.md:185-194` |
| 26 | Repaired | R | `0046-technical.md:329-332` |
| 27 | Strict pipe kept | RR | `0049-technical.md:148-170, 221`; an unrequested question in V2's static pipe fails a mandatory attended step and feeds finding 38; bidirectional case unowned (finding 32); `unknown` disposition missing (finding 30) |
| 28 | Repaired | RR | `0048.md:9`; `0048-technical.md:60-76`; `M7-technical.md:45-47`; shared resolver and CLI discard exemption unnamed (finding 31) |
| 29 | Repaired | RR | `0049-technical.md:91-99`; delegation allowance on resume unstated (finding 29) |
| 30 | Repaired | R | `0045.md:28-32`; `0045-technical.md:95-103` |
| 31 | Explicit limit | RR | `M7-technical.md:248-252`; ADR 0030 best-effort mailbox stated; "Loopex-only" wording mismatch (finding 36) |
| 32 | Maintainer A | R | context map wire disposition; `M7-technical.md:73-110`; `0044.md:143`; rows 4/8/9 migration unstated (finding 37) |
| 33 | Clarified | RR | `M7-technical.md:994-1011`; "supported procedure" remains at `:988-989` and in the V13 title; three-tree lane and digest-based binary identity unstated (finding 34) |
| 34 | Repaired | P | `M7-technical.md:842-867`; provider B, models and variable names unnamed; no pin mechanism or slot; OpenRouter question open (findings 33, 43) |
| 35 | Rejected | RC, with residue | `0048-technical.md:29-31` already excludes credential names by spelling, so the "name proves nothing" rejection is defensible; the residue is a mis-send risk (another provider's well-known name sent to the wrong endpoint), an optional guard |
| 36 | Strict retained | W | `M7-technical.md:424-436`; the strictness is the maintainer's recorded choice (review prompt), its mechanics are undecidable (finding 38) |
| 37 | Repaired | RR | `M7-technical.md:469-490, 949-954` agree; injection point exists; driver entry, policy origin and escript coverage unnamed (finding 35) |
| 38 | Repaired | RR | `M7-technical.md:815-841`; slots and pin timing (findings 43, 44); manifest identity conflict (finding 40) |
| 39 | Repaired | RR | `vision.md:12-17, 143, 229, 326-345, 618`; `vision-technical.md:493, 1031, 1064`; §13.4 and governing-text residue (findings 46, 47) |
| 40 | Maintainer A | R | context map helper-concurrency disposition; `M7.md:180-186`; `0046-technical.md:166-183`; slot source undefined (finding 21) |
| 41 | Repaired | R | `M7-technical.md:34, 36`; residual header mismatches (finding 51) |
| 42 | Repaired | R | `M7-technical.md:789-807` |
| 43 | Clarified | RR | `0041.md:21`; `0041-technical.md:16`; `M7-technical.md:916`; `vision.md:618`; the 2026-09-29 decisions remain plan prose only (context map `:369`); pin destination generic (finding 43) |
| 44 | Repaired | R | `0043.md:37-44`; `0044.md:23`; `M7.md:268-271` |

### Evidence limits

- No provider calls, product tests, probes, release lanes or dependency
  installs were run. Provider behaviour in findings 11, 12, 14 and 17 comes from
  the bundled Anthropic reference dated 2026-09-25 and from the retained
  mapping probe; real signature and summary sizes, Haiku's default display and
  summary status, acceptance of a final assistant tool_use without thinking,
  and extra block fields are unverified.
- Scratch probes were verified by hash, not rerun. They are synthetic: final
  M7 record shapes (receipt revision 4, maintenance and purpose fields) do not
  exist yet, so findings 3, 4 and 8 are estimates from measured shapes.
- The review was conducted by one integrating reviewer directing six read-only
  advisory passes over disjoint areas; each pass's load-bearing claims were
  re-read at the cited path before inclusion, but not every ADR technical file
  was read line by line by the integrator. Reconciliation rows marked R were
  checked at the cited passage and its surroundings, not by a complete reread
  of every file.
- Whether the daemon's lease owner can see child sessions the adapter creates,
  whether the app-server and daemon keep running after a refusal, the Node
  vector contents, `rollback-lane.sh` driver behaviour against M7, ReqLLM
  multi-route feasibility and actual HTTP wiring were not verified.
- No accepted document other than the review prompt records the maintainer's
  strict model-miss choice; the context map has no disposition for round 2
  finding 36. This review treats the prompt as the record.
- Planned scripts `scripts/m7-fixture-chat.exs` and
  `scripts/m7-ephemeral-question-demo.exs` and `test/fixtures/m7` do not exist,
  as expected for a planning candidate.
