<a id="technical-depth"></a>
## Technical depth

Concept: [Daemon attachment residency and replay](0032-daemon-attachment-residency-and-replay.md#concept).

<a id="technical-adr-0032-decision"></a>
### Contract and Evidence

Concept: [Context and decision](0032-daemon-attachment-residency-and-replay.md#concept-adr-0032-decision).

### Transport

The daemon listens on one Unix-domain socket, and where it puts it matters.
Its path is `<state root>/daemon/daemon.sock` by default, inside a
daemon-owned subdirectory the daemon creates mode `0700`, and it may be set
explicitly to another path under the same rule.

The shared parser/path resolver first applies `String.valid?/1` to the selected
state-root binary and to an explicit socket-path binary, before `Path.expand/1`,
path containment, readiness encoding, or any filesystem, placement, Store,
component or socket operation. Invalid state-root bytes refuse
`state_root_unusable` for daemon startup and `daemon prepare-index`; because the
default socket derives from that root, the root refusal owns that case. Invalid
bytes in an explicit `--socket` value refuse startup as `invalid_socket_path`.
This is a direct binary boundary rather than an assumption about how a given OS
normalizes environment or argument bytes.

It is a subdirectory rather than the state root itself because the root is not
the daemon's to re-permission. `LoopexAppServer.Host` creates it with
`File.mkdir_p/1` and no mode, so under the ordinary umask of 022 an existing
M4 root is `0755` — measured, not assumed. Requiring the *root* to be `0700`
would have made the daemon refuse every root the foreground server and the CLI
have been writing since M4, which contradicts this milestone's central
compatibility claim: daemon-to-foreground rollback and switches after the
one-time daemon-index import require only stopping one surface before starting
the other. A first M5 daemon over a populated legacy root still requires that
explicit offline import. Tightening the root instead
would be an unannounced permission change to an operator's existing directory.
The daemon therefore owns one subdirectory and leaves the root's mode exactly
as it found it.

**The path bound is derived, not assumed.** `sun_path` is 104 bytes on Darwin
and 108 on Linux *including* the NUL terminator, so the usable path is one
byte shorter than the structure: at most 103 bytes on Darwin and 107 on Linux.
That is measured, not inferred — on the supported OTP 29 Darwin toolchain a
bind at 103 bytes succeeds and at 104 bytes is refused with
`{:invalid, {:sockaddr, …}}`. Each supported platform derives its own bound
the same way rather than carrying a constant, and a path beyond it is refused
at start with `socket_path_too_long` naming the derived bound, never
truncated. The closure matrix binds at the bound and at one byte past it on
both supported platforms: Darwin in the floor-pair fast check and Linux in the
current-pair CI and release lanes.

**Peer authorization has two layers, and the load-bearing one is the
filesystem.** The socket lives in that `0700` daemon-owned subdirectory and is
itself created mode `0600`. Both are verified after bind by reading back their
owner and mode and comparing them with the daemon's own effective user, and
the daemon refuses to serve if either is wrong, if the subdirectory is not
owned by that user, or if any component of the path below the state root is a
symbolic link it did not create. The state root above it is read, never
re-permissioned and never required to be `0700`. That is what actually keeps another user out:
connecting to a Unix-domain socket requires write permission on the socket and
traversal of its directory, so a foreign peer never reaches `accept`. It is
the same arrangement ADR 0019 already uses for the provider child's private
channel, proved there, and reused rather than reinvented.

**Peer-credential inspection is the second layer, and its mechanism is named
per platform** because the portable one does not exist. On the supported
OTP 29 Darwin toolchain `:socket.supports(:options, :socket)` reports
`peercred: false` and `passcred: false`, and `:socket.getopt(sock, :socket,
:peercred)` answers `{:error, {:invalid, {:socket_option, …}}}`; the named
option is simply not available there. What is available is the raw option:
`:socket.getopt_native(sock, {0, 1}, 128)` — Darwin's `SOL_LOCAL`,
`LOCAL_PEERCRED` — returns a `struct xucred` from which the peer's effective
uid is decoded, and it was confirmed to return the connecting process's uid on
that toolchain. On Linux the mechanism is `SO_PEERCRED` at `SOL_SOCKET`,
yielding `struct ucred`. Both are socket options, and the classic `inet`
backend exposes neither, so the listener uses OTP's own `:socket` API (or
`gen_tcp` over the socket backend, whose handle it can reach) rather than the
classic backend. A peer whose decoded uid differs from the daemon's is closed
before any frame is read.

**Startup creates a parked listener before it creates an accept.** The bound,
listening socket is transferred to the listener with an unforgeable
`startup_ref`; the listener monitors the daemon owner, acknowledges that it is
parked and performs no `accept` until the lifecycle sentinel sends exact
`{:begin_accept, startup_ref}`. The signal handler targets that sentinel. The
owner submits exact
`{:begin_readiness, owner_ref, startup_ref, listener_pid, line}`; the sentinel
starts and monitors the whole-line helper, records the absolute five-second
deadline and becomes the single startup-disposition arbiter. It serializes
matching stop, helper result, helper `DOWN`, deadline check, owner-reported
startup fatal and owner release authorization. The timer only prompts a clock
check, and every candidate result is rejected at or after the absolute instant.

From submission until the sentinel returns a disposition, the owner remains in
its owned-exit loop and immediately reports a consumed component fatal. Exact
output success does not release the listener. The sentinel sends exact
`{:readiness_output_succeeded, owner_ref, startup_ref, sentinel_pid}` to the
owner; the owner consumes queued component exits, rechecks the clock and every
required component, then sends exactly one of
`{:readiness_release_authorized, owner_ref, startup_ref, owner_pid,
listener_pid}` or
`{:readiness_startup_fatal, owner_ref, startup_ref, owner_pid, listener_pid,
class, status}`. Because
one owner sends both, an owner-observed fatal is ordered against its later
authorization. The owner waits for the sentinel's exact disposition and does
not independently clean up or declare startup complete.

The first valid disposition consumed by the sentinel wins. Stop selects
provisional `:operator_stop`; startup fatal retains that class and status;
helper refusal, helper death or deadline selects `readiness_write_failed`.
Every nonzero winner is also the sentinel's retained first-fatal class and
status and arms its watchdog. Deadline expiry hard-halts with that exact status
because an IO request already queued at the IO server cannot safely be
recalled; a completed refusal or helper death tells the owner to reverse-clean.
Stop merely authorizes the owner to halt with status `0` after cleanup
completes; owner death before then selects `owner_lost`. Except for deadline
hard-halt, the winner is returned as exactly one of
`{:readiness_disposition, owner_ref, startup_ref, :operator_stop}`,
`{:readiness_disposition, owner_ref, startup_ref, {:fatal, class, status}}` or
`{:readiness_disposition, owner_ref, startup_ref, :running}`. Stop or fatal
tells the owner to reverse-clean and
leaves the gate parked; every later candidate is cleanup-only. The sentinel
kills and reaps any retained helper during bounded cleanup without claiming it
recalled queued IO. The complete line may already be visible because helper,
signal handler and owner are different senders, but no server connection
process, registry row, relay origin, lease owner, attachment, core call or wire
state exists.

Only release authorization consumed before the deadline and any other
disposition lets the sentinel send `{:begin_accept, startup_ref}`. It records
`running` before returning the exact `:running` disposition and forwards any later
stop for the ordinary shutdown path. That exact send is the classification
cut: an owner-observed linked listener `EXIT` ordered into the sentinel before
authorization is `listener_start_failed`; after the send it is
`listener_lost`. The rule uses observable messages and the sentinel's send,
without inferring kernel-time order. A client queued in the backlog observes
service only after release, or close without initialize or mutation. Verified
stale placement, marker and socket recovery handles crash residue. Forced
cases cover stop versus success/refusal/death/deadline in both sentinel orders,
component fatal versus success/deadline in both sentinel orders, and both
sides of the listener cut.

**The listener transfers every accepted socket before the connection becomes
live, with a monitor in both directions during the handoff.** After `accept`,
the registry holds a provisional row
`{rollback_token, listener_incarnation, accepted_at, initialize_deadline,
connection_pid | nil, connection_incarnation | nil, transfer_disposition}` and
monitors the listener. `transfer_disposition` is exactly `:listener_owned`,
`:transferring` or `:connection_owned`.
`accepted_at` is the listener's monotonic instant immediately after the kernel
accept returns, and `initialize_deadline = accepted_at + 30_000`; neither value
is recomputed. The listener never creates a connection process. It asks the
registry to start one for the exact rollback token. In that one serialized
registry callback, after rechecking the row, listener incarnation and deadline,
the registry calls `GenServer.start_link/3` with itself, the listener and that
unchanged deadline in the waiting child's arguments. The child's `init/1` does
no IO or external call: it installs monitors on the registry and listener and
returns immediately. Before it serves, the registry sets
`Process.flag(:trap_exit, true)` and retains the exact daemon-owner pid, whose
own `EXIT` still stops the registry. A temporary child's `EXIT` is instead
matched by its exact pid and handled idempotently with that child's monitor
`DOWN`; it can never take the registry down. Before the callback replies or
processes any queued listener `DOWN`, child `EXIT` or child `DOWN`, the registry
installs its provisional child monitor, binds the returned pid and fresh
connection incarnation into the row, prepares the updated state, then unlinks
the child. From the instant of creation until that unlink, the registry link
owns the child; afterwards the child's registry monitor and the registry's
child monitor own each other. A caught start exit or returned start
failure leaves `connection_pid: nil` and enters the ordinary no-child abort.
Thus `nil` means no child exists, never “a child may have been returned but not
recorded.” If the registry dies at any point, its link or the child's registry
monitor ends the child; registry loss remains daemon-fatal.

Only the exact successful registry reply gives the listener the child pid and
incarnation. The connection already monitors the listener. While the listener
is still the socket owner, it compare-and-sets the row from `:listener_owned`
to `:transferring`, calls
`:socket.setopt(socket, {:otp, :controlling_process}, connection_pid)`, and
reports that exact call's result to the registry before it may promote. The
registry changes a successful result to `:connection_owned`; a refusal returns
the row to `:listener_owned` for exact close.

Only after that succeeds may the connection ask the registry to promote the
slot. In one registry callback, promotion changes the exact provisional row to
live **before** replying and keeps its connection monitor as the permanent live
monitor. After that acknowledgement, the connection flushes and removes its
listener monitor, begins receiving, and sends the listener
`promotion_complete`. Only that message lets the listener demonitor and flush
its temporary connection monitor.

The registry transition is a compare-and-set on the rollback token and
connection incarnation. Reservation, child start, socket transfer, promotion,
the connection's first receive and every initialize continuation recheck
`monotonic_now < initialize_deadline`; the same deadline survives every
handoff. Before promotion, either provisional monitor `DOWN`, expiry, a
deadline check that loses, a
failed child start, a failed transfer or a failed registry commit changes
`provisional(token, :handing_off)` to `provisional(token, :aborting)`; that
substate remains an occupied provisional slot. The registry already monitors
the exact listener incarnation, so its `DOWN` is terminal evidence that every
socket still owned by that listener is closed. If no child was started, the
registry removes the row only after either the listener's exact socket-close
acknowledgement or that exact listener `DOWN`. With a child, the transfer
disposition decides cleanup. In `:listener_owned`, the registry requires that
close acknowledgement or listener `DOWN` **and** kills and reaps the child. In
`:connection_owned`, it kills and reaps the exact connection, whose death
closes its socket. In `:transferring`, it marks abort pending and waits for the
listener's exact transfer result, then takes exactly one of those branches. If
the listener dies before reporting, listener `DOWN` closes the
listener-owned possibility and killing/reaping the child closes the
successfully transferred possibility; the registry removes the row only after
both exact `DOWN`s are accounted. This remains true
when the transferred socket's owner is suspended: an abort request being queued
is not evidence that the pid or socket is gone. Promotion changes only
`:handing_off` to `live` and requires `:connection_owned`. After promotion or exact reap, a late abort, promotion
or `DOWN` for the token is a no-op. The daemon owner also observes listener exit
and orders
`abort_provisional_for(listener_incarnation)` before fatal listener teardown;
that idempotent sweep covers listener loss between slot reservation and child
start and simultaneous listener/connection death rather than depending on one
temporary peer surviving to report the other.

The connection process owns the transferred socket, and the registry owns its
live monitor and buffer interface without linking to it. Because no listener
monitor remains after the two acknowledgements, listener death cannot
propagate to or close a promoted connection. No accepted socket enters the
registry's live set while the listener still controls it. Forced witnesses
cover slot reservation before child start, listener death after reservation
but before child start, and the registry paused after `start_link/3` returns but
before it binds and unlinks the child: listener death makes the child exit too,
but the trapped child `EXIT`, child `DOWN` and listener `DOWN` remain queued;
the registry completes the atomic bind when resumed, consumes them
idempotently, survives, and reaps the exact child, row, socket and slot. They
also cover expiry after child
start while the listener still owns
the socket, listener death after a failed transfer restored
`:listener_owned` but before close acknowledgement, transfer failure on each
side of the ownership change, expiry and abort racing transfer in both result
branches, promotion refusal, abort racing promotion, connection death
after transfer but before promotion, and simultaneous listener/connection
death; each awaits the exact close acknowledgement or listener/connection
`DOWN` required by its disposition and
leaves no socket, pid or provisional row. A suspended post-transfer connection
keeps its aborting slot charged while repeated accepts prove there is no 513th
connection process or socket; reaping it frees exactly one slot. A final case completes
promotion, kills the listener and proves the connection and socket remain
available for the bounded `fatal:listener_lost` write and close. The registry
owns the one deadline timer keyed by rollback token and connection incarnation.
The timer only prompts a monotonic check: expiry in a provisional row takes the
ordinary abort-and-reap path; expiry after promotion but before initialization
moves the live row to closing and closes it with EOF; and only the registry's
exact initialize-complete transition consumed while `now < deadline` cancels
and flushes the timer. A completion queued before the instant but consumed at
or after it is cleanup-only and cannot make the connection initialized.

**Fail closed.** Where a platform has a named mechanism, a credential read
that errors, returns a short or unrecognised structure, or reports a uid the
daemon cannot decode closes the connection before initialize; it is never
treated as permission. Where a platform has no mechanism at all, the daemon
says so in its diagnostics and the boundary is the verified filesystem layer
alone — which the daemon proves it has, because it refuses to serve when
ownership and mode cannot be verified.

The evidence follows the same split. The fast check proves the filesystem
layer and every fail-closed credential branch without needing a second user: a
permissive directory or socket mode, a parent the daemon does not own, and a
path component the daemon did not create are each refused at start; a
credential read that is unreadable, short, undecodable, or validly decoded to
a mismatched uid closes the accepted connection before initialize. The Linux
release lane has two tagged cases under a real second unprivileged user. The
foreign-user case first proves the verified `0700`/`0600` filesystem boundary
denies the connection in the kernel. The fixture then deliberately relaxes
those two permissions *after readiness*, allowing a new foreign-user
connection to reach `accept`, and proves `SO_PEERCRED` decodes that uid and the
daemon closes it before initialize; this test-only tampering is what makes the
second-layer assertion non-vacuous. The paired daemon-uid connection succeeds.
Both cases restore the directory and socket modes during cleanup and record
their results with the run.

Startup order is fixed. The daemon first acquires the root's host placement
lock through the shared mechanism accepted ADR 0008 and already used by the
reference CLI. A live or unverifiable placement owner refuses before the Store
or socket path is touched; a stale owner is reclaimed only after its OS pid and
process incarnation are proved dead. The daemon then opens the state root
through the local adapter and acquires its writer marker; a daemon that cannot
hold the marker refuses with the adapter's `store_writer_active` or
`store_writer_unverifiable` reason and still never reads, unlinks or binds the
socket path. The daemon opens the root with `recover_stale_writer: true`,
explicitly, because that option defaults to `false` in both
`Loopex.Store.Local` and `LoopexComposition` and a daemon that did not ask for
it could never restart after being killed. Asking for it is not asking to
ignore a holder: the adapter reclaims the marker only where it probes the
recorded holder and finds it dead, leaves it in place with
`store_writer_unverifiable` where the holder cannot be decided, and refuses
with `store_writer_active` where the holder is alive. All three are proved
before the socket path is read, unlinked or bound. Only a daemon that holds
both the placement lock and the Store marker may remove a stale `daemon.sock`
left by a dead daemon and bind a new one, so two simultaneous daemon starts on
one root resolve at the placement lock, exactly one listener exists, and the
loser exits without touching the Store or socket.

**Removing the pathname is the successor's job, not the predecessor's**, and
that follows from the same rule read in the other direction. A daemon's claim
on the path is its placement lock plus its successfully opened Store. **No daemon unlinks on its way out at all** — not on
an orderly stop, not on any fail-stop, not in reverse cleanup. The next daemon
to acquire and verify the placement lock and marker removes the stale pathname before binding,
which is the one moment at which removing a socket file is unambiguously
correct.

M5 also closes the placement gap behind that rule. A Store self-stop invokes
its best-effort marker release before the daemon can react, so the marker alone cannot protect the
old Runtime Control. The independent placement lock names the daemon OS process
and stays held through every fatal halt. While the predecessor daemon and its
Control remain live, a contender receives the placement live-owner refusal and
cannot open the Store or touch the socket. After the predecessor halts,
verified stale-owner recovery reclaims the placement lock; the successor then
acquires or recovers the Store marker and removes the pathname. The forced
interleaving witness holds predecessor Store-EXIT handling after the release
attempt returns,
starts both a separate-VM contender and a same-VM second acquisition and proves
both refuse while the old Control is live, then releases the predecessor to
fail-stop and proves one successor starts by stale-placement recovery. There is
no interval with two active Controls for one `{Store identity, runtime_id}`,
preserving accepted ADR 0008; Store commit fencing alone is not treated as
placement safety.

After composition the daemon owner resolves and monitors the exact `Control`
and `EventDispatcher` pids for that runtime generation. Either `DOWN`, or a
child lookup that identifies a replacement while the daemon is serving, is
fatal `runtime_lost` even when the root supervisor survives. An empty
replacement would erase core session or attachment state while daemon leases,
reservations and sockets still claim it. Those monitor messages are expected
only once deliberate runtime teardown begins. During active `quiesce/1`, root
loss remains `runtime_lost`. A captured-Control event first checks the retained
exact root pid: dead root selects `runtime_lost`, while live root with lost or
replaced Control invalidates the drain as `drain_failed`. A captured-
EventDispatcher event checks the retained root and Control pids in that order:
dead root selects `runtime_lost`; live root with absent or dead Control selects
`drain_failed`; and both exact pids live selects `runtime_lost` for isolated
dispatcher loss. The checks are nonblocking and call neither process nor the
supervisor, so root exit and Control-triggered `:rest_for_one` each retain one
classification in every monitor/link-message order. Later monitor events
are cleanup-only after the first class is latched. Tests kill each child with
controller and observer attachments live, force both monitor orders for a
Control restart during quiesce, force root/child messages in both orders for a
root exit, and force dispatcher-only loss with root and Control still live.
They prove the exact fatal class, close and absence of stale daemon
accounting. A healthy branch proves marker
absence and immediate reopen; an injected unlink or parent-sync failure leaves
a complete residual that follows the adapter's live, dead and unverifiable
holder rules.

The shutdown fence does not give the quiesce caller a Store handle. The first
census is one atomic `Control` operation: it sets `quiescing: drain_id` and
returns the entries and ordinary coordinator pids. From that point, create,
resume, attach and ordinary coordinator-route requests ordered after the
barrier return `runtime_unavailable`. Create and resume perform their Store
work inside their serialized `Control` calls: when either call is already being
handled it finishes its Store work and entry-or-dormant decision before
`begin_quiesce/1` can be handled, and when the gate wins it refuses that call
before Store access. Every handled-first path that leaves a coordinator writer
installs its entry; a committed create whose owner cannot start is durable and
dormant with no writer, so it needs no shutdown fence. The
gate freezes the census key set until every fence disposition is known.
Owner-ready, owner-replayed, owner-unavailable and monitor messages may update a
retained entry, but may not delete one; an owner-group `DOWN` for
`:awaiting_owner_barrier` answers its waiters `runtime_unavailable`, retains the
entry and its fence inputs, and never calls `do_start_owner`. The gate is
terminal because `quiesce/1` is a shutdown operation.

That transition is single-use. `begin_quiesce/1` succeeds only when
`quiescing` is unset; a concurrent or later call that finds any drain ID already
installed returns `{:error, :runtime_unavailable}` before starting per-session
work. Two callers therefore cannot admit two aborts, terminate the same
coordinator twice or start competing fence-mode writers. A forced concurrent
case proves one caller owns the drain and the other starts no worker.

The daemon-scoped, `@doc false` `quiesce/1` entry point starts and monitors one
private phase-owner process;
it does not change the arbitrary caller's `trap_exit` flag. The phase owner
monitors that caller, sets `trap_exit`, owns the census and deadlines, and starts
the linked, non-trapping per-session workers. It is a pure receive coordinator:
child lookup, `Control`/coordinator calls, supervisor calls and temporary-owner
waits all run in workers, so caller `DOWN` and worker exits cannot wait behind a
blocking call. One abnormal worker `EXIT` becomes
only that session's conservative phase result while siblings finish. Phase-owner
death makes the public call return `runtime_unavailable`; caller death makes the
phase owner terminate every linked worker. For the daemon, the caller is
its unlinked outer helper, so killing that helper during fail-stop also removes
the phase owner and its worker tree before any later phase can start.

Core owns four fixed phase clocks rather than accepting a daemon deadline:
`quiesce_admission_ms: 70_000`, `status_census_ms: 10_000`,
`coordinator_termination_ms: 330_000`, and `fence_budget_ms: 130_000`. Every
clock is one absolute instant shared by the whole bounded population. The first
reserves its initial 5,000 ms for exact-Control resolution and
`begin_quiesce/1`, admits all per-session aborts concurrently before its
5,000 ms kill/reap tail, and leaves at least 60,000 ms for the maximum two-call
drain-only local-Store path. A failed initial projection returns
`runtime_unavailable`; an unanswered per-session admission is `unsettled` and
releases no cleanup.

The initial projection is also the process and result bound. `Control`
maintains a monotonic set of session IDs whose `writer_started?` fact became
true. `begin_quiesce/1` installs the gate, freezes that writer-domain set and
projects only those IDs. The bit and set membership are written in the same serialized Control
callback immediately after `DynamicSupervisor.start_child` returns `{:ok,
coordinator}` and before later attach or readiness work. If that eligible set exceeds 64, the phase owner returns
`{:error, :runtime_unavailable}` before it spawns any per-session worker. The
terminal gate remains installed because this is a shutdown-only entry point. A
daemon cannot reach that branch under its activation-plus-reservation invariant,
while another internal caller cannot turn one call into an unbounded process
fan-out or cross-application result. One witness holds more than 64 no-writer
dormant entries beside 64 writer-domain IDs and proves the no-writer entries
are omitted from all three lists and the fence map and spawn no workers; a separate
65-eligible-entry core witness asserts the refusal and zero per-session workers.

For each active coordinator from that census, the helper sends one
drain-specific call. In the coordinator mailbox that call atomically closes
ordinary command admission and then proposes the existing abort. An ordinary
command processed before it is part of the run the abort observes; an ordinary
command processed after it refuses `runtime_unavailable`. Internal owner,
commit, cancellation, receipt and recovery messages remain admitted so work
already linearized can settle. Therefore `rejected_no_active_run` is evidence
that no later ordinary command can start in that coordinator, rather than a
snapshot a delayed routed command can invalidate. A forced witness holds a
pre-barrier prompt after `Control` routing but before
`SessionCoordinator.command/3`, lets the drain call return
`rejected_no_active_run`, then releases the prompt and proves it refuses with no
prompt record. Paired create and resume calls are forced in both `Control`
mailbox orders. If the gate is handled first, the call refuses with no entry or
durable record; if the create or resume call is handled first, its Store
operation and entry-or-dormant decision complete before the gate. A resulting
entry whose writer was started follows the ordinary terminate-and-fence path; a
post-commit owner-start failure has no writer, remains dormant and is omitted
from the drain projection and fence map.

At most 64 admission calls run concurrently. At
`admission_deadline - 5_000` the phase owner kills every unanswered worker and
requires its exact exit by the outer instant. A coordinator call already queued
may later admit only the deterministic paused abort; no cleanup is released for
it, and termination plus exact-ID recovery and fencing conservatively resolves
its disposition. The phase never waits through an arbitrary coordinator
mailbox backlog.

Every committed abort pauses at the existing cleanup split. Only when every
admission is committed or definitively `rejected_no_active_run` does one
phase-owner transition compute `budget_ms` from the committed paused-cleanup
set, start `cancellation_deadline = now + budget_ms`, and release every cleanup
together. An empty set has budget `0`; if any admission failed, remained
ambiguous or did not answer, no cleanup is released and the budget used is `0`.
All released sessions share that one absolute instant. The status census begins
at the earlier of every released cleanup reaching a terminal state or that
deadline, without a per-session, timer-delivery or late-message restart. A
maximum-population witness releases 64 cleanups at the same controlled instant,
proves an all-early set advances as soon as all are terminal, then holds a mixed
set through the cutoff and proves the deadline advances classification once
rather than 64 times in sequence.

The drain abort's identity is restart-recoverable. Core adds
`SessionState.drain_abort_command_id/2`, using the existing deterministic
`stable_id/3` discipline under the `"drain_abort"` namespace with the session
ID and pre-admission `owner_epoch` from the durable head. The Store binds that
identity on first presentation to the exact journal version, owner incarnation
and canonical abort digest. The
result is both the abort `command_id` and its Store `tx_id`; it grants no
authority, while the Store still binds the proposal to the current owner
incarnation and canonical mutation. The namespace prevents accidental
cross-kind collisions but is not reserved from a client supplying the same
binary. Live admission and restart therefore validate the retained
command-idempotency row's exact abort type, canonical drain-abort digest and run
binding before replay; transaction status alone never proves that an abort was
committed. During the live drain, a row deliberately pre-bound to another
command makes abort admission fail as `idempotency_conflict`; cleanup is not
released, the session is reported unsettled, and termination/fencing proceeds.
On restart, exact replay of a different committed command proves that no drain
abort occupied that candidate, so recovery treats it like an absent drain
candidate and continues. Only a committed status whose replay binding is
missing or malformed keeps activation unavailable. The ordinary coordinator presents that
commit once. On `commit_unknown` it returns the candidate ID and head and
releases no cleanup.

After that coordinator is `DOWN`, fence mode queries the exact abort ID. A
terminal commit is replayed before fencing from the resulting head; a terminal
non-commit proceeds; `:absent` is non-terminal and proceeds to the fresh fence
CAS, so whichever of the delayed abort and fence moves the original head makes
the other stale; `:unavailable` proposes no fence and returns a tagged
abort-stage unknown. After a crash, existing-session activation replays, reads
current epoch `E`, and queries `drain_abort(E)` and, only on absence or exact
replay that proves a different-binding collision/no-drain, `drain_abort(E - 1)`
when a predecessor exists. A retained commit is replayed
from the journal only when its exact abort type, digest and run binding match.
An exact different binding is collision/no-drain and continues the bounded
search; a terminal non-commit resolves that exact operation; an unattributable
committed, unavailable or malformed result stays fail-closed. Only then does
activation resolve the current and predecessor epoch fence IDs before ordinary
succession. It admits
no command until exact-ID recovery and its fresh-ID owner-succession CAS both
finish. Abort and fence discovery each add at most two status queries to
existing-session activation. A fresh create adds none. The ordinary shutdown
fence remains at most three Store calls; ambiguous-abort resolution plus that
fence is at most four.

The abort namespace is single-use per owner epoch. The terminal quiescing gate
permits one drain abort per session in a daemon lifetime, and a later lifetime
must commit fresh owner succession before admission or another drain. Correct
core therefore cannot bind `drain_abort(session_id, epoch)` to a second journal
version. Forced restart cases cover a same-epoch stale-journal result, a
predecessor-epoch commit after a fence advanced the head, both candidates
absent, unavailable and malformed status, attempted same-epoch reuse, and a
client command deliberately pre-bound to the derived ID with a different
digest and type.

Attach has a second serialized cut because its registration spans Control and
EventDispatcher. Its state-changing Control pending-row reservation is the
linearization point against `begin_quiesce/1`. Gate first refuses with no
pending or dispatcher state and no borrowed capacity charge. Reservation first
grandfathers only that exact transaction and dispatcher incarnation through
stage, authorize, publish and finalize or discard. Quiesce neither enumerates
nor waits for this transient attach state. During ordinary service and holder
retirement, the relay retains its ticket and the daemon slot until the real
result. During orderly shutdown, successful `seal_after_quiesce` kills the relay
task and removes an unresolved ticket; the core transaction and capacity charge
remain cleanup-owned until holder `DOWN` or runtime teardown, with no capacity
reuse after the admission cut.

After the root-derived cancellation budget, the status census issues all at
most 64 `session_status/2` calls together under one
`status_census_ms: 10_000` instant. Their existing 5,000 ms call bound is the
work cutoff; the remaining 5,000 ms kills and reaps unanswered workers, whose
sessions are `unsettled`.

The later termination projection is a read under the already-closed gate. It is
the first 5,000 ms of one
`coordinator_termination_ms: 330_000` clock and has
the same writer-domain session-ID set as the first census, although an entry may
have changed status or disappeared. Each domain entered the monotonic set when
its `writer_started?` fact was set immediately after the coordinator child started successfully and never cleared in
that runtime lifetime. Status alone is insufficient: dormant can mean either a
post-commit start failure with no writer or a formerly active entry, and
unavailable can follow either kind of path; in particular, a started owner whose
attach later fails is reset to `:unavailable` but may already have entered Store
succession. Entries for which the fact is false need no fence because no process
was ever authorized to write; they are deliberately absent from the bounded
projection and result. Every projected domain is fence-eligible, including a coordinator child that started
but failed before owner readiness or attach completion. Ordinary start and bit
assignment are one serialized `Control` callback: `begin_quiesce` cannot enter
until `DynamicSupervisor.start_child` returns and that callback sets the bit. If
the bounded `Control` call cannot finish, quiesce returns
`{:error, :runtime_unavailable}` and claims no census. Thus no ordinary pending
start crosses a successful projection. The
serialized projection rejects more than 64 writer-domain IDs
as `{:error, :runtime_unavailable}` before spawning per-session work. A correct
daemon cannot reach that branch because the activation set plus reservations is
bounded at 64, even when it has accumulated more no-writer dormant entries.

After that projection, the phase owner issues all at most 64
`DynamicSupervisor.terminate_child/2` calls together. They serialize through
the one session supervisor and each child has `shutdown: 5_000`, so the work
cutoff is `termination_deadline - 5_000`: 320,000 ms after the projection
allowance. At that cutoff the phase owner directly kills every coordinator still
alive and every still-live termination worker blocked in the suspended
supervisor call, then reserves the final 5,000 ms for every exact coordinator
`DOWN` and worker exit. A missing signal at the outer instant returns
`runtime_unavailable` and starts no fence. Only after
all enumerated ordinary coordinators are `DOWN` does the phase owner start a
fence operation for every eligible entry through an operation-ID handshake that
cannot authorize Store work after its deadline and leaves no pid after timeout
cleanup. A start handled just before the instant may still materialize a waiting
pid just after it, which the later checks and reap make harmless. The phase owner preallocates and retains `op_ref`, then
sends `start_fence(op_ref, phase_owner, session, absolute_deadline)` to Control.
In its serialized mailbox Control first rejects an expired deadline, otherwise uses
`spawn_monitor` with its Store handle captured inside core. The new fence-mode
`SessionCoordinator` first links to the phase owner, handshakes with Control and
waits. Control records that exact pid in the frozen entry and sends
`{fence_started, op_ref, pid}` **directly to the phase owner**; it does not send
`go`. The phase owner installs its own monitor of that pid, retains
`{op_ref, pid, monitor_ref}`, and, only while the shared fence deadline remains
live, sends `authorize_fence(op_ref, absolute_deadline)`. Control validates the
registered operation and rechecks the absolute deadline before sending
`{go, absolute_deadline}`. The fence process checks that same deadline when it
receives `go` and refuses before any Store operation if it has expired. The
phase owner never receives a Store handle.

The phase computes two named absolute instants once for every eligible entry.
At `fence_work_deadline = t0 + 125_000`, the phase owner sends
`cancel_fence(op_ref)` for every unresolved operation, kills every exact
already-authorized pid, and permits no further Store operation to begin. If
Control has not handled start before the work deadline, the deadline carried by
that earlier message makes it refuse without spawning. A started but
unauthorized operation makes Control kill the exact waiting pid and acknowledge
cancellation only after its own monitor receives `DOWN`. Authorize before cancel
means the phase owner already owns the exact pid and monitor; its kill is
idempotent and it awaits `DOWN`, while Control consumes the same terminal
operation idempotently. The phase owner uses no separate waiter worker in the
fence phase. A Store call authorized and begun before the work cutoff keeps its
ordinary ambiguity. Control cancellation acknowledgements and exact `DOWN`s are
consumed only until `fence_deadline = t0 + 130_000`. A missing acknowledgement
or surviving pid at that outer deadline returns `runtime_unavailable`; no new
head read, status query, transaction or exact re-presentation may begin after
the work cutoff.

The Store-work cutoff is `125_000` ms: four sequential local-Store calls at its
fixed 30-second call timeout cover abort-status recovery plus the worst fence
path, and five seconds cover the Control start/authorize handshake. All entries start concurrently against that one cutoff; clocks are never restarted per entry. A separate outer deadline at `130_000` ms reserves five seconds to kill and reap every exact pid after the work cutoff. The result reports that outer bound separately as `fence_budget_ms`; the existing
`budget_ms` remains the cancellation budget derived from committed session
graces, and the daemon stop line and operator page show both. Sixty-four held
fence paths plus one ordinary sibling case prove cancellation starts at the
125-second work cutoff, every exact pid and operation is absent by the 130-second
outer fence deadline, and the sibling can finish.

The other fixed clocks have matching maximum-population witnesses. One suspends
the initial Control projection and proves `runtime_unavailable` inside its
5,000 ms gate with no per-session worker. Another holds 64 admission calls past
their work cutoff, proves every worker is reaped by 70,000 ms, no cleanup is
released and a late deterministic abort is recovered rather than mistaken for
absence. A third holds 64 status calls and proves all become `unsettled` with no
worker left by 10,000 ms. A fourth suspends the session supervisor with 64
coordinators: the direct-kill cutoff runs at 325,000 ms, every exact coordinator
`DOWN` and blocked termination-worker exit arrives by 330,000 ms, and the worker
population is at baseline before fencing. Resuming the supervisor afterwards
starts no delayed coordinator, result or Store call. Each boundary is run on
both supported toolchain pairs at its smallest admitted population and at 64.

Fence mode is the only start admitted under the terminal gate. Its process is
the sole serial session owner for one abort-unknown resolution, one
`advance_owner` transaction and, on `commit_unknown`, one exact byte-identical
re-presentation of that fence transaction, reports a closed disposition, then
exits. Phase-owner death ends every such coordinator, although any Store call
already delivered retains its ordinary ambiguity. Neither the caller nor the
daemon writes Store truth directly. Forced deadlines cover cancel before Control
handles a delivered start after its carried deadline, after spawn before the phase owner receives it,
after receipt before authorization, and after authorization before `go`, as
well as before the head reply, inside the first fence transaction, and before
and inside exact re-presentation. Every cut leaves no temporary coordinator or
waiter and starts no later Store call while a sibling session finishes normally.
A suspended ordinary session-supervisor witness proves fence start still
completes through Control and that resuming the supervisor creates no late
coordinator. A forced `:awaiting_owner_barrier` case releases its owner group
after the first census and before the termination census. It proves the waiters
receive `runtime_unavailable`, the entry remains in both censuses, no replacement
ordinary coordinator starts, and the fence-mode process is the sole writer. This
keeps the founding one-serial-owner rule true during shutdown as well as service.

Fence transaction ID and proposed incarnation are deterministic under separate
namespaces from `{session_id, expected_owner_epoch}`. Journal version remains
part of the Store's immutable transaction binding and canonical digest, but not
the recoverable operation identity.
The current fence owner resolves an initial `commit_unknown` by one
byte-identical re-presentation, not by `transaction_status/4`, because status
carries no immutable binding and could describe a conflicting retained
transaction. That exact re-presentation is available only while the fence owner
still holds the transaction bytes.

A `{:not_committed, :tx_id_conflict}` on the **first** presentation is a
different, reachable branch: a client command may already have bound the
deterministic ID. Fence mode chooses no alternate identity and makes no retry;
it reports `{:unknown, :fence, head}` and the session remains `unsettled`.
That is conservative because the live process cannot attribute the retained
binding from the refusal alone. Evidence deliberately pre-binds the current
fence ID with a different client transaction and distinguishes this branch from
a conflict on exact re-presentation, which is an invariant violation after the
fence owner has already presented its own binding.

After restart a successor first replays the journal, then reads the current durable owner epoch `E`. It first
queries `transaction_status/4` for `drain_fence(session_id, E)`. A terminal
non-commit resolves a fence that lost without advancing the epoch. For a
committed result, recovery requires a replayed `owner_advanced` record carrying
the fields the adapter actually journals: matching prior and new owner epochs,
the deterministic proposed incarnation and the deterministic transaction ID.
The replayed record's stamped journal version yields
`expected_journal_version = record.journal_version - 1`; together with the
session ID from journal context and the prior epoch, those values reconstruct
the exact `Store.advance_owner/6` candidate and its canonical mutation digest.
Recovery requires every journal field to match that reconstruction. A replayed
different binding is a client collision and proves this candidate was not a
fence; a committed status with no attributable replay stays unavailable. A
matching fence while the head still reports `E` is inconsistent
and stays unavailable. Only if that identity is absent or a proved collision does the successor query the bounded predecessor
identity for `E - 1`, when such an epoch exists. A committed result there
resolves the fence that advanced the head to `E` only when the same
reconstruction matches every replayed field; a proved different
binding is collision/no-fence. A terminal non-commit also
resolves that exact operation. Absence at both identities means neither
candidate for the immediately unresolved stop is retained; it does not erase
older fence history. Store unavailability, exit, malformed output, or any result
inconsistent with the observed head stays fail-closed.

The namespace prevents accidental cross-kind collision but is not reserved
from client command IDs. The terminal quiescing gate permits one fence per
session in a daemon lifetime, and a later service lifetime must commit ordinary
owner succession before activation or another drain. Correct core can therefore
present only one **core fence** binding under `drain_fence(session_id, epoch)`;
replay attribution, rather than identity-only status, makes this the
restart-safe ADR 0008 recovery path. An acquiring coordinator's already-delivered succession
may move the epoch after its `DOWN` but before fence mode reads the head. Once
fence mode has read its head, however, the gate starts no owner and every older
CAS is bound to an older head; only the fence or a competitor on that observed
head can move it. Current and predecessor fence IDs are therefore complete even
when the acquiring straggler and then the fence produce two post-`DOWN` epoch
moves. No older identity is searched.
Only after this exact-ID recovery does ordinary fresh owner succession run; no
command is admitted until it commits.

Collision evidence covers both current- and predecessor-epoch candidates. It
reconstructs the candidate from the replayed journal fields and stamped version,
proves a different client binding is collision/no-fence, and proves a committed
status with no attributable `owner_advanced` record remains unavailable.

Framing, the initialize handshake, admission records, snapshot,
event and progress records, the frame ceiling, the strict UTF-8/LF rule and
the unknown-field rule are reused from ADR 0023 unchanged. **Request records
have one generation-2 addition**: every existing-session mutation carries
`writer_epoch`. Attach keeps ADR 0023's optional boolean `replace`; because
each protocol connection holds at most one attachment, the adapter can map
that boolean to core's exact replacement selector without ambiguity.

**The addition, at the exactness a vector needs**, because "carries
`writer_epoch`" is not a type, an optionality or a list:

| Generation-2 request | `writer_epoch` |
| --- | --- |
| `session.resume` | **binary identity, ≤ 64 bytes, required** |
| `session.prompt` | the same |
| `session.steer` | the same |
| `session.follow_up` | the same |
| `session.abort` | the same |
| `session.respond_interaction` | the same |
| `session.admit_resources` | the same |
| `session.activate_skill` | the same |
| `session.release_control` | the same — it is lease-authorized like the eight, though it starts no core call and takes no relay ticket |
| `session.create`, `session.attach`, `session.list`, `daemon.status`, `session.acquire_control`, and every ADR 0023 query | **absent, and refused if present** — an unknown field refuses before a facade call under ADR 0023's own rule (`0023-…-technical.md:131-136`) |

It is **required**, not optional: an absent `writer_epoch` on one of the nine
is a malformed request, answered with ADR 0023's `invalid_request`, and never
`control_not_held` — the gate has not been reached, because there is nothing
well-formed to put through it. Every other field of those requests is ADR
0023's, unchanged. `writer_epoch` is generation-2 transport authorization,
not part of ADR 0023's durable command semantics: ADR 0033's gate consumes and
removes it before the request is mapped to core, so exact command-ID
re-presentation after reacquisition uses the fresh epoch without changing the
core command digest. A connection is
one attachment after `session.attach`; generation 2 permits a connection to
hold at most one attachment at a time — **and at most one controller lease**,
which ADR 0033 fixes for the same reason and which is what makes closing "the
controller's connection" name exactly one session — and a client process to
hold as many connections as the residency limits admit. Its attach request
keeps optional `replace`: on either protocol generation `true` maps to that
connection's sole live attachment, while a second attach with `false` refuses
ADR 0023's existing `attachment_conflict`. Embedded callers are not subject to
the connection rule and use core's explicit `replace_attachment_id` option.

**An attachment never outlives its holder, and M5 makes the holder explicit.**
Today `Runtime.attach/3` uses the process that calls it as the transient scan
caller, the dispatcher drops that monitor after installation, and `Control`
keeps only one attachment per session. Those three facts cannot implement
multiple attachments, and a daemon relay task cannot stand in for the
connection whose lifetime the attachment must follow.

Core change 1 therefore has two entry paths with one implementation:

- `Runtime.attach/3` remains the embedded entry and uses `self()` as the
  holder;
- the daemon-only `Runtime.attach_for_holder/4` accepts the already-authorized
  connection pid as the stable holder. The admission relay starts the
  monitored attach task and passes that pid before acknowledging the ticket,
  so the task may end without changing whose lifetime owns the result.

Both EventDispatcher and Control install their **own** monitor of the stable
holder. A monitor is observed only by the process that creates it, so sharing
one reference or expecting Control to receive EventDispatcher's `DOWN` would
be an unrunnable design. Each component keeps a holder entry containing a set
of attachment IDs. EventDispatcher owns the cursor barriers, queues and open
transfers; Control owns command routing and repetition state. A holder may own
several attachments to the same session, and each ID resolves exactly one
entry in both components. On `DOWN`, EventDispatcher removes every attachment
in that holder set and calls `release_transfers/2` for each; Control removes
the same IDs and their repetition state. Each component demonitors only after
its set for that holder is empty.

**Dispatcher replacement is an attachment-generation cut, including for an
embedded runtime.** The runtime supervisor can restart EventDispatcher without
restarting Control, so every attach transaction is also bound to an opaque
dispatcher incarnation. `init/1` returns only an `initializing` dispatcher;
its `handle_continue(:register_dispatcher, ...)` starts a linked, monitored,
non-trapping registration worker and then returns, leaving the GenServer loop responsive.
The worker resolves Control through the runtime supervisor and begins the
handshake. Resolving a sibling from `init/1` would call the supervisor while it
was synchronously waiting for this child's `start_link/3` and deadlock startup;
performing the Control call in `handle_continue` would create a second
deadlock, because `Control.handle_call(:post_commit, ...)` synchronously calls
`EventDispatcher.acknowledge/3`.

Control atomically marks that incarnation initializing and terminally resolves
every predecessor pending transaction before it clears the predecessor's live
and pending attachment rows, repetition rows and holder monitors. Each retained
live caller receives the stable core error `:attachment_superseded`; a dead
caller's reply alone is dropped. The daemon relay settles the matching ticket
and releases its reserved or borrowed charge exactly once. Reserved, staged,
authorized and published-with-acknowledgement-lost rows take that same result
because the dead dispatcher cannot prove a usable handle or transfer survived.
Control releases their holder monitors and repetition state, never restores an
old replacement target, and treats any late predecessor stage, publish,
acknowledgement, cleanup or finalize message as cleanup-only under the old
incarnation. It then returns
a registration reference plus the acknowledged event sequence from each active
Control entry to the worker. The worker sends that seed to the dispatcher.
While initializing, the dispatcher refuses ordinary external operations with
`dispatcher_initializing` but **accepts and replies to acknowledgement calls**,
merging each event position into its local map. It merges the Control seed by
per-session maximum, so a post-commit acknowledgement delivered during the
handshake cannot be overwritten by an older seed.

After the dispatcher reports the merged seed to the worker, the worker asks
Control to finalize the registration reference. Control validates the exact
incarnation and moves it only to `ready_pending`; it does not open attachment
admission. The worker sends the final token to the dispatcher and exits. The
dispatcher marks itself ready and sends an asynchronous ready notice to
Control; only when Control consumes that notice does it allow attach or
attachment-authorized commands. Thus Control never waits for the dispatcher
while the dispatcher waits for Control, and Control never opens a call path to
an initializing dispatcher. A lookup, worker death or handshake failure stops
the initializing dispatcher without serving an ordinary operation; dispatcher
death kills the linked worker, and exact-incarnation validation rejects every
late predecessor message. No registration worker survives its dispatcher. The
projection contains session IDs and acknowledged positions only, no Store
handle.

Every stage, publication acknowledgement and finalization carries the
dispatcher incarnation. A late message from a predecessor refuses and cannot
recreate a cleared row. Old handles are stale and callers attach again. The
dead dispatcher owned the transfer descriptors, so its death closes them as
ADR 0028 requires; the successor never claims they survived. Seeding the
watermarks is as important as clearing the rows: without it, a replacement's
empty `acknowledged` map would make a fresh snapshot scan unbounded past an
unacknowledged outbox row even though Control retained the last safe event
sequence. A forced witness holds Control in `post_commit` while the successor
registers: the replacement accepts and merges the synchronous acknowledgement,
both operations complete, and the ready watermark is the maximum of the seed
and the acknowledgement. This is the interleaving that a synchronous
`handle_continue` registration would deadlock.

The monitors are installed before the snapshot scan starts. Control retains a
holder-liveness tombstone on every attach transaction, beside its
`reserved | staged | authorized | published` phase. A holder `DOWN` before
publication marks the transaction cancelled in each serial owner; an install
step rechecks that mark, discards the staged row and refuses
`:holder_unavailable` rather than publishing an attachment for a process
already known dead. The tombstone is retained through a publication race, so
death immediately after the relay task's core call cannot be forgotten merely
because the publish acknowledgement is still in another mailbox.

**Replacement names one attachment, and installation is a cross-process
transaction.** Core attach options gain optional `replace_attachment_id`; when
present, the target must be a live attachment owned by the same holder and
session. The existing bounded, read-only `begin_attach` preflight remains, but
M5 replaces the state-changing dispatcher-then-Control calls with one
`:infinity` Control call. Its `handle_call` revalidates the request, retains the
caller's `from` value and a caller monitor, reserves the transaction and returns
`{:noreply, state}`. Control owns the resulting asynchronous state machine keyed
by attachment identity and continues to a defined disposition if that caller
dies, dropping only the reply route. **Control allocates that identity.**
Its state gains a per-generation attachment counter and moves the existing
`fresh_id/3` derivation for both `attachment_id` and `incarnation_id` out of
EventDispatcher's install step. During reservation Control increments the
counter, derives both IDs, and binds them to the session generation, dispatcher
incarnation, holder and optional replacement target. Discarded IDs are not
reused. EventDispatcher receives those supplied IDs, stages and later installs
exactly them, and never mints a second identity. Control first reserves that
pending row. It drives every later step by exact-incarnation messages and never
blocks its mailbox in a dispatcher call; dispatcher acknowledgements return
directly to Control, leaving `post_commit` serviceable. EventDispatcher stages
the new cursor barrier and queue under that identity without
publishing it and without removing the old target. Control validates its
generation/status again and marks the pending row authorized but not live.
EventDispatcher atomically publishes the staged row and, for replacement,
removes the named old row at its last emitted cursor and releases its transfers.
That acknowledgement is the transaction's **commit point** within that
dispatcher incarnation. After it, while that incarnation remains current,
Control can only roll forward to the terminal result selected by the holder
tombstone; it can never restore a replacement target the dispatcher already
removed. If Control consumes the acknowledgement while the holder is live, its
final idempotent transition makes the new row live for the holder gate and
removes the old routing row. A later `DOWN` takes the ordinary full-holder
cleanup path. If Control consumes `DOWN` first and later learns publication
committed, it marks the transaction `published/down`, never creates a live
routing row, and requests idempotent dispatcher removal of the new attachment
and release of its transfers. The dispatcher may already have removed it on
its own holder monitor; either answer is the same cleanup acknowledgement.
Only then does Control send `GenServer.reply/2` with
`{:error, :holder_unavailable}` to a caller that is still alive. The attach
result is replied only by Control and only after both owners acknowledge the same transaction identity
and, for the dead-holder terminal, agree that the new row is gone.

Snapshot preparation runs in a linked, monitored, non-trapping dispatcher
worker, at most one per pending transaction. Worker death refuses that
transaction; dispatcher death ends every such worker. The pending-attachment
charge bounds the group at 512 in daemon use, and embedded construction uses
the same core pending-row ceiling. The dispatcher loop therefore remains
available for acknowledgements and cleanup throughout a scan.

The pending-row reservation is also the exact linearization point against
`begin_quiesce/1`; the read-only `begin_attach` validation is not. If the
terminal gate is installed first, reservation refuses `runtime_unavailable`
and no dispatcher row, borrowed replacement charge or holder monitor exists.
If reservation wins first, that exact transaction and dispatcher incarnation
are grandfathered through only their stage, authorize, publish, finalize or
discard messages. The gate admits no new reservation. Before publication a
refusal discards; after publication the existing roll-forward rule still
applies. Quiesce neither awaits nor enumerates the transaction because it
changes no durable session truth. During ordinary service and connection
retirement the relay retains its ticket and reserved daemon slot until the real
result. During orderly shutdown the post-quiesce seal removes an unresolved
ticket after killing the caller task, while the transaction and charge remain
until holder cleanup or terminal runtime teardown; admission is already closed,
so the charge is never reused meanwhile.

Before the commit point, every refusal or holder death has an idempotent
discard path in both owners. Initiating-caller death drops only its reply route
and the state driver still reaches a terminal disposition. A Control refusal after dispatcher staging
discards only the new pending row and leaves the replacement target and its
transfers untouched. A holder `DOWN` removes live rows and selects discard for
unpublished transactions or released/no-live-route for published ones. After
the commit point, Control drives that idempotent terminal transition even if
the transient caller or relay task is gone. A dispatcher-generation cut is the
one exception: the replacement handshake first selects
`:attachment_superseded` for every half-finished transaction, replies to each
live retained caller, then clears both sides before the successor becomes
ready. An embedded caller therefore observes that stable core result. In the
daemon, the exact dispatcher `DOWN` independently selects fatal `runtime_lost`;
fail-stop clears the relay ticket and charge, so the transport may see that
fatal close instead of the core reply. A Control restart is daemon-fatal under the
sentinel rule, so teardown is the other case that interrupts that driver. It
never tries to restore a transfer already released and never reports success
before agreement.

Daemon capacity uses one explicit equation: `charged = live + nonreplacement_pending
+ replacement_pending - borrowed_replacement_targets`. Each valid replacement
pending row borrows exactly the named live target's one charge until commit or
discard, so replacement at 512 is net-zero; an ordinary pending attach consumes
a new charge. Pending rows are not live attachments, and the daemon cannot
undercharge or admit a 513th charge. The steady-state
invariant, whenever the registered dispatcher is ready, is exact equality of
the live attachment-ID sets. A published/dead cleanup may transiently leave one
side ahead only while its transaction identity and daemon charge remain
retained; the cleanup acknowledgement restores equality before either is
released. During dispatcher replacement both are cleared before ready, and
pending rows must return to zero.

Borrowing is exclusive by the exact live target identity
`{holder, attachment_id, attachment_incarnation}`. The connection first installs
its exact `pending_ticket(origin_id, :attach, nil)` at the relay. The connection
registry is the daemon's one serial reservation owner; it then installs
`borrow[target] = {request_binding, primary_ticket_id}` and synchronously asks
the relay to promote that exact primary. The call direction is always
registry-to-relay. The relay never synchronously calls the registry, because
the daemon owner also calls the relay for cut, freeze and seal.

An exact repetition of `request_binding` makes its distinct pending origin
`waiting(primary_ticket_id)` and starts no second task or core transaction. A
different request for an already borrowed target terminalizes its origin as the
inherited `attachment_conflict`, with no second borrow or task. Before primary
promotion, relay refusal, connection-incarnation loss or an admission cut
releases the exact borrow synchronously in the registry; after promotion, only
the real result converts or releases it, while shutdown abandonment retains it
through runtime teardown. Two pipelined
replacements therefore cannot each subtract the same live target from the
capacity equation. Core independently reserves and revalidates the same exact
target in Control so embedded callers receive the same exclusion without
depending on daemon state.

An absent, stale, foreign-holder or other-session replacement target refuses
`:stale_attachment` in core, mapped to generation 2's inherited
`attachment_conflict`, and changes nothing. With no selector, a distinct request
installs another attachment even when that holder already owns one for the
session. Exact repetition of the same attach identity returns the same live
handle rather than installing a duplicate. A distinct concurrent replacement
of a target already reserved by another pending transaction refuses
`attachment_conflict`; the first reservation and target remain unchanged.
Forced cases change Control's
generation/status between staging and validation for ordinary attach and for a
replacement at the ceiling, then assert no orphan, the old replacement remains,
both live maps agree, transfer disposition is exact, pending rows are empty and
the daemon count never exceeds 512. Ordinary, replacement, exact-repetition and
published/dead cleanup cases also assert the same attachment and incarnation IDs
in Control's pending/live rows, the dispatcher's staged/live row, the returned or
replayed handle and the cleanup acknowledgement; any second minted ID fails the
case.

Shutdown cases force the gate immediately before reservation and, with
reservation first, pause before dispatcher stage, before Control authorization,
and after publication before finalization. At the last cut, ordinary and
replacement attaches force both Control mailbox orders: publish acknowledgement
then `DOWN`, and `DOWN` then publish acknowledgement. The first may finalize a
handle before ordinary holder cleanup; the second returns
`:holder_unavailable` only after idempotent dispatcher cleanup. For replacement,
neither order restores the already-removed target or its transfers. Every case
ends with an exact result or cleanup acknowledgement, zero pending rows, equal
live maps, the correct transfer disposition and no retained charge or attachment
count above 512; none delays the durable drain.

ADR 0023's boolean remains the wire field on both protocol adapters. Each
adapter permits only one connection attachment, so on `replace: true` it maps
the sole handle it already holds to core's `replace_attachment_id`; on
`replace: false` it keeps ADR 0023's second-attach refusal. Embedded callers
use the core selector directly and are the case for which several candidates
can exist.

**Holder cleanup, request retirement and connection-slot release are one
acknowledged sequence.** The connection registry owns accepted slots and the
daemon's activation and attachment reservations. Before a connection can send
any admitted request, it
synchronously registers its pid and fresh connection incarnation with the
admission relay, which installs its own monitor. Every one of the connection's
at most 32 active request slots has one relay origin row keyed by
`origin_id = {connection_incarnation, request_slot, request_sequence}` and
carrying the operation class. The monotonically increasing sequence prevents a
late result from a prior use of the same local slot from touching its successor.
A lightweight call uses its permit row. A ticketed call first installs
`pending_ticket`; create, an activation-capable resume and attach then pass that
exact origin through the registry's reservation handshake, while another
lease-authorized mutation sends its descriptor to the lease owner only after
the pending row is acknowledged. Only the owner named for that path may promote
the exact row to `ticketed(task_pid, monitor)`, with task start ordered before
acknowledgement.

When the connection ends, the registry changes its accepted slot from `live`
to `closing`; it does not release the slot merely because its monitor fired.
The relay terminalizes every unpromoted origin row for that incarnation and
retains every promoted ticket until its real result, fatal disposition or
successful shutdown seal. Promotion after terminalization refuses and starts
no task.

The registry must remain responsive while core cleanup runs. In the same
callback that changes `live` to `closing`, it destroys the socket/output buffer
and starts one unlinked monitored cleanup worker identified by
`{connection_incarnation, cleanup_ref}`. That worker alone calls the internal,
idempotent `Runtime.release_holder/2`, which returns only after EventDispatcher
and Control contain no attachment for the holder; cleanup already caused by
their monitors is success. The operation is internal cleanup admitted even
after core's quiescing gate, because orderly step 3 closes holders only after
quiesce. Its exact success acknowledgement sets `holder_cleanup_acked`; a stale
ack is a no-op. Only the exact normal `DOWN` after that acknowledgement sets
`cleanup_worker_reaped`. Abnormal worker exit, timeout or loss at either stage
leaves the slot charged and selects fatal `runtime_lost`. The registry never
reuses that incarnation.

The accepted slot becomes free only under the conjunction
`closing && relay_retired && holder_cleanup_acked && cleanup_worker_reaped`,
where `relay_retired` means there is no nonterminal origin, waiter, permit,
request worker or relay task for the incarnation. Up to 512 cleanup workers may run concurrently, one per
closing slot; orderly step 3 awaits their exact acknowledgements and `DOWN`s
within its shared deadline, kills and reaps survivors at the deadline, and
takes the fatal path rather than reporting a successful stop. This ordering
prevents a late ticket or attachment after slot reuse and makes both the
connection and attachment ceilings true at every instant without serializing
accept, status or an unrelated connection behind core cleanup.

The same path handles an orderly daemon close and an abrupt peer loss. For an
embedded caller no daemon counter exists; the two core monitors still remove
the whole holder set. The runtime-local pids and monitor references cross no
durable, public or executor boundary.

**Transfer cleanup remains mandatory.** `release_transfers/2` is currently
called only by unconditional same-session supersession. M5 moves that call to
each named-replacement removal and to every holder-set removal. The witness
opens transfers from two same-holder attachments, replaces one by ID and then
kills the holder: replacement releases only the target's transfers; holder
loss releases the survivor's; a different holder's attachments continue.

A general public `detach/1` remains rejected. It would require every caller to
remember cleanup precisely when the caller may already be dead. The two
internal operations above have narrower purposes: `attach_for_holder/4`
separates the relay task from the lifetime owner, and `release_holder/2` lets
the daemon retain resource reservations until the automatic monitor cleanup is
confirmed. Neither gives a client authority to detach another holder.

The core EventDispatcher and Control therefore retain multiple live attachment
IDs and incarnations for one session and multiple IDs for one holder. A new
distinct attachment does not implicitly detach another or cancel its pending
read. Snapshot barriers, queued durable delivery, stale-handle checks and
holder cleanup remain core operations. The daemon neither copies the snapshot
into a second fan-out owner nor reads coordinator state to repair an
attachment race.

### Queue ownership

Two bounded stages exist per attachment, with distinct owners. The core
dispatcher owns the per-attachment event-count queue that already exists,
configured by the daemon at 1,024 events through the runtime's
`attachment_capacity`; it never holds encoded bytes. The daemon owns a
per-connection socket output buffer of encoded frames not yet written to the
socket, bounded at 4 MiB, and the per-session resident window of encoded
recent events, bounded at 4,096 events and 16 MiB, and it enforces the
512 MiB aggregate across every output buffer and resident window it holds.
Neither daemon stage owns replay: core owns the cursor and decides what is
owed, and both daemon stages hold only bytes for events core has already
named.
When the next event would exceed the core count or a daemon byte bound, the
daemon detaches the attachment at its last completely emitted cursor with a
stable reason rather than letting either stage grow — which, under the
daemon-initiated detach rule above, means one best-effort `detached` record
and then the close of that connection. No byte limit is
enforced inside core.

### Generation 2 additions

Every table below is the wire contract at the exactness a literal vector
needs: the keys a request carries, the keys a result carries, which are
optional, and what type each is in ADR 0023's vocabulary — `binary identity`,
`u64` (a canonical unsigned decimal **string**), `bool`, `plain_object`. The
envelope is ADR 0023's unchanged: a request is a flat object with exactly
`method`, `request_id` and its row's fields, an optional field is **absent**
rather than `null`, and unknown fields refuse before a facade call
(`0023-…-technical.md:131-136`).

**`session.list`**

| Direction | Key | Type | Optionality |
| --- | --- | --- | --- |
| request | `limit` | integer 1 to 256 | required |
| request | `after_session_id` | binary identity | optional |
| result | `entries` | array of entry objects, at most `limit` | required |
| entry | `session_id` | binary identity | required |
| entry | `placement_identity` | binary identity | required |
| entry | `residency` | `"active"` \| `"dormant"` | required |
| entry | `controlled` | bool | required |
| result | `next_after_session_id` | binary identity | present **exactly when** more entries exist |
| result | `index_full` | bool `true` | present **exactly when** the index is at its 4,096-entry ceiling; the row-size derivation below guarantees that row ceiling fits inside 4 MiB |

Entries are ordered by session ID bytes ascending, and carry nothing else —
no content, no durable session state.

**`daemon.status`**

| Direction | Key | Type | Optionality |
| --- | --- | --- | --- |
| request | — | — | takes no fields |
| result | `placement_identity` | binary identity | required |
| result | `daemon_incarnation` | binary identity | required |
| result | `socket_path` | string | required |
| result | `connections` | integer, occupied accepted slots: provisional (including aborting) + live + closing | required |
| result | `connection_limit` | integer, 512 | required |
| result | `attachments` | integer | required |
| result | `attachment_limit` | integer, 512 | required |
| result | `active_sessions` | integer | required |
| result | `activation_limit` | integer, 64 | required |
| result | `activations_used` | integer, activations spent in this daemon lifetime **plus reservations in flight** — see below | required |
| result | `index_entries` | integer | required |
| result | `index_limit` | integer, 4,096 | required |
| result | `index_full` | bool | required |
| result | `uptime_ms` | `u64` | required |

**What the counts mean while a reservation is in flight**, which an earlier
revision left to the implementation and which two clients calling
`daemon.status` during a burst of creates would otherwise disagree about.
The rule is that **a reservation counts**:

- `activations_used` is `|activation set| + |reservations|` — the same
  quantity the ceiling invariant bounds, so `activations_used` and
  `activation_limit` are directly comparable and a client can never read
  `activations_used < activation_limit` on a daemon that would refuse its next
  create;
- `active_sessions` is `|activation set|` alone — **the sessions this daemon
  has activated in this lifetime**, which is what the set holds and what
  `residency: active` means. It is *not* "sessions with a live coordinator":
  activation is one-way and the daemon has no way to know a coordinator died,
  which this pair says twice elsewhere. It differs from `activations_used`
  only by the reservations in flight;
- `attachments` counts installed attachments plus reserved and
  cleanup-pending attachment slots, for the same reason `activations_used`
  does; a connection `DOWN` does not lower it before core confirms holder
  cleanup;
- `connections` counts occupied accepted slots: `provisional` (including its
  aborting substate), `live` and `closing`;
  socket death alone does not advertise headroom while an origin row or holder
  cleanup remains.

So `activations_used` may exceed `active_sessions` for as long as a call is in
flight, and settles to it. Reporting the set alone would advertise headroom
the very next call would refuse.

**Every ceiling consumed by a ticketed core call uses one reservation-to-relay
handshake.** The connection preallocates
`origin_id = {connection_incarnation, request_slot, request_sequence}` and first
installs `pending_ticket(origin_id, class, nil)` at the relay. The connection
registry then makes the serial capacity decision and binds any reservation or
borrow to that exact origin before it synchronously asks the relay for one of
two transitions. Create and attach still have `pending_ticket`; a resume has
already bound its request worker and is `queued`:

- `pending_ticket | queued -> ticketed(primary_ticket_id, task_pid, monitor)`
  starts and monitors the one primary task before acknowledging promotion; or
- `pending_ticket | queued -> waiting(primary_ticket_id)` starts no task and
  retires and reaps any queued request worker before acknowledging the waiter.

For activation, the registry retains
`activation_binding = {kind, request_binding, primary_ticket_id, reservation}`.
A create's request binding is its `command_id` plus the canonical digest of all
creation inputs, including `session_options`; a dormant resume's is its
`{session_id, command_id}`. Exact repetition joins the existing primary, while
reuse of a create command ID with different inputs is a command conflict and a
different resume command is a different request. A resume for a session already
in the activation set needs no reservation. At the activation ceiling, a
dormant resume is refused before promotion and before core; a create instead
promotes one history-only primary that may return a historical session ID, but
an `absent` result becomes `activation_ceiling_reached` without invoking the
activation-capable create call.

For attachment, an ordinary primary reserves one charge. A replacing primary
takes an atomic net-zero borrow of its exact
`{holder, attachment_id, attachment_incarnation}`. The registry retains
`borrow[target] = {request_binding, primary_ticket_id}`, so exact repetition
joins that primary and a different request for the target receives
`attachment_conflict` before any second borrow, task or core transaction. A
stale, foreign-holder or other-session core selector refuses and releases the
claim; an ordinary attach with no selector is refused when it cannot reserve a
new charge.

Registry serialization keeps a duplicate from overtaking an unpromoted
primary. If the relay refuses promotion because the origin or connection was
terminalized, or because the admission cut won, the registry synchronously
releases that exact reservation or borrow and installs no waiter. Once
promotion succeeds, primary connection loss drops only its reply route: the
task, reservation and closing slot remain through the real result. Each
coalesced caller owns its distinct origin and route; its connection loss
terminalizes only that waiter. A primary result moves the relay row to
`settling(result, reservation_ref)` and is sent asynchronously to the registry;
after the registry idempotently converts or releases the exact charge, its ack
lets the relay answer and terminalize the primary and all live waiters. This
asynchronous result leg avoids a relay-to-registry synchronous call opposite
the reservation call direction. A shutdown seal that must abandon a promoted
primary terminalizes the primary and its waiter origins but retains the charge
until runtime teardown, so admission never reuses an outcome it could not
classify.

Thus every active origin is one of `pending_ticket`, `queued`, `ticketed`,
`waiting`, `settling` or a lightweight-permit state. The exact bounds are
`occupied_slots = provisional_including_aborting + live + closing <= 512`,
`active_origins <= occupied_slots * 32 <= 16_384`, and
`relay_tasks <= promoted_primary_origins <= active_origins`; waiters consume
origins but start no task. A dead accepted slot remains `closing` until its last
origin and holder cleanup are terminal, so reconnect churn cannot evade either
equation.

**`session.acquire_control`**

| Direction | Key | Type | Optionality |
| --- | --- | --- | --- |
| request | `session_id` | binary identity | required |
| result | `writer_epoch` | binary identity, ≤ 64 bytes | required |
| result | `expires_in_ms` | `u64`, the remaining term on the daemon's clock | required |
| result | `renewed` | bool | present **exactly when** the caller was already the holder of a held, unexpired lease |

A holder's own `session.acquire_control` is a **renewal**, not a refusal: the
deadline moves, the epoch stays, `writer_epoch` is the same value it held and
`renewed` is `true`. ADR 0033 owns the branch; the field is here so a client
can tell a renewal from a fresh grant without comparing epochs it treats as
opaque.

**`session.release_control`**

| Direction | Key | Type | Optionality |
| --- | --- | --- | --- |
| request | `session_id` | binary identity | required |
| request | `writer_epoch` | binary identity | required |
| result | `released` | bool `true` | required |

**Notification records — there are two**, and the Concept says two as well:

| Family | Key | Type | Optionality |
| --- | --- | --- | --- |
| `daemon.stopping` | `reason` | one of the closed set below | required |
| | `message` | bounded non-secret string | required |
| `daemon.notice` | `code` | closed set, today `"index_write_failed"` | required |
| | `session_id` | binary identity | required |
| | `message` | bounded non-secret string | required |

Neither is correlated and neither carries a cursor.

**The new error codes, with their shape.** All of these are **correlated**
errors answering one request: each carries that request's `request_id`, no
`event_cursor`, no session state, and closes nothing.

| Code | Answers | Carries beyond the envelope |
| --- | --- | --- |
| `control_held` | `session.acquire_control` | **Nothing.** It does *not* carry the current epoch: an epoch is authority-shaped, and handing one to a client that was just refused is exactly the value it must not have. An earlier revision of ADR 0033 said it named the current epoch; that is withdrawn |
| `control_not_held` | `session.release_control` from a non-holder, **and every lease-authorized existing-session mutation whose combined admission gate fails**, except the verified dormant-session `session.resume` ADR 0033 expressly allows before attachment — any of the **five** conditions ADR 0033 lists: wrong connection, wrong epoch, a lease that is not `held`, a deadline already passed, or no live attachment for the pinned session. A request missing `writer_epoch` altogether is `invalid_request` instead, being malformed before the gate | **Nothing**, deliberately: the five conditions are indistinguishable on the wire, because saying which one failed would make the refusal an epoch and lease oracle. ADR 0033 fixes the gate; this is the one answer it has |
| `control_pending` | `session.acquire_control` that waited out its deadline | nothing |
| `control_capacity_reached` | an acquisition for an unrelated session that would reserve a 513th lease-owner slot; a same-session successor takes the freed process slot only after the daemon owner consumes the predecessor's exact linked `EXIT`, starts only after exact mirror pop, owner-loss classification acknowledgement and terminal holder-close or correlated-refusal settlement, and grants only after the relay's monitored `DOWN`, retirement completion and prior tickets, while renew and release use an existing owner and remain available at the cap | nothing |
| `control_owner_lost` | an acquire or release whose `owner_lost` CAS wins, or a pending/queued lease-authorized mutation claimed before promotion because its exact lease owner or fresh acquisition child is lost | nothing; this correlated form carries only its request envelope and keeps a non-holder connection open. An origin on the returned granted holder receives the mutually exclusive uncorrelated form below and closes instead; a promoted mutation remains relay-owned to its real core result |
| `session_dormant` | `session.attach` | nothing |
| `session_unavailable` | `session.inspect` after an attach to a session whose one-way daemon activation remains recorded but whose temporary core coordinator has died | nothing; generation 2 maps only core's exact `:session_unavailable` reason to this code and never parses `message`. Other inspection failures keep their existing mapping or select the daemon's runtime-fatal path |
| `daemon_stopping` | any post-initialize method arriving after the daemon's admission cut; an uninitialized peer has negotiated no encoding and receives EOF instead | nothing |
| `session_unknown`, `session_id_invalid`, `store_unavailable` | any method that validates existence first | nothing |
| `activation_ceiling_reached` | a fresh `session.create` or dormant `session.resume`; an exact historical create replay remains available through the read-only discriminator | nothing |
| `composition_mismatch` | `session.resume` on a session this composition cannot serve | nothing |

The same `control_owner_lost` code also has one **uncorrelated** granted-holder
form, defined below with its cursor and close behaviour. Its two exact shapes
are distinguished by `request_id` versus `session_id`; neither shape admits
the other's discriminator.

**The limits input is not unchanged**, which an earlier revision's digest
table said while this pair advertised limits a client can read. The following
seven keys are the complete generation-2 additions to initialize `limits` and
are enumerated so the digest covers them:

| Limit key | Value |
| --- | --- |
| `connections_per_daemon` | 512 |
| `initialize_deadline_ms` | 30,000 |
| `attachments_per_session` | 64 |
| `attachments_per_daemon` | 512 |
| `session_list_page_max` | 256 |
| `session_index_entries` | 4,096 |
| `lease_term_ms` | 30,000 |

ADR 0023's own framing and input ceilings are unchanged; these are additions
beside them, and **all five** digest inputs therefore change in generation 2.
The event queues, encoded-byte buffers and windows, aggregate retention, idle
interval and per-lifetime activation ceiling remain server-enforced; where a
client needs them they appear through the exact `daemon.status` projection,
not as undeclared initialize keys.

**A connection reserves its one session before asynchronous work begins.**
Its state is `unbound`, `reserving(session_id, request_id, request_digest)` or
`bound(session_id)`. The first well-formed `session.attach` or
`session.acquire_control` changes `unbound` to `reserving` atomically in the
connection process **before** it asks the relay, existence query or core to do
anything. An exact retransmission with the same request ID and canonical
digest coalesces on that result. Any different request while reservation is in
flight, and every later request naming another session after binding, refuses
with ADR 0023's existing `invalid_request` before any gate or side effect.

Success converts the reservation to `bound`. A definite refusal that created
neither attachment nor lease clears it back to `unbound`; in ordinary service an
admitted relay ticket keeps it reserved until the real result arrives, and an
unaccounted task makes the relay fatal rather than guessing. During orderly
shutdown the successful post-quiesce seal may remove an unresolved ticket, but
the connection reservation remains until holder or runtime cleanup and cannot
admit another request after the cut. This closes the pipeline race
in which attach for one session and acquire for another could both pass while
the connection still appeared unpinned. Without the rule a connection could
hold a lease on one session and an attachment on another, and
the uncorrelated `control_owner_lost` form — whose close ends *the connection* — would take down an
attachment belonging to a session that had nothing to do with the lost owner.

**The uncorrelated `control_owner_lost` form therefore carries `event_cursor`
exactly when there was an attachment to carry one for.** It is an ADR 0023 `error` record with
required `code`, bounded non-secret `message` and `session_id`. A connection
that acquired and never attached has no emitted cursor, and inventing one
would be a lie about what it received; `event_cursor` is **absent** in that
case and present otherwise. Both shapes are generation-2 vectors — one with
the cursor, one without — because a client parser must accept both.

**Accepted connection incarnations are bounded, and an earlier revision said they were bounded by
the attachment ceiling, which they are not.** A client may connect,
`initialize`, call `session.list`, `daemon.status` or
`session.acquire_control`, or sit idle, without ever attaching — so the
attachment ceilings bound nothing about the number of sockets the daemon
holds, and a daemon whose bound is "the attachment ceiling" has no bound on
connections at all. The ceiling is **512 occupied accepted connection slots**,
where occupied means `provisional` (including a handoff being aborted and
reaped), `live` or `closing`,
the attachment number reused rather than a fourth 512 invented, and the
daemon reports it as `connection_limit` with the occupied count as
`connections`, so an operator can see usable headroom before it is gone.

**The slot is taken at `accept`, not at `initialize`.** A ceiling enforced
only at the handshake bounds nothing that matters: a peer that connects and
never speaks holds a socket, a process and a buffer, and the daemon would
count it as zero. So the listener **reserves a connection slot as it accepts**
and closes the socket immediately when none is free — before any frame is
read, before the peer check, with no record, because a connection that was
never admitted has no generation to be told anything in. A process `DOWN`
closes the socket but changes the slot to `closing` while any relay origin row,
request worker, ticket task or core holder cleanup remains. The cleanup worker
runs outside the registry callback; a connection with no retained relay work
still frees only after that worker's exact acknowledgement and `DOWN`.

**There is no `initialize`-time refusal for the connection ceiling, and an
earlier revision of this section kept one beside the accept-time slot.** The
two cannot both hold: a slot taken at `accept` means the 513th socket never
reaches `initialize` to be answered anything, and a ceiling answered at
`initialize` is the ceiling on nothing that the paragraph above rejects. The
accept-time slot is the rule. What is lost with the refusal is stated rather
than glossed: a peer beyond the ceiling is closed **without being told why**,
and cannot tell a full daemon from one that is wedged or gone. That is the
price of bounding sockets rather than handshakes, and `daemon.status` is where
an operator sees the headroom instead. The peer-credential and filesystem
checks are unaffected, running on connections that did get a slot; a foreign
peer is closed before any of this.

Its witness is the boundary pair that matches the rule: the **512th occupied**
connection is accepted, initializes and is served; the **513th socket is
accepted and closed with no frame read and no record written**, asserted from
the client side as an immediate EOF rather than as an error record; and
closing a connection with no retained relay work lets the next one through only
after its cleanup worker acknowledges and exits, while a connection with a held
ticket remains `closing` and keeps the next peer out until that row, every
request worker and holder cleanup are terminal. A witness asserting a
`capacity_exceeded` at `initialize` would be asserting a path this decision
does not have.

**An accepted connection that never initializes is closed on a deadline**, and
without one the ceiling would be a ceiling on nothing: a peer that connects
and then says nothing occupies a slot for as long as it likes, and 512 of
them would refuse every real client while the daemon held 512 silent sockets.
Nothing else releases such a connection — there is no attachment to evict, no
lease to expire, and ADR 0023's connection-state rules govern what a
connection may *do* before `initialize`, not how long it may take. So an
accepted connection that has not completed `initialize` within the **lease
term, 30 seconds measured from kernel accept**, is closed, under its **own** advertised limit key,
`initialize_deadline_ms`. It is a separate key carrying the same value as
`lease_term_ms`, and the separation is the point: one key meaning two
contracts would let a later change to the lease term silently move the
handshake deadline, or the reverse, and a client reading `lease_term_ms` to
decide when to renew would be reading a number that also governs something it
has nothing to do with. **The value is derived rather than chosen**: thirty
seconds because that is the one connection-lifetime bound this milestone
already fixes, so the daemon introduces no number — and if the two ever need
to differ, they can, which is what having two keys buys. An `initialize`
handshake is one frame each way on a local socket, so thirty seconds is a
ceiling no honest client approaches. Adding the key changes generation 2's
limits input and therefore its digest, which is stated here so the pinned
literal is computed over it. The close carries no record — the connection has
negotiated nothing, so there is no generation whose error shape it could be
sent in — exactly as the peer-credential refusal closes before initialize.

The listener records one monotonic `accepted_at` as soon as `accept` returns
and the provisional registry row stores the absolute
`initialize_deadline = accepted_at + initialize_deadline_ms`. That exact value
is passed unchanged into the connection process and retained when the registry
promotes the row. The registry owns the timer and the final initialize-complete
CAS; the listener, registry and connection each recheck `now < deadline` before
every handoff, promotion or initialize continuation. The timer only prompts a
check. At or after the instant, a provisional row enters exact abort/reap and a
promoted uninitialized row enters closing with EOF. An initialize result queued
before the instant but consumed by the registry at or after it loses and cannot
reset or extend the deadline. Only an exact initialize completion consumed
before the instant marks the row initialized and cancels and flushes the timer.

Its witness is the pair that must differ: a connection accepted and left
silent is asserted **closed** after the term and the slot it held asserted
free, while one whose exact completion is consumed inside it is asserted to
stay open indefinitely with no such close. Boundary cases expire after child
start while the listener still owns the socket; race expiry against
controlling-process transfer and force both its failure/listener-owned and
success/connection-owned results; hold registry promotion across the instant;
and queue initialize completion before the instant but let the registry consume
it afterwards. Every expiry closes with EOF, reaps the exact socket owner, child
and provisional or live row, and frees one slot, while the transfer race takes
exactly one ownership branch. The paired just-before cases advance once. The timer is delivered on
both sides of the completion in each case to prove it only prompts the clock
check. It is a long-duration bound, so it is tagged `long_bound`; the same
cases inject the clock at the accept-time arming point, with the production
default asserted once.

The tables above are the contract for both directions; an earlier revision
kept a second, prose summary of the same four methods beside them, which is
exactly how two descriptions of one wire drift apart. It is gone, and the
per-method tables are the only statement of what a request and a result
carry.

**The `daemon.stopping` record, field by field:**

| Field | Value |
| --- | --- |
| `reason` | One of `operator_stop`, `store_lost`, `store_capacity_exceeded`, or `fatal:<class>` for a live-registry fatal class. The set includes `fatal:listener_lost`: every live socket has already transferred from the listener to its connection process, so listener loss stops new accepts but leaves the connection registry and existing sockets available for the bounded write and close. The set excludes `fatal:connections_lost`: once that registry is gone there is no live inventory or buffer-control interface through which to write. On every fatal class the owner directly kills the listener and relay without awaiting them, sends at most one unacknowledged ordinary message asking a still-live registry to attempt its bounded writes and closes, first sends the lifecycle sentinel the exact class, unique integer status and latch instant; the sentinel starts an unawaited diagnostic helper and owns `latched_at + 35_000`, while the owner waits for the executor only until `latched_at + 5_000` and for the Store only until the earlier of its own 30-second deadline and the global instant. A suspended registry or blocked stderr cannot extend that wall-clock bound, and existing sockets close with the VM. The ordinary component reasons remain `fatal:runtime_lost`, `fatal:transfers_lost`, `fatal:workspace_lease_lost`, `fatal:executor_lost`, `fatal:registry_lost`, `fatal:custody_lost`, `fatal:capability_lost`, `fatal:relay_lost`, and `fatal:drain_failed`. A lease owner's death is session-scoped and uses `control_owner_lost`. Startup classes have no socket, and `owner_lost` has no owner to write a record |
| `message` | A bounded non-secret sentence for an operator to read |

There is no `retry_after_ms`. Even on `operator_stop` the daemon does not know
when an external service manager or operator will start a successor, so any
numeric retry promise would be invented.

**Its delivery is bounded best-effort, and the bound is one the daemon already
has.** The daemon makes exactly **one** write attempt of the record into the
connection's existing 4 MiB output buffer and then closes the connection
regardless of what happened. If the buffer cannot accept it — a backpressured
client that has not been reading — the record is dropped and the connection is
closed anyway. A dead client receives nothing at all. **So a client may learn
of a shutdown only by its socket closing**, and this pair says so rather than
implying the record always arrives; a client that treats an unexplained close
as a defect would be wrong.

The bound is the buffer's, not a new timer: a millisecond deadline would be a
number this milestone introduces, and the minimalism budget requires every
number to come from an accepted or proposed decision. One non-blocking attempt
into a bound that already exists is the same guarantee with nothing new to
justify.

**The two generations have two exact contract values.**
`LoopexProtocol.Session` remains the generation-1 compatibility facade used by
the foreground server and keeps its existing zero-arity `generation/0`,
`methods/0`, `record_families/0`, `error_codes/0`, `limits/0`,
`schema_digest/0` and generation-1-only `negotiate/2` API. M5 adds
`LoopexProtocol.Session.V2` with that same metadata and negotiation API for
generation 2; only the daemon aliases and calls it. Neither zero-arity module
can report the other generation, and the foreground server does not gain a
generation-2 route. A private canonical digest helper may remove duplicated
calculation, but the two explicit modules own their different inventories.

**This changes the generation-2 digest, and so do the error codes.**
`LoopexProtocol.Session.V2.schema_digest/0` is taken over the generation, the
ordered methods, the ordered record families, the ordered error codes and the
limits — five inputs, and generation 2 changes **all five**:

| Digest input | Generation 2 |
| --- | --- |
| Generation | New string |
| Methods | Adds `session.list`, `daemon.status`, `session.acquire_control`, `session.release_control` |
| Record families | Adds `daemon.stopping` and `daemon.notice` |
| **Error codes** | Adds every refusal generation 2 can return and generation 1 cannot: `control_held`, `control_not_held`, `control_pending`, `control_capacity_reached`, `control_owner_lost`, `session_dormant`, `session_unavailable`, `daemon_stopping`, the three existence-query refusals the daemon maps to the wire (`session_unknown`, `session_id_invalid`, `store_unavailable`), and the activation and residency refusals (`activation_ceiling_reached`, `composition_mismatch`). **Not** `session_index_too_large`, `session_index_corrupt` or `session_index_upgrade_required`, which are startup exit classes and can reach no client, and **not** `capacity_exceeded`, which generation 1 already carries and generation 2 keeps for the two **attachment** ceilings — `attachments_per_session` and `attachments_per_daemon`, the "stable reason when exhausted" the attachment-lifecycle list names — and no longer for the connection ceiling, which is enforced at `accept` and therefore reaches no `initialize` |
| **Limits** | ADR 0023's framing and input ceilings are unchanged, and generation 2 **adds** the residency keys a client can read: `connections_per_daemon`, `initialize_deadline_ms`, `attachments_per_session`, `attachments_per_daemon`, `session_list_page_max`, `session_index_entries`, `lease_term_ms` |

**The uncorrelated `control_owner_lost` form closes a controller whose lease
owner died.** ADR 0033
makes a lease owner's failure session-scoped: the daemon closes that session's
controller connection, leaves its observers attached on their own, and lets the next
acquisition start a fresh owner with a fresh epoch. The closing client is owed
a reason for a close it did not ask for, and this is it — distinct from
`control_held`, which refuses an acquisition, and from `control_pending`,
which times one out. It enters the ordered error list, the digest and the
generation-2 vectors with the others.

**`control_pending` is the acquisition timeout, and it was missing.** ADR 0033
refuses an acquisition whose own deadline elapses while it waits behind an
unresolved admission, with a stable reason — and the inventory above claimed
to be complete while having no code for it. `control_pending` is that code: it
says the lease is not held by anyone the client must wait for indefinitely,
only that this acquisition did not get it in time, which is a different fact
from `control_held` and deserves a different refusal. It enters the ordered
error list, the digest above, and the generation-2 vectors alongside the
others.

`control_capacity_reached` is the refusal for a lease operation that would
exceed the concurrent lease-owner cap — 512, the per-daemon ceiling this ADR
already fixes, reused rather than doubled by a second number. The plan's
companion states where that cap comes from and why the population it bounds is
not the activation count.

Listing the error codes matters because it is the input most easily forgotten:
a refusal reason invented at implementation time and not entered in the
ordered list would make the served contract differ from the digest the server
advertises, which is exactly the drift the digest exists to catch. The
generation-2 literal the conformance module pins is the digest of the contract
*including* all five changed inputs, and a build missing any of them computes
a different value and fails there. Generation 1 gains no method, no record family and no error code — but its
digest is **not** untouched, because M5 renames its generation string from
`loopex.session.v1-experimental` to `loopex.experimental/1` and the generation
is the digest's first input. That rename is the plan's decision, taken under
the vision's 0.x experimental policy; this ADR records its consequence here,
which is that generation 1's **schema digest** — and only that — is
recomputed and re-pinned alongside generation 2's, with every other input to
it byte-identical. Its two published manifests are not touched: they already
declare `loopex.experimental/1`, so the rename makes the code agree with them
rather than changing them. The
generations the two servers advertise are therefore `loopex.experimental/1`
from the foreground server and `loopex.experimental/2` from the daemon —
**neither advertises both**, each serving exactly one generation, which is what
the exact-generation rule means here — and neither carries the old name.


### Generation 2, at the precision literal vectors need

Every code and record below has to be written as bytes before the conformance
module can pin a digest, so each is fixed here rather than left to the
implementation. Seven were underspecified in an earlier revision, and this is
the whole of what was missing.

**`control_not_held`, the one answer the admission gate has.** It refuses
`session.release_control` from a connection that is not the current holder or
whose `writer_epoch` does not match, **and** every lease-authorized
existing-session mutation that fails ADR 0033's combined check on holder
connection, epoch, `held` state, unexpired deadline or a live attachment for
the pinned session. One code for all of them, carrying nothing beyond the envelope:
the refusals a client can provoke must not tell it whether a lease exists,
whether its epoch was right or whether it was merely late, because that is an
oracle for the value the gate protects. It is distinct from `control_held`,
which refuses an *acquisition* because
somebody else holds the lease, and from `control_owner_lost` below. The
refusal changes nothing: the current holder's lease, epoch and deadline are
untouched, which is the point — a release that could be issued by a non-holder
would be a way to take control away without taking it over.

**`control_pending` and the deadline behind it.** A request carries exactly
`method`, `request_id` and its row's fields (ADR 0023's request shape,
`0023-…-technical.md:131-133`), so there is **no deadline field on the wire**
and none is added. The deadline is the **daemon's**, it starts when the
acquisition request is admitted — not when the client sent it, which the
daemon cannot know — and it equals the **lease term**, 30 seconds, so no
number enters that ADR 0033 has not already fixed. A waiter that reaches it
refuses `control_pending` and the client may acquire again.

