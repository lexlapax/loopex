# M7 external review, round 2

Date: 2026-09-30. Reviewed candidate: `10749d084bd74487aac423d9640ac2eb1d05bee6`
(HEAD at review time, clean tree, equal to `origin/m7`). Repository treated as
read-only; no branch change, commit, push, provider call or test run. Prior
records read: `docs/evidence/M7-external-review-1.md`,
`docs/evidence/M7-audit-repair-review.md`, `docs/evidence/M7-continuation-review.md`.
The continuation review's contract digests were spot-checked against HEAD for
M7.md, M7-technical.md, ADR 0046 technical and the context map; they match.
Documentation checks and the skeletal prompt-sizing probe are not treated as
product proof. Every finding below was independently re-read at the cited
path; where a claim depends on provider behaviour, the source is the cached
Anthropic API reference dated 2026-09-25, not a live call.

## Concept

**Verdict: not ready for acceptance.** The round 1 repairs are real, not
cosmetic: bounded excerpts with artifact references, the labelled vision
amendment, explicit supersession lines, piped chat, child defer refusal,
catalog binding, the fixed attended subset, the V13 rollback procedure and the
context-map dispositions all exist in the committed bytes. The packet is now
close to acceptable on ownership and authority. It is not acceptable on
feasibility and closure, because four families of constraints, taken together
as written, make the promised behaviour unreachable in ordinary use or make
closure a matter of chance.

**Principal blockers.**

1. **A single large model-authored group permanently disables compaction.**
   Excerpts apply only to executor results. Assistant tool arguments (a
   `write` of about 10 KB, or a pasted prompt of about 12 KB) stay at full size,
   must be summarised as an indivisible group starting from the oldest range,
   and must fit a 16,384-byte source envelope that also holds the prior summary
   (up to 6,144 bytes). Once such a group is the oldest eligible one, every
   automatic and explicit compaction refuses with `compaction_input_too_large`,
   every overflowing staging fails, and with no branch or fork in M7 the
   session is dead. ADR 0043's evidence lists this refusal as a passing case.

2. **Thinking continuation cannot hold an ordinary coding run.** The capsule
   stores thinking, signatures and the full `tool_use` input; the aggregate
   envelope is capped at 16,384 bytes and is stored twice in the record; the
   whole record is capped at 65,536 bytes. Measured against current tool
   definitions and record shapes, a thinking run fits about three to five tool
   rounds, and a single maximal 4,096-token reply can exceed the capsule limit
   by itself, producing `unreadable_model_answer`. Compaction is barred while an
   exchange is open and stops as soon as the request fits, so a session near the
   ceiling fails every thinking run. Outcome 4's "multiple tool rounds" would
   pass at two.

3. **The thinking mode matrix does not match current Claude models, and
   compaction requires a setting they cannot provide.** Manual
   `budget_tokens` is accepted only by Haiku 4.5, which is Loopex's default
   model; it returns 400 on Opus 5.5, 5, 4.8, 4.7, Sonnet 5.5, 5 and Fable.
   Thinking cannot be disabled on Opus 5.5 or Fable, and Sonnet 5.5 needs a
   `between_tools` variant the ADR lacks. ADR 0043 requires a verified
   thinking-off setting for every maintenance call, so sessions on those models
   can never compact. Pinned ReqLLM 1.24.0 also injects `display: "summarized"`
   and silently converts manual to adaptive, contradicting the "provider
   default" mapping. Under the default 4,096 reply limit, `high` is always
   refused, which the ADR never says.

4. **Closure depends on single-shot real-model behaviour with no defined
   consequence.** The oracles now fail a task when the model does not call
   `loopex.ask` or `loopex.task`, the release check runs once, retry is
   forbidden, and an Accepted-limitation disposition cannot be recorded in the
   administrative commit. More than ten single-shot model-dependent verdicts
   exist. The plan detects a model miss but says nothing about what follows.
   The fixture test-policy adapter the attended steps need also contradicts ADR
   0049's closed policy registry.

**Required maintainer decisions.** Each preserves the recorded scope choices
unless stated.

