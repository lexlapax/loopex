# App Server Protocol — Technical Depth

<a id="technical-depth"></a>
## Technical depth

Concept: [App server protocol](app-server-protocol.md#concept).

This companion is the normative wire reference: the generations, the methods,
the record families, the error codes, the identities and their encodings, the
exact limits, and where the schemas, the vectors, and the evidence live. The
inventories are data in `LoopexProtocol.Session` (generation 1) and
`LoopexProtocol.Session.V2` (generation 2), and each generation's schema and
vectors are files in `apps/loopex_protocol/priv/`.

<a id="technical-protocol-generation"></a>
## Generation and Negotiation

Concept: [Experimental is in the name on purpose](app-server-protocol.md#concept-protocol-experimental).

| Generation | Served by | Module | Schema and vectors |
| --- | --- | --- | --- |
| `loopex.experimental/1` | the app server, over standard input and output | `LoopexProtocol.Session` | `priv/schema/loopex-experimental-1.json`, `priv/vectors/loopex-experimental-1.json` |
| `loopex.experimental/2` | the daemon, over its Unix-domain socket | `LoopexProtocol.Session.V2` | `priv/schema/loopex-experimental-2.json`, `priv/vectors/loopex-experimental-2.json` |

Each server selects only its own literal: the daemon refuses a client that
offers only generation 1 at initialize, and never downgrades. Generation 1 was
previously named `loopex.session.v1-experimental`; the generation string is one
of the schema digest's inputs, so the rename changed only that digest, and
`apps/loopex_protocol/test/public_schema_conformance_test.exs` proves the
methods, record families, error codes, limits, schema manifest, and vector
bytes are otherwise the same. The schema and vectors change only with the
generation they describe.

Every request is one object carrying `method` and a `request_id`. The first must
be `initialize`:

```json
{"method":"initialize","request_id":"c1","generations":["loopex.experimental/1"],"capabilities":[]}
```

Initialization happens exactly once per connection; a second attempt is refused
with `already_initialized`, and any other method before it with
`not_initialized`. The server selects the first offered generation it knows or
refuses with `unsupported_generation`, and a connection refused that way is
still uninitialized. The `initialized` record carries `selected_generation`,
`exact_schema_sha256`, `supported_methods`, `record_families`, and `limits`, so
a client can verify the contract it is about to speak rather than assume it.

<a id="technical-protocol-methods"></a>
## The Sixteen Methods

Concept: [One contract, not a second loop](app-server-protocol.md#concept-protocol-one-contract).

Besides `initialize`, generation 1 has sixteen methods:

| Group | Methods |
| --- | --- |
| Lifecycle | `session.create`, `session.resume`, `session.inspect`, `session.attach` |
| Driving a run | `session.prompt`, `session.steer`, `session.follow_up`, `session.abort` |
| Interactions | `session.respond_interaction` |
| Resources and skills | `resources.catalog`, `resources.read`, `session.admit_resources`, `session.activate_skill` |
| Artifacts | `artifact.open_transfer`, `artifact.read_chunk`, `artifact.close_transfer` |

A method the generation does not name is refused with `unsupported_method`, and
that check precedes every other one, so a runtime-nil guard cannot mask an
unimplemented method and report the wrong reason. Unknown fields are refused.

`session.create` takes a `command_id` and `session_options`; `session.attach`
takes a `session_id` and an optional `after_event_sequence` and answers with a
`snapshot`. The connection, not the caller, holds the attachment, because later
commands are admitted through it and the transport delivers what it publishes.
So `session.prompt`, `session.steer`, `session.follow_up`, `session.abort`, and
`session.respond_interaction` name no session: they act on the connection's
attachment and are refused `not_attached` without one. A prompt carries its
text as unpadded base64url in `content_b64`; an interaction answer carries
`interaction_id` and `answer: {"choice_id": ...}`. A connection holds at most
one attachment: a further `session.attach` is refused `attachment_conflict`,
for any session, unless it carries `replace: true`, which replaces the
connection's own attachment. Generation 1 does not list sessions.

<a id="technical-protocol-records"></a>
## Seven Record Families

`initialized`, `result`, `snapshot`, `admission`, `error`, `event`, `progress`.

An `admission` carries `status` `accepted` or `refused` with a stable `reason`,
and for `session.create` and `session.resume` the `session_id`. It says a
command was accepted and journaled; it is not completion.

A `snapshot` is anchored to an exact durable `event_sequence`. It is not a live
process-state read and does not advance as events are consumed.

An `event` carries one committed public event: `kind`, `event_id`,
`event_sequence`, and `data`. The kinds are `user.message_appended`,
`run.started`, `assistant.message_appended`, `tool.started`, `tool.finished`,
`run.finished`, `steer.resolved`, `follow_up.resolved`, `session.settled`,
`interaction.requested`, `interaction.resolved`, `interaction.expired`, and
`interaction.cancelled`. A `progress` record carries one transient item —
`text_delta`, `reasoning_delta`, `tool_call_delta`, `tool_progress`,
`model_stream_closed`, or `tool_stream_closed` — with its `stream_domain_id`
and `base_event_sequence`.

<a id="technical-protocol-errors"></a>
## Fifteen Error Codes

`invalid_frame`, `invalid_request`, `not_initialized`, `already_initialized`,
`unsupported_generation`, `unsupported_method`, `not_attached`,
`attachment_conflict`, `capacity_exceeded`, `facade_unavailable`,
`recovery_required`, `admission_unknown`, `transfer_refused`, `detached`,
`internal_failure`.

An error carrying no `request_id` is about the connection rather than about a
request; only `invalid_frame`, `invalid_request`, `internal_failure`, and
`detached` may arrive that way, and a client must not attribute one to whichever
request happens to be in flight. A `detached` error carries the `session_id`
and the `event_cursor` to reattach from. A `transfer_refused` error carries a
`reason` from a closed list.

<a id="technical-protocol-wire"></a>
## Wire Representations

| Kind | Encoding |
| --- | --- |
| Request identity | ASCII `[A-Za-z0-9._~-]`, 1 … 64 bytes, unique among the connection's in-flight requests |
| Identity | Unpadded base64url, 1 … 65,536 decoded bytes; a padded value is refused |
| Session identity | The same, 1 … 256 decoded bytes |
| Quantity (`u64`) | Canonical decimal **string** — no sign, no leading zero except zero itself, no whitespace. A JSON number is refused even when it would fit |
| Digest | 64 lowercase hex characters |
| Bytes | Unpadded base64url |
| Artifact reference | Base64url of the sorted-member JSON object `{digest, locator, size, use_locator}`, with `size` as a decimal string |

A quantity is a string because the contract admits exactly one representation.
The reference is opaque and compared by bytes, so a client building one must
sort members exactly as the server encodes them.

<a id="technical-protocol-framing"></a>
## Framing and Decoding

Concept: [Strictness is the feature](app-server-protocol.md#concept-protocol-strict).

One JSON object per line, LF-delimited. `LoopexProtocol.Frame` refuses:
duplicate members, depth above 16, more than 1,024 members, strings over 131,072
bytes, integers outside ±(2⁵³ − 1), any number with a fraction or exponent,
trailing bytes after a complete value, and control characters inside strings.
Keys stay binaries, so no input is ever interned. Encoding emits members in
sorted order.

<a id="technical-protocol-limits"></a>
## Exact Limits

Concept: [Two delivery planes, bounded separately](app-server-protocol.md#concept-protocol-planes).

| Limit | Value |
| --- | --- |
| `frame_bytes_before_initialization` | 65,536 |
| `frame_bytes` | 1,048,576 |
| `output_record_bytes` | 2,097,152 |
| `max_depth` | 16 |
| `max_members` | 1,024 |
| `max_string_bytes` | 131,072 |
| `max_identity_bytes` | 65,536 |
| `max_identity_wire_bytes` | 87,382 |
| `max_session_identity_bytes` | 256 |
| `integer_min` / `integer_max` | −9,007,199,254,740,991 / 9,007,199,254,740,991 |
| `max_requests_in_flight` | 32 |
| `durable_queue_records` / `durable_queue_bytes` | 64 / 4,194,304 |
| `progress_queue_records` / `progress_queue_bytes` | 32 / 524,288 |
| `diagnostics_lines` / `diagnostics_bytes` | 64 / 65,536 |
| `raw_chunk_bytes` | 32,768 |
| `reply_wait_ms` | 30,000 |
| `writer_detach_ms` | 5,000 |

Both delivery dimensions are checked **before** a record is queued; checking
afterwards makes the bound "whatever arrived, plus one", which for a 4 MiB
budget is not a bound. Durable overflow detaches at the cursor; progress
overflow drops.

<a id="technical-protocol-transport"></a>
## The Transport Process

Concept: [Foreground, not a daemon](app-server-protocol.md#concept-protocol-foreground).

`Loopex.AppServer.Stdio.serve/1` takes a runtime the host composed and is one
process that reads, answers, pulls durable events, and is the only writer.
`Loopex.AppServer.Host.serve/0` is the shipped host: it reads its launch inputs
from the environment, composes the reference stack inside
`LoopexComposition.with_runtime/2`, and serves one connection until input ends.

Input arrives as port messages from
`Port.open({:fd, 0, 1}, [:in, :binary, :stream, :eof])`, opened in the reading
process, which owns it. A read that asks a pipe for a block returns only when
the block fills or the writer closes, so a server built on blocking reads would
answer a client's first frame only after the client had given up. The transport
reads raw bytes rather than lines, because the input device's own line reading
strips a carriage return before the newline and this contract makes CRLF an
error.

**The VM must be started with `-noinput`**, or it owns standard input for its
own shell; `serve/1` warns on standard error rather than stalling silently.

Standard output carries protocol records only. Every complete frame in a chunk
is answered before the next chunk is read, so a client writing several frames
at once receives its answers in order. Input ending mid-frame produces an
`invalid_frame` record rather than silence.

<a id="technical-protocol-generation-two"></a>
## The Daemon's Generation

Concept: [What the daemon's generation adds](app-server-protocol.md#concept-protocol-daemon).

Generation 2 carries every generation-1 method, record family, error code, and
limit, and adds:

| Addition | Members |
| --- | --- |
| Methods | `session.list` (`limit` 1 … 256, optional `after_session_id`), `daemon.status`, `session.acquire_control` (`session_id`), `session.release_control` (`session_id`, `writer_epoch`) |
| Record families | `daemon.stopping` (`reason`, `message`), `daemon.notice` (`code` `index_write_failed`, `session_id`, `message`) |
| Error codes | `control_held`, `control_not_held`, `control_pending`, `control_capacity_reached`, `control_owner_lost`, `session_dormant`, `session_unavailable`, `daemon_stopping`, `session_unknown`, `store_unavailable`, `activation_ceiling_reached`, `composition_mismatch` |
| Limits | `connections_per_daemon` 512, `initialize_deadline_ms` 30,000, `attachments_per_session` 64, `attachments_per_daemon` 512, `session_list_page_max` 256, `session_index_entries` 4,096, `lease_term_ms` 30,000 |

`session.acquire_control` answers with a `writer_epoch` and `expires_in_ms`. The
holder renews by calling it again before the term lapses, and the result then
carries `renewed: true`. Every mutation of an existing session —
`session.resume`, `session.prompt`, `session.steer`, `session.follow_up`,
`session.abort`, `session.respond_interaction`, `session.admit_resources`,
`session.activate_skill`, and `session.release_control` — carries that
`writer_epoch`. A second client asking for control while it is held receives
`control_held` or `control_pending` and asks again; it is never granted control
over a live holder. `daemon.stopping` names `operator_stop`, `store_lost`,
`store_capacity_exceeded`, or a `fatal:<class>` reason. How the daemon keeps
leases, connections, and output bounded is in
[the daemon pair](daemon-technical.md#technical-depth).

<a id="technical-protocol-evidence"></a>
## Evidence

| Claim | Where |
| --- | --- |
| Canonical positive and negative vectors, with distinct refusal reasons | `apps/loopex_protocol/test/public_schema_conformance_test.exs` |
| Method and record shapes against the generation-1 schema | `apps/loopex_protocol/test/session_schema_test.exs` |
| Method and record shapes against the generation-2 schema | `apps/loopex_protocol/test/session_v2_schema_test.exs` |
| Framing and decoding refusals | `apps/loopex_protocol/test/frame_test.exs`, `apps/loopex_protocol/test/wire_test.exs` |
| Facade and wire agree on identities and meaning | `apps/loopex_app_server/test/session_mapping_test.exs` |
| Mapping negatives and real effects | `apps/loopex_app_server/test/foundation_mapping_test.exs` |
| Delivery bounds and slow readers | `apps/loopex_app_server/test/delivery_bounds_test.exs` |
| An independent client drives a whole session, and the skill, interaction, and artifact chain, over a real process | `apps/loopex_app_server/test/external_workflow_test.exs` |
| An independent client observes and takes over a session over the daemon's socket | `apps/loopex_daemon/test/external_socket_workflow_test.exs` |

The vectors are literal byte strings with literal verdicts, not values generated
from the implementation they check. A generated vector proves only that this
encoder and this decoder agree with each other.

## Related

- [Architecture technical depth](architecture-technical.md#technical-depth).
- [Compatibility surfaces](compatibility-surfaces.md#concept).
- [Operator app server runbook](../operator/app-server.md#concept).

Back to the [developer index](README.md).
