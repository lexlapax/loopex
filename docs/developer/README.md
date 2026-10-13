# Developer Documentation

How Loopex works and how to build on it: embedding a runtime, driving its
sessions over the wire, and replacing a port. How Loopex itself is developed —
checks, milestones, the documentation charter and the context map — is in the
[development process](../process/README.md) and
[DEVELOPMENT.md](../../DEVELOPMENT.md). Part of the
[documentation index](../README.md).

## Start Here

New to Loopex, in this order:

1. [Getting started](getting-started.md#concept) — embedding a runtime, writing
   the host policy, driving sessions over the wire, and replacing a port.
2. [Root README](../../README.md) — what Loopex is and where things stand.
3. [Architecture](architecture.md#concept) — the applications, ports, truth
   planes and the serial session owner.

Read the [vision pair](../vision.md#concept) for the direction behind these
contracts.

## Building on Loopex

For embedding a runtime, driving it over the wire, or understanding how it
works.

| Document | Purpose |
| --- | --- |
| [Getting started](getting-started.md#concept) · [technical](getting-started-technical.md#technical-depth) | Building on Loopex: a one-call ephemeral host, durable embedding, the host policy, the daemon/app-server protocol, replacing a port, and a first trace session. |
| [Architecture](architecture.md#concept) · [technical](architecture-technical.md#technical-depth) | The applications and their inward dependency direction, the replaceable ports, the truth planes and who may publish to each, and the serial session owner; then the invariants with the module enforcing each, the record shapes, and a sequence diagram of one turn. |
| [Runtime and embedding](runtime-and-embedding.md#concept) | Ephemeral and durable composition over one kernel: the in-VM session API and its trust limit, durable embedding and options, resource snapshots and commands, interactions, transfers and recovery. |
| [Agent loop and tools](agent-loop-and-tools.md#concept) | The multi-turn loop: turn ordering, the tool registry and canonical requests, attempts and settlement, run bounds, streaming, host policy, artifacts, and progressive skill context and replay. |
| [App server protocol](app-server-protocol.md#concept) · [technical](app-server-protocol-technical.md#technical-depth) | The normative wire reference for both session-protocol generations: the foreground `loopex.experimental/3` served over standard input and output, and the daemon's `loopex.experimental/4` over its Unix socket, with methods, record families, error codes, encodings and limits. |
| [The daemon](daemon.md#concept) · [technical](daemon-technical.md#technical-depth) | The host that keeps a root's sessions alive between processes over generation 4 on a Unix-domain socket: controller lease and takeover, durable-first delivery and lifecycle order; then its processes, stop clocks, bounds and succession. |
| [Observability](observability.md#concept) · [technical](observability-technical.md#technical-depth) | Trace sessions and telemetry as the diagnostics plane, why neither is truth or authority, and why redaction is a contract; then the ADR 0030 emission inventory, trace ceilings and redaction rules. |
| [Compatibility surfaces](compatibility-surfaces.md#concept) | The experimental ephemeral API and `ask` command alongside durable and wire surfaces, exact-generation rules, current-format reading and recovery, and why none is frozen. |

## Document Forms

Paired documents — the getting-started, architecture, protocol, daemon and
observability pairs — are a Concept file
and a Technical depth file changed and reviewed as one authority. Runtime and
embedding, agent loop and tools, and compatibility surfaces are subsystem
references that carry both depths in one file, each opening with its `Concept`
section and reaching its `Technical depth` section below it.

## Related

- [Decisions](../adr/README.md) — accepted and proposed architecture decisions.
- [Plans](../plans/README.md) — milestone register and lifecycle.
- [Operator documentation](../operator/README.md) — runtime operation and recovery runbooks.
- [Independent clients](../../clients/README.md) — consumers of the experimental
  session protocol written outside Elixir, and the evidence they carry.
- [Archive](../archive/README.md) — non-normative historical inputs.
