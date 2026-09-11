# 0023: Technical depth

<a id="technical-depth"></a>
## Technical depth

Concept: [Experimental public session protocol](0023-experimental-public-session-protocol.md#concept).

<a id="technical-adr-0023-context"></a>
## Boundary and Ownership Problem

Concept: [Context](0023-experimental-public-session-protocol.md#concept-adr-0023-context).

The public Elixir facade already orders durable commands against one coordinator.
The protocol layer must preserve that ordering while adding only parsing,
correlation, projection, and bounded delivery. Any path from the app-server to a
coordinator, Store, model, executor, journal, or cursor implementation other than
through the public facade is a second runtime surface and fails conformance.

<a id="technical-adr-0023-decision"></a>
## Exact Protocol Contract

Concept: [Decision](0023-experimental-public-session-protocol.md#concept-adr-0023-decision).

### Framing and initialization

Each input frame is one JSON object followed by LF. CRLF, a top-level non-object,
trailing bytes, invalid UTF-8, a frame beyond the negotiated pre-initialization
ceiling, and EOF inside a frame are protocol errors. A decoder first preserves
object member order so duplicate keys can be rejected before conversion to a
map. It decodes keys as strings and never interns input.

`initialize` carries a connection-local `request_id`, a non-empty ordered list
of supported protocol generations, and client capability declarations. The
successful response echoes the request ID and returns the selected generation,
the exact SHA-256 schema digest, supported methods and record families, and
limits for frames, nesting, strings, collections, queued output, and waits. It
creates no session record. Exactly one successful or refused initialization is
allowed per process.

### Record families and ordering

Every server record has one `type` discriminant. Correlated responses echo
`request_id`; asynchronous records do not manufacture one. Mutations carry a
separate `command_id` in their semantic payload. A successful admission is
written only after the facade returns the committed admission result. The
server may emit no progress or terminal record for that command before its
admission record.

An attachment response contains an authoritative snapshot and `event_cursor`.
Later durable events carry monotonically ordered session event sequence and are
interpreted only after that cursor. Progress records carry `stream_domain_id`
and the domain-local sequence/count contract from ADR 0011. They never advance a
durable event cursor. Diagnostics are absent from stdout.

The wire record for durable truth has `type = "event"`; its nested event `kind`
is the exact public kind, including canonical `run.finished` and the distinct
later `session.settled`. It never invents a transport-only `run.terminal`
synonym. A query response carrying a map is not a snapshot merely because it
echoes a session ID: snapshot responses bind the same session, an integer
`event_cursor`, a snapshot at that exact `event_sequence`, and the authoritative
active-run state.

### Operations

The generation contains methods for `session.create`, `session.list`,
`session.resume`, `session.inspect`, `session.attach`, `session.prompt`,
`session.steer`, `session.follow_up`, `session.abort`,
`session.respond_interaction`, `project_resources.inspect`,
`project_resources.decide`, `resources.catalog`, `resources.read`,
`session.admit_resources`, `session.activate_skill`, `artifact.open_transfer`,
`artifact.read_chunk`, and `artifact.close_transfer`.
The project_resources pair preserves the existing root AGENTS.md trust class;
resources.catalog/read map M3's resource_catalog/read_resource facade queries,
and the two session methods map M3's exact admission/selection commands. No
wire method fetches arbitrary URLs or selects a host resource root.
The three artifact methods map M4's ADR 0028 transfer lifecycle one to one:
open names an opaque use reference, a start offset and an optional window
length and returns the object and use references, total size, window bounds,
the full-object digest and an opaque transfer reference that the server binds
to the opening connection's attachment; read_chunk returns the next sequential
chunk with its offset, bytes in a declared transfer encoding and chunk digest;
close releases the transfer. A transfer reference from another connection or
attachment refuses. Connection loss closes every transfer the connection
opened. The methods expose no path, and no chunk digest is presented as proof
of the complete object.

`session.create` admits the durable creation command and returns the new session
identity; it does not attach. `session.attach` is connection-local and returns
the authoritative snapshot/cursor pair. Session commands and live delivery are
refused until that explicit attachment succeeds. After terminal settlement, a
fresh attachment at the observed settled-event cursor is the authoritative
final-state check; `session.inspect` is a query but does not substitute for that
attachment contract.

Unknown query methods return a bounded error. Unknown mutating methods are
refused before durable admission. Unsupported future capability families are
reported during initialization and never guessed from method names.

### Bounds and backpressure

All protocol collections and strings have schema maxima no larger than the
server's negotiated limits. Identities are strings under explicit byte and
alphabet bounds; JSON numbers never carry an identity or a value whose exactness
would depend on an IEEE-754 reader. Decoder work, per-frame memory, queued
durable output, queued progress, stderr output, and every gate wait are bounded.

The app-server process owns a bounded writer. When its progress queue fills it
may coalesce or drop progress within ADR 0011's rules. When durable output cannot
be retained, the connection detaches at the last reported cursor or a new
admission is refused before mutation. It never blocks a coordinator callback on
the client's read rate.

### Connection states, process loss and resume

| Situation | Required behavior |
| --- | --- |
| Before `initialize` | Every other frame refuses; nothing durable is created |
| Repeated `initialize` or no common generation | Refuse; the connection stays uninitialized; each generation binds exactly one schema digest |
| Attachment | At most one active attachment per foreground process; a second `session.attach` refuses with a stable reason unless it names explicit replacement, which detaches the first at its last completely emitted cursor |
| Request identity | `request_id` is unique among in-flight requests on the connection; reuse while in flight refuses; reuse after completion is ordinary correlation |
| Pre-admission pressure | Refuse the mutation before any durable write |
| Post-admission pressure | Drop or coalesce progress first; if durable output still cannot drain, detach at the last completely emitted cursor and say so |
| Clean stdin EOF | Connection closed by the host: inherited orderly foreground shutdown, no new dispatch, open transfers closed, no cancellation record, no interaction state change |
| Abrupt process death | Host loss: nothing is recorded by the dying process; the journal alone states what settled, and the inherited recovery contract resolves unresolved outcomes |
| Deliberate cancellation | Only the durable `session.abort` command cancels; it is never inferred from EOF or death |
| Restart | A fresh process attaches with snapshot and cursor first; pending interactions remain pending; cancelled, expired or denied ones never reappear |

Neither EOF nor process death grants anything or cancels anything. Owned
session shutdown, effect cleanup, and unresolved outcome follow M2's public
facade. A later process uses the durable state root and ADR 0008 resume command
identity to acquire ownership. M4 promises neither live attachment replay
across process loss nor controller takeover; the new attachment starts again
from a current snapshot and cursor.

<a id="technical-adr-0023-consequences"></a>
## Evidence and Operational Consequences

Concept: [Consequences](0023-experimental-public-session-protocol.md#concept-adr-0023-consequences).

Acceptance evidence includes exact schema and vector digests; facade-versus-wire
semantic parity; a raw external-process transcript proving admission before
asynchronous work; malformed, duplicate-key, oversized, fragmented, multi-frame,
and slow-reader cases; stdout/stderr separation; kill and restart; and executed
Elixir, Python, and JavaScript clients. The external clients use their language
standard libraries on named evidence lanes and are not new repository bootstrap
dependencies.

A real-provider task is driven entirely through the app-server and retains the
same provider evidence limitations M2 states. No offline gate claims that a
credential's presence proves a network request.

<a id="technical-adr-0023-compatibility"></a>
## Rollback Mechanics

Concept: [Compatibility, migration, and rollback](0023-experimental-public-session-protocol.md#concept-adr-0023-compatibility).

The schema manifest maps one generation to exact schema and vector digests.
Rollback before closure removes the ninth application and its schema/client
artifacts together. The codec uses stdlib JSON and adds no external dependency. `loopex_protocol`
may retain private implementation helpers only if they expose no unaccepted wire
contract. `VERSION=0.1.0` is applied at the closure rejoin, after the separately
approved inherited gate generations can validate the canonical version rather
than a literal `0.0.0`.