**`session_unavailable`, exactly.** The literal generation-2 vector is an
ordinary correlated `error` record with `code: session_unavailable`, the
request's `request_id` and one bounded non-secret `message`. It has no
`session_id`, `event_cursor` or session state and leaves the connection open.
The daemon emits it only when `session.inspect` returns core's exact
`:session_unavailable`; it never derives the code by parsing `message`.

**A waiter whose connection disappears before the permit's result CAS is
cancelled.** Connection `DOWN` wins `connection_lost`; for a fresh acquire the
daemon owner then exact-clears any provisional routing mirror and kills and
reaps the child named by `start_op_ref`, so no epoch or grant becomes visible.
If the daemon owner's `result` CAS wins first, the lease is already granted and
the later EOF follows the ordinary rule: it does not shorten that lease even
when the reply was lost. This cut is what distinguishes cancellation from a
grant to a connection that disappeared after the grant linearized.

**`control_owner_lost`, exactly, has two mutually exclusive forms.** It reuses
the `error` record family ADR 0023 already defines rather than adding one.

The **correlated in-flight lease-operation refusal** carries required `type: error`,
`code: control_owner_lost`, the request envelope's `request_id` and a bounded
non-secret `message`. It carries no `session_id`, `event_cursor` or session
state. It answers exactly one acquire or release whose `owner_lost` CAS won, or
one pending/queued lease-authorized mutation claimed before promotion, when
that origin is not the holder returned by the exact mirror pop, and it leaves
that connection open. A promoted mutation is outside this form and stays
relay-owned to its real core result.
An origin on the returned holder suppresses this form and receives only the
uncorrelated form below.

