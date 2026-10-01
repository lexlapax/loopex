<a id="technical-depth"></a>
## Technical depth

Concept: [Run model and reasoning configuration](0044-run-model-and-reasoning-configuration.md#concept).

<a id="technical-adr-0044-decision"></a>
### Contract

Concept: [Context and decision](0044-run-model-and-reasoning-configuration.md#concept-adr-0044-decision).

The closed configuration contains exact `model` string, `reasoning`,
`configuration_version`, `instructions` bytes/digest under ADR 0042, `max_tokens`,
`context_token_budget`, `system_class_tokens`, budget origins and the resolved
`model_capabilities` envelope and resolved provider mapping defined below. Initial legacy
fallback may be represented explicitly without rewriting prior requests.

One coordinated `session_genesis_v3` extends ADR 0016's v2 with this initial
configuration, full immutable tool definitions/name mapping and policy-defer
mode from ADR 0046. The closed payload is:

```text
{kind: "session_genesis_v3",
 options: normalized_session_options,
 runtime_configuration: {cleanup_grace_ms: positive_uint64},
 initial_configuration: <the closed configuration above>,
 tool_selection: {definitions: [<complete normalized definitions>],
                  names: <name-to-id/version/digest map>,
                  artifact_read: null | <ADR 0041 exact capability binding>},
 policy_defer_mode: "admit" | "refuse"}
```

Use the existing record envelope for journal version 1, owner epoch 0 and nil
owner incarnation; those are not extra genesis payload members. Definition
format versions distinguish legacy effect definitions from interaction-class
ones. Require each name mapping to match exactly one retained definition and
reject duplicates/unused mappings. Validate `artifact_read` under ADR 0041
against those exact retained definitions and its fixed table. This derived field
is not a create/configure option or a grant. Preserve mandatory committed cleanup.
Preflight the complete genesis against 65,536 bytes before create commits.
The M7 decoder explicitly reads v2/v3. Preserve v2 staged requests/effects;
resolve historical selections from retained evidence, rejecting contradictions.
For a settled session with no historical request, require an explicit host
selection and commit its migration before dispatch. An unfinished session
without sufficient evidence refuses unsupported recovery, preserving admission
and uncertainty; no invented default may dispatch it. Never infer helper status; legacy
policy uses `admit`. Missing cleanup remains invalid. Prove actual M6 reader
behavior on disposable v3 copies; no claim that the old binary knows v3 follows.

Active tools remain the immutable generation under ADR 0009; changing them is out of
M7's configure command.

**Closed ephemeral options.** This is the combined M7 amendment to ADR 0039's
startup grammar. `start_session/1` retains `policy`, `model`, `req_llm`, `tools`,
`skills`, `cwd`, `max_steps`, `deadline_ms`, `max_tokens`, `context_token_budget`,
`timeout` and `base_url`. M7 adds only `instructions`, `system_class_tokens`
(ADR 0042), `reasoning` (this ADR), `maintenance_instructions` and
`maintenance_model` (ADR 0043), `questions` (ADR 0045), `provider_bindings`
(ADR 0048) and `trace` (ADR 0049), with each owning ADR's grammar and defaults.
Unknown and duplicate options keep the existing refusal semantics.
`run/2` admits the same startup set plus one-shot-only `question_responder`,
consumes the function locally and forwards only startup data. `start_session/1`
rejects that responder; `ask/3` retains only its existing per-call `timeout`
option. Neither per-call settings nor arbitrary capability/mapping inputs can
override startup configuration. Composition resolves model metadata and mapping,
then the ephemeral owner forwards instructions/reasoning/ceiling into the shared
initial configuration and maintenance settings separately into runtime options.
Omitted instructions retain the compatibility fallback, omitted reasoning is
`default`, and the omitted system ceiling remains 1,000. Buffered transport,
credential audience and cleanup are unchanged.

`configure` is a normal idempotent session command containing any nonempty subset
of mutable model/reasoning/instructions/max_tokens/context_token_budget/
system_class_tokens. Merge against committed state, validate the whole candidate,
and commit one version or one unchanged refusal. Replayed identical command ID
returns its original disposition; different payload reuse refuses. The session
must be settled with no unresolved effect, provider attempt or maintenance.
Configuration preflight may report compaction required; it does not call a model
or compact as a side effect. The operator can use the configured summarizer to
compact before retrying configuration.

Host admission first checks controller authority and any host-owned ceilings.
Validation uses ADR 0048's admitted provider routes, declared model capabilities,
ADR 0041's window/reserve calculation and exact byte/token staging preflight with
the retained history and immutable active tools. Recompute derived budgets when
a model or reply reserve changes; explicit overrides remain explicit and must
still fit. A rejected candidate changes neither projection nor defaults.

The host normalizes the pinned ReqLLM/LLMDB catalog into bounded plain metadata:
exact model, optional positive context/output limits, verified reasoning subset,
source revision and digest. Core receives no dependency structs and performs no
catalog lookup. At most five reasoning levels and a 128-byte source revision
are admitted; the whole canonical metadata envelope is at most 2 KiB. Retain its
values and provenance with each configuration; replay never reinterprets a run
using a newer catalog. Public configure input cannot supply capability metadata;
the host resolves and validates it before committing the internal configuration.
A claimed reasoning level requires adapter conformance,
not just a catalog label. Require `max_tokens <=` the known model output limit.
Only an unknown context window uses ADR 0041's 8,192 input fallback; unknown
output capacity has no invented catalog guarantee. Existing explicit reply
limits remain enforced and visible.

Each new run and maintenance episode binds its configuration version at admission.
ADR 0043's runtime `maintenance_instructions` and explicitly resolved
`maintenance_model` are captured separately in the episode's maintenance
configuration. They are absent from session genesis,
ordinary configuration and public `configure`; recovery never substitutes a
new runtime block or model into an admitted episode. The ordinary configuration
supplies the parent version and applicable ceilings, not the summarizer's model
or provider mapping. Ordinary `configure` never mutates the runtime selection.
`reasoning` enters canonical sampling and digest when non-default; `default`
omits it. Existing committed request bytes and provider attempts remain immutable.
The ReqLLM adapter maps only verified model/level combinations. Retain a closed
`provider_mapping` with `mapping_revision` and `renderer_revision` strings of
at most 128 bytes each, Booleans `continuation_required`,
`canonical_terminal_tool_history` and `thinking_disabled`, and a `thinking`
selection. Host resolution validates thinking_disabled against the native
variant/default; core gates maintenance on that Boolean without reading modes. The host resolves
these facts from the verified exact mapping, including provider-default behavior.
Core uses them without interpreting the provider's thinking mode; a reasoning
label alone cannot establish any of these facts. `canonical_terminal_tool_history` is
true only when deterministic conformance proves that exact mapping/renderer
shape; its counted live closure witness must then prove actual provider support.
True means the provider accepts the canonical post-terminal request below and
returns a valid reply under this mapping. It does not promise that the provider
thinks on that particular request.
There is no candidate-only resolver or alternate core representation.
The closed `thinking` variants are
`{mode: omitted}`, `{mode: disabled}`, `{mode: manual, budget_tokens: positive_integer}`
and `{mode: adaptive, effort: low | medium | high, display: summarized}`.
Explicit adaptive levels request the verified summary display selected below.
`{mode: omitted}` sends no thinking, display or effort override; it retains the
verified exact model's default behavior, including whether continuation is
required and any public summary is returned. Omission is not disabled thinking.
No arbitrary provider-option bag is admitted. Include this mapping in the
2-KiB configuration capability budget, and its resolved values in canonical
sampling. Unknown capability permits `default` only and cannot enable a
continuation-required mode without conformance. An exact model with no
registered row therefore resolves `default` to one literal generic descriptor:
`mapping_revision: "loopex.unregistered.default.v1"`,
`renderer_revision: "loopex.reqllm.canonical.v1"`, all three Booleans false and
`thinking: {mode: omitted}`. That renderer is the ordinary canonical ReqLLM
rendering with no private blocks, for every provider route; on an Anthropic
route the adapter still classifies native reply blocks before conversion, solely
to apply the refusal below. Every other level refuses before commitment. Such a
session never gains private continuation: on the Anthropic native grammar, a
reply carrying a thinking or redacted-thinking block under
`continuation_required: false` fails that attempt through the bounded
started-call error path instead of dropping the block; this holds for registered
rows too. Because `canonical_terminal_tool_history` is false, the post-terminal
gate below applies to such a session. `default` omits the override;
it does not claim that the provider disables thinking. Manual low/medium/high
map to 1,024/2,048/4,096 thinking tokens. Host resolution and adapter preflight
require `max_tokens > budget_tokens` and reject a conflict before commitment;
core validates declared output limits without inspecting a manual-mode variant. Do not enlarge the
reply limit. Verify the actual outgoing request: dependency translation may
neither raise committed `max_tokens` nor enable an unadmitted mode. Pin the
supported exact model, mapping and renderer in vectors before integration.

M7's initial Claude conformance rows are below. These are proposed mappings,
not claims that the current product implements or has verified them. Both use
renderer revision `loopex.anthropic.native.v1`. Source metadata is the pinned
LLMDB snapshot `b78cd916413017210f042b413c715d73180999b194545d1aa7e95a293e837c53`,
generated 2026-09-18, plus the provider references below and the completed
adapter conformance record. Keep those identities/digests in the bounded source
metadata; a catalog label cannot override a verified request/response contract.
The Haiku alias in the current reference default resolves to the dated identity
below; these conformance rows use that exact identity. That resolution is one
literal alias entry of mapping revision `loopex.anthropic.haiku45.v1`:
`anthropic:claude-haiku-4-5` names `anthropic:claude-haiku-4-5-20251001`. Host
resolution applies only such literal entries, commits the dated literal as the
exact `model` and sends it in new requests; legacy derivation from a latest
request that names the alias applies the same entry. Old request bytes stay
unchanged. A catalog alias with no literal entry is an unregistered model. M7
changes the reference default string itself to the dated literal; the alias
entry serves existing configuration and legacy requests. The baseline case pin
names the dated literal.

| Exact model after `anthropic:` | Reasoning | Outgoing thinking and effort | Continuation | Public summary | Reply condition |
| --- | --- | --- | --- | --- | --- |
| `claude-haiku-4-5-20251001` | `default` | Omit both | No | No | Preserve committed limit |
| `claude-haiku-4-5-20251001` | `none` | `type: disabled`; omit effort and display | No | No | Preserve committed limit; maintenance uses 1,024 |
| `claude-haiku-4-5-20251001` | `low`, `medium`, `high` | `type: enabled`, budget 1,024 / 2,048 / 4,096 respectively; omit effort and display | Yes | Yes: native summarized thinking text | Strictly greater than the selected budget |
| `claude-fable-5-1` | `default` | Omit both; provider default is adaptive with omitted summary display | Yes | No | Preserve committed limit |
| `claude-fable-5-1` | `low`, `medium`, `high` | `type: adaptive`, `display: summarized`; `output_config.effort` equals the selected level | Yes | Yes: native summarized thinking text | Preserve committed limit |
| `claude-fable-5-1` | `none` | Refuse before commitment; no request | — | — | Thinking cannot be disabled |

Mapping revisions are `loopex.anthropic.haiku45.v1` and
`loopex.anthropic.fable51.v1` respectively. These also propose `canonical_terminal_tool_history: true` for every dispatchable
row in this table; thinking_disabled is true only for Haiku none and false for
every other dispatchable row. The refused Fable none row has no mapping.
Deterministic conformance must pass per cell before implementation integration.
The tested implementation bytes register these rows for ordinary resolution;
closure is conditional on their counted live witnesses. A failed positive
case cannot silently change the value to false or omit its required behavior.
These define the summary classification used below; there is no independently authored disclosure bit.
Haiku manual low/medium/high classify supported native thinking text as a
provider summary: its omitted display setting defaults to summarized under the
[provider display contract](https://platform.claude.com/docs/en/build-with-claude/thinking#controlling-thinking-display),
checked 2026-09-30. Default/none remain ineligible. This is the mapping's literal
policy, still subject to exact response-identity and native-event validation;
a converted thinking chunk does not establish eligibility.
All rows remain subject to ordinary model output, run-spending, context,
capsule and record bounds. A syntactically valid reply allowance promises no
number of thinking/tool rounds. With the unchanged 4,096 ordinary reply default,
manual `high` refuses. An explicit larger allowance, such as 8,192, uses existing
configuration and must pass all bounds; dependency code cannot grant the increase.
The maintainer selected ordinary availability at M7 closure. All nine dispatchable
Claude cells below are registered for ordinary resolution in the tested implementation
bytes, after per-cell deterministic conformance. Ordinary chat, ephemeral startup, configure
and resume use the same resolver; no test override, status member or later
registration edit is required. Live proof is an acceptance obligation on that
candidate, not a runtime gate whose first success changes source or durable data.
A failed or incomplete owning witness blocks closure and support claims; it
cannot downgrade the descriptor, omit a cell or allocate a calibration/reroll.

| Model / level | Continuation witness | Post-terminal witness | Summary witness |
| --- | --- | --- | --- |
| Haiku default | m7.baseline.durable (nil capsule) | m7.thinking-bound.haiku.default | m7.baseline.durable (no reasoning disclosure) |
| Haiku none | m7.provider-switch.haiku.none (nil capsule) | m7.thinking-bound.haiku.none | m7.maintenance.haiku.none (natural, no thinking) |
| Haiku low | m7.thinking-rounds.haiku.low | m7.thinking-bound.haiku.low | m7.thinking-rounds.haiku.low |
| Haiku medium | m7.thinking-rounds.haiku.medium | m7.thinking-bound.haiku.medium | m7.thinking-rounds.haiku.medium |
| Haiku high | m7.thinking-rounds.haiku.high | m7.thinking-bound.haiku.high | m7.thinking-rounds.haiku.high |
| Fable default | m7.thinking-rounds.fable.default | m7.thinking-bound.fable.default | m7.thinking-rounds.fable.default (no disclosure) |
| Fable low | m7.thinking-rounds.fable.low | m7.thinking-bound.fable.low | m7.thinking-rounds.fable.low |
| Fable medium | m7.thinking-rounds.fable.medium | m7.thinking-bound.fable.medium | m7.thinking-rounds.fable.medium |
| Fable high | m7.thinking-rounds.fable.high | m7.thinking-bound.fable.high | m7.thinking-rounds.fable.high |

These are fixed subcase keys of their named owning cases, not CLI selectors or
replacement attempts. `m7.maintenance.haiku.none` is the existing Haiku summary
subcase of m7.long. Each thinking-rounds subcase proves two actual continuation
requests and its prescribed disclosure/no-disclosure. Each counted continuation
request must replay at least one retained thinking or redacted-thinking literal
from that exchange's capsules; an exchange whose capsules hold reference nodes
only does not satisfy this oracle and is `required_action_absent`. Each bound subcase proves
canonical post-terminal rendering on that cell. The maintainer selected its
oracle on 2026-09-30: the post-terminal request must be accepted with the cell's
exact outgoing mapping, correct fixture facts and no resurrected native state;
it need not itself show native thinking, because the provider may answer that
one request without it. One further prompt in the same subcase, after that
completed assistant turn, then proves native thinking has resumed for each
continuation-required cell. Haiku default and none prove the nil-continuation,
no-thinking behavior on both requests. The separate thinking-cancel
case pins one admitted thinking cell and proves cancellation with the same two
later prompts and the same oracle; it does not
replace the nine bound witnesses. The phase-0 manifest enumerates every subcase,
its exact prompts, limits, attendance, oracle and retained execution slot before
any dispatch. Manual high pins a permitted reply allowance above 4,096. No paid
call beyond this counted matrix is authorized. Additional registered mappings,
including a default that requires continuation, still require their own
conformance and a proposed counted witness before ordinary registration.
Haiku's manual mode does not claim interleaved thinking support. No new beta
headers, `between_tools`, extra effort levels or raw provider-option bags are
introduced. The Haiku thinking-off row supplies one maintenance conformance
case. M7's required cross-provider compaction case separately pins a verified
thinking-off model on provider B; it cannot use two Anthropic models to claim
that routing proof. Different providers mean different admitted `provider:`
route identities and their endpoint/custody routes, not different model vendors.
An admitted OpenRouter route may therefore host an Anthropic model; this proves
route switching without claiming cross-vendor model diversity. The always-on
conversation model need not disable thinking. That provider-B summarizer is one
additional registered row beyond the nine cells. Phase 0 pins its exact
`provider:model`, mapping and renderer revisions and its native thinking-off
encoding in vectors before integration, with `thinking_disabled: true` and
`continuation_required: false`; `m7.cross-provider-maintenance` is its counted
witness.

Inspect the final request after dependency normalization, not only Loopex's
input options, including final headers and transport controls. A dependency-
injected interleaved-thinking beta header or an unadmitted display/body override
refuses before HTTP launch; preserve required authentication/routing headers.
The pinned Anthropic header-name allowlist is accept, content-type, content-length,
host, user-agent, connection, authorization, x-api-key, anthropic-version and
anthropic-beta, case-insensitive. The buffered OneShotHTTP1 path additionally
admits its own transport-owned `accept-encoding` header with the single value
`identity`; no other value or path admits it. Route-only headers must be explicitly pinned
in ADR 0048's trusted route capture; they cannot come from model/config extras.
The only admitted beta value here is tools-2024-05-16, emitted only when tools
are present; interleaved-thinking and any additional beta token refuse.
Validate values against the captured endpoint/authentication/control settings,
without retaining or reporting selected credential values.
The invocation wrapper validates the complete normalized request, not just its
JSON body. In pinned ReqLLM, `reasoning_effort: none` removes the option;
it does not send `thinking.type: disabled`. Default omission likewise must not
use ReqLLM's `reasoning_effort: default`, which can enable thinking. Set the
verified native disabled/manual/adaptive values explicitly where selected. The
wrapper installs them in the native body itself: passing a manual selection
through the dependency's `thinking` or `reasoning_effort` options makes pinned
ReqLLM add the interleaved-thinking beta that this contract refuses.
Reject unadmitted manual-to-adaptive conversion, reply-limit increases or
display injection before HTTP launch. Validation performed after start_stream/4
remains dispatched_or_unknown under the handoff rule, even if HTTP was prevented. Only conformance-complete exact rows are registered, and only they may require
continuation; an unregistered model receives only the generic descriptor above
and cannot bypass that rule. Additional exact model mappings need the same bounded
contract and evidence, not a family-name inference or automatic catalog update.

**Public reasoning projection.** The retained exact model/mapping revision and
actual outgoing mode/display settings determine whether native text is a
verified provider summary. Keep that classification in the versioned adapter
mapping, not a caller-authored permission flag or a new core provider taxonomy.
Apply it before converting native events, emitting progress or incrementing
the public delta counter. For streaming, verify the response identity and
supported event kind before its first eligible fragment. Revision 1 requires
the native response model to equal the row's literal model identity and permits
only a native `thinking_delta` inside its validated thinking block as summary
text; signatures and redacted-thinking deltas are ineligible. An unverified mode,
changed response identity or unexpected event cannot inherit another mapping's
summary classification. A response-model mismatch fails the whole attempt
through the bounded started-call error path before any summary/canonical reply
can settle; it is not merely a suppressed-summary success. Exact aliases need
an admitted literal mapping revision, never an inferred fallback. Malformed
native streams retain the failure rules below.

Only provider-declared summary text is eligible for `reasoning_delta`. A field
named `thinking`, a converted `:thinking` chunk, a missing signature or an
`encrypted?: false` marker cannot establish eligibility. Pinned dependency
conversion may erase the distinction between summary and other reasoning
events. Classify at the native boundary and suppress unverified reasoning text;
do not decode signatures, copy redacted data or generate a local summary from
private continuation. This rule also applies to other provider routes. It does
not require enabling thinking or requesting a summary when the admitted mode
does not return one. No new user option or provider mode follows from this rule.

Project only bounded UTF-8 summary text through ADR 0011's existing
`reasoning_delta` schema, with its terminal-control, credential and binding
checks. Exclude native block wrappers, signatures, redacted data and private
continuation metadata. Count only emitted public deltas in the shared model
sequence and reply `delta_count`; suppressed private events consume no sequence
number. Chunking, loss detection, closure and cancellation retain their existing
rules. Receiving a complete summary block grants no tool or settlement authority.
The private assembler independently retains the original block unchanged, even
if public projection is ineligible, split or lost by a subscriber. An otherwise
eligible summary fragment that fails existing terminal-control validation fails
the attempt through the started-call failure path; do not sanitize or silently
suppress it into a successful reply. Ineligible private text is suppressed
before public projection, not subjected to a new disclosure rule.

A visible summary is provisional progress. Reference clients distinguish it
from answer text and may retain received progress in their operator transcript.
It is absent from canonical answer/history, snapshots, compaction input, helper
results and diagnostics. Reopen/replay does not regenerate it from the capsule.
ADR 0011's summary-only rule remains; this proposal qualifies its blanket
continuation-material exclusion only for the verified text projection. ADR 0023's
public progress kinds and field names are unchanged. Ephemeral calls remain
buffered without a new progress callback or post-hoc summary disclosure.

**Private reply and request forms.** Every newly staged ordinary or maintenance request uses
`loopex.model_request.v2`, including nil continuation; v1 is read-only. This revision retains
the same top-level semantic members and digest coverage, admitting `continuation`
as nil or the envelope below. Old v1 bytes remain immutable. An adapter reply
uses `bounded_adapter_reply_v3`, the exact nine fields of ADR 0018's v2 plus `completion` and `continuation`.
`completion` is exactly `natural`, `limit` or `unknown`, validated from the final
native stop reason. In the pinned Anthropic grammar, end_turn, tool_use and
stop_sequence map to natural; max_tokens maps to limit; model_context_window_exceeded,
refusal, pause_turn, absent and unrecognized reasons map to unknown. Normalized
non-Anthropic length/max-token reasons map to limit only in their own exact
admitted mapping; each provider-B maintenance row pins its literal stop table
and natural-completion vector before admission. Adapters retain no raw stop
strings. Maintenance requires natural. Relations are closed below.
`continuation` is nil or this closed capsule:

```text
{format: "loopex.anthropic.content_refs.v1", provider: "anthropic", model: exact_model,
 status: "open" | "closed", content: [ordered content nodes]}
```

Each content node is exactly one of these model-port forms:

```text
{kind: "literal", value: bounded_object}
{kind: "text_ref", byte_length: nonnegative_integer,
 template: bounded_object, field: bounded_field_name}
{kind: "tool_use_ref", call_index: nonnegative_integer, native_id: bounded_identity,
 template: bounded_object, field: bounded_field_name}
```

One pure bounded expansion rule serves core validation/accounting and adapter
rendering. A literal returns its value unchanged. A reference inserts one value
into one absent top-level template member. A field name is nonempty ASCII of
at most 128 bytes and names one key, never a path. Reject unknown node members,
overwrites, out-of-range indices and cross-entry or recursive substitution.
Opaque literal/template/argument data is never scanned for nested references.
No callback, provider dependency, store handle or external lookup enters this
rule. The shared rule unifies these two required consumers; core does not
interpret native block types, names or signatures.

Text nodes consume successive UTF-8 byte slices of the owning canonical text,
starting at zero, with valid slice boundaries and complete final consumption.
Zero-length nodes preserve empty native text blocks. Tool nodes consume indices
exactly `0..call_count-1` in native tool-call order, each once, inserting the
selected canonical arguments. Empty calls require no tool nodes. Native
identities use the existing nonempty UTF-8 reply-call identity contract and
the enclosing size limits. Retain each node's `native_id` as generic mapping
data; the adapter proves it equals the
native identity inside the opaque template. This small identity duplication
avoids provider-field interpretation by core. Text and tool arguments are not
repeated in the private layout.

For this Anthropic format the adapter requires text templates exactly
`{type: "text"}` with field `text`, and tool templates exactly
`{type: "tool_use", id: original_id, name: original_name}` with field `input`.
Literal nodes are only the supported exact thinking/completed-signature or
redacted-thinking/data blocks. The adapter constructs these reference nodes;
provider-supplied objects are never accepted as reference instructions.
Conformance covers complete native field sets. Unknown members fail reply
validation and are never silently discarded. Supporting an additional member
requires a new explicit mapping/renderer revision with exact templates,
expansion vectors and retained bounds; existing revisions keep their meaning.
Expand against the simultaneously produced
canonical reply and compare the complete native array with the bounded captured
array before settlement. Preserve
all decoded string values and array order exactly. JSON whitespace and map-key
order are not preserved wire bytes. Reject unknown blocks, incomplete streaming
signatures or a mismatch with the canonical reply's text/calls/arguments before
any tool intent or policy evaluation. `tool_use` stop with complete matching
calls means open; genuine `end_turn` with no unresolved calls means closed.
A capsule need not contain a thinking literal: when the provider returns no
thinking block for one request under a continuation-required mapping, the reply
still settles a valid capsule of reference nodes.
The accepted relations are:

| Mapping / final native stop | Tool calls | Completion and capsule |
| --- | --- | --- |
| continuation_required false, complete native reply with no thinking or redacted-thinking block | Existing canonical call validation | nil capsule; natural/limit/unknown according to the exact stop table |
| continuation_required false, reply carrying a thinking or redacted-thinking block, registered or generic descriptor | No tool authority | No successful adapter reply; bounded started-call error, existing conservative accounting |
| continuation_required true, tool_use | One or more complete matching calls | natural, open capsule |
| continuation_required true, end_turn | No calls | natural, closed capsule |
| continuation_required true, every other stop/call combination or incomplete native reply, including tool_use with no call and end_turn with calls | No tool authority | No successful adapter reply; bounded started-call error, existing conservative accounting |

A complete native limit-stopped thinking reply therefore follows the adapter's
started-call model_call_failed path, even if its text is parseable. Core rejects
an externally supplied v3 that contradicts these declared relations as
unreadable_model_answer before tools; it never invents a closed exchange.
Unsupported/incomplete blocks use the same started-call failure path. An admitted mapping with
`continuation_required: true` requires a capsule for each successfully decoded
reply; false requires nil. An omitted required
capsule is an unreadable answer, not permission to continue without thinking.

The capsule is private data in its source settlement, whose existing operation,
attempt and request digest bind it. The owner constructs each next request's
closed envelope from committed source settlements, not adapter-supplied journal
identities:

```text
{format: "loopex.anthropic.content_refs.v1", provider: "anthropic", model: exact_model,
 configuration_version, exchange_id: first_model_operation_id,
 base_request_digest,
 entries: [{source: {run_id, turn_id, operation_id, attempt, settlement_digest},
            assistant_message_index: zero_based_index,
            calls: [{canonical_call_id, native_id, result_message_index}],
            capsule: <exact retained open reply capsule>}]}
```

The first request of an exchange has nil continuation. Its staged digest is the
base identity; it never contains a digest of itself. Source digests bind prior
complete settlement records, so there is no circular digest. Each entry names
the exact assistant message position and its ordered call/result mapping in the
current request. Copy the source compact capsule unchanged, and require staged
assistant text and ordered arguments to equal its source canonical reply.
`calls[n].canonical_call_id` names that staged assistant's nth call, whose
relationship to the source nth call follows the retained projection rule.
`calls[n].native_id` comes from its tool node; it need not equal the canonical
ID. The owner validates identities and result positions against source facts
and exact projected messages; content matching is never identity.
The adapter validates index, role, arguments and native/canonical correspondence
before rendering. Native names match the original reply. For known tools they
also match the frozen model-visible name/generation mapping, not a guessed
`tool_id` spelling or interchangeable alias. Unknown names retain their exact
source bytes and existing failed-call behavior, not a new grant or a fabricated
generation.
Missing, duplicate or ambiguous mappings refuse.

Each capsule and the aggregate request envelope, both compact and expanded as
defined below, are at most 16,384 bytes under ADR 0042's compact UTF-8 JSON
recipe. Bound counting/expansion before allocating an oversized value. At most
32 assistant entries and 128 native content blocks, including empty text blocks,
are admitted in one exchange; existing depth/cardinality limits also apply.
Every source must be a canonical, successful reply of this exchange, in order,
under the exact model/configuration/renderer. Late evidence-only replies cannot
supply continuation. Core validates generic identity, bounds and integrity;
the adapter alone interprets provider block schemas. No provider struct, secret,
process handle or arbitrary dependency metadata enters either form.

`bounded_canonical_reply_v3` removes only the echoed `canonical_request_bytes`
from v3, retaining its other ten fields exactly. `model_attempt_settled_v3`
keeps the twelve outer fields and accepts that reply variant. ADR 0021 already
owns v2; never reinterpret v2 records as carrying v3 replies. Preserve its
compact `accounting_evidence` member and closed relations under the new kind.
M7 writes `model_attempt_settled_v3` for every newly committed settlement:
ordinary, maintenance, error-only, nil-continuation, unreadable and validated
reply compaction. Historical v1/v2 kinds are read-only under their original validators, including
when an older request later receives a new v3 settlement. This explicitly amends
ADR 0021's v2-only writer clause. Within each session the first v3 settlement is
a monotonic cutover: no later newly appended v1/v2 settlement is valid. Historical
earlier versions remain readable; recovery validates that ordering.
An exact nine-member v2 adapter reply is still admissible when the staged
request requires no continuation, including eligible legacy requests and maintenance requests. V2 requires all nine
keys, including `provider_response_id` even when nil; an eight-key reply is
prevalidation unreadable_model_answer with accounting_evidence none. This
explicitly amends the Model-port type that currently makes that key optional.
Migrate every in-tree fake/fixture to exact v2 or v3 keys and add a negative
eight-key vector; discriminate versions by exact key sets, never optional fields.
Validate v2, then add `continuation: nil` and `completion: unknown`. A request
requiring continuation rejects v2 as unreadable_model_answer. A maintenance
request validates it as readable; its `completion: unknown` then fails ADR
0043's `maintenance_summary_incomplete`. V3 adapter replies
have exactly eleven members and their canonical projections ten; extra keys and mixed shapes
refuse. V3 model-call errors retain ADR 0021's two-member result; unreadable and
compacted results retain its three-member result and closed accounting-evidence
union. Commit reply, continuation, usage and next disposition atomically before
tool intent.
Measure the complete owning settlement against 65,536 bytes. Invalid or oversized continuation is prevalidation rejection: retain compact
`unreadable_model_answer` with `accounting_evidence: {kind: none}`, no canonical
reply/tools and terminal failure, charging the conservative remaining allowance
as ADR 0021 requires. A merely plausible usage field in a rejected reply does
not prove reported accounting. Only after the entire reply, including capsule,
passes validation may a complete owning-record byte/depth overflow use ADR
0021's `validated_reply_compaction_v1` evidence. Its observed/limit fields
measure the attempted full v3 settlement, with exact reported usage only when
that evidence validates it. Unknown extra fields, evidence kinds or dimensions
refuse; do not invent a capsule-limit compaction dimension. Late replies remain evidence only.
`commit_unknown` fences tool dispatch and publication until resolved. No new
retry authority, second reply transaction or separate provider-state writer
is introduced.

**Space before an exchange.** When the retained mapping has
`continuation_required: true` and staging would begin a new ordinary exchange,
apply revision `loopex.thinking_headroom.v1` before its first provider intent.
This includes a first candidate that already fits the hard limits. With captured
input ceiling `C`, the inclusive admission targets are:

```text
record_target = 32,768
token_reserve = min(8,192, floor(C / 2))
input_target = C - token_reserve
```

This leaves half the 65,536-byte record and up to 8,192 estimated input tokens
available. An unknown-window `C = 8,192` gives `input_target = 4,096`; odd/small
positive budgets use the equation without rounding through floating point.
These are fixed preparation targets, not configuration flags, a changed `C`,
additional spending allowance or a deduction from `max_tokens`.

Apply both targets inside ADR 0041's required-context allocator and optional
intake, measuring the complete fixed-point record with both reserved header
variants. If the minimum required projection at `q=0`, with optional resources
absent, misses either target, use ADR 0043's single bounded maintenance episode
for this staging identity. Preserve current-run inputs and fixed metadata, applying ADR 0043's conditional
terminal-tail release and target-aware optional tail growth first. If that
irreducible projection still exceeds a target, refuse without a summary call.
A fresh session with a large first prompt can therefore refuse the initial
reserve despite fitting ordinary hard limits; no absent-history exemption exists.
Otherwise each checkpoint must strictly reduce that same minimum projection in
both bytes and estimated tokens, and maintenance continues until both targets
fit. Fitting only the hard ceilings does not end this preparation.

Once the minimum fits, maximize eligible excerpts and admit optional resources
within these same targets, then preflight the complete actual candidate. Optional
content cannot spend the reserve. Capture the trigger kind, rule revision and
derived targets in the maintenance episode alongside its existing configuration,
staging identity and bounds. Recovery validates the captured derivation and
continues with the same counters/targets, never current defaults or a new
episode. A request already staged before a crash keeps its exact bytes and
dispatch classification; recovery does not summarize it again.

If no eligible range can leave the reserve, retain `thinking_exchange_headroom`
through ADR 0043's version-2 failure union with dimension, observed size,
target and hard ceiling before ordinary intent.
Missing maintenance configuration, no progress, uncertain commits and exhausted
bounds retain their more specific failure causes. Preserve committed checkpoints;
none of these failures authorizes another automatic episode for the same staging
identity. The rule reserves capacity but guarantees no number of rounds: a
single large reply, fixed metadata, later steer or accumulated results can still
exhaust a hard limit. After first staging, continuation requests use the hard
ceilings and never replenish the reserve by changing their frozen prefix.

**Lossless rendering and exchange lifetime.** Pinned ReqLLM 1.24.0's ordinary
message conversion drops redacted thinking and groups thinking/text/tools.
Implement bounded capture before that conversion and exact native-array
rendering within the existing adapter transport path, for buffered and streaming
responses. Keep ReqLLM transport/custody/cleanup; no second provider client or
implicit dependency upgrade is authorized. The raw path obeys existing input,
reply, private-channel and cleanup bounds. A mode whose complete blocks cannot
be captured and rendered losslessly is unsupported before dispatch.

**Streaming assembly.** The selected live-delivery scope applies to the existing
durable streaming path. ADR 0039's ephemeral caller remains buffered through its
one-shot transport; changing it to `stream_text` would bypass that accepted
transport/cleanup contract. Both paths must capture the same complete native
blocks and construct the same capsule for equivalent decoded replies.

The streaming adapter captures native events before ReqLLM's ordinary chunk
conversion. Use a per-invocation bridge over the pinned provider/parser callbacks
and ReqLLM transport, with no global provider replacement, application setting,
second HTTP client or dependency upgrade. Preserve request option validation,
exact model/routing, native request rendering, the existing dispatch handoff
classification and companion lifetime. Native assembly state stays private to
that invocation; it cannot be recovered from a public progress subscriber.
The durable bridge performs credential-free model, option and context validation
before calling pinned `ReqLLM.Streaming.start_stream/4` with its provider wrapper.
It explicitly preserves the required normalization otherwise performed by
`stream_text/3`; no global provider registry is changed. Entering `start_stream/4`
is the transport handoff: all subsequent errors, exceptions and incomplete
responses are `dispatched_or_unknown`, regardless of dependency error tags.
At the wrapper's request-building boundary, install and validate the exact
native body after dependency normalization and before HTTP launch. The final
validator must run after both pinned request mutation hooks, application-env
:finch_request_adapter and opts[:on_finch_request]. Pinned ReqLLM reads the
application-environment adapter unconditionally and applies the per-request
hook last, so the invocation-owned `on_finch_request` is the validating join:
it accepts no caller-supplied hook and refuses any final request whose method,
URL, headers or body differ from the wrapper's expected values. It returns that
refusal without raising a term that carries request detail, because the pinned
caller inspects and logs a raised exception. No hook runs after it. Rejection uses the fixed
literal :invalid_provider_request, never a body/headers/exception detail that
dependency inspect/logging could disclose. Ordinary
context conversion may not reorder native arrays, replace malformed arguments
with an empty object or alter admitted controls. Preserve route/authentication
and transport ownership. The buffered caller captures native response content
before lossy ReqLLM response conversion and applies the same exact native request
rendering through its existing OneShotHTTP1 path, validating the final normalized
headers/body/controls immediately before OneShotHTTP1 issues the HTTP request.
Return completed capture over a bounded private path correlated to that same
invocation. Never return native blocks or signatures through ordinary chunk
metadata, dependency telemetry, progress or raw exception terms. The buffered
caller extends its existing selected-key screening to every new captured value
before returning it. This does not claim an existing durable per-delta key
screen that its current drain does not implement.
The existing converted-chunk list is not an adequate native capture or memory
bound. Replace its unbounded accumulation on this path with bounded assembly;
do not retain both a full event log and its assembled reply.

Count raw HTTP response-body bytes before SSE parsing, including comments,
pings and framing. The proposed stream ceiling is 8,388,608 bytes, reusing the
buffered one-shot response ceiling. Pending framing/JSON input shares that
ceiling, not a fresh allowance for each event. Check before append/decode;
release consumed fragments. Completed native content still obeys this ADR's
16,384-byte expanded cap, block limit and ordinary structural/reply bounds.
Account for every retained accumulator and dependency queue in the memory proof;
a chunk-queue count or a final Store refusal alone proves none of those byte
bounds. Pings do not extend the committed deadline or count as model progress.
The bridge must make overflow, malformed framing and JSON decode errors fatal
before dependency code can discard them or render their raw diagnostics. Retain
a monotonic invocation-failure latch and terminate the exact owned stream;
later input cannot clear the latch or restore success. The invocation owner
runs the drain in a separate invocation-owned monitored process and observes
private fatal failure independently of its blocked enumeration. It terminates
the exact stream and wakes and joins the blocked drain through existing cleanup.
Infinite dependency timers cannot defer this handling. Pinned StreamServer logs
and continues on a parser error return, so that return alone cannot enforce
this rule. Validate before lossy SSE event conversion too. Test final parser
flush as well as ordinary input; neither may turn a previous failure or
incomplete event into successful completion. The wrapper implements every
provider/parser callback probed by the pinned streaming path, including
ReqLLM.Streaming and StreamServer; conformance records that exact inventory.
Pin the protocol state as ServerSentEvents.Parser and its SSE.flush/1 final
flush separately; an
unhandled/non-Parser state cannot silently no-op into success.

For the pinned native event grammar, require one message start, unique ordered
block indices, type-correct deltas for an open block, matching block stops and
one final message stop. Preserve empty blocks and event-defined content order.
Assemble text, thinking and signature fragments exactly; finish tool-argument
JSON as one bounded object at its block stop. No partial JSON or signature can
become a completed block. Message-level usage updates are cumulative: retain the
final supported totals, not their sum. Preserve missing/invalid counter evidence
and use the existing accounting rule; dependency zero defaults cannot turn
absent counts into reported usage.
Allow documented pings without retaining them; unsupported content/events,
conflicting identities, invalid ordering or incomplete final framing fail with
the existing bounded error shape. Native provider fallback or server tools are
not silently interpreted as the selected model or local application tools.
Pinned ReqLLM currently marks a converted `message_delta` terminal before the
native `message_stop`, and its thinking-signature update replaces a prior
fragment. The invocation bridge must defer converted terminal completion until
the actual native message stop, concatenate signature fragments and reject
incomplete flush/EOF. A converted finish reason or successful metadata task
alone cannot establish complete native capture.

Answer-text and supported tool-call progress use ADR 0011's existing transient
projection as they arrive, with its payload limits, sequence/count rules and
credential/terminal-control exclusions. Private capture does not add a public
event type. A slow or disconnected subscriber may lose progress without losing
private assembly or changing the eventual reply. No tool policy evaluation or
dispatch begins until the complete native message, canonical reply and capsule
validate and the owner commits their atomic settlement. A block stop, progress
closure or partial tool argument is never that authority.

On stream error, premature EOF, cancellation, deadline or assembly-bound failure,
stop emitting progress and clean up through the existing invocation owner.
For non-cancellation failure before a complete reply exists, preserve ADR 0018's
started-call failure and conservative accounting; a completed but invalid reply
follows this ADR's prevalidation rejection rule. Admitted cancellation retains
its existing precedence, cleanup outcome and abandoned-stream close. Earlier
visible text remains provisional, not a durable assistant message or checkpoint
source. Owner loss discards incomplete assembly;
recovery uses committed attempt/settlement evidence and never reconnects using a
provider response ID, appends to a partial reply or repeats an ambiguous call.
Late complete replies stay evidence only under the existing attempt rules.

Freeze the first request's complete rendered system, tools, messages, artifact
excerpts and canonical-ID mapping. Every next request extends that same prefix
with assistant arrays expanded from the exact retained layouts and their
canonical targets, followed by committed tool results in order.
The adapter replaces the corresponding canonical assistant view, rather than
sending both views. Every staged request includes the complete frozen prefix
and all replacement content and mappings needed to render it. The base digest
is provenance, not a fetch instruction; dispatch consults no journal, volatile
cache or current catalog to reconstruct the request. Canonical facts remain
independently recoverable. Native
tool IDs in preserved arrays are unchanged; map their results by the source
run/turn/call identity. Validate collisions against the frozen prefix and earlier
entries; a collision requiring ID rewriting refuses the reply before tools.
After the exchange, ordinary ADR 0041 normalization applies again. Provider
rendering must be deterministic under the retained revision; an unavailable
revision refuses recovery rather than using a newer renderer.

Do not recompact, re-render or revise any earlier prefix while the exchange is
open, even an older complete group. Append newly admitted steer only at its
ordinary boundary after required results, preserving the prefix and native
message grouping; vectors must prove this path. A configuration change is
already forbidden within a run. Compaction waits until no exchange is open.
If the next request does not fit, retain the named staging-bound failure and
end the run without removing thinking or silently downgrading reasoning. A
terminal run or true end_turn ends reuse. The next run may compact canonical
history and begins with nil continuation; A→B→A never resurrects a closed,
failed or invalidated exchange. Compatible reuse in M7 means the exact admitted
model/configuration/renderer within that exchange; no cross-model native reuse
is promised.

For post-terminal canonical rendering, emit retained assistant text/tool calls
without old private blocks. Omit an empty assistant text block, while preserving
nonempty text and calls in their canonical order. If neither remains, omit that
empty assistant message; it creates no empty native content array or fabricated
completion. An omitted empty completion counts as absent for the grouping rule
and for the capability check below. Render each following ordered
tool-result group and adjacent admitted user text, including the new prompt,
in one native user content array: all results first, then text in canonical
order. Do not emit a separate adjacent user message for that text. Do not fabricate an assistant
completion or change that grouping to imply one. This rule applies to retained
canonical groups; it does not rewrite the frozen prefix of an open exchange.
Before ordinary provider intent, inspect the projected history after any admitted
compaction. If it still contains a terminal run's tool turn with results but no
assistant completion, require `canonical_terminal_tool_history: true` from the
selected mapping. Otherwise refuse `canonical_history_rendering_unsupported`
through ADR 0043's closed failure projection, without provider dispatch. Explicit
compaction that covers the group or configuration of a verified compatible
mapping is the remedy; neither old native-state resurrection nor an automatic
retry is permitted. Explicit compaction may select the offending terminal group
even when it otherwise fits byte/token targets. The exact retained rendering and
capability value are conformance facts, not inferred from another model or an
ordinary completed turn.

**Accounting and private retention.** The complete staged-request record still
has the 65,536-byte limit, including semantic continuation, its duplicate inside
canonical bytes, receipt, envelope and fixed-point size. No artifact reference
stands in for required native data. Define `E(request)` as its continuation
envelope with each capsule's content nodes expanded against the indicated staged
assistant text/calls. Preserve all other members, including format strings.
`E` is an accounting preimage, not another admitted dispatch format or retained
payload. The same generic expansion validates a reply capsule against its owning
canonical reply. Both compact and expanded JSON caps apply before admission;
JSON size is distinct from `Canonical.encode`'s deterministic ETF size.
Extend ADR 0017's estimator revision to
charge the entire expanded canonical continuation envelope in addition to existing
message/tool/system charges, using the existing ceil(bytes/3) rule. This
conservatively counts canonical text/tool arguments again; smaller storage never
treats private state as free or subtracts an unproved provider discount.

Context-provider receipt revision 4, shared with ADRs 0042/0043, adds exactly one
mandatory outer member `continuation_cost`: null for nil continuation, otherwise
`{content_digest, byte_cost, token_cost}`. Compute the digest and byte count over
`Canonical.encode(E(request))` and `token_cost = ceil(byte_cost / 3)`.
The digest is lowercase SHA-256 hex. Recompute all three against the actual
staged request at construction and replay using generic expansion; no
caller-supplied cost or provider-specific expansion callback is trusted. The
actual request digest still binds the compact envelope and canonical targets.
This is private receipt metadata, not an extra provider message or descriptor.
Keep `totals` and every `by_provenance` bucket equal to their message/tool
descriptor sums. Under estimator `loopex.context_bytes.v2`,
`provider_estimated_tokens = totals.token_cost + continuation_cost.token_cost`,
treating null as zero. Input admission uses that complete sum. Maintenance has
nil continuation and a null cost. Existing receipt revisions 2/3 retain their
original estimator, closed keys and block-only equations. Public projection
retains its existing metadata allowlist; this does not expose the private
continuation or its digest. Charging only the smaller stored layout is invalid;
mutating a target, index or slice must change the staged digest or refuse.
System-class limits stay separate. Test the final rendered provider input
against the declared estimator preimage; provider tokenization remains an
estimate, not a billing guarantee.

Retain private capsules, staged requests and their bindings with raw session
recovery history. Existing private-root ownership/access controls protect durable
plaintext copies; no new encryption or independent lifetime is claimed. The host
retires the complete history under existing retention policy; M7 introduces no
selective continuation collection. Ephemeral runtime teardown removes its owned
state under the existing cleanup contract. Public events, snapshots, history
views, transcripts, helper results, summary input, progress and diagnostics omit
the capsules, native block objects, signatures, redacted data and unverified
thinking text. The public reasoning projection above is the sole exception for
verified summary text; its identical occurrence inside a capsule is permitted.
Other capsule exposure is limited to bounded format, size and availability
metadata. The raw capture path preserves selected-key
screening and credential isolation. Backup/restore includes private state;
ordinary artifact retrieval never exposes it. Host-authorized raw store access
retains the existing private-store audience, not an encryption guarantee.

Recovery dispatches committed requests byte-for-byte under the same digest and
ADR 0018's dispatch classification. Missing/corrupt/incompatible state refuses
before dispatch, never reconstructs a signature, reuses a provider response ID
as authority, or repeats an ambiguous provider attempt. Legacy v1 requests,
v2 replies and v1/v2 settlements decode under their old rules. No continuation
is synthesized for historical replies that did not retain it.

Protocol adds `session.configure`, `session.configured` and configuration snapshot
fields with a new experimental schema/generation jointly with ADRs 0043/0045.
The same coordinated change includes ADR 0046's generic absolute deadline.
Only the new server-specific generations are served, under the selected policy
below. Exact vectors and independent Node client updates precede implementation
integration; no old client receives unknown shapes under unchanged negotiation.

<a id="technical-adr-0044-evidence"></a>
### Evidence

Concept: [Observable consequences](0044-run-model-and-reasoning-configuration.md#concept-adr-0044-consequences).

- Atomic creation/configure, strict validation, version capture and idempotency.
- New v3 settlement writers cover ordinary/maintenance, successful nil/non-nil
  continuation, model-call error, unreadable and validated-compaction results.
  Exact legacy v2 adapter replies succeed only without required continuation;
  mixed/extra-key shapes refuse. Historical settlement readers stay unchanged.
- Ephemeral explicit instructions, reasoning and system ceiling reach the shared
  initial configuration and encoded request. Unknown/duplicate options and
  per-call overrides refuse; buffered delivery and cleanup remain unchanged.
- Revision-4 continuation-cost null/non-null branches, exact digest/cost replay,
  descriptor totals versus complete input estimate, unchanged v2/v3 equations,
  and public exclusion of the private cost digest. A missing or fabricated
  continuation charge cannot pass input admission.
- Generic expansion vectors cover zero-length/interleaved text, UTF-8 splits,
  quotes/control characters, overwritten fields, missing/duplicate/reordered call
  indices, literal data resembling references, unequal native/canonical IDs and
  aliases distinct from tool IDs. Compare complete expanded arrays with capture;
  verify multiple results grouped into one native user message and later steer.
- Exact pre-exchange target edges, including odd input budgets, and initial
  candidates that fit hard limits but require compaction for the reserve.
  A checkpoint that fits hard limits but misses a target continues within the
  original episode. Compare required `q=0` projections before/after; optional
  intake cannot consume reserved space. Mandatory-only, no-progress and exhausted
  episodes refuse before ordinary intent without repeated automatic episodes.
  Recovery on both sides of checkpoint and first staging retains the rule,
  targets, request bytes and existing spending/attempt bounds.
- Active/unresolved change refusal; legacy model derivation versus conflict.
- Restart at configure and staging boundaries preserves configuration/digest.
- Reasoning capability negatives, default omission versus verified disabled mode,
  and unchanged outgoing reply limits for manual and admitted adaptive modes.
  Cover every literal matrix row after actual pinned request encoding, including
  Haiku manual-high rejection at 4,096 and explicit 8,192, Fable default omission
  versus explicit summarized adaptive display, and Fable `none` refusal. Check
  retained source/mapping/renderer identity, continuation requirement and summary
  eligibility. A newer catalog or resumed run cannot reinterpret old rows.
- Real-provider continuation after a bound or cancellation immediately after
  tool results, followed by a new user prompt on the same thinking model.
  Verify the exact rendered message grouping and provider acceptance without
  resurrecting old native state or inventing an assistant completion; one
  further prompt after that completed turn proves native thinking resumes on
  continuation-required cells. Vectors cover the generic unregistered
  descriptor, its thinking-block refusal and post-terminal gate, the literal
  alias entry with legacy derivation, a reference-node-only capsule and the
  buffered `accept-encoding` allowance. A mapping
  that cannot render this canonical history has the capability false and refuses
  `canonical_history_rendering_unsupported` before provider intent. Vectors prove
  that refusal and explicit compaction/model-change remedies even when the group
  fits ordinary limits. Do not claim that one successful ordinary end_turn proves
  this path.
- Native/derived ID collision yields the named unreadable-answer or staging
  refusal before tool dispatch, with usage truth preserved.
- Privacy witnesses name chat transcripts, one-shot JSON, independent Node
  history/snapshots, diagnostics and ReqLLM telemetry. Host crash dumps and
  trusted host-installed handlers retain ADR 0039's stated host-VM audience;
  the private-store and credential guarantees must not imply secrecy from it.
- Use distinct canaries for permitted summary text, unverified thinking text,
  signatures and redacted data. A verified summary appears only in received
  reasoning progress and any recording of that progress; private canaries never
  appear in public planes. Assert both positive display and negative exclusion,
  rather than requiring every byte in the private capsule to remain undisclosed.
  Ordinary answer-text overlap is likewise not a private-state disclosure.
- Mapping/native-event vectors distinguish summary and other thinking events
  even when dependency conversion produces the same `:thinking` chunk. Cover
  absent/unverified classification, omitted/empty display, changed identity,
  split UTF-8 and terminal-control rejection, mixed hidden/public events with
  gapless counts, slow subscribers and cancellation. The capsule stays exact
  and reopening never republishes its summary as canonical history. Buffered
  ephemeral output remains free of reasoning progress.
- A real selected Claude thinking/tool loop, including multiple tools/rounds;
  raw block fidelity, redacted/interleaved blocks, signatures and native ID mapping.
- Streamed/buffered native-equivalence vectors and one live durable thinking case
  with answer progress before complete reply settlement. Controlled barriers prove
  this ordering without a latency threshold or a requirement that every model
  produce text before tools. The ephemeral case remains buffered.
- Before bridge integration, exercise its production request-building and actual
  local HTTP transport path with the pinned dependency: exact native outgoing
  body, parser callbacks, interior malformed event, fatal-latch wakeup under
  infinite dependency timers, cancellation and cleanup. Direct SSE injection
  proves parser behavior only. Buffered integration separately proves capture
  before conversion, OneShotHTTP1 routing, selected-key screening and cleanup.
- Native streams split across UTF-8, SSE and JSON boundaries; empty/interleaved
  blocks, cumulative usage, signature completion and exact argument assembly.
  Reject duplicate/out-of-order indices, wrong-kind deltas, unknown blocks,
  missing stops, premature EOF and provider error/fallback events before tools.
- Raw-body, pending-parser, expanded-content and block-count boundary vectors;
  repeated pings, slow subscribers and bounded dependency queues. Retain measured
  memory/counter evidence; no full raw-event/chunk log may grow alongside assembly.
- An interior malformed SSE/JSON event followed by valid block/message stops
  remains failed: abandoned progress, conservative started-call accounting,
  cleanup, no canonical reply or tools, and no automatic retry. A parser return,
  flush or later valid terminator cannot hide the lost event.
- Cut the stream before/after signature and block completion, before message
  completion and around reply settlement. Prove provisional progress closure,
  no partial durable answer/tool dispatch, truthful accounting, cleanup in each
  transport profile and no retry/reconnect of dispatched-or-unknown work.
- Crash/commit_unknown cuts at reply settlement, tool intent and next staging;
  no lost capsule, stale source, late-reply activation or duplicate provider call.
- Compact and expanded capsule/aggregate limits, complete-record boundaries and
  context charges, including combined large excerpts and duplicate request
  representations. Measure a useful multi-round fixture with the final generic
  node overhead and revision-4 receipt; earlier prototype sizes are not proof.
  Before ordinary registration of an exact mapping in the tested candidate, complete deterministic
  native request/response and bound conformance. Its owning real-provider cases retain compact/expanded capsule
  sizes, block counts and owning settlement sizes. Synthetic signatures prove
  mechanics only; a live sample promises no future response size. A real bound
  failure remains a failed attempt under the fixed evidence/disposition rule,
  not authority to truncate, enlarge a cap, omit selected summaries, remove a
  required row or replace the attempt.
- Frozen-prefix compaction refusal, same-model restart, terminal invalidation
  and A→B→A without resurrecting old signatures.
- Private-state canaries across both transport profiles, public/progress/trace
  planes, helpers, compaction input, artifacts, backup/restore and ephemeral
  teardown, with the verified-summary projection classified separately above.
- Deterministic same-model/cross-provider history, repeated tool IDs and raw-history
  preservation; real A→B→A with restart and tool results.
- Schema negotiation, events/snapshots and independent client vectors.

<a id="technical-adr-0044-compatibility"></a>
### Compatibility Mechanics and Alternatives

Concept: [Compatibility and rollback](0044-run-model-and-reasoning-configuration.md#concept-adr-0044-compatibility).

This ADR owns M7's coordinated wire-generation replacement in
[the plan's protocol contract](../plans/M7-technical.md#technical-plan-prerequisites).
Foreground `/3` and daemon `/4` use full `loopex.experimental/N` names, distinct
payload-complete schema digests and their existing different authority rules.
Compute each digest with `LoopexProtocol.Canonical.digest/1`, encoding revision
`loopex.canonical.v1`, over one closed manifest with exactly `generation`,
`canonicalization_revision` (the literal `loopex.canonical.v1`), `methods`,
`record_families`, `error_codes`, `limits` and `payload_definitions`. Those
inventories are ordered; definitions include every request, result, public
event/snapshot and referenced nested union. Unknown manifest keys refuse.
Integer-only literal schema data, duplicate-key rejection and pinned list order
make its independent Node preimage reproducible.
Pin every list's order, the manifest preimage and the resulting literal digest
in vectors. JSON transport encoding is not the schema-digest recipe.
Old-only or wrong-server offers refuse before attachment or session authority;
a mixed offer succeeds only for that server's new generation. Preserve the
single initialization attempt and existing refusal framing/lifecycle. Updated
clients verify the independently pinned generation/digest before session work,
and close on mismatch without automatic downgrade or mutation replay. Required
vectors cover refusal, mixed offers, repeated initialization, side-effect
exclusion and both independent clients. Historical schema/vector identities
remain evidence of their original contracts, not M7 live-service promises.
The implementation migration note instructs operators to update wire clients
with the M7 server. Old-session readability and full-root rollback remain
separate decisions; protocol negotiation neither migrates nor downgrades data.

A future adapter may extend capability mapping through a new explicit decision.
No within-run switching, automatic model routing or mutable tool generation is
admitted. Legacy-root upgrade records the inferred configuration only when its
identity is proved. Exact downgrade fixtures must distinguish unchanged staged
requests from new configuration/schema support; backups preserve the prior state.


Source evidence for the selected scope, checked 2026-09-30: the official
[Anthropic tool/thinking workflow](https://platform.claude.com/docs/en/build-with-claude/thinking-tool-workflows)
requires applicable thinking blocks to accompany tool results unchanged. A
text-only completion does not prove that workflow compatible with empty
continuation. Pinned ReqLLM 1.24.0's `adjust_max_tokens_for_thinking/2` raises a
reply limit at or below its thinking budget to that budget plus 201; its legacy
high mapping uses 4,096. Thus a nominal 4,096 can become 4,297. Request-level
vectors and a real admitted tool loop must prove the selected compatibility
subset and unchanged effective reply ceiling. The official
[preserved-thinking rules](https://platform.claude.com/docs/en/build-with-claude/preserved-thinking)
can bind signatures to the full earlier prefix, which requires the exchange
freeze above. ReqLLM capture/render vectors must cover its pinned
`providers/anthropic/response.ex` and `providers/anthropic/context.ex` losses.
No provider credential or live
call was used for this planning research.

The official [stream event contract](https://platform.claude.com/docs/en/build-with-claude/streaming),
checked 2026-09-30, describes indexed block assembly, partial tool JSON,
thinking signatures, cumulative usage and message completion. These event facts
do not supply Loopex dispatch, recovery or publication authority. Pinned local
ReqLLM exposes provider decoding callbacks before ordinary stream chunks, but
its chunk queue does not bound the accumulated response. The implementation
must prove the per-invocation bridge and bounds above with the retained version.

The provider's [thinking display contract](https://platform.claude.com/docs/en/build-with-claude/thinking#controlling-thinking-display),
checked 2026-09-30, distinguishes readable summaries from signatures and omitted
text. Display defaults vary by model. That supports a mapping-specific projection,
not treating all returned thinking text as public or inferring output cost from
visible summary length.
The [mode matrix](https://platform.claude.com/docs/en/build-with-claude/thinking-troubleshooting#thinking-support-defaults-and-rejected-configurations-by-model)
and [manual-mode rules](https://platform.claude.com/docs/en/build-with-claude/extended-thinking#budget-rules-and-tuning)
checked the same day support the proposed rows above. The provider's
[assistant-turn rules](https://platform.claude.com/docs/en/build-with-claude/thinking),
checked 2026-09-30, state that a tool loop is one assistant turn, that manual
mode expects that turn to begin with a thinking block and that an incompatible
history makes the API disable thinking for that request. The post-terminal
oracle above therefore asserts acceptance on that request and thinking on the
next exchange. These references establish
API intent; pinned request encoding, complete native replay and real-provider
acceptance remain separate required evidence.
