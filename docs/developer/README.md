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
   autonomy tiers, milestones and gates.
5. [Development charter](development-charter.md#concept) — why documentation is
   shaped the way it is, before adding or restructuring any of it.

Read the [vision pair](../vision.md#concept) when the work touches architecture,
trust boundaries, public contracts, or a new plan. Use the context map below to
load only the sections a task needs rather than reading it end to end.

## Contents

| Document | Purpose |
| --- | --- |
| [Development charter](development-charter.md#concept) · [technical](development-charter-technical.md#technical-depth) | Clarity before mechanism, traceable depth, proportional documentation, capability routing. |
| [Runtime and embedding](runtime-and-embedding.md#concept) | Application shape, explicit runtime composition, commit ordering, embedded API, the shipped reference composition, recovery, and verification entrypoints. |
| [Agent loop and tools](agent-loop-and-tools.md#concept) | The M2 turn machine: the tool contract and registry, canonical encoding, conversation projection, request digests, bounds, streaming, policy, artifacts, and commit ordering. |
| [Compatibility surfaces](compatibility-surfaces.md#concept) | Every surface M2 touches, why none is labelled or frozen, and what that means for an embedder. |
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
- [Archive](../archive/README.md) — non-normative historical inputs.
