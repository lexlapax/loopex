<a id="concept"></a>
## Concept

Technical depth: [Observability mechanics](0030-observability-tracing-and-telemetry-technical.md#technical-depth).

- **Status:** Proposed
- **Date:** 2026-09-12
- **Decision owner:** Maintainer
- **Supersedes:** 0001, only the two clauses that require an empty `apps/loopex` dependency list
- **Prerequisite for:** M4 acceptance

<a id="concept-adr-0030-decision"></a>
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
  stop, exception, with durations and counts) at exactly the emission
  inventory the technical companion binds: every callback of the model, store,
  artifact-store, executor and policy ports, and six coordinator cuts (command
  admission; durable commit and `commit_unknown` resolution; effect intent;
  receipt and publication; interaction transitions; artifact transfer
  lifecycle). Metadata carries identities, kinds and outcome categories, never
  content, credentials or arguments. `:telemetry` becomes core's sole external
  dependency under the maintainer's recorded
  [vision change](../developer/agent-context-map.md#disposition-m4-vision-core-telemetry-2026-09-13)
  of 2026-09-13; this decision supersedes only the two ADR 0001 clauses that
  require an empty `apps/loopex` dependency list (its Decision bullet for
  `apps/loopex` and implementation constraint 1 as it applies to
  `apps/loopex`), and every other ADR 0001 clause, including the empty
  protocol dependency list and the one-way contract edge, stands. Telemetry
  dispatch is synchronous by the library's design, so core attaches no handler
  at all; a new edge application, `loopex_telemetry`, owns the only
  Loopex-attached handler, which hands each event to the runtime's diagnostics
  dispatcher through its asynchronous admission path and never blocks the
  emitting process. The dispatcher owns bounded admission for the queues
  Loopex controls: a sender reserves capacity with one hardware atomic before
  it sends, so the admission backlog can never exceed 4,096 items per runtime
  however many senders race; above that, items are dropped and counted
  without a send; crash reconciliation never erases a live reservation; the
  drop count is taken by one atomic exchange; and one summary item is
  published when the backlog drains. The host sink's own mailbox is the
  host's and is only backpressured, never bounded, by Loopex. Reporters, exporters and
  OpenTelemetry remain edge adapters. A handler a host attaches itself runs in
  the emitting process and is the host's responsibility.

Both feed the diagnostics plane. Trace output is bounded to at most 4,096
bytes per entry after redaction, 2,000 entries per second per session and
8,192 queued entries; every excess is dropped and counted. Loopex-owned paths
degrade by dropping rather than blocking a coordinator, and nothing here is
authority or session truth.

Technical depth: [Contract and evidence](0030-observability-tracing-and-telemetry-technical.md#technical-adr-0030-decision).

<a id="concept-adr-0030-consequences"></a>
### Consequences, Compatibility and Rollback

Developers get exhaustive call tracing without touching any file, and hosts
get standard metrics events at the boundaries that matter. The cost is one
pure-Erlang, dependency-free library in core admitted by an explicit vision
change, one small edge application for the forwarding handler and reporter
wiring, a bound inventory of instrumentation points, and a tracer that must
redact and truncate. Trace sessions require the OTP 27 floor ADR 0026
proposes; on the current floor the session facility is unavailable evidence,
not a fallback to VM-global tracing.

No durable format changes. Events and trace output are transient diagnostics.
Removing the trace facility or the telemetry dependency restores the previous
behavior without data migration. A future OpenTelemetry edge, metrics reporter
or W3C trace-context correlation is a separate adapter decision.

Technical depth: [Compatibility mechanics](0030-observability-tracing-and-telemetry-technical.md#technical-adr-0030-compatibility).

## Governance Record

| Decision | Authority | Authority evidence | Bound bytes |
| --- | --- | --- | --- |
| Acceptance | — | — | — |
