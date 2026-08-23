# 0008. Session protocol candidate

<a id="concept"></a>
## Concept

Technical depth: [Envelope, negotiation, and vector mechanics](0008-session-protocol-candidate-technical.md#technical-depth).

- **Status:** Proposed
- **Date:** 2026-08-22
- **Decision owner:** Maintainer
- **Prerequisite for:** `M2` acceptance, and implementation of its outcomes 2, 3, 4, 6, and 9

## Governance Record

| Decision | Authority | Authority evidence | Bound bytes |
| --- | --- | --- | --- |
| Acceptance | — | — | — |

<a id="concept-adr-0008-context"></a>
## Context

`M1` exposes an embedded API to one in-VM caller. `M2` puts independent clients
on the other side of a socket, which turns a function call into a wire contract:
framing, versioning, an error model, and a shape that survives a client written
by someone who cannot read the Elixir.

The vision fixes the semantics — command and event envelopes, four stream planes,
race-free attachment, delivery and backpressure — and states that public DTOs use
a documented JSON Schema 2020-12-compatible subset backed by language-neutral
golden vectors. What is unresolved is the concrete wire: how a message is framed,
how versions are negotiated, how an experimental method is gated, and what an
error looks like.

This must be decided before implementation because every other `M2` outcome binds
to it. A transport built against an unsettled envelope is rewritten when the
envelope settles.

Technical depth: [Why the wire cannot be derived from the embedded API](0008-session-protocol-candidate-technical.md#technical-adr-0008-context).

<a id="concept-adr-0008-decision"></a>
## Decision

- **JSON-RPC 2.0 framing.** Requests carry `method`, `params`, `id`; responses
  echo `id` with `result` or `error`; notifications omit `id`. It is widely
  implemented, trivially expressible from the standard library, and already the
  shape of the editor ecosystem Loopex intends to meet.
- **An explicit `initialize` handshake.** A client sends `initialize` with its
  metadata and requested capabilities before any other request, and acknowledges
  with `initialized`. Any other request before that is refused, not queued.
- **Capability negotiation gates experimental surface.** The server advertises
  what it supports; a client opts in explicitly. A method behind an unrequested
  capability is refused with a named error, never best-effort served. This is the
  mechanism that makes the 0.x experimental posture enforceable rather than
  merely asserted.
- **Approvals are server-initiated requests, not notifications.** A deferred
  policy decision reaches the client as a request with an `id`, and the client's
  decision is the correlated response. A notification cannot express a decision
  the session is waiting on.
- **Errors are a closed, versioned set** with stable codes. `cursor_expired` is
  one of them, not a special case bolted onto a stream.
- **Golden vectors are the contract.** Committed canonical bytes for every
  envelope and every negative case. The Elixir encoder is an implementation of
  the vectors, not their source.
- **Experimental, not frozen.** The protocol carries a version from its first
  commit so a later change is visibly a change, and it is labelled experimental
  until a milestone past the extension and activation barrier decides otherwise.

Technical depth: [Exact envelopes, negotiation, error model, and vector obligations](0008-session-protocol-candidate-technical.md#technical-adr-0008-decision).

<a id="concept-adr-0008-alternatives"></a>
## Alternatives

**A bespoke framed binary protocol** is smaller on the wire and lets Loopex
define exactly what it needs. It is not recommended: it makes every independent
client an implementation project, and the milestone's whole point is that clients
are independent and disposable.

**Erlang term framing** is the cheapest thing to write and the worst thing to
consume. It also violates plain boundary data by making the wire carry
implementation types.

**A schema-first IDL with generated codecs** is where a frozen public protocol
eventually wants to be. It is premature here: generating codecs for a protocol
still being designed spends the effort twice.

Technical depth: [Alternative analysis](0008-session-protocol-candidate-technical.md#technical-adr-0008-alternatives).

<a id="concept-adr-0008-consequences"></a>
## Consequences

JSON-RPC's request/response correlation gives approvals and cancellation a
natural shape, at the cost of a text encoding on a local socket. That cost is
accepted for a milestone whose consumers are editors and scripts.

Every envelope change means a vector change, which is friction on purpose: it
makes a silent redefinition impossible.

Adopting the ecosystem's framing invites the assumption that Loopex implements
ACP or the Codex app-server protocol. It does not. Those are edges an adapter may
map later, and the vision already forbids making Loopex an implementation of any
of them at its core.

Technical depth: [Operational consequences](0008-session-protocol-candidate-technical.md#technical-adr-0008-consequences).

<a id="concept-adr-0008-compatibility"></a>
## Compatibility, Migration, and Rollback

No public compatibility claim is made and nothing is frozen. No client exists to
migrate. Rollback is removing the protocol app's public modules while no daemon
depends on them.

Technical depth: [Compatibility and rollback mechanics](0008-session-protocol-candidate-technical.md#technical-adr-0008-compatibility).

## Links

- [ADR 0009](0009-attachment-cursor-and-residency.md#concept) — the attachment
  and cursor semantics these envelopes carry
- [ADR 0010](0010-daemon-collaboration-policy.md#concept) — the collaboration
  policy whose decisions travel as approvals
- [Vision technical §11](../vision-technical.md#technical-depth) — public
  protocol and channel semantics
