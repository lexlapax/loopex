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

It is a subdirectory rather than the state root itself because the root is not
the daemon's to re-permission. `LoopexAppServer.Host` creates it with
`File.mkdir_p/1` and no mode, so under the ordinary umask of 022 an existing
M4 root is `0755` — measured, not assumed. Requiring the *root* to be `0700`
would have made the daemon refuse every root the foreground server and the CLI
have been writing since M4, which contradicts this milestone's central
compatibility claim that moving a root between the daemon and the foreground
surfaces is stopping one and starting the other. Tightening the root instead
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
truncated. The tests bind at the bound and at one byte past it on every
platform the release check runs.

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

**Fail closed.** Where a platform has a named mechanism, a credential read
that errors, returns a short or unrecognised structure, or reports a uid the
daemon cannot decode closes the connection before initialize; it is never
treated as permission. Where a platform has no mechanism at all, the daemon
says so in its diagnostics and the boundary is the verified filesystem layer
alone — which the daemon proves it has, because it refuses to serve when
ownership and mode cannot be verified.

The evidence follows the same split. The fast check proves the filesystem
layer and the fail-closed paths without needing a second user: a permissive
directory or socket mode, a parent the daemon does not own, and a path
component the daemon did not create are each refused at start; an unreadable
or undecodable peer credential closes the connection. The real cross-uid
refusal is a release-check case on the Linux lane, where a second unprivileged
user exists: a connection from another uid is refused before initialize and a
connection from the daemon's own uid succeeds, both recorded with the run.

Startup order is fixed. The daemon first opens the state root through the
local adapter and acquires its writer marker; a daemon that does not hold the
marker refuses with the adapter's `store_writer_active` or
`store_writer_unverifiable` reason and never reads, unlinks or binds the
socket path. The daemon opens the root with `recover_stale_writer: true`,
explicitly, because that option defaults to `false` in both
`Loopex.Store.Local` and `LoopexComposition` and a daemon that did not ask for
it could never restart after being killed. Asking for it is not asking to
ignore a holder: the adapter reclaims the marker only where it probes the
recorded holder and finds it dead, leaves it in place with
`store_writer_unverifiable` where the holder cannot be decided, and refuses
with `store_writer_active` where the holder is alive. All three are proved
before the socket path is read, unlinked or bound. Only the marker holder may remove a stale `daemon.sock` left by
a dead daemon and bind a new one, so two simultaneous starts on one root
resolve at the marker, exactly one listener exists, and the loser exits
without touching the socket.

**Removing the pathname is the successor's job, not the predecessor's**, and
that follows from the same rule read in the other direction. A daemon's claim
on the path is its marker, so the claim ends when the marker does — which can
happen without the daemon being asked, since the Store releases the marker in
its own `terminate/2`. A daemon therefore unlinks only while it can still show
it holds the marker, and one that has lost it, or cannot show it, leaves the
file. Nothing is lost by that: the next daemon to acquire and verify the
marker removes the stale pathname before binding, which is the one moment at
which removing a socket file is unambiguously correct. If the daemon loses store ownership while
running, because its Store child exits or the marker can no longer be
proved held, it closes the listener and every connection before anything
else and then exits; no connection outlives the daemon's ownership of the
root.

Framing, the initialize handshake, admission records, snapshot,
event and progress records, the frame ceiling, the strict UTF-8/LF rule and
the unknown-field rule are reused from ADR 0023 unchanged. **Request records
are the one exception**, and they are reused with one addition rather than
unchanged: every existing-session mutation in generation 2 carries
`writer_epoch`. That is the addition, and it is the reason generation 2 needs
a schema digest of its own. A connection is
one attachment after `session.attach`; generation 2 permits a connection to
hold at most one attachment at a time and a client process to hold as many
connections as the residency limits admit.

The core EventDispatcher and Control retain multiple live attachment IDs and
incarnations for one session. A new distinct attachment does not implicitly
detach another session attachment or cancel its pending read. Repetition of
the same attachment request returns its live attachment; explicit replacement
invalidates only the named prior incarnation at its last emitted cursor.
Snapshot barriers, queued durable delivery, stale-handle checks and detach
remain core operations. The daemon neither copies the snapshot into a second
fan-out owner nor reads coordinator state to repair an attachment race.

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
stable reason rather than letting either stage grow. No byte limit is
enforced inside core.