The **uncorrelated granted-holder loss** carries no `request_id` and has:

| Field | Value |
| --- | --- |
| `type` | `error` |
| `code` | `control_owner_lost` |
| `message` | bounded non-secret explanation |
| `session_id` | the session whose lease owner died |
| `event_cursor` | optional; present exactly when this connection held an attachment, carrying that attachment's last completely emitted durable cursor exactly as `detached` does |

It is uncorrelated because no request caused it. A record containing both
`request_id` and `session_id`, or neither, is invalid. **Close behaviour:** it is one
instance of the daemon-initiated detach rule below — the daemon writes the
record best-effort into that connection's output buffer and then **closes that
connection**. Every other connection is untouched, so every observer keeps its
attachment and keeps receiving, which is what "the observers stay" means: an
observer is on a connection of its own, because generation 2 binds a
connection to at most one attachment. A client that sees it may reconnect and
acquire again; the next acquisition starts a fresh owner and mints a fresh
epoch.

**Every daemon-initiated detach is a record and a close, and the rule is one
rule.** A connection holds at most one attachment, so a daemon that "detaches"
a connection has left it holding nothing — no cursor position it can act on,
no way to be told what it may resume from except the record it is being sent,
and no mechanism to re-establish an attachment except a fresh `session.attach`
it could equally send on a fresh connection. An earlier revision left such a
connection open and declined a detach API in the same breath, which left the
client in a state neither side had defined. So:

