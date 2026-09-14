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

Each input frame is one JSON object followed by LF. The JSON payload, excluding
the final LF, is at most 65,536 bytes before initialization and 1,048,576 bytes
after it. Each encoded output record, including LF, is at most 2,097,152 bytes.
CRLF, a top-level non-object,
trailing bytes, invalid UTF-8, a frame beyond the negotiated pre-initialization
ceiling, and EOF inside a frame are protocol errors. A decoder first preserves
object member order so duplicate keys can be rejected before conversion to a
map. It decodes keys as strings and never interns input.

The decoder admits at most 16 nested arrays/objects and 1,024 members in any
one array or object. A decoded string is at most 131,072 UTF-8 bytes unless a
method-specific contract is tighter. JSON integers are accepted only in the
exact IEEE-754-safe interval from -(2^53 - 1) through 2^53 - 1. Opaque binary
identities inherited from M3 are reversible unpadded base64url encodings of
their original bytes; the transport admits 1–65,536 bytes (at most 87,382
wire characters), and each method retains any tighter facade bound. In
particular session and runtime placement IDs are at most 256 original bytes,
while the existing session-command `command_id` and `run_id` validators admit
up to 65,536 bytes. The decoder does not narrow an identity's underlying
alphabet. Session/event sequences, cursors,
artifact sizes and offsets that may use the full unsigned 64-bit domain are
canonical decimal strings, never JSON numbers. Connection-local `request_id`
is 1–64 ASCII bytes from `[A-Za-z0-9._~-]` and is not reused while in flight.

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
later `session.settled`. Accepted ADR 0011 requires the latter, but Closed M3
does not yet emit it; M4 adds the core public fact in the same terminal
transaction when no follow-up is queued before mapping it to the wire. It
never invents a transport-only `run.terminal` synonym. A query response carrying a map is not a snapshot merely because it
echoes a session ID: snapshot responses bind the same session, a canonical
decimal-string `event_cursor`, a snapshot at that exact `event_sequence`, and the authoritative
active-run state.

### Operations

The generation contains methods for `session.create`,
`session.resume`, `session.inspect`, `session.attach`, `session.prompt`,
`session.steer`, `session.follow_up`, `session.abort`,
`session.respond_interaction`, `resources.catalog`, `resources.read`,
`session.admit_resources`, `session.activate_skill`, `artifact.open_transfer`,
`artifact.read_chunk`, and `artifact.close_transfer`.
Project-resource trust is fixed by the host at launch, not changed by a wire
method. `resources.catalog` and `resources.read` map M3's
`resource_catalog` and `read_resource` facade queries,
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

`session.list`, `project_resources.inspect`, and
`project_resources.decide` are unavailable methods in this generation.
Unknown-method refusal applies to them before any directory scan, resource
trust change or durable admission. A host may use M3's local session directory
outside this wire contract; a client resumes only a session ID it retained or
the operator supplied. The existing `Loopex.list_sessions/1` materializes its
directory and is not a bounded implementation of a wire list. Project
manifest inspection and trust decision remain host launch configuration, and
the runtime's launch inputs cannot be changed by a later client frame.

Unknown query methods return a bounded error. Unknown mutating methods are
refused before durable admission. Unsupported future capability families are
reported during initialization and never guessed from method names.

### Generation-one wire data transfer objects

The following names are wire keys, not Elixir atom keys. A client request is a
flat object with exactly `method`, `request_id`, and the fields in its row below;
an optional field is absent rather than `null` unless its row says otherwise.
Unknown fields refuse before a facade call. All binary identities use the
unpadded base64url representation defined above and are decoded before calling
the facade. A `digest` is 64 lowercase hexadecimal characters; `u64` is a
canonical unsigned decimal string; `bytes` is unpadded base64url of the exact
bytes, not a UTF-8 rendering. `plain_object` is a bounded JSON object whose
members recursively satisfy the frame limits. It cannot carry a PID, function,
atom name, unlisted command selector, or non-JSON term. A method's narrower M3
facade validator still applies after wire validation; failure refuses rather
than truncates.

The response envelope has `type` and, for a response to a request,
`request_id`. An `initialize` request has `generations` (a nonempty ordered
array of generation strings) and `capabilities` (an array of capability
strings, possibly empty). Its successful `type = "initialized"` reply has
`selected_generation`, `exact_schema_sha256`, `supported_methods` (the exact
sixteen names below), `record_families`, and `limits`. No capability string
implicitly enables an unlisted method. A successful query has `type =
"result"`, `method`, and `result`; successful `session.attach` has `type =
"snapshot"` and the snapshot fields below. A mutation resolved by the facade
has `type = "admission"`, `method`, `command_id`, `status = "accepted" |
"refused"`, and `reason` (a bounded reason code or `null`). A pre-admission
error or unavailable query has `type = "error"` and the error fields below.
No `request_id` is copied into a journal, event or progress record. A mutating
reply whose commit is unknown is an error with `code = "admission_unknown"`,
never a fabricated admission.