| Decision | Options and consequences |
| --- | --- |
| Summary source for oversized model-authored content (blocker 1) | (a) Allow marked, bounded head/tail excerpts of old tool arguments and prompts in the summary source with a digest to the raw record: sessions keep working, summaries may lose argument detail. (b) Keep the rule and document that one large write can end a session: honest, contradicts outcome 3. (c) Cap write/edit argument size per call: keeps compaction alive, restricts the tools. Option (a) extends the "excerpts only for executor results" choice. |
| Continuation storage and headroom (blocker 2) | Store the capsule once, digest-bound, and keep positional references for derivable text and tool input: stays within the 65,536 choice but changes ADR 0044's two-copy form. Compact to a low-water mark before opening an exchange, at the cost of one extra maintenance call per run. State whether thinking-mode tasks are in the demonstration. |
| Thinking model matrix and compaction on always-on models (blocker 3) | (a) Let maintenance run with thinking on and nil continuation, with a measured reserve: works on all models, costs more tokens. (b) Declare Opus 5.5, Sonnet 5.5 and Fable unsupported for M7 compaction. (c) Limit M7 thinking to Haiku 4.5 and 4.6-class models. Also decide whether thinking configurations may require a reply cap above 4,096. |
| Model-miss disposition under no-retry (blocker 4) | (A) Strict: every real task must pass, expect several candidates each with a substantive fix and all failures retained. (B) Predeclared verdict `pass / product_failure / model_nonconformance` computed from committed facts; product proof carried by deterministic scripted-model tests; a disclosed model miss lets the maintainer decide. (C) Preregistered N attempts with a k-of-n threshold: changes the no-retry rule. |
| Attended fixture test path | Wrapper script as the operator path (production registry stays closed) or a fixture-only registry entry refused outside the pinned manifest (product command reproduces the run; adds a fixture profile to production code). Record in ADR 0049 or a small ADR. |
| Public `reasoning_delta` versus capsule privacy | (A) Keep it as a public summary and exclude only signatures and redacted data from the canary. (B) Suppress it whenever continuation is required, a visible CLI change. Amend ADR 0011 and 0023 accordingly. |
| Provider B and release lanes | Durable chat requires a credentialed hosted route, so B cannot be Ollama. OpenAI as B means two paid secrets in every release run; an operator-only lane is cheaper but release CI does not re-prove routing. Name A, B, exact models and variable names. |
| Protocol generations | (a) Refuse old generations after M7; in-repo Node clients and release rows update together. (b) Keep both; needs per-session attach refusal rules for pending text questions and committed configuration, and double the vectors. |
| Parallel-helper ban scope | The maintainer record bans parallel helpers unqualified; the amendment and ADR 0046 ban them only within a parent run. Confirm per-parent-run, or add a runtime-wide single-helper slot and test. |
| Prompt target and system ceiling | Helper-enabled chat is arithmetically about 1,450 to 1,500 estimated tokens against a 1,000 target and default ceiling. (a) Charge the system class over the compact JSON rendering, about 30 percent lower, amending ADR 0017's cost preimage. (b) Apply the target to the ordinary profile only. (c) Accept a stated higher ceiling. (d) Cut descriptions. |
| Prompting a child session directly | (A) Refuse: keeps the delegation allowance meaningful. (B) Allow as ordinary operator work not charged to delegation: weakens the allowance claim. |
| Range read size and old-session compatibility | Range reads of 1,024 bytes make a 16 KiB file cost about fifteen calls; decide a larger requested-range budget. Decide whether upgraded M6 sessions holding inline results above about 1.7 KB may be unpromptable, or whether old inline bytes project when the request still fits. |
| Ephemeral responder termination | Accept one sentence that Loopex terminates the host callback on expiry or abort even mid-effect, and that recursion is a host obligation. Decide whether ephemeral `ask` tracing is wanted, since it needs a new public option. |

## Technical depth

### Findings

Severity: **B** blocker, **S** should-fix, **N** note. "Checks" says whether the
plan's proposed evidence would catch the defect. "MI" marks findings needing
maintainer input, with options in the Concept table.

**Context, compaction and budgets**