| Occasion | Record written first | Then |
| --- | --- | --- |
| The controller's lease owner died | `error`, `control_owner_lost`, with required `message` and `session_id`, plus `event_cursor` exactly when the connection held an attachment | close that connection |
| Output-buffer or core-queue overflow | `error`, ADR 0023's `detached`, with `session_id` and `event_cursor` | close that connection |
| Aggregate byte pressure chose this attachment | the same `detached` | close that connection |
| Idle observer eviction at ten minutes; a connection holding a controller lease is exempt until release or expiry | the same `detached` | close that connection |

Reusing `detached` for the three eviction rows is a **widening inside
generation 2**, stated rather than slipped in: ADR 0023 defines that code for
post-admission writer loss, and its own pressure rule already says to detach
at the last completely emitted cursor and say so
(`0023-…-technical.md:362`). Generation 2 extends the occasions, not the
record — same code, same fields, same uncorrelated shape — and generation 1's
use of it is untouched, so the foreground server's behaviour does not move and
the ordered error list gains nothing for it.

**Where `event_cursor` is present, it is the same quantity in all four**: the
**last completely emitted durable cursor** for that attachment — the highest
event sequence the daemon finished writing to that socket, never one it had
only encoded or buffered. A controller connection that never attached omits
it. The cursor is the position the client reconnects at, and delivery from it
is contiguous and at least once, so a duplicate at the seam is expected and a
gap is a defect.

