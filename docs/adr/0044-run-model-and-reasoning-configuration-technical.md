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
                  names: <name-to-id/version/digest map>},
 policy_defer_mode: "admit" | "refuse"}
```

Use the existing record envelope for journal version 1, owner epoch 0 and nil
owner incarnation; those are not extra genesis payload members. Definition
format versions distinguish legacy effect definitions from interaction-class
ones. Require each name mapping to match exactly one retained definition and
reject duplicates/unused mappings. Preserve mandatory committed cleanup.
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
at most 128 bytes each and a `thinking` selection. Its closed variants are
`{mode: omitted}`, `{mode: disabled}`, `{mode: manual, budget_tokens: positive_integer}`
and `{mode: adaptive, effort: low | medium | high, display: provider_default}`.
The adaptive display value omits a display override; the pinned mapping must
prove this exact choice supports the retained content format.
No arbitrary provider-option bag is admitted. Include this mapping in the
2-KiB configuration capability budget, and its resolved values in canonical
sampling. Unknown capability permits `default` only and cannot enable a
continuation-required mode without conformance. `default` omits the override;
it does not claim that the provider disables thinking. Manual low/medium/high
map to 1,024/2,048/4,096 thinking tokens. Require `max_tokens > budget_tokens`
and reject a conflicting configuration before commitment. Do not enlarge the
reply limit. Verify the actual outgoing request: dependency translation may
neither raise committed `max_tokens` nor enable an unadmitted mode. Pin the
supported exact model, mapping and renderer in vectors before integration.

**Private reply and request forms.** Revision `loopex.model_request.v2` retains
the same top-level semantic members and digest coverage, admitting `continuation`
as nil or the envelope below. Old v1 bytes remain immutable. An adapter reply
uses `bounded_adapter_reply_v3`, the exact nine fields of ADR 0018's v2 plus
`continuation`, either nil or this closed capsule:

```text
{format: "loopex.anthropic.content.v1", provider: "anthropic", model: exact_model,
 status: "open" | "closed", content: [ordered native content blocks]}
