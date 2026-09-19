# Developer Documentation

Method, routing, and retained evidence for working on Loopex. Part of the
[documentation index](../README.md).

## Start Here

New to the repository, in this order:

1. [Root README](../../README.md) — what Loopex is and where things stand.
2. [DEVELOPMENT.md](../../DEVELOPMENT.md) — prerequisites, and the one command
   that validates a checkout: `bash scripts/check-bootstrap.sh`.
3. [Plans and current status](../plans/README.md) — what the project is
   committed to, what is authorized right now, and the next decision. Its
   Directing the Work section covers how development is requested.
4. [AGENTS.md](../../AGENTS.md) — the canonical development contract: authority,
   autonomy tiers, milestones and checks.
5. [Development charter](development-charter.md#concept) — why documentation is
   shaped the way it is, before adding or restructuring any of it.

Read the [vision pair](../vision.md#concept) when the work touches architecture,
trust boundaries, public contracts, or a new plan. Use the context map below to
load only the sections a task needs rather than reading it end to end.

## Contents

| Document | Purpose |
| --- | --- |
| [Development charter](development-charter.md#concept) · [technical](development-charter-technical.md#technical-depth) | Clarity before mechanism, traceable depth, proportional documentation, capability routing. |
| [Architecture](architecture.md#concept) · [technical](architecture-technical.md#technical-depth) | The ten applications and their inward dependency direction, the five replaceable ports, the truth planes and who may publish to each, the serial session owner, with an architecture diagram, a truth-plane diagram, the invariants and the module enforcing each, the record shapes, and a sequence diagram of one turn. |
| [Runtime and embedding](runtime-and-embedding.md#concept) | Application shape, explicit composition, immutable skill snapshots, resource commands and queries, the durable interaction lifecycle and the bounded artifact transfer capability as embedding contracts, commit ordering, recovery and verification entrypoints. |
| [Agent loop and tools](agent-loop-and-tools.md#concept) | Turn ordering, tool registry, canonical requests, attempts and settlement, bounds, streaming, policy, artifacts, required-first admission, progressive skill context and replay. |
| [App server protocol](app-server-protocol.md#concept) · [technical](app-server-protocol-technical.md#technical-depth) | The experimental session generation as the normative wire reference: why one contract rather than a second loop, what the experimental name commits to, why strict framing is the feature, the two delivery planes; then the sixteen methods, seven record families, fifteen error codes, wire encodings, exact limits, the transport process and the evidence. |
| [Observability](observability.md#concept) · [technical](observability-technical.md#technical-depth) | Trace sessions and telemetry as the diagnostics plane: why neither is truth or authority, why core emits and the edge handles, why redaction is a contract; then the exact ADR 0030 emission inventory, the trace configuration domain and ceilings, the redaction rules and the tests that hold them. |
| [Verification](verification.md#concept) · [technical](verification-technical.md#technical-depth) | The rule book for checking work after the milestone gates: three stages with one question each, how a changed boundary selects its checks, the rules that keep the checks honest, and the measured plan for making the push check fast; then what each stage runs, where each boundary's checks live, and the per-application and per-test measurements behind the plan. |
| [Compatibility surfaces](compatibility-surfaces.md#concept) | M2, M3 and M4 surfaces with their experimental labels, the app server's exact-generation rule, interaction-record old-reader refusal and rollback, and why none is labelled or frozen. |
| [Agent context map](agent-context-map.md) | Task-oriented routing into Concept first and exact Technical depth second; current client-ecosystem facts. |
| [Adapter smoke evidence](agent-adapter-smoke.md) | Retained proof that development clients load the canonical contract and skills. |

The charter is a Concept and Technical depth pair and is changed and reviewed as
one authority. The context map and smoke evidence are routing and evidence
records; they are deliberately unpaired and may link both depths. Runtime and
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
