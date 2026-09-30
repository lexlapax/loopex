<a id="concept"></a>
## Concept

Technical depth: [Run model and reasoning configuration](0044-run-model-and-reasoning-configuration-technical.md#technical-depth).

- **Status:** Proposed
- **Date:** 2026-09-30
- **Decision owner:** Maintainer
- **Supersedes:** [ADR 0010](0010-provider-continuation-and-context-staging.md#concept) session-fixed model and empty continuation field; [ADR 0011](0011-session-input-algebra-and-streaming.md#concept) closed input set to add `configure`; [ADR 0017](0017-durable-context-admission-budget.md#concept) runtime-only context-budget placement to allow committed per-session creation/configuration. Exact staged requests and admitted run bounds remain frozen. Also amends [ADR 0016](0016-configured-cancellation-observation.md#concept)'s exact genesis shape, preserving its mandatory committed cleanup value. Amends [ADR 0018](0018-provider-attempt-authority-and-recovery.md#concept)'s closed reply/settlement shapes and ADR 0017's estimator preimage to include bounded private continuation, preserving attempt authority and both owning-record ceilings.
- **Requires with multi-provider use:** [ADR 0048](0048-host-provider-routing-and-credential-bindings.md#concept)
- **Prerequisite for:** M7 outcome 4

<a id="concept-adr-0044-decision"></a>
### Context and Decision

Technical depth: [Contract](0044-run-model-and-reasoning-configuration-technical.md#technical-adr-0044-decision).

The maintainer selected bounded provider continuation for M7 on 2026-09-30.
Selected Claude thinking modes need exact provider blocks returned during tool
use. Keep those blocks privately with their committed reply, bound to the exact
model, configuration and current tool exchange. They are data, never authority.
This proposal defines the selected scope; its bytes remain unaccepted.

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
Raw history remains unchanged. Preserve the complete rendered conversation
prefix while a thinking tool exchange is open. Compaction waits until it ends;
if the next request cannot fit, stop with a named bound failure rather than
dropping or changing required blocks. A new run starts from canonical history
and never resurrects old thinking state.

Private continuation has a 16-KiB envelope cap and remains within the existing
64-KiB request and settlement record limits. Durable copies use the private
store's access controls and remain with raw session history until the host
retires that history; ephemeral copies end with their runtime. Local storage
remains plaintext under the existing host protection model. M7 adds no key
service or selective deletion. Public transcripts, events, snapshots, tool
results, summaries and diagnostics exclude the private blocks.

<a id="concept-adr-0044-consequences"></a>
### Observable Consequences

Technical depth: [Evidence](0044-run-model-and-reasoning-configuration-technical.md#technical-adr-0044-evidence).

Each run reports which configuration produced it. A→B→A continuation must retain
earlier facts and tool evidence. Higher reasoning may use more time/tokens, within
the same declared stopping rules. Saved file changes alone do not alter history
or pending work. Unsupported models or thinking formats refuse explicitly; a
provider catalog entry alone is not a support promise. Crash recovery must
preserve the exact required blocks or fail without another provider call.

<a id="concept-adr-0044-compatibility"></a>
### Compatibility and Rollback

Technical depth: [Compatibility mechanics](0044-run-model-and-reasoning-configuration-technical.md#technical-adr-0044-compatibility).

New configuration records/events, private continuation replies/settlements and
snapshot fields require an M7 reader. Old requests and settlements keep their
original meanings. Private continuation is retained in recovery state, never
in public configuration snapshots.
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