| Method | Additional request fields | Successful response body after facade result |
| --- | --- | --- |
| `session.create` | `command_id`: binary identity; `session_options`: `plain_object` | Admission also has `session_id`: binary identity; does not attach |
| `session.resume` | `session_id`, `command_id`: binary identities | Admission also has resumed `session_id`; does not attach |
| `session.inspect` | `session_id`: binary identity | Result is the public status projection defined below |
| `session.attach` | `session_id`: binary identity; optional `after_event_sequence`: `u64`; optional `replace`: boolean, default `false` | Snapshot response has `session_id`, `event_cursor`: `u64`, `snapshot`, and same-cursor `open_interaction` |
| `session.prompt` | `command_id`: binary identity; `content_b64`: nonempty bytes | Admission; ordinary durable events follow |
| `session.steer` | `command_id`, `run_id`: binary identities; `content_b64`: nonempty bytes | Admission |
| `session.follow_up` | `command_id`: binary identity; `content_b64`: nonempty bytes | Admission |
| `session.abort` | `command_id`: binary identity | Admission; this alone requests durable cancellation |
| `session.respond_interaction` | `command_id`, `interaction_id`: binary identities; `answer`: exactly `{ "choice_id": <base64url of an offered choice ID> }` | Admission; an answer is not an allow or executor grant |
| `resources.catalog` | `session_id`: binary identity | Result is the exact M3 catalog projection defined below |
| `resources.read` | `session_id`: binary identity; `manifest_digest`, `source_id`, `name`, `label`: M3 resource-request strings | Result has `digest`, `size`: `u64`, and `content_b64`: bytes |
| `session.admit_resources` | `command_id`: binary identity; `manifest_digest`: digest; `decision`: `null` or seven-field M3 project-skills decision | Admission; the decision is part of durable command identity |
| `session.activate_skill` | `command_id`: binary identity; `manifest_digest`, `pack_digest`: digests; `source_id`, `name`: M3 resource strings; `supporting_labels`: ordered M3 label array | Admission |
| `artifact.open_transfer` | `use_ref`: opaque use identity; `start_offset`: `u64`; optional `window_length`: `u64` | Result has `object_reference`, `use_reference` (public reference objects), `transfer_ref` (opaque identity), `total_size`, `window_start`, `window_end_exclusive`: `u64`, and `object_digest`: digest |
| `artifact.read_chunk` | `transfer_ref`: binary identity; `length`: integer from 1 through the negotiated raw-chunk ceiling | Result has `offset`: `u64`, `bytes_b64`: bytes, `chunk_digest`: digest, `eof`: boolean |
| `artifact.close_transfer` | `transfer_ref`: binary identity | Result has `closed: true`; no bytes or path |

`session.create` passes bounded `session_options` as the existing genesis
options and binds its durable `command_id`; the app-server does not add or
replace run policy. `session.resume` takes a known session ID through the
public facade and enforces ADR 0008 runtime placement; it does not invent a
wire session directory. A fresh-process host first loads and compares its
retained configuration through M3's prepared recovery path before activating
work. No one-use recovery capability is serialized to the client; a host that
cannot prove the required binding returns `recovery_required` and does not
claim a successful resume. Both methods return a session ID even though the
caller must attach separately. `session.inspect` projects only `status`,
`event_sequence`: `u64`, `active_run_id`: identity or `null`,
`cleanup_grace_ms`: `u64`, `active_context_token_budget`: `u64` or
`null`, `pending_work_ids`: bounded array of identities, and
`open_interaction`: the view defined below or `null`. It omits owner
epoch, journal version, handles, and attachment state. The attachment's
`snapshot` is exactly `snapshot_revision = 2`, `session_id`,
`event_sequence`: `u64` equal to `event_cursor`, `active_run_id`: identity or
`null`, and `active_run_phase`: `"admitted_unstaged" | "started" | null`;
the active-run members are both null or both non-null. Absent
`after_event_sequence` requests the current tail; a supplied cursor invokes
the facade's retained-cursor replay. `replace = true` explicitly detaches the
prior attachment at its last completely emitted cursor. The separate
`open_interaction` field is captured by core at that same durable cursor,
never copied from a later status query. The unchanged revision-2 snapshot is
not extended or silently relabeled.

