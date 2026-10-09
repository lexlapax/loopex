# App Server Protocol — Technical Depth

<a id="technical-depth"></a>
## Technical depth

Concept: [App server protocol](app-server-protocol.md#concept).

This companion projects the accepted current M7 wire contract and prepared
implementation candidate. It names required evidence, not completed
qualification or closure. Complete manifests supply the inventories consumed by
`LoopexProtocol.Session` for foreground /3 and `LoopexProtocol.Session.V2`
for daemon /4. Schemas and literal vectors live in `apps/loopex_protocol/priv/`;
no partial manifest independently activates serving.

<a id="technical-protocol-generation"></a>
## Generation and Negotiation

Concept: [Experimental is in the name on purpose](app-server-protocol.md#concept-protocol-experimental).

| Generation | Served by | Module | Schema and vectors |
| --- | --- | --- | --- |
| `loopex.experimental/3` | the app server, over standard input and output | `LoopexProtocol.Session` | `priv/schema/loopex-experimental-3.json`, `priv/vectors/loopex-experimental-3.json` |
| `loopex.experimental/4` | the daemon, over its Unix-domain socket | `LoopexProtocol.Session.V2` | `priv/schema/loopex-experimental-4.json`, `priv/vectors/loopex-experimental-4.json` |

Each server selects only its own literal. Old-only /1 or /2 offers and the
other current server's /3 or /4 offer refuse before session authority. A mixed
offer succeeds only for that server's literal. Clients verify generation and
independently pinned exact schema digest before session work, and close on
mismatch without downgrade or mutation replay.

`LoopexProtocol.Canonical.digest/1` uses revision `loopex.canonical.v1` over
exactly seven members: `generation`, `canonicalization_revision`, `methods`,
`record_families`, `error_codes`, `limits`, `payload_definitions`. Definitions
include every request, result, event/snapshot and referenced nested union,
including artifact refusal branches. List order is part of the preimage.
Unknown manifest keys, duplicate JSON keys and non-integer schema numbers
refuse. JSON file serialization is not the digest recipe.
`current-contract-manifests.v1.json` pins both complete canonical preimages and
literal digests for the independent Node consumer.

Historical generation 1 was named `loopex.session.v1-experimental` before its
rename. That rename changed its metadata digest while the original methods,
families, codes, limits, manifest and vectors stayed the same, as recorded by
the public-schema conformance test at that revision. Historical /1 and /2
identities remain evidence at their original tested revisions. The before-1.0
candidate removes their product schemas/vectors after caller migration; it
keeps no compatibility decoder or old-client promise.

Every request is one object carrying `method` and a `request_id`. The first must
be `initialize`:

```json
{"method":"initialize","request_id":"c1","generations":["loopex.experimental/3"],"capabilities":[]}
```

Initialization happens exactly once per connection; a second attempt is refused
with `already_initialized`, and any other method before it with
`not_initialized`. The server selects the first offered generation it knows or
refuses with `unsupported_generation`, and a connection refused that way is
still uninitialized, but its valid negotiation attempt is spent. A later
initialize returns `already_initialized`; other methods return
`not_initialized`. Malformed initialization does not spend the valid attempt.
Foreground keeps its bounded loop until EOF/host failure; daemon keeps its
original accept-time initialization deadline. The `initialized` record carries `selected_generation`,
`exact_schema_sha256`, `supported_methods`, `record_families`, and `limits`, so
a client can verify the contract it is about to speak rather than assume it.

<a id="technical-protocol-methods"></a>
## The eighteen foreground methods

Concept: [One contract, not a second loop](app-server-protocol.md#concept-protocol-one-contract).

Besides `initialize`, the foreground candidate has eighteen methods:

| Group | Methods |
| --- | --- |
| Lifecycle | `session.create`, `session.resume`, `session.inspect`, `session.attach` |
| Driving a run | `session.prompt`, `session.steer`, `session.follow_up`, `session.abort` |
| Settled configuration and maintenance | `session.configure`, `session.compact` |
| Interactions | `session.respond_interaction` |
| Resources and skills | `resources.catalog`, `resources.read`, `session.admit_resources`, `session.activate_skill` |
| Artifacts | `artifact.open_transfer`, `artifact.read_chunk`, `artifact.close_transfer` |

A method the generation does not name is refused with `unsupported_method`, and
that check precedes every other one, so a runtime-nil guard cannot mask an
unimplemented method and report the wrong reason. Unknown fields are refused.

`session.create` carries command identity and closed `session_options` with
required JSON integer `version: 1`. The only optional members are nonempty
`configuration` and ordered unique `tools`. Omission selects the host-captured
tools; `[]` selects none. Explicit tools contain zero through 1,024 unique names
matching `^[a-z][a-z0-9_]{0,63}$` in authored order. Configuration permits only `model`, `reasoning`, raw
four-section `instructions`, `max_tokens`, `context_token_budget` and
`system_class_tokens`. Its three numeric ceilings are positive uint64 decimal
strings. Supplied-member presence, authored bytes and tool order are retained.
Host routes, credentials, definitions, capabilities, paths, helper roles and
cleanup settings refuse. See
[ADR 0055's grammar](../adr/0055-remote-session-creation-options-technical.md#technical-options).

`session.attach` takes `session_id`, optional `after_event_sequence` and optional
`replace`, and returns a snapshot. The connection owns the attachment. Prompt,
steer, follow-up, abort, answer, configure, compact and artifact work use it and
refuse `not_attached` without one. Another attach refuses `attachment_conflict`
unless `replace: true` replaces that connection's own attachment. Foreground
has no session-list method.

`session.configure` carries command identity and nonempty closed `changes` over
the same six mutable configuration members. It requires the owning settled
boundary and cannot change immutable tools or host maintenance inputs.
`session.compact` carries command identity and complete explicit `bounds`:
`max_attempts`, `deadline_ms`, `token_budget`, as decimal strings in 1 through 4,
1 through 60,000 and 1 through 32,768 respectively. Admission, unknown outcome
and completion remain distinct.

Prompt text is unpadded base64url `content_b64`. Optional prompt bounds retain
partial ordinary overrides and optional `deadline_at_ms`; follow-up bounds
permit only `deadline_at_ms`; steer has no bounds. Turns/tokens retain arbitrary
positive-integer decimal domains, relative deadline is positive uint64, and the
authored absolute deadline is a positive safe JSON integer. Omission and empty
bounds remain distinct command inputs. No decoder rounds through floats.

An answer carries `interaction_id`, command identity and exactly one `answer`
branch: `{choice_id}`, `{text}` or `{disposition: "declined"}`. Choice identity
is opaque; text is 1 through 8,192 UTF-8 bytes; decline has no extra member.
The owning question validates the branch. Policy-defer keeps only its choice
branch, and an answer or identity grants no authority.

Inspection has exactly eleven required public fields: `status`,
`event_sequence`, `active_run_id`, `cleanup_grace_ms`,
`active_context_token_budget`, `pending_work_ids`, `open_interaction`,
`configuration`, `active_bounds`, `checkpoint`, `active_maintenance`.
Configuration exposes its arbitrary positive-integer committed version as a
canonical decimal string, exact model/reasoning, effective
reply/context/system ceilings and instruction version/digest. Active bounds
and maintenance use captured closed DTOs. Raw instructions, private
continuation, provider capability/mapping envelopes, credentials, owner epochs
and internals are absent.

<a id="technical-protocol-records"></a>
## Seven Record Families

`initialized`, `result`, `snapshot`, `admission`, `error`, `event`, `progress`.

An `admission` carries `status` `accepted` or `refused` with a stable `reason`,
and a session identity on successful create/resume. Retained creation
cancellation is exactly `{type, request_id, method, command_id, status, reason}`
with method `session.create`, status `refused`, reason `creation_cancelled`;
`session_id` and `disposition`, including null forms, are absent. Decoding the
envelope does not prove cancellation. See
[ADR 0061](../adr/0061-creation-cancellation-admission-envelope-technical.md#technical-adr-0061-decision).
Admission is not completion.

A `snapshot` is anchored to an exact durable `event_sequence`. It is not a live
process-state read and does not advance as events are consumed. Snapshot
revision 3 retains configuration, checkpoint, active maintenance, open
interaction and last standalone compact result at that cursor. It accumulates
neither raw private configuration nor every historical question.

An `event` carries `kind`, `event_id`, `event_sequence` and kind-specific
closed `data`. Its twenty kinds are `user.message_appended`, `run.started`,
`assistant.message_appended`, `tool.started`, `tool.finished`, `run.finished`,
`steer.resolved`, `follow_up.resolved`, `session.settled`,
`interaction.requested`, `interaction.answer_admitted`, `interaction.resolved`,
`interaction.expired`, `interaction.cancelled`, `interaction.answered`,
`interaction.declined`, `session.configured`, `context.compacted`,
`context.maintenance_changed`, `context.compaction_finished`. Shared codecs
check configuration, checkpoint, maintenance and interaction DTOs. Standalone
compact can finish checkpointed, unchanged or failed; its completion is distinct
from a checkpoint event. Known event kinds never authorize private-map pass-through.

Progress has seven closed families: `text_delta`, `reasoning_delta`,
`tool_call_delta`, `tool_progress`, `model_stream_closed`, `tool_stream_closed`,
`context.compaction_progress`. Ordinary families keep owning identities,
sequences, counts and closure dispositions. Compaction activity contains only
`kind`, `episode_id`, exact `{kind, id}` owner, `stream_domain_id`,
`progress_sequence: "0"`, `base_event_sequence`. It has no closing companion,
never proves completion and never advances the event cursor. Frame/queue limits
apply in addition to member limits. Base64 content must fit the enclosing
131,072-byte string ceiling: 98,304 raw bytes fit, 98,305 refuse before emission.
This projection does not shrink Core's independent content allowance. Tool
versions likewise retain their semantic-version grammar and enclosing 131,072-byte
string ceiling; passing a field regex alone cannot authorize an oversized frame.

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

<a id="technical-protocol-artifacts"></a>
## Artifact opening and refusal branches

Concept: [Verified artifacts and truthful cleanup](app-server-protocol.md#concept-protocol-artifacts).

`artifact.open_transfer` takes literal `use_ref` equal to `use:` plus 64
lowercase hex characters, canonical uint64 `start_offset`, and optional
`window_length` in the same decimal-string domain. It decodes to the actual use
locator; null length refuses and omission means the remaining window. The actual
attachment supplies session/holder binding. No object argument or base64
reference-envelope fallback is accepted.

Success keeps seven compact result fields: `object_reference`, `use_reference`,
`transfer_ref`, `total_size`, `window_start`, `window_end_exclusive`,
`object_digest`. Object reference is the closed digest/size/locator triple; use
reference also retains verified media type, role, canonicalization revision,
use digest and locator. Size/window quantities are decimal strings. Paths and
private session/run/operation provenance are excluded.

Admitted opening refusal is exactly six keys: `type`, `request_id`, `code`,
`message`, `reason`, `cleanup`. Type is `error`, code `transfer_refused`, message
bounded redacted server text, cleanup `proved` or `unproved`. Its seventeen
reasons are `invalid_artifact_request`, `invalid_open_context`,
`reservation_required`, `reservation_conflict`, `unknown_artifact_use`,
`artifact_use_mismatch`, `artifact_integrity_failed`, `artifact_digest_mismatch`,
`unknown_artifact`, `artifact_too_large`, `invalid_window`,
`open_deadline_exhausted`, `open_work_budget_exhausted`, `transfer_limit_reached`,
`transfers_unavailable`, `artifact_unreadable`, `cancelled`.

Ordinary pre-admission, read and close refusals have exactly the same five keys
without `cleanup`. A missing cleanup cannot represent admitted opening. Their
closed reason sets are operation-specific:

| Branch | Reasons |
| --- | --- |
| Open before admission | `attachment_required`, `invalid_attachment`, `stale_attachment`, `invalid_artifact_request`, `artifact_transfer_unsupported`, `transfer_limit_reached`, `open_work_budget_exhausted`, `transfers_unavailable` |
| Read | `attachment_required`, `invalid_attachment`, `stale_attachment`, `unknown_transfer`, `invalid_chunk_length`, `open_work_budget_exhausted`, `transfers_unavailable`, `read_deadline_exhausted`, `artifact_unreadable`, `runtime_unavailable` |
| Close | `attachment_required`, `invalid_attachment`, `stale_attachment`, `unknown_transfer`, `cleanup_unproved` |

This ordinary union has fourteen names and authorizes no arbitrary adapter atom.
Unknown adapter results use `internal_failure`. Neither branch exports private
receipt/work/pending identity, PID, handle or adapter details. A decoded cleanup
label supplies no physical proof.

Accepted [ADR 0066](../adr/0066-owned-artifact-transfer-opening-technical.md#technical-adr-0066-custody)
requires non-I/O reservation then one-use opening under the original custodian.
Use resolution, canonical/session checks, complete object verification, response
validation and adoption share one original 60,000 ms opening cutoff. Early failure
responds immediately; expiry responds independently of blocked callbacks.
Cleanup has one separately anchored 5,000 ms observation, with no response
extension, renewed timeout or extra join grace. Reserved/adopted retirement
requires Store physical proof, original invocation completion, matching receipt
ack and original custody joins before release. A conclusively never-reserved
branch needs no receipt/ack, but all acquired original joins. Lost registration
additionally needs expired original opening cutoff, no permission and exact
original Store-owner confirmation. Late proof reclaims prospectively only;
it never rewrites a refusal or supplies timely success.

Object size remains 67,108,864 bytes; verification reserves 134,217,728 payload-work
bytes for source reads plus conservative attempted snapshot writes. At most
131,073 returned metadata bytes are additional. Failed/cancelled work charges
once with no refund; unknown accounting retains conservative reservation or
unavailable state. The actual connection charges
`max(1,048,576, source_read + snapshot_write_debit + metadata_read)` per opening,
plus emitted snapshot reads once, within 1,073,741,824 bytes. Pending, live,
retiring and unacknowledged entries retain two connection/attachment slots and
four runtime slots; genuine job reservations share Store headroom. These are
required invariants, not proof established by this documentation.

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
| Artifact opening use reference | Literal `use:` plus 64 lowercase hex characters; no base64 envelope |
| Artifact result references | Closed object/use DTOs; quantities are canonical decimal strings |

A quantity is a string because the contract admits exactly one representation.
Opaque identities compare by original bytes. A use locator identifies retained
provenance; it is not a path or an authority grant.

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
| Artifact object / verification buffer bytes | 67,108,864 / 65,536 |
| Artifact opening response / cleanup observation ms | 60,000 / 5,000 |
| Artifact opening payload / returned metadata work bytes | 134,217,728 / 131,073 |
| Artifact read deadline / successful-open lifetime ms | 5,000 / 600,000 |
| Artifact connection work / minimum opening debit bytes | 1,073,741,824 / 1,048,576 |
| Artifact slots per connection/attachment / runtime | 2 / 4 |

Both delivery dimensions are checked **before** a record is queued; checking
afterwards makes the bound "whatever arrived, plus one", which for a 4 MiB
budget is not a bound. Durable overflow detaches at the cursor; progress
overflow drops. General reply/queue ceilings never extend the artifact opening
or cleanup clock. A host may refuse earlier; an earlier transport response is
not evidence that original storage custody completed within its own cutoff.

<a id="technical-protocol-transport"></a>
## The Transport Process

Concept: [Foreground, not a daemon](app-server-protocol.md#concept-protocol-foreground).

`Loopex.AppServer.Stdio.serve/2` receives the composed runtime and optional
host-owned native progress sink; the one-argument form uses the default sink.
Stdio owns the raw input port, serial dispatcher, attachment holder and bounded
output FIFO. One request worker may block in a runtime call while Stdio receives
input and exact cleanup controls. An independent `OutputWriter` owns physical
stdout work. Stdio retains active-record/native lease charges through exact
writer completion; queued progress drops only through its owning discard and
credit-release path.

`Loopex.AppServer.Host.serve/0` composes launch inputs through
`LoopexComposition.with_runtime/2` and serves until input ends. Input arrives
through `Port.open({:fd, 0, 1}, [:in, :binary, :stream, :eof])`, opened by its
actual owning reader. Raw bytes retain CR for strict CRLF refusal; blocking
line/block reads would lose that property or responsiveness. **Start with
`-noinput`** so the port exclusively owns stdin; serve warns on stderr otherwise.

OutputWriter owns an OS proxy and exact stdout worker with private control
pipes. Successful write requires physical write and exact worker/process-group
joins; actor DOWN or timer alone is not physical completion. Each write keeps
its original 5,000 ms write cutoff and following 5,000 ms cleanup cutoff. A retired
writer closes the connection rather than treating a partial frame as success.
Replies reserve FIFO capacity before facade dispatch; queued/active records
retain charges and native progress follows its exact acknowledgement path.

Stdout contains protocol frames only; diagnostics use separately bounded stderr.
The selective loop preserves unrelated host messages while checking actual
actor/incarnation/request references for its controls. EOF retires input,
request and writer custody through the original cleanup path and releases the
actual holder without aborting the durable session. Truncated input produces
`invalid_frame` when output is available. Cleanup timeout/unjoined physical
custody remains uncertainty, never success inferred from a disappeared PID.

<a id="technical-protocol-generation-two"></a>
## The Daemon's Generation

Concept: [What the daemon's generation adds](app-server-protocol.md#concept-protocol-daemon).

The daemon candidate carries the foreground methods, families, codes and limits,
for twenty-two methods after initialization, and adds:

| Addition | Members |
| --- | --- |
| Methods | `session.list` (`limit` 1 … 256, optional `after_session_id`), `daemon.status`, `session.acquire_control` (`session_id`), `session.release_control` (`session_id`, `writer_epoch`) |
| Record families | `daemon.stopping` (`reason`, `message`), `daemon.notice` (`code` `index_write_failed`, `session_id`, `message`) |
| Error codes | `control_held`, `control_not_held`, `control_pending`, `control_capacity_reached`, `control_owner_lost`, `session_dormant`, `session_unavailable`, `daemon_stopping`, `session_unknown`, `store_unavailable`, `activation_ceiling_reached`, `composition_mismatch` |
| Limits | `connections_per_daemon` 512, `initialize_deadline_ms` 30,000, `attachments_per_session` 64, `attachments_per_daemon` 512, `session_list_page_max` 256, `session_index_entries` 4,096, `lease_term_ms` 30,000 |

`session.acquire_control` answers with a `writer_epoch` and `expires_in_ms`. The
holder renews by calling it again before the term lapses, and the result then
carries `renewed: true`. Every mutation of an existing session —
`session.resume`, `session.configure`, `session.compact`, `session.prompt`,
`session.steer`, `session.follow_up`, `session.abort`,
`session.respond_interaction`, `session.admit_resources`,
`session.activate_skill`, and `session.release_control` — carries that
`writer_epoch`. A second client asking for control while it is held receives
`control_held` or `control_pending` and asks again; it is never granted control
over a live holder. `daemon.stopping` names `operator_stop`, `store_lost`,
`store_capacity_exceeded`, or a `fatal:<class>` reason. How the daemon keeps
leases, connections, and output bounded is in
[the daemon pair](daemon-technical.md#technical-depth).

<a id="technical-protocol-evidence"></a>
## Required evidence

| Claim | Where |
| --- | --- |
| Complete canonical preimages, literal digests and positive/negative vectors | `apps/loopex_protocol/test/current_contract_manifest_test.exs`, `apps/loopex_protocol/test/public_schema_conformance_test.exs`, `clients/node/current-contract-manifest-vectors.mjs`, `clients/node/contract-negotiation-tests.mjs` |
| Method and record shapes against the foreground /3 schema | `apps/loopex_protocol/test/session_schema_test.exs` |
| Method and record shapes against the daemon /4 schema | `apps/loopex_protocol/test/session_v2_schema_test.exs` |
| Framing and decoding refusals | `apps/loopex_protocol/test/frame_test.exs`, `apps/loopex_protocol/test/wire_test.exs` |
| Facade and wire agree on identities and meaning | `apps/loopex_app_server/test/session_mapping_test.exs` |
| Mapping negatives and real effects | `apps/loopex_app_server/test/foundation_mapping_test.exs` |
| Delivery bounds and slow readers | `apps/loopex_app_server/test/delivery_bounds_test.exs` |
| An independent client drives a whole session, and the skill, interaction, and artifact chain, over a real process | `apps/loopex_app_server/test/external_workflow_test.exs` |
| An independent client observes and takes over a session over the daemon's socket | `apps/loopex_daemon/test/external_socket_workflow_test.exs` |

These paths name required proof, not a passing run. Coordinated integration,
both supported pairs and the independent/real-provider lanes remain necessary.

The vectors are literal byte strings with literal verdicts, not values generated
from the implementation they check. A generated vector proves only that this
encoder and this decoder agree with each other.

## Related

- [Architecture technical depth](architecture-technical.md#technical-depth).
- [Compatibility surfaces](compatibility-surfaces.md#concept).
- [Operator app server runbook](../operator/app-server.md#concept).

Back to the [developer index](README.md).
