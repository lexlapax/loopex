# Developer Documentation

How Loopex is built and how to build on it. How Loopex itself is developed is
in the [development process](../process/README.md). Part of the
[documentation index](../README.md).

## Start Here

New to the repository, in this order:

1. [Getting started](getting-started.md#concept) — the two tracks: building on
   Loopex, or contributing to it.
2. [Root README](../../README.md) — what Loopex is and where things stand.
3. [DEVELOPMENT.md](../../DEVELOPMENT.md) — prerequisites and the two check
   commands: `bash scripts/check.sh` once per integration candidate and
   `bash scripts/check-release.sh` once before closure; an unchanged-source
   release reuses that evidence.
4. [Plans and current status](../plans/README.md) — what the project is
   committed to, what is authorized right now, and the next decision. Its
   Directing the Work section covers how development is requested.
5. [AGENTS.md](../../AGENTS.md) — the canonical development contract: authority,
   autonomy tiers, milestones and checks.
6. [Development charter](../process/development-charter.md#concept) — why documentation is
   shaped the way it is, before adding or restructuring any of it.

Read the [vision pair](../vision.md#concept) when the work touches architecture,
trust boundaries, public contracts, or a new plan. Use the
[context map](../process/agent-context-map.md) to load only the sections a task needs
rather than reading documents end to end.

## Building on Loopex

For embedding a runtime, driving it over the wire, or understanding how it
works.

| Document | Purpose |
| --- | --- |
| [Getting started](getting-started.md#concept) · [technical](getting-started-technical.md#technical-depth) | Two tracks: building on Loopex (a one-call ephemeral host, durable embedding, or the daemon/app-server protocol) and contributing (toolchain, checks, milestones). |
| [Architecture](architecture.md#concept) · [technical](architecture-technical.md#technical-depth) | The applications and their inward dependency direction, the replaceable ports, the truth planes and who may publish to each, and the serial session owner; then the invariants with the module enforcing each, the record shapes, and a sequence diagram of one turn. |
| [Runtime and embedding](runtime-and-embedding.md#concept) | Ephemeral and durable composition over one kernel: the in-VM session API and its trust limit, durable embedding and options, resource snapshots and commands, interactions, transfers and recovery. |
| [Agent loop and tools](agent-loop-and-tools.md#concept) | The multi-turn loop: turn ordering, the tool registry and canonical requests, attempts and settlement, run bounds, streaming, host policy, artifacts, and progressive skill context and replay. |
| [App server protocol](app-server-protocol.md#concept) · [technical](app-server-protocol-technical.md#technical-depth) | The normative wire reference for both session-protocol generations: the foreground `loopex.experimental/3` served over standard input and output, and the daemon's `loopex.experimental/4` over its Unix socket, with methods, record families, error codes, encodings, limits and evidence. |
| [The daemon](daemon.md#concept) · [technical](daemon-technical.md#technical-depth) | The host that keeps a root's sessions alive between processes over generation 4 on a Unix-domain socket: controller lease and takeover, durable-first delivery and lifecycle order; then its processes, stop clocks, bounds, succession and tests. |
| [Observability](observability.md#concept) · [technical](observability-technical.md#technical-depth) | Trace sessions and telemetry as the diagnostics plane, why neither is truth or authority, and why redaction is a contract; then the ADR 0030 emission inventory, trace ceilings, redaction rules and their tests. |
| [Compatibility surfaces](compatibility-surfaces.md#concept) | The experimental ephemeral API and `ask` command alongside durable and wire surfaces, exact-generation rules, old-reader refusal and rollback, and why none is frozen. |

## Contributing

Checks, milestones, the documentation charter and the context map are in the
[development process](../process/README.md).

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