The `resources.catalog` result has exactly `configured_manifest_digest` and
`admitted_manifest_digest` (each a digest or `null`),
`decision_disposition` (the M3 disposition string), and `entries`. Each entry
has `pack_index` (safe JSON integer), `source_id`, `name`, `description`,
`pack_digest`, and `manual_only` (boolean). M3's 262,144-byte canonical catalog
ceiling applies before projection. `resources.read` uses the M3 four-key
request; its response's verified raw content is base64url-encoded. The
`session.admit_resources` decision is **project-skills admission**, distinct
from the root AGENTS.md launch-time `project_resources` trust decision. When
non-null it has exactly `manifest_digest`, `workspace_ref`, `trust_scope =
"project_skills"`, `decision_source = "interactive_operator" |
"host_supplied"`, `issued_at` (M3 ISO-8601 string), `expires_at = null`, and
`revocation_state = "active" | "revoked"`. The server passes it through the
existing facade validator; no wire field selects a resource root or changes
the host's project-root trust.

The artifact `use_ref` is exactly ADR 0015's public `use_locator` string,
`"use:"` followed by the lowercase use SHA-256 from the compact artifact
reference. It is an opaque use reference, not a filesystem path or a
client-constructed object triple. The facade resolves and validates its use
binding for the session and attachment. `object_reference` is the
existing public object triple `{digest, size, locator}` with `size` projected
as `u64`; `use_reference` is the existing compact public reference with exactly
`digest`, `size`: `u64`, `locator`, `media_type`, `role`,
`use_canonicalization_version`, `use_digest`, and `use_locator`. Neither
exposes the private artifact-use metadata or a filesystem path. The open response's
`window_end_exclusive` makes an empty window unambiguous. A read returns the
next sequential chunk, never a caller-selected offset. At the window end it
returns `bytes_b64 = ""`, the SHA-256 of empty bytes as `chunk_digest`,
`offset = window_end_exclusive`, and `eof = true`; a nonempty chunk has
`eof = false`. A chunk never exceeds `length`, the accepted raw-chunk ceiling,
or the window end. Closing consumes the reference; repeat close refuses as
unknown transfer.

The server's asynchronous record families have no `request_id`:

| `type` | Required fields | Meaning |
| --- | --- | --- |
| `event` | `session_id`, `event` | `event` has `kind`, `event_id`, `event_sequence`: `u64`, and `data` containing only the matching public-event fields; only this family advances the durable cursor |
| `progress` | `session_id`, `progress` | `progress` is one ADR 0011 projected delta or stream closure with `kind`, `stream_domain_id`, `base_event_sequence`: `u64`, and its kind's public fields; it never advances the durable cursor |

`event.data` retains the core public event kind's member names except the three
envelope members and converts binary identities to base64url, full-range
unsigned positions to decimal strings, and raw content to `content_b64`.
`run.finished` and `session.settled` remain distinct. ADR 0024's public
interaction event kinds are exactly `interaction.requested`,
`interaction.resolved`, `interaction.expired`, and `interaction.cancelled`;
the private `interaction_requested_v1` record kind is never a wire event.
The four interaction `event.data` shapes share exactly `interaction_id`,
`run_id`, `turn_id`, and `tool_call_id` (base64url identities), plus `status`.
Their remaining fields are closed:

| `kind` | `status` | Other `event.data` fields |
| --- | --- | --- |
| `interaction.requested` | `pending` | `request`, `effective_expires_at_unix_ms`: `u64` |
| `interaction.resolved` | `answered` or `denied` | `answer_choice_id` and `answer_command_id`, both base64url identities for `answered` and both `null` for `denied` |
| `interaction.expired` | `expired` | None |
| `interaction.cancelled` | `cancelled` | None |

The `request` has exactly `kind = "choice"`, nonempty bounded UTF-8 `prompt`,
and one to eight `choices`, each exactly `{id, label}` with base64url `id` and
nonempty bounded UTF-8 `label`. `effective_expires_at_unix_ms` is the retained
absolute wall-clock expiry, not a recomputed duration. `session.settled`
`event.data` is exactly `{run_id}`; its event envelope already supplies the
session and sequence. The fixed M3 artifact reference in `tool.finished` is
projected without a path. No interaction event discloses a policy module,
`decision_ref`, grant, or executor intent. An answered event records committed
answer evidence, not an allow; only separate committed policy/grant/intent
facts can authorize an effect.

`open_interaction` in a status or attachment response is `null` or one object
with exactly the four shared identities, `status = "pending" | "answered"`,
the same `request` and `effective_expires_at_unix_ms`, and
`answer_choice_id` and `answer_command_id` both `null` when pending or both
base64url identities when answered. The serial session owner exposes at most
one such open view. The attachment view and revision-2 snapshot are captured
at one cursor; a terminal interaction is never reintroduced by a stale
process-local answer. The status view is current at its own `event_sequence`.