### Generation 2 additions

| Method | Required fields | Result |
| --- | --- | --- |
| `session.list` | `limit` (1 to 256), optional `after_session_id` | A page of at most `limit` index entries ordered by session ID bytes ascending and starting strictly after `after_session_id`; each entry carries the session identity, the placement identity recorded for it, `residency` of `active` or `dormant`, and `controlled` as a boolean, never content and never durable session state; `next_after_session_id` is present exactly when more entries exist, and `index_full` is present and true exactly when the index is at its 4,096-entry ceiling, so a client is told the listing may be incomplete rather than reading an omission as an absence |
| `daemon.status` | none | Placement identity, daemon incarnation, socket path, attachment, active-session and index counts against their limits, uptime |
| `session.acquire_control`, `session.release_control` | `session_id`, `request_id` and the lease fields ADR 0033 fixes | Lease result naming the writer epoch and the remaining lease term |

Generation 2 also adds **one notification record family**, `daemon.stopping`,
which no client requests and every client may receive:

| Field | Value |
| --- | --- |
| `reason` | One of `operator_stop`, `store_lost`, `store_capacity_exceeded`, or `fatal:<class>` for the remaining classes the plan's fatal-class map names, one per linked component: `fatal:runtime_lost`, `fatal:transfers_lost`, `fatal:workspace_lease_lost`, `fatal:executor_lost`, `fatal:registry_lost`, `fatal:custody_lost`, `fatal:relay_lost`, `fatal:listener_lost`. A lease owner's death is not among them: it closes one session's controller attachment with `control_owner_lost` and ends no daemon. The startup classes carry no reason, because no socket exists when they occur, and neither does `owner_lost`, where the process that would write it is the one that is gone |
| `message` | A bounded non-secret sentence for an operator to read |
| `retry_after_ms` | Present only for `operator_stop`, where a restart is expected; absent for every fatal reason, because the daemon does not know when the cause will be fixed |

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

**This changes the generation-2 digest, and so do the error codes.**
`LoopexProtocol.Session.schema_digest/0` is taken over the generation, the
ordered methods, the ordered record families, the ordered error codes and the
limits — five inputs, and generation 2 changes four of them:

| Digest input | Generation 2 |
| --- | --- |
| Generation | New string |
| Methods | Adds `session.list`, `daemon.status`, `session.acquire_control`, `session.release_control` |
| Record families | Adds `daemon.stopping` |
| **Error codes** | Adds every refusal generation 2 can return and generation 1 cannot: `control_held`, `control_pending`, `control_owner_lost`, `session_dormant`, the four existence-query refusals the daemon maps to the wire (`session_unknown`, `session_id_invalid`, `store_unavailable`, `existence_indeterminate`), and the activation and residency refusals (`activation_ceiling_reached`, `session_index_too_large`, `composition_mismatch`) |
| Limits | Unchanged from ADR 0023's ceilings |

**`control_owner_lost` closes a controller whose lease owner died.** ADR 0033
makes a lease owner's failure session-scoped: the daemon closes that session's
controller attachment, leaves its observers attached, and lets the next
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

Listing the error codes matters because it is the input most easily forgotten:
a refusal reason invented at implementation time and not entered in the
ordered list would make the served contract differ from the digest the server
advertises, which is exactly the drift the digest exists to catch. The
generation-2 literal the conformance module pins is the digest of the contract
*including* all four changes, and a build missing any of them computes a
different value and fails there. Generation 1's digest is untouched, since
generation 1 gains no method, no record family and no error code.

### The session index, and what it may claim

`session.list` reads a daemon-owned index, never the session directory or the
store on the request path. What the index *is* follows from what it is built
from. `Loopex.SessionDirectory` holds plain files beside the log and states
that neither is Store durable truth; a host records an entry after
`create_session/3` commits, and that write can fail on its own — the reference
CLI reports exactly that failure to the operator. So there is a real crash cut
between a committed session and its directory entry, and a daemon rebuilt from
the directory can be missing a session the Store holds.

