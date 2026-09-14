<a id="concept"></a>
## Concept

Technical depth: [Attachment residency mechanics](0032-daemon-attachment-residency-and-replay-technical.md#technical-depth).

- **Status:** Proposed
- **Date:** 2026-09-14
- **Decision owner:** Maintainer
- **Supersedes:** nothing; ADR 0023's one-attachment-per-foreground-process rule and generation-1 wire remain in force
- **Prerequisite for:** M5 acceptance

<a id="concept-adr-0032-decision"></a>
### Context and Decision

The M4 foreground server maps one connection to one attachment in one
process that exits with the client. A daemon keeps sessions alive across
client processes, so it must answer what a client is owed when it attaches,
reconnects, falls behind or goes idle, and it must do that over a transport
that several processes on one machine can reach. The vision fixes the
semantics: attach is one race-free cursor transaction anchored at a committed
sequence, a cursor older than retained history returns `cursor_expired` with
a fresh snapshot instead of truncating silently, a slow attachment is bounded
and cannot block the coordinator or another client, and a reconnecting client
is owed complete durable events and terminal outcomes, not every dropped
progress fragment.

Decide the transport and the residency rules together, because the numbers
only mean something against a transport. The daemon carries the ADR 0023
JSONL protocol over a Unix-domain socket: generation 1 keeps its framing,
initialize handshake and record envelopes. Generation `loopex.experimental/2` adds
the daemon methods, `session.list`, `session.stop`, `daemon.status` and the
lease methods ADR 0033 names. A narrow core change lets distinct attachments
to the same session coexist without replacing one another; the core continues
to own their independent cursor barriers and delivery queues, while the daemon
owns the residency ceilings. Generation-1 wire stays unchanged. On the daemon,
a generation-1 connection may attach only when no other connection is attached
to that session and no other unexpired held lease exists. Its own held lease
excludes generation-2 attachments until release or expiry. The M4 foreground
server retains its original behavior. The socket path is the
state root's `daemon.sock` unless the operator names another, and a path
beyond the platform bound is refused at start rather than truncated. Only the
daemon's own operating-system user may connect; a foreign peer is refused
before initialize.

Every attachment starts from a snapshot anchored at the committed sequence
and then receives the buffered and live stream contiguously. The daemon keeps
a bounded resident window of recent durable events per session and replays
older ones from the store on demand; beyond retention it answers
`cursor_expired` with a fresh snapshot and cursor. Each attachment owns a
bounded queue; a slow attachment is detached at its last completely emitted
cursor while every other attachment continues. Idle attachments are evicted
at the residency limit and reconnect at their retained cursor with no
duplicate or missing durable event. Transient progress is coalesced or
dropped first and never delays a journal transaction. The proposed limits are
exact and are bound at acceptance: 64 attachments per session, 512 per
daemon, a 1,024-event queue per attachment, a 4,096-event resident window per
session, 4 MiB of encoded queued events per attachment, 16 MiB of encoded
resident-window events per session, 512 MiB of aggregate retained encoded
events per daemon, ten minutes of idle time before eviction, and the ADR 0023
frame ceiling unchanged. Count and byte ceilings apply together; an event
that would exceed either triggers the stated detachment, eviction or refusal
behavior before the ceiling is crossed.

Technical depth: [Contract and evidence](0032-daemon-attachment-residency-and-replay-technical.md#technical-adr-0032-decision).

<a id="concept-adr-0032-consequences"></a>
### Consequences, Compatibility and Rollback

A client that reconnects after any loss short of retention sees the same
durable events it would have seen live, once, in order; one that reconnects
beyond retention gets a truthful fresh start rather than a gap. A misbehaving
client costs the daemon a bounded queue and its own detachment, never another
client's progress. Generation 2 is additive: a generation-1 client negotiates
generation 1 and never sees the daemon methods; unknown methods still refuse.
The daemon's exclusive generation-1 session rule prevents two generation-1
connections, or a generation-1 and generation-2 connection, from claiming
simultaneous command authority. The public protocol remains experimental with
exact-generation agreement and no mixed-generation stream promise.
When its internal lease expires, a still-connected generation-1 attachment is
detached before any successor attaches or acquires control.

Rollback is the M4 foreground server on the local store: it carries no
residency state, so removing the daemon loses nothing durable. Numbers are
safety ceilings to prove under the M5 gate, not measured service promises.

Technical depth: [Compatibility mechanics](0032-daemon-attachment-residency-and-replay-technical.md#technical-adr-0032-compatibility).

## Governance Record

| Decision | Authority | Authority evidence | Bound bytes |
| --- | --- | --- | --- |
| Acceptance | — | — | — |