```

The adapter validates closed supported blocks: text, thinking plus completed
signature, redacted thinking plus data, and application tool use. Preserve
all decoded string values and array order exactly. JSON whitespace and map-key
order are not preserved wire bytes. Reject unknown blocks, incomplete streaming
signatures or a mismatch with the canonical reply's text/calls/arguments before
any tool intent or policy evaluation. `tool_use` stop with complete matching
calls means open; genuine `end_turn` with no unresolved calls means closed.
`max_tokens`, unfamiliar stop reasons and incomplete responses fail rather than
masquerading as a completed exchange. Nil is allowed only when the admitted
mapping does not require continuation for that reply. An omitted required
capsule is an unreadable answer, not permission to continue without thinking.

The capsule is private data in its source settlement, whose existing operation,
attempt and request digest bind it. The owner constructs each next request's
closed envelope from committed source settlements, not adapter-supplied journal
identities:

```text
{format: "loopex.anthropic.content.v1", provider: "anthropic", model: exact_model,
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
current request. The owner validates these against source settlements and the
exact projected messages before staging; content matching is never identity.
The adapter validates index, role, call arguments and ID correspondence before
rendering, rejecting missing, duplicate or ambiguous mappings. Each capsule and
the aggregate request envelope are at most 16,384 bytes under ADR 0042's compact
UTF-8 JSON recipe. At most 32 assistant entries and 128 native content blocks
are admitted in one exchange; existing depth/cardinality limits also apply.
Every source must be a canonical, successful reply of this exchange, in order,
under the exact model/configuration/renderer. Late evidence-only replies cannot
supply continuation. Core validates generic identity, bounds and integrity;
the adapter alone interprets provider block schemas. No provider struct, secret,
process handle or arbitrary dependency metadata enters either form.

`bounded_canonical_reply_v3` removes only the echoed `canonical_request_bytes`
from v3, retaining its other nine fields exactly. `model_attempt_settled_v3`
keeps the twelve outer fields and accepts that reply variant. ADR 0021 already
owns v2; never reinterpret v2 records as carrying v3 replies. Preserve its
compact `accounting_evidence` member and closed relations under the new kind. Commit
reply, continuation, usage and next disposition atomically before tool intent.
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

**Lossless rendering and exchange lifetime.** Pinned ReqLLM 1.24.0's ordinary
message conversion drops redacted thinking and groups thinking/text/tools.
Implement bounded capture before that conversion and exact native-array
rendering within the existing adapter transport path, for buffered and streaming
responses. Keep ReqLLM transport/custody/cleanup; no second provider client or
implicit dependency upgrade is authorized. The raw path obeys existing input,
reply, private-channel and cleanup bounds. A mode whose complete blocks cannot
be captured and rendered losslessly is unsupported before dispatch.

Freeze the first request's complete rendered system, tools, messages, artifact
excerpts and canonical-ID mapping. Every next request extends that same prefix
with exact retained assistant arrays and their committed tool results in order.
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

**Accounting and private retention.** The complete staged-request record still
has the 65,536-byte limit, including semantic continuation, its duplicate inside
canonical bytes, receipt, envelope and fixed-point size. No artifact reference
stands in for required native data. Extend ADR 0017's estimator revision to
charge the entire canonical continuation envelope in addition to existing
message/tool/system charges, using the existing ceil(bytes/3) rule. This
conservatively counts duplicated canonical text/tool arguments; it never treats
private state as free or subtracts an unproved provider discount.

Context-provider receipt revision 4, shared with ADRs 0042/0043, adds exactly one
mandatory outer member `continuation_cost`: null for nil continuation, otherwise
`{content_digest, byte_cost, token_cost}`. Compute the digest and byte count over
`Canonical.encode(staged_continuation)` and `token_cost = ceil(byte_cost / 3)`.
The digest is lowercase SHA-256 hex. Recompute all three against the actual
staged request at construction and replay; no caller-supplied cost is trusted.
This is private receipt metadata, not an extra provider message or descriptor.
Keep `totals` and every `by_provenance` bucket equal to their message/tool
descriptor sums. Under estimator `loopex.context_bytes.v2`,
`provider_estimated_tokens = totals.token_cost + continuation_cost.token_cost`,
treating null as zero. Input admission uses that complete sum. Maintenance has
nil continuation and a null cost. Existing receipt revisions 2/3 retain their
original estimator, closed keys and block-only equations. Public projection
retains its existing metadata allowlist; this does not expose the private
continuation or its digest. This accounting recipe describes the currently
proposed continuation representation; a later selected representation must
explicitly re-prove its estimator preimage and rendered-input coverage.
System-class limits stay
separate. Test the final rendered provider input against the declared estimator
preimage; provider tokenization remains an estimate, not a billing guarantee.

Retain private capsules, staged requests and their bindings with raw session
recovery history. Existing private-root ownership/access controls protect durable
plaintext copies; no new encryption or independent lifetime is claimed. The host
retires the complete history under existing retention policy; M7 introduces no
selective continuation collection. Ephemeral runtime teardown removes its owned
state under the existing cleanup contract. Public events, snapshots, history
views, transcripts, helper results, summary input, progress and diagnostics omit
the capsules and native thinking/signature deltas. Expose only bounded format,
size and availability metadata. The raw capture path preserves selected-key
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
No old client receives unknown shapes under unchanged negotiation. Exact vectors
and independent Node client update precede implementation integration.

<a id="technical-adr-0044-evidence"></a>
### Evidence

Concept: [Observable consequences](0044-run-model-and-reasoning-configuration.md#concept-adr-0044-consequences).

- Atomic creation/configure, strict validation, version capture and idempotency.
- Revision-4 continuation-cost null/non-null branches, exact digest/cost replay,
  descriptor totals versus complete input estimate, unchanged v2/v3 equations,
  and public exclusion of the private cost digest. A missing or fabricated
  continuation charge cannot pass input admission.
- Active/unresolved change refusal; legacy model derivation versus conflict.
- Restart at configure and staging boundaries preserves configuration/digest.
- Reasoning capability negatives, default omission versus verified disabled mode,
  and unchanged outgoing reply limits for manual and admitted adaptive modes.
- Real-provider continuation after a bound or cancellation immediately after
  tool results, followed by a new user prompt on the same thinking model.
  Verify the exact rendered message grouping and provider acceptance without
  resurrecting old native state or inventing an assistant completion. A mapping
  that cannot render this canonical history is unsupported and refuses by name;
  do not claim that one successful ordinary end_turn proves this path.
- Native/derived ID collision yields the named unreadable-answer or staging
  refusal before tool dispatch, with usage truth preserved.
- Privacy witnesses name chat transcripts, one-shot JSON, independent Node
  history/snapshots, diagnostics and ReqLLM telemetry. Host crash dumps and
  trusted host-installed handlers retain ADR 0039's stated host-VM audience;
  the private-store and credential guarantees must not imply secrecy from it.
- A real selected Claude thinking/tool loop, including multiple tools/rounds;
  raw block fidelity, redacted/interleaved blocks, signatures and native ID mapping.
- Crash/commit_unknown cuts at reply settlement, tool intent and next staging;
  no lost capsule, stale source, late-reply activation or duplicate provider call.
- Capsule/aggregate/complete-record boundaries and context charges, including
  combined large tool excerpts and duplicate request representations.
- Frozen-prefix compaction refusal, same-model restart, terminal invalidation
  and A→B→A without resurrecting old signatures.
- Private-state canaries across both transport profiles, public/progress/trace
  planes, helpers, summaries, artifacts, backup/restore and ephemeral teardown.
- Deterministic same-model/cross-provider history, repeated tool IDs and raw-history
  preservation; real A→B→A with restart and tool results.
- Schema negotiation, events/snapshots and independent client vectors.

<a id="technical-adr-0044-compatibility"></a>
### Compatibility Mechanics and Alternatives

Concept: [Compatibility and rollback](0044-run-model-and-reasoning-configuration.md#concept-adr-0044-compatibility).

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
