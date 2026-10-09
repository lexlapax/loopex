<a id="technical-depth"></a>
## Technical depth

Concept: [Owned artifact transfer opening](0066-owned-artifact-transfer-opening.md#concept).

<a id="technical-adr-0066-decision"></a>
### Current owners and proposed boundary

Concept: [Current owners and proposed boundary](0066-owned-artifact-transfer-opening.md#concept-adr-0066-decision).

Current Runtime starts no original clock before its infinity dispatcher call; EventDispatcher invokes callbacks serially and ignores close disposition; Local.Artifacts describes before Transfers queues/stat-checks and captures a later verification clock. The following are PROPOSED rules, not current behavior.

Runtime owns the clock/response. Responsive EventDispatcher owns attachment authority, original admission slots, permission/adoption and custodian/observer monitors. One original Core custodian reserves, waits for permission, opens and stays owned through live/retiring custody. Responsive Local.Transfers owns capacity/bindings/revocation/receipt and one original I/O actor/monitor; that actor acquires use/source/snapshot descriptors with cleanup at acquisition, verifies once and becomes the reader. One persistent Core observer performs successive close/status/ack phases while other actors block. Local.Artifacts remains the adapter; Core opens no path. JobRange illustrates actual disposable I/O, not authority to borrow its JobRequest/source/grant/budget.

Links/kill requests do not prove descriptor retirement. Existing Composition tracks original edge identities, not the proposed per-opening recovery proof. No new service, global registry, persistent ledger, fabricated job or owner framework is proposed.

<a id="technical-adr-0066-capability"></a>
### Closed callback and data grammar

Concept: [Closed callback and data grammar](0066-owned-artifact-transfer-opening.md#concept-adr-0066-capability).

The capability is optional as a whole. Superseded optional open_transfer/4 is removed only with coordinated callers/capability detection/conformance; no fetch fallback or mixed generation. Read/3 remains the existing sequential chunk callback and its result/limits.

All maps below are closed plain data: exact members, no structs or unknown keys, native handles, paths, functions or caller-selected object. Named native actors/monitors stay private to their actual owners. The composed handle is captured by Core, never supplied as public authority.

| Record | Exact fields and domains |
| --- | --- |
| request | session_id=actual routed opaque binary within its existing owning limit; use_locator=`use:`+64 lowercase hex; start=unsigned64 integer; optional length=unsigned64 integer. Absent length means remaining window; null refuses. |
| context | transfer_ref=original fresh lowercase32-hex identity; open_deadline_ms=original signed originating-VM monotonic D_open; object_work_bytes=134217728; metadata_read_bytes=131073. Same immutable record for reserve/open. |
| object | Existing ArtifactStore object triple digest, size, locator with its exact owning validation; size<=67108864. |
| transfer | transfer_ref, object, use_locator, total_size, window_start, window_length, object_digest: existing seven-member projection, preallocated ID and exact object/use/window equalities. |
| use | canonicalization_version, object_digest, object_size, object_locator, media_type, role, metadata. Existing canonical/scalar/digest limits apply; metadata is exactly session_id, run_id, operation_id, attempt, tool_call_id with existing lossless opaque ID and positive-attempt domains. |
| work | source_read_bytes=0..67108864; snapshot_write_debit=0..67108864; their sum<=134217728; metadata_read_bytes=0..131073; write_uncertain=Boolean. No unknown accounting is represented by a fabricated zero map. |
| retire selector | action=:retire, transfer_ref=original ID, open_deadline_ms=original D_open, close_deadline_ms=original D_close. |
| ack selector | action=:acknowledge, transfer_ref=original ID, receipt_ref=Store-produced lowercase32-hex value bound to that entry's original retirement proof. Receipt is correlation, not client authority. |

For valid original request/context, callbacks and result grammar are:

```elixir
reserve_transfer(handle, request, context)
  {:ok, %{transfer_ref: id}}
  {:error, %{reason: closed_reason, transfer_ref: id, state: :not_reserved}}

open_transfer(handle, request, context)
  {:ok, %{transfer: transfer, use: use, work: work}}
  {:error, %{reason: closed_reason, transfer_ref: id, work: work,
             state: :retiring | :retired}}

read_transfer(handle, transfer, length)
  # Existing callback, closed chunk {offset, bytes, chunk_digest} or completion/refusal.
  {:ok, chunk} | {:ok, :complete} | {:error, reason}

close_transfer(handle, retire_selector)
  {:retired, %{transfer_ref: id, receipt_ref: receipt, work: work | :unavailable}}
  {:unregistered, %{transfer_ref: id}}
  {:error, :cleanup_unproved} | {:error, :invalid_close_context}

close_transfer(handle, ack_selector)
  :ok | {:error, :retirement_receipt_mismatch} | {:error, :invalid_close_context}
```

These forms are specification alternatives, not implementation code. Malformed/pre-admission inputs use their existing bounded refusal before reservation, with no echoed invalid identity or invented custody/accounting. Admitted closed_reason is exactly invalid_artifact_request, invalid_open_context, reservation_required, reservation_conflict, unknown_artifact_use, artifact_use_mismatch, artifact_integrity_failed, artifact_digest_mismatch, unknown_artifact, artifact_too_large, invalid_window, open_deadline_exhausted, open_work_budget_exhausted, transfer_limit_reached, transfers_unavailable, artifact_unreadable or cancelled. Exceptions, malformed/unavailable producer results and lost accounting are host-observed uncertainty, not a valid work map; retain conservative reservation/unavailable internally and map to admitted facade refusal with cleanup unproved. Private errors/stack details remain diagnostics.

Reserve success means bounded validation, clock checks, original caller monitor and capacity/binding installation have completed with no I/O: no describe/stat/descriptor/scratch/verification. A not_reserved refusal proves no admitted reservation remains; an exception does not. Open requires the exact acknowledged entry and same actual callback caller, is one-use, and rechecks binding/clock before I/O. Duplicate, absent, changed-caller/context/request and revoked/expired entry refuse before I/O. Core validates returned use canonical bytes/digest against original use_locator and session, plus exact object/window equalities, using ArtifactStore-owned pure checks without another live describe or copied validator. Public success retains the current compact projection; admitted failure is proposed `{:error, %{reason: closed_reason, cleanup: :proved | :unproved}}`, without private work, provenance, receipt or pending ID. Its exact coordinated DTO/schema mapping is part of choice1.

A retired result requires original Store I/O/descriptor/scratch retirement evidence. It does not yet prove Core custody is joined. Store retains exactly one receipt/accounting record in the original slot. Unregistered alone proves nothing about queued calls. Ack removes the matching retained record once, without I/O; an already-removed ack is an idempotent no-op and not new proof. Wrong receipt for an extant entry refuses. Core never acknowledges unregistered/unproved custody.

<a id="technical-adr-0066-custody"></a>
### State, actors and bounded cancellation order

Concept: [State, actors and bounded cancellation order](0066-owned-artifact-transfer-opening.md#concept-adr-0066-custody).

Core states are pending/reserving, reserved-awaiting-permission, opening, adopted-live, retiring, retired-awaiting-ack/joins and released. Store states are reserved, verifying/live, retiring and retired-awaiting-ack. Cancellation revokes Core permission/adoption immediately; Store serial revocation prevents new I/O when retirement is processed. Completed/uncertain work is never undone or refunded.

Pending/live/retiring/unacknowledged-proof entries and real job reservations occupy the existing four Store slots. Core keeps the original attachment ceiling two/runtime ceiling four, including after attachment removal. Actor records, not only payload/descriptor records, remain in those original entries. Adopted-live is not a transition that drops the custodian monitor: the same custodian completes reserve/open invocation, reports evidence and remains owned through reads/retirement. Its DOWN while live triggers retirement; a normal exit after adoption cannot silently close an otherwise successful transfer. For an admitted Store reservation/transfer, it exits in the normal cleanup path only after exact receipt acknowledgement, and its actual original DOWN is joined before Core release/cleanup success. The conclusively never-reserved terminal branch below requires no receipt or acknowledgement; all relevant original joins still precede Core release/cleanup success.

Each entry creates at most one original persistent close/ack observer. It can perform one retire/status/ack invocation at a time. Repeated facade close/shutdown requests reuse the existing pending disposition or receive bounded cleanup_unproved; they do not queue unbounded waiters or spawn another observer. If its original callback is blocked, no second invocation/actor is admitted. If a callback returned unproved, a later explicitly requested observation may use the same observer and original selector/cutoff; there is no automatic polling/retry loop. A completed lost-ack outcome may be observed again through that same original observer using the same receipt, never while an earlier invocation remains outstanding. Original observer loss is retained as loss/uncertainty; no successor actor is silently treated as the original. Where no surviving admitted evidence path can finish, the slot remains occupied/unavailable.

Cancellation before reservation:

1. Dispatcher marks the original entry cancelled and revokes permission first, retaining its slot/custodian/clock.
2. An outstanding reservation call stays owned and can authorize no I/O. Unknown/unregistered close is not successful cleanup.
3. Late reservation success asks the same dispatcher for permission; cancelled/expired permission refuses and the original observer retires the acknowledged entry. A conclusive original not_reserved reply enters the separate no-reservation terminal branch below, with completion and joins of the original custody before release.
4. Custodian/dispatcher loss before registration response is observed through the Store's captured original caller monitor; a late-created entry retires without I/O. Queued reservation at/after D_open refuses before allocation; a post-allocation clock check unwinds a boundary race before acknowledgement. Reservation alone never launches I/O.
5. Lost registration may reclaim a never-reserved entry only after original custodian join, no permission issued, expired D_open and actual original Store-owner confirmation of no entry under exact original ID/context. Without all facts it stays unproved. No permanent cancellation tombstone is required.

After permission, a queued open still needs the same acknowledged entry/caller/context and D_open. If Store verification won an earlier race but Core cancellation/expiry won adoption, its result is retirement evidence only. No chunk is emitted or late success adopted.

Conclusive never-reserved completion is a separate terminal branch:

1. For the conclusive-reply route, the original reservation invocation has completed with its valid not_reserved refusal, and the exact original entry has conclusive evidence that no permission or I/O was issued and no admitted Store reservation remains. Any acquired original callback/observer invocation must have completed; a blocked invocation is not settled custody. Missing response, exception, unregistered alone or lost evidence cannot establish this branch.
2. Dispatcher may complete the original custodian and the original observer, if acquired, without any Store retirement receipt or acknowledgement. It joins their exact original monitors and every other acquired original callback/worker custody before releasing its Core slot once or reporting cleanup proved. There is no Store receipt record to acknowledge or Store reservation slot to release in this branch; an idempotent acknowledgement cannot manufacture that proof.
3. For the alternative lost-registration route, retain the stronger rule in cancellation step5: original custodian join, no permission issued, expired D_open and actual original Store-owner confirmation of no entry under exact original ID/context are all required. An already-observed original custodian loss/join is retained as original evidence, not replaced by a fresh monitor. Only after that complete barrier supplies conclusive no-reservation evidence may remaining original observer/callback custody complete and join, and the Core slot release. No missing registration reply is promoted to a not_reserved reply.

Both terminal branches spend the original D_close for timely cleanup. Late conclusive evidence and original joins may reclaim capacity prospectively only; they never renew a cutoff, change an earlier failure response or supply retroactive timely success.

Reserved/adopted retirement/reclamation has one explicit order:

1. Store revokes admission and proves its original I/O actor/descriptors/scratch retired, retaining one receipt and final bounded work or explicit unavailable accounting.
2. Original observer returns that evidence to the exact dispatcher entry. Core validates it and verifies the original reserve/open invocation has completed; the custodian remains owned/alive. If that invocation is still blocked, no complete Core cleanup is asserted.
3. The same observer acknowledges the exact receipt. Store removes only that record/slot. Core retains its own slot and original identities until it has observed the ack result.
4. Dispatcher completes the original custodian and observer; joins their exact original monitors, and any other acquired original callback/worker custody. Only then releases its Core slot once. Timely public cleanup additionally requires every step below original D_close. No join-before-ack instruction silently kills the live monitored custodian.

Late reserved/adopted outcomes follow exactly that receipt-bearing order but reclaim prospectively only. A lost ack reply does not provide proof: the original retained receipt/native evidence remains, and blocked observer means retained uncertainty. Repeated ack :ok is useful only with that already-held original proof. It cannot establish retirement on its own. Early opening refusal reports cleanup proved only if its applicable terminal branch has completed: relevant original custody/ack/joins for a reserved/adopted entry, or conclusive no-reservation evidence and all relevant original joins for a never-reserved attempt. Otherwise it reports unproved and keeps the original custody owned.

If original Store/dispatcher owner or name is lost, a surviving admitted existing supervision/host boundary may finish only from actually retained original identities/proof. Without it, continued unavailable/occupied is the disposition for that original runtime/handle, including removed attachments and uncertain runtime stop. A fresh owner, reopened scratch path, successor PID or new monitor cannot reconstitute proof or reuse that generation's occupied slots. No VM-wide gate, new persistent recovery schema or speculative guardian service follows. External VM-exit containment is a distinct proof and is not inferred from in-process timeout. Links/sending kill alone do not prove blocked I/O physically gone; supported platform cleanup must be qualified.

<a id="technical-adr-0066-clocks"></a>
### One opening clock and one cleanup observation

Concept: [One opening clock and one cleanup observation](0066-owned-artifact-transfer-opening.md#concept-adr-0066-clocks).

Runtime captures t_open=`System.monotonic_time(:millisecond)` before storage-related queuing, allocates original 32-hex ID and sets D_open=t_open+60000. Request/context remain immutable. Dispatcher revalidates token, routed session, attachment/incarnation before admission and before adoption. Reservation, use read/decode/digest validation, stat, verification, response validation and adoption all spend D_open; actual pre/post observations must be strictly below it. Remote adapters enforce the originating VM's clock there, never compare unrelated clocks.

Success requires completed/adopted original proof below D_open. Early failure returns immediately; at D_open opening responds open_deadline_exhausted with cleanup unproved unless already proved. Runtime/Dispatcher own response independently of a blocked callback. No synchronous opening wait extends to D_close. Scheduling overrun is failed elapsed evidence, not a hidden grace or hard-real-time promise. A host may refuse earlier but no undocumented alternate callback-limit dialect is introduced.

D_close=first cancellation/close anchor+proposed 5000. Opening expiry anchors at D_open itself, not late handling; earlier failure anchors at its first observation. Every send/escalation, original invocation completion, applicable Store proof and receipt/ack, conclusive no-reservation evidence, original joins and Core release shares this original ceiling. No separate grace or join allowance. Explicit close waits only within it and returns cleanup_unproved on expiry; repeated expired close remains an elapsed failure even if later proof is learned. A potentially long-lived original callback waiter stays count-bounded/owned after the observation expires. It is not a renewed synchronous facade wait or permission for another attempt.

<a id="technical-adr-0066-accounting"></a>
### Work metric and exact unchanged ceilings

Concept: [Work metric and exact unchanged ceilings](0066-owned-artifact-transfer-opening.md#concept-adr-0066-accounting).

Before sidecar I/O reserve its 131073-byte metadata allowance; before object I/O, after verified N, reserve 2*N payload bytes with N<=67108864. Charge returned source bytes once. Reserve/debit attempted snapshot-write length before dispatch on success or failure; failed write sets write_uncertain, with no invented physical partial-write count. Failed/cancelled work charges once and never refunds; lost accounting retains conservative reserved debit/unavailable, not zero.

Current Local.read_use performs one first read up to131073 and, only after accepted<=131072 bytes, one trailing-byte probe. Thus total returned sidecar bytes<=131073; canonical cap131072, exact use/session/digest and source object bindings refuse before source open. One sidecar open/two reads/close, one canonical validation, fixed source pre/post descriptor-stat, one source open, snapshot create/chmod/unlink/cleanup and at most 1024 successful64KiB verification blocks plus terminal short/error are a finite application-issued inventory. They all spend D_open. No retry/second describe; no claim about filesystem-internal traffic or heap/page capacity.

| Metric | PROPOSED consequence |
| --- | --- |
| Full64MiB verification | 67108864 source +67108864 write debit =134217728 payload bytes; metadata is explicitly additional, at most 131073. |
| Single128MiB total-returned-byte alternative | floor((134217728−131073)/2)=67043327 object bytes at maximum metadata; full 64MiB opening is then refused. No silent size/budget change. |
| Connection work | max(1048576, source_read+snapshot_write_debit+metadata_read) per open, plus emitted snapshot reads once; failures/cancellation charge once. Cap1073741824 per actual connection remains. Full save can cost201457665 bytes including maximum metadata. |

The cumulative connection owner/binding remains separately required implementation/proof, not a completed ledger or job-budget substitution. Unchanged accepted ceilings: object67108864; verification buffer65536; read chunk32768; read deadline5000ms; transfer lifetime600000ms from successful open; two transfers per connection/attachment and four per runtime. Actual job reservations share Store headroom under their own genuine source/grant contract. These existing numbers authorize no cleanup observation allowance.

<a id="technical-adr-0066-verification"></a>
### Required proof

Concept: [Required proof](0066-owned-artifact-transfer-opening.md#concept-adr-0066-verification).

Complete original ArtifactStore/Local transfer+JobRange+scratch/Core runtime+event/Composition artifact suites and actual foreground/daemon/reference/Node consumers remain required; select whole files/expanded cases only after accepted source exists. No numerical native census or PASS is invented. Required additions must prove:

- queued reservation/cancel-before-permission/cancel-during-open and adoption; late registration touches no descriptor; original owner loss during reserve/open/close;
- original custodian alive after adoption and throughout normal reads; original caller loss retires the same reader; no unrecorded monitor handoff;
- conclusive never-reserved completion has no receipt/ack and releases only after exact original custody joins; lost registration additionally requires the original custodian join, expired D_open, no permission and exact original Store-owner confirmation; unregistered/missing-response/exception negatives retain uncertainty;
- concurrent/repeated close with a blocked first observer keeps actor/monitor/entry cardinalities constant; ack reply loss, actual original joins and exact late single-slot reclamation;
- original 60s response independent of cleanup 5s; boundary equality/late response fail; cleanup expiry/re-observation never renews or rewrites success;
- real jobs plus pending/live/retiring/proof entries obey headroom; unavailable/lost accounting and wrong request/context/caller/receipt refuse;
- metadata cap/cap+1/trailing and session/digest mismatch before object I/O; full 64MiB positive; short reads/partial writes/source mutation/corruption; original descriptor/private-unlinked-snapshot release.

Keep all original windows, grants, corruption negatives, clocks, process joins, actual actor/group/credit controls and physical byte proofs. Unsupported environment is UNRUN, not PASS. No original required acceptance case or bound is dropped by this proposal.

<a id="technical-adr-0066-compatibility"></a>
### Coordinated migration and rollback

Concept: [Coordinated migration and rollback](0066-owned-artifact-transfer-opening.md#concept-adr-0066-compatibility).

After governed disposition, migrate together: ArtifactStore types/capability detection/pure validation and reusable conformance; Runtime original cutoff/response; Dispatcher pending admission/permission/adoption/removal/retirement; Local.Artifacts/Transfers actual custody; all adapters/wrappers/fakes; facade and current DTO/schema/handler mappings. Delete open/4 after coordinated callers, with no old-wire/fetch fallback or serving-generation activation shortcut. Preserve put/fetch/stat/describe, persisted objects/uses and read_job_range. Rollback is quiescent same-format source replacement, not mixed callback generations or deleting retained facts.

