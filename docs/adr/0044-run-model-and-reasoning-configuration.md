<a id="concept"></a>
## Concept

Technical depth: [Run model and reasoning configuration](0044-run-model-and-reasoning-configuration-technical.md#technical-depth).

- **Status:** Proposed
- **Date:** 2026-09-30
- **Decision owner:** Maintainer
- **Supersedes:** [ADR 0010](0010-provider-continuation-and-context-staging.md#concept) session-fixed model; [ADR 0011](0011-session-input-algebra-and-streaming.md#concept) closed input set to add `configure`; [ADR 0017](0017-durable-context-admission-budget.md#concept) runtime-only context-budget placement to allow committed per-session creation/configuration. Exact staged requests and admitted run bounds remain frozen. Also amends [ADR 0016](0016-configured-cancellation-observation.md#concept)'s exact genesis shape, preserving its mandatory committed cleanup value.
- **Requires with multi-provider use:** [ADR 0048](0048-host-provider-routing-and-credential-bindings.md#concept)
- **Prerequisite for:** M7 outcome 4

<a id="concept-adr-0044-decision"></a>
### Context and Decision

Technical depth: [Contract](0044-run-model-and-reasoning-configuration-technical.md#technical-adr-0044-decision).

**Open scope question:** the maintainer is choosing between a verified
canonical-history reasoning subset and bounded provider-specific continuation
in M7. The current canonical-only clauses remain a draft pending that answer.
Neither alternative has been accepted.

Configuration becomes a durable session fact. Creation and settled-only
`configure` commit an exact model identity, reasoning, instruction envelope and
context/reply limits with one version. A run captures that version at admission
and keeps it through restart. No configuration change occurs inside a run or
unresolved maintenance operation.

A host-authorized controller may switch model or provider between runs while
preserving canonical history. Reference CLI ownership and the daemon controller
lease grant configuration authority; observers cannot configure. Other hosts
restrict allowed models and ceilings before calling core. Startup defaults are
mutable defaults, not implicit tenant quotas. Core gains no host policy engine. Host roles resolve before admission; core defines no role type or routing meaning and stores no credential handles.
Role names may occur as uninterpreted host instruction facts; they grant nothing. Validate provider availability, model capability, reasoning,
instructions and effective context together before committing. Refusal leaves
the prior configuration intact. Resume defaults to the committed configuration;
a launch override never silently changes it.

Reasoning is `default`, `none`, `low`, `medium` or `high`. The adapter declares
its supported subset; unsupported values refuse. `default` omits the provider
option. An incompatible model/provider change removes provider-affine continuation
material from projection, while preserving canonical text, calls and results.
Raw history remains unchanged.

<a id="concept-adr-0044-consequences"></a>
### Observable Consequences

Technical depth: [Evidence](0044-run-model-and-reasoning-configuration-technical.md#technical-adr-0044-evidence).

Each run reports which configuration produced it. A→B→A continuation must retain
earlier facts and tool evidence. Higher reasoning may use more time/tokens, within
the same declared stopping rules. Saved file changes alone do not alter history
or pending work.

<a id="concept-adr-0044-compatibility"></a>
### Compatibility and Rollback

Technical depth: [Compatibility mechanics](0044-run-model-and-reasoning-configuration-technical.md#technical-adr-0044-compatibility).

New configuration records/events and snapshot fields require an M7 reader.
A shared genesis revision retains initial configuration, immutable tool
definitions and policy-defer mode with the existing mandatory cleanup value.
ADR 0046 uses this same revision; it does not create a competing session shape.
For legacy sessions derive model from their latest committed request, using an
explicit host model only for sessions with no prior model request. Conflicting
or ambiguous legacy history refuses with a migration diagnostic. Never choose
an arbitrary current file default for an unfinished legacy run.

## Governance Record

| Decision | Authority | Authority evidence | Bound bytes |
| --- | --- | --- | --- |
| Acceptance | — | — | — |
