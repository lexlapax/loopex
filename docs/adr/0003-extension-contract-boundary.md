# 0003. Extension contract boundary and distribution constraints

<a id="concept"></a>
## Concept

Technical depth: [Boundary mechanics and deferrals](0003-extension-contract-boundary-technical.md#technical-depth).

- **Status:** Accepted
- **Date:** 2026-08-15
- **Decision owner:** Maintainer
- **Prerequisite for:** nothing currently blocked; `M0` remains blocked on
  [ADR 0001](0001-repository-and-application-layout.md#concept) and
  [ADR 0002](0002-bootstrap-runtime-floor.md#concept) only

## Governance Record

| Decision | Authority | Authority evidence | Bound bytes |
| --- | --- | --- | --- |
| Acceptance | Maintainer | [disposition](../developer/agent-context-map.md#disposition-founding-adrs-2026-08-15) | candidate `c703a65b665a5e64159e98833c63d29ff521cd2b`; concept `sha256:571d939bd84bc61c33eca6be34ed0b1647adf813a40ebf4cccf71d3695316724`; technical `sha256:80b070b259f5b132e51a62b92bf063410762ea9b92e0e7ae32d62ab2cffafdfa` |

<a id="concept-adr-0003-context"></a>
## Context

Loopex intends to host reviewed extensions developed in this repository and in
other repositories. An out-of-repository author can only build against something
Loopex publishes, so admitting third-party extensions creates obligations before
any extension exists.

Some of those obligations are cheap to reverse and some are permanent. Moving a
module between applications costs a commit while nothing is published; the same
move after publication is a compatibility event. This decision settles only the
questions that publication would foreclose, and defers the rest to the milestone
that builds extensions.

Technical depth: [What publication forecloses](0003-extension-contract-boundary-technical.md#technical-adr-0003-context).

<a id="concept-adr-0003-decision"></a>
## Decision

- A contributor compiles against the extension contract in
  `apps/loopex_protocol`, never against the runtime. The runtime is an
  implementation an extension is loaded into, not a dependency it builds on.
- Only the contract and the runtime are candidate published units. Adapters,
  clients, and reference extensions become candidates only by a later accepted
  decision.
- Publication waits for a consumer that justifies it. This decision creates the
  option and does not exercise it.
- A first-party extension in this repository uses the same manifest, sealing,
  and activation path as a third-party one. No shortcut exists for extensions
  Loopex authors itself.
- A filesystem location holding packages is an acquisition source that
  installation validates, never a path a running brain loads from. Presence in
  a directory grants nothing.
- The configuration naming admissible sources belongs to the host. Loopex core
  reads no user or host configuration location.

Technical depth: [Exact obligations and deferred questions](0003-extension-contract-boundary-technical.md#technical-adr-0003-decision).

<a id="concept-adr-0003-alternatives"></a>
## Alternatives

Publishing the runtime as the contributor-facing dependency was rejected: it
would pin every extension to a runtime version and weld two separately versioned
compatibility surfaces into one package.

Deciding the full acquisition and installation pipeline now was rejected. Its
correct shape depends on a runtime, a manifest implementation, and real
conflict cases, none of which exist. Deciding it now would relocate a redo
rather than prevent one.

Deferring every question to the extension milestone was rejected: the
contributor-facing boundary and the publication rule constrain work that starts
before extensions do.

Technical depth: [Alternative analysis](0003-extension-contract-boundary-technical.md#technical-adr-0003-alternatives).

<a id="concept-adr-0003-consequences"></a>
## Consequences

The extension API can evolve on its own schedule because it is a separate
application and, if published, a separate package. First-party extension work
becomes slower than wiring an application in directly, which is the intended
cost: the contract is exercised by its own authors before anyone else depends
on it.

Because conflicts resolve across the whole sealed closure, admitting one package
may require re-sealing the installed set or isolating the candidate in another
VM. That makes minimal first-party extension dependencies an operational
requirement rather than a preference.

The boundary between contract and runtime is drawn before either exists, so its
first placement will be partly wrong and corrected by in-repository moves while
nothing is published.

Technical depth: [Operational consequences](0003-extension-contract-boundary-technical.md#technical-adr-0003-consequences).

<a id="concept-adr-0003-compatibility"></a>
## Compatibility, Migration, and Rollback

No compatibility surface exists until something is published. Publication
triggers the amendment obligations recorded in
[ADR 0002](0002-bootstrap-runtime-floor.md#concept-adr-0002-compatibility) and
creates the released-package surface the vision now names.

Rollback is deleting this decision and its consequences while unpublished. After
publication, withdrawing a package or moving a module across the boundary is a
compatibility event requiring migration evidence.

Technical depth: [Compatibility and rollback mechanics](0003-extension-contract-boundary-technical.md#technical-adr-0003-compatibility).

## Links

- [Vision: trusted extensions](../vision.md#concept-vision-extensions) and its
  [technical depth](../vision-technical.md#technical-vision-extensions)
- [Vision: compatibility surfaces](../vision.md#concept-vision-compatibility)
- [ADR 0001](0001-repository-and-application-layout.md#concept) — the
  application boundary this decision depends on
- [Roadmap ADR agenda](../roadmap-technical.md#technical-depth) — the deferred
  packaging, acquisition, and installation decision and its trigger