**"Best-effort" is the bound `daemon.stopping` already has**, reused rather
than restated: exactly **one** non-blocking write attempt of the record into
the connection's existing 4 MiB output buffer, and the close happens whatever
that attempt did. A backpressured client — which is precisely the client an
overflow detach is about — will usually not receive it and learns by EOF
instead. No new timer and no new number.

**No other connection is affected by any of the four**, and that is the
property the witnesses assert: a case per occasion, each with a second
connection attached to the same session, asserting the first connection sees
the record where its buffer admits one and sees EOF either way, and the second
keeps receiving durable events across the whole of it. The four
daemon-initiated close occasions have generation-2 vector coverage: both
optional-cursor shapes of the uncorrelated `control_owner_lost` form and one
vector for each of the three `detached` occasions. The correlated in-flight
lease-operation `control_owner_lost` refusal has its separate
request-shaped vector. The three `detached` vectors have identical code and
fields, which is deliberate, because why the daemon detached is an operator
fact in its logs and not authority-shaped information a client acts on
differently.

**The orderly transport cut follows the admission cut and has its own exact
barrier.** Once the relay has closed method admission and acknowledged it, the
connection registry atomically enters `transport_closing(cut_ref)`. Its
acknowledged state rejects every later provisional reservation or promotion and
marks every existing provisional or uninitialized row for EOF close. The owner
then kills and reaps the listener; only after that exact exit proves no further
accept can arrive does the registry close and reap the complete marked set and
acknowledge it empty. A peer accepted between the relay acknowledgement and the
registry gate may hold a provisional slot briefly but never initializes. The
registry gate, listener reap and final sweep share one absolute 5-second clock;
missing listener exit is `listener_lost`, and either missing registry
acknowledgement is `connections_lost`. Initialized peers remain open through the
drain.

**`daemon_stopping`, the refusal after the admission cut.** Every
post-initialize request linearizes admission at the relay. For the ten ticketed
calls ADR 0033 names, admission creates an origin row before any cross-process
descriptor can be sent. The row begins as
`pending_ticket(origin_id, class, nil)`; a lease-mutation row also binds the
session and currently registered owner incarnation before acknowledgement.
Create, activation-capable resume and attach then take the reservation handshake
above; another lease mutation goes to its lease owner. Promotion records the
ticket, starts the monitored core task and records its pid and monitor before
acknowledgement. Queries, artifact transfers, `session.acquire_control` and
`session.release_control` use lightweight permits. The lease calls change
lease-owner state but start no ticketed core mutation; reads and transfers
change neither Control nor the journal. Using and accounting at the same gate
removes a connection-layer check/use race.

