<a id="technical-depth"></a>
## Technical depth

Concept: [Observability: tracing and telemetry](0030-observability-tracing-and-telemetry.md#concept).

<a id="technical-adr-0030-decision"></a>
### Contract and Evidence

Concept: [Context and decision](0030-observability-tracing-and-telemetry.md#concept-adr-0030-decision).

### Trace sessions

`Loopex.Trace` owns at most one OTP trace session per runtime, created with
the OTP 27 `trace` module so it never collides with another tracer in the VM.
The session traces only processes the runtime owns (coordinators, dispatcher,
recovery children, task supervisors) and only modules on an allowlist: every
`Loopex.*` and `LoopexProtocol.*` module by default, plus adapter modules the
host names at launch. A session is configured by a bounded plain map:

| Field | Meaning |
| --- | --- |
| `modules` | Allowlist; wildcards only over the Loopex namespaces |
| `level` | `calls` (identity, caller, process, timing), `returns` (adds return-or-exception class), `arguments` (adds bounded redacted arguments and returns; administrative opt-in) |
| `limits` | Exact ceilings: 4,096 bytes per entry after redaction, 2,000 entries per second per session, 8,192 queued entries; a host may lower but never raise them |
| `sink` | The runtime's diagnostics sink or Logger at debug level |

Entries are plain maps: module, function, arity, caller, pid, monotonic time,
duration when a matching return is seen, class, and, at the `arguments` level,
`inspect`-rendered arguments and returns truncated to the byte limit after a
redaction pass. Redaction replaces any value reachable through a credential
reference, a model request or response body, tool arguments or results, and
artifact bytes with a typed placeholder carrying only size and digest; the
provider key never enters a trace entry because the adapter process is outside
the session unless the host names it, and even then the key-bearing call is
excluded by match specification. The tracer process is the only consumer of
raw trace messages; it applies limits before anything reaches a sink, drops
with a counted `dropped` entry when a limit is exceeded, and never blocks the
traced process.

Sessions start from launch configuration (`trace:` runtime option, the CLI
`--trace` flag, the `LOOPEX_TRACE` environment variable at the reference
client only) or from `Loopex.trace(runtime, config)` and
`Loopex.trace_stop(runtime)`, which require the runtime reference the host
holds; the app-server exposes no method for them. On an OTP release without
the `trace` module the facility returns `{:error, :trace_sessions_unavailable}`
and never falls back to `:dbg` or `erlang:trace`.

### Telemetry events

Core depends on `:telemetry`, admitted as its sole external dependency by the
maintainer's recorded vision change of 2026-09-13, and emits spans with the
prefix `[:loopex | ...]`. The emission inventory is exact: every port callback
below and every listed coordinator transaction cut emits one span; a callback
or cut absent from this table is not instrumented, and adding one is an
amendment to this ADR.

| Boundary | Callback or cut | Event prefix | Metadata (bounded, identities only) |
| --- | --- | --- | --- |
| Model port | `Loopex.Model.complete/3` | `[:loopex, :model, :complete]` | session_id, run_id, attempt, provider, model, endpoint class, outcome |
| Store port | `transact/…`, `transaction_status/…`, `runtime_command/…`, `ownership_head/…`, `load_records/…`, `load_events/…` | `[:loopex, :store, <callback>]` | session_id where bound, record kind, record bytes, outcome |
| Artifact store port | `put/3`, `fetch/2`, `stat/2`, `describe/2`, `open_transfer/…`, `read_transfer/…`, `close_transfer/…` | `[:loopex, :artifact, <callback>]` | session_id, object and use references, transfer_ref, bytes, chunks, outcome |
| Executor port | `execute/5`, `cancel/2`, `retained_receipt/…` | `[:loopex, :executor, <callback>]` | session_id, run_id, tool_call_id, tool_id, operation_id, attempt, outcome |
| Policy port | `Loopex.Policy.decide/1` through the interaction-aware evaluator | `[:loopex, :policy, :decide]` | session_id, run_id, tool_call_id, result category |
| Coordinator cut | command admission | `[:loopex, :command, :admit]` | session_id, command_id, type, result |
| Coordinator cut | durable commit and commit_unknown resolution | `[:loopex, :commit]` | session_id, kind, tx identity class, outcome |
| Coordinator cut | effect intent | `[:loopex, :effect, :intent]` | session_id, run_id, tool_call_id, outcome |
| Coordinator cut | receipt and publication | `[:loopex, :events, :publish]` | session_id, event kind, cursor |
| Coordinator cut | interaction transitions | `[:loopex, :interaction]` | session_id, interaction_id, transition |
| Coordinator cut | artifact transfer lifecycle | `[:loopex, :artifact, :transfer]` | session_id, transfer_ref, bytes, chunks, outcome |

Measurements are durations, counts and byte totals. Metadata never carries
content, arguments, results, credentials or PIDs. Telemetry dispatch runs
handlers synchronously in the emitting process, so core attaches no handler of
its own. The edge application `loopex_telemetry` (role `:edge`, depending
inward on core and outward on `:telemetry` only) owns the only Loopex-attached
handler: it forwards each event to the runtime's diagnostics dispatcher with a
non-blocking send under the diagnostics plane's existing bounds, drops with a
counted entry when that sink is full, and never performs I/O or a call in the
emitting process. Telemetry's own failure isolation detaches a crashing
handler. A handler the host attaches directly runs in the emitting process
and is the host's responsibility; the operator guide states that such handlers
must not block. Reporters (`Telemetry.Metrics`, Prometheus, OpenTelemetry)
live in `loopex_telemetry` or host adapters and never enter core, protocol or
the app-server.

### Evidence

Prove, with a real runtime and Store: a session traces only allowed modules
and owned processes; a second tracer in the VM is unaffected; every level
reports the documented fields; the `arguments` level redacts a credential
reference, model content, tool arguments and artifact bytes to placeholders;
limits drop with a counted entry and never block the coordinator; a session
cannot be started from a session command, client content, model output,
project resource or app-server request; stopping releases every trace flag.
Prove every callback and cut in the emission inventory emits start/stop or
exception with a duration and only the documented metadata, that a crashing
handler is isolated, that a slow or blocked `loopex_telemetry` forwarding sink
never delays a coordinator and drops with a counted entry, and that an OTP
release without trace sessions reports unavailability. Measure the overhead of
enabled tracing and of telemetry emission with no handler attached and record
both with the gate evidence.

### Alternatives

Hand-written debug logging in every module was rejected: it is incomplete by
construction, adds noise to every file and still needs a sink and redaction.
OTP `:logger` structured reports in place of telemetry were rejected: metrics
consumers would need a bespoke adapter from log events. A Loopex-owned
dispatch registry was rejected as a re-implementation of telemetry. VM-global
`:dbg` tracing was rejected because it cannot coexist with another tracer and
cannot be scoped to one runtime.

<a id="technical-adr-0030-compatibility"></a>
### Compatibility and Rollback Mechanics

Concept: [Consequences and rollback](0030-observability-tracing-and-telemetry.md#concept-adr-0030-consequences).

The core dependency budget gains exactly `:telemetry` under the recorded
vision change; the repository dependency checks name it as the sole admitted
core dependency and refuse any other, and those checks and their bound holders
change through the holders' transactions the M4 plan names, not silently.
Core, protocol and the app-server gain no other dependency; `loopex_telemetry`
is the tenth application and the only place a Loopex handler or reporter
lives. Trace and telemetry output is transient
and never journaled; no Store, journal, event or protocol record changes.
Removing the trace facility or the dependency restores the previous behavior
without rewriting data. Trace sessions need the OTP 27 floor of ADR 0026; the
floor decision is settled before this one binds evidence.

Acceptance binds this complete pair at an exact candidate. Its evidence claims
remain unproved until the M4 gate's required paths execute.
