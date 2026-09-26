# Compatibility Surfaces

<a id="concept"></a>
## Concept

Every surface Loopex exposes is unstable. None is labelled, frozen, versioned
for consumers, or given a compatibility promise, and none is owed a deprecation
window or a migration note. This page lists what an embedder, a client author,
or an operator can reach today, what each surface consists of, which data a
given reader can open, and what would have to exist before any surface could be
frozen.

That is a deliberate position, not an omission. The
[compatibility contract](../vision.md#concept-vision-compatibility) freezes a
surface only when its own consumers, schemas, vectors, migration, rollback, and
operational evidence justify the claim. No surface has all of those yet, so
labelling one stable would be a promise with nothing behind it.

**Versions name source, not contracts.** The source `VERSION` is `0.2.0`. The
annotated tag `v0.0.0-m2` identifies one integrated source snapshot and
`v0.1.0` a source release; neither is a package, a publication, or a
compatibility freeze. Nothing is packaged or published, so the vision's package
surface — released names, their contents, and the constraints they declare —
has never been created. The session protocol's generations are negotiated
independently of the source version, as accepted
[ADR 0023](../adr/0023-experimental-public-session-protocol.md#concept)
requires.

**The wire protocol is experimental by name.** The app server speaks the exact
generation `loopex.experimental/1` over standard input and output, and the
daemon speaks `loopex.experimental/2` over its socket. A client offers an
ordered list of generations and the server selects one it knows, with no
partial match, no nearest neighbour, and no version comparison that could round
the word `experimental` up to a released contract. A generation has schemas,
vectors, and an independent consumer; it has no migration path and no freeze.

**Durable data grows by new record kinds, and older readers refuse.** A reader
replays every history a later revision can still interpret, and a session that
contains a record kind an older reader does not know is refused by that reader
at load, before any model or executor work. There is no in-place migration and
none is owed. Rollback means returning to a retained old binary with a complete
backup of the state root it wrote; removing a feature's files or its server
never downgrades a root that already holds its records.

For an embedder this means: pin an exact revision, expect any surface below to
change without notice, and read the changelog for the revision you move to
rather than a version constraint. Treat the whole umbrella as one moving target
— a change to the private journal, the executor protocol, or the tool record can
reach you through the facade you call. Internal process topology, process
messages, supervision structure, and private structs are not a surface at all
and are not listed.

Operator-facing consequences:
[Coding sessions](../operator/coding-sessions.md#concept) and
[Tools and policy](../operator/tools-and-policy.md#concept).

<a id="technical-depth"></a>
## Technical depth

### The Surfaces

Each row names what an embedder, client, or operator can reach, and the vision
surface it belongs to under
[separately versioned surfaces](../vision-technical.md#technical-vision-compatibility).

| Surface | Reached through | Vision surface | State |
| --- | --- | --- | --- |
| Embedded facade | `Loopex` and its start options | 5, embedded Elixir API | Unstable |
| Reference composition | `LoopexComposition.start/1`, `with_runtime/2`, `start_edges/2`, `artifacts/1` | 5, embedded Elixir API | Unstable |
| Store port | `Loopex.Store` behaviour and handle | 1, private journal and store schema | Unstable |
| Model port | `Loopex.Model` behaviour, request and reply shapes, delta contract | 2, public protocol semantics | Unstable |
| Executor port | `Loopex.Executor` behaviour, job, grant, receipt, `cancel/2`, optional `retained_receipt/2` | 3, executor protocol | Unstable |
| Policy port | `Loopex.Policy` behaviour, request, context, refusal categories, defer | 2, public protocol semantics | Unstable |
| Artifact-store port | `Loopex.ArtifactStore` object/use behaviour and eight-member `artifact_reference` | 6, artifact formats | Unstable |
| Artifact transfer capability | the optional transfer callbacks and the facade transfer family | 6 and 5 | Experimental |
| Tool definition contract | `LoopexProtocol.ToolDefinition`, `LoopexProtocol.Canonical` | 2 and 3 | Unstable |
| Durable record shapes | committed record kinds, replayed by `Loopex.Runtime.SessionState` | 1, private journal and store schema | Unstable |
| Durable interaction records | `interaction_requested_v1`, `interaction_answer_admitted_v1`, `interaction_resolved_v1`, and the `interaction_answer` command | 1, private journal and store schema | Experimental; refused by older readers |
| Public event shapes | `Loopex.attach/3`, `Loopex.next_event/1` | 2, public protocol | Unstable |
| App-server wire protocol | generation `loopex.experimental/1`: methods, records, error codes, identities, limits | 2, public protocol semantics | Experimental; exact generation agreement only |
| Daemon wire protocol | generation `loopex.experimental/2` over the daemon's Unix-domain socket | 2, public protocol semantics | Experimental; exact generation agreement only |
| Public protocol schemas and vectors | `apps/loopex_protocol/priv/schema/` and `priv/vectors/`, reported as a schema digest at initialization | 2, public protocol semantics | Experimental |
| Telemetry events | the `[:loopex, …]` span inventory, `Loopex.Telemetry.attach/1` and `detach/1` | not a listed surface; transient diagnostics | Experimental |
| Trace sessions | `Loopex.trace/1`, `trace/2`, `trace_status/1`, `trace_stop/1` | 5, embedded Elixir API; transient diagnostics | Experimental |
| Operator command | the `loopex` escript, its subcommands, flags, exit statuses, and the compact JSON of daemon queries | not a listed surface | Unstable |

Surface 4, the extension manifest and lifecycle API, does not exist yet.
Surface 7, released package names and their contents, is inert: no package is
published, so nothing has welded two surfaces together by shipping them in one
artifact.

### What Each Surface Consists Of

**Embedded facade.** The functions, start options, and command shapes are
listed once, in
[Runtime and embedding](runtime-and-embedding.md#technical-embedding-api). None
introduces a sixth port or a second loop. Prepared resume returns an opaque
one-use activation capability; neither preparation nor handler installation
schedules recovered work, and `activate_resume/1` and `abandon_resume/1` wait
for the coordinator's answer rather than expiring on a bound, because the
message carrying either call is not withdrawn when its caller stops waiting.
Neither call proposes a Store mutation, and a coordinator that has died still
refuses, because its exit is the answer. The explicit three-argument handoff of
[ADR 0020](../adr/0020-explicit-prepared-handoff.md#concept) distinguishes a
definitive refusal from loss after a possible handoff; a missing decision reply
never authorizes a retry, an abandonment, or an activation.

**An abort's acceptance is an admission, not an ending.** `Loopex.command/2`
returns `{:accepted, command_id}` once the abort commits durably; ADR 0009 then
orders the cleanup, then the run's terminal. The run is still active between the
two, so a prompt submitted there is queued as a follow-up on that run rather
than starting a new one, and a caller that needs the run over waits for its
`run.finished` event.

**Ports.** Core declares exactly five behaviours: `Loopex.Store`,
`Loopex.Model`, `Loopex.Executor`, `Loopex.Policy`, and `Loopex.ArtifactStore`;
their callbacks are listed in
[the architecture technical depth](architecture-technical.md#technical-arch-ports).
`Loopex.Executor.cancel/2` is required and returns `{:ok, :cleaned}`,
`{:ok, :unconfirmed}`, or `{:error, term()}`; the facade maps every answer but
confirmed cleanup, a raise, a malformed answer, and a module missing the
callback to unconfirmed cleanup, which keeps a mixed-version failure safe
without making a module that omits the callback conformant. The optional
`retained_receipt/2` reads the terminal receipt an executor retained for one
job: `{:ok, receipt}`, `:absent`, or `{:error, term()}`, with
`{:error, :effect_in_flight}` reserved for a job the executor still holds.
`Loopex.Executor.retained_receipt/3` bounds that call and reports an absent
callback, a raise, a malformed answer, or the bound elapsing as distinct errors
that leave reconciliation host-driven. The ArtifactStore transfer triple is
optional as well.

An executor that refused a job before its effect started says so by returning
`{:error, {:refused_before_effect, reason}}`; the runtime commits that as a
terminal `failed` carrying `reason`. Every other `{:error, _}` is read as
unproven and ends the run `outcome_unknown` with a reconciliation reference, so
an executor that adopts nothing keeps compiling and stays conformant, and its
errors fail closed. The job's `resource_budgets` is an open plain map; the
declared `resource_budgets["max_wall_time_ms"]` is covered by the job's canonical
digest like every other semantic field, and the shipped local executor bounds a
job by the smallest of the run's deadline, that budget, and the budget its own
copy of the definition declares.

**Reference provider launch.**
[ADR 0019](../adr/0019-host-owned-provider-protection.md#concept) requires one
private companion process per invocation and explicit adapter options:
`worker_path`, `interpreter_path`, `worker_sha256`, and
`build_manifest_sha256`, which `mix loopex.provider.build` writes to a `.launch`
file. Unmanaged calls also supply the validated `cleanup_grace_ms`; managed calls
use Core's retained value. Missing, malformed, or mismatched configuration
refuses before credential delivery, with no shared-VM fallback or runtime code
discovery. The Model callback is `complete/3`; the bare-model `complete/2`
helper refuses, and direct callers use `complete_prompt/3`, which takes a
composed `:credential_token` and `:credential_registry` and refuses before
launch without them — compose custody as `LoopexComposition.CredentialHost`
does. `Loopex.LLM.ReqLLM.call_options/3` is an exported, unstable helper that
takes an explicit credential and returns provider options containing it; a
direct caller owns that secret-bearing value and must not log or retain it. The
credential source is `LOOPEX_PROVIDER_API_KEY`, at most 65,536 bytes; empty and
oversized credentials refuse. Provider-side raw diagnostics are unavailable
rather than forwarded for secret-dependent scrubbing. The generic Model reply
accepts an optional non-empty UTF-8 `provider_response_id` of at most 256 bytes
and retains it unchanged.

**The shipped local executor.** It requires executable `/bin/bash` for its
internal carrier and cleanup guard on Darwin and Linux under
[ADR 0022](../adr/0022-local-executor-supervision-shell.md#concept); raw
commands use `/bin/sh`, argv vectors remain literal, and there is no interpreter
selection or fallback. This is an adapter prerequisite, not a Core or
custom-executor dependency. Its start options are trusted host configuration,
not portable job fields: `process_probe` (default `/bin/ps`, recorded on
receipts that use it, answering the `-e -o pid= -o pgid=` table dialect with the
probe's own Port carrier as the witness row), `clock_provider` (a zero-argument
function returning paired wall and monotonic instants), `open_authority_close`
(a two-argument replacement for `Ledger.close_open/2` that must answer `:ok` or
`{:error, reason}`), and `claim_wait_ms` (default `5_000`, capped by the job's
remaining allowance, never a permission). It refuses a missing, empty, or
larger-than-8,192-byte `job_id` before touching the shared ledger. Its ledger
generation encodes the positive 256-bit epoch as exact lowercase 64-hex; a
generation identity containing uppercase letters makes its record unavailable
rather than being rewritten. Its concrete error families include
`{:ledger_unavailable, :operation_owner_unavailable}`, `:effect_settling`,
`{:receipt_not_retained, reason}`, `{:receipt_read_failed, reason}`,
`{:refusal_not_retained, reason}`, and nested `root_claim_retained` details;
only the `{:refused_before_effect, reason}` wrapper proves pre-effect refusal. A
reservation is not evidence that an effect is live: only the separately fenced
permit authorizes one, as
[the turn order](agent-loop-and-tools.md#technical-loop-turn-order) describes.
Functions marked `@doc false` — `stats/1`, `tool/1`, the `bounded_*`, `*_probe`,
and `await_*` helpers among them — are callable test support, not extension
points.

**Model deltas and usage.** `Loopex.Model.valid_delta?/1` requires a delta to
carry exactly the fields `Loopex.Model.delta_fields/1` declares for its kind, and
the payload ceiling is total: a field whose size the named measurements do not
know is measured by encoding it. A reply's usage map is closed to
`input_tokens` and `output_tokens`; a third key settles the attempt as
`unreadable_model_answer`, and omitting either key normalizes as unreported.
Accounting settlements are `model_attempt_settled_v2` under
[ADR 0021](../adr/0021-compacted-provider-accounting-provenance.md#concept);
the details are in
[the agent loop](agent-loop-and-tools.md#technical-depth).

**Store port.** A log removed or replaced underneath a live local Store is
`{:log_unavailable, :enoent}` or `{:log_unavailable, :replaced}`,
commit-ambiguous exactly as any other append failure: the caller receives
`{:commit_unknown, tx_id}` and must re-present that exact transaction, and the
Store process terminates. Item admission has one refusal taxonomy whichever way
a caller reaches it — building a transaction, preflighting through
`Loopex.Store.normalize_and_measure_item/2`, or validating one: `:invalid_item`
for a private record and `:invalid_event` for a public event that is not bounded
plain data, `{:item_structure_exceeded, dimension, observed, limit}` for depth
or cardinality, and `{:item_too_large, observed, limit}` for size. The
list-level `:invalid_records` and `:invalid_events` remain for an ordinary
malformed member.

**Durable records.** The record kinds are listed in
[the architecture technical depth](architecture-technical.md#technical-arch-session-owner).
The Local executor's generation, admission, open, refusal, and receipt ledgers
and the ArtifactStore object and use records are separate kind-owned durability
domains.

**Public events.** The event kinds are listed in the same place. `tool.started`
carries `tool_id` and `tool_version` and `tool.finished` carries `tool_id` and
the outcome; a call whose name resolved to no active tool carries no tool
identity, because publishing the model-supplied string would read as a name the
runtime accepted. A `run.finished` that ends `failed` carries a `failure`
projection only where a context refusal was admitted and a `reason` only where
one exists. Delivery is fenced by resolution as well as commit; cursors,
sequences, and gap semantics are otherwise plain. Progress items and
diagnostics are transient, are not this surface, and carry no compatibility
expectation.

**Tool definition contract.** The nine required fields, the evaluable schema
subset, the generation triple, the reserved `loopex.` namespace, and the
canonical encoding `loopex.canonical.v1` with the record tag
`loopex.tool_definition.v1`, as
[the tool contract](agent-loop-and-tools.md#technical-depth) states. Widening
the schema subset or the budget set is additive and does not disturb a retained
generation, because a definition that did not use the wider form encodes
exactly as before; anything else changes every retained digest.

**Reference composition.** Its options are listed in
[Runtime and embedding](runtime-and-embedding.md#technical-embedding-composition).
It names four concrete implementations, so an embedder that depends on it
acquires the reference adapters and their external dependency whether or not
every one is used; an embedder that wants a different Store, Model, Executor, or
ArtifactStore composes the ports and the `Loopex` facade directly.

**Operator command.** The subcommands are `run`, `sessions`, `resume`,
`attach`, `cancel`, `artifact`, `skill`, and `daemon`. Each admits its own flags,
and an unrecognised flag is refused rather than ignored, so admitting a flag on
one more subcommand is observable and withdrawing one is breaking:

| Subcommand | Flags |
| --- | --- |
| `run` | `--policy`, `--state-root`, `--workspace`, `--steer`, `--follow-up`, `--cleanup-grace-ms`, `--context-token-budget`, `--skill`, `--skill-resource` |
| `resume`, `cancel` | `--policy`, `--state-root`, `--workspace`, `--cleanup-grace-ms`, `--context-token-budget` |
| `sessions`, `artifact` | `--state-root` |
| `skill` | `--state-root`, `--workspace`, `--rev`, `--path` |

A `--daemon SOCKET` argument selects the live grammar of `run`, `resume`, and
`sessions`, and `attach` exists only in that grammar; it is stated with the
daemon's exit statuses in
[the operator daemon reference](../operator/daemon.md#technical-depth). A bare
`--` ends option parsing and preserves every remaining word as data, which is
what makes an artifact locator beginning with `--` retrievable. `--policy`
accepts `allow-all` and `shell-allowlist`; the set of names is part of the
surface. `loopex artifact` reads objects through the `Loopex.ArtifactStore`
port. The command's cross-application interrupt entries —
`LoopexCli.Interrupt.install/1`, `install/2`, `install_prepared/3`,
`activate_prepared/1`, `abandon_prepared/1`, and `abandon_resume/2` — are
described in
[Runtime and embedding](runtime-and-embedding.md#technical-embedding-recovery).

**App-server and daemon wire protocols.** Generation `loopex.experimental/1`
has sixteen methods, seven record families, and fifteen error codes;
`loopex.experimental/2` adds four methods, two record families, twelve error
codes, seven limits, and a `writer_epoch` on every mutation of an existing
session. The exact contract is
[the protocol technical reference](app-server-protocol-technical.md#technical-depth).
Initialization reports the selected generation, the exact schema digest, the
methods, and the limits, and because the digest covers the whole schema, any
change to a method, record, or limit changes what a client sees at
initialization. There is no partial compatibility within a generation and no
promise across generations. Generation 1 was once named
`loopex.session.v1-experimental`; that name is no longer served, and a client
offering it is refused with `unsupported_generation`. Strictness is part of the
surface: a lenient client that relied on repair was never conformant.

**Durable interactions.** The three record kinds, the `interaction_answer`
command, and the `interaction.requested`, `interaction.resolved`,
`interaction.expired`, and `interaction.cancelled` events, under
[ADR 0024](../adr/0024-durable-interaction-lifecycle-and-host-policy-authority.md#concept).
A runtime that names `:policy` must name `:policy_identity`, because a pending
question is resumed only by the same policy identity and revision that asked
it. The answer is bounded evidence for a host-policy decision, never an
authorization, and the host's `decision_ref` is never projected.

**Artifact transfer capability.** Three optional ArtifactStore callbacks —
`open_transfer/4`, `read_transfer/3`, `close_transfer/2` — and the facade family
`Loopex.open_artifact_transfer/2`, `read_artifact_chunk/3`, and
`close_artifact_transfer/2`, under
[ADR 0028](../adr/0028-bounded-artifact-retrieval.md#concept). The object and
use identities and the opaque `use:<sha256>` locator are unchanged by it, and no
artifact format migrates. An adapter without the triple stays conformant and
the facade refuses rather than falling back to an unbounded fetch. The ceilings
are part of the surface and are listed in
[Runtime and embedding](runtime-and-embedding.md#technical-embedding-transfers).

**Telemetry events and trace sessions.** The `[:loopex, …]` span inventory is
bound exactly by
[ADR 0030](../adr/0030-observability-tracing-and-telemetry.md#concept) and
listed in [the observability inventory](observability-technical.md#technical-observability-inventory);
adding a name, removing one, or emitting a second span from one boundary is an
ADR amendment. Trace sessions need the OTP 27 floor, load each named module
from the code path before observing it, and are administrative diagnostics:
neither plane is durable truth or authority, and no session command, wire
request, model output, or project resource can start, change, or stop either.
Neither changes a durable format, and removing either needs no migration.

### Reader Boundaries and Rollback

| Data in a state root | Current reader | Older reader |
| --- | --- | --- |
| A root written before conversation, tool-generation, steer, follow-up, and cancellation records existed (the M1 era) | Not readable; start on a fresh state root | — |
| `model_attempt_settled_v1` settlements | Replayed as an unambiguous prefix; a version-1 settlement after the first version-2 one refuses, and a legacy unreadable result with reported accounting refuses as `ambiguous_legacy_provider_accounting` | — |
| `model_attempt_settled_v2` settlements | Replayed | A reader without version 2 refuses the session |
| `resource_command_v1`, `model_request_committed_resources_v1` | Replayed; even a refused resource command creates this boundary | A reader without resource records refuses the session at load |
| `interaction_requested_v1`, `interaction_answer_admitted_v1`, `interaction_resolved_v1` | Replayed | A reader without interaction records refuses the session before any effect |
| A root with a session directory but no daemon index | Offline commands read it; the daemon refuses it as `session_index_upgrade_required` until `loopex daemon prepare-index` imports it | — |

Rollback therefore requires stopping owners and preserving a complete backup of
the root. Ownership acquisition may still write fenced administration before
replay refuses, so an older reader is not promised zero writes; readiness and
recovered work require successful replay through the committed head. Removing
skill files, the app server, or the daemon does not downgrade a root that holds
their records. The old-binary execution proof for accounting settlements is
`scripts/provider-accounting-rollback.exs`, described in
[DEVELOPMENT.md](../../DEVELOPMENT.md). A local executor ledger that a reader
refuses is preserved, and the
[operator recovery procedure](../operator/tools-and-policy.md#operator-tools-reach)
still requires positive cessation of every old effect authority, or the
prescribed host reboot, before a fresh root is used.

### What an Embedder Should Do About It

- Pin an exact revision of this repository. No published version expresses a
  loop, because no version has been published.
- Do not persist anything that depends on a durable record shape outside the
  Store, and do not read the Store's files with your own code.
- Treat `artifact_reference.locator` as opaque. Core never parses, joins, or
  reconstructs it, and an adapter is free to change what it means.
- Treat `stream_domain_id` as an opaque comparison key of 32 hexadecimal
  characters; its derivation may change behind that stability.
- Expect the absence of a stream closure. It is an emission obligation, never a
  delivery guarantee, so a consumer falls back to the durable record rather than
  inferring abandonment.
- Know which policy caller you are answering. The one-shot
  `Loopex.Policy.decide/2` resolves `{:defer, _}` to
  `{:deny, :interaction_unsupported}`; the interaction-aware
  `Loopex.Policy.evaluate/2`, which the session owner uses, admits a validated
  defer and suspends the tool call on a durable question.
- Supply a `:policy_identity` alongside `:policy`, and change its revision when
  your policy's behaviour changes.
- Treat a transfer reference as opaque and attachment-owned.
- Expect a protocol client to renegotiate. The generation and schema digest are
  checked at initialization, and an exact mismatch is the intended outcome
  rather than a fault to work around.

### What Would Have To Exist Before Any Freeze

Nothing here becomes a release candidate by accumulating usage. Under the
[compatibility contract](../vision.md#concept-vision-compatibility) and its
[technical rules](../vision-technical.md#technical-vision-compatibility), a
surface needs schemas, conformance vectors, independent consumers, and upgrade
and rollback evidence appropriate to what it claims, and the public protocol
specifically waits until embedded, RPC, daemon, host, and extension callers have
exercised its semantics. Executor-protocol stability additionally waits on
isolated and remote evidence, not only the trusted-local implementation that
exists today. Deciding what a published package would contain is itself a
compatibility decision, because a consumer pins the package rather than the
surface inside it.

Until that work is done and recorded, the answer to "is this stable yet" is no,
for all of the above.
