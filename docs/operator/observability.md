# Observability

<a id="concept"></a>
## Concept

M4 gives an operator two ways to see inside a running Loopex runtime, and they
answer different questions.

A **trace session** answers "what is this runtime actually doing right now?" It
turns on tracing of every call in the modules you name, inside the processes
this runtime owns, without changing a line of source, and turns it off again.

**Telemetry events** answer "how is this runtime behaving over time?" Every port
callback and every transaction cut emits a span with its duration and its
outcome, carrying identities and totals and nothing else.

Neither is durable truth, and neither grants authority. A trace entry is a
diagnostic, not a record; a telemetry span is a measurement, not an event a
session can be rebuilt from. Nothing a client sends, nothing a model returns and
nothing a project resource contains can start, change or stop either one.

Related: [Runtime operations](runtime.md#concept) for starting the runtime, and
[App server operations](app-server.md#concept) for the stdio surface.

<a id="operator-observability-tracing"></a>
## Trace Sessions

A trace session starts only through the runtime reference the host holds. That
is the whole access rule: no session command, client content, model output,
project resource or app-server request reaches it.

It is an OTP 27 trace session, so it coexists with any other tracer in the same
virtual machine and is destroyed as a unit. Only processes reachable from this
runtime's supervisor are flagged, and new ones started later are covered
automatically; a process the runtime does not own is never traced.

### What each level shows

| Level | What an entry carries |
| --- | --- |
| `calls` (default) | Who called what, in which process, and when |
| `returns` | The same, plus that the call returned |
| `arguments` | The same, plus a **redacted** rendering of the arguments and the return |

`arguments` is the administrative level. Use it when you need to correlate two
calls about the same payload, not when you want to read the payload — you
cannot, and that is deliberate.

### What is redacted, and why that way

Redaction runs over the term **before** anything is rendered. Rendering first
and filtering the text afterwards would put the secret in memory as a string
and leave the filter guessing where it ended.

A value is replaced with a typed placeholder when its key names a credential, a
model request or reply body, tool arguments or results, or artifact bytes; and
whenever a binary is longer than an identity could be. The placeholder carries
the byte size and the lowercase SHA-256 digest of what it replaced — enough to
tell that two entries concern the same payload, never enough to read it.
Terms nested more than six deep are replaced rather than rendered, and the
finished entry is truncated to the session's per-entry byte ceiling, so an entry
is bounded however deep or wide the term was.

### Ceilings

Every value below is a **maximum**. A host may narrow any of them; none can be
raised, so no configuration can widen what the accepted ADR fixed.

| Ceiling | Value |
| --- | --- |
| Bytes per entry | 4,096 |
| Entries per second | 2,000 |
| Queued entries | 8,192 |

Entries beyond the rate, or arriving while the tracer's own mailbox is over the
queue ceiling, are **dropped and counted**, and the count is reported as its own
entry. You are told what you did not see. A traced process is never delayed by
the fact that it is traced: the tracer never calls into one and never replies to
one.

### Allowlist

The default allowlist is the two Loopex namespaces. Wildcards exist only over
those, because a wildcard over anything else would let a trace session observe
code the runtime does not own. To trace an adapter, name that module exactly.

A session loads each module it names before it starts observing, so an
adapter the runtime has not called yet is traced from its first call. A name
that no installed module answers to traces nothing.

Entries go to the runtime's diagnostics plane by default, or to the logger.

### When tracing is unavailable

An OTP release built without trace sessions reports unavailability rather than
pretending to start one. Stopping a session releases every trace flag it set.

### The one process a trace never sees

The process that hands the provider credential to a model call's isolated
companion excludes itself from every current and future trace session before
it touches the credential, and names the exact functions that carry it; the
call does not proceed unless the exclusion is acknowledged. So even the
`arguments` level never renders the credential, and a trace started mid-call
cannot reach that process. The exclusion ends when the process does.

### Under the daemon

Telemetry is unchanged under the daemon: a session driven through its socket
emits the same spans, with the same identity metadata, as the same session
driven by an embedded host, and the daemon emits no event of its own.

A trace session covers the processes the runtime owns. The daemon's listener,
connections and lease owners are host processes above the runtime, so a trace
session does not flag them. Their lifecycle lines are fixed and identity-free
and are logged at `debug`, which `loopex daemon` does not print: it logs at
`info` to standard error, so a running daemon's standard error carries only
warnings and failures. The daemon's own state is read with
`loopex sessions --daemon SOCKET --status`; see the
[daemon page](daemon.md#operator-daemon-listing).

<a id="operator-observability-telemetry"></a>
## Telemetry Events

Core emits spans; core attaches no handlers. That split matters: `telemetry`
runs handlers synchronously in the emitting process, so a handler that blocks
would block a session coordinator. The one Loopex-attached handler lives in the
`loopex_telemetry` application at the edge, builds a bounded plain item, and
offers it to the runtime's asynchronous diagnostics admission, which either
takes it or drops it and counts the drop. A coordinator emitting a span pays for
one map and one send, at most.

The handler is attached per runtime with that runtime's own admission handle, so
two runtimes in one virtual machine neither share a handler nor see each other's
events.

### The inventory

Each name below emits `start`, `stop` and `exception`. Five port callbacks and
six coordinator transaction cuts, each exactly one span, each naming its own
outcome.

| Boundary | Events |
| --- | --- |
| Model | `[:loopex, :model, :complete]` |
| Store | `transact`, `transaction_status`, `runtime_command`, `ownership_head`, `load_records`, `load_events` |
| Artifact store | `put`, `fetch`, `stat`, `describe`, `open_transfer`, `read_transfer`, `close_transfer` |
| Executor | `execute`, `cancel`, `retained_receipt` |
| Policy | `[:loopex, :policy, :decide]` |
| Coordinator cuts | `[:loopex, :command, :admit]`, `[:loopex, :commit]`, `[:loopex, :effect, :intent]`, `[:loopex, :events, :publish]`, `[:loopex, :interaction]`, `[:loopex, :artifact, :transfer]` |

### What a span carries, and what it does not

Identities, totals and a duration. An outcome the boundary names for itself,
rather than a generic success-or-failure. On an exception, a class name only —
not the exception's own words, not its message, and not a stack trace, because
any of those can carry the content the rest of the redaction rules exclude.

No model content, no tool arguments, no artifact bytes, no credential
references. A handler that tried to forward something richer is refused rather
than trimmed.

### Failure and backpressure

A handler that raises is isolated by `telemetry` itself and detached. A sink
that never drains neither blocks the emitting boundary nor lets the backlog
exceed its ceiling — entries are dropped with a counted entry. With no handler
attached at all, emitting stays inside a bounded cost and every result is
returned untouched.

## Related

- [App server operations](app-server.md#concept) — the stdio surface and its own bounded planes.
- [Runtime operations](runtime.md#concept) — starting and stopping the runtime.
- [How a run works](how-a-run-works.md#concept) — which truth plane is which.

Back to the [operator index](README.md).