| # | Sev | Where | Conflict and failing scenario | Checks | Smallest repair |
| --- | --- | --- | --- | --- | --- |
| 1 | B, MI | `docs/adr/0043-context-compaction-checkpoint-technical.md:40-58` vs `docs/adr/0041-...-technical.md:39-40` | Excerpts cover executor results only. After one checkpoint, the model writes a 10 KB file; escaped, that group exceeds the 16,384 minus 6,144 bytes left in the source envelope. When it becomes the oldest eligible group, every compaction stops with `compaction_input_too_large`; every overflow then fails; no fork exists. A 12 KB pasted prompt does the same. | No. The ADR lists "oversized single turn refusal" as a pass; the long fixture uses small files. | Marked bounded excerpts of old model-authored arguments and prompts in the summary source with a covered-record digest, or project old write/edit arguments as excerpts with a reference. |
| 2 | B, MI | `0044-technical.md` capsule and envelope paragraphs (16,384 per capsule and aggregate; two copies), `0043-technical.md:14-19` (open exchange ineligible), `0041-technical.md:137-140` | Capsule carries full `tool_use` input and text again; envelope stored twice; record capped at 65,536. Measured: base record about 14 to 18 KB; with a full envelope about 47 KB, three rounds fit. One entry is about 2.5 to 3.5 KB, so the envelope binds near five entries and "32 entries" is unreachable. A maximal 4,096-token reply exceeds 16,384 bytes alone: `unreadable_model_answer`, terminal. Near the ceiling, compaction stops at "fits", the next thinking run opens an exchange, round 1 does not fit, run fails, repeat. | No. Outcome 4 needs "multiple rounds"; V6 pins no reasoning level; boundary tests use synthetic sizes. | Store continuation once, digest-bound; keep positional references for derivable blocks; compact to a low-water mark before opening an exchange; constrain the admitted thinking budget so a maximal capsule fits; pin fixture levels and record rounds-to-failure. |
| 3 | B, MI | `0044-technical.md` thinking variants (omitted, disabled, manual 1,024/2,048/4,096, adaptive with `display: provider_default`); `0043-technical.md:64-72` | Cached Anthropic reference (2026-09-25): `budget_tokens` 400 on Opus 5.5/5/4.8/4.7, Sonnet 5.5/5, Fable; disabled 400 on Opus 5.5 and Fable; Sonnet 5.5 needs `between_tools`; default display is `omitted`. Manual mode works only on Haiku 4.5 (`req_llm.ex:60` default). Maintenance requires verified thinking-off, so Opus 5.5, Sonnet 5.5 and Fable sessions can never compact. ReqLLM 1.24.0 injects `display: "summarized"` (`anthropic.ex:1522-1529`) and converts manual to adaptive for models that require it (`:1494-1506`). With default `max_tokens` 4,096 (`runtime.ex:947`), `high` is always refused. | Partly. "Verify the actual outgoing request" would catch the injected display; nothing requires the model-by-mode matrix or compaction on always-on models. | Pin the supported model-by-mode matrix; make `display` an explicit retained value; add `between_tools` or allow maintenance with thinking on; state valid level and reply-limit combinations under ADR 0047 defaults and require a minimum usable reply remainder. |
| 4 | S | `0043-technical.md` output caps (summary 4,096 bytes, carry-forward 2,048, envelope 6,144) vs the 1,024-token reply reserve | By the plan's own estimator, ceil(bytes/3), a maximal summary is 2,048 tokens. A model that fills the six required sections hits `max_tokens`, yielding truncated JSON and a refusal with no repair call. Likeliest V6 failure. | No. | Raise the reserve to 2,048 or cut the byte caps to about 3,000 total. Also bound the host compaction instruction block and name the refusal when an embedding host supplies none. |
| 5 | S | `0041-technical.md:64-67`; `apps/loopex_executor_local/lib/executor.ex:4172-4180, 5470-5476`; `coding_tools.ex:60-61` | Spill happens only when output exceeds the declared 16,384 limit, so results between about 1.7 KB and 16 KiB reach staging with no reference. The "legacy" preparation episode is the normal path every turn, with store writes before intent. A turn with more than 16 such results hits the per-staging source cap and fails. | No. Only legacy results are tested for preparation. | State that preparation is the normal path and size its caps for it, or lower declared output limits in a new tool generation. |
| 6 | S | `0041-technical.md:39-40` (per-result cap) and `0043-technical.md:34-38` (newest group mandatory) | One reply with eight parallel reads or greps at maximal excerpts is about 38 KB plus base and summary: exceeds 65,536, run fails, and the group is irreducible. | No multi-call group test. | Aggregate excerpt budget per assistant group with an explicit omission marker, or bound calls per reply. |
| 7 | S, MI | `0041-technical.md:100-101, 124-127` | Reading a 16 KiB module: a plain read returns about 1.3 KB usable; the rest takes about fifteen 1,024-byte range reads, the whole 16-turn baseline serially, or an irreducible parallel group. Today the same file fits inline once. | No. Fixtures are tiny; external-repository files expose it after acceptance. | Larger requested-range lengths (4 to 6 KB) with the result cap scaled, keeping 2,048 bytes for unrequested excerpts. Measure external-task reads. |
| 8 | S, MI | `0041-technical.md:58-62` | Upgraded M6 sessions keep a read generation without `artifact_use`; any inline result above about 1.7 KB needs a retrievable projection, returns `artifact_read_unavailable`, and every new prompt refuses. The same history staged in M6. V13.2 does not list this as an expected observation. | Written as a passing test. | Project old inline bytes when the whole request still fits; refuse only when an excerpt is actually required; or permit a one-time explicit generation upgrade. |
| 9 | S, MI | `0042` concept `:25-36`; `M7-technical.md:98-101`; `M7-continuation-review.md:54-66` | Current coding profile is 799 estimated tokens; a skeletal probe with one-character descriptions reached 825. Helper chat with meaningful text, environment facts, role facts, artifact-capable read, ask and task is about 1,450 to 1,500. The gate is a disposition "before closure", not a failing check. The term encoding inflates the estimator input about 45 percent over the JSON the provider sees. | No. | Decide the target and ceiling now (Concept table). |
| 10 | S | `0041-technical.md:142-147` vs ADR 0017's 8,192 input budget; `0047-technical.md:15-16` | If 8,192 is the window W, W minus a 4,096 reply reserve leaves 4,096 input, below the post-compaction floor, so compaction can never fit. V6's "small context budget" can be set to a value that cannot work. | No. | State the fallback is the input budget; derive a minimum (system class + summary + tail + one maximal group + maintenance reserve); refuse smaller budgets at configuration time. |

**Thinking continuation**

| # | Sev | Where | Conflict and failing scenario | Checks | Smallest repair |
| --- | --- | --- | --- | --- | --- |
| 11 | S | `0044-technical.md` reuse of `model_attempt_settled_v2` vs accepted ADR 0021 technical `:34-42`; `provider_attempt.ex:36` | The kind is fixed by ADR 0021 to hold `bounded_canonical_reply_v2`; ADR 0044 admits a nine-field reply under the same kind and does not list ADR 0021 as amended. An M6 reader refuses the journal with a misleading diagnosis, or an M7 reader accepts a nine-key reply in a pre-M7 record. | No. | Mint `model_attempt_settled_v3`, or amend ADR 0021 explicitly with the key-set discrimination rule and downgrade fixtures. |
| 12 | S | `0044-technical.md` "lossless rendering" paragraph; `req_llm.ex:431, 485-529, 590-601, 639-650`; `in_process.ex:217`; `deps/req_llm/.../response.ex:203, 273, 284-285` | Both adapter paths see only ReqLLM's decoded output; redacted blocks never become chunks and text-block boundaries are lost. The only hooks below decoding are a provider module's `decode_stream_event/3` and a test-only raw capture. The ADR names no mechanism and forbids a dependency upgrade or second client. | No. | Name the mechanism: a registered wrapper provider module in the existing registry and companion; require the renderer to write the native array verbatim; add vectors for the buffered path as well. Maintainer input only if the wrapper counts as a second client. |
| 13 | S, MI | `0044-technical.md` privacy paragraph vs `req_llm.ex:639-650`, `progress_consumer.ex:247`, ADR 0011 technical `:545`, ADR 0023 `:284` | Thinking text streams publicly as `reasoning_delta` today. Under summarized display, capsule bytes equal the streamed bytes, so the required private-state canary on progress planes fails, or a shipped feature is silently removed. | The canary would fail without saying why. | Choose option A or B in the Concept table and amend ADR 0011 and 0023. |
| 14 | S | `0044-technical.md:183-188`; `0043-technical.md:32-35`; `context.ex:76-97` | A run ending on bound, cancel or `bound_reached` after tool results leaves an assistant `tool_use` with no thinking in canonical history. The next run on the same model with thinking on sends it followed by a user `tool_result` and a new user prompt; ReqLLM does not merge, so consecutive user messages reach the provider. Whether the API accepts a final assistant message without a leading thinking block is not evidenced. | Vectors cannot prove this. | Name a real-provider verification and a deterministic fallback (render the dangling group as closed history, or refuse with a named diagnostic). |
| 15 | N | `0041-technical.md:18-23` | Derived provider-facing IDs have no stated form; today `tool_call_id` is the provider's ID (`mapping.ex:318-326`). A native ID colliding with a derived one refuses the reply before tools, which is safe but terminal after tokens are spent. | Terminal outcome not stated as expected. | Give derived IDs a prefix that cannot match native IDs; state the terminal outcome in V7. |
| 16 | N | `0044-technical.md` privacy audience | Not named: `loopex chat` transcript, `ask --output json`, Node client history view, companion crash dumps (cite ADR 0039), ReqLLM telemetry. In practice the exchange is the whole run, so mid-run compaction is ruled out for thinking runs; stated, but neither V7 nor outcome 4 measures it. | Partly. | Enumerate the planes; add a pre-run headroom check or expected rounds-before-failure. |

