<a id="technical-depth"></a>
## Technical depth

Concept: [M7 coding-agent proof](M7.md#concept).


The [2026-10-02 maintainer override](../developer/agent-context-map.md#disposition-pre1-current-contract-2026-10-02)
supersedes this plan's older-format/client compatibility, upgrade and
cross-version rollback obligations. Before 1.0, remove superseded code and keep
only current contracts. Current-format restart/replay, effect uncertainty,
authority, cleanup and backup/restore remain acceptance obligations. Retired
checklist rows retain their original identities and are not counted as passes.

<a id="technical-plan-prerequisites"></a>
### Prerequisites and Acceptance Points

Concept: [Purpose](M7.md#concept-plan-purpose).

Concept: [Design decisions](M7.md#concept-plan-decisions).

M6 is Closed. The maintainer accepted this plan, ADRs 0041–0049 and both labelled
vision amendments together at `2986150b878151524ecdd9bac5a9779e69e196b4` on
2026-09-30; the [acceptance disposition](../developer/agent-context-map.md#disposition-m7-acceptance-2026-09-30)
binds the exact coordinated packet. No partially accepted subset authorizes
implementation of these joins, regardless of abbreviated Depends-on headers.
The tool-budget amendment gates questions/helpers; section 13.4 gates the shared
configuration, projection and maintenance contracts. Both amendments are
prerequisites for the whole packet and its nine outcome/proof obligations. Both
amendments and all nine ADR pairs have been accepted together, so dependent M7
implementation may begin. The table identifies each decision's direct join, not separate
implementation authority:
| Decision | Accepted before |
| --- | --- |
| [ADR 0041](../adr/0041-session-lineage-projection-and-context-budget.md#concept) | Outcome 1's projection change |
| [ADR 0042](../adr/0042-host-composed-instructions.md#concept) | Outcomes 2 and 7's instruction option |
| [ADR 0043](../adr/0043-context-compaction-checkpoint.md#concept) | Outcome 3's checkpoint record |
| [ADR 0044](../adr/0044-run-model-and-reasoning-configuration.md#concept) | Outcome 4's configuration and bounded private thinking continuation, with versioned replies/settlements and charged context; outcome 7's resolved per-role model configuration |
| [ADR 0045](../adr/0045-model-originated-questions.md#concept) | Outcomes 5 and 6's tool class |
| [ADR 0046](../adr/0046-child-session-tool.md#concept) | Outcome 7's adapter |
| [ADR 0047](../adr/0047-reference-host-run-defaults.md#concept) | Outcome 6's mandatory configured bounds and outcome 8's measured baseline |
| [ADR 0048](../adr/0048-host-provider-routing-and-credential-bindings.md#concept) | Outcomes 3, 4 and 7 provider routing and credential bindings |
| [ADR 0049](../adr/0049-explicit-host-configuration.md#concept) | Outcomes 6 and 7 explicit configuration, roles and command grammar |

Accepted decisions that constrain the work:

| Decision | Constraint on M7 |
| --- | --- |
| [ADR 0010](../adr/0010-provider-continuation-and-context-staging.md#concept) | Staged bytes are committed with intent and digest-bound. A prompt to a settled session projects the whole retained lineage; ADR 0041 amends tool-result projection, ADR 0042 system-text ownership, ADR 0043 raw-only projection/compaction deferral and a turn unit per summary dispatch, and ADR 0044 session-fixed model/empty continuation |
| [ADR 0011](../adr/0011-session-input-algebra-and-streaming.md#concept) | Existing ordering remains; ADRs 0043/0044 add compact/configure, ADR 0044 qualifies continuation exclusion only for verified summary text in existing reasoning progress, and ADR 0043 amends standalone-maintenance admission/abort and completion, ADR 0046 adds the explicit deadline ceiling and versions authored-bound command identity |
| [ADR 0017](../adr/0017-durable-context-admission-budget.md#concept) | Exact record/depth/cardinality limits remain; ADRs 0041–0044 amend host defaults, system ceiling, compaction-before-failure, receipt source provenance, scoped refusal v2, session configuration placement and charged continuation; ADR 0043 also adds one leading episode-terminal row to the deadline-staging transaction of a run-owned episode, admits the `maintenance` stage in its validator and adds the maintenance-only `project_resource` disposition; ADR 0046 extends the closed prompt/follow-up bounds |
| [ADR 0013](../adr/0013-run-deadline-commitment-at-first-request-staging.md#concept) | ADR 0043 makes pre-first-ordinary maintenance staging commit the run deadline; the declared relative duration remains. ADR 0046 explicitly permits an earlier committed absolute cutoff, including before first staging |
| [ADR 0008](../adr/0008-owner-succession-recovery-and-runtime-placement.md#concept) | ADR 0046 adds bounded runtime-private intent/terminal and provenance reads with a read-only Store callback, a pure genesis resolver and an explicitly live-authorized exact-genesis create variant; observations grant no activation or mutation authority |
| [ADR 0016](../adr/0016-configured-cancellation-observation.md#concept) | ADR 0044 adds one shared v3 genesis; mandatory cleanup and known-version decoding remain; ADR 0046 adds exact-genesis live creation and retained-genesis lookup without current-default substitution; ADR 0049 requires abandonment for every post-preparation refusal |
| [ADR 0018](../adr/0018-provider-attempt-authority-and-recovery.md#concept) | ADR 0043 extends permits/settlement/accounting to maintenance through new maintenance record kinds and adds one leading episode-terminal row to the settlement-terminal transaction of a run-owned episode; ADR 0044 versions the closed reply/settlement shapes for completion/private continuation and makes all nine v2 Model-port keys mandatory; two attempts per logical operation and no ambiguous redispatch remain |
| [ADR 0021](../adr/0021-compacted-provider-accounting-provenance.md#concept) | Its validated accounting provenance remains required in v3. ADR 0044 replaces the v2-only writer; the pre-1.0 override removes v1/v2 readers and cross-generation cutover state. Invalid continuation cannot become reported usage |
| [ADR 0023](../adr/0023-experimental-public-session-protocol.md#concept) and [ADR 0032](../adr/0032-daemon-attachment-residency-and-replay.md#concept) | ADR 0044 replaces the served generation set and metadata-only digest with the coordinated M7 contracts below; exact negotiation, framing, session authority and connection lifecycle remain |
| [ADR 0009](../adr/0009-tool-executor-and-grant-contracts.md#concept) | ADR 0041 adds read ranges/resolved arguments and inserts owner refinement/committed-membership resolution between validation and policy, ADR 0045 interaction dispatch, ADR 0046 explicit per-create selection; exact generations, grants and reserved namespace remain |
| [ADR 0028](../adr/0028-bounded-artifact-retrieval.md#concept) | ADR 0041 extends attachment-owned transfers to job-owned range reads, sharing runtime capacity and reusing finite verification/work/deadline ceilings |
| [ADR 0024](../adr/0024-durable-interaction-lifecycle-and-host-policy-authority.md#concept) | ADR 0045 adds model producer/text/decline; ADR 0046 adds immutable defer refusal; interactions grant nothing |
| [ADR 0025](../adr/0025-resource-packs-and-skill-admission.md#concept) | ADRs 0042–0044 use fresh receipt revision 4 for instruction/compaction provenance and continuation accounting; maintenance explicitly skips optional intake. Ordinary resource admission/costs and old v2/v3 validation remain |
| [ADR 0039](../adr/0039-ephemeral-embedded-profile.md#concept) | Credential audience/cleanup preserved; ADRs 0042/0044 add explicit initial instructions, system ceiling and reasoning under ADR 0044's combined closed option inventory; ADR 0043 adds explicit maintenance instructions and model at startup; ADR 0045 adds bounded one-call answers; ADR 0048 adds explicit provider references and amends durable single-source wording; ADR 0049 adds owner-managed trace startup |
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
reviewed contracts; source implementation and literal schema/vector digests are
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

| Member affected | Required M7 contract and owning ADR |
| --- | --- |
| `session.create` | Versioned session-option validation for resolved configuration, instructions and immutable selections under ADRs 0042/0044/0046. Remote input cannot supply provider capabilities, credential routes, host catalogs, registry modules, derived `tool_selection` or `artifact_read` bindings. |
| New `session.configure` | Existing request/command correlation plus a nonempty closed configuration update containing only ADR 0044's mutable fields. Foreground attachment authority and daemon writer-epoch/controller authority apply before mutation. |
| New `session.compact` | Existing request/command correlation plus explicit maintenance `bounds` containing `max_attempts`, `deadline_ms`, `token_budget` under ADR 0043. Same authority as other mutations; admission/unknown/refusal are distinct from completion. |
| `session.prompt` | A closed optional `bounds` object accepts the existing limit overrides (`max_turns`, `token_budget`, `deadline_ms`) and ADR 0046's optional `deadline_at_ms`. Preserve prompt partial-override behavior: capture host defaults for omitted ordinary limits once at admission. Bind authored bounds in the new command identity and retain effective bounds on replay. |
| `session.follow_up` | Optional closed `bounds` accepts only `deadline_at_ms`. Retain that authored ceiling through queue promotion; omission supplies no inherited absolute ceiling. Ordinary turn/token/relative limits retain ADRs 0013/0017's inheritance from the active run. Reject attempts to override them; steer cannot supply bounds. |
| `session.respond_interaction` | Keep the correlated `interaction_id` and command identity. `answer` has exactly one branch: `{choice_id}`, `{text}` or `{disposition: declined}`. Text/decline are model-question-only under ADR 0045; policy-defer retains its choice branch. |
| Configuration records | `session.configured`, inspection and attachment snapshots use an explicit allowlist: committed configuration version, exact model/reasoning, effective reply/context/system limits and instruction version/digest. Exclude raw instruction bytes, model capability/provider mapping envelopes, host binding maps, credential references, capability handles and private native continuation. An unresolved legacy configuration is explicit, never a fabricated default. |
| Compaction records | Durable `context.compacted` identifies the checkpoint, covered range/integrity digest, owner-computed `source_excerpted` flag, exact summarizer model/thinking-off setting, usage and owning configuration/maintenance identity. Checkpoint snapshots and rendered summary provenance retain the flag, including inherited omissions. Active-maintenance inspection/snapshots expose captured model identity and bounds, excluding provider mappings, instruction bytes, permits, routes and private recovery records. `context.compaction_progress` remains transient. Standalone context.compaction_finished and last_compact snapshot carry the exact completed episode/command result, including unchanged and failed without checkpoint. |
| Interaction records | Pending and terminal projections preserve producer, kind, stable choices, original run/turn/call identity, expiry and answer/decline/expiry disposition. Attach snapshot and replay agree at the same cursor, including a question already pending when attachment begins. |
| Run/bound records | Preserve the effective absolute deadline and ordinary bound/terminal outcome through committed run views, while keeping relative and absolute limits distinct. Encode new ordinary bound members as canonical positive decimal strings: `max_turns`/`token_budget` retain their current positive-integer domains, `deadline_ms` its positive uint64 domain. `deadline_at_ms` uses ADR 0046's positive JSON safe-integer domain. Apply the same conversion on output; never round through JavaScript numbers or silently impose uint64 on turns/tokens. |
| Context refusal/failure | ADR 0043 owns private refusal revision 2, its closed numeric/nonnumeric failure union and measured/unavailable projections; new wire event/snapshot/compact-result schemas include it with uint64 values as exact decimal strings. Old revision 1 retains its five-key shape and fixed system limit. |
| Tool-definition format | Version the interaction-class addition and zero artifact-budget exception under ADR 0045. Preserve old effect-definition bytes; the new artifact-capable read generation and artifact-retaining grep/find/ls generations keep their own exact version/digest. The tool-definition version is distinct from session-protocol generation. |

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
that rule. ADR 0046 specifies the explicit amendment: version new normalized
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
prove explicit refusal. The pre-1.0 maintainer override retires historical
release/rollback lanes; current-generation consumers remain required in M7 lanes.
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

The accepted `loopex chat --config FILE` contract owns a foreground durable runtime.
It adds settled prompts and explicit steer/follow-up/answer/compact/configure/
abort/status/wait actions, ordered TTY and pipe input, explicit answers/declines,
bounded EOF/interrupt cleanup and fail-fast pipe errors. Existing
`ask`, `run`, `resume` and daemon client semantics remain, except explicit trace
startup controls on `ask` and daemon startup. Remote chat attachment is M8 successor work.

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
marked serialized excerpts of the oldest eligible whole unit, or of a short
leading prefix together with the next unit, when necessary.
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
not a versioned compatibility assessment. The accepted plan relies on the
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

| Suggested strategy | Verified capability and correction | Accepted M7 disposition |
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
known overshoot, unknown usage, no restart reset and startup classification
under ADR 0046's fixed bound. First protocol integration
adds the negotiated schema and independent Node fixtures for every changed
command/event/snapshot. No outcome is proved by tests of only the happy path.

The accepted fixed task catalog is:

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

**Case verdict and prior failures.** The fixed manifest declares each case's
required model actions and objective oracle before execution. The runner records
a mechanical result first: `pass`, `required_action_absent`, `assertion_failed`,
`evidence_incomplete_pre_dispatch`, `evidence_incomplete_post_dispatch` or
`provider_environment_failure`, with
failed assertion IDs and committed boundary facts. It emits exactly one, the
first that applies in this order: pre-dispatch incomplete evidence; post-dispatch
incomplete evidence, meaning a required retained record (capture, attendance,
command log, index append or cleanup confirmation) is missing or unreadable, not
an assertion that could not be evaluated because an earlier call failed;
`provider_environment_failure`, only when a required call's
committed terminal or retained transport record carries a provider or transport
failure class; `required_action_absent`; `assertion_failed`; `pass`. The label is
mechanical and never binds the reviewer's verdict. A named independent reviewer
then assigns the cause verdict below; the runner cannot decide whether a product
defect caused a model miss. A complete pass can be provisionally mechanical, but
closure still requires review:

| Verdict | Rule |
| --- | --- |
| `pass` | Every prescribed assertion, including expected negative outcomes, passes; required attendance and complete evidence are present and fixture cleanup is confirmed |
| `product_failure` | A product, fixture or harness path fails a required assertion, including a legal capacity/refusal that prevents a required positive case; record the causal evidence. This label does not assert a code defect |
| `model_nonconformance` | Valid committed input and complete boundary evidence show the model omitted a prescribed action or violated the fixed task oracle, with no causal product/fixture/harness failure or missing evidence |
| `evidence_unavailable` | Missing evidence, prerequisites, attendance or unconfirmed fixture cleanup prevents a verdict about the required behavior |
| `environment_failure` | Complete retained boundary evidence establishes a provider-side outage after the case's `started` record, as bounded below, with no causal product/fixture/harness fault or model miss; an independent reviewer confirms the diagnosis and cleanup |

Environment failure is not PASS and supplies no positive behavior proof. The
maintainer selected A on 2026-09-30: retain the failed attempt and its reviewed
outage evidence, then permit only that affected case again on a new candidate
under the normal matrix rules, without requiring an invented product correction.
The new candidate records this diagnosis/authorization; a fresh SHA alone is not
a route. No same-SHA retry, model-miss exemption or missing-evidence substitution
is allowed. Invalid credentials/routes, local harness faults and unconfirmed
cleanup cannot be relabelled external outages.

The maintainer bounded this class on 2026-09-30 to provider-side failures after
the case's `started` index record: transport failure to the provider, provider
5xx/529 responses and provider-side timeout. An HTTP 429, quota or credit
exhaustion on the operator's account and loss of the runner host's own network
are operator-owned prerequisites, not outages. After `started` they are
`evidence_unavailable` under the post-dispatch rule below, whose reviewed
correction may be a committed preflight or procedure fix for that prerequisite.
A first call that never connects after `started` consumed the attempt; the
reviewer classifies it by its retained cause under these two lists. When
retained evidence establishes neither a provider-side cause nor a product,
fixture or harness cause, the verdict is `evidence_unavailable`; a connect
failure, rate limit or exhaustion traced to a product, fixture or harness fault
is `product_failure`.

"Only that affected case" names which prior-failure fence this verdict lifts. A
new candidate always runs its own complete closure matrix, and no result of an
earlier candidate is reused. For a pre-merge `--only` lane, where no scaffold
exists yet, the carrier is a reviewed case event in state
`authorized_next_candidate` appended to the attempts index; the lane then runs
again only on a later commit, and the candidate scaffold reconciles that row.

The reviewer distinguishes a missing model action from invalid inputs, product
refusals and recording/attendance loss. A refusal that follows its contract can
still fail a positive demonstration; it cannot be called model nonconformance or
PASS. A fixture/harness defect has the same causal-correction route as a product
defect. The reviewer assesses whether the correction addresses that failure.
The reviewer cannot waive an assertion, attendance or evidence requirement. Unresolved classification
blocks the case. Every candidate scaffold predeclares a prior-attempt section
with one row for each earlier candidate/case/attempt, its verdict, retained-output
reference/digest, diagnosis and any disposition. A new candidate incorporates
known rows before commitment; the closure child fills only predeclared values.
A failed unchanged case cannot run again merely because another fix produced a
new SHA. `product_failure` needs a substantive causal correction to the affected product,
fixture or harness and review, while preserving required assertions. A
`product_failure` with no assertion-preserving correction, including a legal
refusal and a provider rejection of a registered thinking cell, routes to a named
scope amendment under menu item 3, not an accepted limitation. Pre-dispatch missing prerequisites may be repaired on the
same SHA only after retained proof that no model call started anywhere in that
case; its index state is not_dispatched and no attempt was consumed. Resume the
same logical matrix through the index below; never revisit completed cases. Post-dispatch evidence loss is evidence_unavailable, never a model
miss. The maintainer selected A on 2026-09-30: retain the incomplete attempt,
require an independently reviewed causal fix to the recording, attendance or
operator-prerequisite path, and run the affected checks on a new candidate,
inside that candidate's own complete matrix. Source/configuration changes
must address that cause while preserving the case's assertions. A committed
runner or attendance-procedure repair qualifies only when independent review
shows it would have prevented the loss; an unrelated runbook edit does not.
Absent such a fix, use disposition menu item 3 below. A new SHA alone,
a repaired environment alone or newly available attendance cannot authorize a
post-dispatch replacement on the same unchanged case. This is no same-SHA retry
exception. Record the diagnosis, correction and review before another attempt.

`model_nonconformance` routes to the maintainer with this fixed disposition menu:

1. Keep the case and stop pending a supported causal product correction.
2. Explicitly approve a revised pinned model or witness for a new candidate,
   retaining every required assertion, attendance obligation and prior failure.
3. Propose a named scope or evidence-rule amendment for separate approval.

Until that disposition is recorded, no replacement attempt is authorized.
Nothing here accepts a limitation, cross-candidate evidence reuse or an attendance
waiver. `evidence_unavailable` is not PASS; restarting a dispatched model case
still obeys the same attempt rule.

**Case ownership.** Before the first provider attempt, the fixed manifest assigns
each prescribed real-provider case a stable case ID, one owning release lane
and its ordered prompts, actions and checks. One case execution may contain
several runs and prescribed process restarts. The runner allocates and retains
its attempt identity before dispatch; every session/run/child identity belongs
to that execution record. Multiple outcome or step references reuse that
record, not another model execution. The release selector union executes each
owning case once in the full closure invocation, including when coding-task and
operator steps share its evidence. Extend `scripts/check-release.sh` and its
existing manifest/identity sidecars rather than adding another check command.
The owning lane for each attended M7 case is `m7-operator`; the unattended
real-provider lane is `m7-provider`; the credential-free M7 rollback lane is
`m7-rollback`. Deterministic integration/fault cases name
one exact fast-check or unattended release test. Both M7 provider lanes belong
to the full matrix. The runner binds each case wrapper's execution identity and
oracle result to its manifest case ID, even when one wrapper spans several runs.
Existing ExUnit row identity checks and attended rows remain required. Extend
the manifest/sidecar validator from its fixed eleven-case assumption to two
explicit families: the unchanged eleven legacy ExUnit cases and the fixed M7
wrapper cases. M7 chat/ephemeral wrappers are executable drivers, not fabricated
ExUnit rows. Validate exact manifest membership, identities, attendance and
coverage for both families; missing rows fail.

An attended case, including a shared coding task, runs only in the full matrix
with a named human operator. `--only` accepts lane IDs: `m7-provider` and `m7-rollback` are eligible pre-merge
lanes; `m7-operator` refuses. Case IDs identify manifest rows, not CLI selectors. Such evidence does
not replace any required full-matrix execution or authorize a failed case reroll.
The full runner visits each manifest case once per logical matrix, preventing
duplicate dispatch. `--resume-matrix MATRIX_ID --attempts-index FILE` resumes
that same matrix only after a pre-dispatch stop: validate candidate, pins,
manifest and retained completed-case digests, reuse those results and start only
not_dispatched cases. It never resumes a consumed incomplete case or recreates
an attempt. The resumed invocation has a fresh retained command log joined to
the same matrix ID; no completed fast/release lane runs again. Each resumed
invocation re-stages and rebuilds the fresh-source extraction of the same commit
as a prerequisite, into a fresh retained directory; it must reproduce the first
invocation's retained source-archive manifest digest or refuse, and it is not a
second fresh-source evidence run. Every non-manifest release lane (fresh-source,
each node-client, long-bound, cross-UID and rollback lane) has one index case
key so that resume can skip completed lanes. This is one
logical closure matrix, not a second full check or a new attendance exemption.
Plan acceptance changes what "the release check runs once" means for M7 in this
one respect, as the Concept and context map record: a pre-dispatch stop may be
continued by a later invocation on the same SHA, once per pre-dispatch stop. A
fresh full invocation refuses when the index already holds, for that candidate,
a case at or beyond `started` with a non-null logical matrix ID.
Any non-pass mechanical result of a case or subcase whose index state reached
`started`, that is every result except `evidence_incomplete_pre_dispatch`, in a
credential-free lane or a paid case, stops the logical matrix or the pre-merge
`--only` invocation before the next case or subcase dispatch. Later cases are
not_dispatched. Later subcases of the stopped case get no state of their own:
they belong to that consumed attempt and are recorded as not run in its case
event. A matrix stopped under this rule is not resumable, because its candidate
can no longer close; no later case runs as an unapproved paid look-ahead. A
paid M7 pre-merge `--only` lane, and `m7-rollback` when invoked with
`--attempts-index`, is one logical lane per commit SHA and lane ID. A
pre-dispatch result (`evidence_incomplete_pre_dispatch`) stops the invocation
before the next case and suspends every selected lane that still has a
not_dispatched case; it ends none. A suspended lane may be invoked again on the
same commit as its continuation: it presents the same attempts index, reuses
that commit's completed null-matrix rows and dispatches only its not_dispatched
cases. A lane ends when every one of its cases is completed with `pass`, or when
any case of that invocation reached `started` without a completed `pass`,
including a case left at `started` with no result and a started non-pass in
another lane of the same invocation. An ended lane is not invoked again with
`--only` on that commit; this never bars the full logical matrix, whose rows
carry a non-null matrix ID.
The full runner runs a contiguous attended block through executable wrappers attached to the
operator's `/dev/tty`, with the existing PTY capture preserving human input and
exact IDs. Do not run those wrappers as hidden System.cmd children expecting
unattended stdin. Each manifest case pins finite run, standalone-maintenance,
question/attendance and cleanup ceilings; the block ceiling is their sum plus
its pinned setup allowance, and the runner reports elapsed steps live. These
explicit case budgets never silently inflate a failed check's timeout; automatic
PTY answers never establish M7 attendance. A ceiling breach adds the case's
ceiling assertion ID to the failed assertions. Its mechanical result is still
the first that applies in the order above, and `assertion_failed` only when
nothing earlier applies; the reviewer assigns the cause verdict under the table
above, so a provider-side stall or a late operator is not presumed a product
failure. It stops the matrix under the rule above. Print the summed
finite block ceiling before starting. Phase 0 pins per-case numbers within
60,000-ms standalone maintenance, 120,000-ms question/tool holds, 600,000-ms
individual run and committed cleanup bounds; case totals sum their fixed run/
subcase counts plus a 60,000-ms setup allowance. None may be adjusted during a run.
During the full matrix, before any paid M7 dispatch, complete in this fixed order: fresh-source/build,
the two legacy attended rows as the first legacy real-provider rows, the
remaining legacy unattended rows, node_client, long_bound, cross_uid where the
platform runs it, and both rollback pairs. A failure in
any of them is retained and stops the matrix before the M7 attended block. V10 collection/external execution,
V11 tracing, V12 configuration and V13 artifact/restore steps are actions inside
that same full invocation, with their slots and cleanup joined before success.

| Case ID | Lane and scenario | Objective oracle |
| --- | --- | --- |
| `m7.repair` | `m7-operator`, V2.1–5 | Repair catalog assertions, both pinned test results, allowed diff and reopened diagnosis facts |
| `m7.feature` | `m7-operator`, V5.1–2 | Committed ask/actual-ID answer, chosen row default and both pinned test results |
| `m7.review` | `m7-operator`, V8.1–4 | Both committed role calls, exact known finding/call chain, unchanged child workspace and separate/combined usage |
| `m7.long` | `m7-operator`, V6.1–4 and V6.6 settled reopen | Long catalog facts/files after automatic/explicit compaction and restart; raw/checkpoint agreement |
| `m7.pipe-answer` | `m7-provider`, V2.6 answer and decline subcases | Actual emitted IDs match committed responses; expected answer/decline outcomes and confirmed cleanup |
| `m7.question-restart` | `m7-operator`, V5.3 | Same pending identity after prescribed loss; actual answer and selected feature oracle |
| `m7.ephemeral-question` | `m7-operator`, V5.6 positive | Real displayed question, human callback answer, chosen feature oracle and ephemeral cleanup |
| `m7.oversized-source` | `m7-operator`, V6.5 positive | Progressing checkpoint, inherited omission flag and host-readable complete sentinel/original |
| `m7.cross-provider-maintenance` | `m7-provider`, V6.7 | Captured distinct provider routes, thinking-off summary, continued facts and usage counted once |
| `m7.provider-switch` | `m7-operator`, V7.1–2 and V7.4 | One session's A→B→A canonical facts/tool results and captured configuration identities; its A leg is Haiku at `none` with a tool round, witness key `m7.provider-switch.haiku.none`; the session is reopened once between the B and second A runs |
| `m7.thinking-rounds` | `m7-operator`, V7.3, seven fixed subcases: Haiku low/medium/high and Fable default/low/medium/high | Per subcase, at least two continuation requests after committed tool-result rounds, expanded outgoing-block equality, final fixture facts and settled reopen |
| `m7.thinking-bound` / `m7.thinking-cancel` | `m7-provider`, V7.7; nine bound subcases, one per ADR 0044 cell, and one cancel case | Prescribed bound/cancel after committed tool results; the next prompt on the same model is accepted with canonical grouping/facts, its exact mapping and no old native state; one further prompt proves native thinking resumes on continuation-required cells; truthful cleanup |
| `m7.policy-denial` | `m7-operator`, V9.1 | Required denied call commits its policy result; no effect intent/receipt or workspace change occurs |
| `m7.daemon-detach` | `m7-provider`, V9.4 | Client detach/reattach while the prescribed run is active preserves run identity and does not cancel it; final oracle and cleanup pass |
| `m7.restore` | `m7-operator`, V13.1 record/verify and V13.4–6 | Attended verification of the retained backup manifests, access prevention, restore and manifest inspection joins m7.rollback's exact retained execution; no new provider call or rollback rerun |
| `m7.rollback` | `m7-rollback`, V13.2–3 and credential-free producer for attended inspection | Both historical/new archive pairs, old-reader observations and credential-free restored baseline satisfy their fixed oracles; creates the V13.1 M6 roots and retained pre-upgrade copies |
| `m7.external` | `m7-operator`, V10 external execution | Pre-dispatch pin, pinned repository acceptance commands and allowed diff |

The manifest also pins provider-backed baseline cases `m7.baseline.ask` and
`m7.baseline.durable` for V1; `m7.instructions.admitted`, `.declined` and `.changed`
for V3 with exact receipt identities and distinctive fixture behavior;
`m7.steer-barrier` for V4 with committed steer/follow-up order and generated facts;
`m7.interrupt` for V9.2 with terminal cancellation and cleanup; and
`m7.trace.flag`, `.file` and `.json` for V11 with task assertions and separated
redacted trace output. The baseline, admitted-instruction, steer-barrier,
interrupt and all three trace cases are `m7-operator`, because the mandatory
table attends at least one of their steps; `m7.instructions.declined` and
`.changed` are `m7-provider`. The baseline cases own V1.3.ask and V1.3.durable separately;
`m7.baseline.durable` pins the dated Haiku model at `default` and includes one
tool round, and `m7.long`'s Haiku summary subcase has key
`m7.maintenance.haiku.none`, as ADR 0044's witness table requires. V11.5 trace cleanup
uses terminal/cleanup facts from each existing trace case; it creates no new
provider run. Each variant has its own pinned initial root, ordered inputs and oracle; inspection steps reference those
executions without calling a model again. V12.1–2 reuse `m7.trace.file`'s file-only
startup and `m7.trace.flag`'s explicit override startup, including one ordinary
chat prompt through the built escript and committed effective-value checks.

`m7.range-read` is a deterministic fast-check integration case inspected at
V6.2, not a required model action in `m7.long`. V6.6 faults, V5.4–5, V5.6
responder negatives, V7.5–6, V8.5–7 and other controlled negatives name exact
suite/test IDs and expected facts in the manifest. Tests of those negatives
cannot replace any failed positive provider case. The fast suite cases `m7.instructions-authority`, `m7.late-steer`,
`m7.recovery-faults` and `m7.resume-configuration` own V3.5, V4.5, V9.3 and
V12.4 respectively; their exact test names/paths and negative facts are pinned
in phase 0's manifest. V6.2.long belongs to m7.long; V6.2.range belongs to
m7.range-read. All remaining V steps/subcases receive one fixed step key,
exact owner/test, oracle and evidence slot;
no unlabeled provider call may be added by the runbook.
Each case starts from its pinned initial workspace/state or the exact retained
state of its prescribed predecessor; the manifest declares which. It cannot
silently reuse a workspace already repaired by another case. Independent
oracle reruns verify the existing task workspace without calling the model or
starting another task attempt. Every full-matrix case, including credential-free
cases, and every paid M7 pre-merge --only execution must use
`--attempts-index FILE`, an absolute retained path outside repository/workspaces.
Phase 0 pins one campaign ID and index genesis digest in the committed manifest;
all machines use that campaign's complete index. A fresh unrelated index cannot
hide an earlier attempt within this trusted procedure: genesis is reproducible
from committed data, so the anchors are the committed heads below, not the
genesis pin. One designated campaign writer holds an exclusive local
file lock. Local locks do not establish exclusion between machines. The trusted
runner procedure therefore records a writer identity and ownership epoch in
closed ownership events, separate from genesis and case events. Initial
designation follows genesis before any case record. Before dispatch,
the local runner checks that it is the latest designated writer and has no
unsuperseded relinquishment marker.

A handoff first quiesces the old runner with no unresolved append or active case,
appends and fsyncs relinquishment naming the destination and preceding head/count,
and retains a local relinquishment marker checked by every later invocation there.
A marker refuses dispatch and case appends, never the acceptance step of a
verified incoming handoff whose relinquishment names this host; that host's
appended acceptance then supersedes it, so a correct handoff back is possible.
Only then release the old lock and transfer the complete index and referenced
evidence. The transferred head includes that relinquishment event. The destination
verifies this head, quiescence evidence and source revocation before appending its acceptance of the next epoch and
becoming the sole writer. Interrupted or uncertain handoff blocks dispatch on
both hosts until the same handoff is resolved; it does not create another owner
or campaign. No stale copy is a valid evidence source. This is a retained
single-writer procedure over trusted hosts, not distributed fencing by a local
file lock. Phase 0 pins its control-event shapes, safe recovery procedure and
two-host handoff/split-writer refusal tests. No new service is required.
After an indexed pre-merge lane (paid, or `m7-rollback` invoked with
`--attempts-index`) ends on a commit, whether it completed or stopped after a
started non-pass, or a full logical matrix stops on a candidate,
the next commit of that work appends one line
`index-head: <campaign_id> <sequence> <sha256>` to the Concept file's Progress
and Evidence section, below its table and never as a table row; a commit that only adds this line needs no indexed lane of its own. A
full matrix that completes owes no such line while its candidate closes: the
administrative closure commit records the final head digest/count only in the
scaffold's predeclared Pending slots. If that candidate does not close, the
next commit of that work appends the line as for a stopped matrix. A
suspended lane has not ended: its continuation on the original commit is the
same lane and needs no such line. Its rows beyond the latest committed head are
protected only by the retained single-writer index procedure above, not by a
committed head; preflight still requires the presented index to extend the
latest committed head, and identifies a continuation by that commit's and lane's
rows in it. A suspended lane that will not continue on its commit, for example
because its prerequisite repair needs a commit, is abandoned by the same
head-recording commit: that commit records the current head, the lane's
not_dispatched cases stay not_dispatched, its completed rows are retained and
are not reused on any other commit, and it never continues. An indexed lane is new
when the index holds no row for its commit and lane ID; a new indexed lane refuses
while the index holds any case event at or beyond `started` after the greatest
committed head. Phase 0 pins two vectors: one case passes, the next stops
pre-dispatch, the lane continues on the same commit without dispatching the
passed case again and its head is committed only after it ends; and a suspended
lane is abandoned by a head-recording commit before a new lane runs on the next
commit, which dispatches every case again as that commit's own work.
 Preflight uses the `index-head:` line with the greatest sequence among lines
naming the manifest-pinned campaign ID in the checked-out Concept file; two such
lines with the same sequence and different digests refuse. Lines of a
predecessor campaign are checked only against the succession event's bound
predecessor head digest/count.
The scaffold records the known head/count before candidate commitment. Preflight
requires a valid chain extending the latest committed head, including every
subsequent attempt; missing history or a mismatch refuses dispatch. Loss or
unrecoverable corruption of the index therefore refuses dispatch. Only a
recorded maintainer disposition can authorize a successor campaign; it binds the
last committed head and count, carries every known prior row forward and records
the lost interval as unavailable evidence. The successor's campaign ID and
genesis are pinned by a new manifest commit, so it always starts on a new
candidate. Its first event after designation is a closed succession event
binding the predecessor campaign ID, the last committed head digest/count and
the disposition reference. Phase 0 pins that event shape.

The index is append-only compact sorted-key JSONL, one at-most-65,536-byte record
per line. Its closed envelope is `{version: 1, campaign_id, sequence,
previous_digest, body, digest}`. Sequence increases from 1; previous_digest is
null only for genesis. Digest is SHA-256 of the exact compact JSON encoding of
the other five members, without LF. Body is a closed versioned event union of
genesis, ownership (designation, relinquishment, acceptance), succession and
case events:
genesis binds only the campaign ID and codec version, avoiding a manifest/genesis
digest cycle; case events bind the current manifest digest, candidate SHA,
logical matrix ID or null for pre-merge lane work,
case/subcase key, fixed specification digest, attempt ID or null, state,
mechanical result/verdict or null, and bounded retained evidence/diagnosis/
disposition references and digests or null. Phase 0 pins its full literal schema,
relations and vectors. Unknown members, duplicates, forks, truncated complete
records or state regressions refuse. A trailing incomplete append is unresolved,
never absence; recover exclusively before proceeding. fsync each append before
acknowledgement or dispatch. No credential values enter this index.

Case state is not_dispatched, started, completed, reviewed or
authorized_next_candidate. Register started and the fresh execution path/attempt
identity before the first model call in a paid case, or before the first actual
check/case execution in a credential-free case. Possible execution without
completed evidence consumes either kind of case. Not_dispatched requires
attempt_id null and proof that no model call began anywhere in a paid case, or
that no check/case execution began in a credential-free one. Only allocation/
prerequisite failures before that boundary leave this state. Credential-free
started failures retain the existing prohibition on repeating failed unchanged
bytes; absence of a model call cannot make them resumable. A completed result can be reviewed and dispositioned by appended
records, never overwritten. References join every command log to one logical
matrix ID. Resume consumes only not_dispatched rows, retaining all completed
results and prior attendance. It cannot replace a started unresolved attempt.
Before candidate commitment, reconcile the complete index into predeclared prior
rows. Every candidate scaffold records the committed pre-candidate head
digest/count and the pinned campaign/genesis digest as fixed values. It
predeclares Pending slots for the index path, the final head digest/count and
one cell holding the count and SHA-256 of the ordered logical-matrix
invocation-log reference list; its closure child fills those values from the
extended chain without adding rows/headings.

A selected lane with an unresolved prior case failure refuses before any model
call and reports evidence unavailable for the merge; it neither skips that case
nor dispatches it again. Case/causal disposition must authorize a new candidate
first. The tested implementation SHA's In-review register transition declares
the closure candidate. After that commit no extra paid --only M7 execution is
allowed; the full logical matrix owns its new attempts and existing slots.
Known pre-merge failures on any machine remain visible. Repeated selection,
missing evidence or failure cannot allocate a replacement attempt to manufacture
a pass. The failure/candidate rules above still govern.
The maintainer selected agent-run fixture tests and independent harness reruns.
Add a fixture-host policy adapter supplied by trusted validation-harness
composition to the real CLI path, with exact approved invocations and a pinned
manifest. This bypasses no policy decision and exposes no new production config
profile or caller-supplied policy module. The planned trusted entry point is
`scripts/m7-fixture-chat.exs`: validate the ordinary explicit file and closed
policy profile first, then inject the fixed fixture policy through host
composition and invoke the same CLI conversation driver. Trusted overrides are limited to the pinned fixture
policy and V7.7's conformance-tested pre-transport Model-port cancellation gate.
The latter proves cancellation before that transport, not in-flight HTTP
cancellation; existing real-provider cancellation lanes keep that obligation.
Only the harness owns these overrides; neither a config field nor a model argument names a module.
The planned internal `LoopexCli.Chat.run/2` join accepts resolved conversation
options and trusted host composition overrides; the ordinary `main/1` path
supplies none. It is not a public/configurable policy-module option. Effective
inspection and `/status` report policy origin `harness` and the pinned fixture
policy/manifest identity when the wrapper supplies it; the production registry
profile remains separately visible. V2.4 and V5.3 reopen through the same wrapper
and the same pinned case policy/manifest, with ADR 0024 identity checks for
pending interactions. Exercise V12.1–2 and an ordinary chat
prompt through the built escript too, retaining stdio/live-signal/bootstrap
checks that embedding the driver alone cannot prove. The escript inventory
continues to prove dependency presence, not command behavior. Before the attempt,
pin command bytes, executable/runner
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
declines under case `m7.pipe-answer`. Static repair prompts declare complete
requirements and say no clarifying question is needed; this wording does not
waive an unexpected-question failure or claim the model can be forced not to ask.

1. Open the repair fixture and request a diagnosis without an edit.
2. Ask for the fix by referring to the earlier diagnosis without repeating it.
3. Have the agent run the explicitly approved test command, then rerun the
   pinned acceptance oracle independently. Require both results and allowed-diff
   checks to pass. Execute these three prompts through a pipe with `/wait`
   barriers; interactive use is covered by V3–V5.
4. Close and reopen the settled session using its recorded identity.
5. Ask about the original decision and verify continuity against retained
   history and the resulting patch.
6. Run the separate bidirectional-pipe answer and decline subcases. Read each
   emitted interaction ID, submit that exact ID, and inspect the committed
   response/outcome and cleanup. This automated case is separate from the
   attended repair and cannot replace it.

#### V3. Admit instructions and specialize work

1. Prepare a distinctive benign project instruction and an explicit review skill.
2. Inspect and admit their exact bytes, then perform the fixture task.
3. Repeat from a fresh fixture with the resource declined; inspect admitted
   context and resulting behavior.
4. Change the resource, admit its new identity, and verify the receipt changes.
5. Ask for an action denied by policy and verify that admitted instructions
   and the review role cannot authorize it.

#### V4. Steer and queue a follow-up

1. Start `m7.steer-barrier` and request its exact approved `loopex.bash` argv
   invocation of the pinned fixture runner outside the writable task tree. It
   waits on a harness-owned FIFO. Release it only after committed steer-admitted
   and follow-up-queued evidence for this case, never merely after terminal
   input. Pin a hold limit below the 120,000-ms tool wall time and remaining run
   deadline, leaving a documented cleanup margin. Timeout is a retained failed
   assertion; a missing required call is model nonconformance. Abort removes
   only confirmed fixture-owned processes/FIFO state. The trusted wrapper
   admits that exact runner invocation through its fixture policy. An independent
   observer attachment captures committed events and joins the case's exact
   session/run/operation plus steer/follow-up command IDs before FIFO release;
   terminal input or progress alone cannot open it. Use the existing read-only
Loopex.attach/2 subscription via committed session events and its snapshot,
with event sequence/catch-up validation; it is not a progress subscriber or a
second truth writer. Operator timing against a
   fast provider is not the acceptance oracle.
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
   Inspect retained `m7.range-read` deterministic integration-test evidence for
   a source file of at least 16 KiB: full 4-KiB ranges where encoding fits, exact
   offsets through EOF, escaped/multibyte boundary cases and complete staged
   requests. This host-driven test calls no provider; it does not add required
   range-read actions to the `m7.long` model oracle or rerun that task.
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
3. For each of the seven continuation-required cells of ADR 0044's table, as
   fixed attended subcases of `m7.thinking-rounds`, select that pinned Claude
   thinking mode and run the fixed multi-round
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
   restart and exact replay. `m7.thinking-rounds` pins its measured input ceiling
   and fixtures before dispatch and requires at least two actual continuation
   requests following committed tool-result rounds; a single tool round fails
   that oracle. Each counted continuation request must replay at least one
   retained thinking or redacted-thinking literal; an exchange with none is
   `required_action_absent`. Retain each request's sizes/charges and canonical identities.
4. Close and reopen the session by its recorded identity while provider B is
   configured, then switch back to provider A and verify continuity with the
   fixture's facts and earlier tool results.
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
7. Inspect the separately owned `m7.thinking-bound` and `m7.thinking-cancel`
   real-provider cases. Each performs its prescribed terminal cut after committed
   tool results, then submits a new prompt on the same admitted thinking model.
   Require accepted canonical message grouping, correct fixture facts and no
   resurrected native state. The maintainer selected this oracle on 2026-09-30:
   that post-terminal request need not itself show native thinking, because the
   provider may answer one request without it. Then submit one further prompt in
   the same subcase, after that completed assistant turn, and assert from bounded
   native-capture classification that its reply used native thinking for each
   continuation-required cell. For Haiku default and none, require the registered
   nil-continuation, no-native-thinking behavior on both requests instead. Each
   cell must match its exact admitted mapping on both. Both prompts are fixed
   steps of the one counted subcase. No private blocks enter the evidence.
   Controlled cuts are actions within each fixed case,
   not replacement attempts; missing required model actions still fail. The bound
   case pins a one-turn limit so the first complete tool group commits before
   bound termination. For cancellation, a trusted conformance-tested Model-port
   gate holds the exact second staged request before transport, after the observer
   has joined first-turn committed results; the driver admits parent abort there.
   The gate observes cancellation/cleanup, changes no request bytes and supplies
   no fake reply. The cancel case takes the same two later prompts and the same
   oracle on its pinned cell. The first exchange and both later same-model
   prompts call the real provider. Retain the blocked attempt's truthful dispatch/accounting outcome.

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
   can be recovered without reopening its parent. Inspect pre-reservation crash
   and lost-log cases: proven absence retains a conservative count charge;
   missing evidence for a historical child refuses. Query tests prove no session
   activation. Changed runtime grace cannot replace retained genesis.
   A child may finish cleanup after the parent's observation window; the parent
   remains unknown. Stop helpers through their parent, never direct child abort;
   if unavailable, restart the host for stop-only recovery. Inspect late local
   cancellation, active-row reclamation, per-ID tombstones/overflow restart and cross-parent
   ledger-fence tests. Inspect the startup-classification tests: bounded
   60,000-ms slices with retained coverage, closed admission with covered and
   enumerated counts, resident-host completion of both recorded cases, and an
   unreadable session history keeping the host closed until restore.
6. Exhaust a small delegation allowance across serial children; verify that
   another child refuses while the parent's remaining budget stays distinct.
   Inspect parent, helper and combined usage, then restart and verify no reset.
   The refused call consumed no child count/tokens and requires no ledger row;
   its committed pre-effect refusal must keep the parent activatable after restart.
7. Reject an unknown/disabled role. Edit a role file, reopen the parent and
   verify its retained catalog and every delegation declaration field still
   govern. Edit child and aggregate limits and try conflicting `--no-helpers`;
   confirm refusal of the explicit disable and no allowance/counter reset.

#### V9. Refuse, interrupt and recover

1. Trigger a policy-denied effect and verify no effect occurred.
2. Start m7.interrupt with V4's exact pinned FIFO runner and fixture policy.
   The observer joins the committed effect intent before interruption; release
   only through cancellation/confirmed cleanup. Interrupt the held foreground
   task and inspect its cancellation/cleanup result.
   For a helper, cancellation goes through the parent. A late confirmed child
   stop does not rewrite the parent's expired observation as confirmed cleanup.
3. Recover a disposable durable session after controlled process loss and
   inspect the committed outcome before submitting more work.
4. Start m7.daemon-detach through the same trusted policy-injection composition
   join as the fixture chat wrapper, in its daemon host. Hold V4's pinned FIFO
   invocation while the driver records its connection closure and successful
   reattach response. The observer is a second, observer-role daemon connection
   using the existing attach, snapshot and replay protocol. Join those host observations to the independent observer's
   committed cursor and same-run active snapshot before release. Detach and
   reattach are connection facts, not committed session events; the session
   observer proves that the original run stays active across the join. Verify absence
   alone did not cancel the run. Hold expiry fails; a fast model cannot erase
   the precondition, and no fake reply supplies the oracle.
5. When recovery reports an unknown effect, preserve the root for inspection.
   Do not demonstrate recovery by blindly repeating the request.

#### V10. Record the coding-task result and clean up

1. Collect the authoritative fixture attempts from their owning scenarios;
   do not execute them again for this step or to fill a missing evidence slot.
   Inspect the external repository/task pin chosen during testing before the
   full invocation; it already records base SHA, allowed paths and objective checks. Create its disposable checkout,
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
   configuration, role snapshots and delegation declaration persist. Edit every
   child/aggregate allowance field and try conflicting `--no-helpers`: file
   changes do not replace retained limits, explicit disable refuses, and a new
   run uses the same declaration with only its own fresh counters. Apply a permitted explicit
   `/configure` change and verify it affects only the next run.
   Automated prepared-recovery subcases start with unfinished work, change or
   omit the file's cleanup period, and omit, match or conflict with an explicit
   cleanup flag. Assert the retained value and observation bounds. A conflict
   safely abandons the prepared owner before refusal; failed abandonment stays
   unconfirmed. Both conflict paths dispatch no recovered work. Include all post-prepare
   conflicting flags, workspace mismatch, pending-interaction policy mismatch, a
   missing route, absent bindings on non-task roots (helpers disabled), and
   missing bindings on task roots (activation refused).
5. Refuse in-flight changes and immutable tool/catalog changes. Confirm legacy
   one-shot defaults and unattended behavior remain unchanged; the default model
   selection is the same model, now sent as its dated literal identity.

#### V13. Upgrade and supported rollback

The [pre-1.0 maintainer override](../developer/agent-context-map.md#disposition-pre1-current-contract-2026-10-02)
retires the historical upgrade, old-reader and cross-version rollback work in
this retained specification. Current-format backup/restore, complete manifests,
separate workspace restoration and unknown-effect nonredispatch remain required.
The removed historical runner is no longer a current check or selector.

Use the updated client/server pair for M7. Inspect the retained negotiation
cases first: old-only offers receive `unsupported_generation`, the correct new
offer succeeds, the wrong server's generation refuses, and a digest mismatch
stops the client before session requests. These wire checks are separate from
the old-root reader and frozen-tool checks below.

The rollback lane stages three immutable archives/projections/source identities:
exact v0.2.0, exact published v0.3.0 and the candidate. Build each independently
with isolated dependency/build paths and its recorded compatible toolchain. The historical v0.2.0↔v0.3.0 pair uses its
pinned v0.3.0 driver, worker and assertion bytes; M7 changes to shared driver
files cannot silently alter it. The added v0.3.0↔M7 pair uses candidate drivers
with separately pinned identities. Extract v0.3.0's driver/worker/archive-check
bytes and invoke that driver from its own extraction with both historical
archives; its source_dir therefore names that extraction. Its guard receives
exact v0.2.0 as old and exact v0.3.0 as new. The candidate driver has a separately
versioned two-pair grammar, rather than passing v0.3.0 into the old-only guard.
Its worker paths explicitly select the driver extraction for each pair. Retain
all driver/build/executable/toolchain digests and preflight those builds before
credentialed cases.
The lane preserves every historical assertion and adds the new pair. Plan
acceptance explicitly retires the old v0.2.0-to-current-candidate pairing: the
frozen v0.2.0↔v0.3.0 pair proves historical compatibility, and v0.3.0↔M7 proves
the new upgrade/rollback boundary. It no longer claims that candidate changes
are read by v0.2.0. Record this change in what the check proves in the context
map and update the verification guide with the implementation. The existing
`rollback` selector is re-pinned from v0.2.0↔candidate to the frozen
v0.2.0↔v0.3.0 pair; m7-rollback owns the added pair
and joins the historical execution rather than running it twice. Selected
without `rollback`, `m7-rollback` runs the historical pair once as part of its
own lane. Prevent
old access by exact executable/build digest and launch configuration, not VERSION,
which may be identical. `m7.rollback` owns this credential-free release lane;
V13 inspects its retained results and performs the attended restore steps.
Private format metadata here means versioned records, not M8's future container
marker. Candidate-server release/Node cases migrate to the new wire clients;
only the historical rollback pair and its assertions remain unchanged.

1. `m7.rollback` creates settled and unresolved M6 roots, stops their owners and
   retains complete pre-upgrade copies with manifests outside the test roots;
   the operator records and verifies the retained M6 artifact, source,
   toolchain, digests and those manifests.
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
5. Verify complete manifest equality and inspect the pinned credential-free
   baseline execution produced by `m7.rollback` using the matching M6 artifact.
   Root contents and observable baseline must agree; this step adds no provider
   call or second execution of a real-task case.
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
| Backup/restore baseline | V13.1 record/verify, V13.4–6 |

Every required step names the operator as `Maintainer` or
`Delegate: <recorded identity>`, tested SHA, expected/actual result, objective
assertion and retained evidence. Implement `operator_step_evidence` in the
fixed fixture manifest before demonstrations. It lists every V1–V13 step and
subcase, its attended/automated classification, exact lane/test ID, oracle and
evidence slot. Each provider-backed step/subcase names its owning case ID and
execution-record slot key. The committed manifest contains only fixed mapping
and specification bytes, never actual post-run identities. The runner writes
actual attempt/session/run/child identities, outcomes, operator identity and
verdict to fresh retained execution records outside the repository; each record
binds its case ID and manifest digest. The scaffold predeclares one Pending row
per manifest step/subcase key, including V11.1.flag/file, V11.2.flag/file and
V11.5.flag/file/json joined to their trace execution records. The integration owner implements `mix loopex.m7_evidence`, invoked by the
existing fast check unconditionally before its --docs early exit, and by the
release check inside the fresh-source extraction, after that extraction's build
and before the first case of any later lane. The commit that adds the task
adds the manifest and a Pending scaffold skeleton at their canonical paths; from
that commit on, absence or renaming fails rather than silently skipping. It requires those key
sets, exact case ownership, profile sets, oracle IDs and lane/classification
mappings to agree before any provider demonstration. This is a task inside the
existing check, not a third check command. Filling scaffold values uses
retained records and never edits the manifest after execution. Several steps may reference one execution; each
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

- candidate/source identity, tested implementation SHA, run platform/architecture
  and full toolchain pins; a closure-incomplete platform result remains incomplete;
- floor/current-pair run identities, outcomes, measured durations and complete
  retained-output references/digests, including reused CI evidence where allowed;
- the tested fresh-source archive manifest's exact retained bytes/reference and
  digest, under the existing archive-extraction procedure;
- every outcome and operator step/subcase, operator identity, attended-answer
  authority and the manifest's exact lane/test-to-step mapping;
- fixture manifest, prompt, runner and immutable oracle digests; every task's
  objective result and duration/turn/token/maximum-reply measurements;
- fixed rows for every demonstrated profile key from the committed manifest;
  exact resolved roots/catalogs and instruction/tool/environment/role cost
  measurements fill only those Pending values, never introduce new profiles;
- immutable A/B provider/model/mode pins, per-case mapping/renderer revisions,
  selected credential-variable-name-set pin and credential-free routing metadata;
  the selected-name redaction self-test outcome and retained-output reference/digest;
- both protocol schema/vector manifests and independent Node consumer results;
- upgrade/old-reader/restore lane identities, complete manifests and exact M6
  artifact identity, plus the external task's pre-attempt pin described below;
- security, independent and documentation review identities, conclusions and
  complete retained-report references/digests;
- every case's verdict, failed assertion/cause classification and execution-record
  reference/digest, plus predeclared earlier-candidate attempt/verdict/diagnosis and
  disposition rows. Before commitment enumerate the known prior attempts; no
  later closure child adds headings/rows outside its designated Pending slots.

The release command gains explicit `--pins FILE` input for the immutable A/B
and external-task pin object (or uses committed pins). Validate its closed shape,
path and digest before starting the matrix; it carries references, not credentials.
External-task selection may use credential-free inspection or local prerequisite
checks, but no unpinned paid model trial is authorized; every model attempt
belongs to its pinned counted case and complete attempts index.
The complete matrix execution log records the digest before its first dispatch,
then each case records its relevant pin digest. An external task chosen later
requires selection before the full invocation, not halfway through it.

The external repository/task remains selected during testing. Before any
attempt, write its complete pinned specification to an immutable retained
record under a fresh path outside the repository and task tree, with its complete
bytes, SHA-256 digest and UTC timestamp. The runner refuses reused execution paths
and records the pin digest before its first dispatch in the same retained,
digested execution log. That ordered record is the timing proof; an authored
UTC timestamp alone is not. Recheck the pin digest before dispatch and at case
completion. Reference the pin and log from predeclared evidence slots; filling
slots afterward alone does not prove prior selection. No pin changes within an
execution. Changing a used pin requires a new candidate
under the verdict/disposition rules above; it cannot replace or reclassify the
old result. A committed candidate fixture may instead
supply that pin when selection occurs before candidate commitment. Extend the
existing release runner, selectors, wrapper/redaction tests and the existing
PTY helper for the changed chat workflow. The current runner's fixed eleven
cases and one credential are implementation work, not evidence that new lanes
already run. The three fixed M7 lanes cover coding tasks, piped/attended chat,
thinking/tool continuation, A→B→A, conversation A/summarizer B, parent A/helper B
and M7 upgrade/rollback. Credentialed lanes declare
separate A/B references and redact all selected values; other lanes require no
new credentials. Preserve all existing required lanes and failure honesty.
Both A and B are admitted hosted credentialed routes for the durable examples;
M7 adds no durable local-provider support. Pin their exact models, reasoning
mappings, renderer revisions and selected credential variable names in the
committed manifest or the same immutable pre-dispatch pin mechanism before the
attempt. Names are host-only evidence, not public configuration or credential
values. The runner records their digest/identity with each case and passes the
complete selected-name set to its redactor and PTY driver and
self-tests with every canary, including non-default names. Redaction cannot
remain a fixed four-name list. The new lanes are required in the full
closure release matrix; `--only` selects pre-merge evidence, not an exemption
from closure. `m7.cross-provider-maintenance`, distinct from `m7.long`, pins an
always-on conversation model and an explicit thinking-off summarizer, including their exact mappings. A switching
model needs no thinking-off capability merely because it is provider B; the
configured summarizer must have it. Switching alone proves no compaction capability.
ADR 0044's initial Claude matrix pins `anthropic:claude-haiku-4-5-20251001`
for manual/default and thinking-off maintenance cases, and
`anthropic:claude-fable-5-1` for the always-on adaptive conversation case.
Their exact outgoing mode, display and reply-limit vectors precede integration;
catalog presence alone proves no support. After per-cell deterministic conformance, the tested bytes register all nine
ADR 0044 cells for ordinary host resolution. Their fixed per-cell witness keys
belong to the existing counted cases and must all pass on that candidate before
closure. The manifest lists every key, explicit limit and owning execution slot;
no later registration edit, candidate-only override or extra calibration is
allowed. Failure keeps the fixed disposition and attempt accounting. The release manifest retains these mapping/renderer revisions
with each selected case. This does not choose the
separate hosted provider B or replace its required pre-attempt identity pin.
Provider B's summarizer must have a registered thinking-off row in the tested
bytes; the pre-dispatch pin selects only among registered rows. B's switching
and helper models may be unregistered and then run under ADR 0044's generic
descriptor at `default`. A model with a registered row runs only its registered
levels, so the summarizer's model cannot also serve as an unregistered
switching or helper model at `default`.

<a id="technical-plan-acceptance-issues"></a>
### Internal review disposition and audit targets

Concept: [Design decisions](M7.md#concept-plan-decisions).

The first internal implementation-readiness review corrected the following
proposal contradictions. The [external round 1 assessment](../evidence/M7-external-review-1.md)
then identified additional gaps. This revision records their repairs, with the
selected bounded thinking continuation and stop-only helper recovery included.
The [follow-up record](../evidence/M7-continuation-review.md) binds their review.
The [round 2 disposition](../evidence/M7-round-2-disposition.md) tracks each
subsequent finding, measured limits, selected choices and repairs. Its
[whole-packet internal review](../evidence/M7-round-2-disposition.md#whole-packet-review)
is complete, including repair rereads with no remaining planning blocker from
that pass.
The [round 2 assessment](../evidence/M7-external-review-2.md)
then rejected candidate `10749d08` for additional feasibility and closure gaps.
Its claims have been dispositioned through source-backed checks, bounded
prototypes and that fresh adversarial pass. The subsequent [round 3 assessment](../evidence/M7-external-review-3.md) of
`a4c9061e` supersedes that readiness conclusion. The [round 4 assessment](../evidence/M7-external-review-4.md)
of `018c271c` supersedes round 3's repaired readiness conclusion. Its 55 findings
and renewed internal review are tracked in the [round 4 disposition](../evidence/M7-round-4-disposition.md).
The [round 5 assessment](../evidence/M7-external-review-5.md) of a2ce04c2
supersedes round 4's readiness conclusion. Its 50 findings, both maintainer
choices and renewed internal review are tracked in the [round 5 disposition](../evidence/M7-round-5-disposition.md).
The [round 6 assessment](../evidence/M7-external-review-6.md) of 07b1a19c
supersedes round 5's readiness conclusion. Its 37 findings, three maintainer
choices and renewed internal review are tracked in the [round 6 disposition](../evidence/M7-round-6-disposition.md).
The [round 7 assessment](../evidence/M7-external-review-7.md) of 6f8d4759
supersedes round 6's readiness conclusion. Its four findings and renewed
internal review are tracked in the [round 7 disposition](../evidence/M7-round-7-disposition.md).
The [round 8 assessment](../evidence/M7-external-review-8.md) of 9392e19d found
one remaining Concept/Technical wording mismatch. It and the final internal
readiness review are tracked in the [round 8 disposition](../evidence/M7-round-8-disposition.md).
The [round-9 readiness review](../evidence/M7-readiness-review-9.md) of a234247e
then examined the whole change since the round-8 candidate, including the latest
internal repairs. Its two contract mismatches and one optional clarification
are repaired in the [round-9 disposition](../evidence/M7-round-9-disposition.md).
The repaired packet's recheck and clean-candidate documentation validation are
bound by the final receipt. The maintainer then accepted the exact packet in the
[recorded disposition](../developer/agent-context-map.md#disposition-m7-acceptance-2026-09-30).
These are planning reviews, not product evidence or formal independent closure
review. The acceptance transition updates the roadmap and project README
alongside the coordinated governance records.

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
| Closed reasoning level in configuration | Every host, configure command and recovered run must agree on one bounded durable setting; the host resolves a bounded mapping descriptor, core validates its declared gating data, and adapters translate native provider controls |
| Private continuation envelope and settlement | Exact request replay and atomic reply/tool admission must agree on retained provider data; adapters interpret its content |
| Compaction state/checkpoints | Maintenance accounting, checkpoint transactions and staging are serial session truth |
| Model-question transitions | Answer/expiry/cancel must atomically settle the original call and release the durable interaction slot |
| Optional absolute deadline | A child owner must stop even while its host adapter is unavailable |

Roles, credentials, catalogs, allowances, helper routing, fixture policy and
terminal behavior stay at the edge. Any further review should challenge these
repaired contracts and the outcome-to-proof mapping. Exact fixture paths/content/prompts and the external repository task are
implementation/testing deliverables, fixed before their demonstration attempts.
The external target remains deferred by the maintainer. The prerequisites are
now accepted; no successful product run or completed milestone is asserted by
this planning record.

<a id="technical-plan-ownership"></a>
### Workstreams and Rejoin Order

Concept: [Workstreams](M7.md#concept-plan-workstreams).

| Phase | Work and rejoin condition |
| --- | --- |
| 0. Specify | The coordinated contracts are accepted. Build the task fixtures and executable scenario commands from the fixed grammar; pin the literal read capability table and schema/vector/fixture manifests under the integration owner |
| 1. First complete workflow | Reproduce lost cross-run history, then implement continuity and host instructions under one owner. Integrate a minimal conversational command and prove two prompts plus restart |
| 2. Long-lived work | Add compaction under the same projection/staging owner. Integrate model/reasoning configuration, private continuation and atomic reply settlement; prove frozen-prefix tool exchanges, maintenance thinking-off and canonical history after a change; own provider-B mapping/renderer conformance before its first pinned attempt |
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
and catalog recovery, `Runtime.effect_intents/4`, `Runtime.creation_provenance/2`,
`Runtime.lookup_create_result/4`, the read-only Store provenance callback with complete runtime paging and
shared pure `SessionGenesis.resolve/2` / `normalize/1` and exact-genesis live
create variant, with their conformance; the owner unknown-admission transaction resolver and
observational command_disposition facade; both protocol servers and payload-schema digests; the
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
  estimator revision, context-provider receipt revision 4, versioned refusal/failure
  projections and private/public projection,
  question producer/text/decline records,
  host role/allowance ledger including monotonic stop records and its disposable
  version-1 derived job-index directory with its coverage entries, read-only Store creation_provenance/3 callback and derived
  stable runtime-create ordinals, generic absolute deadline ceiling on prompt/follow-up,
  request and normalized-command revisions, events, snapshots and negotiated
  protocol generation. Each has versioned vectors and an explicit unsupported-reader
  behavior; version each changed record before emitting it. This does not introduce
  M8's future container-format marker. Include child sessions in the inventory.
- Upgrade fixtures include actual M6 roots with settled and unresolved model/tool
  operations. Preserve staged requests and resolve uncertainty without redispatch.
- Downgrade tests use the exact retained M6 binary on disposable copies. Do not
  claim that it recognizes a future marker or error. If it cannot safely refuse
  a new root, the supported procedure is to prevent that binary from opening the
  root and restore a quiescent pre-upgrade backup with the matching binary.
- A legacy root with no new records may reopen only if the exact fixture proves
  it. Normal M7 startup may already write new configuration; no broad backward-read
  promise follows from an unchanged storage container.

Prepared chat startup facts now constrain the selected policy identity/revision
and every admitted model's provider route before activation, with no credential
or current catalog lookup. Pending and answered questions retain exact facts;
refusal abandons without reevaluation or executor/provider dispatch. Recovered
answered-policy scheduling applies the existing recovered-run pause, including
prepared, abandoned and fenced capabilities. Matching-policy activation has a
positive reevaluation and exact worker-join witness. The public chat host now
joins that preparation with exact creation, session-directory tracking, effective
reporting, driver readiness and guarded signal activation. Both supported pairs
prove the built startup/quit path with actual composition and no provider request,
plus scripted two-prompt/restart/refusal/cleanup paths. Closing follows diagnostic
joins, composition cleanup, placement release and signal finish. Built multi-prompt
provider, attended, maintenance/helper integration and closure evidence remain open.

Automatic ordinary-limit episode admission now has a closed private reducer
record, frozen maintenance model/instructions and derived input/system limits,
parent spending bounds and the fixed admission + 60,000-ms preparation cutoff.
Replay checks identities and derived captures against retained run truth; owner
succession cannot renew the cutoff. Admission opens no attempt, publishes no
event and blocks ordinary model staging and bare run terminals while active.
Run-owned endings now prepend an episode terminal whose transient marker applies
only with the complete existing ending transaction. Both-pair tests refuse
partial, interleaved and forged history; expired source preparation retains and
replays its fixed clock observation without inventing a run deadline or numeric
failure. An earlier or equal run cutoff keeps its own bound measurements. Live
expired-preparation and undispatched-abort recovery use the existing owner commit
fence; fault tests join an unresolved owner exit and a successor with no duplicate
ending or provider dispatch. These use the existing test Store adapter and do not
replace real-Store/checkpoint evidence. The live owner does not invoke admission
yet; not-yet-expired source dispatch, its worker/timer cleanup, automatic and
standalone attempts, maintenance settlement/usage, checkpoint commits and complete
abort/deadline precedence remain unproved.

The existing ProviderAttempt and Control boundaries now admit a separate closed
maintenance attempt-open identity: episode, summary ordinal, compaction purpose,
operation, attempt and staged digest. Control rebuilds it from the exact current
journal row before its one-use send; a supplied identity alone grants nothing.
Effect-history scans validate these rows and advance coverage without fabricating
executor effects. Both-pair focused tests cover mixed/changed identities, stale
positions, deadlines, repeat sends and exact fixture process joins. This is the
permit boundary, not a live episode/request reducer or summary dispatch proof;
the complete episode spending/accounting gate and maintenance settlements remain open.

The owner now binds a maintenance request to the episode's actual admission
journal position and complete normalized original-record provenance. The covered
integrity digest deduplicates originals by journal position and hashes their
position, full-record digest and measured cost in journal order, with the
`loopex.compaction.covered_records.v1` domain and unsigned 64-bit length framing.
The source envelope digest separately binds the exact projected JSON bytes.
Each whole unit projects lazily at `q=0`; prefix/excerpt choice preflights the
complete receipt-bearing request record, including range identities and resource
headers. Maintenance retains exactly two descriptors, its captured instruction
and source, with no optional resource intake. Its fixed-point cost and strict
system/input/structure/byte admission use existing boundaries. The private
`maintenance_request_committed_v1` and `maintenance_attempt_opened_v1` rows form
one proposal. A partial or interrupted pair cannot complete recovery or spend
an attempt; the open row alone commits the first request deadline and increments
the episode attempt counter without an ordinary turn or assistant message.
Captured parent capacity, preparation expiry, cancellation and protected-unit
checks refuse before intent. A pure tail selector now releases terminal units
oldest-first through complete-candidate fit probes, preserves protected units,
releases all eligible units for explicit origin, and grows only unreleased tails
within the 2,048-token preference. Configured ordinary staging and the q=0
ordinary-limit probe now share the request/receipt constructor and full record
sizing, preserving fixed inputs, frozen context, empty resource headers and
cancellation. Thinking targets, captured rendering offenders, prior-checkpoint
substitution and live triggering still need the owner join.
Maintenance settlement now retains valid summaries pending checkpoints, charges
exact or conservative usage once, preserves abort/deadline precedence and permits
only the one exact not-dispatched retry. The first-checkpoint pending-substitution
probe authenticates original coverage, renders summary provenance and requires
strictly lower exact ordinary record bytes and estimated tokens, preserving
captured steer through owner succession. The first checkpoint now commits with
its event through the reducer, which recomputes coverage, summary, metadata and
progress on replay. Projection substitutes exact covered source identities and
retains every later raw element; original reads remain unchanged. Fitted episode
completion releases ordinary staging without a parent ending or second charge,
while partial progress remains active and survives cancellation. The private
history reader traverses checkpoint and completion without activation. Live
successors finish inherited lost attempts and invalid/incomplete summaries
without redispatch, including all three Store uncertainty phases and exact owner
joins. Live successors also finish pending/committed first checkpoints through
all three uncertainty phases, with no ordinary dispatch while fenced, one
summary charge and one captured ordinary continuation. Abort/deadline and spent
parent bounds win, retaining previously committed checkpoints. Measured
non-progress endings now authenticate the last minimum ordinary projection and
commit the episode, refusal and parent ending together, including all three live
uncertainty phases and private-reader traversal without redispatch or recharge.
Further-prefix reducer/reader proof now retains the exact prior checkpoint,
separate consumed and cumulative coverage, original-record integrity digests and
inherited omission. New ordinals preserve the original capture and deadline;
physical retries spend the four-attempt ceiling, and later non-progress retains
the useful prior checkpoint. Fitted substitutions refuse summary-only cycles.
The exhausted-episode reducer now rebuilds the last minimum ordinary candidate
and retains its numeric refusal with episode and parent endings, preserving
useful partial checkpoints and settled usage. Replay refuses altered measurements
and removal of the episode identity; ordinary refusals require no active
maintenance. Abort/deadline precedence and current-format replay pass both pairs.
Live exhausted recovery also proves all three Store uncertainty phases, prepared
pause, exact fenced-owner succession, one adjacent ending, unchanged partial
checkpoints and no redispatch or recharge on both pairs.
Live retained source preparation now uses a supervised pure-proposal worker,
exact DOWN, cutoff and current-version checks before request/open commitment.
Newly adopted summaries dispatch their retained request and closed maintenance
identity through Control and the existing provider cleanup; raw summary deltas
stay private. First preparation and further-prefix tests cover all three staging
uncertainty phases before captured ordinary continuation, preserving prior
checkpoints and settling unresolved inherited attempts without redispatch.
The live ordinary-limit trigger now reads the measured v2 numeric failure,
proves a releasable complete older unit with the same q=0 ordinary request and
commits the frozen episode before source work. A recovered prompt then completes
the actual summary, checkpoint and ordinary continuation. Missing summarizer
settings commit the accepted named pre-intent v2 failure, and irreducible
current input keeps its numeric refusal without a model call. Both supported
pairs pass focused recovery and surrounding source/protocol tests; the preceding
911f26c7 candidate passed its exact full current-pair fast check. Thinking and
rendering triggers, remaining preparation errors and standalone compact
remain open.
The source worker now proposes the accepted named excerpt-budget refusal when
no complete or fixed-quota excerpt fits. Its episode terminal, v2 refusal and
parent terminal commit together before provider intent. Replay reselects the
frozen source at the retained clock. A live automatic case and pure replay
mutation checks pass all 87 maintenance staging/recovery tests on both pairs;
the current/floor complete outputs and digests are indexed in the task checklist.
An already-admitted protected tail that cannot fit now retains its measured
numeric v2 refusal, including token or record-byte observation. The first
source boundary derives the same run deadline that request staging would use;
later boundaries preserve the useful checkpoint. Replay remeasures the exact
protected candidate and a live resumed owner commits only the adjacent ending.
The updated 91-test current/floor results are indexed in the checklist.
Captured summarizer instructions that reach their parent system ceiling now
produce a measured maintenance-scope v2 refusal before source traversal. The
single frozen system descriptor fixes its count, estimate and digest; replay
rederives them without provider work. A live automatic ending and both-pair
92-test maintenance selection pass are indexed in the checklist.
Lost source workers now join before the existing unavailable refusal and
adjacent episode/parent ending. Replay proves the eligible source phase and
retained observation clock. Both initial and later source phases pass all three
Store uncertainty cases and cancellation, preserving checkpoints and usage
without redispatch. Durable succession joins the held worker and predecessor,
leaves only the new owner claim while paused, then completes one summary and
ordinary continuation using the frozen capture. The three focused maintenance
files pass 119 tests on both pairs. Two long-bound cases wait the original live
60,000-ms preparation or committed run cutoff without clock/timer replacement,
join the worker and preserve the distinct preparation-failure and deadline-bound
endings; both pairs pass. Existing grouping, source and original-record tests
also pass 97 cases on both pairs, closing original T07's complete eligible-group
selection item. Complete outputs and digests are indexed in the implementation
checklist. New ordinary exchanges now apply the exact thinking headroom
rule inside the shared fixed-point admission path, allocator, optional intake,
tail measurement and checkpoint completion. Episode capture retains the trigger
and derived targets; replay validates both and repeats request admission for
ordinary/resource records. Hard ceilings remain first, while open exchanges
retain their native prefix and use hard ceilings. Live cases prove initial
no-dispatch refusal, optional project withholding, continued preparation after
one hard-fitting checkpoint and reserve spending by an open exchange. All 207
focused cases pass on both pairs; complete outputs and digests are indexed in
the checklist. The original native-prefix protection item is also proved:
any frozen source protects its whole unit, projection preserves exact messages
and ranges, and open continuation blocks maintenance admission. Live cases
cover excerpts, project/resources, queued steer and owner restart. Forty-three
Conversation/Lineage tests pass on the floor. The full current-pair fast check
of `1022eea77a626b27f6e4c2b3461f3fbe29d11bf0` passes all eleven suites,
3,573 tests with 39 expected exclusions, in 925 seconds; its complete output
and digest are indexed in the checklist. This is integration evidence, not
the closure matrix. Rendering-trigger capture, remaining preparation errors,
standalone compact and the real long-conversation proof remain open.
This is not a complete T07 workflow proof.

Standalone command admission now retains only its explicit three-field bounds
and command-derived episode identity, without a clock, prompt, run or episode
capture. Duplicate-first input fences and episode-bound abort replay through
owner succession. The live paused-owner cases resolve all three Store
uncertainty phases once; bounded private coverage reports no effect or completed
checkpoint. The seven-file selection passes 172 cases on both pairs after the
expiry repair recorded in the task checklist. Standalone episode capture,
source/dispatch/spending, checkpoints, completed result/snapshot, abort cleanup
and runtime quiescence remain open. This proves command admission only.
The existing question-deadline test now also proves that an early timer notice
cannot settle before its retained wall-clock cutoff. The handler re-arms against
the same instant, preserving the original real two-second bound and complete
ending/replay assertions. The task checklist retains the deterministic red run,
the earlier failed floor selection and subsequent focused evidence separately.
The clean `9ab1ede347484cc65f9f7a62678533eb66e43d1b` integration commit now
passes its full current-pair fast check: all eleven suites, 3,586 passed,
39 expected exclusions, 912 seconds. This includes the complete Core suite
after the expiry repair. The immutable output and digest are indexed in the
checklist. It does not establish standalone episode capture or execution and
does not replace the closure matrix.

Standalone probes now use an explicit transient session scope in the existing
lineage, unit and projection paths. They include all original runs in order,
substitute retained checkpoint coverage and protect unfinished/native work.
The shared canonical request/receipt constructor uses current committed settings
and a supplied absolute cutoff while admitting no invented run, steer,
continuation or fresh optional intake. This constructs an unsized candidate;
whole-record measurement and episode capture remain open. Original-record,
checkpoint, native-prefix and configuration-restart tests pass on both pairs;
the final source passes the complete current Core suite, 1,121 tests with eight
existing exclusions in 215.2 seconds. The checklist retains all outputs and
digests, including the corrected new receipt assertion's failed first run.
This does not establish live standalone execution or completion.

Standalone preflight now measures the exact deterministic Store fixed point of
its transient command-bound request/receipt/projection view. This seven-member
view is outside the journal grammar and has no run/turn/operation identity;
ordinary staging continues to use its existing durable record and the same
hard-limit preflight. Standalone probes apply hard ceilings without thinking
headroom or continuation. Explicit selection releases every eligible terminal
unit even when the current model fits, retains the prior checkpoint, and pins
the last original offending assistant source for rendering-only repair.
Numeric and structural refusal precedence, interruption during whole and
minimum-tail work, empty history and unchanged raw provenance pass the final
174-case selection on both supported pairs. The checklist retains complete
outputs, digests and failed development assertions separately. The same source
passes the complete current Core suite, 1,133 tests with eight existing
exclusions in 213.2 seconds, and the static compilation/format/status/documentation/
dependency/version gates. These are development checks, not the complete
exact-candidate fast check or closure matrix. Episode capture,
dispatch/spending, result/snapshot and cleanup remain open; this measurement
and selection does not claim any completed standalone workflow.

Standalone episode admission/replay now retains the command-derived identity,
exact explicit declaration, captured current configuration version, measured
trigger, original rendering offender, frozen maintenance configuration and one
admission-time absolute deadline. The new closed private row omits run,
staging-turn and preparation-cutoff fields; its journal stamp supplies the
captured session version. Replay reconstructs its exact members from the
preceding durable state, while a retained episode wins before new host settings
or clocks. Empty fitting history requires no summarizer. Clock overflow and
cancellation admit no episode. Both-pair selection covers all three standalone
triggers, declaration endpoints, rehashed substitutions, owner succession and
bounded one-record private-history traversal without effects. These constructors now join initial live owner capture as described below;
standalone summary dispatch, spent results, snapshots and complete cleanup remain
open. The reply-reserve decision is approved and implemented as recorded below.

Empty fitting standalone commands now produce a durable unchanged completion
proposal with no episode or provider attempt. The accepted five-member result
and exact completion event share one transaction proposal. The completed result
is retained beside its admission binding, wins on duplicate lookup and releases
the pending slot; admission observation still reports the original acceptance.
Replay repeats the empty fit and refuses forged results, identities, duplicate
completion and missing events. Both-pair focused checks and bounded private
coverage prove the new row and cancellation points. Live initial scheduling,
Store uncertainty and zero-attempt failed/cancelled results now join this path.
Completion snapshots remain open.

The owner captures one admission-time clock and absolute cutoff before its
supervised initial preparation. The worker produces only a pure proposal; its
exact DOWN and unchanged journal version precede commitment. Prepared successors
pause recovered compact identities, while fresh post-preparation commands can
progress without an ordinary model. Empty fitting history completes unchanged
without summarizer settings. Missing or unsupported summarizer settings complete
failed before an episode or attempt. Worker loss, cancellation and actual cutoff
expiry join the exact worker before zero-usage, confirmed-cleanup completion.
An admitted zero-attempt episode closes only with its leading terminal and
compact completion in one transaction; replay rejects an incomplete prefix,
changed result/clock and nonzero usage. The bounded private reader rejects a
checkpoint or unknown cleanup in that undispatched completion generation.
All three Store uncertainty phases retain one capture, fixed deadline, result
and public event across exact owner succession; duplicate lookup preserves the
completed result. The task checklist retains both supported-pair results and
the Core/static development runs. Live standalone summary dispatch, successful
checkpoint completion, snapshots and complete runtime cleanup remain open.

Standalone source proposals now reuse the shared encoder and fixed-point Store
measurement under their actual command and whole-session scope. The adjacent
maintenance request/open pair retains the original cutoff and frozen selection;
opening it creates no run deadline, pending work or run accounting. All released
eligible history has a null first-kept identity, which the bounded reader accepts
only when the covered and eligible counts match. Both supported-pair tests prove
exact replay, incomplete/forged pair refusal, oversized-unit excerpt selection,
fixed reserve and cancellation. Live dispatch and settlement/checkpoint adoption
are still open; the task checklist retains the complete development outputs.

Standalone settlement now uses the existing maintenance attempt kinds and its
captured episode allowance. Reported usage retains exact overshoot; dispatched
failures and unreadable replies conservatively charge the remaining allowance.
Not-dispatched settlement charges no tokens and permits only the existing single
retry within the captured attempt ceiling. Failed attempts commit the episode
terminal first, then settlement and compact completion together. Full replay
rederives the result, preserves winning termination and rejects incomplete or
substituted pairs. Unknown owner-loss cleanup remains unknown. Cancellation or
expiry after a settled retry/summary retains usage without another settlement.
The bounded reader validates spent failures without effects. Both-pair tests
cover these reducers/readers; live standalone dispatch, successful checkpoint
completion, snapshots and runtime cleanup integration remain open.

Standalone pending checkpoint substitution now uses the same command-owned
whole-record probe, fixed-point receipt and captured cutoff as initial preflight.
It authenticates original coverage, prior checkpoint and source omission. Explicit
and size triggers require strict byte/token reduction; canonical-rendering repair
advances a contiguous raw cut and fits every ordinary hard limit while allowing
growth. Non-progress retains settled usage in the existing terminal/completion
pair without another settlement, charge or checkpoint. Both supported-pair tests
prove exact cost, actual rendering growth and hard overflow, clock/range refusal,
abort/expiry and cancellation at every probe stop. These are pure measurement
and replay proofs; the pending checkpoint-owner schema decision and live
standalone dispatch/checkpoint/completion integration remain open.

Live standalone source/dispatch/failure integration now uses the tagged actual
command key only in transient worker, adoption, permit and cleanup maps. Durable
requests retain the authenticated episode/summary operation identity; no run,
run deadline, ordinary stream or run accounting is introduced. Source workers
use the captured episode cutoff and propose against one retained journal head;
exact DOWN precedes adoption. The shared Control permit and provider guard
perform actual callback dispatch and cleanup. Named excerpt refusals retain nil
measurement scope; frozen system overflow retains exact maintenance-scope
measurements. Both complete with zero attempts before provider intent.

Invalid and non-progressing summaries retain reported usage once. One proven
not-dispatched retry reuses the same request; actual abort and expiry collect
late usage and join the provider callback/tree. Useful summaries remain pending
under the original cutoff until the checkpoint-owner decision; expiry ends them
without another settlement. The attempt owner epoch is derived from the existing
authenticated journal stamp at open, adding no persistent field. A successor
cannot confirm predecessor cleanup, including when its new abort/deadline wins
over owner loss. Prepared inherited attempts remain unchanged after their cutoff
until activation, then end with conservative spending and unknown cleanup.
Twenty new live cases prove these paths, source-worker loss/abort/deadline joins
and all three Store uncertainty phases for request/open and failed settlement.
The ten-file selection passes 302 cases with two existing exclusions on both
supported pairs; complete outputs, development failures and the floor test
warning repair are indexed in the implementation checklist. The complete current
Core suite passes 1,217 cases with eight existing exclusions in 216.2 seconds;
warning-free compilation, formatting, bootstrap/status, compiled documentation,
dependency and version checks also pass. These are development proofs, not a
full fast check of these bytes, provider lanes or closure matrix. Successful standalone
checkpoint emission, continuation/results, snapshots, complete runtime cleanup
and real-provider evidence remain open. No complete T07 workflow is claimed.

The full current-pair fast check of clean `14a54d1f` failed the artifact-abort
fixture's 1,000-ms initial retention receive. Ten other suites passed; Core
passed 1,216/1,217 with eight exclusions. A controlled held-predecessor probe
shows that the old receive measured a permitted preceding executor callback,
then proves original-bound retention and abort cleanup after its explicit
release. The live fixture now uses that existing progress gate, its declared
5,000-ms prerequisite allowance, and proves no receipt or artifact IO before
release. Original retention/commit waits, exact DOWN assertions and actual
1,000-ms run / 60,000-ms preparation cutoffs remain unchanged. The complete
artifact file and four surrounding files pass 50 cases with one existing
long-bound exclusion on both toolchains. This is focused fixture evidence;
the failed candidate remains failed and the next committed candidate needs
its own full integration check. Complete outputs and digests are indexed in
the implementation checklist.

The clean repaired candidate `6635cb490c978030b9b163fe40f347dbf9db19d4`
then passed its single full current-pair fast check across all eleven
applications: 3,686 tests passed, 39 expected exclusions, 924 reported check
seconds and 923 independently captured shell seconds. Complete immutable output
and SHA-256 are retained in the task checklist. The failed parent stays failed;
this proof covers only that exact repaired implementation and does not replace
the floor full check or release matrix required for closure.

Current model requests admit only `loopex.model_request.v2` with receipt
revision 4, its mandatory null/non-null continuation cost and current estimator.
Request v1 and receipt revisions 2/3 readers and the per-run lineage bypass are
removed. The historical lineage-projection cutover cache and fallback are also
removed; captured artifact capability requires exact projection provenance from
the first request, while current sessions without that capability keep their null
projection. Self-consistent old encodings refuse; current restart/source-binding,
resource class/header bounds and exact record-cost reservation remain required.

The model boundary now admits only eleven-field current v3 callbacks and
projects ten-field canonical replies. The obsolete public two-argument
projection and nine-field callback fallback are removed after migrating all
current producers, fixture callers, public reply types and conformance checks.
Raw Store admission precedes projection and usage classification, excludes only
exactly echoed request bytes and still counts all supplied usage/capsule data.
Current v3 settlement replay refuses retired kinds at every retry/terminal
position and retains exact source binding, once-only accounting and current
restart. Both pairs pass 416 selected cases with two real-provider exclusions.
Native array/string/order/ID/argument fidelity is compared exactly through the
shared expander, both renderer modes and actual streaming HTTP/buffered TLS
for all nine registered cells. A failed buffered predecessor is retained: its
one-byte key `k` collides with current completion `unknown`. The corrected
fixture proves that exact post-dispatch rejection and a noncolliding one-byte
success while preserving missing/empty/65,537-byte refusal, 65,536-byte success,
recursive echo rejection, host-request exceptions and exact cleanup. No screen,
credential bound, stop table or deadline changes. Complete outputs, AST audit,
static checks and original T08 proof mappings live in the task checklist;
counted real-provider demonstrations and complete M7 integration remain open.

T11's private retained-genesis codec now implements ADR 0046's exact
three-member object with normalized plain current v3 genesis, deterministic
uncompressed ETF, canonical padded base64 and the original-byte SHA-256. The
65,536-byte core payload limit applies before safe, complete-consumption
decoding; the shared genesis validator owns all nested settings checks. Both
actual toolchain writers produced retained fixtures read by both pairs, and
an alternate valid ETF encoding proves readers do not require re-encoding
equality. Unsafe terms, compression, trailing bytes, malformed encodings,
input atom creation, changed schemas and exact size overages refuse. The
three focused composition files pass 28 cases without warnings on each pair.
Complete outputs and fixture/source identities are retained in the task
checklist. This prepares parent/child retained objects; ledger framing and
closing credit, host bindings, allowance, routing, classification and live
helper execution remain open.

The single full current-pair fast check of clean `3aa21960` then executed all
3,696 assertions successfully with 39 expected exclusions, but ended FAIL after
925 measured shell seconds because composition's supporting genesis fixture was
not classified by its test discovery configuration. Adding that support-only
module to the existing explicit ignore list removes no test case or check; the
codec test continues to require it, and the same 28 focused cases pass on both
pairs with warnings-as-errors. Complete failed output and repaired focused
outputs are retained in the task checklist. A new exact candidate must prove
full discovery; the failed candidate will not be rerun into green.

The combined clean callback/discovery candidate `bad9f220` then failed its
single full fast check after 924 measured shell seconds, with 3,695 passed,
one failed and 39 excluded. All ten other suites pass; Core's only failure
is a maintenance fixture that dynamically dropped the required completion and
continuation fields but still expected reported incomplete-summary evidence.
Current v3 correctly rejects the retired callback and charges the remaining
allowance atomically. The fixture repair retains
all seven readable summary controls and moves obsolete/missing-field replies
into the conservative-accounting, unchanged-conversation, no-checkpoint,
no-retry and exact replay proof. All 72 focused cases pass with warnings-as-errors
on both supported pairs, and static compilation, formatting, bootstrap/status,
documentation, dependency and version gates pass. The callback migration is
complete again; full integration on the new committed repair remains pending.
Complete failed and focused outputs are retained in the task checklist; the
failed candidate will not be rerun into green. Existing Task.Supervisor cleanup
diagnostics remain a separate open T16 investigation.

The subsequent clean pushed implementation `6058eb95` passes its single full
current-pair fast check: all eleven suites, 3,696 passed and 39 excluded,
916 measured wrapper seconds and 917 rounded check seconds. The added
callback/discovery integration obligation is complete. An external actual-runtime
probe joins held callbacks, task children, worker supervisors, owner groups and
roots for serial and concurrent normal owner exits, but the concurrent case
still emits three Task.Supervisor shutdown_error/noproc reports. Its diagnostic
assertion fails; the T16 cleanup investigation remains open. Complete immutable
outputs and both probe-source identities are retained in the task checklist.
The unchanged retained probe passes both cases on the supported floor pair
in 0.7 seconds without observing a diagnostic. This does not resolve the
current-pair failure; no production repair is claimed.

The [pre-1.0 maintainer override](../developer/agent-context-map.md#disposition-pre1-current-contract-2026-10-02)
supersedes the older-reader, upgrade and cross-version rollback bullets above.
The old archive runner, helpers and exclusive fixtures have been removed.
Current-format recovery preserves staged requests and resolves uncertainty
without redispatch. The operator stops all owners and prevents access to the
root during a quiescent backup or restore. Backups include sessions, runtime
control, artifacts, executor receipts, private continuation/recovery state,
catalogs and host ledgers. Restore into an empty root, compare complete
manifests and restore disposable workspace state separately. This procedure
does not implement M8's backup commands.

No installer, tag, publication or compatibility freeze is part of M7. A release
label is separately selected. Accepted historical plans and evidence remain
records of their own revisions.

The approved `maintenance_reply_reserve_unavailable` preparation cause now
ends eligible run-owned preparation before another summary dispatch. Exact
replay derives the positive unspent interval below 1,024, retained phase and
turn precedence; a fitted checkpoint cannot claim this cause. The existing
leading episode/refusal/run-terminal transaction retains actual usage and useful
checkpoints. Both-pair focused reducer/live checks pass 114 cases with two
existing long-bound exclusions; all three ending Store-uncertainty phases prove
no new summary or ordinary dispatch. Current terminal/compact codecs and their
independent pinned Node consumer pass 19 cases on each pair, including 158
terminal and 120 compact literal vectors. Exact bytes, development failures
and complete outputs are indexed in the
[task record](../evidence/M7-implementation-tasks.md#current-work). This is
focused implementation proof. The clean combined candidate `b4bee93b` now
passes the full current-pair fast check, 3,703 cases with 39 expected exclusions
in 925 seconds, and the selected Node release workflow in 373 measured runner
seconds. Its fresh-source archive and all four consumer lanes pass; complete
retained outputs, manifest bytes and digests are indexed in the task record.
The full closure matrix remains open. Approved standalone checkpoint ownership
and successful completion are now implemented. Run and compact checkpoints have
distinct authenticated private owners; public events share the closed opaque
owner codec. Both supported pairs pass 171 focused core cases, including
three-prefix repair, all six checkpoint/completion uncertainty cases, restart
and private coverage. Both transports and the independent Node owner vectors
pass their focused selections; exact outputs and digests are indexed in the
task record. Standalone pre-dispatch bound completion, full generation-3/4
manifests and checkpoint snapshots remain open. These focused results do not
replace the next clean candidate's full integration checks.
