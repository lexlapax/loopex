<a id="concept"></a>
## Concept

Technical depth: [Attachment residency mechanics](0032-daemon-attachment-residency-and-replay-technical.md#technical-depth).

- **Status:** Proposed
- **Date:** 2026-09-14
- **Decision owner:** Maintainer
- **Supersedes:** nothing; ADR 0023's one-attachment-per-foreground-process rule and generation-1 wire remain in force on the foreground server
- **Prerequisite for:** M5 outcomes 1, 2 and 4, accepted before the socket is
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
handshake, admission, snapshot, event and progress records and limits
unchanged — and its request records with exactly one addition, the
`writer_epoch` every existing-session mutation carries, which is what makes
generation 2 a new schema digest rather than a rename. It serves exactly one
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
has no durable stop command, and M5's five core changes — the complete
concurrent-attachment lifecycle, a read-only existence query, the trace
exclusion, bounded `quiesce/1`, and the create and resume results' two new
fields — are none of them durable commands. The daemon's bounded maintained
index is adapter state, not a sixth core change. Ending a client's involvement is releasing control and
disconnecting; the session itself keeps running, which is the point of a
daemon, and another client reaches it again by acquiring control and
attaching.

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
before asynchronous work begins, coalesces only an exact repeated request, and
rolls the reservation back only on a definite refusal. When a connection
ends, its attachment slots stay charged until the relay has accounted for its
tasks and core has acknowledged complete holder cleanup.
The foreground generation-1 and daemon generation-2 adapters translate their
existing per-connection `replace: true` onto the only attachment that each
connection may hold, so the wire remains unambiguous and ADR 0023 stays
unchanged. Core monitors the stable holder, removes all
of its attachments when it dies, and releases every transfer they opened as
ADR 0028 requires. The core continues to own each attachment's independent
cursor barrier and event-count queue, while the daemon owns per-connection
socket output buffers, the resident window and the residency ceilings. The
socket path is
`daemon.sock` inside a `0700` daemon-owned subdirectory of the state root
unless the operator names another, and a path beyond the platform bound is
refused at start rather than truncated. The subdirectory exists so the daemon
never has to re-permission or reject an operator's existing root, which the
foreground server creates `0755` under the ordinary umask. A daemon
acquires the root's store writer marker before it touches the socket path,
so two simultaneous starts resolve at the marker and never at the socket,
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
evicting it would strand a lease only an explicit release can free. **Every detach the daemon initiates is a record and a
close**: the client is told, best-effort, on the connection being ended, and
that connection is closed with its attachment while every other connection is
untouched. A connection holds one attachment, so there is nothing for it to
do afterwards, and the close is what releases the attachment in core.
Concurrent connections are themselves bounded, at 512, because a client that
never attaches is bounded by no attachment ceiling. Transient progress is coalesced or dropped first and
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

Activation is one-way: dormancy applies to attachments, resident windows and
output buffers, never to a coordinator, because a session with no attachment
may still have a model request, a tool effect, an interaction, a recovery, an
unresolved `commit_unknown` or an executing admission in flight, and because
stopping one would need a core deactivation operation M5 does not add. The
cost is stated rather than hidden: at most 64 sessions are activated per
daemon lifetime, the 65th refuses, and the remedy is to restart the daemon.
`residency` therefore means *this daemon activated this session in this
lifetime* — a daemon-owned fact, true by construction — and never *a live
coordinator exists*, which the daemon has no way to know. A coordinator that
dies is core's to supervise and surfaces through core's own refusal on the
next command for that session, which the daemon forwards unchanged.

Lazy recovery is what a daemon can honestly promise on a store whose session
directory is not Store truth and whose every open replays a full log.
`session.list` returns bounded pages, with an exact continuation cursor, over
a bounded, daemon-owned persistent discoverability index — identity, recorded
placement identity, active or dormant, controlled or not — and never over what
the Store contains. Daemon startup reads only that size-capped index and never
enumerates the legacy session directory, so malformed or arbitrarily numerous
directory names cannot defeat the startup bound. An existing root without the
index requires an explicit offline import before the daemon serves it; the
import's legacy directory scan is intentionally outside the service-start
bound. The index is not Store truth and can omit a session committed across a
crash cut; exact-ID and command-ID recovery repair such an omission. Lineage,
lifecycle state and committed sequence are not list fields: a client that
needs them attaches and reads the snapshot.
The proposed
limits are exact and are bound at acceptance: 512 concurrent connections per
daemon, thirty seconds for an accepted connection to complete `initialize`
before it is closed — a value derived from the lease term but carried as a key
of its own, so neither contract moves the other — 64 attachments per session,
512 attachments per daemon, a 1,024-event core queue per attachment, a 4,096-event
resident window per session, 4 MiB of encoded output buffered per
connection, 16 MiB of encoded resident-window events per session, 512 MiB
of aggregate retained encoded events per daemon, ten minutes of idle time
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

**Implementation and milestone-closure evidence.** Two classes together. The transport and
its generation are a protocol claim, so they need vectors and a compatibility
proof: a generation-2 negotiation vector, refusal of a generation-1-only
initialize, and an independent client over the socket. The residency rules are
a durability and resource claim, so they need process fault injection and
bounded-resource negatives on real processes: simultaneous daemon starts,
loss of the store under a live listener, two attachments from one embedded
holder remaining independent, an explicit replacement removing only its named
target, holder death releasing the holder's complete attachment and transfer
set, a slow observer detached at its last emitted cursor, idle eviction and
reconnect with no missing durable event, bounded-index startup independent of
legacy directory population, and each count and byte ceiling refusing
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
state. An existing root enters M5 through the explicit marker-protected
offline index import; no reverse migration is needed. The numbers are safety
ceilings the M5 tests must show are enforced, not measured service promises.

Technical depth: [Compatibility mechanics](0032-daemon-attachment-residency-and-replay-technical.md#technical-adr-0032-compatibility).

## Governance Record

| Decision | Authority | Authority evidence | Bound bytes |
| --- | --- | --- | --- |
| Acceptance | — | — | — |
