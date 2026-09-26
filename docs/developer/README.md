# Developer Documentation

How Loopex is built, how to build on it, and how work on it is planned,
checked and recorded. Part of the [documentation index](../README.md).

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
6. [Development charter](development-charter.md#concept) — why documentation is
   shaped the way it is, before adding or restructuring any of it.

Read the [vision pair](../vision.md#concept) when the work touches architecture,
trust boundaries, public contracts, or a new plan. Use the
[context map](agent-context-map.md) to load only the sections a task needs
rather than reading documents end to end.

## Building on Loopex

For embedding a runtime, driving it over the wire, or understanding how it
works.

| Document | Purpose |
| --- | --- |
| [Getting started](getting-started.md#concept) · [technical](getting-started-technical.md#technical-depth) | Two tracks: building on Loopex (embedding a runtime, driving the daemon/app-server protocol) and contributing (toolchain, checks, milestones). |
| [Architecture](architecture.md#concept) · [technical](architecture-technical.md#technical-depth) | The applications and their inward dependency direction, the replaceable ports, the truth planes and who may publish to each, and the serial session owner; then the invariants with the module enforcing each, the record shapes, and a sequence diagram of one turn. |
| [Runtime and embedding](runtime-and-embedding.md#concept) | Embedding a runtime: application shape, explicit composition, resource snapshots and commands, durable interactions, bounded artifact transfers, commit ordering, the embedded API, recovery and verification entry points. |
| [Agent loop and tools](agent-loop-and-tools.md#concept) | The multi-turn loop: turn ordering, the tool registry and canonical requests, attempts and settlement, run bounds, streaming, host policy, artifacts, and progressive skill context and replay. |
| [App server protocol](app-server-protocol.md#concept) · [technical](app-server-protocol-technical.md#technical-depth) | The normative wire reference for both session-protocol generations: the foreground `loopex.experimental/1` served over standard input and output, and the daemon's `loopex.experimental/2` over its Unix socket, with methods, record families, error codes, encodings, limits and evidence. |
| [The daemon](daemon.md#concept) · [technical](daemon-technical.md#technical-depth) | The host that keeps a root's sessions alive between processes over generation 2 on a Unix-domain socket: controller lease and takeover, durable-first delivery and lifecycle order; then its processes, stop clocks, bounds, succession and tests. |
| [Observability](observability.md#concept) · [technical](observability-technical.md#technical-depth) | Trace sessions and telemetry as the diagnostics plane, why neither is truth or authority, and why redaction is a contract; then the ADR 0030 emission inventory, trace ceilings, redaction rules and their tests. |
| [Compatibility surfaces](compatibility-surfaces.md#concept) | Every surface Loopex exposes to an embedder or client today, its experimental label, the app server's exact-generation rule, interaction-record old-reader refusal and rollback, and why none is labelled or frozen. |

## Contributing

For changing Loopex: which checks a change needs, how a milestone runs, and
where to read for a given task.

| Document | Purpose |
| --- | --- |
| [Verification](verification.md#concept) · [technical](verification-technical.md#technical-depth) | The rule book for checking work: three stages with one question each, how a changed boundary selects its checks, the rules that keep checks honest, and the measured speed plan; then what each stage runs, where each boundary's checks live, and the measurements. |
| [Milestones](milestones.md#concept) · [technical](milestones-technical.md#technical-depth) | How to plan, run, close and release a milestone: the plan pair, small reviewed merges, the two-commit closure and the pre-tag proofs; then the exact plan sections, register row, branch conventions, closure commands, confinement rule and tag. |
| [Agent context map](agent-context-map.md) | Task-oriented routing into Concept first and exact Technical depth second, current client facts and capability mappings, and the indexed record of maintainer dispositions. |

## Governance

The development method itself and the evidence that development clients follow
it.

| Document | Purpose |
| --- | --- |
| [Development charter](development-charter.md#concept) · [technical](development-charter-technical.md#technical-depth) | Clarity before mechanism: the two-depth documentation pairs, traceable links, report and decision-packet form, capability routing, proportional documentation, portable enforcement, and how the charter itself changes. |
| [Adapter smoke evidence](agent-adapter-smoke.md) | Dated evidence of what the development clients actually load and enforce, including the read-only review lane. |

## Document Forms

Paired documents — the getting-started, architecture, protocol, daemon,
observability, verification, milestone and charter pairs — are a Concept file
and a Technical depth file changed and reviewed as one authority. Runtime and
embedding, agent loop and tools, and compatibility surfaces are subsystem
references that carry both depths in one file, each opening with its `Concept`
section and reaching its `Technical depth` section below it. The context map
and the smoke evidence are routing and evidence records; they are deliberately
unpaired and may link both depths.

## Related

- [Decisions](../adr/README.md) — accepted and proposed architecture decisions.
- [Plans](../plans/README.md) — milestone register and lifecycle.
- [Operator documentation](../operator/README.md) — runtime operation and recovery runbooks.
- [Independent clients](../../clients/README.md) — consumers of the experimental
  session protocol written outside Elixir, and the evidence they carry.
- [Archive](../archive/README.md) — non-normative historical inputs.