**Helper ownership and recovery** (stop-only recovery holds: no path found that
sends a prompt or starts provider work after a committed `stop`, except via
the uncovered resume entry points in finding 20)

| # | Sev | Where | Conflict and failing scenario | Checks | Smallest repair |
| --- | --- | --- | --- | --- | --- |
| 17 | S | `0046-technical.md` stop-fence paragraph (`helper_admission_closed`) ; `session_coordinator.ex:6907-6911, 5945-5951` | Execute and cancel run in separate tasks, so the router may see either first. If it records only helper jobs, the first Ctrl-C during a local `bash` job is "unclassified" and closes helpers for every daemon session until restart; even recording forwarded jobs, a cancel racing a local dispatch closes the global flag. | No. Evidence tests only a cancel racing a helper execute. | Record every forwarded job ID; keep a bounded refused-ID set for never-seen IDs so a later helper execute with that ID refuses and a local one forwards; fall back to the global flag only on overflow. |
| 18 | S | `0046` concept `:46` and technical deadline and cleanup lines; `executor.ex:456-471, 382-387`; `0049-technical.md:36` | Parent cancel observation is max(10,000 ms, grace + 2,000). Inside it the helper must fsync `stop`, abort the child whose own tool job has the same grace and receipt retention, wait for the terminal, then fsync `settle` and `bind_receipt`. With grace above about 8 s, a confirmed child cleanup misses the window and the parent ends `outcome_unknown`. The child cutoff equals the parent job cutoff exactly, so cleanup starts when the parent expires. | No. | Set the child cutoff to the parent cutoff minus a declared cleanup allowance from `cancellation_bounds/1`; give the child a strictly smaller grace or refuse delegation when the chain cannot fit; add a fault test. |
| 19 | S | `runtime/control.ex:2363-2388, 2399-2404` vs `0046-technical.md` binding paragraph and recovery table | `lookup_create_result/3` compares canonical genesis bytes including the current runtime's `cleanup_grace_ms`. Crash after reserve with lost ack, restart with a changed grace: lookup returns `:conflict`, which the table does not map; an implementer may treat it as absent and report "no child" while one exists; the parent-binding replay of the same create also fails and fences the parent permanently. | No. The "duplicate creation after defaults change" test covers tool defaults only. | Look up by command ID plus retained original input digest; freeze resolved runtime values into the retained creation object; map `conflict`, `store_unavailable` and `unexpected` to unknown; name this core change in the joins. |
| 20 | S, MI | `0046-technical.md` "Host startup and CLI resume routing"; `mapping.ex:93-97`; `lease_owner.ex:836-845`; `connection_registry.ex:475-522` | App-server `session.resume` calls eager `Loopex.resume_session` directly; the daemon resumes through its lease owner; a controller can prompt a child directly. A generation-1 client can eager-resume a stopped helper's child and activate recovered work, or prompt it and spend provider-B tokens outside the allowance. | No. Evidence covers blocked eager activation on the CLI path only. | Route every host resume and attach-to-prompt entry through helper classification; refuse unclassifiable sessions under helper-enabled compositions; decide direct child prompting (Concept table). |
| 21 | S | `0046-technical.md` result paragraph vs ADR 0009 technical `:589-596, 640-645` | Parent Ctrl-C, child cleaned, helper receipt says `failed`; ADR 0009 says a confirmed abort or deadline termination is `cancelled`. Run-level result is right, operation record is wrong. | No. | When `stop` reason is `cancel` or `cutoff` and cleanup is confirmed, emit `cancelled` with confirmed cleanup; keep `failed` for independent child failures and bound exhaustion. |
| 22 | S | `0046-technical.md` ledger caps; `0049-technical.md:38` | Six frames per child at 65,536-byte payloads plus header and digest is about 393,678 bytes; 16 MiB holds about 42 children, not 128; the closing credit alone is about 328 KB. Refusal is definite, but an accepted `max_children` above about 42 is unreachable and the exhaustion evidence misleads. The owning app of the ledger module is still unnamed; placement is acquired in CLI and daemon (`loopex_cli.ex:1399`, `service.ex:337`), not composition. | Partly. | Per-kind frame maxima (stop, settle, create ≤ 4 KiB; receipt ≤ 64 KiB), or a 48 MiB cap, or reject `max_children` above capacity at validation. Name the owner. |
| 23 | S | `0046-technical.md` commit_unknown fencing lines | An fsync error on `stop` fences the adapter's whole mutation domain until replay at open; the text does not say whether child abort proceeds. In a daemon, the child runs to cutoff and every other parent's settle and receipt block, so those runs go unknown. | No. | State that the volatile fence already forbids launch, so abort and cleanup proceed and cancel answers unconfirmed; scope the fence per parent-run log; say whether live resolution is allowed. |
| 24 | N | `0046-technical.md` "fresh runtime/executor fencing"; `loopex_composition.ex:324` | Identity, epoch and fence are the constants `executor-local`, 1, 1 on every start. Exclusion of stale jobs rests on the exact router PID, which is adequate given recovered parents only call `retained_receipt` and `:absent` maps to `outcome_unknown` (`session_coordinator.ex:7705`). | Wording only. | Reword to PID and incarnation binding, or derive a fresh epoch. |
| 25 | N | `0046` concept `:9`; ADR 0013 concept `:66, 75-81`; `session_state.ex:1680-1718` | Supersedes names ADR 0013 but not its clauses. A fresh expired `deadline_at_ms` refusal is not journaled, so a wall-clock step backward lets a replay be admitted; re-validating the clock when resolving commit_unknown can tell the caller "refused" while the store holds an admission. A child may consume the parent's whole remaining deadline; not stated. | No. | Never re-validate the clock on commit_unknown resolution; journal the expiry refusal; state or reserve a parent margin. |
| 26 | N | `session_coordinator.ex:7650-7724` | If a recovered parent activates before startup cleanup writes the child's settle and receipt, the helper answers `effect_unresolved` (parent permanently unknown) or `effect_in_flight` (declined, needing an unspecified host reconciliation driver). | No. | Finish a bounded child abort and settle before opening parent activation, or specify the reconciliation driver. |

