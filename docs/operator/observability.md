# Observability

<a id="concept"></a>
## Concept

Loopex gives the host of a runtime two ways to see inside it, and they answer
different questions.

A **trace session** answers "what is this runtime doing right now?" It traces
calls in the modules you name, inside the processes this runtime owns, without
changing any source, and it is turned off the same way it was turned on.

**Telemetry events** answer "how is this runtime behaving over time?" Every port
callback and every transaction cut emits a span with its duration and outcome,
carrying identities and totals and nothing else.

Neither is durable truth, and neither grants authority. A trace entry is a
diagnostic, not a record; a telemetry span is a measurement, not an event a
session can be rebuilt from. Nothing a client sends, a model returns or a
project resource contains can start, change or stop either one.

Constraints: both are reached only by a host that holds the runtime reference —
an embedding program, or code running inside the same VM as the runtime. The
`loopex` command, the daemon and the app server expose no trace command and no
telemetry output of their own; to see what a session did from those surfaces,
read its durable events (see [how a run works](how-a-run-works.md#concept)) or,
under a daemon, its status (see [listing and status](daemon.md#operator-daemon-listing)).

Developer contract: [Observability for developers](../developer/observability.md#concept).
Starting the runtime a host observes: [Runtime operations](runtime.md#concept).

<a id="operator-observability-tracing"></a>
## Trace Sessions

A trace session starts only through the runtime reference the host holds. That
is the whole access rule: no session command, client content, model output,
project resource or protocol request reaches it.

<a id="operator-observability-procedure"></a>
### Start, check and stop a trace

```elixir
{:ok, _status} = Loopex.trace(runtime, %{level: :returns})
{:ok, status} = Loopex.trace_status(runtime)
:ok = Loopex.trace_stop(runtime)
```

`Loopex.trace/2` takes a map with up to four keys, each optional:

| Key | Values | Default |
| --- | --- | --- |
| `:modules` | module names, plus the wildcards `:loopex` and `:loopex_protocol` | both wildcards |
| `:level` | `:calls`, `:returns` or `:arguments` | `:calls` |
| `:limits` | `%{entry_bytes: …, entries_per_second: …, queued: …}`, each no higher than its ceiling | the ceilings |
| `:sink` | `:diagnostics` (the runtime's diagnostics plane) or `:logger` | `:diagnostics` |

Any other key or value is refused by name rather than corrected.
`Loopex.trace_status/1` reports the running configuration with its emitted and
dropped counts together, because an emitted count alone cannot tell a quiet
system from a sink that is losing entries. `Loopex.trace_stop/1` releases every
trace flag the session set.

It is an OTP trace session, so it coexists with any other tracer in the same VM
and is destroyed as a unit. Only processes reachable from this runtime's
supervisor are traced, and processes it starts later are covered automatically;
a process the runtime does not own is never traced.

### What each level shows

| Level | What an entry carries |
| --- | --- |
| `calls` (default) | Who called what, in which process, and when |
| `returns` | The same, plus that the call returned |
| `arguments` | The same, plus a **redacted** rendering of the arguments and the return |

`arguments` is the administrative level. Use it to correlate two calls about
the same payload, not to read the payload — you cannot, by design.

### What is redacted

Redaction runs over the term **before** anything is rendered, so a secret never
exists in memory as rendered text for a filter to miss.

A value is replaced with a typed placeholder when its key names a credential, a
model request or reply body, tool arguments or results, or artifact bytes, and
whenever a binary is longer than an identity could be. The placeholder carries
the byte size and lowercase SHA-256 digest of what it replaced: enough to tell
that two entries concern the same payload, never enough to read it. Terms nested
more than six deep are replaced rather than rendered, and the finished entry is
truncated to the per-entry byte ceiling.

### Ceilings

Each value is a **maximum**. A host may lower any of them and none can be
raised.

| Ceiling | Value |
| --- | --- |
| Bytes per entry | 4,096 |
| Entries per second | 2,000 |
| Queued entries | 8,192 |

Entries beyond the rate, or arriving while the tracer's own queue is over its
ceiling, are **dropped and counted**, and the count is reported as its own
entry, so you are told what you did not see. A traced process is never slowed by
being traced: the tracer never calls into one and never replies to one.

### Allowlist

The default allowlist is the two Loopex namespaces. Wildcards exist only for
those, because a wildcard over anything else would let a trace observe code the
runtime does not own. To trace an adapter, name that module exactly. A session
loads each module it names before it starts observing, so an adapter not yet
called is traced from its first call; a name no installed module answers to
traces nothing.

### When tracing is unavailable

An OTP build without trace sessions returns
`{:error, :trace_sessions_unavailable}` and changes nothing, rather than
pretending to start one.

### The one process a trace never sees

The process that hands the provider credential to a model call's private
companion excludes itself from every current and future trace session before it
touches the credential, and names the exact functions that carry it; the call
does not proceed until that exclusion is acknowledged. Even the `arguments`
level never renders the credential, and a trace started mid-call cannot reach
that process. The exclusion ends when the process does.

<a id="operator-observability-daemon"></a>
### Under the daemon

A session driven through a daemon emits the same telemetry spans, with the same
identity metadata, as the same session in an embedded host, and the daemon emits
no event of its own.

A trace session covers the processes the runtime owns. The daemon's listener,
connections and lease owners are host processes above the runtime, so a trace
does not flag them. Their lifecycle lines are fixed and identity-free and are
logged at `debug`, which `loopex daemon` does not print: it logs at `info` to
standard error, so a running daemon's standard error carries only warnings,
failures and its stop lines. Read the daemon's own state with
`loopex sessions --daemon SOCKET --status`; see
[listing and status](daemon.md#operator-daemon-listing).

<a id="operator-observability-telemetry"></a>
## Telemetry Events

Core emits spans and attaches no handlers. That split matters: `telemetry` runs
handlers synchronously in the emitting process, so a handler that blocked would
block a session coordinator. The one Loopex-attached handler lives in the
`loopex_telemetry` application at the edge. It builds a bounded plain item and
offers it to the runtime's asynchronous diagnostics admission, which takes it or
drops and counts it. A coordinator emitting a span pays for one map and one send
at most.

The handler is attached per runtime with that runtime's own admission handle, so
two runtimes in one VM neither share a handler nor see each other's events. A
host that wants the spans elsewhere attaches its own `telemetry` handler to the
event names below.

### The inventory

Each name below emits `start`, `stop` and `exception`: five port boundaries and
six coordinator transaction cuts, each exactly one span, each naming its own
outcome.

| Boundary | Events |
| --- | --- |
| Model | `[:loopex, :model, :complete]` |
| Store | `[:loopex, :store, …]` with `transact`, `transaction_status`, `runtime_command`, `ownership_head`, `load_records`, `load_events` |
| Artifact store | `[:loopex, :artifact, …]` with `put`, `fetch`, `stat`, `describe`, `open_transfer`, `read_transfer`, `close_transfer` |
| Executor | `[:loopex, :executor, …]` with `execute`, `cancel`, `retained_receipt` |
| Policy | `[:loopex, :policy, :decide]` |
| Coordinator cuts | `[:loopex, :command, :admit]`, `[:loopex, :commit]`, `[:loopex, :effect, :intent]`, `[:loopex, :events, :publish]`, `[:loopex, :interaction]`, `[:loopex, :artifact, :transfer]` |

### What a span carries, and what it does not

Identities, totals and a duration; an outcome the boundary names for itself
rather than a generic success or failure; and on an exception, a class name only
— not the exception's message or a stack trace, because either can carry content
the redaction rules exclude.

No model content, tool arguments, artifact bytes or credential references. A
handler that tries to forward something richer is refused rather than trimmed.

### Failure and backpressure

A handler that raises is isolated and detached by `telemetry` itself. A sink
that never drains neither blocks the emitting boundary nor lets its backlog
exceed the ceiling; entries are dropped with a counted entry. With no handler
attached, emitting stays within a bounded cost and every result is returned
untouched.

## Related

- [Observability for developers](../developer/observability.md#concept) — the contract, and [its technical depth](../developer/observability-technical.md#technical-depth).
- [Runtime operations](runtime.md#concept) — starting and stopping the runtime a host observes.
- [App server operations](app-server.md#concept) — the stdio surface and its own bounded planes.
- [How a run works](how-a-run-works.md#concept) — which truth plane is which.
- [Operator documentation index](README.md).
