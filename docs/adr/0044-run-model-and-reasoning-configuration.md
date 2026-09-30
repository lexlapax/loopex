<a id="concept"></a>
## Concept

Technical depth: [Run model and reasoning configuration](0044-run-model-and-reasoning-configuration-technical.md#technical-depth).

- **Status:** Proposed
- **Date:** 2026-09-30
- **Decision owner:** Maintainer
- **Supersedes:** [ADR 0010](0010-provider-continuation-and-context-staging.md#concept) session-fixed model and empty continuation field; [ADR 0011](0011-session-input-algebra-and-streaming.md#concept) closed input set to add `configure`; [ADR 0017](0017-durable-context-admission-budget.md#concept) runtime-only context-budget placement to allow committed per-session creation/configuration. Exact staged requests and admitted run bounds remain frozen. Also amends [ADR 0016](0016-configured-cancellation-observation.md#concept)'s exact genesis shape, preserving its mandatory committed cleanup value. Amends [ADR 0018](0018-provider-attempt-authority-and-recovery.md#concept)'s closed reply/settlement shapes and ADR 0017's estimator preimage to include bounded private continuation, preserving attempt authority and both owning-record ceilings. Receipt revision 4 adds that charge separately while preserving ADR 0017/0025 descriptor totals and old v2/v3 equations. Also extends [ADR 0021](0021-compacted-provider-accounting-provenance.md#concept) through a new v3 settlement, preserving its accounting-provenance rules and the existing v2 meaning.
- **Requires with multi-provider use:** [ADR 0048](0048-host-provider-routing-and-credential-bindings.md#concept)
- **Prerequisite for:** M7 outcome 4

<a id="concept-adr-0044-decision"></a>
### Context and Decision

Technical depth: [Contract](0044-run-model-and-reasoning-configuration-technical.md#technical-adr-0044-decision).

The maintainer selected bounded provider continuation for M7 on 2026-09-30.
Selected Claude thinking modes need exact provider blocks returned during tool
use. Keep those blocks privately with their committed reply, bound to the exact
model, configuration and current tool exchange. They are data, never authority.
The adapter must capture and render native blocks before ordinary ReqLLM
conversation conversion loses or rearranges them, while retaining the existing
transport, credential and cleanup boundaries. This proposal defines the
selected scope; its bytes remain unaccepted.

The maintainer also selected live streaming. The existing durable streaming
path delivers answer text as it arrives, subject to ordinary progress limits.
It assembles complete provider blocks privately before a reply can authorize
tools. Interrupted or malformed streams may leave visible provisional text,
but never a partial durable answer or tool call. Recovery follows the existing
attempt rules and cannot restart an ambiguous provider call. The buffered
ephemeral path keeps ADR 0039's non-streaming contract and must preserve the
same complete native data before returning a reply.

Configuration becomes a durable session fact. Creation and settled-only
`configure` commit an exact model identity, reasoning, instruction envelope and
context/reply limits with one version. A run captures that version at admission
and keeps it through restart. No configuration change occurs inside a run or
unresolved maintenance operation.
Maintenance retains the parent configuration identity and applicable ceilings,
while capturing ADR 0043's separately configured summarizer and host instructions.
Changing ordinary model or instructions does not replace those runtime settings
or rewrite an admitted maintenance episode.

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
Raw history remains unchanged. The maintainer selected removal of duplicate
text/tool arguments and a reserve before thinking exchanges on 2026-09-30.
Store those values once in the canonical reply or request and retain bounded
local references in its private provider layout. A small provider-neutral
expansion rule supports core accounting and adapter rendering; it reads only
that reply/request. The adapter proves the restored native blocks equal the
captured blocks. References grant no access to history, artifacts or a provider.

Before a new thinking exchange, leave half the complete request-record capacity
and up to 8,192 estimated input tokens available for its continuation. Earlier
eligible history may need compaction even when the first request would fit the
hard limits. Required current content that cannot leave this reserve refuses
before the first ordinary provider call. Existing summary attempts, spending
and deadlines still bound preparation. The reserve does not guarantee a number
of tool rounds or make an oversized reply acceptable.
Preserve the complete rendered conversation
prefix while a thinking tool exchange is open. Compaction waits until it ends;
if the next request cannot fit, stop with a named bound failure rather than
dropping or changing required blocks. A new run starts from canonical history
and never resurrects old thinking state.

Private continuation has a 16-KiB cap on both stored and expanded envelopes,
and remains within the existing
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
The smaller stored form provides no token discount: admission still charges
the complete expanded continuation in addition to canonical conversation data.
Operators can observe earlier compaction and a named reserve refusal while the
ordinary hard limits remain unchanged.
Streaming clients distinguish provisional text and a closed or abandoned
stream from the committed final answer. A silent interval while the provider
thinks is possible; Loopex does not invent progress text or expose private
blocks to fill it.

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
