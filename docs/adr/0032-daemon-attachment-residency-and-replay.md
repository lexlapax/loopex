<a id="concept"></a>
## Concept

Technical depth: [Attachment residency mechanics](0032-daemon-attachment-residency-and-replay-technical.md#technical-depth).

- **Status:** Proposed
- **Date:** 2026-09-14
- **Decision owner:** Maintainer
- **Supersedes:** nothing; ADR 0023's one-attachment-per-foreground-process rule and generation-1 wire remain in force on the foreground server
- **Prerequisite for:** M5 acceptance

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
handshake, request, admission, snapshot, event and progress records and
limits unchanged, and serves exactly one generation,
`loopex.experimental/2`, which adds `session.list`, `session.stop`,
`daemon.status`, the two control methods and the writer-epoch field ADR 0033
names. A client that offers only generation 1 is refused at initialize under
ADR 0023's existing no-common-generation rule and nothing durable is
created; generation-1 clients keep the M4 foreground server, whose wire,
one-attachment rule and behavior do not change. A narrow core change lets
distinct attachments to the same session coexist without replacing one
another; the core continues to own their independent cursor barriers and
event-count queues, while the daemon owns per-connection socket output
buffers, the resident window and the residency ceilings. The socket path is
the state root's `daemon.sock` unless the operator names another, and a path
beyond the platform bound is refused at start rather than truncated. A daemon
acquires the root's store writer marker before it touches the socket path,
so two simultaneous starts resolve at the marker and never at the socket,
and a daemon that loses its store closes the listener and every connection
before it exits. Only the daemon's own operating-system user may connect; a
foreign peer is refused before initialize.

Every attachment starts from a snapshot anchored at the committed sequence
and then receives the buffered and live stream contiguously, at least once.
The daemon keeps a bounded resident window of recent durable events per
session and replays older ones from the store on demand. On M5's local
adapter every durable event stays replayable until the operator retires the
root, so replay always succeeds; `cursor_expired` remains the defined
response a compacting adapter returns for a cursor older than its retained
history, and no M5 path produces it. Each connection owns a bounded socket
output buffer; a slow attachment is detached at its last completely emitted
cursor while every other attachment continues. Idle attachments are evicted
at the residency limit and reconnect at their retained cursor with no
missing durable event. Transient progress is coalesced or dropped first and
never delays a journal transaction. `session.list` returns bounded pages
with an exact continuation cursor from a daemon-owned index. The proposed
limits are exact and are bound at acceptance: 64 attachments per session,
512 per daemon, a 1,024-event core queue per attachment, a 4,096-event
resident window per session, 4 MiB of encoded output buffered per
connection, 16 MiB of encoded resident-window events per session, 512 MiB
of aggregate retained encoded events per daemon, ten minutes of idle time
before eviction, 256 sessions per list page, and the ADR 0023 frame ceiling
unchanged. Count and byte ceilings apply together; an event that would
exceed either triggers the stated detachment, eviction or refusal behavior
before the ceiling is crossed.

**Alternatives rejected.** TCP on loopback has no peer-credential check and
invites remote exposure by misconfiguration. Serving generation 1 from the
daemon would need a second fencing path with no wire epoch, and its one
exclusive connection per session is what the foreground server already
provides. Keeping M4's one-attachment-per-process rule contradicts what a
daemon is for. An unbounded per-attachment queue lets one slow client grow
coordinator-adjacent memory without bound. A daemon-owned proxy fan-out would
duplicate core's cursor and queue ownership and need a second replay boundary
to preserve the subscribe/snapshot race. Promising exactly-once replay was
rejected on 2026-09-14 because at-least-once with client deduplication is the
founding contract and no other surface honors more. Removing `session.list`
was rejected the same day because an observer without filesystem access to the
root would have no way to discover sessions. The companion records each in
full.

**Evidence its acceptance requires.** Two classes together. The transport and
its generation are a protocol claim, so they need vectors and a compatibility
proof: a generation-2 negotiation vector, refusal of a generation-1-only
initialize, and an independent client over the socket. The residency rules are
a durability and resource claim, so they need process fault injection and
bounded-resource negatives on real processes: simultaneous daemon starts, loss
of the store under a live listener, a slow observer detached at its last
emitted cursor, idle eviction and reconnect with no missing durable event, and
each count and byte ceiling refusing independently with observed process RSS
recorded beside it.

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

Rollback is the M4 foreground server on the same local store: the daemon
carries no residency state, so removing it loses nothing durable. The numbers
are safety ceilings the M5 tests must show are enforced, not measured service
promises.

Technical depth: [Compatibility mechanics](0032-daemon-attachment-residency-and-replay-technical.md#technical-adr-0032-compatibility).

## Governance Record

| Decision | Authority | Authority evidence | Bound bytes |
| --- | --- | --- | --- |
| Acceptance | — | — | — |
