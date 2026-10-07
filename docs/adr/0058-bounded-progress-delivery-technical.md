<a id="technical-depth"></a>
## Technical depth

Concept: [Bounded progress delivery](0058-bounded-progress-delivery.md#concept).

<a id="technical-adr-0058-context"></a>
### Source and authority

Concept: [Purpose and observed gap](0058-bounded-progress-delivery.md#concept-adr-0058-context).

Inspected source is `6a5be6a26417672f88f38138541248bf79661e9c`.
The accepted [M7 plan](../plans/M7.md#concept),
[ADR 0011](0011-session-input-algebra-and-streaming.md#concept), its
[owner-loss qualification](0014-stream-closure-at-owner-loss.md#concept),
[ADR 0023](0023-experimental-public-session-protocol.md#concept), and
[ADR 0054](0054-compaction-activity-progress.md#concept) govern the existing
progress meanings. The founding [ownership](../vision-technical.md#technical-vision-ownership-trust),
[dependency](../vision-technical.md#technical-vision-dependency-doctrine) and
[backpressure](../vision-technical.md#technical-vision-public-protocol)
boundaries constrain this proposal.

Concrete paths at the inspected revision are:

| Cut | Actual source behavior |
| --- | --- |
| Model callback | [SessionCoordinator](../../apps/loopex/lib/loopex/runtime/session_coordinator.ex) `model_progress_fun/2` validates a delta, then calls `Control.project_progress/5` with its payload. Maintenance callbacks discard deltas. |
| Executor callback | [ExecutorStream](../../apps/loopex/lib/loopex/runtime/executor_stream.ex) `open/5` forwards raw events through the same Control path. Its relay owns next source sequence, per-stream byte offsets and first-binding refusal accounting. |
| First payload mailbox | [Control](../../apps/loopex/lib/loopex/runtime/control.ex) `project_progress/5` performs a GenServer call carrying the item. Its serialized handler checks current ownership and sends to the relay. |
| Relay and sink | [StreamRelay](../../apps/loopex/lib/loopex/runtime/stream_relay.ex) `emit/2` and `deliver/2` send payloads without aggregate credit. The relay owns ordinary sequence/closure ordering. Its activity mode has no count or closure. |
| Runtime configuration | [Runtime](../../apps/loopex/lib/loopex/runtime.ex) accepts `progress_to: pid`, `{:session, pid}` or nil. Tagged delivery is the accepted [M5 routing change](../developer/agent-context-map.md#disposition-m5-progress-routing-2026-09-22). |
| Daemon fanout | [Service](../../apps/loopex_daemon/lib/loopex_daemon/service.ex) forwards to [ConnectionRegistry](../../apps/loopex_daemon/lib/loopex_daemon/connection_registry.ex), which sends each attachment's payload to its connection before that connection queues it. |
| Foreground output | [Stdio](../../apps/loopex_app_server/lib/loopex_app_server/stdio.ex) `emit/1` calls `IO.binwrite(:stdio, encoded)`. `Delivery.take/1` drains before the write; Stdio does not consume live native progress or retain an active-frame charge/acknowledgement. |

Model and executor chunks each have a 65,536-byte ceiling. No maximum chunk
count or maximum active session population turns those sends into an aggregate
mailbox bound. The current [Delivery](../../apps/loopex_app_server/lib/loopex_app_server/delivery.ex)
and [SocketConnection](../../apps/loopex_daemon/lib/loopex_daemon/socket_connection.ex)
queue logic runs after earlier payload sends. Those observations are defects
against existing outcomes, not permission to omit live progress.

<a id="technical-adr-0058-admission"></a>
### Capability, credit and pressure

Concept: [Proposed native admission decision](0058-bounded-progress-delivery.md#concept-adr-0058-admission).

#### Current trusted capability contract

Introduce one Core-owned opaque `Loopex.ProgressSink.t`, optionally supplied as
`progress_sink` when starting a runtime. Nil deliberately discards progress.
Nil bypasses raw payload transfer before Control or relay admission; it is not
an unbounded relay whose final `deliver` happens to discard.
The capability is bound once to that runtime; it is never a global registered
singleton. These are trusted in-VM configuration operations, not wire DTOs:

```text
ProgressSink.open()             -> {:ok, sink} | {:error, :unavailable}
ProgressSink.try_offer(sink, session_id, item) -> :ok | :dropped
ProgressSink.take(sink)         -> {:ok, lease, session_id, item} | :empty | :closed
ProgressSink.release(sink,lease)-> :ok | {:error, :stale_lease}
ProgressSink.close(sink)        -> :ok | {:error, :cleanup_unproved}
```

`open` gives custody to its calling host process. Only that owner can take,
release or close. `try_offer` accepts an already projected closed native item
and a session identity of 1–256 original bytes. It performs no current-session
mutation or owner authentication. Runtime raw ingress is private and reaches
the existing serialized Control fence before this public delivery cut.
Host consumers can use `try_offer` to reserve a target before a fanout copy;
arbitrary producers cannot acquire an effect grant through this handle. A
lease is opaque, unique to a sink incarnation and one slot generation, and
one-use for release. Foreign, duplicated or stale releases cannot reduce
capacity. Owner death closes admission. It does not report successful external
writer cleanup.

Validate a closed opaque handle containing only one guardian PID, one native
incarnation reference and one private arena identifier. A lease contains only
that incarnation, one slot index in 0–31 and one fresh native token reference.
Neither admits caller-supplied functions, arbitrary metadata or encoded public
identities. Those implementation handles stay outside plain public DTOs.

The host retains a lease while its consumer, encoded queue or active writer
owns that item. It releases only after verified discard of all retained
copies, or full-write and exact-worker join. It cannot dequeue then forget
the lease. Core knows native custody; each host must prove its actual output
resource lifetime. Core calls no host writer or arbitrary sink callback.

The capability unifies ordinary embedded delivery, foreground delivery,
session-tagged daemon delivery and the ADR 0054 activity route. Direct OTP
messages cannot atomically charge these earlier payload transfers, which is
the concrete reason this boundary is necessary.

#### Atomic admission and bounded control

Use a Core-owned finite resident arena with 32 slots and a 524,288-byte total
charge. Reserve slot, byte charge, fresh token and captured owner/route together
in one atomic local state transition. The proposed implementation uses a
bounded ETS state row with exact compare-and-replace and at most 32 attempts;
contention exhaustion refuses admission. No GenServer call, queued reservation
request, wait for a consumer or unbounded CAS retry precedes credit.

Only after reservation may a payload enter a mailbox or resident payload slot.
Every subsequent mailbox transfer carries that same live charged token, or
first obtains independent destination credit. Control can receive a token and
read the resident item under its existing current-owner fence. Its validation
and route transition stay serialized with succession. A stale owner drops the
slot; it cannot publish through a previously checked unguarded callback.

Before measuring or copying, perform finite closed-shape and per-field
preflight. Oversized, non-plain and private values never become an uncharged
message. Preflight refusal is not output pressure. Preserve the first failed
binding rule for events actually admitted to executor validation; a refused
or sealed ingress contributes no invented validator observation or receipt
count. A malformed event outside that observed prefix is dropped, as an offer
to an unavailable plane, rather than classified using unavailable sequence
state. This explicitly narrows private refusal observation to the live
admitted prefix; it adds no private record member.

Charge retained native bytes, projected bytes and encoded bytes conservatively
before materialization. Include copied binary backing storage, active writer
bytes and any fanout copies. A representation or copy needing more credit must
obtain it first or drop; encoded escaping and opaque-identity expansion never
silently enlarge a native reservation. Per-field ceilings and total frame
limits still apply. The limits bound retained progress custody, not all VM
heap, provider memory or the unlimited baseline session population.

A slot carries one current stage, custody owner and token generation. At most
one ready notification per arena/stage is outstanding; the consumer scans the
fixed slots, then atomically clears/rechecks the pending flag. Failed offers
send no notification. Retirement is an idempotent slot state change, not one
new control message for every dropped chunk. Owner registrations/monitors for
held slots are bounded by the 32 slots and removed with custody. Never retain
a growing set of old tokens, attempts or callback offers.

Death between reserve, materialize, notify, fence, route, take, encode and
release must have a discoverable slot and a conservative cleanup branch.
Credit cannot be reopened while a late old-generation copy can still install
or emit. Closing stops offers, revokes routes, proves native holders gone and
joins owned native workers; unproved host writer cleanup keeps that output
retired. A successor receives a fresh sink incarnation, never replayed tokens.

#### Explicit ordinary-domain tail loss

Each ordinary relay retains a constant ingress state `open | sealed`.
The first capacity refusal or failed finite atomic offer seals it. This is
one idempotent domain transition; it does not queue an item or repeatedly
notify Control. Already reserved items keep their original ordering and
current-owner checks. Later raw events drop before the stateful executor
validator, so a missed source sequence or offset never poisons subsequent
validation. No event is reinterpreted as a protocol refusal to explain pressure.
The same rule applies to admission contention, including concurrent callbacks.

Use one constant-size local domain gate with `open`, `offering` and terminal
`sealed` states. A single compare-and-exchange acquires `open -> offering`.
Contending offers atomically set `sealed` and drop without retry or notification.
An offer that acquired the gate before sealing can finish its finite capacity
operation and publish its credited prefix item. Its release can restore `open`
only by compare-and-exchange from `offering`; it cannot undo `sealed`.
Capacity refusal or 32 failed arena comparisons seals instead of reopening.
Closing seals before scanning the bounded published prefix and invalidates
unfinished reservations against later installation. The implementation must
prove reserve/publish/close races with the actual slot generation, rather than
treating a separate liveness read as an atomic admission boundary.

Model sequences remain assigned by the actual relay for projected emissions.
Executor sequences and offsets remain the validated source values. Refused
payload behavior inside the admitted prefix and its existing refusal counters
remain unchanged. Model `delta_count`, `streamed` and executor
`progress_count` remain the producer's original private statement, independent
of delivery loss. The runtime builds no assistant content from progress.

Sealing constructs no closure. When the attempt actually settles, keep ADR
0011/0014's existing complete/abandoned choice and count source. Drain only
the credited prefix before that domain's closing item; closure admission is
itself finite and may fail under pressure. Closing the native domain and
returning its exact projected count cannot wait for stdout or an arbitrary
consumer. Owner loss can still end the plane with no truthful closure.

ADR 0054 activity has no ordinary domain tail to seal. Each positive permit
result gets at most its existing one independently credited six-field item.
Negative/unknown permit, commit fencing, stale owner, succession and recovery
still produce no synthetic activity. A lost or delayed item cannot reopen a
completed durable episode.

<a id="technical-adr-0058-writer"></a>
### Owned output and exact completion

Concept: [Proposed foreground writer decision](0058-bounded-progress-delivery.md#concept-adr-0058-writer).

#### Source-backed mechanism

OTP 27.3.4's [Unix driver source](https://github.com/erlang/otp/blob/OTP-27.3.4/erts/emulator/sys/unix/sys_drivers.c)
`spawn_start` makes the emulator's control-pipe endpoints nonblocking and
creates driver state with `is_blocking = 0`. The same file's `fd_start` can
create blocking state, whose `fd_async` performs `writev` in an async thread.
Changing stdout to a raw fd port therefore supplies no exact-worker cleanup
proof. [Port IO](https://github.com/erlang/otp/blob/OTP-27.3.4/erts/emulator/beam/io.c)
must be included in the retained floor/current audit; killing a Port is not
evidence that an independent blocking fd write has joined.

The [child setup source](https://github.com/erlang/otp/blob/OTP-27.3.4/erts/emulator/sys/unix/erl_child_setup.c)
routes non-stdio control pipes to child fd 3/4 while leaving fd 0/1 inherited.
It also selects a new process group/session before exec. This supports a
separate stdout worker without a host `io_request`. It does not prove the
group topology of an arbitrary launch on Darwin or Linux.

Bash's [builtin reference](https://www.gnu.org/s/bash/manual/html_node/Bash-Builtins.html)
documents pipe timeouts for `read -t` and literal `%s` printing. Its
[job-control reference](https://www.gnu.org/software/bash/manual/html_node/Job-Control-Builtins.html)
documents exact-child `wait` and process-ID `kill` with job control disabled.
These are feasibility inputs. Actual captured process and descriptor proofs
remain owed.

#### Private proxy protocol and captured bounds

Launch fixed `/bin/bash --noprofile --norc` through `spawn_executable` with
`:nouse_stdio`, an explicit credential-free environment and a retained owner.
Use no model-selected script, executable, environment or shell expansion.
The proxy closes its unused stdin descriptor, preserves actual stdout fd 1,
and uses only fd 3/4 for its private control protocol. Protocol stdout receives
only the encoded frame. Proxy diagnostics are bounded and exclude frame data.

There is one frame nonce and one worker PID in flight. The nonce is a fresh
32-byte lowercase hexadecimal identity for that proxy incarnation. Host-to-
proxy control has one finite frame message and one matching `CONTINUE`; proxy-
to-host control has at most one `WRITTEN` and one `JOINED`. Control records are
bounded independently of the unchanged 2 MiB output frame ceiling. Unexpected
nonce, repeated record, wrong order, trailing control data or control EOF
retires the writer; it never acknowledges another frame.

The leader starts one background worker running builtin `printf '%s'` with
the exact already encoded LF-terminated record as data. The worker sends
`WRITTEN(nonce)` on fd 4 only after its complete successful stdout write. The
leader concurrently waits for `CONTINUE(nonce)` with builtin `read -t` on fd 3.
The host sends CONTINUE only for that WRITTEN. The leader then waits for its
exact worker PID and sends JOINED only on the successful matching join.
No helper is exec-replaced and no second frame starts before JOINED.

At frame admission capture monotonic `write_cutoff = now + 5,000` and
`cleanup_cutoff = write_cutoff + 5,000`, once. Queueing/control transit,
WRITTEN, CONTINUE and JOINED all spend the original write interval. The
leader's pipe wait is no longer than five seconds; the host's earlier absolute
cutoff governs even if the leader starts later. It is not reset by partial
writes, an acknowledgement or another caller. Request waits retain their own
original 30,000-ms cutoff.

On delivery expiry, EOF, stop, wrong acknowledgement or actor loss, stop new
frames, detach at the last JOINED durable cursor, terminate the anchored process
group and collect actual port exit, worker/leader exit and group absence within
the captured cleanup cutoff. Keep the live leader as the group identity anchor
until group termination starts; a dead PID is no reusable kill authority.
The success path has an actual wait for the exact child, and the failure path
requires actual descendant/group evidence. Port-owner DOWN or `Port.close`
alone proves neither.

A failure may have exposed a frame prefix or even a full record before its
JOINED reply was lost. Close the connection; never splice an error into that
partial frame. A client discards its incomplete LF frame and uses durable
reattachment. A full but unacknowledged durable record can replay, consistent
with at-least-once delivery. Unproved cleanup returns failure and prohibits
another writer on the same output; it supplies no successful cleanup result.

#### FIFO, reservation and EOF

All snapshots, query/admission replies, errors and durable events enter one
owned durable FIFO. Reserve their count/encoded-byte capacity before dispatch
where refusal must precede mutation. Hold each charge through the active proxy
write and JOINED. Only the JOINED event record advances the durable emitted
cursor. Distinguish queued/pulled cursor from that emitted cursor everywhere,
including replacement, detach and reconnect.

Use the unchanged 64-record/4,194,304-byte durable limit and
32-record/524,288-byte progress limit, each including its active frame. Progress
shares native custody credit until discarded or joined; moving to the encoded
queue cannot release it. Encode no new snapshot or durable batch when its
retained output cannot fit. Drop progress before delaying durable output.
Pressure after mutation admission never becomes `refused`; preserve the
original command identity and unknown/detach semantics.

Input framing remains raw strict LF, with the unchanged pre-initialization
and initialized ceilings. Continue bounded input servicing while a frame is
in flight. Stop request admission before output credit is exhausted. On EOF,
retire each actual attachment/transfer holder and input port, stop the proxy,
join owned workers and invoke inherited orderly foreground shutdown. Do not
record abort, change interactions or cancel a run merely because stdin ended.
A blocked or broken stdout cannot prevent this cleanup control path.

<a id="technical-adr-0058-alternatives"></a>
### Alternative costs and feasibility

Concept: [Options and consequences](0058-bounded-progress-delivery.md#concept-adr-0058-alternatives).

The selected tail-loss design keeps current stateful validation in the relay.
Resuming after an unvalidated raw-event drop would require advancing executor
sequence/offset state for a payload the relay never saw. It cannot be repaired
by copying a later position, suppressing its refusal counter or trusting the
producer's sequence as a new baseline.

A continuing-stream alternative would move the existing pure validation
transition into Core-owned bounded local per-domain state, before output
pressure. It must preserve complete identity, first-binding refusal, source
sequence and offset transitions with finite contention handling and no lost
update. An unbounded CAS loop is not an admission bound. That ownership/API
revision is not selected or supplied by this pair.

ReferenceHost-only Bash would make generic Stdio require an owned writer
capability instead of its current implicit standard IO. Its exact interface
would need nonblocking one-frame offer, full-write acknowledgement, exact join,
stop and cleanup proof, plus conformance for the host implementation. That is a
viable decision alternative, not an optional callback or fallback in this
proposal. The general Stdio prerequisite above avoids adding this second new
public boundary.

A task timeout around `IO.binwrite` abandons the task but leaves the shared IO
request's owner elsewhere. A raw stdout fd Port can leave async write work.
Receiver-only bounded queues admit payloads too late. None meets the claimed
custody proof, and none is retained as a compatibility branch.

<a id="technical-adr-0058-rollout"></a>
### Migration and qualification

Concept: [Compatibility, rollout and required proof](0058-bounded-progress-delivery.md#concept-adr-0058-rollout).

Integrate the Core capability and migrate Runtime, Control, SessionCoordinator,
StreamRelay, ExecutorStream, composition, commands and all current fake/real
consumers together. Remove `progress_to`, bare PID sends and tagged PID
compatibility delivery. Retain session tagging in the capability's native
take result. No credit handle becomes a protocol field or public progress
member. Ordinary codecs and ADR 0054's exact six members remain unchanged.

The daemon service/registry/fanout route uses credited references or reserves
each destination before copying. Its target queues retain separate unchanged
per-connection limits and active socket-writer charges. A slow subscriber
cannot block the shared route or another durable subscriber. Native aggregate
pressure may drop progress, with no cross-session ordering promise. Credit
release for one target is independent of another target's joined write.

Required acceptance obligations include:

- Concurrent model/executor/maintenance offers from more sessions than native
  slots, finite contention exhaustion, exact record/byte high-water accounting,
  worst-case encoding/copy charges, and suspension at every pre-mailbox cut.
- Producer death after credit but before materialization/notification, stale
  Control ownership, sink/relay/consumer death, lost notifications, late old
  generations and duplicate release. Show no early reuse or retained token set.
- Real executor source sequences/offsets before pressure, first sealed event,
  later otherwise-valid offers, zero/malformed prefix, truthful private counts,
  terminal closure loss, retry/domain separation and no effect failure caused
  by delivery pressure. Preserve ordinary owner-loss rules.
- Actual automatic and standalone compaction permit paths, dropped/delayed
  activity, no summary text/credential/private-field exposure, and durable
  reattachment after silence.
- Foreground actual pipe and terminal output, full and partial writes, blocked
  output, broken pipe, WRITTEN without JOINED, mismatched nonces, suspended
  actors, EOF and actor loss. Retain exact worker/leader/group/port evidence,
  captured deadlines and joined-cursor FIFO assertions.
- Reply reservation around real accepted/refused/unknown mutation, snapshot
  before live events, replacement at the last joined cursor, daemon target
  isolation, and independent current clients proving loss never implies an
  outcome. Prove raw input framing and real holder/transfer cleanup.
- Warning-free current/floor native/transport conformance and real Darwin/Linux
  process proofs for both supported toolchain pairs, then required integration
  and release lanes on the actual coordinated candidate. No filtering, increased
  retries, substituted fake stdout or missing-platform PASS.

The proposed finite arena still needs a concrete implementation and independent
review of CAS, copied-byte accounting and owner-loss transitions. The proposed
proxy still needs actual process qualification. Neither source reasoning nor a
shell probe proves these obligations. Material implementation conflicts return
for decision; implementation cannot add a callback, new counter meaning or a
different pressure policy silently.

No journal, checkpoint, receipt or backup representation changes. Quiesce and
join current native and output owners before unactivated source rollback.
Current-format replay/restore remains owed. Pre-1.0 rollback carries no old PID
fallback or older-client decoder; previously unbounded bytes are not a qualified
delivery implementation. This Proposed pair authorizes no activation, milestone
closure, publication or drop of an accepted M7 outcome.