The index therefore claims only what it can keep true, and each field is one
the daemon itself owns or reads once:

- `session_id` and the recorded placement identity, read from the directory
  entry at daemon start, or written when the daemon first activates a session
  the directory does not hold;
- `residency`, a daemon fact meaning *this daemon activated this session in
  this lifetime*, set to `active` at activation and never set back, because
  activation is one-way. It is not a claim about a live coordinator;
- `controlled`, a daemon fact, updated on every lease grant, release and
  expiry by the same lease owner ADR 0033 gives those transitions.

**`residency` says what the daemon knows, not what core is doing.** Its two
values mean exactly:

- `active` — **this daemon activated this session during this lifetime**;
- `dormant` — it has not.

That is a daemon-owned fact, recorded by the daemon at the moment it acted,
and it is **true by construction**: nothing else has to hold for it to stay
accurate, and no other process has to tell the daemon anything.

An earlier draft defined `active` as "the daemon holds a live coordinator",
which is a claim about core's state that the daemon has no way to keep
current, and then paid for it with a rule that took the whole daemon down when
a coordinator died. Both are withdrawn. The reason the first was untenable is
in the code: a coordinator is a `restart: :temporary` child of core's
`DynamicSupervisor`, and when one goes down `Loopex.Runtime.Control` consumes
the `DOWN`, releases the dispatcher fence and returns without altering the
session entry. No notification leaves core, and none is owed — that is core
minding its own supervision.

**So a dead coordinator is surfaced by core's own refusal, not by the index.**
A client that sends the next command for that session gets core's existing
refusal, and the daemon forwards it unchanged, adding nothing and interpreting
nothing. The client learns at the moment it matters, from the component that
knows, and the listing never claimed otherwise: `residency: active` said this
daemon activated the session, which remains true. The activation ceiling still
counts activations per daemon lifetime, for the same reason — it counts what
the daemon did.

Two alternatives were rejected, and both would be **a further core change**
beyond the four this milestone makes. A lifecycle notification from core to the daemon
would be a new core-to-host signal, with its own delivery and ordering
questions, added for a listing field. A monitorable coordinator handle handed
out to the daemon would export core's supervision topology across the boundary
and invite the daemon to reason about it. M5's core changes stay at four, and
neither of these is among them.

The lease-owner fatal rule in ADR 0033 is untouched by this and stays. The
difference is ownership: a lease owner is a **daemon** process holding
daemon-only state that nothing can reconstruct, so losing it is the daemon's
failure to handle; a coordinator is core's, supervised by core, and its loss
is core's to report.

Lineage, lifecycle state and last committed sequence are deliberately absent.
A daemon index cannot keep them current without reading the Store on the
request path or subscribing to every session it is not holding, and a field
that is silently stale is worse than an absent one; a client that needs them
attaches, and the snapshot carries them at a committed sequence.

**The recovery procedure for the crash cut**, in four parts, needing no new
durable record and no Store read by the daemon:

1. **Durable existence is learned from core, through a query that asks only
   that.** The daemon never reads Store internals and never enumerates the log
   to decide whether a session exists. It calls core's read-only
   session-existence query on the ID — no attach, no resume, no side effect,
   a plain-data answer — and treats core's answer as the proof.

   An earlier draft had the daemon learn existence from `attach` or `resume`
   themselves. The maintainer rejected that on 2026-09-20 and admitted the
   query instead. Asking a question by performing the operation is not a
   question: `attach` establishes a cursor barrier and an attachment
   incarnation, `resume` is a durable mutation under ADR 0008's placement
   rules, and a daemon that had to run one of them to discover that a session
   does not exist would be taking a side effect to learn a fact — worst of all
   at `acquire_control`, which must validate existence *before* granting a
   lease and must be safe to call on an ID that turns out to be unknown.

   **The query's result set is closed, and only one member is a yes.** "A
   plain-data answer" is not a contract on its own — a caller has to know what
   it may receive and what each result obliges it to do, especially a caller
   about to grant authority on the strength of it. The query answers exactly
   one of:

   | Result | Means | What the daemon does |
   | --- | --- | --- |
   | `present` | The root holds this session durably | Proceed: acquire may be granted, activation may follow |
   | `absent` | The root does not hold it, and core is certain of that | Refuse, naming the session as unknown |
   | `invalid_id` | The argument is not a well-formed session identifier | Refuse as an invalid argument, before anything is looked up |
   | `store_unavailable` | Core could not read the root to decide | Refuse, naming the store as unavailable — **not** as an unknown session, because those are different facts and an operator acts on them differently |
   | `unexpected` | Anything else, including a result shape the daemon does not recognise | Refuse, the same way as `store_unavailable`, because an answer that cannot be interpreted is not a yes |

   **Control acquisition proceeds only on `present`.** Every other result
   fails closed and identically in what it leaves behind: no attachment, no
   lease, no activation, no index row, nothing created. What differs is only
   what the client is told, and the client is always told which — a refusal
   that said "unknown session" when the store was unreadable would send an
   operator looking for a session that exists.

   Nothing about the index is consulted to decide existence, which is why an
   index that is incomplete is not a correctness problem, and the daemon still
   reads no Store internals.

   Each of the five results is a witness: `present` granting, `absent`,
   `invalid_id`, `store_unavailable` injected through the suite's controllable
   fault store rather than by making the root unreadable — `Loopex.Store.Local`
   answers `ownership_head` from memory, so an unreadable root does not produce
   that result —
   and `unexpected` injected by a stub that answers outside the set. All five
   assert the same absence afterwards — no attachment, no lease, no activation
   — and assert that the four refusals name distinct reasons.
2. **A client that never saw the session ID recovers by command identity, and
   the sequence is written out here rather than left as a gesture.** At the
   cut where the Store committed the creation and the process died before the
   reply, the client holds no session ID at all — only the `command_id` it
   chose for its own `session.create`. Every step below uses something the
   client already has or something already durable:

   | Step | Who acts | What happens |
   | --- | --- | --- |
   | 1 | Client | Reconnects to the daemon and re-presents `session.create` with **the same `command_id`** it used before. It knows no session ID, so it cannot ask for one |
   | 2 | Daemon | Forwards it as an ordinary create. It does not consult the index, which by construction may not hold this session |
   | 3 | Core | Recognises the command identity as already resolved and returns the **historical result** — the same session ID it committed before — rather than creating a second session. This is the command idempotency the resume path already relies on, not a new mechanism |
   | 4 | Client | Now holds the session ID for the first time. **No coordinator is running for it** — see below |
   | 5 | Daemon | Validates durable existence with the read-only existence query on that ID, which answers `present` because the Store committed it in the first place |
   | 6 | Daemon | Repairs what is missing: writes the directory entry and adds the index row, so every later `session.list` shows the session. If that write fails, step 3 of this procedure applies |
   | 7 | Client | Acquires control, receiving the writer epoch |
   | 8 | Client | Sends `session.resume` with a **fresh resume `command_id`** and that writer epoch. This is the step that activates the session: it is a new command, not a replay, because the create's identity is spent |
   | 9 | Daemon | Activates the session — a live coordinator now exists — and counts it against the activation ceiling |
   | 10 | Client | Attaches and drives |

   **Step 8 is the one an earlier draft left out, and without it the recovery
   ends with nothing running.** Replaying a completed create does not start a
   coordinator: `Loopex.Runtime.Control.create_session/4` resolves the
   transaction, sees the command was already resolved, and replies `{:ok,
   session_id}` on the `not fresh?` branch *without* calling `start_owner`.
   That is correct — a replay must not create a second owner — but it means
   steps 1 to 4 return an identity and nothing more. The session is durable
   and idle. `session.resume`, with its own fresh command identity and under
   the lease acquired at step 7, is what brings it back, and the sequence is
   only a recovery once it reaches there.

   Steps 5 and 6 turn the recovery into a repair: the session is not merely
   reachable once, it stops being missing. A client that *does* still hold the
   session ID skips steps 1 to 4 and enters at step 5.

   **Its witness.** One case injects the exact cut — Store commit of the
   create followed by process death before the directory write and before the
   reply — then, from a client that never received the session ID, replays
   `session.create` with the original `command_id` and runs the sequence to
   the end. It asserts: exactly one session exists in the root; the returned
   ID equals the committed one; the replay itself started no coordinator; the
   existence query answers `present`; the directory entry and index row are
   present afterwards and the session appears in `session.list`; the resume
   under the granted epoch activates it, so a **live coordinator exists** and
   the activation count has risen by one; and a prompt sent afterwards lands
   on that session and produces its events, rather than on a second session or
   on nothing at all.