**Configuration, providers, ephemeral, protocol, tracing**

| # | Sev | Where | Conflict and failing scenario | Checks | Smallest repair |
| --- | --- | --- | --- | --- | --- |
| 27 | S | `0049-technical.md:43-47, 97-98, 165`; `M7-technical.md:324-327` (V2 via pipe) | Chat adds `loopex.ask` to every non-empty profile; the only exits drop the coding tools or helpers. If the model asks during a static piped V2 script, `/wait` reports `question`, the next plain line is refused as active-run input, pipe refusal is fatal, and the single attempt fails. Pipe mode itself is undefined (stdin or stdout not a TTY); TTY question rendering, `/status` and `/wait` input records, `choices` element shape and host outcome lines are unspecified. | No row for an unrequested question in a static script. | Add `session.questions` and `--no-questions`, off for V2 and static scripts; define pipe mode as stdin not a TTY; specify the missing record shapes. |
| 28 | S, MI | `0048` concept `:9` vs accepted ADR 0019 `:69` ("remains the only credential source") and ADR 0039 `:496-499` ("The durable profile keeps the single source"); `edges.ex:59-70`; `credential_host.ex:52-55`; `credential_plane.ex:41-43`; `service.ex:376`; `loopex_cli.ex:80-83`; `executor.ex:228, 5819-5826, 5846-5849`; `session_state.ex:139, 3905, 3941` | Durable chat with an `ANTHROPIC_API_KEY` reference contradicts two accepted clauses ADR 0048 does not name. The three-key plane validator, single-variable custody opens, daemon plane construction, CLI single-name discard, executor single-name exclusion and the receipt invariant `provider_credential_present == false` (a one-name claim) are not in the integration owner's joins. The multi-binding plane shape is unspecified. | ADR 0048's two-canary tests pass while the governance gap remains. | Add both clauses to the Supersedes line; specify the plane as a provider-to-token map with its validator; add the plane, custody, daemon, CLI and executor work to the joins; redefine or narrow the receipt field. |
| 29 | S | `0049-technical.md:87-92` vs `0044-technical.md:48-51` and `0047-technical.md:11-12`; `loopex_cli.ex:206-213` | On resume, `max_tokens`, `context_token_budget` and `system_class_tokens` are committed configuration per ADR 0044 but grouped with run bounds per ADR 0047 and omitted from ADR 0049's committed list. `loopex chat --resume S --max-tokens 8000` is applied by one engineer and refused by another. | V12.4 checks role files and defaults only. | Add the three settings to the committed list; conflicting flags refuse and point to `/configure`; only `max_turns`, `deadline_ms`, `token_budget` come from the invocation on resume. |
| 30 | S, MI | `0045` concept `:17, 26`; technical ephemeral interface; `ephemeral/options.ex:4-17` | "Opt-in" names no option; an absent responder "denies before admission" implies the tool is offered, changing staged definition bytes and prompt measurements for every existing `run/2` and `ask --tools coding` caller; `start_session` availability is unstated. Loopex terminates a host closure on expiry or abort even mid-effect; recursion cannot be enforced. Credential audience under ADR 0039 survives (no call in flight, DTO carries no credential, host code already in audience). | No. | Add explicit `questions: true` to `start_session/1` and `run/2`; run the responder from the caller's monitored worker calling `answer/3`; add the terminate-the-callback sentence. |
| 31 | S, MI | `0049-technical.md:178-183`; `ephemeral_ask.ex:113`; `session_owner.ex:2823-2831`; `loopex_composition.ex:44`; `runtime.ex:833`; `trace/config.ex:128-135` | Default `ask` is ephemeral and the host never holds its runtime reference, so V11.4 needs a new public Ephemeral trace option outside the API ADR 0045 preserves. `diagnostics_to` is one pid for all diagnostics, so the 256-entry backlog sheds non-trace diagnostics; boundedness under a stalled stderr needs a receiver and writer split; `Loopex.*` read as a name prefix would include credential modules. No host code calls `Loopex.trace` today. | No. | Limit trace flags to durable-owning commands or add ADR text for an ephemeral option; define selectors as the existing application wildcards excluding credential and sender modules; specify the receiver/writer split and drop-counter sharing. |
| 32 | S, MI | `M7-technical.md:50-61`; `session.ex:32, 191-200, 221-236`; `session/v2.ex:23, 196-205, 211-231`; `clients/node/*.mjs:23-24`; `0044-technical.md:237-238`; `0045` concept `:54`; `0043-technical.md`; `0046-technical.md` deadline | Preserve-or-refuse old generations is undecided; attach behaviour for an old client on a session with a pending text question or committed configuration is undefined; the new foreground generation cannot be named `loopex.experimental/2` (daemon uses it); ADR 0043 names no compact method; ADR 0045 does not name the text/decline extension of `session.respond_interaction`; both "jointly" sentences omit ADR 0046's `bounds.deadline_at_ms`; daemon and app-server have no provider-binding or role source, so `configure` to another provider always refuses there, unstated. | Node vectors test what gets built; they cannot choose. | Decide (a) or (b); write one member inventory (commands, events, snapshot fields, interaction kinds, bounds, definition-format generation); fix the two sentences. |
| 33 | S | `scripts/rollback-lane.sh:9-18, 69-83`; `scripts/lib/rollback-case.sh:8-9, 31`; `check-release.sh:200-203`; `M7-technical.md:655-659`; ADR 0036 concept `:63-67, 80` | The lane takes nine arguments, pins v0.2.0 and builds two trees from source archives. New-to-old cases must fail by design once the candidate writes v3 genesis, so "extend without dropping earlier proofs" is self-contradictory as written; V13 needs the exact v0.3.0 artifact, not a source build. V13.4 "prevent the old binary from opening the live root" has no mechanism (ADR 0036 defers the marker). The copy-and-restore route is called "the supported procedure" while ADR 0036 places backup semantics in M8. ADR 0038's conditional switch-back text is consistent. | Partly. | Keep pair v0.2.0 to v0.3.0 unchanged; add pair v0.3.0 artifact to candidate with the M7 matrix; state which v0.2-to-candidate claims become historical; make V13.4 an operator precondition; call the route a fixture and runbook procedure, not backup semantics. |
| 34 | S, MI | `M7-technical.md:382-394, 405, 541`; `0049-technical.md:25`; `0048-technical.md:33-35`; `check-release.sh:25-56, 63-64, 117-163, 297-330`; `release-lane.sh:156-162`; `scripts/attended-pty.py:20-29` | Provider B must be a hosted credentialed provider passing maintenance thinking-off verification. Runner has fixed rows, index-chosen credential modes, one required name and four-name redaction; values bound to arbitrary names would not be redacted; `attended-pty.py` hard-codes two prompts. Whether A-to-B-to-A rows run in every release check is undecided. | "Implementation work" hides three decisions. | Name A, B, models and variables; pass selected names to the redactor and self-check; decide lane placement. |
| 35 | N | `0048-technical.md:16-19, 30-31`; `guards.ex:16-21` | Nothing checks that a named ephemeral variable matches its provider; `anthropic: {env: OPENAI_API_KEY}` validates and sends the OpenAI key to Anthropic. No Ephemeral option carries the name. Clarify that `config show` is host-local and that `/status`, trace entries and control records never carry names. | No. | Refuse another provider's well-known default name; name the Ephemeral option. |

