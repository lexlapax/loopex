<a id="technical-depth"></a>
## Technical depth

Concept: [Observability: tracing and telemetry](0029-observability-tracing-and-telemetry.md#concept).

<a id="technical-adr-0029-decision"></a>
### Contract and Evidence

Concept: [Context and decision](0029-observability-tracing-and-telemetry.md#concept-adr-0029-decision).

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
| `limits` | Maximum term bytes per entry, entries per second and queued entries; all exact and bounded |
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

Core depends on `:telemetry` and emits spans with the prefix `[:loopex | ...]`:

| Boundary | Event prefix | Metadata (bounded, identities only) |
| --- | --- | --- |
| Command admission | `[:loopex, :command]` | session_id, command_id, type, result |
| Store transaction | `[:loopex, :store, :commit]` | session_id, kind, record bytes, outcome |
| Model attempt | `[:loopex, :model, :attempt]` | session_id, run_id, attempt, provider, model, endpoint class, outcome |
| Policy decision | `[:loopex, :policy]` | session_id, run_id, tool_call_id, result category |
| Effect intent and dispatch | `[:loopex, :executor, :job]` | session_id, run_id, tool_call_id, tool_id, outcome |
| Receipt and publication | `[:loopex, :events, :publish]` | session_id, event kind, cursor |
| Interaction | `[:loopex, :interaction]` | session_id, interaction_id, transition |
| Artifact transfer | `[:loopex, :artifact, :transfer]` | session_id, transfer_ref, bytes, chunks, outcome |

Measurements are durations, counts and byte totals. Metadata never carries
content, arguments, results, credentials or PIDs. Handlers run synchronously
in the emitting process, so core attaches none of its own; the diagnostics
plane attaches a bounded forwarding handler only when the runtime is started
with a diagnostics sink, and a failing handler is detached by telemetry's own
failure isolation. Reporters (`Telemetry.Metrics`, Prometheus, OpenTelemetry)
are edge adapters and never enter core, protocol or the app-server.

### Evidence

Prove, with a real runtime and Store: a session traces only allowed modules
and owned processes; a second tracer in the VM is unaffected; every level
reports the documented fields; the `arguments` level redacts a credential
reference, model content, tool arguments and artifact bytes to placeholders;
limits drop with a counted entry and never block the coordinator; a session
cannot be started from a session command, client content, model output,
project resource or app-server request; stopping releases every trace flag.
Prove every telemetry boundary emits start/stop or exception with a duration
and only the documented metadata, that a crashing handler is isolated, and
that an OTP release without trace sessions reports unavailability. Measure the
overhead of enabled tracing and of telemetry emission with no handler attached
and record both with the gate evidence.

### Alternatives

Hand-written debug logging in every module was rejected: it is incomplete by
construction, adds noise to every file and still needs a sink and redaction.
OTP `:logger` structured reports in place of telemetry were rejected: metrics
consumers would need a bespoke adapter from log events. A Loopex-owned
dispatch registry was rejected as a re-implementation of telemetry. VM-global
`:dbg` tracing was rejected because it cannot coexist with another tracer and
cannot be scoped to one runtime.

<a id="technical-adr-0029-compatibility"></a>
### Compatibility and Rollback Mechanics

Concept: [Consequences and rollback](0029-observability-tracing-and-telemetry.md#concept-adr-0029-consequences).

The core dependency budget gains exactly `:telemetry`; the repository
dependency checks and their bound holders change through the holders'
transactions the M4 plan names, not silently. Core, protocol and the
app-server gain no other dependency. Trace and telemetry output is transient
and never journaled; no Store, journal, event or protocol record changes.
Removing the trace facility or the dependency restores the previous behavior
without rewriting data. Trace sessions need the OTP 27 floor of ADR 0026; the
floor decision is settled before this one binds evidence.

Acceptance binds this complete pair at an exact candidate. Its evidence claims
remain unproved until the M4 gate's required paths execute.