3. **Recording can fail, and says so.** If writing the directory entry fails
   during activation, the failure is reported to the client that triggered it,
   as an explicit warning that this session will not appear in `session.list`
   — the reference CLI already reports exactly that failure today. The
   activation itself succeeds, the session is fully usable, and the daemon
   **retries while it still holds the ID**, which is the only time it can:

   - immediately after activation, once;
   - on each later command for that session, since the daemon has the ID in
     hand at that moment anyway and the retry costs one file write it already
     knows how to make;
   - and when any later client reaches the session by ID, or replays its
     create command, since both paths put the ID back in the daemon's hands.

   The retry stops as soon as it succeeds. Two earlier answers were wrong and
   both are withdrawn. "At the next activation of that session" cannot happen:
   activation is one-way, so within a lifetime there is no second one. "At the
   next daemon start" cannot happen either, and for a sharper reason — a
   restarted daemon builds its index *from the directory*, so a session the
   directory does not hold is a session the new daemon has never heard of. It
   has no ID to retry with. Only a live daemon that still holds the ID can
   repair the gap, which is why the retry is bound to the moments it does.

   Until it succeeds, the session is reachable by ID and absent from
   `session.list`, which is exactly what the client was told.
4. **A full index still activates.** If the index already holds 4,096 entries
   and a client reaches an unrecorded session by ID, the session is activated
   and is **not** recorded. Reachability never depends on the ceiling. What
   changes is the listing's honesty: `session.list` then carries `index_full`,
   so an operator is told the listing is incomplete rather than reading a
   silent omission as an absence.

`session.list` is documented as *the sessions this root records*, not *the
sessions this root contains*, and the operator documentation states all four
parts, because an operator who lost a terminal mid-creation is exactly who
meets them.

A page is consistent with the index at the moment it is read, and no
consistency is promised across pages. What that can actually produce is
narrower than an earlier draft claimed, because the index is append-only
within a daemon's lifetime and keyed by unique session ID: rows are added,
never removed and never renumbered, and ordering is by session ID bytes. So a
session recorded between two page reads may be **missed** — if its ID sorts
before the cursor the client has already passed — and that is the only
anomaly paging can show. A row cannot vanish between pages and cannot be
returned twice, because nothing deletes a row and no two rows share an ID. A
client that needs a complete view pages again from the start; deduplication is
unnecessary here, though a client that deduplicates by session ID loses
nothing. A `limit` outside 1 to 256 or an `after_session_id` that is not
a well-formed session ID refuses with the existing invalid-argument reason; an
`after_session_id` naming an unknown session is admitted and pages from its
byte position.

### Session residency: active, dormant, and their bounds

A session is **active** when this daemon activated it in this lifetime and
**dormant** when the index records it and this daemon has not. Nothing durable
distinguishes the two, and neither is a claim about a live coordinator: both
are daemon facts, recorded when the daemon acted.

A dormant session costs less than an active one, but not nothing, and the
plan should not pretend otherwise. It holds one index row against the
4,096-entry ceiling, and its history sits in the root's single append-only log
against the 256 MiB capacity that every session in the root shares — so a
dormant session still consumes the two resources whose exhaustion stops the
daemon, and retiring a root is what actually frees them. What it costs nothing
in is the things activation buys: no coordinator, no replay at start, no
attachment, no window, no buffer.

**Activation is one-way for the daemon's lifetime.** A session the daemon has
activated keeps its coordinator until the daemon exits. Dormancy is *not*
deactivation, and the daemon has no operation that stops a coordinator.