The connection does not execute a permitted call inline. It first reserves one
of its 32 local request slots, assigns a strictly increasing sequence within
that connection incarnation and synchronously installs the corresponding exact
origin row. Every worker bind, promotion, result and terminalization must match
the full origin ID. Create and attach submit that acknowledged origin to the
connection registry; it owns their reservation and promotes the exact primary
or installs a waiter. For an epoch-authorized mutation, the acknowledged
pending ticket exists before the connection starts a waiting worker and sends
the descriptor to the session's lease owner. An activation-capable resume makes
the lease owner ask the registry to reserve and promote that origin; another
mutation is promoted directly by the lease owner. Acquire, release, queries and
transfers instead install their lightweight permit row.

Every request worker closes its spawn window with a parent-monitor/ready
handshake: before reporting ready it monitors the connection and waits without
dispatching. After readiness the connection asks the relay to bind the exact pid
and a relay-owned monitor. If the connection dies before that bind, the child
exits on parent `DOWN`; after bind, the relay owns retirement. A lease-mutation
origin therefore transitions
`pending_ticket(origin, class, nil) -> queued(origin, class, worker_pid,
worker_monitor, owner_incarnation) -> ticketed(task_pid, task_monitor, ...)`.
The connection sends the owner descriptor only after `queued` is acknowledged.

Messages from that one connection pid preserve wire-arrival order; distinct
workers never race their own `GenServer.call`s into the owner. The owner queues
the descriptor by connection incarnation and sequence and processes
lease-sensitive requests in that order. It validates a mutation's combined gate
at the head, then asks the relay or registry to promote the named queued row.
Promotion starts the core task before acknowledgement and tells the waiting
request worker to retire; the relay retains its monitor until exact `DOWN`, while
the relay task continues independently. If worker `DOWN` wins while the row is
still queued, the relay terminalizes that origin, authorizes the existing
generic request failure when the reply route is live, and later promotion starts
no task. If promotion wins, later worker death cannot cancel or settle the core
call. The owner remains the only initiator of mutation promotion, preserving
ADR 0033's ticket-before-owner-`DOWN` ordering.

If the cut wins before origin-row creation, the relay answers
`daemon_stopping`, no row or core task exists, and a frame merely read before
the cut has not been admitted. A row created before the cut may promote during
the bounded admission wait; the deadline terminalizes one still pending or
queued, kills and reaps its request worker, and makes later promotion a no-op.

For an unticketed call, the connection obtains a lightweight permit retaining
the immutable operation class, connection incarnation, optional session ID and
optional intended actor binding, completes the same worker ready/bind handshake,
and only then attempts `pending -> executing`. Before a lease permit is
acknowledged, the daemon owner supplies the session ID and either the current
registered lease-owner pid/incarnation or, for a fresh-owner acquisition, its
own daemon-owner pid/incarnation. Relay creation is serialized with exact owner
`DOWN`; an already-lost actor routes the origin into its retained owner-loss
classification rather than leaving a pending unbound row. The permit stores two roles separately:
`{request_worker_pid, request_worker_monitor}` and
`{actor_pid, actor_incarnation, start_op_ref | nil}`. For a query, read or
transfer the two pids are the same; for acquire or release the actor is the
lease owner or daemon owner, must match the immutable intended binding, and the
request worker only waits for its correlated answer. The relay sends `go` only after the executing CAS, so no worker may
dispatch before it is tracked. That permit remains until a result or one
terminal connection/worker/owner disposition. Ticket settlement remains with
the relay and keeps the originating accepted slot charged after connection
death. The pending origin row, rather than a cross-receiver ordering
assumption, proves that a mutation cannot materialize after slot retirement:
connection `DOWN` terminalizes an unpromoted ticket row that has no compensating
work, and a promoted row must settle before release. Lightweight acquire and
release permits follow the settling acknowledgements below.

The connection and relay monitor each request worker, at most ADR 0023's 32
in-flight requests per connection. Results, worker `DOWN`s, connection `DOWN`s
and lease-owner `DOWN`s settle a lightweight permit through one relay-owned
winning-disposition compare-and-set from `pending` or `executing`. A disposition
whose mirror, classification or actor cleanup is incomplete remains
`settling(disposition, op_ref)` until its exact acknowledgement and cleanup;
only then does it become terminal and render, if rendering is owed. The
connection reports its worker signal but never renders a result independently;
only the relay's winning disposition tells it whether to render the result, the
existing generic failure, or a correlated `control_owner_lost`.

Connection loss CASes every permit for that incarnation to `connection_lost`,
kills and reaps only its exact request workers, and emits no reply. It never
kills an actor merely because the actor pid appears in the permit: that pid may
be the daemon owner or a lease owner shared with other work. The actor's later
result is cleanup-only; ADR 0033 supplies the compensating rule for an
acquisition that had not yet made its grant visible and a release whose owner
must be restored from `release_pending`. Owner loss claims every pending
acquire/release permit whose immutable intended binding names that exact owner
and every executing permit whose actor binding names it. It also claims every unpromoted
lease-mutation origin bound to the dead owner, kills and reaps a queued worker
and starts no core task; a promoted relay task remains retained to its real
result. Each claimed origin waits for exact mirror-pop classification: an origin
on the returned holder suppresses its correlated form and receives only the
uncorrelated close, while any other origin receives the correlated refusal and
stays open. A later worker result or `DOWN` is cleanup-only. Thus two signal
orders cannot double-answer or double-release one row. Slot retirement waits for every worker monitor `DOWN`, so even a worker
blocked in an `:infinity` call is killed and reaped rather than relying on it to
notice its parent's monitor. Forced cases cover connection death while a
mutation worker is queued behind a prior ticket and while a lightweight read is
blocked at `:infinity`, plus worker death on each side of promotion; they prove
no queued core call after failure, one real result after promotion, and every
origin, worker, permit and accepted slot returning to baseline.

Owner-death cases pause acquire and release before and after their executing
CAS, including after a pending permit with an immutable exact-owner binding is
acknowledged but before that owner claims it, and pause a lease mutation as
`pending_ticket`, `queued` and promoted. The pending-permit case proves the
relay selects `owner_lost` from retained data without guessing and leaks no row.
Holder and non-holder origins prove the mutually exclusive close/refusal forms,
the two unpromoted mutation cuts start no core task, the promoted cut returns
the real core result, and every predecessor set drains before replacement.

A forced-order witness pauses a lease owner after a pre-cut pending ticket is
created but before promotion. Released within the admission wait, it promotes
and remains in the bounded set. Held past the absolute deadline, the pending row
becomes `shutdown_cancelled`; later promotion refuses, no relay task starts and
no durable or Control state changes. A request whose origin-row creation is
ordered after `cut` receives `daemon_stopping` and creates no row.

An orderly stop sends `cut` to that relay. When the relay handles the message
it switches to closed and acknowledges immediately. The mailbox order is the
linearization order: a request admitted before the cut may enter or remain in
core and is allowed to finish; a request processed after the cut refuses with
the correlated `daemon_stopping` carrying its `request_id` and nothing else.
The acknowledgement means **no later request can be admitted**. It does not
mean admitted work has settled or that no pre-cut task will enter core after
the acknowledgement. The cut returns the exact retained origin IDs with
pending, queued, ticketed, waiting or settling state and exact
lightweight permit IDs, not only their counts, and changes daemon lease routing
to `draining`. No request admitted after that transition may start a lease
owner. Any permit named by the frozen pre-cut set may claim execution before the
absolute admission deadline; only an acquisition may finish validation and
start its owner. The
drain waits for those frozen rows against one absolute admission-wait bound. A
pre-cut acquire or release already owned by an existing lease owner may return
its real result inside the bound. An acquire still in existence validation or
waiting for owner creation remains represented by its permit, but owner creation
must finish inside the bound; after the bound no later start is accepted.

At the bound the relay compare-and-sets every remaining `pending` lightweight
row and every unpromoted `pending_ticket` or `queued` ticket to
`shutdown_cancelled`, sends correlated `daemon_stopping` when the socket remains
writable, and kills and reaps its exact request worker before it can dispatch.
The registry releases a reservation whose primary never promoted. A lease owner
that later attempts to promote a cancelled row starts no task. Promoted ticket
tasks remain tracked
through their result, fatal disposition or post-quiesce seal. Executing non-lease queries, reads and transfers remain tracked through result
or the step-3 connection/worker barrier; if still live then, that barrier kills
them and `connection_lost` wins exactly once. Executing lease operations follow
ADR 0033's actor or provisional-child teardown and become
`shutdown_admitted`; their mutation is not described as rolled back. The closed
terminal permit states are therefore exactly `result`, `owner_lost`,
`connection_lost`, `shutdown_cancelled`, or `shutdown_admitted`, with one winner.
The same barrier returns ADR 0033's tagged settling-acquire, settling-release
and settling-owner-loss descriptors. Each keeps its already selected
disposition, finishes exact no-output relay and mirror cleanup inside
`freeze_deadline`, and leaves no nonterminal or claimable lease-operation permit and
no provisional, pending or stale owner mirror before core quiesce. An exact
granted acquisition or restored holder and its valid holder mirror remain for
the drain; the barrier never removes live collaboration state merely because
its operation settled. No descriptor is silently treated as an executing row
or omitted from the frozen set.
If exact owner `DOWN` is retained or arrives after `result` or
`connection_lost` was selected, descriptor settlement finishes first and the
same deadline covers the later reap, exact pop and classification; the selected
disposition does not change and no ordinary output is emitted.
Core then installs its early quiescing barrier. A surviving mutation that already
obtained a coordinator route is ordered against the coordinator's drain-specific
admission close; one that has not reached its first `Control` operation refuses
at the barrier and can create no late entry. A surviving read or transfer may be
ended by the later connection close, which is safe because it changes neither
Control nor the journal. The contract deliberately promises completion only
before that bound, not an unbounded shutdown wait.

After every connection and request worker is gone, the daemon owner performs a
mailbox barrier with itself and the relay, changes both relay and daemon-owner
lease phases to `tearing_down`, and freezes the exact lease-owner pid/incarnation set. No owner
start or routing-mirror install is accepted after that barrier. Registry stop and
the collective owner sweep consume exactly this frozen set, so no lease owner or
mirror can appear behind the sweep.

The connection stays open until the later close phase, so a post-cut frame can
still receive its correlated refusal. That refusal closes nothing by itself;
`daemon.stopping` is the subsequent uncorrelated best-effort notice that names
why the connection is closing. The witnesses deliberately differ: a pre-cut
unticketed request released within the bound completes on its own terms; one
held past the bound ends with the connection and changes no durable or Control
state; the same request admitted after the cut receives `daemon_stopping` and
never invokes its facade.

The lease-call witness forces an acquire before and after its existence reply,
before owner start, after owner start but before provisional mirror
installation, and after that install, plus a release while queued and after its
state transition. It forces both orders of connection `DOWN` and the acquire's
result CAS: loss first exact-clears the provisional mirror, reaps the start child
and exposes no epoch; result first promotes the exact mirror even if the holder
slot is already closing and leaves a granted lease whose reply may be lost.
Each cut is also held past the admission bound. A fresh executing acquisition is
frozen before and after provisional install, and settling acquisition, release
settlement and owner-loss classification are separately
held through the barrier. It must return their tagged descriptors, retain their
winning dispositions and remove every cancelled row and mirror without post-cut
output before quiesce. Existing-owner acquire/release results and restored
release order the recorded actor-owner `DOWN` on both sides of settlement;
fresh-acquire result orders the resulting child lease-owner `DOWN` named by
retained start/operation state, while fresh-acquire connection loss already
reaps its child and leaves the daemon actor alive. Each proves the original
disposition survives while the later pop/classification finishes under the
same deadline. It
asserts one terminal permit
disposition and at most one correlated reply, `daemon_stopping` for every
unlinearized survivor, no rollback of a linearized lease change, no stale mirror,
no owner or mirror appearing after the freeze barrier, and zero permit, worker,
owner and mirror rows after the step-4 sweep.

**Index startup failures are not wire codes.** `session_index_too_large`,
`session_index_corrupt` and `session_index_upgrade_required` all stop startup
before a socket exists, so no client can be holding a negotiated connection to
be told. They stay in the daemon's exit classes and out of generation 2's
ordered error inventory.

**A failed discoverability-index write is a notification, not an error.** Generation 2
adds a **second notification record family**, `daemon.notice`, beside
`daemon.stopping`:

| Field | Value |
| --- | --- |
| `code` | one of a closed set, today `index_write_failed` |
| `session_id` | the session the notice is about |
| `message` | a bounded non-secret sentence for an operator |

**It goes to the connection whose command caused it, and only that one**, and
it is written **after** that command's result rather than before: a client
that sees the notice first would be told about a session it has not yet been
told the identity of. If that connection is gone by then the notice is
**dropped** — it is about a command nobody is waiting on, the session is
reachable regardless, and the daemon's own `stderr` keeps the operator's copy.
It is never broadcast; other connections did not ask.

The activation it follows **succeeded**: the session is usable and reachable
by ID. After a pre-rename failure whose cleanup proved `.next` absent, the
persistent row is missing and the next ID-bearing command may retry it. After
a poisoned cleanup path, later publication is refused for this daemon
lifetime. After rename succeeded but the directory sync failed, the complete
next image is already named and adopted in memory, but the daemon claims no
crash durability and likewise performs no in-lifetime retry. The legacy
directory entry is an independent rollback artifact and its failure is logged
separately. Reporting the index failure as an `error` would
tell a client its command failed when it did not, and saying nothing would
leave a session absent from `session.list` with no explanation. The family
enters the digest's record-families input beside `daemon.stopping`.

**Correlation, for the refusals above.** `control_not_held`,
`control_pending`, `control_capacity_reached`, `control_held`,
the in-flight lease-operation form of `control_owner_lost`, `session_dormant`,
`session_unavailable`,
`daemon_stopping` and the three existence-query refusals are
ordinary **correlated** errors: each answers one request and carries that
request's `request_id`, no `event_cursor` and no session state, and none
closes anything **by itself** — the connection and every attachment on it are
untouched by the refusal, and where the connection is nonetheless closed a
moment later it is the stop sequence or the detach rule below doing it, not
the error. The uncorrelated cases in generation 2 are the ones named above,
the granted-holder form of `control_owner_lost`, ADR 0023's `detached` as this pair's detach rule reuses
it, and the `daemon.stopping` and `daemon.notice` records, and each states its
own close behaviour where it is defined. Stating this once is what lets the
vectors be written without guessing.

**The existence query has four domain results and one runtime-boundary
failure.** Core adds this exact host-facing API:

```elixir
Loopex.Runtime.session_existence(runtime, session_id) ::
  {:ok, :present | :absent | :invalid_id | :store_unavailable}
  | {:error, :runtime_unavailable}
```

It validates the session ID before dispatch, returning `{:ok, :invalid_id}`
without a Store call. For a valid ID it resolves one exact `Control` incarnation
and maps the existing `Loopex.Store.ownership_head/3` result exactly:
`{:ok, head}` to `{:ok, :present}`, `:absent` to `{:ok, :absent}`, and
`:unavailable` to `{:ok, :store_unavailable}`. That Store facade already
normalizes an adapter's malformed or out-of-set answer to `:unavailable`, so
the daemon maps that path to the same wire refusal and does not invent a fifth
domain result or an `existence_indeterminate` wire code. Failure to resolve or
call that exact `Control` is instead `{:error, :runtime_unavailable}`. The
daemon treats it as daemon-fatal `runtime_lost`; it never disguises loss of
core as Store unavailability. Every negative domain result creates nothing,
attaches nothing and grants no lease.

### The session index, and what it may claim

`session.list` reads a daemon-owned persistent discoverability index loaded at
startup. It never enumerates `sessions/` and never reads the Store on either
the startup or request path. This is a **maintained index**, chosen because the
supported OTP file API exposes `File.ls/1` as a complete list and supplies no
portable incremental directory iterator: wrapping that call in a function
which stops after 4,097 valid rows would still materialize every filename and
could inspect arbitrarily many malformed rows before reaching the bound.

The file is `<state root>/daemon/session-index-v1`. It contains only durable
discoverability inputs: `session_id` and `placement_identity`. `residency` and
`controlled` are live daemon overlays and are rebuilt as `dormant` and `false`
at each start. The index is **not Store truth**. It neither proves existence nor
participates in create, resume, admission, replay or recovery. Core's read-only
existence query is the only yes/no authority the daemon uses for an exact ID.

**The persisted format is bounded before parsing.** The file is canonical
UTF-8 JSON Lines with these exact compact objects and one LF after each:

```text
{"format":"loopex-session-index","version":1}
{"session_id":"<sid>","placement_identity":"<placement>"}
{"sha256":"<64 lowercase hexadecimal characters>"}
```

There is exactly one header, zero to 4,096 rows sorted by the **decoded raw
session-ID bytes**, and exactly one trailer. `<sid>` and `<placement>` are the
canonical unpadded base64url encodings ADR 0023 uses for binary identities;
each must decode to 1 through 256 bytes and re-encode byte-for-byte to the input
string. The SHA-256 domain is the exact header LF plus every row and its LF, in
order; it excludes the trailer. JSON has no optional whitespace or escapes in
this format. Key order is the literal order above. Unknown keys, duplicate or
out-of-order decoded IDs, padding, a noncanonical or invalid base64url alphabet,
the wrong version or format literal, CRLF, and bad digests are corruption.
The complete file is at most 4 MiB. The
daemon opens without following a symbolic link, checks the regular-file
identity and byte size before reading, reads no more than 4 MiB plus the
single byte needed to prove overflow, and checks the identity again after the
read. Oversize refuses `session_index_too_large`; malformed content refuses
`session_index_corrupt`. Both occur before socket bind.

The line and file bounds are compatible by construction, rather than two
ceilings whose first winner is undefined. A 256-byte identity has a 342-byte
unpadded base64url spelling, so a maximal **row including its LF is exactly
726 bytes**. The header is 46 bytes and the trailer 78 bytes, including their
LFs. Thus the largest admitted image is
`4096 * 726 + 46 + 78 = 2_973_820` bytes, below 4 MiB. The boundary has three
explicit dispositions: an existing image with a 726-byte canonical row can
open, while a 727-byte row is `session_index_corrupt`; live publication accepts
only the already-validated 1-to-256-byte identities and reports its existing
bounded publication warning rather than writing if an internal caller violates
that invariant; offline import refuses an invalid or over-bound legacy identity
and preserves the prior index byte-for-byte. It never truncates or silently
omits that legacy row. The 4 MiB read ceiling remains independent corruption
protection.

**Updates are atomic snapshots, not an append protocol.** The placement-lock
and marker-holding daemon serializes index changes and writes the complete next
canonical image to the one fixed sibling `session-index-v1.next`, mode `0600`
and created exclusively. The publisher retains the opened file's device and
inode identity. It syncs and closes that file, treating a close failure as a
pre-rename failure, then renames it over
`session-index-v1`, and syncs the `daemon/` directory before it reports success.
A crash before rename leaves the prior image and at most that one `.next` file;
a crash after the directory sync leaves the next image. After acquiring both
locks and before loading or writing the index, startup removes that exact
temporary only after `lstat` proves it is a non-symlink regular file owned by
the daemon user; any other shape is `session_index_corrupt`. No random or
per-attempt temporary name exists, so repeated crashes cannot accumulate an
unbounded directory. This adds no journal record and
changes no local Store byte. At 4,096 rows a new exact-ID session remains
usable but is not added; `session.list` reports `index_full: true` rather than
pretending completeness.

