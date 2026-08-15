# 0001. Repository and application layout

<a id="concept"></a>
## Concept

Technical depth: [Repository layout mechanics](0001-repository-and-application-layout-technical.md#technical-depth).

- **Status:** Proposed
- **Date:** 2026-08-15
- **Decision owner:** Maintainer
- **Prerequisite for:** the M0 gate (see [the roadmap](../roadmap.md#concept-roadmap-m0))

## Governance Record

| Decision | Authority | Authority evidence | Bound bytes |
| --- | --- | --- | --- |
| Acceptance | — | — | — |

<a id="concept-adr-0001-context"></a>
## Context

Loopex needs one repository and one version train whose layout makes dependency
direction visible. The core must use only the Elixir/Erlang standard runtime,
while replaceable adapters may carry their own dependencies. Folder names alone
cannot prove that boundary, and application boundaries must not imply separate
packages or release trains.

Extensions add a consumer the layout must anticipate. A reviewed extension may
be developed in this repository or in its own, and an out-of-repository author
can only compile against something Loopex publishes. That is the demonstrated
external-consumer pressure the founding vision names as evidence for a package
boundary, and it applies to the extension contract rather than to the runtime.
The extension API is already a separately versioned compatibility surface, so
placing it inside the runtime application would let a single published package
weld the two surfaces to one version.

A current client hook anticipates `apps/loopex/mix.exs`, but it is early feedback
and is ineffective before a scaffold exists. The accepted scaffold must replace
that layout assumption with repository-owned enforcement.

Technical depth: [Constraints and current rider](0001-repository-and-application-layout-technical.md#technical-adr-0001-context).

<a id="concept-adr-0001-decision"></a>
## Decision

Use a single Elixir umbrella project at the repository root.

- `apps/loopex_protocol` contains the versioned protocol types and the extension
  contract — behaviours, callbacks, contribution and manifest schemas, and the
  canonical data types a contributor compiles against — with an empty dependency
  list. It depends on nothing in the repository.
- `apps/loopex` contains the pure core and OTP runtime with an empty dependency
  list, including development and test dependencies, and depends on
  `apps/loopex_protocol`. The edge runs one way; the contract never depends on
  the runtime.
- Every replaceable edge and reference client is a separate umbrella
  application that depends inward on `apps/loopex`.
- Application boundaries express dependency direction, not package boundaries.
  Loopex remains one version train through 0.x.
- Adapter and client applications are added only by accepted plans with a named
  responsibility and a concrete need.
- Language-neutral conformance fixtures stay outside `apps/`.
- The first accepted scaffold creates the repository-owned dependency-budget
  and direction command, connects the existing client hook to it, and proves
  both positive and adversarial cases in the M0 gate.

This ADR fixes the repository shape, not the future adapter inventory, package
publication, or implementation scaffold.

Technical depth: [Exact tree and enforcement obligations](0001-repository-and-application-layout-technical.md#technical-adr-0001-decision).

<a id="concept-adr-0001-alternatives"></a>
## Alternatives

A single Mix application would obscure the boundary between a dependency-free
core and adapters with external dependencies. Separate poncho projects or
repositories would buy independent release cadence that the project does not
need through 0.x, while making the shared build and one-version train harder.

Keeping the extension contract inside `apps/loopex` and relying on module
namespaces alone was rejected. Namespaces make a later extraction a package
split rather than a rename, but they never force an answer to what the contract
contains, and the answer stops being free once a package is published. Splitting
while nothing is published costs one application and is reversible; discovering
the boundary after publication is not.

Splitting protocol, core, and runtime into three applications was rejected. Core
and runtime have no distinct external consumer, so the boundary would carry no
evidence.

Technical depth: [Alternative analysis and evidence](0001-repository-and-application-layout-technical.md#technical-adr-0001-alternatives).

<a id="concept-adr-0001-consequences"></a>
## Consequences

The umbrella makes dependency direction inspectable and gives core an ordinary
fakes-only build, but the layout alone is not proof. Repository checks and an
adversarial fixture carry that evidence.

Repository-wide configuration, core-only validation, analysis setup, and later
publication require explicit commands. Runtime state must still be passed by
reference rather than hidden in application environment. A later package split
or project-wide external development tool remains a separate decision.

This decision deviates from the founding vision's singular
"protocol/core/runtime application". The deviation is deliberate and bounded:
the vision does not freeze application names or the tree, and it requires
external-consumer pressure before a boundary is drawn — which extensions supply.
A reviewer should weigh the deviation directly rather than discover it.

Drawing the contract boundary before any runtime exists means the first
placement will be partly wrong. That cost is paid in in-repository moves while
nothing is published, which is the reason to split now rather than later. Two
applications must also hold one version, so the version-train check covers both
from the first scaffold.

Technical depth: [Operational consequences and edge cases](0001-repository-and-application-layout-technical.md#technical-adr-0001-consequences).

<a id="concept-adr-0001-compatibility"></a>
## Compatibility, Migration, and Rollback

No released surface exists. Application names remain internal until a package
is published. Before product code exists, rollback removes the scaffold on the
same branch; after applications exist, renaming one requires an amendment with
compatibility and migration consequences.

Technical depth: [Compatibility and rollback mechanics](0001-repository-and-application-layout-technical.md#technical-adr-0001-compatibility).

## Links

- [Vision — dependency doctrine](../vision.md#concept-vision-dependency-doctrine)
- [Vision — repository seed](../vision.md#concept-vision-repository-seed)
- [Vision — compatibility](../vision.md#concept-vision-compatibility)
- [Roadmap — M0](../roadmap.md#concept-roadmap-m0)
- [Context map](../developer/agent-context-map.md)
