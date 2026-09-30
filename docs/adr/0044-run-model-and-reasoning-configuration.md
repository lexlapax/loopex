<a id="concept"></a>
## Concept

Technical depth: [Run model and reasoning configuration](0044-run-model-and-reasoning-configuration-technical.md#technical-depth).

- **Status:** Proposed
- **Date:** 2026-09-30
- **Decision owner:** Maintainer
- **Supersedes:** [ADR 0010](0010-provider-continuation-and-context-staging.md#concept) only its session-fixed-model clause; exact staged requests and provider-affine rules remain
- **Requires with multi-provider use:** [ADR 0048](0048-host-provider-routing-and-credential-bindings.md#concept)
- **Prerequisite for:** M7 outcome 4

<a id="concept-adr-0044-decision"></a>
### Context and Decision

Technical depth: [Contract](0044-run-model-and-reasoning-configuration-technical.md#technical-adr-0044-decision).

Configuration becomes a durable session fact. Creation and settled-only
`configure` commit an exact model identity, reasoning, instruction envelope and
context/reply limits with one version. A run captures that version at admission
and keeps it through restart. No configuration change occurs inside a run or
unresolved maintenance operation.

An operator may switch model or provider between runs while preserving canonical
history. Host roles resolve before admission; core stores no role names or
credential handles. Validate provider availability, model capability, reasoning,
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
For legacy sessions derive model from their latest committed request, using an
explicit host model only for sessions with no prior model request. Conflicting
or ambiguous legacy history refuses with a migration diagnostic. Never choose
an arbitrary current file default for an unfinished legacy run.

## Governance Record

| Decision | Authority | Authority evidence | Bound bytes |
| --- | --- | --- | --- |
| Acceptance | — | — | — |
