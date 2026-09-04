# 0019. Experimental public session protocol

<a id="concept"></a>
## Concept

Technical depth: [Protocol mechanics](0019-experimental-public-session-protocol-technical.md#technical-depth).

- **Status:** Proposed
- **Date:** 2026-08-24
- **Decision owner:** Maintainer
- **Prerequisite for:** `M4` acceptance

## Governance Record

| Decision | Authority | Authority evidence | Bound bytes |
| --- | --- | --- | --- |
| Acceptance | — | — | — |

<a id="concept-adr-0019-context"></a>
## Context

M2 makes one foreground process a useful coding harness. Its public Elixir
facade owns the durable command semantics, but another program has no bounded,
language-neutral way to initialize the runtime, submit those commands, or
distinguish durable events from transient progress. Adding JSON around internal
calls would expose implementation terms and create a second semantic surface.

The vision calls for a strict headless session protocol before a daemon. M4
therefore needs one public contract that an editor, terminal, or embedding host
can drive in a separate process without granting that process session authority
or asking a transport to own a second loop. The first real transport is stdio;
sockets, concurrent attachments, controller takeover, and process residency
remain evidence M4 does not yet have.

Technical depth: [Boundary and ownership problem](0019-experimental-public-session-protocol-technical.md#technical-adr-0019-context).

<a id="concept-adr-0019-decision"></a>
## Decision

- **`loopex_protocol` owns one transport-neutral public protocol.** It owns
  bounded plain-data request, admission, query, snapshot, durable-event,
  transient-progress, interaction, error, and capability shapes, their
  validation, an exact schema identity, and language-neutral conformance
  vectors. It remains dependency-free and JSON-library-free.
- **`loopex_app_server` is the first consumer, not another runtime.** It maps
  protocol values to the public `Loopex` facade and may own connection-local
  correlation and backpressure only. It owns no coordinator, reducer, Store
  access, cursor truth, model loop, policy authority, or placement decision.
- **The first mapping is one long-lived stdin/stdout process.** Input and output
  are strict UTF-8 JSON objects delimited by one LF byte. Protocol stdout carries
  protocol records only; bounded diagnostics go to stderr. The process is a
  foreground host whose loss invokes M2's shutdown and recovery rules. It is not
  a daemon and promises no independent session residency.
- **Initialization is mandatory, exact, and one-time.** Before any mutation the
  client and server agree on one experimental protocol generation, exact schema
  digest, capabilities, and server-enforced limits. Mutation before
  initialization, repeated initialization, or no common generation is refused
  without creating durable work.
- **Transport and durable identities stay distinct.** `request_id` is bounded,
  connection-local correlation and is never journaled. A mutating request also
  carries the existing durable `command_id`; changed parsed semantics under a
  reused command ID conflict regardless of JSON whitespace or member order.
  Session, run, turn, operation, attempt, interaction, event-sequence, and
  `stream_domain_id` identities retain their existing owners and retry rules.
- **Admission precedes asynchronous work.** A mutation receives its correlated
  admission only after the one serial session owner has committed the durable
  admission or refusal. Progress, events, interactions, and terminal settlement
  follow asynchronously. A query response is correlation, not durable
  admission, and no transport reply itself becomes session truth.
- **Attachment is explicit.** `session.create` returns a durable session identity
  and does not silently attach the connection. `session.attach` must return an
  authoritative snapshot and current cursor before that connection submits a
  session command or receives later events and progress. There is no implicit
  auto-attachment whose cursor a client cannot observe.
- **M4 exposes only implemented semantics.** The protocol covers session
  create, list, resume, inspect, snapshot and current cursor; prompt, steer,
  follow-up, abort, and interaction response; project-resource trust; bounded
  artifact retrieval; durable events; and transient progress. Fork, compaction,
  model switching, extension management, and daemon operations are negotiated
  unavailable rather than invented at the wire.
- **Truth planes remain explicit.** Authoritative snapshots, durable events,
  transient progress, and diagnostics are separate record families. A current
  process attachment starts from an authoritative snapshot and cursor before
  later live events. ADR 0011's `stream_domain_id` scopes progress continuity;
  a gap or absent closure falls back to durable state and never implies abort,
  denial, approval, or abandonment.
- **The boundary fails closed and stays bounded.** Invalid UTF-8, duplicate
  object keys, unknown mutating discriminants, unsafe numeric identities,
  excessive nesting, oversized frames, strings, or collections, and atoms
  derived from input are refused. Slow output cannot block the coordinator or
  grow memory without bound: progress may coalesce or drop, while a durable
  stream detaches at a stated cursor or admission refuses under overload.
- **Source version and protocol generation are independent.** M4 changes the
  source-tree `VERSION` to `0.1.0` at closure, as ADRs 0009–0011 reserved. The
  experimental protocol generation is negotiated separately. The version change
  is not a tag, package, release, publication, or compatibility freeze.

Technical depth: [Exact protocol contract](0019-experimental-public-session-protocol-technical.md#technical-adr-0019-decision).

<a id="concept-adr-0019-alternatives"></a>
## Alternatives

- **Put RPC directly in the coordinator.** Rejected because transport pressure,
  parsing, and request correlation would enter the serial owner of durable truth.
- **Let the command application own the server.** Rejected because a human CLI
  and an app-server are peer clients; neither may become the other's semantic
  substrate.
- **Ship a daemon and sockets now.** Rejected because controller leases,
  concurrent clients, takeover, residency, and disconnect semantics require a
  later serial barrier and different evidence.
- **Use transport request IDs as command IDs.** Rejected because reconnect and
  retry would turn connection-local correlation into durable authority.

<a id="concept-adr-0019-consequences"></a>
## Consequences

An external program can drive the same session M2 exposes without linking
Elixir code or owning another loop. The price is a real public boundary: schemas,
limits, vectors, error behavior, stdout purity, and identity ownership become
reviewed contract rather than adapter accident. The contract is deliberately
experimental and exactly negotiated; it does not promise mixed-generation
compatibility or daemon behavior.

Technical depth: [Evidence and operational consequences](0019-experimental-public-session-protocol-technical.md#technical-adr-0019-consequences).

<a id="concept-adr-0019-compatibility"></a>
## Compatibility, Migration, and Rollback

No released wire surface or installed base exists. A client and server must
agree on the exact experimental generation and schema digest, so M4 creates no
reader/writer compatibility range. Before M4 closure, rollback removes the
app-server and schema bundle and returns callers to M2's embedded and command
surfaces. This decision adds no Store schema by itself. A later compatibility
freeze, package, or public release needs its own explicit authority.

Technical depth: [Rollback mechanics](0019-experimental-public-session-protocol-technical.md#technical-adr-0019-compatibility).

## Links

- [Vision public protocol](../vision-technical.md#technical-vision-public-protocol)
- [Vision serial barriers](../vision-technical.md#technical-vision-serial-barriers)
- [ADR 0011](0011-session-input-algebra-and-streaming.md#concept)
- [ADR 0008](0008-owner-succession-recovery-and-runtime-placement.md#concept)
- [M4 Concept plan](../archive/M4.md#concept)
