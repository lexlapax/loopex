<a id="concept"></a>
## Concept

Technical depth: [Milestone mechanics](M2-technical.md#technical-depth).

<!-- loopex:plan-concept-envelope:start -->
## Normative Concept Envelope

<a id="concept-plan-purpose"></a>
### Purpose

Make a Loopex session outlive the caller that started it.

A reference daemon owns an explicit runtime. Client A attaches over a local
transport, creates a session, drives it through a real model call and one real
controlled tool, then dies abruptly without detaching. The session continues to a
durable fact with zero attachments. Client B attaches later, receives an
authoritative snapshot anchored at an exact committed sequence, resumes the
contiguous committed event stream with no gap and no lost fact, takes control,
and drives the session to a durable terminal result. A read-only observer sees
the same committed history and never acquires command authority. A slow observer
is disconnected with a resume cursor without stalling the session or any other
client.

M1 proved one durable local session under one embedded caller that *was* the
session's lifetime owner. This milestone inverts that ownership and proves the
same truthfulness holds when callers are independent, plural, and disposable. It
claims one machine, one local transport, and no frozen public surface.

<a id="concept-plan-outcomes"></a>
### Outcomes

| # | Outcome | Evidence class | Gate selector |
| --- | --- | --- | --- |
| 1 | A reference daemon starts and owns an explicit runtime; a session created through an attachment survives that attachment's clean detach, its abrupt disconnect, and the death of its client OS process, and continues to a durable terminal result with zero attachments | Lifetime inversion and client-kill fault injection | `apps/loopex_daemon/test/session_lifetime_test.exs` |
| 2 | Command and event envelopes, the initialize handshake, capability negotiation, and canonical encoding form one versioned experimental protocol candidate; a decoder written against the language-neutral golden vectors alone round-trips every vector, and a pre-initialize request, an unknown version, and an ungated experimental method are each refused rather than best-effort handled | Language-neutral vectors and an implementation-blind decoder | `apps/loopex_protocol/test/protocol_vectors_test.exs` |
| 3 | The daemon serves the protocol over one real local transport with explicit framing; a truncated frame, an over-bound frame, a mid-command disconnect, and a malformed envelope are each individually refused with an exact reason and without affecting session truth, another attachment, or the daemon | Transport negative corpus and isolation tests | `apps/loopex_daemon/test/transport_test.exs` |
| 4 | Attach is one runtime-owned cursor transaction — barrier at committed sequence N, authoritative snapshot anchored at exactly N, buffered-then-live delivery contiguous across the seam, deduplicated by session, sequence, and event ID — and concurrent attaches during active event production each receive a gapless stream | Attachment-race tests at N clients | `apps/loopex_daemon/test/attachment_test.exs` |
| 5 | Each attachment holds a bounded queue under a documented slow-consumer policy; a stalled consumer is coalesced or disconnected with a resume cursor and provably cannot grow coordinator memory, delay a journal transaction, change session behaviour, or block another client | Backpressure isolation and memory-bound tests | `apps/loopex_daemon/test/backpressure_test.exs` |
| 6 | A cursor resolvable against retained committed history resumes contiguously across client restart and daemon restart; a cursor older than retained history returns explicit `cursor_expired` with a fresh snapshot and cursor; paged history read is a separate read-only API that never establishes a subscription | Cursor resume, retention boundary, and read/subscribe separation tests | `apps/loopex_daemon/test/cursor_test.exs` |
| 7 | One-controller/many-observer policy, read-only attachment, controller crash takeover, and stale-writer fencing are implemented in the daemon above core; a negative test proves core admits and serializes commands with no controller lease and carries no daemon collaboration concept | Policy conformance plus a core-purity negative test | `apps/loopex_daemon/test/collaboration_test.exs` |
| 8 | A session with zero attachments becomes non-resident after a bounded configured grace period, the transition is observable rather than silent, its durable truth is unchanged by eviction, and a later attach to an evicted session resumes it and delivers a snapshot indistinguishable from one served by a resident session | Residency lifecycle and post-eviction resume tests | `apps/loopex_daemon/test/residency_test.exs` |
| 9 | One real-provider multi-client trace: controller A drives a real model call and one real controlled local tool and is killed mid-run; the daemon's OS process tree is untrappably killed after durable receipt retention but before the session fact commits; the daemon restarts, observer B's cursor resumes with no gap and no duplicated committed fact, a new controller takes over, makes the next real model call, and reaches a durable terminal result | OS-process fault injection, counted dispatches and effects, retained real-path demonstration | `apps/loopex_daemon/test/end_to_end_multi_client_test.exs` |

Technical depth: [Evidence obligations and mapping](M2-technical.md#technical-plan-evidence).

<a id="concept-plan-scope"></a>
### Scope

Product code intended to survive: a reference daemon owning an explicit runtime,
one real local transport, a versioned experimental protocol candidate with
language-neutral golden vectors, race-free attachment at N clients,
per-attachment bounded queues and cursors, session residency with bounded idle
eviction, and a collaboration policy that lives entirely in the daemon.

M1's runtime, store, model, executor, and embedded API are reused unchanged. The
daemon is a peer surface over the same semantic contract, not a second engine: it
owns no durable session truth, no alternate loop, and no authority decision that
core does not already make.

Retention of committed public-event history and residency of a session with zero
attachments both become explicit, configured, observable properties, because a
cursor is only resolvable against history that still exists and a daemon that
never evicts leaks runtimes.

Technical depth: [Prerequisites and acceptance points](M2-technical.md#technical-plan-prerequisites).

Technical depth: [Ownership and rejoin barriers](M2-technical.md#technical-plan-ownership).

Technical depth: [Packaging mechanics](M2-technical.md#technical-plan-packaging).

Technical depth: [Proportional minimalism budget](M2-technical.md#technical-plan-minimalism).

Technical depth: [Compatibility mechanics](M2-technical.md#technical-plan-compatibility).

Technical depth: [Migration and rollback](M2-technical.md#technical-plan-migration).

<a id="concept-plan-non-goals"></a>
### Non-Goals

A public protocol freeze, a release candidate, or any compatibility claim. The
enduring barrier places extension namespaces and VM-global activation proof
before that decision, and this milestone does not reach it.

Remote transport, TCP, WebSocket, distribution across nodes, multi-host anything,
and an executor fleet or broker. One local transport is the whole transport
scope, and stdio is deliberately deferred despite being the likelier embedding
default, because stdio is one client by construction and cannot prove this
milestone's claim.

Host concerns: authentication, authorization semantics, identity, tenancy,
quotas, and retention *policy*. Loopex carries a client correlation reference
without interpreting it.

Durable store adapter selection. Choosing PostgreSQL, SQLite, or another adapter
answers nothing about attachment, and M1's store conformance suite already exists
to evaluate one.

A transport behaviour. With exactly one transport, a replaceable transport
boundary is a speculative single-use layer; the socket server is direct code.

Durable attachment or subscriber records, a non-durable or ephemeral session
mode, client-defined dynamic tools, extensions, activation, isolated hands,
packaging, and publication.

Technical depth: [Deferral acceptance points](M2-technical.md#technical-plan-prerequisites).
<!-- loopex:plan-concept-envelope:end -->

## Workstreams

Ownership and the required rejoin order are fixed in the
[technical envelope](M2-technical.md#technical-plan-ownership).

- **A — Protocol candidate.** Outcome 2. Rejoins first; everything crossing the
  wire binds to it.
- **B — Daemon, transport, residency.** Outcomes 1, 3, 8. The lifetime inversion.
- **C — Attachment, cursors, backpressure.** Outcomes 4, 5, 6.
- **D — Collaboration and demonstration.** Outcomes 7, 9. Rejoins last.

## Progress and Evidence

| # | State | Evidence |
| --- | --- | --- |
| 1 | Open | — |
| 2 | Open | — |
| 3 | Open | — |
| 4 | Open | — |
| 5 | Open | — |
| 6 | Open | — |
| 7 | Open | — |
| 8 | Open | — |
| 9 | Open | — |

## Governance Records

| Decision | Authority | Authority evidence | Bound bytes |
| --- | --- | --- | --- |
| Acceptance | — | — | — |
| Closure | — | — | — |