That is a correction, not a simplification. An earlier draft let an idle
session "go dormant, releasing its slot", which is wrong twice over. The idle
condition it named — no attachment and no admitted command — is not the same
question as whether work is running: a session with every client detached can
still have a model request in flight, a tool effect dispatched, an interaction
awaiting an answer, a recovery in progress, an unresolved `commit_unknown`, or
an admission executing inside core. Stopping it would destroy exactly what
Outcome 1 exists to prove, that work progresses with zero attachments. And
there is no operation to stop one with: core owns coordinator lifetime, and
none of M5's four core changes (concurrent attachment, the read-only existence
query, the excluded-function trace list, and `quiesce/2`) stops a coordinator,
so a deactivation call would be a further core change this milestone does not
make.

- **What dormancy applies to.** Attachments, resident windows and socket
  output buffers, and nothing else. An idle attachment is evicted, its window
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
- **Activation ceiling.** At most 64 sessions are activated **per daemon
  lifetime**, not at once, because nothing gives a slot back. The 65th
  activation refuses with a stable reason naming the ceiling and the remedy,
  which is to restart the daemon. That is a real limitation rather than a
  design, it is recorded as one in the plan and in the operator page, and it
  is the honest cost of leaving coordinator lifetime alone in M5. Lifting it
  needs a core deactivation operation that can tell "quiescent" from "idle",
  which is a decision of its own.
- **Index bound.** The index holds at most 4,096 **recorded** entries. A root
  whose session directory holds more refuses at daemon start with a stable
  reason naming the bound and pointing at root retirement, in the same posture
  as `store_log_too_large`: refuse rather than serve a truncated view of what
  the root records. The ceiling is on recorded entries only, and it never
  makes a session unreachable — see the crash cut below.
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
1's, and generation 1's literal digest, schema-file digest and vectors-file
digest are asserted unchanged in the same place, so an accidental edit to
generation 1's contract fails there rather than silently renaming what
existing clients agreed to. The generation-2 schema and its
vectors are new files beside generation 1's, as
`apps/loopex_protocol/priv/schema/loopex-experimental-2.json` and
`apps/loopex_protocol/priv/vectors/loopex-experimental-2.json`, reviewed with
the change that adds them, and **each carries its own pinned file digest**
written into the conformance module beside the two generation 1 already pins —
so an independent client can fetch either file and verify its bytes, and an
edit to a generation-2 file fails the same way an edit to a generation-1 file
does. The digests are computed and pinned when the files are written;
generation 1's bytes and its two pinned digests are untouched. A
negotiation vector proves selection from a list that also names generation 1
and refusal of a generation-1-only list. The M4 foreground server keeps
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
  When the daemon's aggregate encoded-byte ceiling would be exceeded, windows
  are released in this fixed order: first every window whose session has zero
  attachments, in ascending order of the monotonic time of their last
  delivery, ties broken by session ID bytes ascending; then, if the ceiling is
  still exceeded, the window of the session whose slowest attachment is
  furthest behind **by encoded bytes owed** — the sum of encoded bytes for
  events core has named for that attachment and the daemon has not yet
  written, which is a daemon-owned quantity comparable across sessions because
  it is measured in bytes rather than in each session's own sequence numbers.
  A sequence-distance metric would not be comparable: sequence numbers are
  per-session and say nothing about how much memory an attachment is costing.
  Ties break by session ID bytes ascending. Each step is **repeated until the
  aggregate is below the ceiling**, not applied once: releasing one window may
  not be enough, so zero-attachment windows are released in that order until
  either the aggregate fits or none is left. Only when none is left does the
  daemon detach the slowest attachment at its last emitted cursor, and that
  too repeats until the aggregate fits. Independently of pressure, a window whose session has had zero
  attachments for the idle interval is dropped. No reclamation stalls a
  journal transaction and none changes what any client is owed.

  On the local adapter every durable event is retained until the root is
  retired, so store replay always succeeds. `cursor_expired` with a fresh
  snapshot and cursor is the defined response a compacting adapter returns for
  a cursor older than its retained history; no M5 witness can produce it and
  none claims to;
- the core event-count queue and the daemon socket output buffer above; when
  the next event would exceed either, the attachment is detached at its last
  completely emitted cursor with a stable reason and the client reconnects
  at that cursor;
- at most 512 MiB of retained encoded events across the daemon's output
  buffers and resident windows; on aggregate pressure, evict or detach the
  slowest eligible attachment before admitting more bytes, without stalling
  a journal transaction;