**Outcomes, oracles, closure, consistency, vision**

| # | Sev | Where | Conflict and failing scenario | Checks | Smallest repair |
| --- | --- | --- | --- | --- | --- |
| 36 | B, MI | `M7-technical.md:205, 210, 257-259, 520-529`; `M7.md:272-276, 353-356`; `milestones.md:82-84`; `verification.md:123-125`; `milestones-technical.md:224` | Every task must complete once; a model that ignores the required call fails the attempt; no retry; the administrative commit may only touch the Closure row, so an Accepted-limitation fallback forces a new candidate and full rerun, which is retry-into-green by another name. V4.1-2 needs a steer window with no mechanism guaranteeing one; V7.3's rounds depend on how long the model thinks. More than ten single-shot model-dependent verdicts. | Checks detect the miss; nothing classifies it or says what follows. | Predeclare an oracle verdict `pass / product_failure / model_nonconformance` from committed facts; carry product proof in deterministic scripted-model tests; record the real run once in a Pending slot; define a deterministic steer window (a pending question or a blocking fixture command); pin a low thinking mode for V7.3. Choose (A), (B) or (C). |
| 37 | S, MI | `M7-technical.md:263-267` vs `:617`; `0049-technical.md:26`; `loopex_cli.ex:312`; `shell_allowlist.ex:42, 73-85` | `policy` is a required member validated against the closed registry (allow_all, refuse_all, shell_allowlist, none permitting a test runner). The plan says the fixture adapter is "supplied by trusted validation-harness composition to the real CLI path" and "exposes no new production config profile", yet lists "the CLI policy registry's fixture adapter" as a join. Mandatory attended V2.3 and V5.2 cannot run through the product command without allow-all. A new bash grant path is a trust decision no ADR records. | No. | Record the operator path in ADR 0049 or a small ADR and make the two plan passages agree (Concept table). |
| 38 | S | `M7-technical.md:531-535` vs `milestones-technical.md:143-172, 226`; `M6-closure-runs.md:10, 80`; `0047-technical.md:25-28`; `0042:66-67`; `M7-technical.md:286-290` | Scaffold slots omitted: floor-pair and current-pair run identities and durations; tested archive manifest reference and digest; candidate and source identity section; rollback-lane identities; fixture manifest and oracle digests; per-task measurements; per-profile prompt measurements; operator identity and attended-answer authority; Node vector results; reviewer identities. The external pin must precede the attempt, but a Pending slot filled afterwards proves nothing about timing. Proved/Pending wording matches the guide. | No. | Enumerate the slots; require the external pin as a committed candidate file or a retained, digested record dated before the attempt and referenced from a predeclared slot. |
| 39 | S | `docs/vision.md:12-16, 312-331`; `docs/vision-technical.md:486-490, 1014-1020, 1043-1051, 3115, 3126`; `docs/plans/README.md:25-27`; `docs/roadmap.md:136-139` | §6.4 (user input arrives via policy `defer`), the §10.1 diagram (`suspended --> run_terminal: denied / expired`) and §10.2 steps 7 to 9 (interactions come from deferral; every allowed tool commits executor intent) contradict ADR 0045, where an allowed `loopex.ask` opens an interaction with no executor intent and expiry or decline returns a tool result while the run continues. The header "Other vision boundaries are unchanged" is therefore false. §27 rows on continuation retention/encryption and inline-versus-artifact bytes remain open though ADRs 0044 and 0041 decide them. §14.2 carries no principle/evidence/compatibility/migration statement; the register names no vision acceptance decision; the roadmap does not mention the amendment. | No. | Amend §6.4, §10.1, §10.2 with labelled text; disposition both §27 rows; cite evidence of need; add vision acceptance to the register and plan decisions. |
| 40 | S, MI | `agent-context-map.md:6166-6168`; `M7.md:45, 92-93` vs `vision.md:317-320`, `vision-technical.md:1760-1762`, `0046` concept `:30, 61` | The maintainer record bans parallel helpers unqualified; the amendment and ADR restrict only within a parent run and say independent parents remain concurrent. | No. | Confirm per-parent-run or add a runtime-wide single-helper slot (Concept table). |
| 41 | S | `M7-technical.md:34, 36` vs `0041:9`, `0042:9`, `0043:9`, `0046:9` | ADR 0010 row names only 0044; ADRs 0041 (tool-result projection), 0042 (system text source) and 0043 (raw-only projection, compaction deferral) also amend it. ADR 0017 row says 0041 to 0044 but omits 0046 (closed prompt/follow-up bounds). Other rows match. | No. | Complete the two rows. |
| 42 | S | `M7-technical.md:365-368, 503-504, 514, 521-523` | V5.6's attended positive path has no operator surface; `run/2` with `question_responder` is an embedding API. Operator identity format undefined (reuse `Maintainer | Delegate: <recorded identity>` from the register). "All remaining steps map to automated evidence" has no step-to-test manifest; V8.5-7 and V5.4-5 are fault-injection tests and should be mapped by test ID. Progress mapping is consistent with the register. | No. | Name the ephemeral demo host or drop V5.6 from the attended set; define the identity field; add the manifest. |
| 43 | N | `0044-technical.md` capsule content and `0041` derived IDs | Sole record of the maintainer's 2026-09-29 decisions is plan prose (context map `:369`); the external-task pin has no destination. Outcome 1 is a conformance defect against a closed milestone (ADR 0010 `:344` says M2 implemented lineage) and is still recorded only as "implements". The default tool profile is silently changed by adding `loopex.ask` (`0049-technical.md:43-44`) without dispositioning the vision's open profile question. The five-level reasoning enum still lacks a "why not an edge" row. | No. | Add dated dispositions; record the defect; disposition the profile question; add the row. |
| 44 | N | Concept versus Technical | `0043` concept `:26-27` and `M7.md:305` say the session's model writes the summary but omit the host-owned versioned compaction instruction block in `0043-technical.md:60-63`. `0044` concept is silent on the raw capture/render path bypassing ReqLLM conversion. `M7.md:247-249` omits configuration (V12) and upgrade/rollback though V13.1 and V13.4-6 are mandatory attended steps. The items challenged in round 1 (0046 defer refusal, 0044 Anthropic-only, 0041 preparation, 0045 ephemeral, 0049 piped) now agree across the pairs. | No. | Surface the host prompt block, raw path and runbook coverage in the concept files. |

