<a id="technical-depth"></a>
## Technical depth

Concept: [Daemon attachment residency and replay](0032-daemon-attachment-residency-and-replay.md#concept).

<a id="technical-adr-0032-decision"></a>
### Contract and Evidence

Concept: [Context and decision](0032-daemon-attachment-residency-and-replay.md#concept-adr-0032-decision).

### Transport

The daemon listens on one Unix-domain socket. Its path is
`<state root>/daemon.sock` by default and may be set explicitly; a path
longer than the platform's socket-address bound (104 bytes on Darwin, 108 on
Linux) is refused at start with `socket_path_too_long` naming the bound, never
truncated. The socket file is created with owner-only permissions and the
daemon reads the connecting peer's credentials; a peer whose user identity
differs from the daemon's is closed before any frame is read. A stale socket
file left by a dead daemon is removed only after the writer marker proves the
previous holder gone, using the same liveness probe the local store uses.

Framing, the initialize handshake, request and admission records, snapshot,
event and progress records, the frame ceiling, the strict UTF-8/LF rule and
the unknown-field rule are exactly ADR 0023's. A connection is one attachment
after `session.attach`; generation 2 permits a connection to hold at most one
attachment at a time and a client process to hold as many connections as the
residency limits admit.

The core EventDispatcher and Control retain multiple live attachment IDs and
incarnations for one session. A new distinct attachment does not implicitly
detach another session attachment or cancel its pending read. Repetition of
the same attachment request returns its live attachment; explicit replacement
invalidates only the named prior incarnation at its last emitted cursor.
Snapshot barriers, queued durable delivery, stale-handle checks and detach
remain core operations. The daemon neither copies the snapshot into a second
fan-out owner nor reads coordinator state to repair an attachment race.

### Generation 2 additions

| Method | Required fields | Result |
| --- | --- | --- |
| `session.list` | none | Bounded page of session identities with lineage, lifecycle state, last committed sequence and controller presence; never content |
| `session.stop` | `session_id`, `command_id`, `writer_epoch` | Admission of a durable stop under the current controller; observers refuse |
| `daemon.status` | none | Placement identity, socket path, format version, attachment and session counts against their limits, uptime |
| `session.acquire_control`, `session.release_control` | `session_id`, `request_id` and the lease fields ADR 0033 fixes | Lease result naming the writer epoch |

The client supplies its ordered supported generations in `initialize`; the
daemon selects the first generation in that client order it supports and
returns one `selected_generation`, its exact schema digest, method inventory
and limits as ADR 0023 requires. A client that negotiates generation 1
receives the generation-1 method inventory and every generation-2 method
refuses as unknown for that
connection. The generation-2 schema and vectors are canonical bytes bound by
the M5 gate before acceptance; a negotiation vector proves client-order
selection and the generation-1 fallback.

The daemon admits a generation-1 attachment only when the session has no other
attachment of either generation and no other unexpired held lease. It refuses
any later attach of either generation while a generation-1 lease remains held,
even if its connection has gone and expiry is pending. A generation-1 attach
also refuses while a generation-2 lease remains held after its connection
goes. These are `attachment_conflict` errors under the existing generation-1
error vocabulary. The attachment and internal lease grant are serialized as
one daemon operation. A successful generation-1 attach is the sole controller
connection under ADR 0033's internal lease; it cannot gain an observer peer or
a second controller by opening another connection. At internal lease expiry,
the daemon atomically detaches a still-connected generation-1 client and
fences its commands before any successor lease or attachment is admitted.
Generation-1 frames and the M4 foreground process limit do not change.

### Attachment lifecycle

Attach is the runtime's race-free cursor transaction: the dispatcher
establishes the barrier at committed sequence N, the snapshot is anchored at
exactly N, and durable events after N are buffered for that attachment and
delivered contiguously after the snapshot. The daemon adds:

- a resident window of at most 4,096 durable events and 16 MiB of encoded
  events per session held in memory; a cursor inside the window replays from
  memory, a cursor older
  than the window replays from the store, and a cursor older than retained
  store history returns `cursor_expired` with a fresh snapshot and cursor;
- a bounded queue of 1,024 undelivered durable events and 4 MiB of encoded
  events per attachment; when the next event would exceed either ceiling,
  the attachment is detached at its last completely emitted
  cursor with a stable reason and the client reconnects at that cursor;
- at most 512 MiB of retained encoded events across the daemon's attachment
  queues and resident windows; on aggregate pressure, evict or detach the
  slowest eligible attachment before admitting more queued bytes, without
  stalling a journal transaction;
- 64 attachments per session and 512 per daemon, refused at attach with a
  stable reason when exhausted;
- eviction of an attachment that has consumed nothing for ten minutes; the
  eviction record names the cursor the client may resume from;
- transient progress coalesced per attachment and dropped first under
  pressure, with a counted drop; no progress item ever waits on a journal
  transaction.

A detached, evicted or reconnecting client that attaches at its retained
cursor receives every durable event after that cursor once and in order, or
`cursor_expired`; it never receives a gap.

### Evidence

Tests prove: two core attachments to one session keep independent live handles,
snapshots and cursors with no implicit replacement; an explicit replacement
invalidates only its named incarnation; snapshot-then-contiguous delivery
with no gap across the window boundary; `cursor_expired` beyond retention; a
slow observer detached at its last emitted cursor while the controller and
other attachments continue; the
per-session and per-daemon limits refusing independently; idle eviction and
reconnect with no duplicate or missing durable event; the three encoded-byte
ceilings at maximum attachment count and payload pressure, with process RSS
observed and reported separately; idle connected generation-1 lease expiry
detaching and fencing before generation-2 takeover or attach; progress coalescing
under pressure with counted drops and no journal delay; peer-credential
refusal; a socket path beyond the bound refused at start; frame, fragment and
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
subscribe/snapshot race. Allowing concurrent generation-1 daemon connections
was rejected because their wire has no controller lease field.

<a id="technical-adr-0032-compatibility"></a>
### Compatibility and Rollback Mechanics

Concept: [Consequences and rollback](0032-daemon-attachment-residency-and-replay.md#concept-adr-0032-consequences).

Generation 2 is additive over generation 1 and both are experimental with the
exact-generation rule; no mixed-generation stream promise exists. A
generation-1 daemon client may attach only to a session with no other
attachment or unexpired held lease; the existing foreground server still
admits one attachment in its process. The residency limits are server-enforced
ceilings advertised at initialize under the existing
`limits` member. Removing the daemon leaves the foreground server unchanged;
existing embedded callers retain their behavior, and the core supports
independent same-session attachments. No durable record depends on residency
state.

Acceptance binds this complete pair at an exact candidate. Its evidence and
compatibility claims remain unproved until the M5 gate's required paths execute.
