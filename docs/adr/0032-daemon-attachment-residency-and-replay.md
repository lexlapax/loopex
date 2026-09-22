<a id="concept"></a>
## Concept

Technical depth: [Attachment residency mechanics](0032-daemon-attachment-residency-and-replay-technical.md#technical-depth).

- **Status:** Accepted
- **Date:** 2026-09-14
- **Decision owner:** Maintainer
- **Supersedes:** nothing; ADR 0023's one-attachment-per-foreground-process rule and generation-1 wire remain in force on the foreground server
- **Prerequisite for:** M5 outcomes 1, 2, 4 and 5, accepted before the socket is
  bound or the core attachment change lands — that is, before M5's workstreams
  1 and 3

<a id="concept-adr-0032-decision"></a>
### Context and Decision

The M4 foreground server maps one connection to one attachment in one
process that exits with the client. A daemon keeps sessions alive across
client processes, so it must answer what a client is owed when it attaches,
reconnects, falls behind or goes idle, and it must do that over a transport
that several processes on one machine can reach. The vision fixes the
semantics: attach is one race-free cursor transaction anchored at a committed
sequence; delivery of durable events is at least once and contiguous, so
duplicates are permitted and gaps are not, and a client deduplicates by
session ID, event sequence and event ID; a cursor older than a store's
retained history returns `cursor_expired` with a fresh snapshot instead of
truncating silently; a slow attachment is bounded and cannot block the
coordinator or another client; and a reconnecting client is owed complete
durable events and terminal outcomes, not every dropped progress fragment.

Decide the transport and the residency rules together, because the numbers
only mean something against a transport. The daemon carries the ADR 0023
JSONL protocol over a Unix-domain socket, reusing its framing, initialize
handshake, admission, snapshot, event and progress records and ADR 0023's
existing limit keys unchanged while adding the technical contract's exact seven
initialize-limit keys. The remaining residency ceilings are server-enforced and
reported through `daemon.status` where the contract says so. Its request records
have exactly one addition, the
`writer_epoch` every existing-session mutation carries. Request fields are not
inputs to the current schema-digest function; generation 2 has a distinct
digest because its generation, method, record-family, error-code and limit
inventories differ. It serves exactly one
generation,
`loopex.experimental/2`, which adds `session.list`, `daemon.status`, the two
control methods, the writer-epoch field ADR 0033 names, and **two**
notification record families: `daemon.stopping`, carrying the reason a daemon
is going away, and `daemon.notice`, carrying a bounded code for something an
operator should know about a session whose command nonetheless succeeded —
today, an activation whose persistent discoverability-index write failed.
The milestone that
brings this ADR also renames the released generation-1 string to
`loopex.experimental/1`, so the two generations are named on one scheme and
neither claims the `v1` the vision reserves for the stable protocol; that
rename is the plan's decision under the 0.x experimental policy, and its
consequence here is that generation 1's pinned **schema digest** is recomputed with
its new name while everything else about generation 1 stays as it is.

That record is a new record family, so it is part of what generation 2's
schema digest is taken over; its delivery is one bounded best-effort write
attempt into the connection's existing output buffer, after which the
connection closes whatever happened, so a client may learn of a shutdown only
by its socket closing. It adds no durable
method. An earlier draft of this decision also added `session.stop` and called
it durable; that is withdrawn, because core owns durable session truth, core
has no durable stop command, and M5's six core changes — the complete
concurrent-attachment lifecycle, a read-only existence-and-create-history
query surface, the trace exclusion, bounded `quiesce/1`, the create and resume
results' two new fields, and managed provider lifetime — are none of them
durable commands. The daemon's bounded maintained index is adapter state, not
another core change. Ending a client's involvement is releasing control and
disconnecting; the session itself keeps running, which is the point of a
daemon, and another client reaches it again by acquiring control and
attaching.

The bounded `quiesce/1` preserves the founding serial-writer rule from its
first census through its final fence. Its first `Control` operation atomically
enters a terminal quiescing state and returns the initial entries and ordinary
coordinators. That operation also freezes the entry key set until fencing is
complete: lifecycle messages may update a retained entry, but none may insert
or delete one, and delayed owner-ready or owner-group continuations may not
start another ordinary coordinator. Create and resume are serialized in that
same `Control` mailbox, so one already being handled finishes its Store work
and its entry-or-dormant decision before the barrier can run; every resulting
coordinator writer has an entry, while a post-commit owner-start failure is
dormant with no writer. One ordered after the barrier refuses before Store
access. Attach uses its pending-row reservation as the
cut: gate first refuses without dispatcher state, while reservation first lets
only that exact transaction finish or discard under its retained relay ticket
and capacity charge. For a command that obtained a route before the barrier, a
drain-specific coordinator call closes ordinary command admission in that
coordinator's mailbox before it proposes the abort. A command processed first
is included in the abort; one processed afterwards refuses, while internal
commit and recovery messages remain admissible. After every retained ordinary
coordinator is gone, core starts one temporary fence-mode
`SessionCoordinator` per frozen writer domain. `Control` retains the monotonic
set of session IDs for which a coordinator writer ever started and projects
only that set, bounded at 64, when quiesce begins. No-writer dormant entries are
outside the drain result and spawn no work. A drain abort uses a deterministic
`drain_abort` command and transaction ID derived from the session ID plus the
pre-admission owner epoch. The Store binds that identity to the exact journal
version, owner incarnation and canonical abort digest. If that abort is ambiguous, the
temporary coordinator resolves its exact ID before fencing: a committed result
is replayed, a terminal non-commit proceeds, an absent result is ordered against
the fresh fence CAS, and Store unavailability proposes no fence. A successor
resolves the bounded current-epoch and predecessor-epoch abort identities,
attributing a committed candidate only when replay carries the exact drain-abort
binding; a different committed binding is a client collision and no drain,
then uses its ordinary fresh owner CAS before admitting commands. The fence
transaction ID and proposed incarnation are deterministic from the session ID
and expected owner epoch. The Store still binds that identity to the exact
expected journal version and canonical mutation digest on first presentation.
Only the live fence operation re-presents those exact transaction bytes after
`commit_unknown`. After a crash, a successor reads the current epoch `E` and
resolves the bounded recoverable identities `drain_fence(E)` and, only when the
first is absent or proved to be a client collision, `drain_fence(E - 1)`. A
committed candidate counts as a fence only when replay carries the exact
owner-advance binding. Those cover a non-committing fence at the
current epoch and a committed fence that advanced it. Both absent means neither
identity that can represent the immediately unresolved stop is retained;
unavailable or an impossible result stays fail-closed. Only
after resolving that operation does the successor complete ordinary fresh
owner succession and admit commands.
The temporary
coordinator alone performs that resolution, the single
`advance_owner` and, on `commit_unknown`, one exact byte-identical
re-presentation of that fence transaction, then exits; the daemon
and quiesce helper never receive a Store handle or write session truth directly.

A client that offers only generation 1 is refused at initialize under
ADR 0023's existing no-common-generation rule and nothing durable is
created; generation-1 clients keep the M4 foreground server, whose wire,
one-attachment rule and behavior do not change. A narrow core change lets
distinct attachments to the same session coexist without replacing one
another, including several attachments owned by one embedded holder. Every
attachment has its own identity. Replacement therefore names the exact
`replace_attachment_id`; the target must belong to that holder and session,
and no boolean can choose among several candidates. The daemon still binds a
connection to at most one attachment, while embedded callers may hold a set.
The first attach or acquire tentatively reserves that connection's session
before asynchronous work begins. Every activation or attachment reservation is
bound to an exact relay origin before the one primary task starts; only an exact
repetition becomes a waiter, and it starts no second task. A different request
cannot borrow the same live replacement target while one replacement is
pending. When a connection ends, its accepted slot enters `closing`. The
registry remains responsive while a monitored worker asks core to release that
holder, and the slot stays charged until every bounded origin and request worker
is terminal and the cleanup worker has acknowledged and exited.
The foreground generation-1 and daemon generation-2 adapters translate their
existing per-connection `replace: true` onto the only attachment that each
connection may hold, so the wire remains unambiguous and ADR 0023 stays
unchanged. Core monitors the stable holder, removes all
of its attachments when it dies, and releases every transfer they opened as
ADR 0028 requires. Publication is irreversible for a named replacement, but
it does not resurrect a dead holder: if Control observes holder death before a
committed publication acknowledgement, it completes that transaction directly
to released, with no live route, after both owners acknowledge cleanup. An EventDispatcher-only restart is an attachment-generation
cut: Control clears every predecessor attachment and pending transaction,
seeds the replacement with its retained acknowledged event positions before
the dispatcher becomes ready, and rejects late predecessor messages. Old
handles become stale and embedded callers reattach; the replacement never
forgets a publication fence merely because its local map began empty. The core continues to own each attachment's independent
cursor barrier and event-count queue, while the daemon owns per-connection
socket output buffers, the resident window and the residency ceilings. The
socket path is
`daemon.sock` inside a `0700` daemon-owned subdirectory of the state root
unless the operator names another, and a path beyond the platform bound is
refused at start rather than truncated. The selected state root and any
explicit socket path must also be valid UTF-8 before path resolution or any
filesystem, placement, Store or socket effect: invalid root bytes refuse
`state_root_unusable`, including for the offline import, while invalid explicit
socket bytes refuse startup as `invalid_socket_path`. The subdirectory exists
so the daemon never has to re-permission or reject an operator's existing root, which the
foreground server creates `0755` under the ordinary umask. A daemon first
acquires the root's crash-reclaimable host placement lock, then the Store's
writer marker, before it touches the socket path. Two simultaneous daemon
starts therefore resolve at the placement lock and never at the socket; the
marker still excludes a raw or embedded writer that does not participate in
that host lock,
and a daemon that loses its store closes the listener and every connection
before it exits. Only the daemon's own operating-system user may connect, and
the boundary that enforces it is the filesystem: an owner-only subdirectory
and socket whose ownership and mode the daemon verifies after bind and refuses
to serve without, which is what stops a foreign peer reaching `accept` at all,
while the state root itself keeps whatever mode it already had.
Peer-credential inspection is a second, fail-closed layer whose mechanism is
named per platform, because there is no portable one: the supported OTP 29
Darwin toolchain reports no `peercred` or `passcred` socket option, so Darwin
reads `LOCAL_PEERCRED` and Linux reads `SO_PEERCRED`, and a credential that
cannot be obtained or decoded closes the connection rather than admitting it.
A foreign peer is refused before initialize.
After placement acquisition, the daemon retains the uid of that
acquisition-specific regular-file owner handle and verifies the owner-only
subdirectory against it. If that handle's uid cannot be read or decoded,
startup refuses `placement_lock_failed` before Store or socket work; this is a
failure to establish the placement identity, not a socket-permission result.
After both exclusions are held, an existing selected
socket pathname is removed only when a no-follow metadata read proves a
Unix-domain socket with that retained uid. A regular file, symbolic link,
other file kind, foreign owner, unreadable identity or failed removal is
preserved and startup refuses
`socket_permission_unverified`.

Every attachment starts from a snapshot anchored at the committed sequence
and then receives the buffered and live stream contiguously, at least once.
Replay has exactly one owner, and it is core. Every attach, reattach and
reconnect goes through the runtime's cursor transaction, and every durable
event a client is owed comes from core's dispatcher over the store. The
daemon's resident window is not a replay source: it is a droppable cache of
encoded bytes for events core has already delivered, so a second connection
at the same position is served without re-encoding. It never anchors a
snapshot, never establishes or advances a cursor, and may be dropped at any
moment with no effect but re-encoding. On M5's local adapter every durable
event stays replayable until the operator retires the root, so replay always
succeeds; `cursor_expired` remains the defined response a compacting adapter
returns for a cursor older than its retained history, and no M5 path produces
it. Each connection owns a bounded socket
output buffer; a slow attachment is detached at its last completely emitted
cursor while every other attachment continues. Idle **observer** attachments
are evicted at the residency limit and reconnect at their retained cursor with
no missing durable event; a connection holding a controller lease is exempt
while it holds it, because a controller of a quiet session is healthy and
evicting it would strand the connection-bound lease until explicit release or
expiry. A
non-prepared owner succession is a separate core invalidation cut, begun before
the successor enters acquisition: it removes
every attachment of that session, releases every transfer and daemon charge
after acknowledged cleanup, tells each live generation-2 holder `detached` at
its last emitted cursor, and clears the connection-local attachment while
keeping those connections open. Each attached connection reserves, inside its
existing 4 MiB total, enough output headroom for the maximal encoded succession
`detached` record followed by one maximal correlated succession-reply slot,
reused serially across ADR 0023's at most 32 in-flight lease-authorized
mutation origins. Ordinary frames cannot consume it, so a live holder cannot
miss the notice or a cut-ordered mutation reply merely because its data buffer
is full. The pending attach reserves that local
headroom and a matching share of the
512 MiB aggregate before core preparation; ordinary output and resident-window
admission cannot borrow either reserve, while replacement transfers the exact
target's reserve without a transient second charge. The cut itself leaves a
controller's holder, epoch and deadline unchanged: it must reattach
before another mutation, and another connection cannot take over until the
holder explicitly releases or the term expires. An accepted
succession-causing mutation may renew the deadline under the ordinary lease
rule; the cut does not renew it on its own.

The notice uses the first part of the reserve; predecessor mutation replies
reuse the one reply slot serially. The connection pauses post-cut request
admission until those replies are emitted or it is reaped, then resumes in wire
order. A
ordinary pending attach invalidated before publication uses the same reply slot for
`attachment_conflict` and owes no `detached`. Thus a post-cut query, mutation
or reattach cannot borrow or starve the reserved delivery. A query, read or
transfer result admitted before the cut remains ordinary output and may invoke
the existing overflow close independently; the succession reserve does not
promise space for it.

One route may already have crossed the daemon gate when succession begins. A
daemon-only detailed core path distinguishes that cut from independent
coordinator death while preserving the embedded command API's released result:
a command the predecessor handled keeps its real result; succession first
sends `detached` and then correlated `control_not_held` with no durable
admission; death before any core call sends `session_unavailable`; death after
a route sends `admission_unknown`. The `detached` record never settles the
pending request. A controller that initiated succession with `session.resume`
therefore receives `detached` followed by its one real correlated resume result,
keeps its lease, applies the ordinary renewal only if admission succeeded or is
unknown, and reattaches. Reattachment waits until every mutation origin that
crossed the old attachment gate has settled or been reaped and its reserved
reply space is released. Targeted replacement normally creates no succession
record: the daemon closes the target's local mutation gate, settles or reaps
every older mutation origin, and only then performs the core replacement and
publishes the new handle. If non-prepared succession crosses that still-pending
replacement, the registry serializes the exact target, pending transaction and
preallocated new attachment identity. Succession first converts the one
borrowed reserve into the old target's succession row, sends `detached`, and
returns the replacement's `attachment_conflict` through the reply slot; the
replacement never becomes a local handle. If replacement publication wins the
registry cut first, its success is ordinary and succession then invalidates the
newly installed attachment. Both orders release one charge and one reserve. No
order needs an old-handle route disposition or core tombstone.
**Every ordinary eviction the daemon initiates is a record and a close**: the
client is told, best-effort, on the connection being ended, and that connection
is closed with its attachment. Succession is the one attachment-only
invalidation: it may detach every connection for that session without ending
one, while unrelated sessions remain untouched.
Accepted connection slots are themselves bounded, at 512 provisional —
including a failed handoff being reaped — plus live plus closing,
because a client that never attaches is bounded by no attachment ceiling. A
connection exists only under registry ownership: the registry creates the
waiting child linked inside the same serialized callback that records its pid,
monitor and incarnation, then unlinks it only after that row is prepared. The
registry traps exits before serving, retains the exact daemon-owner pid whose
exit still stops it, and handles the exact temporary-child exit idempotently
with its monitor. The child monitors the registry and listener from its inert
initialization. A
provisional row with no child pid therefore means that no child exists; a
listener death queued during creation is processed only after the row owns the
child and can reap it. A
disconnected slot is not reusable while one of its at most 32 request rows or
its holder cleanup remains, which also bounds relay work under reconnect churn.
Transient progress is coalesced or dropped first and
never delays a journal transaction. Listener loss leaves the connection
registry alive, so existing clients receive best-effort
`fatal:listener_lost` before close. Connection-registry loss leaves no live
socket inventory or writer, so the daemon closes the listener, cuts admission
and halts without claiming it delivered `fatal:connections_lost`.

A session is *active* when **this daemon activated it in this lifetime** and
*dormant* when the root holds it durably and this daemon has not — whether or
not the daemon's index records it, indexing deciding only what `session.list`
shows. Both are daemon
facts, true by construction; neither is a claim about a live coordinator,
which the daemon has no way to know. Recovery is lazy: a restarted daemon activates nothing,
reads its index, and activates a session when a client creates or resumes it.
Creating a session activates it, so `session.create` spends one of the
activations the ceiling counts — a created session has a coordinator like any
other, and a ceiling that counted resumes but not creations would bound the
wrong thing. Acquiring control and attaching do not activate.

Activation is one-way: idle eviction and reclamation apply to attachments,
resident windows and output buffers, never to a coordinator, because a session with no attachment
may still have a model request, a tool effect, an interaction, a recovery, an
unresolved `commit_unknown` or an executing admission in flight, and because
stopping one would need a core deactivation operation M5 does not add. The
cost is stated rather than hidden: at most 64 sessions are activated per
daemon lifetime, the 65th fresh activation refuses, and the remedy is to restart
the daemon. Dormancy means only that this daemon has never activated the
durable session in its current lifetime. An exact historical create replay remains available at that bound:
the read-only create-history discriminator returns its committed session ID
without starting a coordinator or spending an activation.
`residency` therefore means *this daemon activated this session in this
lifetime* — a daemon-owned fact, true by construction — and never *a live
coordinator exists*, which the daemon has no way to know. A coordinator that
dies is core's to supervise. After attach, the live resume client performs one
bounded `session.inspect`; generation 2 maps core's exact
`:session_unavailable` result to the correlated `session_unavailable` code
before any driving mutation. Retrying inspect against that lifetime repeats
the refusal; the client attempts release while writable, and the operator
recovery is to restart the daemon and retry `loopex resume --daemon`, whose
dormant branch starts, reattaches and inspects a new coordinator. Other command
failures retain their existing mappings. Same-lifetime repair would require another core lifecycle
surface and is outside this decision.

A reconnecting resume client keeps one resume command identity while that
activation attempt is unresolved. A resolved historical success does not prove
that the successor daemon activated the session: core replays a completed
resume without starting a coordinator. If the following attach still reports
`session_dormant`, the client ends that resolved attempt, allocates a new resume
command identity for the successor's activation attempt, and retains that new
identity across any further loss. It repeats that sequence only inside the one
non-resetting recovery clock; it never substitutes a new identity while an
attempt remains unresolved.

Lazy recovery is what a daemon can honestly promise on a store whose session
directory is not Store truth and whose every open replays a full log.
`session.list` returns bounded pages, with an exact continuation cursor, over
a bounded, daemon-owned persistent discoverability index — identity, recorded
placement identity, active or dormant, controlled or not — and never over what
the Store contains. Daemon startup reads only that size-capped index and never
enumerates the legacy session directory, so malformed or arbitrarily numerous
directory names cannot defeat the startup bound. A populated legacy root with
session entries and no index requires an explicit offline import before the daemon serves it; the
import's legacy directory scan is intentionally outside the service-start
bound. That import uses a strict daemon-owned reader rather than the released
listing projection, which deliberately skips entries it cannot decode. Before
and after the one materialized listing, the legacy directory must be a
non-symlink directory whose uid equals the acquisition-specific placement owner
handle retained by the importer, with the same owner,
device and inode. Every non-temporary legacy row must validate, and one corrupt,
oversized or invalid-UTF-8 row refuses the whole import without changing an
existing index. The import installs its signal lifecycle before either
exclusion. A handled stop interrupts and reaps the scan, runs the same bounded
Store and placement cleanup, emits no readiness or wire output, and exits with
the distinct non-zero `prepare_index_interrupted` status; an image already
renamed remains a complete valid image rather than being rolled back or
partially published. The exact success report and a late stop use
first-consumed arbitration: success first exits `0` and makes the stop
cleanup-only, while stop first retains the interruption status. The
index is not Store truth and can omit a session committed across a
crash cut; exact-ID and command-ID recovery repair such an omission. Lineage,
lifecycle state and committed sequence are not list fields: a client that
needs them attaches and reads the snapshot.
The proposed
limits are exact and are bound at acceptance: 512 occupied accepted slots
across provisional (including aborting), live and closing per
daemon, thirty seconds from kernel accept for an accepted connection to complete
`initialize` before it is closed — one absolute deadline retained through
provisional handoff and promotion, and a value derived from the lease term but carried as a key
of its own, so neither contract moves the other — 64 attachments per session,
512 attachments per daemon, a 1,024-event core queue per attachment, a 4,096-event
resident window per session, 4 MiB of encoded output buffered per
connection — including the derived succession-delivery headroom that ordinary
frames cannot consume —, 16 MiB of encoded resident-window events per session,
512 MiB of aggregate commitment across retained encoded bytes and unused
per-attachment succession-delivery reserves per daemon, ten minutes of idle time
before an **observer** connection is evicted — a lease holder being exempt
while it holds its lease — 64 sessions activated per daemon lifetime, 4,096 recorded
index entries per root,
256 sessions per list page, and the ADR 0023 frame ceiling
unchanged. Count and byte ceilings apply together; an event that would
exceed either triggers the stated detachment, eviction or refusal behavior
before the ceiling is crossed.

**Alternatives rejected.** TCP on loopback has no peer-credential check and
invites remote exposure by misconfiguration. Serving generation 1 from the
daemon would need a second fencing path with no wire epoch, and its one
exclusive connection per session is what the foreground server already
provides. Keeping M4's one-attachment-per-process rule contradicts what a
daemon is for. Limiting one holder to one attachment was rejected after the
maintainer selected embedded same-holder concurrency on 2026-09-20; a boolean
replacement flag cannot identify one member of that set. An unbounded
per-attachment queue lets one slow client grow
coordinator-adjacent memory without bound. A daemon-owned proxy fan-out would
duplicate core's cursor and queue ownership and need a second replay boundary
to preserve the subscribe/snapshot race. Promising exactly-once replay was
rejected on 2026-09-14 because at-least-once with client deduplication is the
founding contract and no other surface honors more. Removing `session.list`
was rejected the same day because an observer without filesystem access to the
root would have no way to discover sessions. Rebuilding an authoritative
inventory by enumerating the Store, and writing the inventory entry inside the
session-creating transaction so it is crash-atomic with the commit, were both
rejected on 2026-09-20: each is a change to the Store port or to the local
adapter's transaction shape, and both are exactly what M5's selection of the
unchanged adapter declines to buy. Activating every recorded session at
daemon start was rejected the same day. The local adapter replays the root's
**one** log in full at every open, so the cost is not a product of session
count and history — it is that single replay, paid once, plus the cost of
starting a coordinator for every recorded session and holding it. That is what
lazy recovery avoids: a root with 4,096 recorded sessions would start 4,096
coordinators to serve the one a client wanted. And a root with one unservable
session would fail a start that need never have reached it. The companion records each in full.

**Implementation and milestone-closure evidence.** Outcome 5's integrated
real-provider socket workflow waits on this decision as well as the direct
outcomes above. Two classes together. The transport and
its generation are a protocol claim, so they need vectors and a compatibility
proof: a generation-2 negotiation vector, refusal of a generation-1-only
initialize, and an independent client over the socket. The residency rules are
a durability and resource claim, so they need process fault injection and
bounded-resource negatives on real processes: simultaneous daemon starts,
connect-before-readiness followed by readiness-output failure with no accepted
process or daemon/core state; a parked listener exit whose owner fatal notice
the lifecycle sentinel consumes before release authorization selecting startup
`listener_start_failed`, while the same loss after the sentinel sends exact
`begin_accept` selects running `listener_lost`; and one-sentinel arbitration
forcing both orders of stop versus completed success and deadline, and owner
component-fatal notice versus completed success and deadline, with every
pre-release winner keeping the gate parked even when the line is visible and
release authorization first making the later signal or failure take its
running path,
the accept-time initialize deadline held across provisional handoff and
promotion with queued-late completion losing and exact rows reaped,
listener death while the registry is paused after child start but before its
atomic row bind, with the trapped child exit unable to kill the registry and
the child, row, socket and slot all reaped,
loss of the store under a live listener, two attachments from one embedded
holder remaining independent, an explicit replacement removing only its named
target, holder death releasing the holder's complete attachment and transfer
set, non-prepared succession invalidating every session attachment without a
holder death and releasing transfers and charges before `detached` notification
while every daemon connection remains open, including with ordinary output
filled to the local threshold and aggregate commitment filled by 512
succession-delivery reserves, with 32 routed mutations receiving the notice
before every correlated reply; attach reserving local and aggregate headroom
before core preparation; replacement transferring both at full capacity only
after its local mutation barrier settles predecessor mutation origins;
succession crossing replacement before promotion, during core preparation,
after core publication but before daemon finalization, and after finalization,
with one local CAS, one reserve and no stale handle; both
route-versus-succession orders, post-result classification on both sides of the
cut and in both holder-notice orders, coordinator death before and after route,
and an attached generation-2 controller issuing the succession-causing resume
then receiving `detached`, its real result and a successful reattachment; a slow observer detached at its
last emitted cursor, idle eviction and
reconnect with no missing durable event, bounded-index startup independent of
legacy directory population, strict offline import refusing corrupt, oversized
and invalid UTF-8 legacy rows without omitting them or changing the prior index,
a completed resume reply lost across daemon replacement and replayed to success
without activation followed by a fresh resume command identity that activates
and attaches, direct invalid-binary root and socket inputs refusing before any
effect, and each count and byte ceiling refusing
independently with observed process RSS recorded beside it.

Technical depth: [Contract and evidence](0032-daemon-attachment-residency-and-replay-technical.md#technical-adr-0032-decision).

<a id="concept-adr-0032-consequences"></a>
### Consequences, Compatibility and Rollback

A client that reconnects at its cursor sees every durable event after it, in
order, possibly more than once, never with a gap; it deduplicates by session
ID, event sequence and event ID exactly as the vision requires of every
consumer. A misbehaving client costs the daemon a bounded buffer and its own
detachment, never another client's progress. Generation 2 is additive over
generation 1's method set; a client that can speak only generation 1 learns
at initialize that this daemon does not serve it, and the foreground server
still does. The public protocol remains experimental with exact-generation
agreement and no mixed-generation stream promise.

Rollback is the M4 foreground server on the same local store: it ignores the
daemon's bounded discoverability index, and no Store record, event or snapshot
depends on that file. Removing the daemon loses only live residency and lease
state. A populated legacy root with session entries and no index enters M5
through the explicit offline index import; that import acquires the host
placement lock and then the Store marker. A root with neither sessions nor an
index creates the canonical empty index at ordinary startup. No reverse
migration is needed. The numbers are safety
ceilings the M5 tests must show are enforced, not measured service promises.

Technical depth: [Compatibility mechanics](0032-daemon-attachment-residency-and-replay-technical.md#technical-adr-0032-compatibility).

## Governance Record

| Decision | Authority | Authority evidence | Bound bytes |
| --- | --- | --- | --- |
| Acceptance | Maintainer | [disposition](../developer/agent-context-map.md#disposition-m5-acceptance-2026-09-21) | candidate `1e1b33bfbf83953463e6abcdaebd52dc12735d8f`; concept `sha256:7d0fb8b8b095f0e843b19b3160aefb9ed1600262fc7bc0b4cac95076598b47c3`; technical `sha256:51a2bb5d938c4f409fb6d0480d0cad503ddb60ed2b38e210c9f2bae5757a4a02` |
