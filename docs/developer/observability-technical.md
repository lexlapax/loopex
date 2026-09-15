# Observability — Technical Depth

<a id="technical-depth"></a>
## Technical depth

Concept: [Observability](observability.md#concept).

This companion carries the exact emission inventory, the trace session's
configuration domain and ceilings, the redaction rules by name, the module that
enforces each, and the tests that hold them.

<a id="technical-observability-inventory"></a>
## The Emission Inventory

Accepted [ADR 0030](../adr/0030-observability-tracing-and-telemetry.md#technical-depth)
fixes this set exactly. Every name emits `start`, `stop` and `exception`. Adding
a name, removing one, or emitting a second span from one boundary is an ADR
amendment, not an implementation choice.

Five port callbacks:

| Port | Event names |
| --- | --- |
| Model | `[:loopex, :model, :complete]` |
| Store | `[:loopex, :store, :transact]`, `:transaction_status`, `:runtime_command`, `:ownership_head`, `:load_records`, `:load_events` |
| Artifact store | `[:loopex, :artifact, :put]`, `:fetch`, `:stat`, `:describe`, `:open_transfer`, `:read_transfer`, `:close_transfer` |
| Executor | `[:loopex, :executor, :execute]`, `:cancel`, `:retained_receipt` |
| Policy | `[:loopex, :policy, :decide]` |

Six coordinator transaction cuts:

`[:loopex, :command, :admit]`, `[:loopex, :commit]`, `[:loopex, :effect, :intent]`,
`[:loopex, :events, :publish]`, `[:loopex, :interaction]`,
`[:loopex, :artifact, :transfer]`.

<a id="technical-observability-span"></a>
## `Loopex.Instrumentation` Is the Only Place a Span Opens

Every emission goes through `Loopex.Instrumentation`. There is no second path,
and that is enforced by review rather than by a compiler, so a change that emits
`:telemetry.execute/3` directly is a defect however correct its metadata looks.

Two shapes exist:

- `span/4` wraps work whose lifetime is one call. It classifies the result
  through a per-boundary classifier rather than a generic one, because a generic
  classifier flattens every domain result to `:other` and the outcome is the
  point of the span.
- `open_span/2` and `close_span/4` cover a lifetime that spans several calls —
  the interaction and transfer cuts, where the work begins in one message and
  ends in another.

**The library's own `:telemetry.span/3` is not used.** Its exception path
attaches `kind`, `reason` and `stacktrace` to the event metadata, which carries
exactly the content ADR 0030 excludes. The exception path here emits directly
and attaches an error class only:

```elixir
defp error_class(:error, %{__struct__: module}), do: inspect(module)
defp error_class(:error, reason) when is_atom(reason), do: inspect(reason)
defp error_class(kind, _reason), do: Atom.to_string(kind)
```

The original is re-raised with its own stacktrace, so instrumentation is
invisible to error handling.

<a id="technical-observability-handler"></a>
## The Edge Handler

`Loopex.Telemetry` in `loopex_telemetry` is the only Loopex-attached handler.

- `attach/1` reads the runtime's diagnostics admission handle **once** and
  attaches with `:telemetry.attach_many/4`. The handler identity carries the
  runtime reference, so attaching twice for one runtime is idempotent and two
  runtimes in one VM never collide.
- The handle is plain data, read at attach time rather than per event, so a
  runtime whose dispatcher restarts gets a fresh attachment rather than a
  handler holding a dead table.
- The handler performs no I/O, never calls the synchronous host-facing
  diagnostic entry, and never blocks on a sink. Anything it cannot express as
  bounded plain data it drops.

<a id="technical-observability-trace"></a>
## Trace Session Domain

`Loopex.Trace.Config.validate/1` is the whole domain. A supplied value is
accepted when it is positive and no larger than the ceiling, and refused by name
otherwise.

| Field | Domain | Default |
| --- | --- | --- |
| `modules` | Exact module names, or wildcards over `:loopex` and `:loopex_protocol` only | both namespaces |
| `level` | `:calls`, `:returns`, `:arguments` | `:calls` |
| `limits.entry_bytes` | 1 … 4,096 | 4,096 |
| `limits.entries_per_second` | 1 … 2,000 | 2,000 |
| `limits.queued` | 1 … 8,192 | 8,192 |
| `sink` | `:diagnostics`, `:logger` | `:diagnostics` |

Wildcards exist only over the two Loopex namespaces. A wildcard over anything
else would let a session observe code the runtime does not own; an adapter is
traced by naming its module exactly.

`Loopex.Trace` is an OTP 27 `trace` session, so it coexists with other tracers
and is destroyed as a unit. Processes are flagged from the runtime's supervisor
with `set_on_spawn`, so a coordinator started later is covered and a process the
runtime does not own never is. The tracer is the only consumer of raw trace
messages, applies ceilings before anything reaches a sink, never calls into a
traced process and never replies to one.

Match specs by level: `:calls` sends the caller; `:returns` and `:arguments` add
the return trace; `:arguments` drops the `:arity` flag so argument terms arrive.

<a id="technical-observability-redaction"></a>
## Redaction Rules

`Loopex.Trace.Entry.redact/1` walks the term before rendering.

| Trigger | Result |
| --- | --- |
| Key matches `credential\|secret\|token\|api[_-]?key\|password\|authorization` (case-insensitive) | `credential` placeholder |
| Key in `messages canonical_request_bytes text tool_calls arguments argument result results content contents data bytes payload body chunk` | `content` placeholder |
| Binary longer than 64 bytes | `bytes` placeholder |
| Nesting deeper than 6 | `depth` placeholder |

A placeholder carries the byte size and the lowercase SHA-256 digest of what it
replaced. The rendered form is then truncated to `entry_bytes` with a `...`
marker, so an entry is bounded however deep or wide the term was.

<a id="technical-observability-evidence"></a>
## Evidence

| Claim | Where it is proved |
| --- | --- |
| Five locked trace-session witnesses, redaction and limit negatives | `apps/loopex/test/trace_session_test.exs` |
| Port and cut emissions, and the absence of content | `apps/loopex/test/telemetry_boundary_test.exs` |
| The edge handler carries spans into the diagnostics plane and refuses anything richer | `apps/loopex_telemetry/test/telemetry_handler_test.exs` |
| A stalled sink neither blocks an emitting boundary nor exceeds the ceiling; ten thousand spans with no handler stay inside a bounded cost | `apps/loopex/test/telemetry_boundary_test.exs` |

<a id="technical-observability-adding"></a>
## Changing the Inventory

Adding a boundary means amending ADR 0030 first. The inventory is fixed there,
the conformance test asserts it by name, and an emission the ADR does not list
fails that test — which is the intended order of operations, not an obstacle to
route around.

Adding a field to a span's metadata has the same constraint for a different
reason: the handler refuses anything it cannot express as bounded plain data,
and the boundary test asserts the absence of content. A field carrying a model
message, a tool argument or artifact bytes fails both.

## Related

- [Architecture technical depth](architecture-technical.md#technical-depth) — the applications and the dependency budget.
- [Operator observability runbook](../operator/observability.md#concept).

Back to the [developer index](README.md).