**Failures split at the rename, because only the earlier side can preserve the
prior image.** A write, file-sync, close or rename error occurs before a successful
replacement. Where still open, the publisher closes the descriptor and invokes one
cleanup path while it still holds both locks. If `lstat` finds the fixed
`.next` path, the publisher removes it only when its regular-file type, owner,
device and inode match the file this attempt opened, then syncs `daemon/`;
absence is already clean. A different identity, an unverifiable result or a
failed unlink or cleanup-directory-sync poisons index publication for the rest
of that daemon lifetime. Successful cleanup proves the prior canonical image
is still named and lets the next ID-bearing command retry the same snapshot.

A directory-sync error **after rename succeeds is different**: the canonical
path already names the complete next image in this running process, `.next` no
longer names the attempt, and restoring the prior bytes would be a second
unproved mutation. The publisher therefore adopts that valid next image in its
in-memory index, reports `daemon.notice: index_write_failed`, poisons later
publication without touching either path, and makes no durability claim for
the rename. A crash may expose either the prior or next complete canonical
snapshot; startup validates whichever image the filesystem presents. It may
not expose a partial image as valid because the file was synced before the
atomic rename. A poisoned daemon keeps serving the durable session and refuses
every later publication until restart.

`prepare-index` uses the same split and lock order. A pre-rename failure with
successful cleanup preserves the prior index; a post-rename directory-sync
failure leaves the valid next image named in the running filesystem but admits
that a crash may recover either complete image. In either failure case it
stops Store, attempts placement release last through ADR 0031's bounded helper,
and exits
`session_index_write_failed`. The witnesses inject write, file-sync, close and rename
failures before replacement, prove the exact temp is removed and an in-process
retry succeeds, then substitute a mismatched identity at cleanup and prove no
later write occurs before restart. A distinct post-rename directory-sync
failure proves the canonical path and in-memory projection hold the next valid
image, the publisher is poisoned, no rollback or later write is attempted, and
after an abrupt restart the image is one of the two complete valid snapshots.

A successful create or resume adds the row after durable existence **and this
daemon's placement** are established. Bare exact-ID existence and historical
create replay do not publish. The row becomes visible in memory only after the
snapshot is durable on ordinary success. The named post-rename
directory-sync failure is the sole different case: the complete newly named
image becomes visible in this process, the daemon issues
`daemon.notice: index_write_failed`, poisons later publication, and claims no
crash durability. A failed index write does not reverse the session operation;
the causing connection receives that notice, the daemon logs it, and later
commands carrying that ID retry the same idempotent write only when a
pre-rename failed attempt proved the fixed temporary gone. A poisoned
publisher keeps refusing until restart. A retry
with the same placement is idempotent;
a different placement conflicts. The independent legacy
`SessionDirectory.record_session/3` write remains for foreground rollback and
may succeed or fail separately. Its failure emits a bounded operator warning,
does not reuse `index_write_failed` for a different fact, and is retried on the
same later ID-bearing commands as the index write. Neither publication failure
reverses the session operation.

**Upgrade is explicit so startup stays bounded.** After acquiring the host
placement lock and then the Store marker, ordinary startup creates or verifies the owner-only, non-symlink
`daemon/` directory with mode `0700`; a new root whose `sessions/` directory
does not exist gets a **persisted** empty canonical mode-`0600` index there
before bind. If
`sessions/` exists but the index does not, daemon startup performs only the
bounded `stat` needed to learn those two facts and refuses
`session_index_upgrade_required`; it never calls `File.ls/1`. The operator runs
`loopex daemon prepare-index` while no daemon or foreground server owns the
root. That offline command acquires the same host placement lock first and the
local Store marker second, creates or verifies
the same owner-only, non-symlink mode-`0700` `daemon/` directory, uses a strict
daemon-owned legacy reader, and validates any existing canonical index. It
constructs the **union** of those two inputs. A session present in both must
carry the exact same placement identity; a disagreement refuses as
`session_index_corrupt` with status 84 and leaves the old index byte-for-byte
intact. The command validates
every non-temporary legacy row and enforces both the 4,096-row and 4 MiB bounds
over the union, refusing rather than truncating. Only after the complete union
passes does it atomically write or replace the mode-`0600` index, sync the
directory, stop the Store so its best-effort marker-release callback runs, and
then attempt the acquisition-specific placement-handle release through the
fixed `placement_release_ms` helper. A healthy branch proves both paths absent
and an immediate foreground reopen. Injected marker removal or parent-sync
failures and placement-removal failures instead prove that a complete residual
is handled only by the corresponding dead/live/unverifiable-owner recovery; a suspended placement
release reaches its deadline and exits non-zero without an unbounded tail. On a failure before rename it removes
only an empty `daemon/` directory that this invocation created and leaves a
pre-existing valid index unchanged. On a directory-sync failure after rename,
the new complete image remains named but its crash durability is unknown as
described above. Its scan is
explicitly **not** a bounded service-start
operation: the command warns that legacy `File.ls/1` materializes the directory
and may need operator repair of a corrupt or oversized legacy directory. This
one-time cost is kept outside daemon availability rather than mislabeled as a
bound. Re-running the command is therefore a refresh: an index-only row and a
legacy-only row both survive.

The strict reader does not call `Loopex.SessionDirectory.list_sessions/1`:
that released operator projection intentionally drops a row when its entry
cannot be decoded. The daemon reader opens the `sessions/` directory without
following a symbolic link and requires its owner UID to equal the daemon's
effective UID. It retains the owner UID, non-symlink directory type, device and
inode, materializes the names with `File.ls/1`, applies the released
temporary-name exclusion (`String.contains?(name, ".tmp-")`), and rechecks all
four fields, including current-daemon ownership. For
every remaining name it requires the released one-component session-ID
containment rule, a regular non-symlink file,
and an identity-stable read of at most the released 1 MiB entry ceiling plus one
byte to prove overflow. It rejects the compressed external-term tag before it
decodes the existing Erlang-term entry with
`:erlang.binary_to_term(contents, [:safe])`, and requires exactly
`session_id`, `runtime_id` and `commands`: the stored session ID must equal the
filename; the runtime ID and every command ID must be valid UTF-8, 1 through
256 bytes and NUL-free; at most 4,096 commands may exist; and every cached
result must equal the session ID. A non-temporary name or row that fails
containment, file-kind, size, stable-read, safe-decode, exact-key, identity,
UTF-8 or command validation refuses `session_index_corrupt`; it is never
filtered out. Failure to open or list the directory, an initial owner mismatch,
or any owner, type, device or inode change across the listing uses the exact
`state_root_unusable` refusal. All such failures precede publication, preserve
an existing index byte-for-byte and run the same bounded exclusion cleanup as
the other pre-rename failures. This reader remains in the daemon adapter and
adds no core listing API.

Successful import exits `0` after those bounded release attempts, remains
silent on `stdout`, and emits no daemon readiness record. Parser refusals use
the reference CLI's existing status `1` before either exclusion. Operational
refusals reuse the plan's applicable state-root, placement, Store or index class
and integer status, including `session_index_corrupt` for the identity conflict;
they have no wire surface and write only bounded diagnostics or warnings to
`stderr`.

Rollback needs no reverse migration. The M4 foreground server ignores
`daemon/session-index-v1` and continues using `sessions/`; the index may remain.
A later daemon reuses and validates it, but `session.list` never claims that a
row absent from this advisory index is absent from Store truth. If a foreground
server created sessions while the daemon was absent, the operator reruns the
offline import before relying on a complete discoverability view; exact-ID
access works regardless. Deleting the index is not a repair: on a root with
`sessions/` it restores the upgrade refusal and requires another explicit
import.

The in-memory projection claims only facts its owners can keep true:

- `session_id` and `placement_identity` come from the validated persisted row
  or from a successful create/resume under this daemon's configured placement;
- `residency: active` means this daemon activated that session in this
  lifetime; `dormant` means it has not. It never claims a coordinator is live;
- `controlled` is updated by the daemon owner's serialized projection after
  acknowledged lease results and after an exact lease-owner `EXIT` plus routing
  mirror-pop disposition. A dead lease owner never updates it. It names no
  durable controller.

Lineage, lifecycle state and committed sequence are deliberately absent. A
client that needs them attaches and reads the snapshot anchored by core.

**Recovery of an omitted row first proves existence, then proves placement by
activation.** Core's existence query answers one of the four domain results
inside `{:ok, result}` or the distinct outer
`{:error, :runtime_unavailable}`. Only `{:ok, :present}` permits a lease grant or later
activation but **does not permit publication**, because that result carries no
recorded placement identity. The daemon writes the directory/index row only
after create or resume succeeds under its configured placement. The other three
leave no attachment, lease, activation or row and map to their distinct
generation-2 refusals. Runtime unavailability is daemon-fatal `runtime_lost`
and reaches no existence refusal. A session stored under placement A, absent from both
publications and reached by a daemon composed as B, answers `{:ok, :present}` but its
resume refuses the placement mismatch and neither publication may record B.

A client that lost the create reply and therefore lacks a session ID recovers
in this exact sequence:

1. Re-present `session.create` with the original `command_id` and byte-identical
   creation inputs.
2. The daemon reservation verifies the canonical request digest and forwards
   the replay without consulting the index.
3. Core returns the historical session ID; a changed request under that ID is
   a conflict, not a coalesced success.
4. Replayed create starts no coordinator.
5. The daemon asks core's read-only existence query for the returned ID and
   proceeds only on `{:ok, :present}`, without publishing a placement row.
6. The client acquires control and receives a writer epoch.
7. It sends `session.resume` with a fresh resume `command_id` and that epoch.
8. Core validates the daemon's configured placement and activates the session,
   charging the lifetime ceiling.
9. Only after that success does the daemon idempotently repair the legacy
   directory entry and daemon index row from the now-proved placement; either
   write may report its own failure without changing Store truth.

That resume identity belongs to one activation attempt, not to the session for
all future daemon lifetimes. While its result is unresolved, every transport
retry re-presents the same command ID and byte-identical input. Once a success
is resolved, the client attaches. If a daemon replacement made the session
dormant and core answered by replaying the completed resume command, that
successful replay starts no coordinator; an ensuing `session_dormant` attach
therefore closes the resolved attempt and causes the client to allocate a new
resume command ID for a new activation attempt. That new ID is retained across
any loss until its own result resolves. Another resolved-success/dormant pair
may repeat the transition, but every attempt remains inside the original
non-resetting client recovery deadline. The client never allocates a new ID to
escape an unresolved result.

The create-history arm is the companion host-facing API:

```elixir
Loopex.Runtime.lookup_create_result(runtime, command_id, options) ::
  {:ok, {:historical, session_id} | :absent | :conflict
        | :store_unavailable | :unexpected}
  | {:error, :runtime_unavailable}
```

It reuses `Store.runtime_command/2`; it adds no Store callback. Core rebuilds
the canonical create transaction from the supplied
options and the runtime's creation configuration, then presents its bytes and
digest under the existing `command_kind: :create` binding. The local adapter's
read projection recognizes its retained create row and returns
`{:completed, %{result: session_id}}` only on an exact binding; mismatch keeps
the existing `runtime_command_conflict`. This changes no durable frame,
callback arity or Store result union. The five values inside `{:ok, result}`
are the complete create-history domain; failure to resolve or call the exact
`Control` returns the same outer `{:error, :runtime_unavailable}` as the
existence query, and the daemon again treats it as fatal `runtime_lost`.
At the activation ceiling, `{:historical, session_id}` returns the prior create
result without publication, `:absent` maps to
`activation_ceiling_reached`, `:conflict` maps to the existing correlated
admission refusal reason `runtime_command_conflict`, `:store_unavailable` maps
to the correlated `store_unavailable` error, and `:unexpected` maps to the
correlated `internal_failure` error without serializing the term. Each mapping
has a ceiling-path witness; the outer runtime failure is the separate fatal
`runtime_lost` path.
10. The client attaches and drives it.

A client that already knows the session ID begins at step 5. If the index is
full, step 9 omits the row and the next `session.list` reports
`index_full: true`; step 10 remains available. The witness injects the
Store-commit/before-reply crash cut,
runs all ten steps, and proves one durable session, no coordinator from the
create replay, a repaired row, one charged activation and a subsequent prompt
on the recovered session.

A page is consistent with the in-memory index at the moment it is read and is
ordered by session ID bytes. Rows are added but never removed during one daemon
lifetime, so insertion before a page cursor can make a later page miss the new
row; rows do not vanish or repeat. A client that needs a refreshed view pages
again from the start. `limit` outside 1 to 256 and a malformed
`after_session_id` refuse `invalid_request`; an unknown but well-formed cursor
pages from its byte position.

The startup witness places more than 4,096 valid legacy entries and an
arbitrarily large population of malformed names beside a valid bounded index,
and proves that daemon start reads only the index bytes and performs no
`File.ls/1` call. Separate cases prove oversize, digest failure, duplicate ID,
wrong header/version, noncanonical base64url, a maximal 726-byte row accepted,
a 727-byte row refused as corrupt, interrupted snapshot replacement,
missing-index upgrade refusal, successful offline import and foreground
rollback with the extra file present. A fresh root is proved to persist the
literal empty image in a mode-`0600` file under a mode-`0700` non-symlink
directory before bind, and a restart consumes that image. A failed import
before rename removes only an empty daemon directory that invocation created;
with a pre-existing directory or index it leaves every byte and mode unchanged.
A separate post-rename directory-sync failure proves the newly named image is
complete and valid, no rollback is attempted, and an abrupt restart accepts
either complete snapshot. The import
case starts with index-only session A and legacy-only session B and proves both
rows in the replacement; a second case gives one shared ID two placement
identities and proves refusal with the original index unchanged. Three strict-
reader cases place, respectively, a corrupt term, an entry larger than 1 MiB
and an entry whose stored runtime ID contains invalid UTF-8 under otherwise valid
non-temporary names. Each refuses `session_index_corrupt`, leaves the complete
pre-existing index byte-for-byte identical, publishes no partial union and
proves the offending row was not silently omitted. An injected directory-
metadata seam separately reports a foreign owner before listing and an owner
change after listing. Each case refuses `state_root_unusable`, preserves the
prior index byte for byte and publishes no union; the witness does not depend
on the test process having permission to change filesystem ownership.

### Session residency: active, dormant, and their bounds

A session is **active** when this daemon activated it in this lifetime and
**dormant** when the root holds it durably and this daemon has not. Dormancy
is about activation and **not** about the index: a session the index does not
record — one past the 4,096-entry ceiling, or one whose directory entry was
never written — is dormant in exactly the same sense, and is reached by ID and
activated in exactly the same way. What the index controls is whether
`session.list` shows it, and nothing else. An earlier revision defined dormant
as "the index records it and this daemon has not", which made an unrecorded
session neither active nor dormant and made the listing bound look like a
bound on reachability, which this pair says twice that it is not. Nothing
durable distinguishes active from dormant, and neither is a claim about a live
coordinator: both are daemon facts, recorded when the daemon acted.

A dormant session costs less than an active one, but not nothing, and the
plan should not pretend otherwise. If indexed, it holds one row against the
4,096-entry ceiling, and its history sits in the root's single append-only log
against the 256 MiB capacity that every session in the root shares — so a
dormant session still consumes the two resources whose exhaustion stops the
daemon, and retiring a root is what actually frees them. What it costs nothing
in is the things activation buys: no coordinator, no replay at start, no
attachment, no window, no buffer.

**Activation is one-way for the daemon's lifetime.** The daemon never
intentionally stops an activated session's coordinator or returns its
activation fact to dormant. Dormancy is *not* deactivation, and the daemon has
no operation that stops a coordinator. A temporary coordinator can still die;
that does not falsify the one-way activation fact.

That is a correction, not a simplification. An earlier draft let an idle
session "go dormant, releasing its slot", which is wrong twice over. The idle
condition it named — no attachment and no admitted command — is not the same
question as whether work is running: a session with every client detached can
still have a model request in flight, a tool effect dispatched, an interaction
awaiting an answer, a recovery in progress, an unresolved `commit_unknown`, or
an admission executing inside core. Stopping it would destroy exactly what
Outcome 1 exists to prove, that work progresses with zero attachments. And
there is no operation to stop one with: core owns coordinator lifetime, and
none of M5's six core changes (the complete concurrent-attachment lifecycle,
the read-only existence-and-create-history query surface, the trace exclusion,
`quiesce/1`, the `disposition` and `control_entry` fields on the detailed create
and resume functions, and managed provider lifetime) stops a coordinator,
so a deactivation call would be a further core change this milestone does not
make.

- **What idle eviction and reclamation apply to.** Attachments, resident windows
  and socket output buffers, and nothing else. Dormancy means only that the
  durable session has never been activated by this daemon in its current
  lifetime. An idle observer attachment, or a connection no longer holding a controller lease, is evicted; its window
  may be reclaimed, its buffer is released — and the coordinator beneath them
  keeps running. Every byte ceiling in this decision is about those three and
  is unaffected.
- **Lazy recovery.** A restarted daemon activates no session. It acquires the
  writer marker, reads the index, binds the socket, and activates a session
  when a client first reaches it — by `session.resume`, or by `session.create`,
  which starts a coordinator for a session that did not exist before.
  **Creation counts as an activation** against the ceiling below, because it
  costs exactly what any other activation costs: a live coordinator the daemon
  holds for its lifetime. A ceiling that counted resumes but not creations
  would be a ceiling on the wrong thing.

  `session.acquire_control` and `session.attach` do **not** activate. Acquire
  is a lease over a session that durably exists, validated by the existence
  query, and attach is refused with `session_dormant` against a session this
  lifetime has not activated — which is exactly why the CLI's `resume` form
  exists and why `attach` alone cannot start work.
- **Temporary coordinator death.** If an activated coordinator dies, the
  activation set remains active. Attach may therefore succeed, after which
  a generation-2 `session.inspect` reaches core and maps only its exact
  `:session_unavailable` reason to the wire's `session_unavailable`; repeating
  against the same daemon repeats that result without parsing a message or
  sending a mutation.
  The operator restarts the daemon and retries `loopex resume --daemon`, whose
  dormant branch resumes and starts a new coordinator. A forced witness kills
  the coordinator, proves attach then inspect refuses without a second
  coordinator, restarts the daemon, and proves resume, reattach and a later
  prompt succeed on the same durable session.
- **Activation ceiling.** At most 64 sessions are activated **per daemon
  lifetime**, not at once, because nothing gives a slot back. The 65th
  **fresh** activation refuses with a stable reason naming the ceiling and the
  remedy, which is to restart the daemon. Before refusing a create, the daemon
  uses core's read-only create-history discriminator with the exact
  `command_id` and canonical session options. `historical(session_id)` returns
  that prior result without a coordinator, activation or publication; discovery
  is repaired only after a later successful resume proves this daemon's
  placement (which may require a later daemon lifetime at the ceiling);
  `absent` is the fresh case the ceiling refuses; `conflict` preserves the
  runtime's command-conflict refusal; store failure and an unrecognised result
  fail closed. A resume of an already activated session likewise needs no new
  slot; a dormant resume at the ceiling refuses before core is called. That is
  a real limitation rather than a
  design, it is recorded as one in the plan and in the operator page, and it
  is the honest cost of leaving coordinator lifetime alone in M5. Lifting it
  needs a core deactivation operation that can tell "quiescent" from "idle",
  which is a decision of its own.
