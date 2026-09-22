<a id="technical-depth"></a>
## Technical depth

Concept: [Collaboration: controller lease and takeover](0033-collaboration-controller-lease-and-takeover.md#concept).

<a id="technical-adr-0033-decision"></a>
### Contract and Evidence

Concept: [Context and decision](0033-collaboration-controller-lease-and-takeover.md#concept-adr-0033-decision).

### Lease record

The daemon keeps one lease record per session in its own process memory,
never in the session journal, in a file or in any store:

```text
session_id, writer_epoch, holder (connection identity), granted_at (monotonic),
deadline (monotonic), state ∈ {held, released, expired}
```

`writer_epoch` is an opaque string from ADR 0023's identifier alphabet, at
most 64 bytes, carrying at least 128 bits of fresh randomness. It is minted
at every grant and never reused: not across grants to the same connection,
not across the fresh owner a lease owner's death leaves behind — that failure
is **session-scoped**, as this pair sets out below — and not across a restart
of the daemon. Clients treat the epoch as opaque and compare it
only for equality. The daemon incarnation is a fresh opaque identifier
generated at each daemon start and reported by `daemon.status` as a
diagnostic; it confers nothing and is not part of the epoch.

The writer epoch is a **daemon** fact and stays one. Core never receives it,
never stores it and never checks it; the daemon checks it before forwarding a
mutation and core is handed an ordinary command afterwards. Core's own
fences are untouched and unrelated: the Store's `{owner_epoch,
owner_incarnation_id}` pair under ADR 0006, runtime control's post-commit
fence admitting the exact generation and owner pair, and command identity for
idempotency. Those remain the commit-authority fence, and they answer a
different question — which coordinator owner may commit — than the writer
epoch does, which is which client may drive.

One owner process per session serializes every lease read, grant, renewal,
release and expiry transition with that session's mutation-admission handoff,
so a takeover cannot pass a mutation whose holder check has already started
but whose relay ticket is unresolved; the relay accounts for that admission
first, or the daemon's own holder-and-epoch check refuses it before it ever
reaches core.

A revision of 2026-09-20 proposed collapsing these into one process for the
daemon holding a record per session. The maintainer rejected that on
2026-09-20 and kept the process per session: the process *is* the lease
serialization boundary and failure-isolation unit, while the fixed relay owns
the cross-owner ticket ledger. Collapsing the lease owners would put every
session's lease transitions behind one mailbox. The plan's companion states
the population and its bound.

The daemon owner accounts for that population with one explicit equation:
`owner_slots = starting_waiting_pop + starting + live + retiring <= 512`.
A `starting_waiting_pop` row owns a transferred slot but has no child; a
`starting` row reserves a slot before `start_link`; a materialized pid remains charged as `live` or
`retiring` until the daemon owner consumes its exact `EXIT`. Start failure frees
the row. A predecessor tombstone in the relay is not a process and consumes no
owner slot.

**A lease owner's failure ends that session's collaboration state, not the
daemon**, on the maintainer's decision of 2026-09-20. The owner loses its
transient lease record, but it does not take admitted work with it: the fixed
relay retains the session's ticket set and a successor queries that set before
grant.

The connection registry holds a bounded routing mirror for every **granted**
lease: `{session_id, lease_owner_pid, owner_incarnation,
holder_connection_pid, holder_connection_incarnation, writer_epoch}`. While an
acquisition is being completed it may instead hold the exact provisional row
`{permit_id, start_op_ref, session_id, lease_owner_pid, owner_incarnation,
holder_connection_pid, holder_connection_incarnation, writer_epoch}`. The
mirror is routing, not lease authority; admission still asks the live lease
owner. There is at most one provisional or granted row per concurrent owner,
and both share the 512 owner-slot bound.

Mirror publication is an explicit asynchronous operation rather than a nested
synchronous call. A lease owner sends its linked daemon owner
`{mirror, op_ref, owner_pid, owner_incarnation, action, exact_row, from}` and
enters one `mirror_pending` state, admitting no later lease transition. The
daemon owner records `op_ref`, the exact owner and registry incarnations,
action, row and an absolute deadline **before** it sends
`{apply_mirror, op_ref, daemon_owner_pid, registry_incarnation, action,
exact_row}`. The registry applies the exact-incarnation action and acks the
daemon owner. The daemon validates both incarnations and `op_ref`; a one-step
renewal, expiry or retirement then removes the pending row and replies to the
lease owner. Release uses the result-CAS-and-clear settlement below. A
holder-changing acquisition takes the two resolution steps below before either
the owner or a fresh child may finalize. A stale or late ack is cleanup-only.
The effective absolute mirror deadline is
`accepted_at + 5_000 ms`, or the earlier shared admission deadline when shutdown
has begun. It is one clock for the operation, never restarted by an ack or owner
exit. Every apply acknowledgement and continuation rechecks that instant in
serving and draining states. An ack queued before its timer but consumed after
the instant is cleanup-only: the daemon atomically latches `connections_lost`,
notifies the sentinel so the 35-second fail-stop watchdog is running, sends
untrappable `:kill` to the exact registry and enters fail-stop without awaiting
its reap or claiming mirror success. Its later linked `EXIT` is cleanup-only.
The timer only prompts the check; mailbox order never extends the operation.

An acquisition that would change the holder uses three exact mirror actions:
`install_provisional`, then `resolve_provisional(granted)` or
`resolve_provisional(cancelled)`. Install succeeds only while the named
connection incarnation is still `live`. An exact not-live refusal means the
registry consumed connection `DOWN` before the relay did: the daemon owner
CASes that permit from the recorded `executing` actor to `connection_lost` (or
observes the relay's already-terminal winner), exact-clears any row and cancels
the proposal or kills and reaps the fresh child. The later relay `DOWN` is
cleanup-only. Any other install refusal is an invariant failure and takes the
`connections_lost` fail-stop path. The lease owner, or the fresh child,
only proposes the epoch and holder and remains in a provisional state. The
daemon owner is the resolution coordinator for both: after the install ack it
attempts the exact relay permit CAS
`executing(actor_pid, actor_incarnation, ...) -> result` on behalf of that
recorded actor. That CAS is the sole grant linearization. If `result` wins, the
daemon sends `granted`, and the registry promotes the exact provisional row even
when the holder slot became `closing` after the CAS. Only the promotion
acknowledgement lets the daemon acknowledge the proposer, expose the epoch and
send a reply. The relay retains the winning permit as
`settling(result, op_ref)` until that acknowledgement, so a closing connection
cannot retire its origin while registry resolution is unfinished. If connection
`DOWN` won `connection_lost`, the daemon sends
`cancelled`, exact-clears the provisional row, and tells the existing owner to
discard the proposal or kills and reaps the fresh `start_op_ref` child; no epoch
or grant becomes visible. If the relay instead consumed an existing actor
owner's `DOWN` and won `owner_lost` before the daemon's result CAS, the daemon
also sends `cancelled`, exact-clears the provisional row, finishes proposal
cleanup without addressing the dead owner, and sends that request's one
correlated `control_owner_lost` refusal while leaving its connection open; no
epoch or grant becomes visible. If the daemon's result CAS wins first, it
resolves `granted`; the later owner `DOWN` is ordinary granted-owner loss and
closes the exact promoted holder once. Each terminal permit is retained as
`settling(disposition, op_ref)` until the corresponding promotion or clear
acknowledgement and child/proposal cleanup complete. A provisional row
therefore remains through slot close until one exact resolution, rather than a
registry inferring the outcome from cross-process signal order. Duplicate
resolution is idempotent. Missing acknowledgement or registry loss follows the
same exact-registry kill and `connections_lost` fail-stop rule. Renewal does not
change the holder, and release removes one; neither enters this provisional
holder-change state.

Release has one coordinator so it cannot split between a result sent to the
relay and a clear sent to the daemon. After the combined gate succeeds, the
lease owner enters `release_pending`, admits no later transition and sends only
the linked daemon owner exact
`{:release_proposed, release_ref, permit_id, owner_pid, owner_incarnation,
holder_connection_incarnation}`. The owner retains the original absolute lease
deadline in `release_pending`; it has not yet made the lease free. The daemon
records that operation before asking the relay to CAS the exact
`executing(owner_pid, owner_incarnation, ...)` permit to `result`. If
`connection_lost` has won, the relay retains
`settling(connection_lost, release_ref)` and renders nothing. The daemon sends
the exact owner `{:release_cancelled, release_ref, permit_id, owner_pid,
owner_incarnation}`. A matching owner still in that `release_pending` state
restores `held` with the original deadline, immediately treats an already
reached deadline as expired before admitting another transition, and returns
the exact cancellation acknowledgement to the daemon. The daemon then sends
the relay exact `release_cancellation_settled`; only its matching acknowledgement
terminalizes the no-reply `connection_lost` disposition. Exact owner death
before the restoration acknowledgement makes the daemon send the relay exact
`release_cancellation_owner_lost`; the relay terminalizes that no-reply
`connection_lost` disposition, acknowledges, and ordinary owner-loss pop and
classification handles the dead owner and every other claimed origin. Fatal
teardown supersedes both. A loss to
`owner_lost` before `connection_lost` preserves the granted mirror for the
pop-and-classification path. If `result` wins, the relay retains
`settling(result, release_ref)` without rendering. That CAS linearizes the
release. The daemon exact-clears the granted mirror under the operation's one
absolute deadline, then sends exact `release_mirror_settled` to the relay. Only
the relay's matching acknowledgement terminalizes and renders the correlated
success; only then does the daemon acknowledge the owner, which enters free or
retirement state.

The daemon defers an owner `EXIT` ordered after `release_proposed` until the
result, cancellation or owner-loss settlement selects its exact branch, or
fatal teardown completes. The relay may independently consume the
owner's monitor `DOWN` first: if `owner_lost` wins, the later result CAS loses
and the unchanged mirror classifies the holder; if `result` won first, the
later `DOWN` is cleanup, the daemon still clears the mirror and the later pop is
absent, so no uncorrelated holder-loss form can accompany the correlated
release result. Registry or relay loss follows its existing daemon-fatal path;
neither component guesses success from a missing acknowledgement.

When the daemon records `release_proposed` while serving, it fixes two absolute
monotonic instants from the same acceptance time:
`owner_restore_deadline = proposal_accepted_at + 5_000 ms` and
`release_settlement_deadline = proposal_accepted_at + 10_000 ms`. Neither
restarts. The relay's initial result CAS, any owner cancellation and restoration
acknowledgement, and a result branch's mirror clear must be accepted before the
first instant. The matching relay cancellation or result-settlement
acknowledgement may use the remaining interval but must be accepted before the
second. A missing or malformed relay answer at either exchange is `relay_lost`.
A result branch whose registry clear does not complete by the first instant is
`connections_lost`, as for every mirror apply. On the `connection_lost` branch,
a missing, malformed or late owner restoration acknowledgement at the first
instant makes the daemon send untrappable `:kill` to that exact owner, mark
cancellation superseded, and begin the no-reply
`release_cancellation_owner_lost` settlement. Its matching relay
acknowledgement must arrive before the second instant; otherwise the daemon
selects `relay_lost`. An owner acknowledgement queued before but consumed at or
after the first instant, or a relay settlement acknowledgement consumed at or
after the second, is cleanup-only.

If the orderly admission cut linearizes before the release row terminalizes,
both serving timers become cleanup-only and the exact row joins the frozen
pre-cut set. It may settle only under the already fixed `admission_deadline`;
at that instant any remaining exact cleanup and terminal CAS are owned by the
`freeze_lease_ops` barrier and must finish by its `freeze_deadline`. Shutdown
therefore starts no release-private extension and suppresses ordinary
owner-loss output, while a live but stuck owner still cannot retain
`release_pending` without bound and an owner failure is not misclassified as
registry loss.

A mirror timeout cannot merely kill a helper because a delivered registry call
could still run. There is no helper and no synchronous registry call. On the
deadline governing that exact mirror operation, or on registry loss, the daemon
owner atomically latches
`connections_lost`, notifies the sentinel, sends untrappable `:kill` to the
exact registry incarnation and enters fail-stop without awaiting its reap. Its
later linked `EXIT` is cleanup-only; the dead daemon lifetime can expose no
queued apply as a live route. A lease-owner
request sent before that owner's later `EXIT` reaches the linked daemon owner
first by signal ordering; the daemon records the deferred owner disposition and
finishes the exact mirror operation or fatal teardown before handling the
controller close. Death before the request leaves no row; death after an ack
uses the committed mirror. On exact owner `EXIT`, after any signal-ordered
pending mirror operation has completed, the daemon owner starts
`pop_owner_mirror` through the same async operation/deadline protocol. The
registry atomically removes only a row matching that session, dead owner pid and
owner incarnation and returns its exact holder route, or returns absent. The
daemon retains that result while the relay classifies every `owner_lost`
permit against the returned connection incarnation, then closes a returned
controller route only after the relay's exact classification acknowledgement.
A successor start and install remain queued until the pop, classification
acknowledgement and terminal holder-close or correlated-refusal settlement
complete, or fatal teardown wins. Duplicate or
stale pops are idempotent and cannot erase a successor. Exact owner incarnation
and epoch on clear, and exact dead incarnation on pop, prevent an old operation
from erasing a successor.

The daemon writes the uncorrelated `control_owner_lost` form to the controller
route returned by that atomic pop and closes it with its attachment, while the
relay suppresses a correlated form for that same exact connection and every
observer remains attached. Every other claimed acquire, release or unpromoted
mutation instead receives the correlated form and stays open. The lease is then
held by nobody. The next acquire starts a fresh owner and names the predecessor
pid/incarnation to the relay; its first grant waits until the relay has consumed
that predecessor's `DOWN`, the retirement completion and every ticket ordered
before it. Only then does the new owner mint a fresh epoch.

Tests suspend the registry while an independent Store exit and `SIGTERM` are
consumed, kill the registry during install, and order owner exit before request,
after request before ack, and after ack. They also force a late stale ack and an
old exact clear racing a successor install. An ordinary-serving ack is queued
ahead of its timer and consumed after the five-second instant, proving the
deadline check rather than timer order kills the exact registry and claims no
success. Owner-death cases prove exact pop before successor install, returned
holder classification before close, absent and duplicate pop, and an old pop
racing a successor. Forced acquire, release and unpromoted-mutation cuts consume
relay `DOWN` and pop result in both orders and prove the returned holder receives
only the uncorrelated close while every other claimed operation receives only
the correlated refusal; a promoted mutation still receives its real result.
One crossing witness pauses a serving classification before
its acknowledgement and orders stop consumption and classification completion
both ways: classification-first may complete its selected form before the cut;
stop-first rebinds the row to the transport-cut instant, makes the old timer and
queued acknowledgement cleanup-only, and emits only the later
`daemon.stopping`/EOF path. A maximum-population stop-overlap case kills every owner
after the admission cut, orders each exact `DOWN` and pop result both ways, and
proves those facts join one already-scheduled stop barrier and deadline: no
per-owner clock starts, no `control_owner_lost` form is emitted and the measured
orderly bound gains no owner-count term. Every case proves one terminal
classification or owner outcome, no stale mirror, and no blocked daemon-owner
receive loop.

The fresh epoch alone is **not** what orders the old and new tenures, and an
earlier revision of this section said it was. It stops a *later* command from
the old tenure, which is different from accounting for a call already on its
way. The relay's predecessor-retirement barrier and retained ticket set
together keep a successor's first call from overtaking that older call; core
orders what it receives and never sees the writer epoch.

**The daemon closes that window with one fixed process, the admission relay**,
added on the maintainer's decision of 2026-09-20. Every post-initialize request
takes a permit from it, giving orderly stop one linearization point. Ten calls
also take retained mutation tickets: the eight lease-authorized core mutations,
`session.create`, and `session.attach`. Reads and artifact transfers use only a
lightweight permit. Acquire and release use lightweight permits that remain
owned by the lease actor through terminal disposition.

Every request row is keyed by
`origin_id = {connection_incarnation, request_slot, request_sequence}`. At most
32 are active for a connection, while the monotonic sequence prevents slot-reuse
ABA. A ticketed request first installs `pending_ticket(origin_id, class, nil)` at the
relay; a lease mutation also binds its session and the relay's currently
registered owner incarnation. That acknowledged row is the admission point; no cross-sender ordering
between connection, lease owner and relay is assumed. A mutation worker then
binds the row as `queued(worker_pid, worker_monitor, owner_incarnation)`. A
promoted row is `ticketed(task_pid, task_monitor, worker_monitor | nil)`;
promotion starts the relay task before acknowledgement and retires the waiting
worker without transferring result authority to it. Connection loss kills and
reaps a queued worker and terminalizes the row; a promoted row and its accepted
connection slot remain retained until a real result, fatal disposition or
successful shutdown seal.

Exact lease-owner `DOWN` has its own pre-promotion rule. The relay atomically
claims every `pending_ticket` or `queued` lease-mutation origin bound to that
owner pid/incarnation as `owner_lost`; it kills and reaps a queued worker,
starts no core task and retains the claimed origin for the holder-classification
exchange below. A `ticketed` row already has a relay-owned core task and is not
reclassified: it stays retained to its real result, fatal disposition or
orderly seal. The predecessor barrier waits for both populations, so neither an
unpromoted origin nor a promoted task can be forgotten across replacement.

A lightweight permit row retains its immutable operation class, connection
incarnation, optional session ID and optional intended actor binding
`{actor_pid, actor_incarnation}` and is
`pending(nil | {request_worker_pid, request_worker_monitor}) |
executing(actor_pid, actor_incarnation, request_worker_pid,
request_worker_monitor, start_op_ref | nil) | settling(disposition, op_ref) |
terminal(disposition)`.
The closed terminal dispositions are `result`, `owner_lost`,
`connection_lost`, `shutdown_cancelled`, and `shutdown_admitted`; one relay CAS
wins. Every acquire/release message carries its `permit_id`. Before acknowledging
a lease permit, the daemon owner supplies its session ID and intended exact
actor: the registered lease-owner pid/incarnation for an existing-owner
operation, or the daemon-owner pid/incarnation for a fresh-owner acquisition.
The relay serializes that creation against its owner monitor. Owner `DOWN` first
routes the new origin into the retained owner-loss classification; a pending
acknowledgement therefore always names a live registered actor and never leaves
an unbound lease permit. Immediately before an existing lease owner mutates
lease state, it synchronously claims `pending -> executing` only when its exact
pid/incarnation matches that immutable intended binding, while retaining the
distinct request-worker fields. For a query, read or artifact transfer, the
request worker is also the actor. In either case the connection first completes
ADR 0032's worker-ready and relay-bind handshake, and the relay sends `go` only
after the executing CAS.
For a fresh acquisition,
the daemon owner is the actor: immediately before it asks to start an owner it
claims the permit, retains an exact start `op_ref`, and remains the completion
authority for that entire first acquire. The child reports its grant or refusal
to the daemon owner, which alone settles the permit; later lease operations use
the registered lease owner as actor. A request worker is never the completion authority
after delivery; the exact lease owner or daemon owner reports the terminal
result to the relay. Connection loss kills only the request worker, never the
daemon or lease-owner actor. An acquisition grant remains provisional through
owner start and mirror install; the daemon owner's relay `result` CAS on behalf
of the recorded actor and the exact mirror resolution follow the rule above.

Every lease owner first registers its pid, session and fresh owner incarnation
with the relay in a synchronous handshake before it may answer an acquisition
or admit a mutation. A replacement registration carries the exact predecessor
pid/incarnation. For a lease-authorized mutation the owner validates the
combined gate. For an activation-capable resume it asks the connection registry
to bind an activation reservation to the exact queued origin and promote the
primary; for another mutation it promotes the complete core descriptor
directly. Create and attach likewise install their origin first and use ADR
0032's registry-owned reservation handshake. An exact duplicate create, resume
or attach becomes `waiting(primary_ticket_id)` and starts no second task.
Before acknowledging promotion, the relay starts and monitors
the core task, then answers `admitted`. The task may finish before that
reply is delivered; the invariant is recorded ticket, task pid and monitor plus
start ordered before reply, and the ticket remains until the relay consumes the
queued result or `DOWN`. Connection or owner death after acknowledgement does
not cancel the core call.

A task that dies without a result before the relay enters its orderly-drain
phase makes the relay and daemon fail-stop as `relay_lost`; receipt cannot be
inferred. The relay monitors owners, so a ticket
request sent before owner `DOWN` is consumed first. A replacement grant waits
for the named predecessor `DOWN` and all tickets ordered before it. Create names
no existing session and attach grants no control, so neither blocks an
unrelated lease grant; both remain visible to drain.

Every daemon-owner lifecycle transition with the relay is a ref-tagged message
exchange, synchronous only in sequencing. The owner sends
`{:relay_barrier, barrier_ref, action}`, waits in its all-owned-exit receive loop
and advances only on the exact
`{:relay_barrier_ack, barrier_ref, action, payload}` before the action's absolute
instant. Stale or wrong-reference messages satisfy nothing. An exact malformed
answer or missing exact answer at the instant atomically latches `relay_lost`,
notifies the sentinel so the 35-second fail-stop watchdog is running, sends
untrappable `:kill` to the exact relay and enters fail-stop without awaiting its
reap; a later linked `EXIT` is cleanup-only. The owner never infers a missing
payload from its own maps.

The relay's `cut` closes new origin rows, freezes and returns the exact pre-cut
origin-ID set with its pending, queued, promoted, waiting or settling ticket and lightweight-permit states,
then moves lease routing to `draining`, and acknowledges immediately. Before
sending it the owner starts the fixed absolute
`transport_cut_deadline = now + 5_000`; that same instant covers this
acknowledgement and the subsequent registry gate, listener reap and
uninitialized-peer sweep. A suspended relay atomically selects `relay_lost`;
the owner notifies the sentinel, sends untrappable `:kill` and enters fail-stop
without awaiting its reap. Its later linked `EXIT` is cleanup-only; no transport
or core success step follows. Any pre-cut permit
represented by one of those IDs can still claim `pending -> executing`, and any
pre-cut pending ticket can promote, before the absolute admission deadline;
among lightweight permits, only acquisition can start an owner. No origin
outside the frozen set can create a task.

The cut linearization stores one absolute monotonic
`admission_deadline = cut_linearization_time + admission_wait_ms` in both relay
and daemon-owner state. `admission_wait_ms` is the fixed candidate value selected
before closure from a maximum-population witness with 16,384 origins across 512
connections, including the slowest permitted pre-cut promotion and owner-start
path; closure evidence and the operator page record its value and measurement
conditions. No event restarts or extends that instant. Every permit CAS,
owner-start or mirror acceptance, and every continuation after child start or
registry acknowledgement rechecks that same instant. An expired path idempotently enters or joins
`lease_ops_frozen` even when the timer message is still queued: a late permit
claim loses, a child that materialized across the instant is killed and reaped
before grant, and a late mirror acknowledgement is cleanup-only and follows the
exact-registry kill/`connections_lost` rule. The timer prompts the transition;
mailbox order never defines the deadline.

The orderly-stop bound charges the complete five-second transport-cut
allowance and the complete `admission_wait_ms` separately. They can overlap
after the cut acknowledgement, but they cannot be combined by `max`: the
transport clock starts before the send, while the admission clock starts only
at `cut_linearization_time`.

At the shared admission deadline the relay also terminalizes every unpromoted
pending or queued ticket as `shutdown_cancelled`, killing and reaping its exact
request worker; later owner or registry promotion starts no task and any
unpromoted reservation is released.
The daemon owner first enters its own deadline-checked `lease_ops_frozen`
state, computes a fresh absolute
`freeze_deadline = now + relay_control_timeout_ms`, where
`relay_control_timeout_ms` is **5,000**, then sends the relay's ref-tagged,
idempotent `freeze_lease_ops(admission_deadline)` barrier. The admission
deadline remains the claim-authority cut; the later instant only bounds the
barrier and cleanup. The relay rechecks the same
instant, atomically moves routing from `draining` to `lease_ops_frozen`, CASes
`pending` rows to `shutdown_cancelled`, CASes every still-`executing` lease row
to terminal `shutdown_admitted`, and retains and returns one fixed tagged cleanup
descriptor set. A barrier-owned row is
`{:shutdown_admitted, permit_id, class, actor_pid, actor_incarnation,
start_op_ref}`;
the last field is present for a fresh acquisition and identifies its
daemon-owned provisional start. A proposed release whose relay disposition is
already selected is
`{:settling_release, permit_id, disposition, actor_pid, actor_incarnation,
release_ref}`, where disposition is the row's already selected `result` or
`connection_lost`. A holder-changing acquisition whose disposition is selected
while provisional mirror resolution or child cleanup remains uses
`{:settling_acquire, permit_id, disposition, actor_pid, actor_incarnation,
start_op_ref, op_ref}` for `result` or `connection_lost`; the daemon's exact
retained `op_ref` record supplies its provisional row and phase. Every release
or acquire whose dead-owner classification is already selected uses
`{:settling_owner_loss, permit_id, class, actor_pid, actor_incarnation,
op_ref}`. It may have no accepted daemon operation record, or may have the exact
acquire/release record whose later result CAS lost to `owner_lost`. The immutable
actor binding supplies each pid and incarnation; the daemon's exact
`release_ref` record and retained acquisition `op_ref` supply the selected settlement phases,
so neither process scans an actor map or infers a winner. If an actor result,
connection loss or owner loss CAS wins before the barrier's atomic transition,
the row appears in its exact settling variant; if the barrier wins, the later
actor result is cleanup-only. Every later freeze request returns the same
retained set. No post-deadline claim can join it. The relay returns correlated
`daemon_stopping` for cancelled rows where a
connection survives and kills their waiting workers. An executing non-lease
read, query or transfer remains tracked through its result or the step-3
connection/worker `DOWN`; if still live then, it terminates as
`connection_lost`.

The frozen daemon owner rejects or tombstones every not-yet-processed
owner-start and mirror request as `shutdown_admitted`, creating no child or row.
It consumes only the relay's fixed descriptor set, never infers actors by
scanning its owner map. For a barrier-owned `shutdown_admitted` existing-owner
operation it kills and
reaps the exact descriptor actor, exact-pops the pid/incarnation mirror, joins
that result with the relay's exact owner `DOWN`, and settles every
owner-loss-claimable lease permit and pending or queued mutation origin without
`control_owner_lost` output. A promoted ticketed mutation remains relay-owned to
its real core result, fatal disposition or orderly seal. The barrier already won
the target permit before any destructive cleanup begins; a late actor result is
cleanup-only. The cleanup is idempotent and the mirror must be absent before
core quiesce.
For a fresh acquire, whose descriptor actor is the daemon owner itself, that
owner remains alive. Its retained exact start record keyed by `start_op_ref`
must say `not_materialized` or carry the exact `{child_pid, child_incarnation}`;
the former is tombstoned and the latter is killed and reaped. Missing or
mismatched start state selects the barrier's `relay_lost` path rather than an
actor-map scan. If its provisional mirror was installed, the daemon first
resolves it cancelled and requires its exact absence before quiesce. A barrier-owned operation is not
described as rolled back; `shutdown_admitted` is the terminal disposition that
authorized this exact cleanup.

For each settling-release descriptor the daemon requires the matching retained
`release_ref` record. A `result` disposition finishes or confirms the exact
mirror clear, terminalizes `result` without rendering it after the cut, and
acknowledges the owner into free or retirement state. A `connection_lost`
disposition whose owner already restored finishes its no-reply relay settlement
and leaves the restored holder alive for the drain. If restoration is unresolved,
the daemon kills and reaps that exact owner, exact-pops and classifies its mirror
without client output, sends the no-reply cancellation supersede and
terminalizes `connection_lost`. A `settling_owner_loss` descriptor completes
the retained exact `DOWN`, mirror-pop and classification join without client
output. With no accepted daemon operation record it terminalizes directly. With
a matching release record it tombstones that record; with a matching acquisition
record it finishes or confirms provisional cancellation and discards the
existing-owner proposal or exact fresh start record. Missing a record whose
accepted phase requires one selects `relay_lost`; unfinished mirror cleanup
selects `connections_lost`. It then terminalizes `owner_lost`. A
`settling_acquire` descriptor requires its matching retained `op_ref` record. A
`result` row finishes or confirms `resolve_provisional(granted)`, renders no
post-cut reply and retains the granted owner for the drain. A `connection_lost`
row finishes or confirms `resolve_provisional(cancelled)`, discards an
existing-owner proposal or kills and reaps its exact fresh `start_op_ref` child,
and renders nothing. Either path leaves no provisional mirror operation pending.
A permit's selected disposition does not change if its exact lease owner dies
later. For an existing-owner operation that is the recorded actor owner; for a
fresh acquire whose `result` granted, it is the resulting child lease owner
named by the retained start record, never the daemon owner that acted as the
permit's completion authority. The daemon first completes the descriptor's
release or provisional settlement, then consumes and reaps any retained or
newly arrived exact lease-owner `DOWN` and exact-pops and classifies the mirror under the same
`freeze_deadline`, without ordinary output. A restored `connection_lost`
release therefore completes cancellation before owner loss; an acquire or
release `result` remains `result`, and the later pop is present or absent
according to the mirror state that exact settlement produced. No second
disposition or clock begins.
A missing or mismatched required release record, malformed relay answer or
unfinished relay join or terminalization by `freeze_deadline` selects
`relay_lost`; unfinished exact mirror work, including a mirror that remains
after an executing-owner kill, selects `connections_lost`. Shutdown owns those
deaths and dispositions, so ordinary `control_owner_lost` handling is
suppressed. If a mirror is still pending, the
barrier atomically latches `connections_lost`, notifies the sentinel, sends
untrappable `:kill` to the exact registry and enters fail-stop without awaiting
its reap or claiming that routing state settled. Its later linked `EXIT` is
cleanup-only. Idle or granted lease owners remain
alive through the runtime drain. The exact acknowledgement, returned-set
cleanup and terminal-row confirmation must all finish before `freeze_deadline`; otherwise
the owner atomically latches `relay_lost`, notifies the sentinel, sends
untrappable `:kill` to the relay and enters fail-stop without awaiting its reap,
reconstructing the set or calling core quiesce. A later relay `EXIT` is
cleanup-only.

After the admission wait and lease freeze, immediately before core quiesce, the
daemon owner computes a new `now + relay_control_timeout_ms` instant and sends
the ref-tagged transition to `quiescing(drain_id)`. These are two sequential
uses of the same timeout value within orderly stop, not one shared instant; the
serving-only owner-loss classification instant above is outside `T_orderly`.
Failure to receive the exact acknowledgement atomically latches `relay_lost`, notifies the sentinel,
sends untrappable `:kill` to the relay and enters fail-stop without awaiting its
reap or calling core quiesce. A later relay `EXIT` is cleanup-only. A ticketed
task `DOWN` without a result in this phase retains an unresolved ticket but does
not independently turn an already ordered stop into `relay_lost`; it grants no
successor and asserts no core result. After successful core quiesce the owner
sends the ref-tagged deferred `seal_after_quiesce(drain_id)` barrier, the first consumer of the shared
teardown deadline. The relay kills every remaining exact task pid concurrently
and consumes each result/`DOWN` ordering against the remaining absolute time
before it replies. A
real result sent by a task before its exit wins because that sender's signals
arrive in order; every other retained ticket is returned as unresolved and
abandoned for this shutdown, never relabelled as settled. Each primary result
or abandonment terminalizes its live `waiting(primary_ticket_id)` origins too.
If the relay cannot finish the fixed population by that deadline, or returns
an exact malformed result, the owner atomically latches `relay_lost`, notifies
the sentinel, sends untrappable `:kill` to it and enters fail-stop without
awaiting its reap or reporting an `operator_stop` success. A later relay `EXIT`
is cleanup-only.
The population is bounded independently of connection churn: at most 512
provisional (including aborting), live or closing accepted connection slots times 32 active origin
rows, so there are at most
16,384 origin rows and no more promoted relay tasks; waiting origins start no
task. A healthy maximum-population
seal must complete within the selected teardown bound; a suspended relay proves
deadline expiry selects the fatal path.
Core's terminal
admission barrier, census, coordinator termination and fencing have then ordered
every durable mutation domain. A pending attach is nondurable; the seal removes
its unresolved ticket after killing the caller task, while holder and runtime
teardown clear any late transaction and charge. A quiesce
error remains `drain_failed` and never receives a successful seal.

Only after quiesce and that seal have returned and the step-3 connection/request-worker barrier
has observed every such process `DOWN`, the registry has no nonterminal origin
or permit for any closing incarnation, every relay task is gone and
each monitored cleanup worker has both acknowledged `release_holder/2` and gone
`DOWN`, do the relay and daemon owner both enter
`tearing_down`. A ref-tagged mailbox barrier then freezes the remaining idle or granted
owner pid/incarnation set, continues to reject owner-start and mirror work, and
the next teardown step performs one collective sweep. No queued pre-cut start
or mirror crossing the first barrier can be authorized, produce a grant, install a mirror
or survive cleanup, and no remaining owner can materialize behind the second.
The barrier consumes the existing teardown deadline. Missing or malformed
acknowledgement atomically latches `relay_lost`, notifies the sentinel, sends
untrappable `:kill` to the relay and enters fail-stop without awaiting its reap
or sweeping a guessed owner set; a later relay `EXIT` is cleanup-only. Registry
loss while it is
pending retains the existing `connections_lost` classification.

So the ordering claim rests on the relay, and the session-scoped rule gives
the rest. Owner death is disposed by the state the exact owner incarnation had:

- with a granted lease, the routing mirror identifies the holder. The daemon
  owner pops that exact owner pid/incarnation but does not yet write or close.
  It carries the returned holder connection incarnation into the relay's
  owner-loss classification exchange described next; no command from the old
  tenure can be admitted afterwards;
- before a first grant, while a takeover grant waits on a predecessor or while
  any lease operation has no visible result, the relay atomically claims every
  pending acquire or release permit whose immutable intended actor is
  `{dead_owner_pid, dead_owner_incarnation}`, every matching
  `executing(dead_owner_pid, dead_owner_incarnation, ...)` permit, and every
  `pending_ticket` or `queued` lease-mutation origin
  bound to that exact owner as `owner_lost`. It kills and reaps a queued
  mutation worker, starts no core task and retains each winner in
  `settling(owner_lost, op_ref)` without rendering a reply. A promoted
  `ticketed` mutation instead stays owned by its relay task until the real core
  result, fatal disposition or orderly seal. The daemon owner
  and relay then join two independently ordered facts: the relay's exact owner
  `DOWN` and the registry's exact mirror-pop result. Under one fresh
  `now + relay_control_timeout_ms` instant, the daemon sends exact
  `{:owner_lost_classified, classification_ref, owner_pid, owner_incarnation,
  holder_connection_incarnation_or_none}`. The relay keys and retains whichever
  fact arrives first — that classification or the exact owner `DOWN` — and
  joins them only when both match; an early classification is not rejected.
  It then answers exact
  `{:owner_lost_classified_ack, classification_ref, owner_pid,
  owner_incarnation}`. If the returned holder is the same exact
  connection as a claimed origin, the relay resolves that origin as
  `holder_close` and suppresses its correlated reply. Every other claimed
  lease-operation origin resolves as `correlated_refusal`, carrying its
  `request_id` and leaving its connection open. The relay acknowledges only
  after every claimed origin has one of those dispositions. Only then does the
  daemon write the one uncorrelated `control_owner_lost` record and close the
  returned holder. A missing or malformed classification acknowledgement takes
  the existing bounded `relay_lost` path; registry loss takes
  `connections_lost`. The predecessor barrier remains until this exchange and
  the holder close or correlated replies are terminal. The two monitor/message
  orders therefore produce the same mutually exclusive wire forms.

  That fresh five-second exchange is **serving-state only** and is outside
  `T_orderly`. When the daemon owner consumes a stop and begins the admission
  cut, it atomically marks every locally pending classification stop-owned
  before sending the ref-tagged cut. Cut acceptance in the relay atomically
  absorbs every matching in-progress classification into the earlier
  `transport_cut_deadline_ms` instant; its old private timer becomes
  prompt/cleanup-only. A classification whose acknowledgement the daemon owner
  consumed and whose selected output it completed before consuming the stop
  remains an ordinary pre-cut result. Otherwise, ordinary owner-loss
  notification stops: no fresh per-owner deadline starts, any queued
  classification acknowledgement is cleanup-only and no `control_owner_lost`
  form is emitted. The daemon and relay retain every dead-owner and mirror-pop
  fact, batch them into the current or next already-scheduled cut, freeze,
  quiescing or teardown barrier, and resolve them under that phase's existing
  absolute deadline. Permit dispositions become the stop-owned
  `shutdown_cancelled`, `shutdown_admitted` or retained real result that the
  barrier already defines; the later `daemon.stopping`/EOF path owns client
  notification. Simultaneous owner deaths therefore consume one shared stop
  clock rather than serial five-second clocks, and the orderly expression
  still contains exactly the freeze and quiescing relay-control terms.

  A pending or executing holder renewal changes no mirror. A pending or
  executing release keeps the holder mirror until its relay `result` CAS has
  won and the mirror-clear settlement begins. An unpromoted mutation likewise
  changes no lease mirror. Thus, when `owner_lost` wins any of those origins,
  mirror pop still returns the exact holder connection; the correlated form is
  suppressed only for an origin on that holder, while a non-holder origin gets
  the correlated refusal and stays open. If `result` won first, the later `DOWN` is cleanup for that
  permit and ordinary granted-holder or already-cleared-mirror handling applies.
  A renewal result sent directly to the relay before owner exit wins `result`
  by signal order and makes the later `DOWN` cleanup-only. Release uses the
  daemon-coordinated result-CAS-and-clear protocol above, so it has no
  cross-recipient send order to infer. A holder-changing grant report instead
  reaches the daemon first and begins the provisional-mirror protocol; the
  relay's independently consumed owner `DOWN` may still make `owner_lost` win
  before the daemon's later result CAS. That winner is resolved `cancelled`,
  exact-cleared and answered once with correlated `control_owner_lost` on an open
  connection. If the daemon's result CAS wins first, granted resolution
  completes and the later owner loss closes the exact promoted holder. An
  `executing(daemon_owner_pid, ...)` fresh acquisition is not claimed merely
  because its provisional child died: the live daemon actor remains completion
  authority. If that exact child exits before sending a grant or refusal, the
  daemon owner exact-clears any provisional mirror and CASes the permit to
  `owner_lost`; the connection receives the correlated refusal. If the child
  sent its grant report first, same-sender signal order lets the daemon consume
  that report before `EXIT`; because the live daemon is the relay actor for a
  fresh acquisition, it can complete the result CAS and granted resolution
  before disposing the child exit. That result-first resolution makes the
  later `EXIT` ordinary granted-owner loss and closes the exact holder. The
  winning owner-lost disposition for any claimed non-holder lease operation
  answers with a **correlated** `control_owner_lost` carrying its `request_id`;
  those connections remain usable and no epoch was ever visible. A later request
  worker result or `DOWN` is cleanup only and cannot emit or settle again. A
  claimed origin on the returned granted holder instead observes only the exact uncorrelated holder
  close; no operation receives both forms;
- when the lease is free or the owner is retiring and no lease operation was
  claimed, there is no controller or request to notify. The relay still consumes the exact `DOWN`, preserves
  every predecessor barrier and ticket until settlement, and then removes the
  owner, predecessor and empty permit rows.

In every state a later acquisition starts a fresh owner only after the routing
pop, classification and terminal-notification barrier, and receives a fresh
epoch only after its named predecessor ticket and retirement barrier clears.
The cost is still stated
honestly: the daemon does not tell a new controller what an earlier mutation
did, only that nothing of it is still unaccounted for.

An earlier draft had the daemon restart the owner and carry on with its
sockets intact, and a 2026-09-20 revision made the failure fatal to the whole
daemon instance. Both are superseded: the restart was wrong because a
restarted owner would claim the lease record it cannot know, and daemon-fatal
was the smaller design the maintainer declined on 2026-09-20 — it ends every
other session's work for one session's fault, where the relay ends none of it.

So a lease owner's failure is **session-scoped**, and the daemon's own
structure supplies that without special-case code: each lease owner is
`start_link`ed by the daemon's owner process, which traps exits, and its
`{:EXIT, pid, reason}` clause maps the pid to the session it belonged to
rather than to a daemon-wide class. Every other linked process the daemon
holds is still daemon-fatal — the relay included, because a daemon without it
can no longer honour the ordering rule for any session. The lease owners are
the one class with a session-scoped rule. There are no restarts to configure
and no strategy to get wrong: nothing is restarted, and the next acquisition
starts a new owner from nothing.

**When an owner exists at all.** One starts on the **first lease operation for
that session after its existence has been validated**, not at activation: a
dormant session is acquired *before* it is resumed, and `attach --take-over`
may acquire and release a session it never activates, so an activation-scoped
owner would not exist when the lease it serves does. One retires when the
lease is free, no acquisition is waiting, and the relay holds no outstanding
ticket for that session — all three, since any one alone would retire an owner
something still depends on.

Retirement is an acknowledged handshake, not a self-exit the daemon has to
guess about. The owner asks the relay to mark its exact pid/incarnation
retiring. After that acknowledgement, it sends the daemon owner a pre-exit
retirement intent and waits for the daemon's acknowledgement before exiting
`:normal`; same-sender ordering makes that intent precede the linked `EXIT`.
The owner slot remains `retiring` through that acknowledgement and is not free
until the daemon consumes the exact `EXIT`. The daemon may consume only that
exact normal exit as expected. Any other owner exit, including `:normal`
without the intent handshake, is
`control_owner_lost`. The relay consumes its own monitor `DOWN`, waits for
every ticket ordered before it, and sends retirement-complete to the daemon.

An acquisition arriving before the daemon consumes predecessor `EXIT` is
queued without spawning a successor. In the callback that consumes `EXIT`, the
daemon atomically transfers the freed slot to a same-session
`starting_waiting_pop` reservation and starts no process. It then completes the
exact `pop_owner_mirror`, runs the matching owner-loss classification exchange
and finishes its selected holder close or correlated refusals; expected
retirement supplies an absent holder and an empty classification. Only the pop,
classification acknowledgement and terminal notification settlement together
change the reservation to `starting` and permit the successor child to spawn
naming the dead predecessor pid/incarnation. The relay tombstone and ticket
barrier may outlive the process and that child, but its first grant still waits
for retirement-complete and every predecessor ticket. An acquisition arriving
after `EXIT` but before the full predecessor barrier takes the same
`starting_waiting_pop` reservation without spawning; one arriving after relay
completion and the full barrier starts with no predecessor. At a population of
512, an unrelated
513th session still refuses `control_capacity_reached` rather than borrowing a
live or retiring slot. The daemon drops the predecessor identity at completion,
and the relay drops its tombstone and empty ticket set, so
churn over exact-ID, unindexed sessions cannot accumulate one row per session.
A witness retires more than 512 distinct dormant-session owners and proves the
owner, predecessor and relay maps return to baseline, while a separate
unexpected-normal exit under a held lease takes the session-scoped failure
path. At an exact population of 512, a predecessor is held after retirement
intent acknowledgement and before exit; its same-session successor remains
unspawned, the unrelated 513th acquisition refuses, and consuming exact `EXIT`
transfers that one slot into `starting_waiting_pop` without a capacity refusal
or transient 513th pid, proves no child exists before exact mirror-pop,
classification acknowledgement and terminal notification settlement, and only
then starts the successor. A forced-order case delivers the linked `EXIT` before the relay's
post-`DOWN` completion and proves the recorded pre-exit intent prevents a false
`control_owner_lost`. Owner-loss cases kill the process before its first grant
and while a takeover waits on its predecessor, with acquire and release on both
sides of `pending -> executing` and mutation in `pending_ticket`, queued and
promoted states. Every claimed non-holder operation gets its own correlated
refusal, no returned holder also gets one, an unpromoted mutation starts no core
task, and a promoted mutation returns its real result. The predecessor tickets
remain and every bounded map returns to baseline after settlement. Each case
orders owner `DOWN`, actor result and request-worker `DOWN` both ways, proving
the permit compare-and-set produces exactly one reply or close and one release.

Retaining the **lease** in a survivor was rejected: it would make a replacement
process claim collaboration state it cannot reconstruct. The relay retains
pending, queued, waiting and promoted origins, including tickets for tasks it
started, but holds no lease or authority and is not restarted. Its own failure
is daemon-fatal, which is the fail-closed edge
that lets its volatile accounting be sufficient without turning it into a
durable lease record.

**One lease per connection.** A connection holds at most one controller lease
at a time, so a client that wants to drive two sessions opens two connections.
That is the same shape ADR 0032 already gives attachments — one per
connection — and it is what makes the session-scoped close exact: when a lease
owner dies, "close the controller's connection" names one session's controller
and cannot take a second session's control down with it. Without the rule the
close would be ambiguous. A same-session acquisition by the holder is the
renewal defined below; an acquisition for another session on that already
pinned connection refuses ADR 0032's `invalid_request` before lease lookup.

A holder's connection is **exempt from ADR 0032's idle eviction while the
lease is held**, for the reason that decision states: evicting it would close
the connection the lease is bound to, and only an explicit
`session.release_control` frees a lease early, so the session would be
uncontrollable until the term ran out. A holder that stops renewing loses the
lease on its own clock and becomes an ordinary observer, evictable like any
other.

ADR 0032's non-prepared core-succession invalidation is not idle eviction and
does not end the connection. The connection loses only its attachment and is
sent `detached`; the lease owner retains the exact holder connection,
`writer_epoch` and, absent an independently admitted mutation, absolute
deadline. The five-condition mutation gate then
refuses `control_not_held` on its missing-attachment condition until that same
connection reattaches. Release remains available without an attachment, and a
different connection still receives `control_held` until explicit release or
monotonic expiry makes takeover eligible.

A mutation that passed that gate before the cut retains a candidate renewal,
not an immediately visible deadline. If core returns accepted, or returns
`admission_unknown` after a successful route so admission cannot be excluded,
the daemon commits the candidate absolute deadline calculated from the gate's
monotonic instant. Exact pre-call `session_unavailable`, a positively proved
succession-before-admission `control_not_held`, or any other real refusal
discards it. The mutation stays in the existing in-flight set until this
disposition and the corresponding succession join settle, so expiry cannot
grant takeover through the gap. Targeted attachment replacement waits for each
older origin to settle this same accepted, refused or unknown disposition
before its core transaction begins. Succession itself never renews. An accepted controller-issued
`session.resume` renews because it is an admitted mutation; another actor's
succession and a refused resume preserve the prior deadline.

Expiry and
admission use the daemon's monotonic clock: a deadline is set only by a
successful grant or renewal, and a wall-clock jump cannot shorten or extend
a live holder's authority. Nothing about a lease is persisted or recovered.
After a daemon restart no lease exists, every session is uncontrolled, the
previous socket and its connections are gone, and a client presenting an old
epoch is refused both because it can never match and because it is not a
holder connection. Runtime-Control exclusion between two daemons on one state
root is the shared crash-reclaimable host placement lock; the local Store's
unchanged writer marker remains physical Store-writer exclusion.

### Methods and fields

- `session.acquire_control` (`session_id`, `request_id`): grants control when
  no lease is held, or when the held lease is released or expired; **renews**
  it when the caller is the recorded holder of a held, unexpired lease — see
  the renewal branch below; and refuses
  with `control_held` otherwise, **carrying no epoch** — an epoch is
  authority-shaped, and a client that was just refused control is the last one
  that should be handed the current one. An earlier revision of this sentence
  said the refusal named it; ADR 0032's error table is the contract and it
  carries nothing beyond the envelope. Every result carries `writer_epoch`
  and `expires_in_ms`, the remaining term on the daemon's clock. A holder
  renewal additionally carries `renewed: true`; a fresh grant omits `renewed`
  entirely. ADR 0032 owns that exact public result shape. For a known dormant session, a connection may acquire by
  session ID before attach. The daemon validates durable session existence
  first, and it does so with core's read-only session-existence query — the
  one that asks only whether the root holds that ID, with no attach, no
  resume and no side effect. Its answer is one of the four in
  ADR 0032's closed set and nothing more — it says whether the root holds the
  session, not whether this daemon has activated it, which is a daemon fact
  core does not carry. Acquisition therefore does **not** refuse a dormant
  session: a dormant session is acquired here precisely so it can be resumed,
  which is the sequence this ADR's concept sets out. That matters here more than anywhere: acquire
  must be safe to call on an ID that turns out to be unknown, and an earlier
  draft that learned existence by calling `attach` or `resume` would have
  taken a durable or attaching side effect to answer a question. The
  maintainer rejected that on 2026-09-20. An unknown ID refuses with nothing
  created, nothing attached and no lease granted; a known one grants, and the
held lease lets that connection call `session.resume` and then attach. Daemon startup recovery of sessions is a root-owner operation under
the host placement lock and Store writer marker, never a client mutation and never a grant of
  controller authority.
- `session.release_control` (`session_id`, `request_id`, **`writer_epoch`**):
  releases the caller's own lease. It carries `writer_epoch` like every other
  lease-authorized call, and ADR 0032's DTO table is the contract for it; an
  earlier revision of this line omitted the field the table already required,
  which would have left two documents describing one request. A caller that is
  not the recorded holder, whose epoch does not match, whose lease is not
  `held`, or whose deadline has elapsed refuses `control_not_held` and changes
  nothing. Release requires **no live attachment**: it must remain possible
  after a dormant session's attach refuses and on any writable exit path where
  the attachment has already ended.
- **Renewal is a branch of `session.acquire_control`, and it has to be stated
  because the refusal rule would otherwise swallow it.** Acquire from the
  connection that **is** the recorded holder of a lease that is `held` and
  unexpired is a **renewal**: the deadline moves to the full term from the
  admission instant, the **epoch does not change**, and the result carries
  that same `writer_epoch` with the new `expires_in_ms` and `renewed: true`.
  A fresh grant omits `renewed`. Acquire from any
  other connection while such a lease exists refuses `control_held`. The two
  branches are told apart by the connection identity alone — acquire carries
  no epoch on the wire, and needs none, because the holder is recorded against
  the connection. An earlier revision said both "refuses with `control_held`
  otherwise" and "renewal is explicit through `session.acquire_control` from
  the holder" without saying which clause a holder's own acquire took.
  Renewal is also implicit on any admitted mutation and likewise never changes
  the epoch. The gate records a candidate deadline from its exact monotonic
  instant; an accepted result commits it, `admission_unknown` commits it
  conservatively, and a proved pre-admission or real refusal discards it. This
  is what "admitted" means at the route and succession races.
- Every existing-session core mutation in generation 2, including
  `session.resume`, `session.prompt`, `session.steer`,
  `session.follow_up`, `session.abort`, `session.respond_interaction`,
  `session.admit_resources` and `session.activate_skill`, carries
  `writer_epoch` — a **required** binary identity of at most 64 bytes, exactly
  as ADR 0032's request table fixes it. `session.release_control` carries the
  same required field although it starts no core call. A request of those
  eight mutations, or a release, that omits it is malformed
  and answered with ADR 0023's `invalid_request`
  (`0023-…-technical.md:304-307`), never with `control_not_held`: the gate is
  not reached, because there is nothing well-formed to put through it. The daemon admits it only if the sending connection is the
  recorded holder, the epoch matches, the lease state is `held`, the deadline
  is later than the live daemon's monotonic admission time, and the
  connection holds a live attachment for its pinned session, except that a verified
  dormant session's `session.resume` may precede attach under that
  connection's held lease. The check and core handoff are serialized against
  lease transitions for the session. `writer_epoch` is consumed only by this
  daemon authorization gate and is removed before the ADR 0023 request is
  mapped to the core command. It never enters the core command digest or a
  durable record. Re-presenting the same method, durable `command_id` and
  canonical semantic input after reacquisition therefore uses the fresh epoch
  to authorize the call while core sees the same idempotent command binding.
  Release uses the same serialized check without the attachment condition.

  **Every way either gate can fail answers one code, `control_not_held`, and it
  says nothing about which condition failed.** The gate has five conditions —
  holder connection, epoch equality, `held` state, unexpired deadline,
  live attachment for the pinned session — and an earlier revision required each of
  them without naming the result any of them produces, which left the one
  refusal a client actually meets undefined and ADR 0032's error table
  incomplete. It is deliberately **non-oracular**: a stale epoch, a copied
  current epoch, a non-holder connection, a released lease, an expired lease
  and an observer's mutation are **indistinguishable on the wire**, because
  telling a caller *which* condition it failed tells it something about the
  lease it does not hold — whether one exists, whether its epoch was right,
  whether it was merely late — and an epoch oracle is exactly what a refusal
  must not be. It refuses before core admission and before any session write,
  carries the request's `request_id` and nothing else, and changes nothing
  about the current holder's lease, epoch or deadline. Queries and attach
  carry no epoch and pass no **lease** gate; they still take the relay permit,
  and attach takes a relay ticket under the rule above.

  **The core-mutation gate has five conditions and six cases**, and the mapping is written out so the two
  numbers stop reading as a disagreement:

  | Case | Condition it fails |
  | --- | --- |
  | A stale epoch from the previous tenure | epoch equality |
  | An observer replaying the **current** epoch it saw | holder connection — the epoch matches, the connection is not the holder |
  | A mutation from a connection that never acquired | holder connection |
  | A mutation after `session.release_control` | `held` state |
  | A mutation after the term elapsed | unexpired deadline |
  | A mutation from the holder connection after its attachment ended, or before it attached | live attachment |

  The witnesses assert each case separately in the daemon's own state — which
  condition it constructed — and assert that all six produce the
  **same** code and the same fields on the wire, which is what stops a later
  revision from helpfully differentiating them.
  Release has the first four conditions only. Its separate witnesses prove a
  non-holder, stale epoch, non-held state and expired term all receive the same
  refusal, while acquire of a dormant session followed by `session.attach`
  refusing `session_dormant` can still release successfully with no live
  attachment.
- `session.create` has no `writer_epoch` because the session lease does not
  exist. It creates an uncontrolled session, and creation never implicitly
  grants control. The caller must acquire control explicitly and use the
  returned epoch for its first session command. Acquire and attach may be
  sent in either order, because acquire is keyed by session ID and validates
  only durable session existence, through the read-only query; the
  constraint is on the first mutation,
  not on the two calls that precede it, and that mutation refuses unless the
  sending connection is the holder, the epoch matches and the connection
  holds a live attachment for its pinned session.
- **Only an explicit release releases early.** A successful
  `session.release_control` from the holder frees the lease at the relay's
  `result` CAS; its success reply waits for the daemon-owned mirror clear and
  exact settlement acknowledgement. Every
  other way a connection ends — an orderly close, an EOF, a killed client, a
  severed socket — leaves the lease to expire on its term.

  Core succession does not enter that list because it leaves the connection
  open. Its attachment invalidation neither releases nor renews the lease:
  holder, epoch and absolute deadline stay exact, mutation waits for reattach,
  and takeover remains limited to explicit release or expiry.

  An earlier draft said an orderly close released the lease while an abrupt
  loss waited. That cannot be implemented over a Unix-domain socket and is
  withdrawn: the daemon sees EOF, and EOF is EOF. A client that closed
  politely and a client that was killed present the reading end with exactly
  the same event, so a rule that distinguishes them is a rule the daemon
  cannot execute. Binding early release to a message the client actually sent
  is the only version of this the transport can support, and it is also the
  more honest one — a controller that wants to hand over says so.

### Expiry against an in-flight admission

Two rules above meet at the deadline and their order has to be stated, not
left to the implementation. The lease owner serializes the gate and relay
ticket handoff against lease transitions; the relay then retains the admitted
call until its real result. Takeover is admitted at expiry with no grace. The
linearization rule is:

1. A mutation whose holder, epoch, state, deadline and attachment check
   completed while the deadline was still in the future, and whose relay
   ticket was admitted, is **in flight** and settles under that lease even if
   the deadline passes while core is unresolved. It completes or fails on its
   own terms; it is neither retried nor fenced by the expiry.
2. At the deadline the lease state becomes `expired` and the holder gains
   nothing further: every mutation whose check begins at or after the deadline
   refuses, including one from the holder, and renewal no longer extends it.
3. A takeover becomes **eligible** at the deadline and is **granted** only
   once the relay reports every mutation ticket for that session settled. Until then the
   acquire waits, bounded by the acquiring request's own deadline; a wait that
   exceeds it refuses with **`control_pending`**, the stable reason ADR 0032's
   generation-2 error inventory carries for exactly this case, and the client
   may acquire again. It is distinct from `control_held`, which says another
   client holds the lease; `control_pending` says only that this acquisition
   ran out of time behind an admission that had not resolved.
4. The grant then mints a fresh epoch, so nothing admitted under the previous
   lease can be confused with anything after it.

This adds no grace to the lease. The expired holder gains no new authority; it
only finishes what it had already started, which is the same guarantee the
serialization rule gives at every other moment. A holder cannot extend its
tenure by starting work, because rule 2 refuses every new check at the
deadline and the in-flight set can only shrink.

Proposed terms bound at acceptance: lease length 30 seconds, renewal interval
10 seconds for the reference clients, takeover eligible when the live daemon's
monotonic deadline is reached and granted when the in-flight set is empty, no
grace period beyond the lease itself.

### Cancellation across processes

`session.abort` is the durable abort command the core already accepts. The
daemon forwards it from the current controller regardless of which
connection or process admitted the command that started the running work,
because dispatch, cancellation and the two-phase abort with its truthful
`cancelled` or `outcome_unknown` terminal belong to the core's coordinator,
not to the client that prompted. An observer's abort refuses before
admission.

### Authority

Control is a daemon-owned scheduling fact. It grants no effect: host policy,
grants, fences and executor validation apply to a controller's tool calls
exactly as to a single-client session. The daemon's configuration may
restrict takeover to the daemon's own operating-system user, which the socket
already enforces, and to an operator-supplied allow rule; it cannot admit a
command that host policy would refuse. No client content, model output,
interaction answer, metadata, request identity or attachment order confers
control, and a read-only attachment never admits a command whatever it sends.
The daemon's observer role is connection authorization. An explicit successful
acquire grants that connection a controller role scoped to the lease; neither
the existing core attachment handle nor an observer's knowledge of the epoch
is itself command authority.

### Evidence

Tests prove: exactly one controller with observers within the ADR 0032 bounds;
a stale epoch, copied current epoch, non-holder connection, released state
expired state and a holder lacking a live attachment each refused before core admission with the current
controller unaffected; release applies its four-condition gate without an
attachment condition, including dormant acquire, failed attach, successful
release and immediate acquisition by another connection; a lease transition racing command admission preserves
this order. A non-prepared core succession invalidates a controller attachment
and an observer attachment while keeping both daemon connections open; it
preserves the controller's exact holder and epoch, and preserves the absolute
deadline when another actor caused the cut. Forced route orders prove a real
accepted result commits its gate-time renewal candidate, exact
superseded-before-admission discards it, and post-route `admission_unknown`
commits it conservatively; takeover waits for each disposition. A targeted
replacement begins only after every predecessor mutation has reached one of
those outcomes, so it adds no renewal branch. A controller-issued accepted resume receives `detached`
before its real result and commits the renewal, while its refused-resume pair
preserves the prior deadline. The cut refuses a
controller mutation on the missing-attachment condition before reattach,
admits it under the same epoch after reattach, and refuses observer takeover
until paired explicit-release and expiry cases make it eligible. Every ticketed
call first has its retained
`{connection_incarnation, request_slot, request_sequence}` origin row, a lease
mutation binds its waiting worker before crossing to the owner, and any
activation or attachment charge is bound by the registry before the exact
primary is promoted. Exact repeats become waiter origins and start no second
task. A promoted primary records its task pid and monitor, with task start
ordered before the sender receives `admitted` — a
fast task may already have queued its result, so liveness at delivery is not
asserted; attach's task uses the connection as
stable holder; killing that task before a result and before the relay's
`quiescing` transition makes the relay and daemon fail-stop. Four orderly-stop
cuts prove the phase distinction: after the relay has acknowledged
`quiescing(drain_id)`, an injected hold in the relay task itself is killed by the
seal and returned unresolved while operator stop succeeds rather than becoming
`relay_lost`; in the paired case the relay consumes that task's no-result `DOWN`
before it processes the quiescing transition and becomes `relay_lost`; an attach pending through quiesce is reaped by
`seal_after_quiesce`, then holder `DOWN` and runtime teardown clear its
transaction and charge; and a real result queued before task `DOWN`
wins terminal disposition rather than abandonment. One healthy seal reaps the
maximum 16,384 promoted tasks within the selected teardown bound; a second with
the relay suspended proves the shared deadline atomically latches `relay_lost`,
starts the fail-stop watchdog, sends untrappable `:kill`, awaits no out-of-phase
reap and emits no operator-stop success. Reconnect churn cannot exceed
that population because a dead incarnation remains a charged closing slot until
it has no nonterminal origin. Owner `DOWN` is forced while a lease mutation is
still `pending_ticket`, while its worker is `queued` and after promotion. The
first two cuts claim `owner_lost`, kill and reap any worker, start no core task
and complete exactly the holder close or non-holder correlated refusal selected
by mirror classification; the promoted cut keeps the relay task to its real
result. Each drains its predecessor ticket set and eventually permits a
successor grant. Every acquire/release carries its permit ID and forced cuts before
the `pending -> executing` CAS, after CAS before owner mutation, with fresh-owner
start queued behind freeze, after spawn before reply, after mutation before the
mirror request, and with mirror request before and after freeze prove one
terminal disposition. Acquire and release each prove all three permit orders:
  permit before cut and claim before the absolute deadline settles normally; cut
before permit refuses; deadline before claim wins `shutdown_cancelled`. A paused
acquire and release are each killed before the exact-owner claim and after it.
For a holder origin, both cuts retain `owner_lost` until pop classification,
suppress the correlated form and produce only the uncorrelated close. A
non-holder acquire or release receives exactly one correlated refusal and
remains open. A separate cut kills the existing owner after the relay
acknowledged a pending permit with that exact immutable actor binding but
before the owner claims it, proving `owner_lost` is selected without actor
guessing and the row settles without leaking. Renewal is also killed after
claim but before its direct result in
both signal orders: a result sent before owner `EXIT` wins `result`, while the
relay consuming exact-owner `DOWN` first wins `owner_lost`. Release's separate
settlement witness kills the owner before `release_proposed`, after the proposal
but before the relay result CAS, after result wins but before mirror clear, and
after clear but before the correlated reply. It disconnects the holder after
`release_proposed` but before the result CAS, proving the relay retains
`settling(connection_lost, release_ref)`, the exact cancellation restores
`held` with the original deadline before terminalization, no success is sent,
and ordinary expiry later permits takeover without a stuck `release_pending`.
It also disconnects after result wins before mirror clear and after clear before
the success attempt, proving result-first settlement still clears the mirror,
terminalizes the permit and frees the lease even when its reply is lost. It
queues each matching result, cancellation and clear acknowledgement around
owner `DOWN`: owner death before cancellation acknowledgement uses the
exact no-reply supersede and then ordinary pop/classification, while
acknowledgement first restores `held` before the later owner-loss path. An
owner restoration acknowledgement queued before `owner_restore_deadline` but
consumed at or after it is cleanup-only, and a nonanswering owner is killed at
that same instant; both begin the no-reply supersede and ordinary owner-loss
path without leaving `release_pending`. The supersede acknowledgement is then
forced just before and at or after `release_settlement_deadline`: the first
terminalizes, while the latter is cleanup-only after `relay_lost`. Matching
cancellation and result-settlement acknowledgements are forced at the same
second cut. A missing or malformed relay settlement also selects `relay_lost`.
Separate cut crossings overtake each serving instant and prove the exact row
joins the fixed admission/freeze cleanup without a private extension. If it is
still settling at the admission deadline, the barrier returns its exact tagged
settling-acquire, settling-release or settling-owner-loss
descriptor. Forced acquisition `result` and `connection_lost`, release
`result`, restored `connection_lost`, unresolved `connection_lost` and
`owner_lost` rows before and after acquire grant/provisional install and release
proposal each complete their specified no-output cleanup before
`freeze_deadline`; a missing required daemon release record, wrong tag and
deadline crossing select the named relay or registry fatal class without
beginning core quiesce. Fresh executing acquisition is frozen before and after
child materialization and provisional install; the exact `start_op_ref` record
must tombstone or name the child, and any installed row must be cancelled before
child reap. Existing-owner acquire and release are held across freeze in both
result-versus-stop and owner-`DOWN`-versus-pop orders. No provisional, pending
or stale operation mirror remains. A result-granted or restored holder's exact
mirror remains for the drain unless the paired later owner-`DOWN` case pops it.
Every claimable origin has a terminal no-output disposition, and a promoted
mutation remains on its real-result path before quiesce. An owner-loss winner preserves
the mirror and selects exactly the classified refusal or close; a result winner
clears the mirror before rendering the correlated success, makes a later pop
absent and never emits the uncorrelated form. Every cut leaves no stale mirror
or nonterminal release permit. A separate
existing-owner holder-change case consumes the grant report and install
acknowledgement, then forces owner `DOWN` before and after the daemon's result
CAS: `owner_lost` first resolves the mirror `cancelled`, waits for its exact clear
acknowledgement, sends one correlated refusal and leaves the connection open;
result first resolves `granted`, then the owner-loss path closes the exact
promoted holder once. A fresh
acquire executed by the daemon actor is separately proved not claimed merely
because its provisional child dies: child `DOWN` before a report exact-clears
the provisional mirror and makes `owner_lost` win, while a grant report before
`DOWN` is resolved first by same-sender order and makes the later death a
granted-owner loss. A pre-cut acquire and release each claim immediately
before the absolute instant, with relay freeze forced before and after the
daemon's timer message; idempotent `freeze_lease_ops` returns the same complete
tagged `shutdown_admitted`, settling-acquire, settling-release and
settling-owner-loss descriptor set in both orders. Renewal, existing-owner
acquire/release and fresh acquire each force actor-result versus atomic freeze in
both relay-mailbox orders: result first enters the exact settling protocol, while
freeze first terminalizes `shutdown_admitted` and makes the late result
cleanup-only. Each existing-owner result and restored connection-loss case is
then forced with exact actor-owner `DOWN` both before and after descriptor
settlement; each fresh-acquire result instead forces the resulting child
lease-owner `DOWN` in those two orders, never daemon-owner death. In every case
the selected disposition stays fixed, settlement finishes first, and the same
freeze deadline covers the later no-output reap, exact pop and classification.
One disposition exists per permit without scanning the daemon
owner map. A paused
artifact read that claims and dispatches before the cut remains `executing`
across the admission deadline and quiesce, then the step-3 peer close kills it
and wins `connection_lost` exactly once; its paired pause before the claim loses
`shutdown_cancelled` at the deadline and never dispatches. Connection loss while
a mutation worker is queued behind an earlier ticket kills and reaps that
worker, terminalizes its exact queued origin and starts no core task; the same
loss while a lightweight worker is blocked at `:infinity` kills and reaps it
without killing the daemon or lease-owner actor named separately in the permit.
Separate
owner-start and mirror-ack cases queue the continuation ahead of the timer but
cross the monotonic instant, proving no grant or mirror success after it. At the admission bound the owner enters
`lease_ops_frozen`: pending rows become `shutdown_cancelled`, executing
non-lease rows remain tracked to result or step 3, existing-owner
actors or fresh-acquire provisional children are killed and reaped and
terminally recorded without pretending their mutation rolled back, while the
daemon owner survives its fresh-acquire case; queued owner/mirror work becomes
`shutdown_admitted`, and a pending mirror kills the exact registry and latches
`connections_lost`. Idle and granted owners remain through quiesce. Only after
every connection and request worker is down does the second `tearing_down`
barrier freeze and collectively sweep that remaining set; no owner or mirror
exists afterwards. The expiry linearization above, with a mutation blocked inside
core across the deadline settling under its own lease while the eligible
takeover waits and is granted only after it resolves, the holder's next
mutation refused at the deadline, the acquiring request refusing with
`control_pending` when its own deadline elapses first, the holder's connection
disconnecting while its mutation is in flight, and the lease owner
failing while a mutation is in flight — in every case exactly one of settle or
refuse, never both, and no epoch reused; live-owner takeover only after release
or expiry. Post-owner-loss successor start additionally waits for exact
dead-owner pop, classification acknowledgement and terminal holder-close or
correlated-refusal settlement, while its first grant waits for every retained
predecessor ticket and retirement completion. Either route mints a fresh epoch
before the successor's first command; the three ways
a controller stops holding proved separately, because only one of them is
early and the transport cannot tell the other two apart — an explicit
`session.release_control` linearizes release at the relay's `result` CAS and
reports success only after mirror-clear settlement, while an EOF from a politely
closed client and a killed client both wait for expiry, with a takeover
refused before the deadline and granted after it in both cases; a controller
killed mid-run fenced after takeover, its late commands refused; a
lease owner killed while a mutation is in flight taking neither the daemon nor
any other session down: that session's controller connection is sent
`control_owner_lost` and closed with its attachment, its observers stay
attached on their own connections, the replacement owner does not start until
the pop, classification and terminal-notification barrier completes, the relay
retains the outstanding ticket and the replacement owner's first grant waits
until it and retirement completion settle, and the previous holder's delayed
command is refused on both the holder and the epoch check;
at a population of 512, a retiring predecessor held after intent
acknowledgement keeps its slot and no successor pid exists, an unrelated 513th
acquisition refuses, and exact predecessor `EXIT` atomically transfers that one
slot to the queued same-session `starting_waiting_pop` reservation before any
spawn; the full routing-and-notification barrier then permits that spawn, so the
live process count never reaches 513;
mirror-publication cuts killing a lease owner before it sends the daemon
request, after that request reaches the daemon but before the registry ack, and
after ack before the daemon replies; registry suspension while Store loss and
`SIGTERM` are consumed; registry death during install; a queued apply at the
five-second deadline; a late stale ack; and an old exact clear racing a
successor install — proving the linked daemon owner remains responsive, defers
an ordered owner `EXIT`, atomically latches `connections_lost` and kills the
registry on unresolved timeout without an unnamed reap wait, emits exactly one
classification or owner outcome, and preserves no continuing daemon in which a
stale row could authorize routing;
fresh-owner and existing-owner takeover grants each force connection `DOWN`
before and after the permit result CAS. Registry-close-before-relay-`DOWN`
makes an exact not-live install refusal select `connection_lost` and reap the
proposal; loss-first leaves no provisional row, child or visible epoch, while
result-first promotes the exact row even after the slot becomes `closing` and
leaves a real lease whose reply may be lost. Both wait for the exact registry
resolution acknowledgement, and every unexpected refusal or timeout selects
`connections_lost` rather than inferring success;
an abort from the new
controller cancelling work dispatched under the old controller's command
with a truthful cleanup outcome; an observer never acquiring authority
through content, metadata, answers or order; after a daemon restart every
session uncontrolled, an epoch from before the restart refused, and the
first acquire granting a fresh epoch; forward and backward wall-clock jumps
not changing live admission or takeover timing; creation yielding an
uncontrolled session and requiring both attach and explicit acquire before
prompt, proved in both orders, with the prompt refused while either is
missing; a dormant session acquired by ID, then resumed with epoch and
attached.

Each of the five lifecycle barriers is also proved independently: `cut` under
the transport-cut deadline; `freeze_lease_ops` and `quiescing` under their fresh
five-second deadlines; and `seal_after_quiesce` and `tearing_down` under the
remaining shared teardown deadline. For every action, the exact correlated
acknowledgement advances once; stale and wrong-reference acknowledgements are
ignored; an exact malformed response and a suspended relay atomically latch
`relay_lost`, notify the sentinel, send untrappable `:kill` and enter fail-stop
without awaiting an out-of-phase reap; and another owned component `EXIT` while
the barrier is pending keeps the precedence of the first fatal class. An exact
acknowledgement consumed just before the monotonic instant succeeds, while the
same acknowledgement consumed at or after it is cleanup-only. A failed cut,
freeze or quiescing barrier starts no core quiesce; a failed seal or
tearing-down barrier reports no operator-stop success. Every later relay `EXIT`
is cleanup-only under the 35-second fail-stop watchdog.

### Alternatives

Placing the lease in core was rejected because the vision keeps collaboration
policy above core and another host may choose a different rule. Last-writer-
wins without an epoch was rejected because a killed controller's late command
would interleave with the successor's. A lease with no expiry was rejected
because a crashed controller would hold the session forever. A durable lease
record was rejected: after a daemon restart every connection is gone with its
socket and admission already requires the holder connection, so durability
could only preserve an epoch counter that nothing needs. A counter-based
epoch scoped to the daemon incarnation was rejected on 2026-09-14 because a
lease-owner process restart under the same incarnation would mint values
already issued, and a connection re-acquiring after such a restart could
have its own earlier delayed command admitted; a fresh random epoch per
grant costs nothing and closes that hole.

<a id="technical-adr-0033-compatibility"></a>
### Compatibility and Rollback Mechanics

Concept: [Consequences and rollback](0033-collaboration-controller-lease-and-takeover.md#concept-adr-0033-consequences).

The lease methods and the `writer_epoch` field exist only in generation 2 of
the experimental protocol, which is the only generation the daemon serves.
The M4 foreground server still has its own single connection and no daemon
lease. Core session records, events and snapshots are unchanged. Removing the
daemon removes the lease with it; no journal or file depends on it.

Acceptance binds this complete pair at the exact candidate the maintainer
names in the governance record. Its evidence and compatibility claims remain
unproved until the tests the M5 plan maps to Outcome 3 exist and pass, and
Outcome 5 closes against those same bytes.
