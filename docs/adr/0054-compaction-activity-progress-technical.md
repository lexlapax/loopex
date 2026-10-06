<a id="technical-depth"></a>
## Technical depth

Concept: [Compaction activity progress](0054-compaction-activity-progress.md#concept).

<a id="technical-adr-0054-context"></a>
### Current source and authority

Concept: [Purpose and current gap](0054-compaction-activity-progress.md#concept-adr-0054-context).

The inspected source is `28c8e86bcdaa182bd5a9664246ba72b2052cc2c9`, whose
compact-only ingress is a source checkpoint, not runtime proof. Relevant bodies
are unchanged from its parent `4ee52100dbe6a532f8cf83fa250c1f4c6b52c66d`:

- [ADR 0043 technical depth](0043-context-compaction-checkpoint-technical.md#technical-depth)
  names transient progress, episode/summary identities and checkpoint-last
  publication. The [M7 contract](../plans/M7-technical.md#technical-depth)
  requires the new record with both current wire generations.
- [SessionState](../../apps/loopex/lib/loopex/runtime/session_state.ex)
  `propose_maintenance_request/4` commits the maintenance request and opened
  provider attempt together. `maintenance_source_episode/3` derives a further
  summary ordinal from an actual committed checkpoint.
  `maintenance_public_view/1` derives owner `run` from the automatic admission
  or owner `compact` from the standalone admission.
- [SessionCoordinator](../../apps/loopex/lib/loopex/runtime/session_coordinator.ex)
  `advance_compact_episode/2`, `start_model_work/2`, `provider_work/2` and
  `dispatch_provider_attempt/2` share the actual maintenance dispatch path.
  `provider_work/2` binds committed episode, summary ordinal, operation,
  attempt and staged digest through `ProviderAttempt`.
  `model_progress_fun/2` deliberately returns a discarded progress callback
  for maintenance. Ordinary model deltas use a separate relay and turn domain.
- [Control](../../apps/loopex/lib/loopex/runtime/control.ex)
  `provider_dispatch/3` serializes exact binding, owner, position, worker,
  deadline and one-use permit checks. Its positive reply follows the permit
  send, not confirmation of provider entry. `project_progress/5` serializes
  the current-owner fence with admission to the progress relay.
- [StreamDomain](../../apps/loopex/lib/loopex/stream_domain.ex) currently admits
  only model/executor domain kinds. [StreamRelay](../../apps/loopex/lib/loopex/runtime/stream_relay.ex)
  supplies ordinary stream sequence/closure ownership. The new activity family
  must not borrow a turn domain or produce a model closure with no model turn.
- [Foreground Delivery](../../apps/loopex_app_server/lib/loopex_app_server/delivery.ex)
  `progress_record/2` and [daemon WireRecords](../../apps/loopex_daemon/lib/loopex_daemon/wire_records.ex)
  `progress/2` currently encode domain/base and otherwise pass native members
  through. Both require an explicit closed projection for the new family;
  nested opaque identities must not be passed as unencoded native binaries.

These bodies explain the proposed insertion cuts. They do not constitute an
existing producer, approved schema or measured emission guarantee.

<a id="technical-adr-0054-decision"></a>
### Exact closed payload and derivation

Concept: [Proposed decision](0054-compaction-activity-progress.md#concept-adr-0054-decision).

The native item is a plain map with exactly these atom-keyed members; `owner`
is the existing plain string-keyed two-member CheckpointOwner shape:

```elixir
%{
  kind: "context.compaction_progress",
  episode_id: episode_id,
  owner: %{"kind" => "run" | "compact", "id" => owner_id},
  stream_domain_id: domain,
  progress_sequence: 0,
  base_event_sequence: base
}
```

The quoted alternatives in this notation describe a closed union, not a literal
Elixir expression. Every member is required and non-null. Structs, missing or
extra fields, alternate keys and other kind values refuse. The native identity
ceilings are the existing 1–65,536 original bytes for episode and owner; their
bytes are opaque, not required UTF-8. The owner is exactly the committed
maintenance view's owner, never a caller-selected correlation value.
`base` is an integer in `0..18_446_744_073_709_551_615`, captured from the
coordinator's committed public event cursor when constructing the observation.
It never advances that cursor. `progress_sequence` is exactly integer zero;
it gives this one-item domain its only sequence and supports equality-based
consumer deduplication. No sequence or count comparison spans domains.

The wire envelope is exactly the existing progress record shape:

```text
{type: "progress", session_id: identity, progress: {
  kind: "context.compaction_progress",
  episode_id: identity,
  owner: {kind: "run" | "compact", id: identity},
  stream_domain_id: identity,
  progress_sequence: "0",
  base_event_sequence: canonical_u64
}}
```

All keys above are JSON strings. Identities use the existing canonical unpadded
base64url encoding, including the domain's native 32 ASCII bytes. Base uses
canonical unsigned decimal, with zero rendered as `"0"`. JSON numeric quantities,
padding, alternate encodings, nulls and extra members refuse. Reuse
[CheckpointOwner](../../apps/loopex_protocol/lib/loopex_protocol/session/checkpoint_owner.ex)
for the exact owner encoding and existing Wire scalar codecs. Apply the selected
current manifest's existing total frame and progress-queue byte/record ceilings
independently of field ceilings; no limit increases or unconstrained pass-through
are authorized.

The coordinator computes the native domain using ADR 0011's existing
length-aware canonical encoding and truncated digest recipe, adding only the
finite domain kind `"compaction"`:

```text
lowercase_hex(first_16_bytes(sha256(canonical_encoding({
  "loopex.stream_domain.v1", "compaction", session_id,
  committed_maintenance_operation_id, committed_model_attempt
}))))
```

The attempt is the integer itself. The domain is exactly 32 lowercase ASCII
hexadecimal bytes and opaque under equality. Its encoding is unambiguous;
truncated-hash collision resistance is not injectivity or authority. Neither
the label nor a progress emission counter is persisted. A retry changes the
committed attempt; a further summary changes the committed operation. Both
produce a new domain. The private ordinal, operation, attempt and digest are
not payload fields. Domain stability does not authorize replay or redispatch.

The proposed amendment to ADR 0011 adds this domain kind and exempts only this
single-observation family from closing/count/disposition requirements. There is
no `context.compaction_progress_closed` or ordinary model-stream closure for it.
Ordinary model/executor rules and ADR 0014's current-owner/loss restrictions
remain unchanged. The observation is not evidence that the attempt ended.

<a id="technical-adr-0054-delivery"></a>
### Producer cuts and loss behavior

Concept: [Emission, succession and privacy](0054-compaction-activity-progress.md#concept-adr-0054-delivery).

1. Use the existing automatic or standalone committed episode and actual opened
   attempt. Unknown Store outcomes still fence work; no observation precedes
   established committed attempt identity.
2. In the shared `dispatch_provider_attempt/2` path, only the
   `Control.provider_dispatch/3` reply `{:ok, :dispatched}` permits constructing
   this observation. That reply proves a sent permit, not that the receiver
   sampled its deadline or entered the model callback. A negative, lost or
   malformed reply emits none, even if transport work may actually have begun.
3. Admit and send the item through the serialized current-owner boundary.
   Reuse bounded session progress routing; checking the owner and later calling
   an unguarded sink is forbidden. Any relay used for this one-item projection
   has the existing owner lifetime, bounded state and actual cleanup; it cannot
   accumulate per-attempt workers or fabricate a closing record. Delivery must
   not run an arbitrary sink callback in Control or block provider settlement.
4. Within this owner, emit at most once for that positive attempt-dispatch
   result. Repeated commands, an in-flight dispatch, completed command replay
   and retained attempt recovery produce no new activity for the same attempt.
   This is an emission obligation when the owner and plane remain available,
   not acknowledged delivery or durable exactly-once behavior across death.
5. Keep maintenance provider progress discarded. Source preparation, source
   refusal, checkpoint-pending validation, checkpoint commit and terminal
   completion do not generate variants or follow-up observations.

A handoff between permit and projection can make Control refuse the old
owner's item. Owner death can lose it or a queued delivered item. A successor
cannot know whether the old send happened and never reconstructs it from the
journal or snapshot. Ambiguous permit use remains settled by the existing
maintenance ownership/uncertainty rules; progress never authorizes another
provider call. A genuinely new allowed attempt produces only its new domain.

The record can be dropped/coalesced under existing backpressure. Reattachment
replays durable history and supplies the current snapshot, not old activity.
No closure or silence is interpreted as failure, inactivity or success. A
client receiving delayed activity after a newer durable completion uses the
committed cursor/view for current status; the observation cannot reopen it.
No ordering between transient arrival and durable delivery is promised beyond
the item's base cursor. Transient activity never enters history, private
recovery, checkpoint/receipt integrity, or retained run-accounting evidence.

The allowlist excludes text, model/provider fields, source offsets or sizes,
stage, attempt/ordinal, measurements, usage, digests, timestamps, routes,
credentials, lease/fence/session epochs, permits and native handles. The
owner/session/episode labels and arrival timing remain observable to the
already attached audience, with the existing host-controlled audience and
retention limits. They confer no permission or provider capability.

<a id="technical-adr-0054-alternatives"></a>
### Alternative contracts and implementation cost

Concept: [Alternatives and consequences](0054-compaction-activity-progress.md#concept-adr-0054-alternatives).

The recommended single-item rule needs one closed codec/projection, the new
finite domain kind and one emission cut shared by both maintenance owners.
It deliberately cannot drive a phase-specific progress bar. Its sequence is
always zero and it offers no tail-loss or completion accounting.

A viable phase-stream alternative would add an approved finite `activity`
vocabulary such as `preparing`, `summarizing`, `validating`, per-domain
monotone sequence, and a separate closing payload with disposition/count.
Preparation and validation span more than one provider attempt, so that choice
must decide whether the domain is the whole episode or several attempt streams
before naming its exact derivation. Episode ownership would require a different
identity recipe; it cannot be silently substituted for ADR 0011's attempt
recipe. Phase transitions, uncertain commits and quiet-owner death need actual
producer/closure controls. This exposes private scheduling structure and grows
both public contract and test matrix without establishing durable completion.
It is an alternative for a separate selected decision, not an optional extension
or accepted payload in this proposal.

<a id="technical-adr-0054-activation"></a>
### Coordinated activation and verification

Concept: [Activation, compatibility and required proof](0054-compaction-activity-progress.md#concept-adr-0054-activation).

Activation includes the closed native codec, coordinator/Control routing,
foreground Delivery and daemon WireRecords projection, complete foreground
experimental generation 3 and daemon experimental generation 4 manifests and
schemas, independent vectors and both reference clients. Pin the whole selected
served schema digest. A standalone schema or producer does not establish the
current generation. Preserve attachment/controller/writer-epoch admission and
all existing leases, relay bounds and command retry behavior. No new command,
Model callback, host context or persistent field is introduced.

Required proof is claim-proportional and includes:

- Closed native/wire round trips and independent literal vectors for both owner
  kinds, canonical opaque binary IDs, base zero/u64 maximum, fixed sequence
  zero, wrong kinds, null/missing/extra fields, alternate identities/quantities
  and enclosing frame/queue limits; both adapters produce identical payloads.
- Real coordinator automatic and standalone maintenance with the actual permit
  owner; no observation before committed attempt/positive permit, no provider
  delta disclosure, and exact binding to the actual episode/owner/domain/base.
- Permitted retry and next-summary domain separation, command duplicate replay,
  negative/uncertain dispatch and commit fencing, and terminal completion
  remaining a separate durable fact rather than a progress variant.
- Controlled succession/death between permit and projection, stale-owner
  refusal, no successor replay or synthetic closure, joined finite routing
  workers, and no growth/backpressure delay in the serial session owner.
- Dropped/coalesced activity, reattachment after loss, delayed activity after
  durable completion and a client that never infers outcome from silence.
- Privacy controls with actual summary content and private binding data; reject
  accidental fields before projection, with no generic serialization fallback.

No current runtime evidence is claimed by this Proposed pair. Implementation
and the applicable current/floor and selected wire/daemon verification remain
owed. Acceptance does not waive any existing long, real-path or integration
check. Existing journals and public durable records are unchanged, so there is
no old-root decoder, migration or cross-version rollback path. Removing or
changing an activated payload requires a governed coordinated current generation;
restoring an unactivated source checkpoint does not rewrite retained history.
