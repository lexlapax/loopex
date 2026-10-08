<a id="technical-depth"></a>
## Technical depth

Concept: [Runtime creation startup status](0063-runtime-creation-startup-status.md#concept).

<a id="technical-adr-0063-purpose"></a>
### Existing paths and authority

Concept: [Purpose and evidence](0063-runtime-creation-startup-status.md#concept-adr-0063-purpose).

ADR 0059 separates Runtime.start_link's dispatcher readiness from creation
eligibility and requires unavailable/no-activation intake while startup remains
unresolved. Its finite startup claim/read/close episode, exact original actors,
Store-owned custody, host-exclusive placement and zero historical activation
remain in force. This proposal adds observation and host acquisition gating;
it does not amend those mutation or recovery permissions.

At the proposal baseline Runtime.start_link awaits await_dispatcher_ready.
Composition.compose starts and owns the runtime, binds trace capability and
returns it immediately. RuntimeOwner.start/open have no captured startup
cutoff or timed receive, and Edges.run supplies none. Daemon's owner-handoff
and listener-parking limits belong to separate phases, not this startup wait.
Configuration and liveness do not expose eligibility. Retained-command lookup
can return absence after a missing-capability startup became unavailable.

Ephemeral.RuntimeHolder receives its original native-monotonic caller deadline.
It currently returns Runtime.start_link's result immediately; SessionOwner then
starts its owned FacadeClient and the single create. It bypasses durable compose.
The caller's existing startup bracket and all descendant cleanup retain their
current limits. A new host allowance cannot be borrowed from another phase.

Source routing: apps/loopex/lib/loopex/runtime.ex and runtime/control.ex;
apps/loopex_composition/lib/loopex_composition.ex, runtime_owner.ex,
loopex_composition/edges.ex and ephemeral/runtime_holder.ex; ephemeral/session_owner.ex
and facade_client.ex; apps/loopex_cli/lib/loopex_cli/chat.ex;
apps/loopex_daemon/lib/loopex_daemon/service.ex. These paths name implementation
joins, not evidence that the proposal already runs.

<a id="technical-adr-0063-decision"></a>
### Exact native read and state semantics

Concept: [Recommended decision](0063-runtime-creation-startup-status.md#concept-adr-0063-decision).

Add Loopex.Runtime.creation_startup_status/1,2 and matching
Loopex.creation_startup_status/1,2. The second argument is a positive integer
caller timeout in milliseconds from 1 through 1,000; omission selects 1,000.
The read accepts the existing opaque runtime reference and token. It returns
exactly one of:

```elixir
{:ok, %{
  state: :starting | :ready | :unavailable,
  startup_id: opaque_binary,
  startup_deadline_ms: signed_integer
}}
{:error, :invalid_status_timeout}
{:error, :runtime_unavailable}
```

The successful map has exactly those three atom keys. startup_id is exactly
32 opaque bytes, distinct for each original Control initialization, including
replacement within the same runtime. It contains no PID, monitor, reference,
Store selection, generation, command, credential or authority. The signed
integer is System.monotonic_time(:millisecond)'s same-VM cutoff; negative values
are valid. It is not wall-clock time, portable time, a serialized recovery fact
or a reusable deadline in another VM. No extra keys or partial success exist.

Invalid timeout returns invalid_status_timeout without sending a Control read.
Invalid reference/token, unavailable original Control, read timeout or Control
loss return runtime_unavailable. A timed-out read may later reach Control but
performs only the same pure snapshot; its late reply cannot establish readiness,
renew a cutoff, allocate work or change a gate. The handler retains no waiter,
subscriber, Store request or new process and answers from serial Control state.
Nonwaiting means no wait for startup or an external callback; mailbox scheduling
is not claimed instantaneous. A caller timeout is a failed observation, not a
proof of failed Store work or completed cleanup.

Control initialization captures one identity and cutoff now_ms + 60,000 before
sending its startup message. Startup consumes that capture instead of creating
another invocation cutoff. Its timer uses only the remaining original interval.
Keep this private capture after startup retirement so the public read cannot
invent identity or time from a missing entry. This explicitly moves the startup
capture from later message intake to initialization; time spent before intake
is consumed, never added. Native live creation captures remain unchanged.

| State | Exact meaning |
| --- | --- |
| starting | This original startup has not proved its required barrier and is still before its original work cutoff. |
| ready | This original startup positively completed the barrier and all required original joins before that work cutoff. Later authored creation may be busy; each operation still checks its current admission gate. |
| unavailable | Original startup failed, its original work cutoff passed without timely proof, or this Control is stopping/quiescing. Cleanup uncertainty remains unavailable. |

Precedence is stopping/quiescing, retained startup failure or expired unproved
startup, then proved ready, then starting. Check current time in the read;
a queued expiry timer cannot make an expired starting read look fresh. Once
ready was proved timely, the old work cutoff passing does not undo that startup
fact. An authored invocation's failure cannot rewrite the original startup fact,
and ready never overrides that invocation's admission refusal. Stop/quiesce can
only reduce availability. An absent capture is runtime_unavailable, never a
ready/default result and never permission to create another startup episode.

<a id="technical-adr-0063-callers"></a>
### Host acquisition and cleanup mechanics

Concept: [Host waiting and cleanup](0063-runtime-creation-startup-status.md#concept-adr-0063-callers).

The first successful read pins its exact startup_id and startup_deadline_ms.
Every further read must match both literally; otherwise fail runtime_unavailable
and clean up the original acquisition. Do not follow a replacement, translate
an old VM cutoff or recapture a host period. If the first read returns ready,
startup requires no polling. Unavailable fails immediately. Starting enters
only a private host observation loop, not a pending creation request.

For durable compose the waiting deadline is that original Core cutoff. The
initial read is bounded by the API's 1,000-ms cap, because no Core snapshot has
yet been obtained; this is a read failure bound, not a new startup episode or
60-second host allowance. A successful initial starting reply whose cutoff has
already passed fails without another read. After pinning, each read timeout is
at most min(1,000, remaining_ms); positive remaining time is required before
sending. An observation pause is at most min(10, remaining_ms), spending that
same interval. Check expiry before accepting a polled ready reply or publishing
success; failure maps to startup_deadline_expired. Failure or mismatch maps to
runtime_unavailable. Neither maps to created or acknowledges Store cancellation.
This bounds the new observation interval, not earlier Store/executor setup or
all Runtime.start_link dispatcher work.

Place the durable gate in shared compose after start_edge has retained runtime
ownership and before trace/publication success. RuntimeOwner and tracked Edges
must continue to own all previously acquired children during observation.
Caller/owner/owned-child loss must interrupt observation and enter existing
cleanup; a private loop must not make these messages wait until cutoff.
No new public waiting callback or recovery seam is added. with_runtime never
runs its user's callback on refusal, and daemon cannot publish listener/service
readiness from an unresolved composition. CLI creation and prepared resume
remain single calls after successful acquisition.

For ephemeral acquisition, compare deadlines in one unit without rounding to a
later instant. Convert the Core millisecond cutoff exactly to native monotonic
units, then retain min(existing_holder_deadline, converted_core_cutoff).
The first read also spends the existing holder deadline. Runtime ownership and
its original monitor must be installed before observation, including a held
first read. The holder must remain responsive to its original owner/root/runtime
loss and cancellation: observe with owned bounded work under its existing phase
protocol rather than blocking its GenServer callback. No create is issued until
a timely ready snapshot is accepted. Failure follows the existing startup
failure/root cleanup path. FacadeClient then receives only the one authorized
actual create grant; it gets no retry or recovery role.

Keep the existing Core startup/live work, cooperative and observation cleanup
bounds, RuntimeOwner shutdown waits, ephemeral startup bracket, root/provider
joins and daemon teardown bounds. A host observation failure can request stop,
but must retain original cleanup evidence and unresolved durable custody. It
cannot claim Store cancellation because a status read or deadline ended.

<a id="technical-adr-0063-consequences"></a>
### Verification, alternative and current-contract integration

Concept: [Alternatives and consequences](0063-runtime-creation-startup-status.md#concept-adr-0063-consequences).

Prove the closed native grammar, wrong runtime/token, invalid timeout, missing
capture, original Control loss, two-runtime isolation and distinct replacement
identity. Hold the actual startup Store read and claim/close calls: status must
answer starting within its caller timeout, safe stop remains responsive, and
no create or new carrier is caused by observation. Missing callback adapters
must remain unavailable; a test readiness helper cannot make them ready.

Prove time captured at initialization, literal ID/cutoff retention through every
startup phase and completed retirement, unavailable at the cutoff even when the
expiry message is delayed, no adoption of a replacement, timely ready, and
later authored busy without changed startup facts. Suspend the original Control
to prove timeout and late replies do not become successful observations. Retain
all original operation identities, counters, cutoffs and joins; no allowance
renewal, synthetic cleanup or retry-only pass is admissible.

Exercise actual Composition.start, with_runtime and start_edges acquisition with
Memory and Local stores, held startup, unavailable adapter, caller/owner loss,
cutoff and failure cleanup. Assert no publication, bracket callback, CLI create,
resume or daemon listener readiness before timely completion. Retain exact
original runtime/Store/executor/credential-plane joins and existing cleanup
bounds. A successful CLI/chat/resume and daemon startup must use these real
routes, not only an isolated native status fixture.

Exercise the separate ephemeral RuntimeHolder/SessionOwner/FacadeClient path:
held startup before the single create, initial status timeout, shorter caller
cutoff, earlier Core cutoff, original owner/root/runtime loss and provider-root
cleanup. Check min-deadline retention and no question/model/provider call before
accepted creation. Positive startup and actual refusal cases remain distinct;
changing original startup tests must explicitly identify the changed observation.
Tests do not prove universal quiet from a status result.

The inspection-only alternative keeps this native schema/capture/read, but
omits both host waiting gates. It changes Composition's promise and updates
CLI/daemon expectations to immediate unavailable/no-activation refusal. A
refused one-shot startup still cleans up its owned runtime once. It authorizes
no sacrificial create, lookup-based readiness, private Control state access,
recovery invocation or repetition. Selecting that alternative requires revising
this pair before acceptance.

The recommendation changes a native observation contract and reference-host
waiting rule. It adds no JSONL/daemon method, wire schema/digest, configuration
read field, Store frame, restore DTO or persistent startup clock. Accepted
ADR 0059 custody/current frame 2 and ADR 0061's cancellation envelope stay
unchanged. Current-only before-1.0 integration updates facade, Runtime, Control,
both host paths, tests and their operator/developer descriptions together.
There is no older-readiness fallback. Source rollback changes no durable data;
it must describe dispatcher-only readiness and potential initial refusal.
Acceptance of the Proposed pair precedes implementation; native proof and whole
caller verification remain separate obligations.