- **Index bound.** The maintained index holds at most 4,096 recorded entries
  and its complete persisted image is at most 4 MiB. Startup refuses an
  oversize or corrupt index before bind; runtime discovery of an additional
  exact-ID session sets `index_full` and leaves the session usable. The daemon
  never scans the legacy session directory. A root that predates the index is
  prepared explicitly by the offline import described above, which refuses
  above 4,096 rather than writing a truncated image. This mechanism belongs to
  the daemon adapter and removes the proposed `Loopex.list_sessions/2` change
  from core.
- **Homogeneity.** One state root is one host composition for the daemon's
  process lifetime. The daemon is composed once, with one workspace, policy,
  provider configuration and set of project resources, and serves every
  session in the root under it. A recorded session the current composition
  cannot serve — a placement identity it does not hold, or retained
  configuration it cannot satisfy — is reported at *activation*, naming the
  session and the mismatch, with the existing refusal reasons; it is never a
  reason a start fails, because recovery is lazy and start never reads it. The
  operator documentation says that mixing compositions in one root means some
  sessions will refuse to activate, and that the remedy is one root per
  composition.

The client supplies its ordered supported generations in `initialize`. The
daemon supports exactly `loopex.experimental/2`: it selects that generation
when the client lists it, at any position, and otherwise refuses with
`unsupported_generation`, leaving the connection uninitialized with no second
attempt, exactly as ADR 0023 fixes for a foreground process. The successful
reply carries `selected_generation`, generation 2's own exact schema digest,
the generation-2 method inventory and limits. That digest is necessarily a new
value: the digest is taken over the generation, the ordered methods, the
ordered record families, the ordered error codes and the limits, and
generation 2 changes the generation and the method list, so it cannot and must
not equal generation 1's. It is written out as a literal beside generation
1's. Generation 1's **schema digest** is re-pinned in the same place rather
than asserted unchanged, because the rename above moves it — its two
manifest file digests do not move, those files already carrying the new
name — and the case that pins it asserts every *other* input to generation 1's
digest, its ordered methods, record families, error codes and limits, is
byte-identical to what `0.1.0` served. That is what still catches an accidental edit to
generation 1's contract: the inputs are compared, not just the result, so a
changed method list fails there instead of hiding behind a digest that was
expected to move anyway. The generation-2 schema and its
vectors are new files beside generation 1's, as
`apps/loopex_protocol/priv/schema/loopex-experimental-2.json` and
`apps/loopex_protocol/priv/vectors/loopex-experimental-2.json`, reviewed with
the change that adds them, and **each carries its own pinned file digest**
written into the conformance module beside the two generation 1 already pins —
so an independent client can fetch either file and verify its bytes, and an
edit to a generation-2 file fails the same way an edit to a generation-1 file
does. The digests are computed and pinned when the files are written;
generation 1's two file digests are **unchanged**, because those manifests
already carry `loopex.experimental/1` and never carried the retired name; only
its schema digest moves, the generation being one of that digest's inputs.
Every served generation is additionally asserted against its own contract
module: `LoopexProtocol.Session.generation()` equals generation 1's manifest
`/generation`, and `LoopexProtocol.Session.V2.generation()` equals generation
2's. That is the check whose absence
let the released code and the released manifests disagree in the first place. A negotiation vector proves selection from a list
that also names generation 1 under its new string, refusal of a list naming
only generation 1, and refusal of a list naming only the retired
`loopex.session.v1-experimental`. The M4 foreground server keeps
serving generation 1 only, with its one-attachment-per-process rule.

### Attachment lifecycle

Attach is the runtime's race-free cursor transaction: the dispatcher
establishes the barrier at committed sequence N, the snapshot is anchored at
exactly N, and durable events after N are buffered for that attachment and
delivered contiguously after the snapshot. The daemon adds:

- a resident window of at most 4,096 durable events and 16 MiB of encoded
  events per session held in memory, defined as a **droppable encoding
  cache** and nothing else. It holds the encoded bytes of events core has
  already delivered to at least one attachment of that session, so a second
  attachment arriving at the same position is served without encoding them
  again. It is not a replay source: it never anchors a snapshot, never
  establishes or advances a cursor, and is never consulted to decide what a
  client is owed. Every attach, reattach and reconnect — including one whose
  position lies inside the window — goes through core's cursor transaction,
  and the window is used only to answer the bytes core has already named. It
  may be dropped whole at any instant; the only consequence is that the next
  delivery re-encodes. Correctness therefore cannot depend on it, and the
  tests prove that by running the residency cases twice, once with the window
  disabled, with identical delivery.

  Reclamation is deterministic so that it can be tested rather than observed.
  Before an encoded-byte admission, the candidate bytes remain pending and
  uncharged. If `charged_aggregate + pending_admission_bytes` would exceed the
  daemon's aggregate ceiling, the registry takes one accounting snapshot and
  reclaims from that snapshot in
  this fixed order: first every window whose session has zero
  attachments, in ascending order of the monotonic time of their last
  delivery, ties broken by session ID bytes ascending; then, if the ceiling is
  still exceeded, the window of the session whose slowest attachment is
  furthest behind **by encoded bytes owed** — the sum of encoded bytes for
  events core has named for that attachment and the daemon has not yet
  written, which is a daemon-owned quantity comparable across sessions because
  it is measured in bytes rather than in each session's own sequence numbers.
  A sequence-distance metric would not be comparable: sequence numbers are
  per-session and say nothing about how much memory an attachment is costing.
  Ties break by session ID bytes ascending. Each step is **repeated until
  `charged_aggregate + pending_admission_bytes` is at or below the ceiling**,
  not applied once: releasing one window may not be enough, so zero-attachment
  windows are released in that order until either the pending admission fits
  or none is left. Active-session windows follow in
  the derived order until none remains. The registry then closes connections
  with **no live attachment**, largest output buffer first, ties by ascending
  connection-incarnation bytes. Such a connection has no session cursor to
  preserve and receives no `detached` record; an initialized one is closed
  after exactly one non-blocking write/flush attempt for already-buffered
  complete records and is never awaited for peer progress, while an
  uninitialized one closes immediately. This step repeats until the pending
  admission fits or no unattached connection remains. Only then does the daemon detach
  the slowest live attachment at its last emitted cursor — sending
  that connection a `detached` record and closing it, under the detach rule
  above, so the bytes the attachment was holding are released with the
  connection rather than lingering behind an open socket nothing is reading —
  and that too repeats until the pending admission fits. Only then does the
  registry atomically charge and admit the candidate bytes. If the complete
  allowed sequence cannot make them fit, the corresponding connection is
  refused, closed or detached without ever charging those pending bytes.
  Independently of pressure, a window whose session has had zero
  attachments for the idle interval is dropped. No reclamation stalls a
  journal transaction and none changes what any client is owed.

  On the local adapter every durable event is retained until the root is
  retired, so store replay always succeeds. `cursor_expired` with a fresh
  snapshot and cursor is the defined response a compacting adapter returns for
  a cursor older than its retained history; no M5 witness can produce it and
  none claims to;
- the core event-count queue and the daemon socket output buffer above; when
  the next event would exceed either, the attachment is detached at its last
  completely emitted cursor with a stable reason — a `detached` record and the
  close of that connection, under the detach rule above — and the client
  reconnects at that cursor on a new connection;
- at most 512 MiB of retained encoded events across the daemon's output
  buffers and resident windows; on aggregate pressure, evict windows, close
  unattached buffered connections, or detach the slowest eligible attachment
  in the exact order above before admitting more bytes, without stalling a
  journal transaction;
- 64 attachments per session and 512 per daemon, refused at attach with
  **`capacity_exceeded`** when exhausted — ADR 0023's existing code, and after
  the connection ceiling moved to `accept` the only thing in generation 2 that
  produces it;
- eviction of an **observer** attachment that has consumed nothing for ten
  minutes; the
  `detached` record names the cursor the client may resume from and the
  connection is closed with it.

  **A connection holding a controller lease is exempt while it holds it**, and
  that exemption is a correction rather than a convenience. A controller of a
  quiet session — one waiting on a long model call, a slow tool or an
  unanswered interaction — consumes nothing for minutes at a time and is
  perfectly healthy; evicting it would close the connection its lease is bound
  to, and ADR 0033 frees a lease early only on an explicit
  `session.release_control`, so the session would then be uncontrollable until
  the term expired, with the outgoing controller told nothing it could act on.
  Renewals are that connection's activity, and they are already required every
  ten seconds against a thirty-second term, so a controller that has stopped
  renewing loses its lease on its own clock and becomes an ordinary observer,
  at which point the idle interval applies to it like any other.

  Its witness is the pair that must differ: a controller of a session with a
  long-running model call, consuming nothing for longer than the interval, is
  asserted **still attached and still holding its lease**, while an observer
  on the same session across the same interval is asserted evicted and closed.
  A second case stops the controller's renewals and asserts that once the term
  elapses it is evicted like any observer, so the exemption is proved to be
  the lease's and not the connection's.

  **What resets the interval**, stated because "consumed nothing" is not a
  mechanism: any **durable record the daemon completely emits to that
  connection**, and any **request that connection sends**. Either is evidence
  of a live peer. Progress that is coalesced or dropped does not reset it, and
  neither does a record the daemon buffered but did not finish writing — the
  cases where the client may be exactly the one that has stopped reading;
- transient progress coalesced per attachment and dropped first under
  pressure, with a counted drop; no progress item ever waits on a journal
  transaction.

A detached, evicted or reconnecting client that attaches at its retained
cursor receives every durable event after that cursor at least once and in
order; it never receives a gap, and it deduplicates by session ID, event
sequence and event ID.

### Evidence

Tests prove: two attachments from one embedded holder and attachments from two
holders keep independent handles, snapshots and cursors; named replacement
removes only its exact same-holder target and releases only that target's
transfers; a foreign, stale or other-session selector changes nothing; holder
death removes its complete attachment set in EventDispatcher and Control and
releases every transfer while another holder continues; the daemon retains
closing slots until relay settlement and the cleanup worker's
`release_holder/2` acknowledgement and `DOWN`, so a replacement attach never
crosses either count ceiling. One held cleanup worker does not block status,
acceptance within remaining capacity or retirement of an unrelated slot; 512
simultaneous closing slots run 512 cleanup workers concurrently, while an
abnormal worker exit or missing acknowledgement selects `runtime_lost` and
never reuses its slot. At the
post-publication/pre-finalization cut, ordinary and replacement cases force
publish-ack-before-`DOWN` and `DOWN`-before-publish-ack orders. Both finish with
equal empty live sets for that holder, no pending transaction or charge and
released new transfers; the latter returns `:holder_unavailable`, while the
former may return the handle before ordinary cleanup. A replacement target and
its transfers are never resurrected after publication in either order.

The reservation handshake is forced after origin installation, after the
registry's activation reservation or replacement borrow, and on each side of
primary promotion. Create and dormant resume each prove the invariant
`|activation set| + |reservations| <= 64`; exact duplicate creates and resumes
use distinct waiter origins but one reservation and one task. At attachment
charge 512, an exact repeated replacement uses one borrow and one Control
transaction, while a distinct request for that target receives
`attachment_conflict`. Connection loss or cut before promotion leaves no task,
waiter or charge; after promotion, primary connection loss retains the one task
and charge through its real result. Every result settles registry accounting
before any primary or waiter reply, and shutdown abandonment reuses no charge.

Dispatcher-restart cases kill EventDispatcher with several holders before
stage, after stage, after authorization, and after the publication
acknowledgement was sent but before Control consumed it. At every cut the
original embedded caller receives `:attachment_superseded` within the fixed
bound. In the daemon form the dispatcher sentinel selects fatal `runtime_lost`;
teardown clears the relay ticket and charge exactly once, without promising a
stronger client result than the fatal close. The replacement
registration clears Control and dispatcher live/pending/waiter sets, holder and
repetition state, reserved and borrowed capacity charges, and transfer state;
late old-incarnation messages are cleanup-only, no removed replacement target
is restored, all old handles are stale, and a fresh attach succeeds. A case
holds an unacknowledged outbox row across the restart and
proves the replacement was seeded at Control's retained event sequence: the
fresh snapshot stops there, then resolution and acknowledgement release the
row exactly once. Startup and restart are also held between `init/1` and the
continue: the runtime root completes child start without deadlock, queued
attachment calls remain unserved, and no acknowledged watermark is lost before
ready. The decisive interleaving holds Control inside `post_commit` while the
successor registers: the initializing dispatcher remains responsive to the
synchronous acknowledgement, merges it by maximum with the seed, and both
operations finish before admission opens. Killing the dispatcher at each
registration phase kills its linked worker; no predecessor worker remains to
finalize a later incarnation.

The call-shape cases prove the read-only preflight keeps its five-second bound,
the state-changing half is one deferred `:infinity` Control call, Control alone
replies, caller death drops only the route, and `post_commit` completes while a
snapshot worker is held. Killing that worker refuses only its transaction;
killing the dispatcher ends all preparation workers, and 512 pending attaches
produce no 513th worker.

The protocol suite proves the inherited boolean replacement remains byte- and
behavior-compatible in both generations and each adapter maps it to core's
exact target, a
pipelined attach and acquire cannot bind one connection to different sessions,
`control_owner_lost` vectors cover the correlated in-flight lease-operation shape
and both uncorrelated optional-cursor shapes, with the required message and
their opposite discriminators forbidden; `fatal:listener_lost` reaches existing clients and
`fatal:connections_lost` does not claim a record, and the acknowledged cut
admits pre-cut work while refusing every post-cut request.

Replay evidence proves snapshot-then-contiguous at-least-once delivery with no
gap across enabled, disabled and mid-stream-dropped resident windows; bounded
reclamation, slow-client detach, idle-observer eviction and reconnect leave other
attachments progressing; a population consisting only of initialized but
unattached clients attempts the next output-buffer admission for which
`charged_aggregate + pending_admission_bytes` would pass the aggregate
threshold, proves those pending bytes are never charged, reclaims until that
sum fits or closes in the specified order without admitting them, and observes
that the aggregate never exceeds 512 MiB, without a fabricated detach cursor;
a suspended initialized peer proves the
single non-blocking attempt cannot stall reclamation and its retained bytes are
charged until close, then return the aggregate to at most 512 MiB; all count and
byte ceilings refuse
independently with process RSS recorded; and progress is coalesced or dropped
without a journal delay.

Client-recovery evidence forces the resume replay cut: a resume commits and
activates, its reply is lost, the daemon is replaced, and the retained command
ID resolves as a completed replay that starts no coordinator. Attach still
returns `session_dormant`; the client then allocates one new resume command ID,
and a loss before that attempt's reply reuses that new ID. The fresh attempt
activates exactly one coordinator and the subsequent attach succeeds, all
inside the original non-resetting recovery clock.

Index evidence proves startup reads at most the 4 MiB index image and never
enumerates `sessions/`, including with more than 4,096 valid legacy files and
arbitrarily many malformed names; oversize, corrupt, duplicate and interrupted
images fail or recover as specified; a missing legacy-root index requires the
offline import; foreground rollback ignores a valid index; paging carries only
the four fields and exact cursor; and full-index exact-ID activation succeeds
with `index_full`. A clean pre-rename failure notifies the causing connection,
proves the fixed temporary was removed and the directory synced, and permits a
later ID-bearing command in the same daemon lifetime to retry publication. An
unverifiable or failed pre-rename cleanup poisons publication so that later
commands touch no publication path until restart. A post-rename directory-sync
failure adopts the complete next image in memory, notifies the causing
connection, and likewise permits no later publication until restart. A
compatibility-directory failure is independent: it emits only the bounded
operator warning and is retried by a later ID-bearing command. None of those
publication outcomes reverses the session operation, and command-ID recovery
repairs an omitted row without creating a second session.
The transport cases also cover simultaneous starts, Store
loss, generation negotiation, peer authorization, socket-path bounds and ADR
0023 framing refusals. Direct parser/path-resolver cases pass binaries containing
`<<0xFF>>` as the selected state root and as the explicit socket path rather
than relying on an OS argument or environment representation. They assert exact
`state_root_unusable` and `invalid_socket_path` refusals, respectively, before
path normalization or any placement, Store, filesystem, component, readiness
encoding or socket call; `daemon prepare-index` repeats the root case with the
same zero-effect assertion.

### Alternatives

TCP on loopback was rejected for the local daemon: it has no peer-credential
check and invites remote exposure by misconfiguration; WebSocket and HTTP
remain later transports under vision §18.8. An unbounded per-attachment queue
was rejected because it lets one client grow coordinator-adjacent memory
without bound. Keeping the M4 one-attachment-per-process rule was rejected
because a daemon's clients are processes by definition. Keeping one
attachment per holder was also rejected: an embedded holder may need several,
and a boolean replacement cannot identify one of them. A daemon-owned proxy
fan-out was rejected because it would duplicate core cursor and queue
ownership and need a second replay boundary to preserve the
subscribe/snapshot race. Serving generation 1 on the daemon was rejected: its
wire has no lease field, so it could only ever be served as one exclusive
connection per session, which the foreground server already provides, and it
would add a second fencing path with no wire epoch. Promising exactly-once
replay was rejected on 2026-09-14 because the founding contract is
at-least-once with client deduplication, and a stronger daemon promise would
create an expectation no other surface honors. Removing `session.list` was
rejected on the same day because an observer without filesystem access to
the root would have no way to discover sessions; the bounded page contract
above is the cost of keeping it. A bounded wrapper around `File.ls/1` was
rejected because the complete name list has already been materialized before
the wrapper can stop. A daemon-maintained index was selected instead of a
native directory iterator because OTP exposes no portable streaming iterator
on the supported platforms and the index changes neither Store ports nor
journal bytes.

<a id="technical-adr-0032-compatibility"></a>
### Compatibility and Rollback Mechanics

Concept: [Consequences and rollback](0032-daemon-attachment-residency-and-replay.md#concept-adr-0032-consequences).

Generation 2 is additive over generation 1's method set and both are
experimental with the exact-generation rule; no mixed-generation stream
promise exists. The daemon serves generation 2 only; the existing foreground
server still serves generation 1 with one attachment in its process. The seven
initialize-limit additions are advertised under the existing `limits` member;
the remaining residency ceilings are server-enforced and, where specified,
reported by `daemon.status`. Removing the daemon leaves the foreground server
unchanged. For embedded callers, core keeps the same attach API shape and
preserves the common one-attachment case
while supporting independent same-session and same-holder attachments. Two
intentional transient behaviors change: a second attach no longer implicitly
supersedes the first, and holder death releases that holder's complete
attachment set and transfers. The new index
is a bounded daemon discoverability file only: no journal record, Store port,
session event or snapshot depends on it. Foreground rollback ignores it, while
an M5 daemon validates and reuses it. A legacy root is upgraded explicitly by
the offline import under the host placement lock and then the Store marker;
there is no reverse migration.

Acceptance binds this complete pair at the exact candidate the maintainer
names in the governance record. Its evidence and compatibility claims remain
unproved until the tests the M5 plan maps to outcomes 1, 2 and 4 exist and pass,
and Outcome 5 closes against those same bytes.