`progress.kind` is one of `text_delta`, `reasoning_delta`,
`tool_call_delta`, `tool_progress`, `model_stream_closed`, or
`tool_stream_closed`. Its remaining fields retain ADR 0011's per-kind public
names and nullability: `turn_id`; `model_sequence` or `progress_sequence`;
`content_index`, `call_index`, `tool_call_id`, `name`,
`arguments_fragment`, `text`, `stream`, `byte_offset`, `chunk_b64`,
`disposition`, `delta_count`, or `progress_count` as applicable. Binary
identities and chunks follow the above encodings; counts and offsets that can
reach `u64` use decimal strings. `stream_domain_id` is an equality label,
not an attempt capability. A stream closure names `disposition = "complete" |
"abandoned"` and its exact count. A progress gap or missing closure sends the
client back to durable state rather than manufacturing a terminal event.

The error record has `type = "error"`, `code`, `message`, and `request_id`
only when a valid request ID was safely parsed for correlation. `invalid_frame`
is always uncorrelated because parsing failed; an `invalid_request` lacking a
valid request ID and an `internal_failure` before safe correlation are also
uncorrelated. No error fabricates a request ID from malformed bytes. `message`
is bounded server-authored text containing
no raw exception, command content, path, credential, or private policy term.
The top-level `code` set is `invalid_frame`, `invalid_request`,
`not_initialized`, `already_initialized`, `unsupported_generation`,
`unsupported_method`, `not_attached`, `attachment_conflict`,
`capacity_exceeded`, `facade_unavailable`, `recovery_required`, `admission_unknown`,
`transfer_refused`, `detached`, and `internal_failure`. A known facade
rejection of a well-formed durable command uses `admission` with
`status = "refused"` and a bounded stable `reason`; unexpected terms collapse
to `internal_failure` without serialization. A timed-out mutation uses only
`admission_unknown` and can be retried only under its original durable
`command_id`. On post-admission writer loss the server may emit one
uncorrelated `error` with `code = "detached"`, `session_id`, and `event_cursor`
(the last completely emitted durable cursor), then stops delivery. No error
makes an unknown mutation a known refusal.

`transfer_refused` adds one closed `reason` value. The set is
`object_missing`, `object_corrupt`, `use_mismatch`,
`capability_unsupported`, `invalid_window`, `transfer_unknown`,
`transfer_expired`, `open_deadline_exceeded`, `open_work_exceeded`,
`connection_transfer_limit`, `runtime_transfer_limit`,
`connection_work_exceeded`, `attachment_mismatch`, `session_mismatch`,
`runtime_mismatch`, `transfer_closed`, `read_deadline_exceeded`,
`read_length_exceeded`, and `transfer_cancelled`. It distinguishes ADR 0028's
refusal causes without putting an adapter exception or storage path in
`message`. The status of a timed-out read remains a refusal of that read,
not a claim that an earlier durable mutation failed.

### Bounds and backpressure

All protocol collections and strings have schema maxima no larger than the
server's negotiated limits. No more than 32 requests are in flight per
connection. The durable writer holds at most 64 records and 4 MiB of encoded
bytes; transient progress holds at most 32 records and 512 KiB. Both dimensions
are checked at admission, not after enqueue. Diagnostics hold at most 64
stderr lines and 64 KiB of encoded bytes; excess is dropped and counted, never
printed to stdout. Initialization, query, attachment, and admission reply
waits are 30 seconds; a blocked writer detaches after five seconds without
blocking a coordinator. A timed-out mutating admission is an unknown outcome:
retry uses the same durable `command_id` and no timeout implies refusal,
cancellation, or abort. A healthy idle foreground server has no global idle
expiry. ADR 0028 owns the separate chunk-read deadline. Decoder work,
per-frame memory and every gate wait are bounded.

The app-server process owns a bounded writer. When its progress queue fills it
may coalesce or drop progress within ADR 0011's rules. When durable output cannot
be retained, the connection detaches at the last reported cursor or a new
admission is refused before mutation. It never blocks a coordinator callback on
the client's read rate.

### Connection states, process loss and resume

| Situation | Required behavior |
| --- | --- |
| Before `initialize` | Every other frame refuses; nothing durable is created |
| First `initialize` with no common generation | Refuse and remain uninitialized; the process does not get a second negotiation attempt |
| Repeated `initialize` after success or refusal | Refuse without changing state; a successful connection remains initialized on its selected generation, and a refused one remains uninitialized |
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