### Disposition of round 1 blockers

| Round 1 item | Status at `10749d08` | Repairing text or residue |
| --- | --- | --- |
| 16-KiB outputs versus compaction and record ceiling | Repaired for executor results; new gap for model-authored content | `0041-technical.md:39-62, 99-130`; `0043-technical.md:40-58`. Residue: findings 1, 5, 6, 7; §27 inline-versus-artifact row undispositioned. |
| Phase-1 default budget too small | Partially | `0041-technical.md:143-148` derives W minus R. Audit-repair review says "measure the actual fixture", which restates the question. Finding 10. |
| Seven-tool and no-sub-agent readings | Repaired with residue | Labelled amendment in both vision files. Residue: findings 39, 40. |
| Undeclared amendments (0013, 0017, 0011, 0009, 0024; ephemeral API; child defer; catalog binding) | Repaired in the ADRs | Supersedes lines at `0041:9`, `0043:9`, `0044:9`, `0045:9`, `0046:9`; `0045-technical.md` ephemeral interface; `0046-technical.md` defer and binding. Residue: plan table (finding 41); ADR 0021 (11); ADR 0019 and 0039 clauses (28). |
| Attended set and pass rule | Repaired | `M7-technical.md:506-525`. |
| Prose-judged release rows | Repaired | Concrete oracles at `M7-technical.md:242-255`. |
| Model choice versus single run | Re-worded only | "fails that attempt. Do not retry" states no consequence. Finding 36. |
| Compatibility evidence row and backup gated on ADR 0036 | Repaired | V13 at `:478-496`; quiescent copies; rollback lane re-pinned at `:655-659`. Residue: finding 33. |
| Evidence scaffold | Partially | Named with a slot list; slots omitted (finding 38). |
| Hidden work: executor slot and construction order; interaction re-runs policy; two protocol servers; context map | Repaired | `0046-technical.md:16-23`; `0045-technical.md:33-38`; `M7-technical.md:50-61`; context map `:59, 369, 6156-6200`. |
| Hidden work: eleven-row runner and one credential; PTY helper | Named as obligation; PTY helper exists | `M7-technical.md:536-542`; `scripts/attended-pty.py`. Residue: finding 34. |
| Hidden work: single-provider wiring in core receipt validation and executor | Not addressed | Finding 28. |
| Test runner blocked by the shell allowlist | Partially | Fixture policy adapter at `:262-279` contradicts ADR 0049 (finding 37). |
| System-class ceiling about 3 KB | Re-worded only | "Measure each actual profile"; probe already at 799 of 1,000 (finding 9). |
| Should-fix: outcome 1 as a conformance defect; "why not an edge" rows; missing capabilities; prompt-budget escape hatch; piped input; Anthropic canary; provider pair; joins; durable decisions; stale labels | Mostly repaired | Rows exist at `M7-technical.md:578-585` (enum missing); branch/fork and tool changes deferred (`M7.md:79-81`); piped input specified; instruction version, environment rendering and child budgets defined; 2026-09-30 decisions in the context map; roadmap and placement table fixed. Not done: live canary (`0044-technical.md` states none was used); provider pair (34); compact method name (32); 2026-09-29 decisions and external pin destination (43). |

