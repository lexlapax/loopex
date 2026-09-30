<a id="technical-depth"></a>
## Technical depth

Concept: [M7 coding-agent proof](M7.md#concept).

<a id="technical-plan-prerequisites"></a>
### Prerequisites and Acceptance Points

Concept: [Purpose](M7.md#concept-plan-purpose).

Concept: [Design decisions](M7.md#concept-plan-decisions).

M6 is Closed. Nine ADRs and the labelled narrow amendment to both vision files
are proposed with this candidate. The vision tool-budget amendment is a
prerequisite for questions and helpers. Each decision is accepted before the
implementation that depends on it:

| Decision | Accepted before |
| --- | --- |
| [ADR 0041](../adr/0041-session-lineage-projection-and-context-budget.md#concept) | Outcome 1's projection change |
| [ADR 0042](../adr/0042-host-composed-instructions.md#concept) | Outcome 2's instruction option |
| [ADR 0043](../adr/0043-context-compaction-checkpoint.md#concept) | Outcome 3's checkpoint record |
| [ADR 0044](../adr/0044-run-model-and-reasoning-configuration.md#concept) | Outcome 4's configuration and bounded private thinking continuation, with versioned replies/settlements and charged context; outcome 7's resolved per-role model configuration |
| [ADR 0045](../adr/0045-model-originated-questions.md#concept) | Outcome 5's tool class |
| [ADR 0046](../adr/0046-child-session-tool.md#concept) | Outcome 7's adapter |
| [ADR 0047](../adr/0047-reference-host-run-defaults.md#concept) | Outcome 6's mandatory configured bounds and outcome 8's measured baseline |
| [ADR 0048](../adr/0048-host-provider-routing-and-credential-bindings.md#concept) | Outcomes 4 and 7 provider routing and credential bindings |
| [ADR 0049](../adr/0049-explicit-host-configuration.md#concept) | Outcomes 6 and 7 explicit configuration, roles and command grammar |

Accepted decisions that constrain the work:

| Decision | Constraint on M7 |
| --- | --- |
| [ADR 0010](../adr/0010-provider-continuation-and-context-staging.md#concept) | Staged bytes are committed with intent and digest-bound. A prompt to a settled session projects the whole retained lineage; ADR 0044 amends session-fixed model and empty continuation |
| [ADR 0011](../adr/0011-session-input-algebra-and-streaming.md#concept) | Existing ordering remains; ADRs 0043/0044 add compact/configure and ADR 0046 adds the explicit deadline ceiling |
| [ADR 0017](../adr/0017-durable-context-admission-budget.md#concept) | Exact record/depth/cardinality limits remain; ADRs 0041–0044 amend host defaults, system ceiling, compaction-before-failure, session configuration placement and charged continuation |
| [ADR 0013](../adr/0013-run-deadline-commitment-at-first-request-staging.md#concept) | Existing relative deadline remains; ADR 0046 explicitly permits an earlier committed absolute cutoff, including before first staging |
| [ADR 0016](../adr/0016-configured-cancellation-observation.md#concept) | ADR 0044 adds one shared v3 genesis; mandatory cleanup and known-version decoding remain |
| [ADR 0018](../adr/0018-provider-attempt-authority-and-recovery.md#concept) | ADR 0043 extends permits/settlement/accounting to maintenance; ADR 0044 versions the closed reply/settlement shapes for private continuation; two attempts per logical operation and no ambiguous redispatch remain |
| [ADR 0009](../adr/0009-tool-executor-and-grant-contracts.md#concept) | ADR 0041 adds read ranges/resolved arguments, ADR 0045 interaction dispatch, ADR 0046 explicit per-create selection; exact generations, grants and reserved namespace remain |
| [ADR 0024](../adr/0024-durable-interaction-lifecycle-and-host-policy-authority.md#concept) | ADR 0045 adds model producer/text/decline; ADR 0046 adds immutable defer refusal; interactions grant nothing |
| [ADR 0039](../adr/0039-ephemeral-embedded-profile.md#concept) | Credential audience/cleanup preserved; ADR 0045 adds bounded one-call answers and ADR 0048 permits explicit env names |
| [ADR 0034](../adr/0034-provider-credential-handoff-over-bootstrap-channel.md#concept) | Durable provider dispatch retains host-owned credential references and per-invocation custody; ADR 0048 narrowly amends its single-provider restriction |
| [ADR 0030](../adr/0030-observability-tracing-and-telemetry.md#concept) | Host-owned runtime tracing, bounded diagnostics and redaction remain unchanged when exposed through startup flags |

Vision sections that bind the work: what Loopex is not (§3.2), compaction
(§12.5), model identity and provider state (§13.4), the context pipeline
(§13.5) and the minimalism budgets (§23.4).

Proposed ADR 0037 governs installed discovery in M8, not this milestone.
Public protocol and generic bounds additions in ADRs 0043–0046 share one
coordinated M7 integration, with distinct negotiated contracts for both the
foreground generation-1 and daemon generation-2 servers. Preserve old payloads
under their old negotiation or explicitly refuse that negotiation; never send
new payloads under an unchanged generation/digest. Inventory command inputs,
configuration/genesis, interaction variants, events, snapshots and bounds,
including authorization differences. The new digest includes canonical payload
schemas, not only method/record names and limits. Independent Node vectors
cover both servers and old/new-client combinations. Acceptance binds the
proposal contracts; source implementation and numeric schema identifiers are
verified at the first protocol integration before any new wire shape is exposed.

<a id="technical-plan-configuration"></a>
### Explicit configuration contract

Concept: [Explicit configuration](M7.md#concept-plan-configuration).

[ADR 0049](../adr/0049-explicit-host-configuration-technical.md#technical-adr-0049-decision)
is the single schema, precedence and grammar definition. It specifies explicit
JSON, exact provider:model selection, mandatory file run limits, saved roles,
relative-path rules, prompt files, effective value origins and trace controls.
Core and reusable composition receive explicit options and read no files.

The proposed `loopex chat --config FILE` owns a foreground durable runtime.
It adds settled prompts and explicit steer/follow-up/answer/compact/configure/
abort/status/wait actions, ordered TTY and pipe input, explicit answers/declines,
bounded EOF/interrupt cleanup and fail-fast pipe errors. Existing
`ask`, `run`, `resume` and daemon client semantics remain, except explicit trace
startup controls on owning hosts. Remote chat attachment is M8 successor work.

ADR 0047 preserves 16 turns, 600,000 ms and 1,000,000 run tokens as documented
starting values; the file must declare them or other valid explicit values.
The reply default remains 4,096. Helpers require independent child-count,
aggregate-token and per-child bounds, with no silent spending defaults.
ADR 0046 persists reservations and outcomes across restart. Operator output
separates parent usage, helper usage and combined totals; token thresholds stop
subsequent work and do not promise exact provider invoice caps.

Model requests, including the normalized record envelope and receipt, remain
at most 65,536 bytes. ADR 0043 fixes summary input/output limits and a four-attempt
maintenance ceiling. ADR 0041 projects bulky tool output as retained artifacts
with at most 2,048 encoded bytes per executor-backed model-facing result, and adds bounded read
ranges. Compaction uses those projections without automatically fetching full
objects. Model-question results preserve exact bounded answers and use the
ordinary final preflight, including explicit irreducible refusal. Measure the
complete final record, including both semantic messages
and canonical bytes. Irreducible content refuses explicitly.
The reference prompt target remains below 1,000 estimated tokens, including
question/helper definitions and role facts for demonstrated chat profiles.
Measure each actual profile. An explicit larger host ceiling does not itself
approve a reference-product target deviation.

Trace flags map only to the existing runtime-scoped host API and ceilings.
Bounded stderr consumption, separate drop counts, redaction, credential process
exclusions and runtime cleanup are implementation obligations. They add no
client trace method. Effective inspection never resolves a credential.

<a id="technical-plan-comparison"></a>
### Comparison Basis

Concept: [Purpose](M7.md#concept-plan-purpose).

Read from source at `20ff082a23b7f0bbba09f123a3db0dc262a866bc`, which
retains the M6 implementation, with the comparison recorded on 2026-09-29:

| Fact | Location |
| --- | --- |
| Turn continuation and bound order | `apps/loopex/lib/loopex/runtime/session_coordinator.ex` `settle_turn/2`; `apps/loopex/lib/loopex/bounds.ex` |
| Fixed instruction block | `session_coordinator.ex` `system_block/1` |
| Request options: model, active tools, `max_tokens`, deadline | `session_coordinator.ex` `model_candidate/5` |
| A run's conversation starts as its prompt alone | `apps/loopex/lib/loopex/runtime/session_state.ex`, both `Map.put(state.conversation, run_id, [element])` sites |
| Reasoning is streamed back and no setting is sent | `apps/loopex_llm_reqllm/lib/loopex/llm/req_llm.ex` |
| Tools: read, write, edit, bash, grep, find, ls | `apps/loopex_executor_local/lib/coding_tools.ex` |
| Interaction kind is exactly `choice` | `apps/loopex/lib/loopex/interaction.ex` |

The earlier Pi and opencode comparison was an exploratory source summary,
not a versioned compatibility assessment. The current proposal relies on the
specific Pi documentation below and Loopex's own contracts. It copies no
implementation, tests or private contract, and creates no Pi compatibility
claim.

<a id="technical-plan-specialization"></a>
### Pi research and scope mapping

Concept: [Specialized agents and the milestone boundary](M7.md#concept-plan-specialization).

Primary documentation was checked on 2026-09-29, after Context7 resolved
`/earendil-works/pi`. Context7 also returned material about a separate Pico
API; that does not establish the Pi coding-agent CLI's built-in behavior.
The live documentation is a dated comparison, not a dependency pin.

| Suggested strategy | Verified capability and correction | M7 disposition proposed |
| --- | --- | --- |
| Markdown specialization | [Prompt templates](https://pi.dev/docs/latest/prompt-templates) expand text into the current conversation. They do not create another session or enforce a tool restriction | Resolve saved host roles to instructions/model settings and use existing admitted skills; no role type in core or new template language |
| Project instructions | [Configuration](https://pi.dev/docs/latest/configuration) distinguishes discovered context files from trusted project configuration. Project system overrides live in `.pi/SYSTEM.md`, with `.pi/APPEND_SYSTEM.md` for appending | Preserve Loopex's project-resource admission and provenance; never promote a repository file into trusted system content merely because of its name |
| Terminal teams and branches | Pi's [session guide](https://pi.dev/docs/latest/sessions) distinguishes `/tree` within one session file from `/fork` into another. Neither operation creates a Git worktree | Document ordinary session separation; do not claim a terminal pane or conversation fork isolates filesystem writes |
| Automatic delegation | The [Pi overview](https://pi.dev/) excludes built-in subagents and points to extensions. Its [subagent example](https://github.com/earendil-works/pi/blob/main/packages/coding-agent/examples/extensions/subagent/README.md) supplies separate processes and configurable tools | Learn from explicit child context and tool selection; implement ADR 0046 as a Loopex host adapter, not a Pi launcher |
| Programmatic orchestration | [RPC](https://pi.dev/docs/latest/rpc) controls a long-lived subprocess through JSONL; print/JSON and an SDK are also available | Keep the existing Loopex facade and protocol as the shared contract; a Pi adapter needs its own later scope and failure mapping |

Pi's [security boundary](https://pi.dev/docs/latest) leaves tools and
extensions with the process's permissions. A prompt role is therefore not
evidence of read-only execution. For Loopex, demonstrate read-only helpers
with an explicit tool set and policy, and describe the local executor's
existing trust limits. Do not claim OS isolation.

For the two M7 examples, the explicit host file saves a repository-investigation
role and a review role with instructions and model choices. Both use the same
four read-only tools. The parent supplies a bounded task prompt; the host
resolves the selected role before admitting child work. A role name embedded
in free text grants nothing. Define the selection field and which configured
roles the host exposes rather than interpreting arbitrary model text as
configuration.

The maintainer selected automatic parent-initiated delegation among the
host-enabled roles after helper opt-in. Include a validated role selector in
the task tool's bounded arguments and expose only the admitted role choices.
Every call still consults host policy; allowed calls do not require an extra
M7 confirmation step. Refuse unknown/disabled roles and prevent arguments
from overriding role credentials, tool policy or bounds. Record the resolved
role identity and configuration with the child for inspection and recovery.

ADR 0046 freezes the parent role catalog and selected child settings, with
stable operation-bound command IDs and a private host ledger. ADR 0048 supplies
one admitted env-reference binding per provider; durable custody and ephemeral
caller resolution stay distinct. Host restart may explicitly rebind the same
provider to a replacement key without redirecting a committed model request.

ADR 0044 specifies pure cross-provider history conversion and A→B→A proof.
Canonical text and tool facts survive. Selected Claude thinking modes preserve
exact private continuation within an open exchange, including across restart.
The complete rendered prefix stays fixed; compaction waits until the exchange
ends. Later runs start without old provider state, including on A→B→A.
After helper-manager failure, ADR 0046 recovers completed results and stops
unfinished helpers without replaying create/prompt or activating recovered work.
No parallel, nested or write-capable helper is included.

<a id="technical-plan-evidence"></a>
### Evidence Obligations and Mapping

Concept: [Outcomes](M7.md#concept-plan-outcomes).

Concept: [Scope and non-goals](M7.md#concept-plan-scope).

Concept: [How each outcome is verified](M7.md#concept-plan-verification).

| # | Fast check | Release check |
| --- | --- | --- |
| 1 | The second run's staged request contains the first run's prompt, assistant messages and tool results in committed order. The projection is rebuilt identically after owner succession and restart. Accounting for the new run starts at zero | The second prompt of a real session refers to the first |
| 2 | Staged bytes equal the host's composed block. The digest changes when the block changes. An oversize or malformed block is refused before dispatch. Project files stay in separate provenance classes. Core retains only ADR 0042's compatibility fallback | The default block drives a real task; record its cost with the active tools |
| 3 | The checkpoint records input range, summary, model identity, usage and integrity digest. Projection substitutes it and keeps the first later raw record verbatim. Raw records remain readable. Recovery selects the last committed checkpoint, fences uncertain commits and never repeats an ambiguous summary attempt. Tool receipts and effect outcomes are unchanged by a summary | A real session passes its context limit and continues |
| 4 | Run configuration commits provider/model and reasoning. Adapter conformance proves native thinking/block fidelity, frozen-prefix replay, original IDs inside the exchange, canonical conversion afterward, private-state exclusion and all size limits. Crash/commit_unknown cuts preserve atomic reply/continuation; missing routes/state and in-run changes refuse | A selected Claude thinking mode completes multiple tool rounds; one session continues A→B→A with restart, retaining canonical facts without resurrecting old thinking state |
| 5 | Policy permits the question before interaction admission. Durable replay re-presents the same question; ephemeral interaction state ends with its runtime. Both hold no provider call while waiting. Answer/expiry differ; cancellation stays terminal. Test the explicit ephemeral answer path, absent/failed responder, deadlines, duplicate/late answers and cleanup. Answers grant nothing | A real model asks and uses an answer through the durable command and the ephemeral host-answer interface |
| 6 | The command drives the public session contract only. Steer, follow-up, question and interrupt paths each have a test over a pseudo-terminal and piped input, including state/ordering differences. Configuration tests cover explicit file selection, flag precedence, prompt files, invalid values and resume semantics | Attended conversation of at least three prompts using the documented flags and config file |
| 7 | Saved roles resolve to exact provider/model/instruction settings and separate credential references without widening policy. Routing and custody have conformance/canary coverage. The child has its own identity, bounds and read-only tools. Recovery uses recorded settings; manager loss stops unfinished helpers, preserving completed results; cancel/launch races and observational receipt lookup have fault tests; nesting refuses; failures preserve uncertainty | A real parent delegates investigation and review sequentially using saved roles, including a helper on a different provider |
| 8 | The task set and its acceptance checks are fixtures in the repository | Every task completes against the real provider. Transcripts and workspace diffs are retained outside the repository with digests |
| 9 | Runbook commands use the same fixture setup and objective checks as outcome 8. Tests cover failure cases that require controlled injection | A named operator follows the documented workflow on the tested SHA; record steps, observations, failures and evidence references |

Each coding task states its starting workspace, its prompt and a check that
decides pass or fail without reading the model's prose, such as a test suite
that must pass. A task that passes only on retry is a failure to explain.

Use the existing CLI coding-task fixture and release lane as the starting
point: `apps/loopex_cli/test/coding_task_test.exs` and
`scripts/check-release.sh`. Extend the existing interaction, context,
provider, executor and protocol suites at the changed boundaries. Select
unattended pre-merge release lanes under the verification guide when those
boundaries change. The closure matrix remains the repository's two checks,
with retained exact-SHA evidence; operator validation does not replace them.

Outcome 6's fast proof includes schema/precedence, each conversation state and
trace enable/disable, limits, bounded stderr, dropped counts and redaction.
Outcome 7 includes durable role-catalog recovery, allowance reservation/settlement,
known overshoot, unknown usage and no restart reset. First protocol integration
adds the negotiated schema and independent Node fixtures for every changed
command/event/snapshot. No outcome is proved by tests of only the happy path.

The proposed fixed task catalog is:

| Task | Starting fixture and input | Objective completion check |
| --- | --- | --- |
| Repair | A small repository with a seeded boundary bug and a failing test; diagnose, then fix using a second prompt referring to the diagnosis | The original failing test and regression suite pass; the patch stays within named paths and leaves checks intact |
| Bounded feature | A repository with a missing option and an ambiguous default; ask the operator, implement the chosen behavior, then run tests | Tests prove the chosen default and explicit alternative, with no unrelated changes |
| Investigation and review | A repository with a known call chain and a prepared defect; delegate search, then use a separately instructed read-only review example | Results identify the fixture's known locations and defect; workspace bytes are unchanged by the helper |
| Long conversation | A bounded fixture with early facts, several dependent steps and enough context to trigger compaction | Later assertions still match the early facts and resulting files; checkpoint, raw history and restart observations agree |
| External repository | Maintainer-selected repository and pinned starting commit, a bounded real task and disposable checkout; target and task pending selection | Agreed repository tests and task-specific assertions pass; retained diff obeys the allowed-path/change constraints |

Implement the fixed catalog in `test/fixtures/m7/manifest.json` with fixture
roots beneath `test/fixtures/m7/`. The manifest pins initial file digests, literal
prompts, exact accepted output fields/values, allowed diffs, invocation and
oracle digests. Implement these concrete oracles before the first real run:

- `repair`: `Ledger.total([]) == 0`, positive and negative entries sum exactly;
  only the named implementation path may change, and oracle files stay fixed.
- `feature`: a row encoder's nil behavior is explicitly chosen through
  `loopex.ask`; external tests assert the chosen `empty` or `literal_null` default
  and both explicit modes. The retained interaction answer selects the expected
  oracle branch. An unasked question fails this task.
- `review`: the pinned fixture contains one duplicated fee in its call chain.
  Require a bounded structured finding with the exact manifest file, function,
  defect code and call-chain sequence. Assert every helper workspace digest is
  unchanged. A prose claim of correctness is insufficient.
- `long`: establish manifest facts `release_prefix=amber` and `batch_size=3`,
  then require the final generated values and files to match after automatic
  compaction, explicit compaction and restart. Inspect checkpoint boundaries
  and raw facts independently of the model answer.

Fixed prompts explicitly request the question/helper calls needed by their
scenario. Inspect committed call identities and outcomes; a model that ignores
the required call fails that attempt. Do not retry until a favorable response.
These are specifications to implement, not fixtures or successful proof today.

The maintainer selected agent-run fixture tests and independent harness reruns.
Add a fixture-host policy adapter supplied by trusted validation-harness
composition to the real CLI path, with exact approved invocations and a pinned
manifest. This bypasses no policy decision and exposes no new production config
profile or caller-supplied policy module. Record the effective policy/manifest
identity; production config retains its closed profile registry. Before the attempt, pin command bytes, executable/runner
path and digest, cwd, permitted inputs and scrubbed environment. The trusted
runner lives outside the writable task tree and uses absolute toolchain paths
or its own fixed PATH. Validate prerequisites under the executor's scrubbed
environment, not an ambient shell. Deny alternate shell expressions/arguments,
commands and directories; do not expand the ordinary shell-allowlist or use
allow-all. Keep acceptance oracles outside the agent-writable workspace. Task
edits or added development tests cannot weaken them. Require a successful
committed agent test result and an independent run of the same pinned oracle,
retaining both outputs and checking allowed diffs. Reverify runner/oracle
digests before and after the independent rerun; location outside the task tree
alone is not proof that bytes stayed unchanged.

The maintainer selected the fixture set plus an external repository task on
2026-09-30. Retain the external source URL or checkout provenance, exact base
SHA, prerequisite versions, initial worktree state, task prompt, allowed
paths, test commands and objective success criteria. Keep the user's original
checkout untouched. The task's changes remain evidence in the disposable
checkout; no external merge, push or publication is implied. Establish the
repository and task during testing, as the maintainer explicitly directed on
2026-09-30. Their selection is not a plan-acceptance prerequisite. Pin the
starting commit, task and pass criteria before the demonstration attempt;
retain failures without changing the task to turn an observed failure into
a pass.

<a id="technical-plan-operator-validation"></a>
### Scenario steps and evidence

Concept: [Operator validation](M7.md#concept-plan-operator-validation).

Deliver an indexed runbook under `docs/operator/` with copyable commands and
expected output for the implemented command grammar. The following steps are
the scenario specification. M7 syntax is specified in ADR 0049 but is not implemented yet; these steps
are validation requirements, not a claim that the commands run today. Fill in exact commands alongside each feature and
verify them against the real command before closure.

Every scenario begins from a named build and disposable workspace/state root.
It states the selected provider/model, declared time/token/turn bounds,
prerequisites, expected observations, objective checks, evidence destination,
failure interpretation and cleanup. Use existing M6 build, `ask`, `run`,
`resume` and daemon instructions for baseline steps. Distinguish foreground
process loss from a daemon client's detach.

#### V1. Establish the baseline

1. Record the source SHA, toolchain and model identity, and build the command.
2. Create the fixture workspace and separate temporary Loopex state root.
3. Run a read-only one-shot request and a durable request through documented
   existing commands.
4. Inspect the rendered terminal outcome and the workspace check. A legacy
   `run` or `resume` exit status of zero proves rendering, not task success.
5. Retain output and the fixture identity before continuing.

#### V2. Repair across prompts and restart

1. Open the repair fixture and request a diagnosis without an edit.
2. Ask for the fix by referring to the earlier diagnosis without repeating it.
3. Have the agent run the explicitly approved test command, then rerun the
   pinned acceptance oracle independently. Require both results and allowed-diff
   checks to pass. Execute these three prompts through a pipe with `/wait`
   barriers; interactive use is covered by V3–V5.
4. Close and reopen the settled session using its recorded identity.
5. Ask about the original decision and verify continuity against retained
   history and the resulting patch.

#### V3. Admit instructions and specialize work

1. Prepare a distinctive benign project instruction and an explicit review skill.
2. Inspect and admit their exact bytes, then perform the fixture task.
3. Repeat from a fresh fixture with the resource declined; inspect admitted
   context and resulting behavior.
4. Change the resource, admit its new identity, and verify the receipt changes.
5. Ask for an action denied by policy and verify that admitted instructions
   and the review role cannot authorize it.

#### V4. Steer and queue a follow-up

1. Start a task with a documented opportunity to steer before its next turn.
2. Steer the active objective and observe its admission/disposition.
3. Queue a follow-up while the run remains active.
4. Observe that the follow-up becomes a separate run with prior context.
5. Exercise late steering and confirm that it is explicitly unapplied when
   it misses the applicable boundary.

#### V5. Ask, answer and recover a question

1. Start the ambiguous feature task and observe the model's question.
2. Answer its actual interaction ID, then verify the selected behavior with
   agent-run and independent fixture tests.
3. In the separate pinned restart case, start the question-producing task and
   leave its question unanswered. Cause controlled process loss before expiry,
   reopen, verify the same pending identity, then answer and finish. This is a
   prescribed recovery case, not a retry of a failed attempt. Normal `/quit`,
   EOF and orderly termination cancel it and cannot prove this recovery path.
4. Exercise `/decline ID`, expiry, denied presentation and cancellation using documented
   fixture cases; inspect their distinct results.
5. Verify that an answer requesting more authority cannot bypass the next
   policy decision. Provider inactivity while waiting is proved by tests.
6. Run the equivalent ambiguous task through one ephemeral call with a
   configured host answer path. Supply the answer and verify the result.
   Demonstrate absent responder and cancellation behavior without claiming
   restart recovery; the interaction disappears with that runtime.

#### V6. Continue after compaction

1. Use the long-conversation fixture and a documented small context budget.
2. Establish an early fact, then continue until automatic compaction occurs.
3. Verify the visible checkpoint and ask about the earlier work.
4. Explicitly compact a settled session and inspect retained raw history.
5. Reopen the session and verify the same continuation. Atomic checkpoint
   commits and ambiguous provider attempts use controlled fault tests.

#### V7. Change provider, model and reasoning

1. Complete a run and record its model and reasoning configuration.
2. Select a supported model on provider B through its separate credential
   reference and submit a follow-up referring to work from provider A.
3. Select a pinned supported Claude thinking mode and run the fixed multi-round
   tool fixture. Record its admitted reply/thinking limits, private-state sizes
   and objective outgoing-block equality result without printing private blocks.
   Reopen the settled session and confirm configuration and canonical history.
   The next run starts a new exchange; automated fault cuts cover open-exchange
   restart and exact replay.
4. Switch back to provider A and verify continuity with the fixture's facts
   and earlier tool results.
5. Request an unsupported level or an in-run change and verify refusal
   before a new provider dispatch. Exercise a missing provider binding and
   verify refusal without fallback. V8 proves the separate parent/child workflow.
6. Automated cases force capsule and complete-record limits, missing/corrupt
   state, conflicting reply/thinking limits and compaction during an open
   exchange. Verify named refusal without dropped blocks, enlarged limits or
   extra provider calls. After settlement, a new prompt can compact canonical
   history. Inspect canary results for public/progress/trace/artifact exclusion.

#### V8. Delegate bounded investigation and review

1. Save investigation and review roles in the explicit config file with
   instructions and supported exact models, then enable explicitly bounded read-only
   helpers. Record provider A for the parent and provider B for the review role.
2. Ask the parent to delegate the fixture's repository investigation using
   the configured role.
3. Inspect the separate child identity, transcript, outcome and usage, then
   verify that the parent uses its findings.
4. Repeat with the saved review role on provider B and verify its
   selected provider/model, the known finding and unchanged workspace.
5. Exercise child failure, bound exhaustion and parent cancellation. Observe
   truthful parent settlement; nested delegation and question tools refuse.
   Deduplication and reconciliation after crashes are automated proof. Crash
   after child creation but before prompt, stop the parent while the manager
   is down, then recover: no prompt is submitted and no provider work starts.
   An already running child is aborted or reported uncertain; a completed result
   can be recovered without reopening its parent.
6. Exhaust a small delegation allowance across serial children; verify that
   another child refuses while the parent's remaining budget stays distinct.
   Inspect parent, helper and combined usage, then restart and verify no reset.
7. Reject an unknown/disabled role. Edit a role file, reopen the parent and
   verify its retained catalog still governs already admitted work.

#### V9. Refuse, interrupt and recover

1. Trigger a policy-denied effect and verify no effect occurred.
2. Interrupt a foreground task and inspect its cancellation/cleanup result.
3. Recover a disposable durable session after controlled process loss and
   inspect the committed outcome before submitting more work.
4. Detach a daemon client, reattach and verify that client absence alone did
   not cancel the daemon-owned run.
5. When recovery reports an unknown effect, preserve the root for inspection.
   Do not demonstrate recovery by blindly repeating the request.

#### V10. Record the coding-task result and clean up

1. Run the repeatable fixtures from their pinned initial content and prompts.
   Choose the external repository/task during testing; record base SHA, allowed
   paths and objective checks before the attempt. Create its disposable checkout,
   execute the task and retain the original results and diff.
2. Run every objective acceptance command and inspect the allowed diff.
3. Record elapsed duration, usage, largest reply and terminal outcome for
   each task; retain failed attempts as well as successful ones.
4. Stop the fixture-owned processes and retain redacted logs, workspace diffs
   and checks outside the workspace and repository with SHA-256 digests.
5. Remove only disposable state whose process cleanup is confirmed. Preserve
   uncertain state and report the incomplete scenario.

#### V11. Enable and inspect tracing

1. Start a disposable foreground runtime with tracing enabled through the
   documented flag, then repeat with the explicit config file.
2. Run a small task and inspect the selected trace level, module scope,
   emitted/dropped counts and redacted entries.
3. Override a file-enabled trace with the disable flag and verify the
   effective configuration. Reject invalid options and excessive limits.
4. Repeat through existing `ask --output json` with trace startup flags and
   confirm diagnostics do not enter the result stream. Chat remains text-only. Use automated canaries to prove payload redaction and
   runtime isolation; operators need not inspect real credentials.
5. Finish or interrupt the host and verify trace cleanup. Document the
   distinct daemon-startup procedure without adding remote trace authority.

#### V12. Resolve explicit configuration

1. Validate a complete explicit file and inspect effective values/origins without
   resolving credentials. Start chat with file values only.
2. Override model/reasoning, limits, prompt files and trace settings through flags;
   inspect the committed settings and staged instruction digest.
3. Refuse duplicate/unknown JSON members, bad paths, malformed values and missing
   mandatory run/delegation limits before provider dispatch.
4. Edit defaults and role files, then resume a settled session. Verify committed
   configuration and role snapshots persist. Apply a permitted explicit
   `/configure` change and verify it affects only the next run.
5. Refuse in-flight changes and immutable tool/catalog changes. Confirm legacy
   one-shot defaults and unattended behavior remain unchanged.

#### V13. Upgrade and supported rollback

1. Record the retained M6 artifact, source, toolchain and digest. Create settled
   and unresolved M6 roots; stop their owners and retain complete pre-upgrade
   copies with manifests outside the test roots.
2. Open copies with M7; verify unchanged staged bytes and truthful settled/unknown
   recovery. No missing result authorizes blind provider/effect redispatch.
3. Run the exact M6 reader only on disposable copies of new roots and record its
   actual behavior. A reducer rejection does not prove refusal before root mutation.
4. Prevent the old binary from opening the live upgraded root. Restore its
   pre-upgrade copy into a separate empty root.
5. Verify complete manifest equality and run the pinned baseline using the
   matching M6 artifact. Root contents and observable baseline must agree.
6. Retain upgrade, old-reader and restore outputs with identities/digests; clean
   only confirmed disposable state. Uncertain state remains available for review.

This fixture procedure uses quiescent filesystem copies, not future M8 backup
commands. Restoring session state does not undo external workspace effects; pin
or separately restore the disposable workspace baseline for the comparison. V13 maps to outcomes 1–7 and the compatibility contract.

The evidence record includes the tested SHA, fixture digests, toolchain,
provider/model identifiers, prompts and operator answers, session/run/child
identities, complete redacted output, expected versus observed results,
workspace diff, acceptance-check output, measured durations and usage.
Reference the operator run from the closure evidence page. Reuse the current
release runner and redaction path. Record who attended; an automated answer
fixture cannot be described as a person validating the workflow.

The mandatory attended subset is fixed here; the runbook may clarify commands
but cannot reduce it without maintainer disposition:

| Block | Mandatory steps |
| --- | --- |
| Baseline, config and trace | V1.1–5, V12.1–2, V11.1–2 |
| Piped repair, tests and restart | V2.1–5 |
| Interactive instructions, steer and follow-up | V3.1–2, V4.1–4 |
| Human answer, question restart and ephemeral answer | V5.1–3, V5.6 positive path |
| Compaction and model changes | V6.1–5, V7.1–4 |
| Two saved read-only roles on distinct providers | V8.1–4, including separate/combined usage |
| Denial, interrupt and trace cleanup | V9.1–2, V11.5 |
| External task and retained results | V10.1–5 |
| Backup/restore baseline | V13.1, V13.4–6 |

Every required step names the operator, tested SHA, expected/actual result,
objective assertion and retained evidence. All remaining steps, including positive paths,
map to automated evidence, including V8.5–7 and V5.6 responder negatives.
Missing/unavailable evidence, unexpected refusal, failed independent rerun or
uncertain cleanup blocks closure. Preserve the repository candidate procedure:
Proved rows assert completed implementation and name proof obligations while
exact-candidate run/review scaffold slots remain Pending until those operations
produce results. An observed defect cannot be hidden behind that administrative
allowance or a Proved label.

Create and index `docs/evidence/M7-closure-runs.md` in the implementation
candidate before its closure matrix. It contains Pending slots for every
outcome, attended step, full run output/digest, schema/vector manifest,
provider/model identities, backup/restore manifests, exact M6 artifact,
security review, independent review and documentation checklist. Extend the
existing release runner, selectors, wrapper/redaction tests and the existing
PTY helper for the changed chat workflow. The current runner's fixed eleven
cases and one credential are implementation work, not evidence that new lanes
already run. Required new selectors cover coding tasks, piped/attended chat,
thinking/tool continuation, A→B→A, parent A/helper B and M7 upgrade/rollback. Credentialed lanes declare
separate A/B references and redact all selected values; other lanes require no
new credentials. Preserve all existing required lanes and failure honesty.

<a id="technical-plan-acceptance-issues"></a>
### Internal review disposition and audit targets

Concept: [Design decisions](M7.md#concept-plan-decisions).

The first internal implementation-readiness review corrected the following
proposal contradictions. The [external round 1 assessment](../evidence/M7-external-review-1.md)
then identified additional gaps. This revision records their repairs, with the
selected bounded thinking continuation and stop-only helper recovery included.
The [follow-up record](../evidence/M7-continuation-review.md) binds their review.
Fresh external audit remains outstanding. This is review of planned contracts, not product evidence or
formal independent acceptance review.

| Finding | Governing repair and implementation witness |
| --- | --- |
| Full-lineage joins could cross runs | ADR 0041 keys results by run/turn/call and tests repeated provider call IDs |
| Admission and byte-limit claims conflicted with ADR 0017 | ADR 0041 retains staging failure and optional withholding; exact normalized record measurement stays at 65,536 bytes |
| Compaction was unbounded and unsafe after uncertain commits | ADR 0043 bounds episodes/input/output, retains attempts/checkpoints and fences ambiguity |
| Instruction updates/fallback lacked a durable contract | ADR 0042 uses ADR 0044's atomic settled configuration with exact bytes and strict ceiling |
| Provider changes omitted accepted amendments | ADRs 0044/0048 name ADR 0010/0034/0039 restrictions and preserve profile-specific custody |
| Questions conflated restart, cancellation and ephemeral lifetime | ADR 0045 defines producer/response branches, a bounded responder and terminal precedence |
| Helpers allowed writes and changed identity on retry | ADR 0046 fixes read-only scope, immutable catalogs, operation IDs, durable budget and recovery evidence |
| Larger defaults contradicted maintainer choice | ADR 0047 requires configured limits and retains current starting values |
| Config/CLI/tracing were unspecified | ADR 0049 supplies one closed schema and command contract; ADR 0037 becomes M8-only discovery |
| Successors promised unsupported downgrade | M8–M10 drafts and Proposed ADRs 0036–0038 distinguish container format, record capability and binary version |

Round 1 repairs add exact accepted-clause amendments, the proposed paired
vision change, bounded artifact projections/retrieval, preservation of the
existing ephemeral API, same-runtime session tool selection, parent catalog
binding, closed-until-bound routing, child defer refusal, input barriers and
pipe framing, protected credential names, actual dual-server schema coverage,
fixed attendance and a concrete rollback procedure. Core additions are limited
to mechanisms that must be owned by the serial session writer:

| Core mechanism | Why an edge alone cannot supply it |
| --- | --- |
| Retained lineage/excerpts and preparation facts | Staging/recovery must agree on committed context and its exact digest |
| Configuration/genesis and immutable tools/defer mode | Admission, recovery and dispatch must use the same durable selection |
| Private continuation envelope and settlement | Exact request replay and atomic reply/tool admission must agree on retained provider data; adapters interpret its content |
| Compaction state/checkpoints | Maintenance accounting, checkpoint transactions and staging are serial session truth |
| Model-question transitions | Answer/expiry/cancel must atomically settle the original call and release the durable interaction slot |
| Optional absolute deadline | A child owner must stop even while its host adapter is unavailable |

Roles, credentials, catalogs, allowances, helper routing, fixture policy and
terminal behavior stay at the edge. External audit should challenge these
repaired contracts and the outcome-to-proof mapping. Exact fixture paths/content/prompts and the external repository task are
implementation/testing deliverables, fixed before their demonstration attempts.
The external target remains deferred by the maintainer. No successful product
run, accepted ADR or completed milestone is asserted by this packet.

<a id="technical-plan-ownership"></a>
### Workstreams and Rejoin Order

Concept: [Workstreams](M7.md#concept-plan-workstreams).

| Phase | Work and rejoin condition |
| --- | --- |
| 0. Specify | Accept the proposed contracts; build the task fixtures and executable scenario commands from the fixed grammar. Accept prerequisite ADRs before dependent implementation |
| 1. First complete workflow | Reproduce lost cross-run history, then implement continuity and host instructions under one owner. Integrate a minimal conversational command and prove two prompts plus restart |
| 2. Long-lived work | Add compaction under the same projection/staging owner. Integrate model/reasoning configuration, private continuation and atomic reply settlement; prove frozen-prefix tool exchanges, maintenance thinking-off and canonical history after a change |
| 3. Operator control | Add model questions to the existing interaction lifecycle; complete conversation steering, answers, follow-up, interrupt and noninteractive behavior |
| 4. Bounded helper | Integrate the host adapter after outcomes 1, 2 and 4; prove identity, read-only policy, cancellation and recovery before role examples |
| 5. Acceptance evidence | Complete the coding-task set and operator runbook, measure defaults, reconcile documentation and retain the closure matrix and attended evidence on the exact candidate |

One integrator owns changes to the coordinator, state reducer and shared
protocol. Parallel work is limited to non-overlapping adapters, fixtures or
documentation after their contracts are settled, with a worktree per writer.
The early conversational slice is extended in place as later capabilities
join; it must not acquire a second loop or durable state owner.

The integration owner also owns the source joins hidden by the earlier packet:
configuration normalization and session genesis/migration; runtime-to-session
tool selection; executor router binding before recovery dispatch; parent-binding
and catalog recovery; both protocol servers and payload-schema digests; the
CLI policy registry's fixture adapter; release selectors/credential redaction;
and the existing attended PTY driver. Each rejoins with conformance or negative
vectors before a real-provider demonstration. No separate implementation may
invent a second configuration, tool-generation or session-truth contract.

<a id="technical-plan-compatibility"></a>
### Compatibility, Migration and Rollback

Concept: [Rollout and compatibility](M7.md#concept-plan-rollout).

- The instruction envelope and the projection are covered by the staged
  request digest, so the change is visible in every retained request.
- New records require M7-aware readers. Old-reader behavior and supported
  rollback are established by the exact fixtures and procedure below.
- Already staged requests keep their exact bytes. Recovery obeys existing
  provider ambiguity rules, and later requests use the run's committed
  configuration; upgrade does not promise that an interrupted run completes.
- Compatibility inventory before the first decoder change: configuration/instruction
  records and v3 genesis, prepared tool-result references and artifact-read resolved
  arguments, immutable tool/policy selections, maintenance/compaction records,
  model_request.v2 continuation, bounded adapter/canonical reply v3 and
  model_attempt_settled_v2, estimator revision and private/public projection,
  question producer/text/decline records,
  host role/allowance ledger including monotonic stop records, generic absolute deadline ceiling on prompt/follow-up,
  request revision, events, snapshots and negotiated
  protocol generation. Each has versioned vectors and an explicit unsupported-reader
  behavior; bump private format metadata where needed before emitting new records.
- Upgrade fixtures include actual M6 roots with settled and unresolved model/tool
  operations. Preserve staged requests and resolve uncertainty without redispatch.
- Downgrade tests use the exact retained M6 binary on disposable copies. Do not
  claim that it recognizes a future marker or error. If it cannot safely refuse
  a new root, the supported procedure is to prevent that binary from opening the
  root and restore a quiescent pre-upgrade backup with the matching binary.
- A legacy root with no new records may reopen only if the exact fixture proves
  it. Normal M7 startup may already write new configuration; no broad backward-read
  promise follows from an unchanged storage container.

The old reference is the published `v0.3.0` source at
`187d6efa6a1cfda6fc48785bcaba916405b85c88`. Retain or build its exact executable
with source/toolchain/digest evidence before the fixture run. A later source-docs
commit is not a substitute for that artifact. Extend `scripts/rollback-lane.sh`
and its selectors to cover the M7 matrix without dropping its earlier proofs.
Quiescent backups include sessions, runtime control, artifacts, executor
receipts, private continuation/recovery state, catalogs and host ledgers; compare complete manifests after restoring
into an empty root. Old staged v1 requests and old tool-definition bytes remain
unchanged; new semantics have explicit versions. Pre-v2 genesis remains refused.

No installer, tag, publication or compatibility freeze is part of M7. A release
label is separately selected. Accepted historical plans and evidence remain
records of their own revisions.
