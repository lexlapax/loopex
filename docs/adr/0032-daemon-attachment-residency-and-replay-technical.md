<a id="technical-depth"></a>
## Technical depth

Concept: [Daemon attachment residency and replay](0032-daemon-attachment-residency-and-replay.md#concept).

<a id="technical-adr-0032-decision"></a>
### Contract and Evidence

Concept: [Context and decision](0032-daemon-attachment-residency-and-replay.md#concept-adr-0032-decision).

### Transport

The daemon listens on one Unix-domain socket. Its path is
`<state root>/daemon.sock` by default and may be set explicitly.

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
filesystem.** The socket lives in a directory the daemon owns with mode
`0700`, and the socket itself is created mode `0600`; both are verified after
bind by reading back their owner and mode and comparing them with the daemon's
own effective user, and the daemon refuses to serve if either is wrong, if the
parent is not owned by that user, or if any component of the path is a
symbolic link it did not create. That is what actually keeps another user out:
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
without touching the socket. If the daemon loses store ownership while
running, because its Store child exits or the marker can no longer be
proved held, it closes the listener and every connection before anything
else and then exits; no connection outlives the daemon's ownership of the
root.

Framing, the initialize handshake, request and admission records, snapshot,
event and progress records, the frame ceiling, the strict UTF-8/LF rule and
the unknown-field rule are reused from ADR 0023 unchanged. A connection is
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
| `session.list` | `limit` (1 to 256), optional `after_session_id` | A page of at most `limit` index entries ordered by session ID bytes ascending and starting strictly after `after_session_id`; each entry carries the session identity, the placement identity recorded for it, `residency` of `active` or `dormant`, and `controlled` as a boolean, never content and never durable session state; `next_after_session_id` is present exactly when more entries exist |
| `daemon.status` | none | Placement identity, daemon incarnation, socket path, attachment, active-session and index counts against their limits, uptime |
| `session.acquire_control`, `session.release_control` | `session_id`, `request_id` and the lease fields ADR 0033 fixes | Lease result naming the writer epoch and the remaining lease term |

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
- `residency`, a daemon fact, updated on every activation and every transition
  to dormant;
- `controlled`, a daemon fact, updated on every lease grant, release and
  expiry by the same per-session owner ADR 0033 gives those transitions.

Lineage, lifecycle state and last committed sequence are deliberately absent.
A daemon index cannot keep them current without reading the Store on the
request path or subscribing to every session it is not holding, and a field
that is silently stale is worse than an absent one; a client that needs them
attaches, and the snapshot carries them at a committed sequence.

The recovery procedure for the crash cut is explicit and needs no new durable
record. A session absent from the index is still reachable by its ID: a client
that knows the ID acquires control and resumes it, the Store answers because
the Store is the authority, and the daemon records the directory entry as part
of that activation, so the session appears in every later listing. The
operator documentation states this, because an operator who lost a terminal
mid-creation is exactly who meets it. `session.list` is documented as *the
sessions this root records*, not *the sessions this root contains*.

A page is consistent with the index at the moment it is read; no consistency
is promised across pages, so a session created or dropped between pages may
appear in neither or both, and a client that needs a stable view deduplicates
by session ID. A `limit` outside 1 to 256 or an `after_session_id` that is not
a well-formed session ID refuses with the existing invalid-argument reason; an
`after_session_id` naming an unknown session is admitted and pages from its
byte position.

### Session residency: active, dormant, and their bounds

A session is **active** when the daemon holds a live coordinator for it and
**dormant** when the index records it and the daemon does not. Nothing durable
distinguishes the two; dormancy is a daemon fact and costs a dormant session
nothing.

- **Lazy recovery.** A restarted daemon activates no session. It acquires the
  writer marker, reads the index, binds the socket, and activates a session
  the first time a client attaches to, acquires control of or resumes it.
- **Active-session ceiling.** At most 64 sessions are active at once per
  daemon. A session that has had no attachment and no admitted command for the
  idle interval goes dormant, releasing its slot. An activation that would
  exceed the ceiling while every active session is still in use refuses with a
  stable reason naming the ceiling; it never evicts a session that a client is
  driving or watching.
- **Index bound.** The index holds at most 4,096 entries. A root whose session
  directory holds more refuses at daemon start with a stable reason naming the
  bound and pointing at root retirement, in the same posture as
  `store_log_too_large`: refuse rather than serve a truncated view of what the
  root records.
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
the change that adds them; generation 1's bytes are untouched. A
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
  furthest behind, by the same tie-break. Only after every window has been
  released does the daemon detach the slowest attachment at its last emitted
  cursor. Independently of pressure, a window whose session has had zero
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
session; the active-session ceiling refusing an activation while every slot is
in use, and admitting one after a session goes dormant; a root whose directory
holds more than the index bound refusing at start with its stable reason; a
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
