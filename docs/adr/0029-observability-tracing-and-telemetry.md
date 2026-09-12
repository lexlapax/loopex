<a id="concept"></a>
## Concept

Technical depth: [Observability mechanics](0029-observability-tracing-and-telemetry-technical.md#technical-depth).

- **Status:** Proposed
- **Date:** 2026-09-12
- **Decision owner:** Maintainer
- **Prerequisite for:** M4 acceptance

<a id="concept-adr-0029-decision"></a>
### Context and Decision

No Loopex module logs, traces or emits metrics today. The runtime has a
diagnostics plane (`diagnostics_to`, `Loopex.diagnostic/2`) but nothing feeds
it. An operator or developer who needs to know which function ran, in which
process, with what timing, has no supported way to find out; and a host that
wants call metrics has no events to consume. The vision names metrics and
traces as diagnostics-plane content, keeps OpenTelemetry out of core, and
requires references and redaction rather than captured secrets or payloads.

Two mechanisms, chosen by the maintainer on 2026-09-12:

- **Runtime-owned OTP trace sessions.** A runtime may own one isolated OTP
  trace session (the OTP 27 `trace` module) covering its own processes and an
  allowlist of Loopex modules. It reports function identity (module, function,
  arity), caller, process, timing and return-or-exception class for every call
  in those modules, with no instrumentation in the traced source. Argument and
  return capture is off by default; an explicit administrative flag enables
  bounded, redacted capture. Enabling, changing or stopping a session is a
  host administrative act at launch or through the facade; no session command,
  client content, model output, project resource or wire request can do it.
- **Telemetry boundary events.** Core emits `:telemetry` span events (start,
  stop, exception, with durations and counts) at every port call and every
  coordinator transaction cut: admission, commit, model attempt, policy
  decision, effect intent and dispatch, receipt, publication, interaction and
  artifact transfer. Metadata carries identities, kinds and outcome categories,
  never content, credentials or arguments. `:telemetry` becomes core's one
  observability dependency; reporters, exporters and OpenTelemetry remain
  edge adapters.

Both feed the diagnostics plane. Trace output and telemetry events are
bounded in term size, rate and queue depth, degrade by dropping rather than
blocking a coordinator, and are never authority or session truth.

Technical depth: [Contract and evidence](0029-observability-tracing-and-telemetry-technical.md#technical-adr-0029-decision).

<a id="concept-adr-0029-consequences"></a>
### Consequences, Compatibility and Rollback

Developers get exhaustive call tracing without touching any file, and hosts
get standard metrics events at the boundaries that matter. The cost is one
pure-Erlang, dependency-free library in core, a small fixed set of
instrumentation points, and a tracer that must redact and truncate. Trace
sessions require the OTP 27 floor ADR 0026 proposes; on the current floor the
session facility is unavailable evidence, not a fallback to VM-global tracing.

No durable format changes. Events and trace output are transient diagnostics.
Removing the trace facility or the telemetry dependency restores the previous
behavior without data migration. A future OpenTelemetry edge, metrics reporter
or W3C trace-context correlation is a separate adapter decision.

Technical depth: [Compatibility mechanics](0029-observability-tracing-and-telemetry-technical.md#technical-adr-0029-compatibility).

## Governance Record

| Decision | Authority | Authority evidence | Bound bytes |
| --- | --- | --- | --- |
| Acceptance | — | — | — |