### Evidence limits

- No provider calls were made. Model and mode behaviour (findings 3, 6, 13,
  14) comes from the cached Anthropic API reference dated 2026-09-25, whose
  drift table states the same `budget_tokens` and `disabled` rejections. Real
  capsule and signature sizes per round were not measured; the round counts in
  finding 2 are simulations against compiled `_build/dev` beams using current
  tool definitions and approximated M7 record keys, read-only.
- Whether the API accepts a dangling `tool_use` without a leading thinking
  block on the same model (finding 14) and whether steer text after tool
  results breaks signatures could not be determined without a live call.
- Whether a capsule's tool-argument nesting stays within the store's depth
  limit of 12 (`store.ex:54`) was not checked; arguments sit about nine levels
  deep inside the envelope.
- The toolchain pin for `scripts/attended-pty.py`, ReqLLM telemetry content,
  `ToolCallIdCompat` passthrough under Loopex options, which genesis version
  v0.2 roots carry, and daemon stderr behaviour under service managers were
  not verified.
- ADR 0038's edits were checked by hash and one quoted passage only.
- Whether `check-release.sh` runs the attended runbook in-process or as a
  separate demonstration is implied by `M7.md:353-356` but not stated.
- The prompt-cost probe in the continuation review is a planning measurement,
  not product proof, and was used here only as an input to finding 9.

### Non-blocking notes

- Preparation episode ordering (commit reservation, `ArtifactStore.put`, commit
  reference) is consistent with ADR 0010 intent-before-dispatch and with the
  executor's spill-before-receipt order; content-addressed `put` converges on
  recovery (`artifact_store.ex:435-452`). Residual: cancellation after `put`
  orphans objects with no collection, bounded at 1 MiB per staging identity;
  the 60,000 ms preparation window runs before the relative deadline starts;
  add a vector that the five provenance labels never include preparation
  attempt identity.
- With a known large window the 65,536-byte record binds first, at roughly 20
  to 25 thousand real tokens; compaction will run about every four maximal
  rounds in non-thinking runs, costing one turn each, so outcome 3 survives in
  that path. Documentation should say "context fills" means the 64 KiB record.
- The v3 genesis decoder rule ("reads v2/v3, pre-v2 refused") matches current
  code (`session_state.ex:1955-1974`; `control.ex:2403-2417`); genesis size is
  not a practical risk.
- Child policy defer to `interaction_unsupported` is coherent with the existing
  `:refuse_defer` evaluator path (`policy.ex:159, 393-396`); the remaining work
  is wiring the per-session mode into the two `:admit_defer` call sites and
  genesis.
- Helper receipts sharing the local executor's identity, epoch and fence pass
  today's `receipt_matches_job` and reconciliation comparison
  (`session_state.ex:3764-3773`; `session_coordinator.ex:7747-7760`).
- `Runtime.lookup_create_result/3`, `Loopex.prepare_resume_session/3`,
  `activate_resume/1`, idempotent create with command ID and the placement
  lease all exist; `active_tools` is runtime-wide only and `policy_defer_mode`
  and `bounds.deadline_at_ms` do not exist, as the plan's joins list implies.
- ADR 0047 and 0049 agree on mandatory bounds; ADR 0046 allowance fields and
  ADR 0045's `/answer` and `/decline` syntax are consistent.
- Waiting for a human answer consumes the run deadline (ADR 0045 expiry rule);
  the attended V5 operator must answer within the remaining 600,000 ms
  baseline. Stated, but worth a runbook caution.