- 64 attachments per session and 512 per daemon, refused at attach with a
  stable reason when exhausted;
- eviction of an attachment that has consumed nothing for ten minutes; the
  eviction record names the cursor the client may resume from;
- transient progress coalesced per attachment and dropped first under
  pressure, with a counted drop; no progress item ever waits on a journal
  transaction.

A detached, evicted or reconnecting client that attaches at its retained
cursor receives every durable event after that cursor at least once and in
order; it never receives a gap, and it deduplicates by session ID, event
sequence and event ID.

### Evidence

Tests prove: two core attachments to one session keep independent live handles,
snapshots and cursors with no implicit replacement; an explicit replacement
invalidates only its named incarnation; snapshot-then-contiguous at-least-once
delivery with no gap across the window boundary; the same delivery cases run
again with the resident window disabled, byte for byte identical, and with the
window dropped mid-stream, proving the cache establishes nothing; deterministic
reclamation in the fixed order above, including the case where zero-attachment
windows alone consume the aggregate ceiling and are released before any
attachment is detached; a slow observer detached at
its last emitted cursor while the controller and other attachments continue;
the per-session and per-daemon limits refusing independently; idle eviction
and reconnect with no missing durable event and any duplicate deduplicated by
session ID, sequence and event ID; the three encoded-byte ceilings at maximum
attachment count and payload pressure enforced in the daemon-owned stages,
with process RSS observed and reported separately; a generation-1-only
initialize refused with `unsupported_generation` and nothing created;
simultaneous daemon starts on one root leaving exactly one listener with the
loser never touching the socket; Store-child failure closing the listener and
every connection before exit; `session.list` pages of at most 256 entries in
session-ID order with an exact continuation cursor, carrying only the four
fields above; a session committed to the Store whose directory entry was never
written — injected at exactly that cut — absent from the listing, still
reachable by ID, and present in every listing after the activation that
records it; a restarted daemon activating nothing until a client reaches for a
session; a detached long-running command and a pending admission each crossing
the idle deadline with every client gone and running to completion, so
dormancy is proved to release attachments and never a coordinator; the
activation ceiling refusing the 65th activation of a daemon lifetime with its
stable reason and restart remedy; a root whose directory holds more than the
recorded-entry bound refusing at start with its stable reason; at that bound a
session reached by ID activated, not recorded, and the listing carrying
`index_full`; a client that never saw a session ID recovering it through the
create command's durable `command_id`; a directory write failing at activation
reported to that client, the session still usable, and the record written by
the retry the next time the live daemon holds that ID — right after
activation, on a later command for the session, or when a client reaches it by
ID; a
recorded session the current composition cannot serve refused at activation by
name while every other session in the root activates; progress coalescing under
pressure with counted drops and no journal delay; peer-credential refusal; a
socket path beyond the bound refused at start; frame, fragment and
malformed-input refusals identical to the foreground server's.

### Alternatives

TCP on loopback was rejected for the local daemon: it has no peer-credential
check and invites remote exposure by misconfiguration; WebSocket and HTTP
remain later transports under vision §18.8. An unbounded per-attachment queue
was rejected because it lets one client grow coordinator-adjacent memory
without bound. Keeping the M4 one-attachment-per-process rule was rejected
because a daemon's clients are processes by definition. A daemon-owned proxy
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
above is the cost of keeping it.

<a id="technical-adr-0032-compatibility"></a>
### Compatibility and Rollback Mechanics

Concept: [Consequences and rollback](0032-daemon-attachment-residency-and-replay.md#concept-adr-0032-consequences).

Generation 2 is additive over generation 1's method set and both are
experimental with the exact-generation rule; no mixed-generation stream
promise exists. The daemon serves generation 2 only; the existing foreground
server still serves generation 1 with one attachment in its process. The
residency limits are server-enforced ceilings advertised at initialize under
the existing `limits` member. Removing the daemon leaves the foreground server
unchanged; existing embedded callers retain their behavior, and the core
supports independent same-session attachments. No durable record depends on
residency state or on the session index.

Acceptance binds this complete pair at the exact candidate the maintainer
names in the governance record. Its evidence and compatibility claims remain
unproved until the tests the M5 plan maps to outcomes 2 and 4 exist and pass.
