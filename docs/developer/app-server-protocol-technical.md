# App Server Protocol — Technical Depth

<a id="technical-depth"></a>
## Technical depth

Concept: [App server protocol](app-server-protocol.md#concept).

This companion is the normative wire reference: the generation, the methods,
the record families, the error codes, the identities and their encodings, the
exact limits, and where the schema, the vectors and the evidence live.

<a id="technical-protocol-generation"></a>
## Generation and Negotiation

```
loopex.session.v1-experimental
```

Initialization happens exactly once per connection; a second attempt is refused
with `already_initialized`, and any other method before it with
`not_initialized`. The client offers an ordered list of generations; the server
selects one it knows or refuses with `unsupported_generation`. There is no
partial match.

The `initialized` record reports the selected generation, the exact schema
digest, the supported methods and the limits below, so a client can verify the
contract it is about to speak rather than assume it.

Schema and vectors are the contract's data files, bound at M4 closure and
changed only with the generation they describe:

| File | Role |
| --- | --- |
| `apps/loopex_protocol/priv/schema/loopex-experimental-1.json` | The method and record shapes |
| `apps/loopex_protocol/priv/vectors/loopex-experimental-1.json` | Canonical positive and negative vectors |

<a id="technical-protocol-methods"></a>
## The Sixteen Methods

| Group | Methods |
| --- | --- |
| Lifecycle | `session.create`, `session.resume`, `session.inspect`, `session.attach` |
| Driving a run | `session.prompt`, `session.steer`, `session.follow_up`, `session.abort` |
| Interactions | `session.respond_interaction` |
| Resources and skills | `resources.catalog`, `resources.read`, `session.admit_resources`, `session.activate_skill` |
| Artifacts | `artifact.open_transfer`, `artifact.read_chunk`, `artifact.close_transfer` |

An unimplemented method is refused with `unsupported_method`, and the check for
whether a method exists precedes every other check — otherwise a runtime-nil
guard masks an unimplemented method and reports the wrong reason.

`session.attach` returns the attachment on the connection rather than to the
caller alone: the connection holds it, because a later command is admitted
through the same attachment and a transport delivers what that attachment
publishes.

This generation does not list sessions over the wire.

<a id="technical-protocol-records"></a>
## Seven Record Families

`initialized`, `result`, `snapshot`, `admission`, `error`, `event`, `progress`.

An `admission` says a command was accepted and journaled. It is not completion:
what the run then does arrives as `event` records.

A `snapshot` is anchored to an exact durable `event_sequence`. It is not a live
process-state read and does not advance as events are consumed.

<a id="technical-protocol-errors"></a>
## Fifteen Error Codes

`invalid_frame`, `invalid_request`, `not_initialized`, `already_initialized`,
`unsupported_generation`, `unsupported_method`, `not_attached`,
`attachment_conflict`, `capacity_exceeded`, `facade_unavailable`,
`recovery_required`, `admission_unknown`, `transfer_refused`, `detached`,
`internal_failure`.

An error carrying no `request_id` is about the connection rather than about a
request. A client must not attribute it to whichever request happens to be in
flight.

<a id="technical-protocol-wire"></a>
## Wire Representations

| Kind | Encoding |
| --- | --- |
| Identity | Unpadded base64url, 1 … 65,536 decoded bytes; a padded value is refused |
| Session identity | The same, 1 … 256 decoded bytes |
| Quantity (`u64`) | Canonical decimal **string** — no sign, no leading zero except zero itself, no whitespace. A JSON number is refused even when it would fit |
| Digest | 64 lowercase hex characters |
| Bytes | Unpadded base64url |
| Artifact reference | Base64url of the sorted-member JSON object `{digest, locator, size, use_locator}`, with `size` as a decimal string |

A quantity is a string because the contract admits exactly one representation; a
client that sent a number has not read the contract. The reference is opaque and
compared by bytes, so a client building one must sort members exactly as the
server encodes them.

<a id="technical-protocol-framing"></a>
## Framing and Decoding

One JSON object per line, LF-delimited. The transport reads raw bytes rather
than using line reading, because the input device's own line reading strips a
carriage return before the newline and this contract makes CRLF an error — a
server that trusted the device would silently admit a framing the contract
refuses.

`LoopexProtocol.Frame` refuses: duplicate members, depth above 16, more than
1,024 members, strings over 131,072 bytes, integers outside ±(2⁵³ − 1), any
float, trailing bytes after a complete value, and control characters inside
strings. Encoding emits members in sorted order.

<a id="technical-protocol-limits"></a>
## Exact Limits

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

Both delivery dimensions are checked **before** a record is queued. Checking
afterwards makes the bound "whatever arrived, plus one", which for a 4 MiB
budget is not a bound. Durable overflow detaches at the cursor; progress
overflow drops.

<a id="technical-protocol-transport"></a>
## The Transport Process

`Loopex.AppServer.Stdio.serve/1` is one process that reads, answers, pulls
durable events, and is the only writer.

Input arrives as port messages: `Port.open({:fd, 0, 1}, [:in, :binary, :stream, :eof])`.
This is not a style choice. A read that asks a pipe for a block returns only
when the block fills or the writer closes, so a server built on blocking reads
answers a client's first frame only after the client has given up. The port must
be opened in the reading process, which owns it.

**The VM must be started with `-noinput`**, or it owns standard input for its own
shell; `serve/1` warns on standard error rather than stalling silently.

Standard output carries protocol records only. Every complete frame in a chunk
is answered before the next chunk is read, so a client writing several frames at
once receives its answers in order. Input ending mid-frame produces an
`invalid_frame` record rather than silence.

<a id="technical-protocol-evidence"></a>
## Evidence

| Claim | Where |
| --- | --- |
| Canonical positive and negative vectors, with distinct refusal reasons | `apps/loopex_protocol/test/public_schema_conformance_test.exs` |
| Method and record shapes against the schema | `apps/loopex_protocol/test/session_schema_test.exs` |
| Facade and wire agree on identities and meaning | `apps/loopex_app_server/test/session_mapping_test.exs` |
| Mapping negatives and real effects | `apps/loopex_app_server/test/foundation_mapping_test.exs` |
| Delivery bounds and slow readers | `apps/loopex_app_server/test/delivery_bounds_test.exs` |
| An independent client drives a whole session, and the skill, interaction and artifact chain, over a real process | `apps/loopex_app_server/test/external_workflow_test.exs` |

The vectors are literal byte strings with literal verdicts, not values generated
from the implementation they check. A generated vector proves only that this
encoder and this decoder agree with each other.

## Related

- [Architecture technical depth](architecture-technical.md#technical-depth).
- [Compatibility surfaces](compatibility-surfaces.md#concept).
- [Operator app server runbook](../operator/app-server.md#concept).

Back to the [developer index](README.md).
