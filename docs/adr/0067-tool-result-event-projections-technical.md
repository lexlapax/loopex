<a id="technical-depth"></a>
## Technical depth

Concept: [Tool result event projections](0067-tool-result-event-projections.md#concept).

<a id="technical-adr-0067-decision"></a>
### Existing producers and proposed closed grammar

Concept: [Purpose and proposed decision](0067-tool-result-event-projections.md#concept-adr-0067-decision).

**Authority boundary.** ADR 0023's event projection retains Core public member
names except the envelope and encodes identities, positions and content.
ADR 0045 requires one transaction to settle the question, original tool result,
response identity and next action without executor intent, grant or job.
The vision's public-event rules permit a pre-dispatch tool terminal without an
executor attempt. Those authorities require truthful delivery; they do not pin
the additional closed wire variant below. Both complete current manifests now
require eight fields, `operation_id` as a nonempty identity and `reason: null`.
The proposed pair expressly resolves that incomplete projection grammar.

**Source inventory.** The two native constructors are in
`apps/loopex/lib/loopex/runtime/session_state.ex`:
`tool_finished_event/4` projects an actual job and receipt-backed terminal;
`apply_tool_result_record/2` projects the existing `tool_result_committed_v2`
transition without an operation member. `settle_model_question/2` uses the
latter constructor inside the atomic question settlement and then appends the
interaction terminal. No new Core constructor or recovery record is proposed.

All current runtime callers of the latter path are accounted for here:

| Producer or path | Native outcome and reason | Operation evidence |
| --- | --- | --- |
| Model question text or choice answer | `completed`, reason null; exact text or selected label stays in its existing conversation/interaction records | No executor intent, grant or job |
| Model question decline or expiry | `denied`, respectively `question_declined` or `question_expired` | No executor intent, grant or job |
| Model question cancellation | `cancelled`, reason null | No executor intent, grant or job; abort precedence unchanged |
| Host policy deny, unavailable/defer refusal, repeated defer or recovered policy refusal | `denied`; `policy_denied`, `effect_class_not_permitted`, `workspace_not_permitted`, `interaction_unsupported`, `policy_unavailable`, `interaction_expired`, or the existing retained resolution reason | No executor dispatch authorized by the refusal |
| Tool resolution, argument/artifact resolution, job/grant construction failure, or tagged executor refusal before effects | `failed`; existing `failure_reason/1` text | Some paths already have a retained job/intent; absence in this public shape proves neither presence nor absence |
| Deadline before effect dispatch or proven wrapper non-entry | `cancelled`, `the run deadline passed before dispatch` | An intent and job may already exist |
| Executor result lacking proof, malformed/unretained receipt, or cleanup without confirmation | `outcome_unknown`, existing stable reconciliation reference | May follow actual dispatch; existing unknown fencing and reconciliation remain mandatory |

In `session_coordinator.ex`, `commit_tool_terminal/5` funnels ordinary refusals
and failures; `commit_tool_unproven/4`, `commit_owned_operation_unknown/2` and
`retain_executor_predispatch_deadline/3` cover the latter exceptional paths.
`failure_reason/1` preserves the existing unknown-tool explanation containing the
model's unresolved name, atom/category spellings, or its fixed fallback. The
Model reply validator admits only nonempty UTF-8 call names inside the existing
bounded reply. These reasons are not a finite enum. The proposal does not add
new reason production, inspect arbitrary errors, or expose executor diagnostic
bodies. Actual unknown effects retain their reconciliation reference rather
than the executor error that could not prove a result.

`called_tool_id/1` yields the retained generation's actual ID, or null when the
model name resolved to no active tool. Do not replace that null with the model's
unresolved name. A transport must not make an unresolved tool appear admitted.

**Native payload key sets.** After the existing event envelope is removed,
accept exactly one of these ordinary maps, never a struct or a map with extra
atom/binary keys:

```text
R8 = run_id, turn_id, tool_call_id, operation_id, tool_id,
     outcome, reason, artifacts
T7 = run_id, turn_id, tool_call_id, tool_id, outcome, reason, artifacts
```

The names above are binary keys. Select by exact key set. `operation_id: null`
is neither absence nor a valid R8 identity. Never delete a malformed or private
member to make a payload fit a variant. Encode and decode the whole value or
refuse it whole. There is no fallback from failed R8 validation to T7.

| Member | R8 | T7 | Wire projection |
| --- | --- | --- | --- |
| `run_id`, `turn_id`, `tool_call_id` | Required opaque binary, 1–65,536 bytes each | Same | Canonical unpadded base64url of the original bytes; no UTF-8 round trip or authority inference |
| `operation_id` | Required opaque binary, 1–65,536 bytes | Absent | Same identity encoding when present; never null or manufactured |
| `tool_id` | Required ASCII, 1–128 bytes, `[a-z][a-z0-9_]*(\.[a-z][a-z0-9_]*)*` | Same resolved ID or null | Preserve literal ASCII or null |
| `outcome` | Existing closed union below | Same union | Preserve literal spelling |
| `reason` | Required null | Required null or valid UTF-8 binary, 0–131,072 bytes | Preserve null or exact text, including empty text; no normalization, sentinel, truncation or conversion to an authority token |
| `artifacts` | Required array of existing closed artifact-use references | Required exactly `[]` | Existing artifact encoding; T7 remains empty |

The unchanged outcome union is `completed`, `failed`, `denied`, `cancelled`,
`outcome_unknown`, `cancelled_workspace_lease_lost`. Core's existing result
reducer admits this vocabulary and normalizes the workspace-loss conversation
outcome internally; this ADR changes neither value nor normalization. T7's
currently observed runtime producers use the first five values. No new outcome
or correlation between missing operation identity and retry safety is added.

The T7 reason ceiling reuses the ordinary public reason string ceiling already
implemented by both transports' `event_member/2`; their `tool.finished` gates
currently prevent that member from accepting a non-null reason. This is a
public string bound, not permission to enlarge a private record or retain new
content. Existing Store admission, public provenance, redaction, known-credential
exclusion and model/client payload separation apply before this projection.
Invalid UTF-8, runtime terms or an over-bound reason refuse the entire event.
No diagnostic text becomes public merely because it fits the bound.

Each R8 artifact retains exactly `digest`, `size`, `locator`, `media_type`,
`role`, `use_canonicalization_version`, `use_digest`, `use_locator`.
The digests are 64 lowercase hexadecimal characters, size is native uint64
0–18,446,744,073,709,551,615 and wire canonical decimal text, role is
`tool_output`, canonicalization is `loopex.canonical.v1`, and use locator equals
`use:` followed by the use digest. Existing locator and media-type bounds are
respectively 1–1,024 and 1–255 UTF-8 bytes excluding Unicode Cc, Cf, Zl and Zp.
No paths, private provenance, handles or extra keys are admitted. Existing
recursive/frame cardinality and total record limits continue to apply.

The unchanged native event envelope supplies `:kind = "tool.finished"`,
`:event_id` (opaque, 1–65,536 bytes), and `:event_sequence` (uint64). The wire
envelope is exactly `type`, `session_id`, `event`, with `type = "event"` and
session identity 1–256 native bytes; the nested event has exactly `kind`,
`event_id`, `event_sequence`, `data`. Encode event/session IDs as canonical
base64url and the sequence as canonical decimal. This proposal adds no quantity
or envelope field. Both transport output ceilings and all queue/credit bounds
are unchanged. The entire encoded output frame must fit its existing ceiling;
an individually bounded reason cannot waive that whole-frame check. Refuse
overflow whole without truncating, splitting or silently dropping the result.

<a id="technical-adr-0067-alternatives"></a>
### Alternative mechanics and limits

Concept: [Alternatives and recommendation](0067-tool-result-event-projections.md#concept-adr-0067-alternatives).

An optional-member schema is equivalent only if it imposes the complete R8/T7
constraints above. Merely making `operation_id` optional and `reason` nullable
would lose the R8 private-reason refusal and admit nonempty artifacts without an
operation member. An explicit new producer/tag field would require a new Core
public event field and provenance contract when exact existing key sets suffice.
A synthesized ID, null operation member, dropped event or discarded legitimate
reason would change the original observation.

The union describes bounded public data, not a receipt authentication protocol.
An independently fabricated seven-member map cannot prove its producer; an R8
map stripped of an empty-artifact operation member can be byte-identical to a
valid T7 map. Do not claim a pure codec can distinguish those equal values.
Existing serial-owner commit/publication, outbox integrity and transport
attachment validation remain the provenance boundary. Neither variant supplies
new control, execution or retry authority.

A shared codec is justified by the two current duplicate adapter validators in
`loopex_daemon/wire_records.ex` and `loopex_app_server/delivery.ex`. Keep their
envelope, queue, cursor, credit, detach and lifetime logic where it is. Share
only this closed payload validation/projection; add no service, journal reader,
owner, general event framework or broader Core event rewrite.

<a id="technical-adr-0067-evidence"></a>
### Required evidence and implementation confinement

Concept: [Observable consequences and proof](0067-tool-result-event-projections.md#concept-adr-0067-evidence).

Implementation after acceptance must provide a shared Elixir payload codec and
one literal language-neutral schema/vector corpus for `tool.finished`, plus an
independent Node decoder and vector consumer. Name the selected files in the
implementation source manifest. Pin both native and wire key sets, exact
original opaque bytes, null versus absent, empty versus nonempty reason,
resolved versus unresolved tool ID, outcomes, artifacts and uint64 extremes.
Neither language's expected vectors may be generated from the other decoder.

Negative vectors require missing/extra members, null/empty/invalid operation ID,
R8 non-null reason including the existing `PRIVATE_REASON` canary, R8 null tool
ID, T7 nonempty artifacts, invalid IDs/text/quantities/outcomes, unknown private
members, malformed nested references and boundary-plus-one values. Include
canonical base64url refusal and complete-record framing. Do not weaken the
existing receipt-backed cases or claim rejection of a value identical to an
accepted T7 map.

Keep the complete original cases in:

- `apps/loopex_daemon/test/wire_records_current_events_test.exs`, including
  ordinary event fields and whole-event/private-member refusals;
- `apps/loopex_app_server/test/current_delivery_records_test.exs`, including
  malformed payload detachment while active credit remains owned;
- `apps/loopex/test/tool_event_identity_test.exs`, including repeated denied
  calls, transaction/event uniqueness and refusal of retired identities;
- `apps/loopex/test/agent_loop_test.exs`, including receipt loss after effects,
  tagged pre-effect refusal and unclassifiable executor errors;
- `apps/loopex/test/cancellation_test.exs`, including original-owner and
  recovering-owner unproved-call settlement before run termination;
- `apps/loopex/test/model_question_records_test.exs` and
  `apps/loopex_composition/test/model_question_restart_test.exs` for literal
  question bindings, replay corruption, abort and retained terminal answers;
- `apps/loopex_daemon/test/identity_corpus_test.exs` for actual model-produced
  text, choice and decline answers through one controller socket, malformed
  union and stale epoch refusal without mutation, exact durable terminal
  answer/tool result/digest, model continuation, no executor job and duplicate
  historical admission; and the existing real policy-defer transport oracle.

Add producer-specific projection evidence to both transport files and actual
foreground question transport evidence using the existing fixture. Preserve
all original actors, monitors, joins, failure cleanup, cutoffs and pressure
assertions. The new T7 shape must traverse the real transport without detachment;
malformed shapes must retain existing detach and custody behavior. Do not
replace the failing controller test with disconnected codec assertions or
separate malformed-request traffic merely to conceal a later projection fault.

Run the complete affected files, the complete manifest/negotiation files and
independent Node consumers on the supported pairs through the repository's
qualification procedure. Source discovery selects their actual complete
populations with zero new exclusions/skips and warning-free compilation.
Focused proof does not substitute for the required real transport/release
lanes, full integration or M7 closure matrix. No native result is asserted by
this Proposed pair.

<a id="technical-adr-0067-compatibility"></a>
### Current-contract replacement mechanics

Concept: [Compatibility and rollback](0067-tool-result-event-projections.md#concept-adr-0067-compatibility).

Replace the `tool.finished` definitions in
`apps/loopex_protocol/priv/schema/loopex-experimental-3.json` and
`loopex-experimental-4.json` as one current-contract change. Both complete
manifests must include the exact R8/T7 grammar and any referenced nested schema.
Retain the seven manifest keys, ordered inventories, integer-only data and
`loopex.canonical.v1` canonicalization fixed by ADR 0044. Recompute and retain
literal canonical preimages, byte lengths, schema-file digests and complete
schema digests in `priv/vectors/current-contract-manifests.v1.json`; update
both generation vector assets and every server/client/fixture digest pin that
selects these manifests. The new digests are results of those exact approved
bytes, not values selected in this proposal.

Update `clients/node/contract-manifest.mjs`, its independent complete-manifest
and negotiation consumers, and the independent payload vectors together.
`apps/loopex_protocol/test/current_contract_manifest_test.exs` continues to
prove the whole manifest preimage, inventories and refusal of malformed
manifests. Independently verify every added variant and definition changes each
complete digest; no metadata-only digest or unreferenced auxiliary schema is
sufficient. Foreground and daemon keep distinct server-specific names and
separate complete digests; their differing authority remains unchanged.

Prior pins must fail negotiation/client gating before attachment or mutation.
No old asset, decoder branch or fallback remains live. This is a pre-1.0
current-only replacement, not a claim of old-client compatibility. Existing
private record kinds, original public outbox facts, event IDs/sequences,
settlement transactions and current-format recovery remain unchanged. Replaying
a retained native T7 event uses the same newly accepted projection.

Rollback restores a mutually matching server/client schema asset set without
rewriting journal/outbox bytes. The prior transport still cannot deliver the
existing T7 event and therefore cannot claim this outcome; rollback is not
permission to erase the event, synthesize an operation or mark its proof passed.
Maintainer acceptance binds this exact Proposed pair before implementation;
index/disposition changes and final qualification belong to integration.
