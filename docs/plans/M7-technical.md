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
| [ADR 0048](../adr/0048-host-provider-routing-and-credential-bindings.md#concept) | Outcomes 3, 4 and 7 provider routing and credential bindings |
| [ADR 0049](../adr/0049-explicit-host-configuration.md#concept) | Outcomes 6 and 7 explicit configuration, roles and command grammar |

Accepted decisions that constrain the work:

| Decision | Constraint on M7 |
| --- | --- |
| [ADR 0010](../adr/0010-provider-continuation-and-context-staging.md#concept) | Staged bytes are committed with intent and digest-bound. A prompt to a settled session projects the whole retained lineage; ADR 0041 amends tool-result projection, ADR 0042 system-text ownership, ADR 0043 raw-only projection/compaction deferral, and ADR 0044 session-fixed model/empty continuation |
| [ADR 0011](../adr/0011-session-input-algebra-and-streaming.md#concept) | Existing ordering remains; ADRs 0043/0044 add compact/configure, ADR 0044 qualifies continuation exclusion only for verified summary text in existing reasoning progress, and ADR 0046 adds the explicit deadline ceiling and versions authored-bound command identity |
| [ADR 0017](../adr/0017-durable-context-admission-budget.md#concept) | Exact record/depth/cardinality limits remain; ADRs 0041–0044 amend host defaults, system ceiling, compaction-before-failure, receipt source provenance, session configuration placement and charged continuation; ADR 0046 extends the closed prompt/follow-up bounds |
| [ADR 0013](../adr/0013-run-deadline-commitment-at-first-request-staging.md#concept) | Existing relative deadline remains; ADR 0046 explicitly permits an earlier committed absolute cutoff, including before first staging |
| [ADR 0016](../adr/0016-configured-cancellation-observation.md#concept) | ADR 0044 adds one shared v3 genesis; mandatory cleanup and known-version decoding remain |
| [ADR 0018](../adr/0018-provider-attempt-authority-and-recovery.md#concept) | ADR 0043 extends permits/settlement/accounting to maintenance; ADR 0044 versions the closed reply/settlement shapes for private continuation; two attempts per logical operation and no ambiguous redispatch remain |
| [ADR 0021](../adr/0021-compacted-provider-accounting-provenance.md#concept) | Its settlement v2 and validated accounting provenance remain readable; ADR 0044 introduces v3 and cannot promote an invalid continuation reply to reported usage |
| [ADR 0023](../adr/0023-experimental-public-session-protocol.md#concept) and [ADR 0032](../adr/0032-daemon-attachment-residency-and-replay.md#concept) | ADR 0044 replaces the served generation set and metadata-only digest with the coordinated M7 contracts below; exact negotiation, framing, session authority and connection lifecycle remain |
| [ADR 0009](../adr/0009-tool-executor-and-grant-contracts.md#concept) | ADR 0041 adds read ranges/resolved arguments, ADR 0045 interaction dispatch, ADR 0046 explicit per-create selection; exact generations, grants and reserved namespace remain |
| [ADR 0024](../adr/0024-durable-interaction-lifecycle-and-host-policy-authority.md#concept) | ADR 0045 adds model producer/text/decline; ADR 0046 adds immutable defer refusal; interactions grant nothing |
| [ADR 0025](../adr/0025-resource-packs-and-skill-admission.md#concept) | ADRs 0042–0044 use fresh receipt revision 4 for instruction/compaction provenance and continuation accounting; maintenance explicitly skips optional intake. Ordinary resource admission/costs and old v2/v3 validation remain |
| [ADR 0039](../adr/0039-ephemeral-embedded-profile.md#concept) | Credential audience/cleanup preserved; ADR 0043 adds explicit maintenance instructions and model at startup; ADR 0045 adds bounded one-call answers; ADR 0048 adds explicit provider references and amends durable single-source wording; ADR 0049 adds owner-managed trace startup |
| [ADR 0019](../adr/0019-host-owned-provider-protection.md#concept) | ADR 0048 amends only its sole credential source; durable isolation, cleanup and trusted-launch exclusions remain |
| [ADR 0034](../adr/0034-provider-credential-handoff-over-bootstrap-channel.md#concept) | Durable provider dispatch retains host-owned credential references and per-invocation custody; ADR 0048 narrowly amends its single-provider restriction |
| [ADR 0030](../adr/0030-observability-tracing-and-telemetry.md#concept) | Host-owned runtime tracing, bounded diagnostics and redaction remain unchanged when exposed through startup flags |

Vision sections that bind the work: what Loopex is not (§3.2), compaction
(§12.5), model identity and provider state (§13.4), the context pipeline
(§13.5) and the minimalism budgets (§23.4).

Proposed ADR 0037 governs installed discovery in M8, not this milestone.
Public protocol and generic bounds additions in ADRs 0043–0046 share one
coordinated M7 integration, with distinct negotiated contracts for both the
foreground and daemon servers. The selected policy refuses older negotiation;
it adds no dual-service compatibility layer. Never send
new payloads under an unchanged generation/digest. Inventory command inputs,
configuration/genesis, interaction variants, events, snapshots and bounds,
including authorization differences. The new digest includes canonical payload
schemas, not only method/record names and limits. Independent Node vectors
cover both servers and old/new-client combinations. Acceptance binds the
proposal contracts; source implementation and literal schema/vector digests are
verified at the first protocol integration before any new wire shape is exposed.

The source baseline has two different contracts: `LoopexProtocol.Session`
serves `loopex.experimental/1` through the foreground app-server, while
`LoopexProtocol.Session.V2` serves `loopex.experimental/2` through the daemon.
The latter already owns `/2`; it cannot be reused for M7 foreground semantics.
Both current digests cover metadata inventories and limits, not the payload
schemas. New contracts must digest the complete closed payload definitions.
M7 serves only `loopex.experimental/3` on the foreground server and only
`loopex.experimental/4` on the daemon. These distinct names preserve the
different attachment/controller contracts; `/2` is never repurposed. ADR 0044
owns this coordinated amendment to ADRs 0023/0032, with ADRs 0043/0045/0046
joining the same payload and snapshot revisions. Historical `/1` and `/2`
schemas, vectors and committed data keep their original meaning.

| Offered generations | M7 foreground | M7 daemon |
| --- | --- | --- |
| Only `/1`, `/2` or the retired `loopex.session.v1-experimental` name | `unsupported_generation` | `unsupported_generation` |
| Only `loopex.experimental/3` | Select `/3` | `unsupported_generation` |
| Only `loopex.experimental/4` | `unsupported_generation` | Select `/4` |
| Mixed list containing the server's new generation, with any old/wrong-server entries | Select its exact new generation regardless of the other entries' order | Select its exact new generation regardless of the other entries' order |

The table uses `/N` as shorthand only; wire offers and replies use complete
generation strings. No common generation produces the existing bounded,
request-correlated refusal and leaves that connection uninitialized without
a second negotiation attempt. Ordinary post-refusal frames cannot create,
attach, resume, mutate or obtain control of a session, or start work for that
connection. Preserve existing malformed-frame, pre-initialization and shutdown
rules; this does not claim that unrelated daemon sessions stop running.
After a well-formed unsupported offer, another initialize returns
`already_initialized`; ordinary frames return `not_initialized`. A malformed
initialize returns `invalid_request` without consuming that one valid negotiation
attempt. There is no new immediate server close: the foreground continues its
bounded loop until EOF/host failure; the daemon retains its original
accept-time initialization deadline and closes with EOF on expiry. Successful
daemon initialization still waits for registry/relay setup before replying or
processing pipelined session frames. Unknown initialize fields are checked
against the new closed schemas; do not claim the old foreground already did so.
There is no fallback to an older generation, host or binary on that connection.
Update both bundled Node clients and all reference-client protocol pins together.
They verify the selected generation and independently pinned schema digest
before session requests; a mismatch ends the client connection without replaying
a mutation under another contract. Their session-request entrypoints also refuse
locally before verified initialization or after refusal; server gating remains
mandatory against raw or nonconforming clients. Existing foreground attachment and daemon
writer-epoch rules still apply after successful negotiation.

| Member affected | Required M7 contract and owning proposal |
| --- | --- |
| `session.create` | Versioned session-option validation for resolved configuration, instructions and immutable selections under ADRs 0042/0044/0046. Remote input cannot supply provider capabilities, credential routes, host catalogs or registry modules. |
| New `session.configure` | Existing request/command correlation plus a nonempty closed configuration update containing only ADR 0044's mutable fields. Foreground attachment authority and daemon writer-epoch/controller authority apply before mutation. |
| New `session.compact` | Existing request/command correlation plus explicit maintenance `bounds` containing `max_attempts`, `deadline_ms`, `token_budget` under ADR 0043. Same authority as other mutations; admission/unknown/refusal are distinct from completion. |
| `session.prompt` | A closed optional `bounds` object accepts the existing limit overrides (`max_turns`, `token_budget`, `deadline_ms`) and ADR 0046's optional `deadline_at_ms`. Preserve prompt partial-override behavior: capture host defaults for omitted ordinary limits once at admission. Bind authored bounds in the new command identity and retain effective bounds on replay. |
| `session.follow_up` | Optional closed `bounds` accepts only `deadline_at_ms`. Retain that authored ceiling through queue promotion; omission supplies no inherited absolute ceiling. Ordinary turn/token/relative limits retain ADRs 0013/0017's inheritance from the active run. Reject attempts to override them; steer cannot supply bounds. |
| `session.respond_interaction` | Keep the correlated `interaction_id` and command identity. `answer` has exactly one branch: `{choice_id}`, `{text}` or `{disposition: declined}`. Text/decline are model-question-only under ADR 0045; policy-defer retains its choice branch. |
| Configuration records | `session.configured`, inspection and attachment snapshots use an explicit allowlist: committed configuration version, exact model/reasoning, effective reply/context/system limits and instruction version/digest. Exclude raw instruction bytes, model capability/provider mapping envelopes, host binding maps, credential references, capability handles and private native continuation. An unresolved legacy configuration is explicit, never a fabricated default. |
| Compaction records | Durable `context.compacted` identifies the checkpoint, covered range/integrity digest, owner-computed `source_excerpted` flag, exact summarizer model/thinking-off setting, usage and owning configuration/maintenance identity. Checkpoint snapshots and rendered summary provenance retain the flag, including inherited omissions. Active-maintenance inspection/snapshots expose captured model identity and bounds, excluding provider mappings, instruction bytes, permits, routes and private recovery records. `context.compaction_progress` remains transient. |
| Interaction records | Pending and terminal projections preserve producer, kind, stable choices, original run/turn/call identity, expiry and answer/decline/expiry disposition. Attach snapshot and replay agree at the same cursor, including a question already pending when attachment begins. |
| Run/bound records | Preserve the effective absolute deadline and ordinary bound/terminal outcome through committed run views, while keeping relative and absolute limits distinct. Encode new ordinary bound members as canonical positive decimal strings: `max_turns`/`token_budget` retain their current positive-integer domains, `deadline_ms` its positive uint64 domain. `deadline_at_ms` uses ADR 0046's positive JSON safe-integer domain. Apply the same conversion on output; never round through JavaScript numbers or silently impose uint64 on turns/tokens. |
| Tool-definition format | Version the interaction-class addition and zero artifact-budget exception under ADR 0045. Preserve old effect-definition bytes; new artifact-capable read/search generations keep their own exact version/digest. The tool-definition version is distinct from session-protocol generation. |

The integration owner updates the foreground `Mapping`, daemon `Request`,
`SocketConnection`, `LeaseOwner`, `AdmissionRelay` and `WireRecords` together.
All new daemon mutations join the controller checks and succession/capacity
inventory; merely adding a parser branch cannot bypass or omit lease fencing.
Retained command IDs and prior refusal/unknown facts keep their original meaning.
Version the attachment snapshot beyond current revision 2. It contains the
latest configuration, zero or one active maintenance view and zero or one open
interaction, within the existing bounded frame/record envelope. Terminal
question facts remain in events/replay; snapshots do not accumulate all prior
questions or configurations. Snapshot projection and transient progress must
not expose the private fields added for recovery. Existing `WireRecords`
payload pass-through is not a privacy filter: use explicit kind-specific public
projections at core or wire mapping, never serialize a retained configuration
or maintenance map wholesale. Bound their version/digest/identity fields and
text members in the literal schemas before implementation exposes them.
Observed turn/token terminal counters use canonical nonnegative decimal
strings, including exactly `0` for zero, without narrowing the core domain.
Canaries prove absence of private fields in both servers' events, inspection,
snapshots and progress, not merely the successful configured response.

ADRs 0011/0017 deliberately omit ordinary bound configuration from normalized
command identity, and current `SessionState.normalize_command/1` implements
that rule. ADR 0046 now proposes the explicit amendment: version new normalized
commands/digests to bind exact authored prompt bounds or the follow-up ceiling,
including omission. Parser plumbing alone cannot establish that behavior. Look up
a duplicate's retained fact before resolving defaults or the clock again;
effective bounds are captured once in its admission record. Preserve historical
normalized bytes, digests and duplicate behavior under their original version.
Vectors cover a changed bound under the same new command ID, an unchanged
authored retry after host defaults change, old-command replay, and follow-up
inheritance with only its own explicit absolute ceiling.

Extend `apps/loopex_protocol/priv/schema/` and `priv/vectors/`, their literal
schema/conformance tests, and both `clients/node/loopex-client.mjs` and
`clients/node/daemon-client.mjs`. The existing Node `vectors.mjs` checks frame
syntax; it does not prove method payloads, authority or live workflow semantics.
Keep that framing proof and add independent literal payload validation plus
facade-backed round trips for the new methods and records. Both independent
Node clients must assert independently retained expected generation/digest
pairs before any mutation;
the current foreground client merely stores the digest and the daemon client
does not validate it. Add mismatched-digest refusal vectors. Vectors cover unknown
members, mixed answer branches, stale writer epochs, duplicate command IDs,
absolute-deadline promotion, pending-text-question attachment, snapshot/replay
agreement and absence of private continuation. Exercise old-only, new-only and
mixed-generation offers against each server. Every outcome must follow the
table above, with no new payload under an old digest. Include repeated initialize
and post-refusal create/attach/resume/control/mutation attempts, asserting no
session work attributable to the refused connection. Exercise malformed versus
well-formed initialization, client digest mismatch, both mixed-offer orders,
daemon accept-time expiry and foreground continued refusal using real transport
paths; framing-only vectors cannot prove these behaviors. Preserve historical literal
schema/vector validation where retained; old-only offers to an M7 live server now
prove explicit refusal. Keep the pinned historical release/rollback lanes
unchanged and add the new-generation consumers to the M7 lanes.
The implementation updates the operator/developer protocol references, examples
and migration notes to show the new client/server pair and expected upgrade
diagnostic. Do not rewrite current-product documentation before that integration.

<a id="technical-plan-configuration"></a>
### Explicit configuration contract

Concept: [Explicit configuration](M7.md#concept-plan-configuration).

[ADR 0049](../adr/0049-explicit-host-configuration-technical.md#technical-adr-0049-decision)
is the single schema, precedence and grammar definition. It specifies explicit
JSON, exact provider:model selection, mandatory file run limits, saved roles,
relative-path rules, prompt files, explicit `maintenance.model` /
`--compaction-model`, effective value origins and trace controls.
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
with at most 2,048 encoded bytes per unsolicited executor-backed model-facing
result, except exact legacy inline content under ADR 0041's old-tool rule.
Explicit artifact reads request up to 4,096 raw bytes within an
8,192-byte complete encoded result, preserving exact next offsets and the
65,536-byte whole-request bound. Compaction uses those projections without
automatically fetching full objects. Model-question results preserve exact bounded answers in ordinary
projection and use its final preflight, including explicit irreducible refusal.
For maintenance source alone, ADR 0043 first seeks a complete prefix, then uses
marked serialized excerpts of the oldest eligible whole unit when necessary.
Original facts remain readable; a checkpoint's omission flag survives later
summaries. The protected tail and open thinking exchange cannot be excerpted.
The host explicitly selects the summarizer through ADR 0043; there is no inherited
or fallback model. Each episode captures its verified thinking-off mapping and
input ceiling derived from its own window, capped by the parent input ceiling.
Ordinary run configuration stays unchanged, including an always-on thinking
conversation model. Missing configuration refuses compaction before dispatch.
Measure the
complete final record, including both semantic messages
and canonical bytes. Irreducible content refuses explicitly.
The reference prompt target remains below 1,000 estimated tokens, including
question/helper definitions and role facts for demonstrated chat profiles.
Measure each actual profile. An explicit larger host ceiling does not itself
approve a reference-product target deviation.
Before integrating each demonstrated reference profile, retain complete
instruction/tool preimages, the exact resolved workspace, enabled-role facts
and catalog digest, and assert a system-class estimate strictly below 1,000
with the accepted estimator. Use useful complete schemas and new immutable
generation bytes for changed descriptions; no field removal or implicit budget
increase can satisfy this gate. Before each provider attempt, validate its final
staged request, including receipt revision 4 and applicable expanded-continuation
accounting, against all configured bounds and the 65,536-byte ceiling. The earlier
990-token prototype is a narrow arithmetic example, not this final-profile proof.

Trace flags map only to the existing runtime-scoped host API and ceilings.
Bounded pending stderr output, separate drop/delivery-uncertainty counts,
ADR 0030's unchanged best-effort diagnostic-sink mailbox, redaction, credential process
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
Helpers are serial per parent session across runs, including unfinished cleanup.
Independent parent sessions may run helpers concurrently, with separate allowances
and cancellation. ADR 0046 reconstructs occupied slots from retained operations;
no runtime-wide slot, waiting queue, nested or write-capable helper is included.

<a id="technical-plan-evidence"></a>
### Evidence Obligations and Mapping

Concept: [Outcomes](M7.md#concept-plan-outcomes).

Concept: [Scope and non-goals](M7.md#concept-plan-scope).

Concept: [How each outcome is verified](M7.md#concept-plan-verification).

| # | Fast check | Release check |
| --- | --- | --- |
| 1 | The second run's staged request contains the first run's prompt, assistant messages and tool results in committed order. The projection is rebuilt identically after owner succession and restart. Accounting for the new run starts at zero | The second prompt of a real session refers to the first |
| 2 | Staged bytes equal the host's composed block. The digest changes when the block changes. An oversize or malformed block is refused before dispatch. Project files stay in separate provenance classes. Core retains only ADR 0042's compatibility fallback | The default block drives a real task; record its cost with the active tools |
| 3 | The checkpoint records input range, summary, model identity, usage, integrity digest and inherited source-omission flag. Projection substitutes it and keeps the first later raw record verbatim. Raw records remain readable. Large prompts, arguments, group metadata and terminal input-only runs use deterministic marked source excerpts within exact source/request limits. Recovery reuses staged source, selects the last committed checkpoint, fences uncertain commits and never repeats an ambiguous summary attempt. Tool receipts and effect outcomes are unchanged by a summary | A real session passes its context limit and continues; the oversized-source case shows marked omissions and readable originals without claiming the model saw omitted detail |
| 4 | Run configuration commits provider/model and reasoning. Adapter conformance proves native thinking/block fidelity, frozen-prefix replay, original IDs inside the exchange, canonical conversion afterward, private-state exclusion and all size limits. Crash/commit_unknown cuts preserve atomic reply/continuation; missing routes/state and in-run changes refuse | A selected Claude thinking mode completes multiple tool rounds; one session continues A→B→A with restart, retaining canonical facts without resurrecting old thinking state |
| 5 | Policy permits the question before interaction admission. Durable replay re-presents the same question; ephemeral interaction state ends with its runtime. Both hold no provider call while waiting. Answer/expiry differ; cancellation stays terminal. Test the explicit ephemeral answer path, absent/failed responder, deadlines, duplicate/late answers and cleanup. Answers grant nothing | A real model asks and uses an answer through the durable command and the ephemeral host-answer interface |
| 6 | The command drives the public session contract only. Steer, follow-up, question and interrupt paths each have a test over a pseudo-terminal and piped input, including state/ordering differences. Configuration tests cover explicit file selection, flag precedence, prompt files, invalid values and resume semantics | Attended conversation of at least three prompts using the documented flags and config file |
| 7 | Saved roles resolve to exact provider/model/instruction settings and separate credential references without widening policy. Routing and custody have conformance/canary coverage. The child has its own identity, bounds and read-only tools. Recovery uses recorded settings; manager loss stops unfinished helpers, preserving completed results; cancel/launch races and observational receipt lookup have fault tests; nesting refuses; failures preserve uncertainty | A real parent delegates investigation and review sequentially using saved roles, including a helper on a different provider |
| 8 | The task set and its acceptance checks are fixtures in the repository | Every task completes against the real provider. Transcripts and workspace diffs are retained outside the repository with digests |
| 9 | Runbook commands use the same fixture setup and objective checks as outcome 8. Tests cover failure cases that require controlled injection | A named operator follows the documented workflow on the tested SHA; record steps, observations, failures and evidence references |

Each coding task states its starting workspace, its prompt and a check that
decides pass or fail without reading the model's prose, such as a test suite
that must pass. A task that passes only on retry is a failure to explain.

Outcome 4 includes ADR 0044's selected local-reference and initial-reserve
contract. Prove exact expansion against canonical reply/request values, full
expanded continuation accounting and both stored/expanded private-data caps.
Test initially fitting requests that require earlier compaction, target-aware
excerpt/optional admission, no-progress/exhaustion refusals and recovery of the
same preparation targets. The real multi-round case records its first request,
subsequent complete records and input estimates; a small initial request alone
does not prove useful continuation capacity. No fixed round count is guaranteed
for every admitted prefix.
The selected durable live-streaming path also proves provisional answer delivery,
bounded native assembly and exact final block reconstruction. Interruption and
owner loss cannot commit a partial answer, dispatch tools from deltas or retry
an ambiguous call. Buffered ephemeral delivery retains ADR 0039's transport.
Verified provider summaries use existing reasoning progress after native-event
classification. Positive display and separate private-data canaries prove that
permitted text can appear while signatures, redacted data and unverified thinking
cannot. The public schema stays unchanged; canonical history omits that progress.

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
A missed required model action is a failed real-task attempt and blocks that
outcome's proof and closure. Label its observed cause honestly, but a
model-nonconformance label does not turn the required task into a pass. A new
candidate requires a substantive correction supported by a causal diagnosis,
with prior failures retained and affected checks run under the normal rules;
a new SHA or prompt reroll alone does not authorize retrying into green. A
change to the task, required outcome or acceptance rule needs an explicit
maintainer disposition before another attempt. The administrative closure
commit cannot introduce that change. These are specifications to implement,
not fixtures or successful proof today.

**Case ownership.** Before the first provider attempt, the fixed manifest assigns
each prescribed real-provider case a stable case ID, one owning release lane
and its ordered prompts, actions and checks. One case execution may contain
several runs and prescribed process restarts. The runner allocates and retains
its attempt identity before dispatch; every session/run/child identity belongs
to that execution record. Multiple outcome or step references reuse that
record, not another model execution. The release selector union executes each
owning case once per invocation, including when both coding-task and attended
selectors need its evidence. A pre-merge selector cannot substitute unattended
execution for required attendance. Existing release cases remain required;
this mapping prevents duplicate dispatch of the newly shared M7 cases.

| Catalog task | Owning scenario steps; final collection is V10 |
| --- | --- |
| `repair` | V2.1–5, including the agent test and independent oracle rerun |
| `feature` | V5.1–2, including the actual-ID answer and both test results |
| `review` | V8.1–4, including investigation and the separately instructed review |
| `long` | V6.1–4 and the settled-reopen positive path in V6.6 |

V5.3's question restart, V5.6's ephemeral answer, V6.5's oversized source,
V6.6's injected faults and V6.7's separate summarizer-provider case are
distinct predeclared cases. They never replace a failed main case. Other
prescribed positives and negatives receive the same explicit ownership.
Each case starts from its pinned initial workspace/state or the exact retained
state of its prescribed predecessor; the manifest declares which. It cannot
silently reuse a workspace already repaired by another case. Independent
oracle reruns verify the existing task workspace without calling the model or
starting another task attempt. Repeated selection, missing evidence or failure
cannot allocate a replacement attempt to manufacture a pass; the failure and
candidate rules above still govern.

The maintainer selected agent-run fixture tests and independent harness reruns.
Add a fixture-host policy adapter supplied by trusted validation-harness
composition to the real CLI path, with exact approved invocations and a pinned
manifest. This bypasses no policy decision and exposes no new production config
profile or caller-supplied policy module. The planned trusted entry point is
`scripts/m7-fixture-chat.exs`: validate the ordinary explicit file and closed
policy profile first, then inject the fixed fixture policy through host
composition and invoke the same CLI conversation driver. Only the harness owns
this injection; neither a config field nor a model argument names a module.
Record the effective policy/manifest
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

The static-pipe variant treats an unexpected question as a recorded failed
scenario and exits through the ordinary cleanup path. It never answers a future
or guessed ID. A separate bidirectional-pipe case proves actual-ID answers and
declines. Neither path assumes the model can be forced never to ask.

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

1. Start the pinned task and wait for its controlled tool barrier. The trusted
   fixture holds that tool's completion until the operator has submitted the
   steer and follow-up. Document the barrier and its bounded failure path;
   operator timing against a fast provider is not the acceptance oracle.
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

1. Use the long-conversation fixture, a documented small context budget and an
   explicit `maintenance.model` or `--compaction-model`. Inspect the selected
   thinking-off summarizer and its admitted provider without reading credentials.
2. Establish an early fact, then continue until automatic compaction occurs.
   Inspect the fixture's automated range-read evidence for a source file of at
   least 16 KiB: full 4-KiB ranges where encoding fits, exact offsets through EOF,
   escaped/multibyte boundary cases and complete staged-request measurements.
   This reuses the owning fixture run; it adds no duplicate model attempt.
3. Verify the visible checkpoint and ask about the earlier work.
4. Explicitly compact a settled session and inspect retained raw history.
5. In the oversized-source fixture, make the documented large prompt or write
   group eligible as old history. Verify compaction progresses, displays source
   omissions and retains the complete original. Inspect the fixture's sentinel
   outside both excerpts through host history; do not ask the model to prove
   knowledge of bytes it was never shown. A later checkpoint retains the omission
   flag. Automated cases cover large metadata, input-only runs and size failures.
6. Reopen the settled long-conversation session and verify the same continuation
   as an attended positive path. A separate automated fault case
   changes/removes the startup summarizer option while an episode is admitted;
   verify that episode keeps its recorded model and later episodes use the new
   setting or refuse unconfigured. Atomic checkpoint commits, missing routes and
   ambiguous provider attempts use controlled fault tests.
7. Run the pinned case with an always-on thinking conversation model and a
   thinking-off summarizer on another admitted provider. Verify the summary,
   continued conversation and separate maintenance usage counted once in totals.
   No ordinary run changes model merely because compaction occurred.

#### V7. Change provider, model and reasoning

1. Complete a run and record its model and reasoning configuration.
2. Select a supported model on provider B through its separate credential
   reference and submit a follow-up referring to work from provider A.
3. Select a pinned supported Claude thinking mode and run the fixed multi-round
   tool fixture. Record its admitted reply/thinking limits, private-state sizes
   and objective outgoing-block equality result without printing private blocks.
   Record the initial reserve, complete request sizes and expanded input charges;
   storage savings do not count as lower provider input. An automated near-limit
   initial-history variant proves compaction leaves the reserve before dispatch.
   Observe live provisional answer text when the provider supplies it. Automated
   barriers prove progress precedes final settlement and tools wait for it;
   fault cases cover split events, limits and interrupted signatures/messages.
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
   history. In a verified summary mode, distinguish reasoning progress from answer
   text and confirm it is absent from reopened canonical history. Inspect separate
   permitted-summary and private-data canaries across public/progress/trace/
   artifact output. Automated cases also prove suppression for an unverified or
   empty summary, unchanged private replay and the buffered ephemeral result.

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

1. Collect the authoritative fixture attempts from their owning scenarios;
   do not execute them again for this step or to fill a missing evidence slot.
   Choose the external repository/task during testing; record base SHA, allowed
   paths and objective checks before the attempt. Create its disposable checkout,
   execute the task and retain the original results and diff.
2. Verify the collected objective check results and allowed diffs against the
   fixed manifest. Run the external task's pinned acceptance commands and
   inspect its allowed diff as part of that task's execution.
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
   Automated prepared-recovery subcases start with unfinished work, change or
   omit the file's cleanup period, and omit, match or conflict with an explicit
   cleanup flag. Assert the retained value and observation bounds. A conflict
   safely abandons the prepared owner before refusal; failed abandonment stays
   unconfirmed. Both conflict paths dispatch no recovered work.
5. Refuse in-flight changes and immutable tool/catalog changes. Confirm legacy
   one-shot defaults and unattended behavior remain unchanged.

#### V13. Upgrade and supported rollback

Use the updated client/server pair for M7. Inspect the retained negotiation
cases first: old-only offers receive `unsupported_generation`, the correct new
offer succeeds, the wrong server's generation refuses, and a digest mismatch
stops the client before session requests. These wire checks are separate from
the old-root reader and frozen-tool checks below.

1. Record the retained M6 artifact, source, toolchain and digest. Create settled
   and unresolved M6 roots; stop their owners and retain complete pre-upgrade
   copies with manifests outside the test roots.
2. Open copies with M7; verify unchanged staged bytes and truthful settled/unknown
   recovery. Inspect the old-tool compatibility cases: a saved inline result above
   2 KiB remains exact when the full request fits, without new artifact preparation
   or tool capabilities; an irreducible overflow refuses. Include a later receipt
   from the same old generation and preserved truncation/spill notices. No missing
   result authorizes blind provider/effect redispatch.
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
| Compaction and model changes | V6.1–5, V6.6 settled-reopen positive path, V7.1–4 |
| Two saved read-only roles on distinct providers | V8.1–4, including separate/combined usage |
| Denial, interrupt and trace cleanup | V9.1–2, V11.5 |
| External task and retained results | V10.1–5 |
| Backup/restore baseline | V13.1, V13.4–6 |

Every required step names the operator as `Maintainer` or
`Delegate: <recorded identity>`, tested SHA, expected/actual result, objective
assertion and retained evidence. Implement `operator_step_evidence` in the
fixed fixture manifest before demonstrations. It lists every V1–V13 step and
subcase, its attended/automated classification, exact lane/test ID, oracle and
evidence slot. Each provider-backed step/subcase names its owning case ID and
retained execution record, including the actual attempt and session/run
identities after execution. Several steps may reference one execution; each
step/subcase still has exactly one coverage entry. Validate classifications
against the mandatory attended table, splitting positive and automated fault
subcases even when they share a numbered step. Missing or duplicate coverage,
conflicting attempt references or a reduced attended classification fails
validation; a prose promise that all other steps are automated is insufficient.
This includes V8.5–7 and
V5.4–5 fault cuts and V5.6 responder negatives. V5.6's attended positive path
uses the checked-in `scripts/m7-ephemeral-question-demo.exs` host, which invokes
the public ephemeral API and displays the real question for the operator to
answer. Its callback submits through the ordinary answer path; no canned
answer may stand in for attendance.
Missing/unavailable evidence, unexpected refusal, failed independent rerun or
uncertain cleanup blocks closure. Preserve the repository candidate procedure:
Proved rows assert completed implementation and name proof obligations while
exact-candidate run/review scaffold slots remain Pending until those operations
produce results. An observed defect cannot be hidden behind that administrative
allowance or a Proved label.

Create and index `docs/evidence/M7-closure-runs.md` in the implementation
candidate before its closure matrix. Its predeclared Pending slots cover:

- candidate/source identity, tested implementation SHA and full toolchain pins;
- floor/current-pair run identities, outcomes, measured durations and complete
  retained-output references/digests, including reused CI evidence where allowed;
- the tested fresh-source archive manifest's exact retained bytes/reference and
  digest, under the existing archive-extraction procedure;
- every outcome and operator step/subcase, operator identity, attended-answer
  authority and the manifest's exact lane/test-to-step mapping;
- fixture manifest, prompt, runner and immutable oracle digests; every task's
  objective result and duration/turn/token/maximum-reply measurements;
- meaningful per-profile instruction/tool/environment/role cost measurements;
- exact provider/model/mode identities and credential-free routing metadata;
- both protocol schema/vector manifests and independent Node consumer results;
- upgrade/old-reader/restore lane identities, complete manifests and exact M6
  artifact identity, plus the external task's pre-attempt pin described below;
- security, independent and documentation review identities and conclusions.

The external repository/task remains selected during testing. Before any
attempt, write its complete pinned specification to an immutable retained
record with a SHA-256 digest and UTC timestamp. The runner requires that record,
records its digest at startup and checks its timestamp precedes the attempt.
Reference it from the predeclared evidence slot; filling a slot afterward alone
does not prove prior selection. Changing the pin creates a new recorded attempt
and cannot reclassify the old result. A committed candidate fixture may instead
supply that pin when selection occurs before candidate commitment. Extend the
existing release runner, selectors, wrapper/redaction tests and the existing
PTY helper for the changed chat workflow. The current runner's fixed eleven
cases and one credential are implementation work, not evidence that new lanes
already run. Required new selectors cover coding tasks, piped/attended chat,
thinking/tool continuation, A→B→A, conversation A/summarizer B, parent A/helper B
and M7 upgrade/rollback. Credentialed lanes declare
separate A/B references and redact all selected values; other lanes require no
new credentials. Preserve all existing required lanes and failure honesty.
Both A and B are admitted hosted credentialed routes for the durable examples;
M7 adds no durable local-provider support. Pin their exact models, reasoning
mappings and selected credential variable names before the attempt. The runner
passes that complete selected-name set to its redactor and PTY driver and
self-tests with every canary, including non-default names. Redaction cannot
remain a fixed four-name list. The new selectors are required in the full
closure release matrix; `--only` selects pre-merge evidence, not an exemption
from closure. The compaction lane pins an always-on conversation model and an
explicit thinking-off summarizer, including their exact mappings. A switching
model needs no thinking-off capability merely because it is provider B; the
configured summarizer must have it. Switching alone proves no compaction capability.
ADR 0044's initial Claude matrix pins `anthropic:claude-haiku-4-5-20251001`
for manual/default and thinking-off maintenance cases, and
`anthropic:claude-fable-5-1` for the always-on adaptive conversation case.
Their exact outgoing mode, display and reply-limit vectors precede integration;
catalog presence alone proves no support. The release manifest retains these
mapping/renderer revisions with each selected case. This does not choose the
separate hosted provider B or replace its required pre-attempt identity pin.

<a id="technical-plan-acceptance-issues"></a>
### Internal review disposition and audit targets

Concept: [Design decisions](M7.md#concept-plan-decisions).

The first internal implementation-readiness review corrected the following
proposal contradictions. The [external round 1 assessment](../evidence/M7-external-review-1.md)
then identified additional gaps. This revision records their repairs, with the
selected bounded thinking continuation and stop-only helper recovery included.
The [follow-up record](../evidence/M7-continuation-review.md) binds their review.
The [round 2 disposition](../evidence/M7-round-2-disposition.md) tracks each
subsequent finding, measured limits, repairs and pending choices. It explicitly
withholds a new readiness/handoff claim until those choices and our own complete
adversarial review are resolved.
The [round 2 assessment](../evidence/M7-external-review-2.md)
then rejected candidate `10749d08` for additional feasibility and closure gaps.
Its claims are under source-backed review; repairs and a fresh internal
adversarial pass precede the next external handoff. This is review of planned contracts, not product evidence or
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
| Closed reasoning level in configuration | Every host, configure command and recovered run must agree on one bounded durable setting; only adapters map that setting to provider-specific options |
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
trusted fixture-chat wrapper and composition policy injection, preserving the
CLI's closed production policy registry; release selectors/credential redaction;
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
  runtime/composition maintenance-instruction/model options and per-episode capture,
  model_request.v2 local-reference continuation and its generic expansion rule,
  captured thinking-headroom trigger/targets, bounded adapter/canonical reply v3 and
  model_attempt_settled_v3 preserving ADR 0021's v2/accounting provenance,
  estimator revision and private/public projection,
  question producer/text/decline records,
  host role/allowance ledger including monotonic stop records, generic absolute deadline ceiling on prompt/follow-up,
  request and normalized-command revisions, events, snapshots and negotiated
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
Keep the v0.2.0↔v0.3.0 fixture pair pinned to those exact historical artifacts
and its original assertions. Add a distinct v0.3.0↔M7 pair: M6-to-M7 recovery
must preserve staged truth; M7-to-M6 new-record cases expect safe refusal or
the isolated backup-restore procedure, never successful decoding of v3 genesis
by M6. Do not silently retarget an old positive-read vector to M7 and invert
its expected result. The operator first stops all owners and removes the old
binary's access to the live upgraded root through their launch procedure;
this is a runbook precondition, not a new store marker claimed to fence M6.
This fixture and runbook procedure does not implement M8's backup commands.
Quiescent backups include sessions, runtime control, artifacts, executor
receipts, private continuation/recovery state, catalogs and host ledgers; compare complete manifests after restoring
into an empty root. Old staged v1 requests and old tool-definition bytes remain
unchanged; new semantics have explicit versions. Pre-v2 genesis remains refused.

No installer, tag, publication or compatibility freeze is part of M7. A release
label is separately selected. Accepted historical plans and evidence remain
records of their own revisions.
