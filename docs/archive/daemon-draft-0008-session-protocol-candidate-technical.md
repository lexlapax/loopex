# 0008: Technical depth

<a id="technical-depth"></a>
## Technical depth

Concept: [Session protocol candidate](0008-session-protocol-candidate.md#concept).

<a id="technical-adr-0008-context"></a>
## Why the Wire Cannot Be Derived From the Embedded API

Concept: [Context](0008-session-protocol-candidate.md#concept-adr-0008-context).

An in-VM API and a wire protocol differ in what they can assume. The embedded API
hands back a term; the caller either exists or the VM is gone. On a socket the
peer can vanish mid-message, send half a frame, send a message from a version
that no longer exists, or ask for a method the server never advertised.

None of those cases have a natural in-VM analogue, so a wire derived
mechanically from the embedded API has no answer for them and grows one
ad-hoc per site. That is how a protocol acquires three different error shapes
and a "best effort" parse path.

The direction that works is the reverse. The wire is specified first, with its
failure cases enumerated, and the embedded API stays a separate surface over the
same runtime. Both are thin; neither is generated from the other. The vision
already requires this by making them peer surfaces over one semantic contract.

<a id="technical-adr-0008-decision"></a>
## Exact Envelopes, Negotiation, Error Model, and Vector Obligations

Concept: [Decision](0008-session-protocol-candidate.md#concept-adr-0008-decision).

Framing is JSON-RPC 2.0 over the transport's message boundary. On a stream
socket, messages are newline-delimited JSON with a configured maximum frame size;
a frame exceeding it is refused and the connection closed rather than buffered.

Connection lifecycle:

```text
client -> initialize {clientInfo, protocolVersion, capabilities}
server -> result {serverInfo, protocolVersion, capabilities}
client -> initialized (notification)
   any other request before this -> error not_initialized
```

`protocolVersion` is compared exactly. An unknown version is refused with
`unsupported_protocol_version` carrying the versions the server does support; it
is never downgraded silently.

Capability gating: the server's advertised `capabilities` names each optional or
experimental method group. A client requesting none of them may call only the
stable core. Calling a method behind an unrequested capability returns
`capability_not_negotiated` naming the capability. This is what makes
"experimental" a runtime property rather than a documentation adjective.

Message classes:

| Class | Direction | Shape |
| --- | --- | --- |
| Command | client → server | request with `id`; result is admission, not completion |
| Query | client → server | request with `id`; read-only, never a durable mutation |
| Event | server → client | notification carrying a committed public event and its sequence |
| Progress | server → client | notification carrying its declared base sequence; coalescible and droppable |
| Approval | server → client | **request** with `id`; the client's decision is the correlated response |
| Diagnostic | server → client | notification; never durable truth |

The approval class is the one that shapes the rest. A deferred host-policy
decision blocks the operation waiting on it, so it needs correlation and a
timeout, which a notification cannot express. Making it a server-initiated
request also makes the client's obligation explicit: a client that never answers
is a client whose operation expires, not one that silently allows.

Errors are a closed set with stable codes, versioned with the protocol. The
initial set covers at least `not_initialized`,
`unsupported_protocol_version`, `capability_not_negotiated`, `malformed_frame`,
`frame_too_large`, `unknown_method`, `invalid_params`, `session_not_found`,
`cursor_expired`, `not_controller`, and `temporarily_unavailable`. A condition
without a code is a defect in this list, not an opportunity for a free-text
error.

Golden vectors are committed canonical bytes under a versioned directory: one
positive vector per message class and one per error code, each with its exact
encoded form. The obligations are that the Elixir codec round-trips every vector,
and that a decoder written against the vectors alone — with no access to the
Elixir source — also round-trips every one. The second is what proves the
protocol is language-neutral rather than serialised Elixir; nothing else does.

<a id="technical-adr-0008-alternatives"></a>
## Alternative Analysis

Concept: [Alternatives](0008-session-protocol-candidate.md#concept-adr-0008-alternatives).

**Bespoke framed binary.** Compact and exactly fitted. The cost lands on every
consumer: a client author must implement a codec before sending a single message,
which is the opposite of disposable independent clients. It also removes the
ability to debug a session by reading the socket.

**Erlang term framing.** `:erlang.term_to_binary` is a few characters of work and
makes the wire carry PIDs, atoms, and implementation types — exactly what plain
boundary data forbids. It also silently couples every client to the BEAM.

**Schema-first IDL with generated codecs.** The right end state for a frozen
public protocol with independent consumers and migration evidence. Premature
while the envelope is still moving: the generator is rewritten each time the
schema is, and the vectors alone already provide the language-neutrality proof
that matters now.

**No handshake, version in every message.** Avoids a round trip and makes every
message self-describing. Rejected because capability negotiation has nowhere to
live, and a per-message version invites a server that supports several at once,
which is a compatibility surface nobody has evidence to support.

<a id="technical-adr-0008-consequences"></a>
## Operational Consequences

Concept: [Consequences](0008-session-protocol-candidate.md#concept-adr-0008-consequences).

JSON encoding on a local socket costs bytes and parse time that a binary format
would not. For editor and script consumers at human interaction rates this is not
a measurable cost, and the debuggability is worth more. If a later milestone
finds a throughput case, that is evidence for a second encoding, negotiated
through the capability mechanism this decision already establishes.

Every envelope change requires a vector change, and a vector change is visible in
review as committed bytes. That friction is the point.

The error set being closed means adding a condition is a decision rather than a
string. That will occasionally feel heavy for an obviously-new failure mode; the
alternative is a client that cannot distinguish conditions it must handle
differently.

Adopting JSON-RPC invites the reading that Loopex implements ACP or the Codex
app-server protocol. It implements neither. Shared framing is not a shared
protocol, and the vision explicitly forbids Loopex being an implementation of any
ecosystem protocol at its core. A later adapter may map one; that mapping is its
own decision with its own conformance evidence.

<a id="technical-adr-0008-compatibility"></a>
## Compatibility and Rollback Mechanics

Concept: [Compatibility, migration, and rollback](0008-session-protocol-candidate.md#concept-adr-0008-compatibility).

No public compatibility claim, no freeze, no release candidate. No client exists,
so there is nothing to migrate.

The protocol version starts at an experimental value and increments on any
envelope, error-code, or negotiation change. Vectors are stored per version, so a
change adds a directory rather than editing one. That is a discipline that makes
a future freeze possible; it is not itself a compatibility promise.

Rollback is removing the protocol app's public modules and the daemon that
depends on them while nothing else does.
