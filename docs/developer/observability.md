# Observability

<a id="concept"></a>
## Concept

Technical depth: [Observability contracts and inventory](observability-technical.md#technical-depth).

Loopex observes itself through two mechanisms that answer different questions
and are bounded in different ways. This document is the reference for what each
one promises a developer, and — more importantly — what neither of them is
allowed to become.

A **trace session** is a runtime-scoped observation of calls inside the
processes one runtime owns. A host turns it on through the runtime reference it
already holds, names the modules it wants, and turns it off. No source changes.

**Telemetry events** are spans emitted at every port callback and every
coordinator transaction cut. Core emits them and attaches nothing; one edge
application carries them into a runtime's bounded diagnostics plane.

The founding decision is accepted
[ADR 0030](../adr/0030-observability-tracing-and-telemetry.md#concept), which fixes the
emission inventory exactly, and the vision change that admits the single
telemetry event dispatcher into core.

Technical depth: [The emission inventory](observability-technical.md#technical-observability-inventory).

<a id="concept-observability-not-truth"></a>
## Neither Is Truth, and Neither Is Authority

This is the constraint that shapes everything else.

Loopex keeps truth planes apart: private recovery records, committed public
events, snapshots, transient progress, and diagnostics all have different
guarantees. Trace entries and telemetry spans are diagnostics. They are the
weakest plane in the system, and code must never be written that depends on one
having arrived.

A dropped span is a normal outcome, not an error. A trace session that hits its
rate ceiling drops entries and says so. If a decision needs to survive, it
belongs in a durable record, not in something an operator can turn off.

Neither mechanism is reachable from anything a session carries. No session
command, client content, model output, project resource or app-server request
can start, change or stop a trace session or alter what a span reports. The only
route in is the runtime reference the host holds, which is the same rule every
other runtime operation follows.

Technical depth: [Trace session domain](observability-technical.md#technical-observability-trace).

<a id="concept-observability-emitting"></a>
## Why Core Emits and the Edge Handles

`telemetry` runs handlers synchronously in the process that emitted the event.
A handler that blocks blocks a session coordinator; a handler that raises would
take the coordinator with it were `telemetry` not isolating it.

So core emits and attaches nothing. The one Loopex-attached handler lives in
`loopex_telemetry`, an edge application, and does almost nothing: it builds a
bounded plain item and offers it to the runtime's asynchronous diagnostics
admission, which takes it or drops it and counts the drop. A coordinator
emitting a span pays for one map and one send.

This is also why the dependency budget admits exactly one external dependency in
core. The event dispatcher is named by the vision's dependency doctrine; nothing
else gets in on the strength of being useful.

Technical depth: [The only place a span opens](observability-technical.md#technical-observability-span).

Technical depth: [The edge handler](observability-technical.md#technical-observability-handler).

<a id="concept-observability-redaction"></a>
## Redaction Is a Contract, Not a Filter

At its administrative level a trace session renders arguments and returns. That
is the only place in the system where a diagnostic comes close to content, and
it is handled as a contract rather than as a best-effort scrub.

Redaction runs over the term before anything is rendered. The alternative —
render, then filter the text — puts the secret in memory as a string and leaves
the filter guessing where it ends. A replaced value becomes a typed placeholder
carrying the byte size and digest of what it replaced: enough to correlate two
entries about one payload, never enough to read it.

The same principle governs telemetry exceptions. A span reports an error class
and not the exception's own words, because a message or a stack trace carries
exactly the content every other rule removes. That is why these spans are
emitted directly rather than through the library's own span helper, which
attaches kind, reason and stacktrace to its metadata.

Where redaction cannot be enough, the process is not traced at all. The one
process that handles the provider credential excludes itself from every current
and future trace session before it receives anything, and the call does not
proceed without that exclusion. Redaction by key would already hide a credential
under a credential-named key; exclusion removes the need to trust that the value
is always under one.

Technical depth: [Redaction rules](observability-technical.md#technical-observability-redaction).

<a id="concept-observability-bounded"></a>
## Everything Is Bounded, and Says So When It Bounds

Every ceiling is a maximum a host may narrow and cannot raise. A configuration
that tries to raise one is refused by name rather than silently corrected.

When a bound is reached, the system drops and counts, and reports the count as
its own entry. An operator is told what they did not see. A traced process is
never delayed by being traced: the tracer never calls into one and never replies
to one, so tracing cannot change the behaviour it is observing.

Technical depth: [Trace session ceilings](observability-technical.md#technical-observability-trace).

## Related

- [Architecture](architecture.md#concept) — truth planes and dependency direction.
- [App server protocol](app-server-protocol.md#concept) — the wire surface's own bounded planes.
- [Operator observability runbook](../operator/observability.md#concept) — turning it on and reading it.
- [Getting started](getting-started.md#concept) — where diagnosing fits in a first contribution.

Back to the [developer index](README.md).
