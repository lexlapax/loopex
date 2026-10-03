<a id="concept"></a>
## Concept

Technical depth: [Run model and reasoning configuration](0044-run-model-and-reasoning-configuration-technical.md#technical-depth).

- **Status:** Accepted
- **Date:** 2026-09-30
- **Decision owner:** Maintainer
- **Supersedes:** [ADR 0010](0010-provider-continuation-and-context-staging.md#concept) session-fixed model and empty continuation field; [ADR 0011](0011-session-input-algebra-and-streaming.md#concept) closed input set to add `configure`; [ADR 0017](0017-durable-context-admission-budget.md#concept) runtime-only context-budget placement to allow committed per-session creation/configuration. Exact staged requests and admitted run bounds remain frozen. Also amends [ADR 0016](0016-configured-cancellation-observation.md#concept)'s exact genesis shape, preserving its mandatory committed cleanup value. Amends [ADR 0018](0018-provider-attempt-authority-and-recovery.md#concept)'s closed reply/settlement shapes and ADR 0017's estimator preimage to include a completion classification, mandatory nine-key version-2 Model-port replies and bounded private continuation, preserving attempt authority and both owning-record ceilings. Receipt revision 4 amends [ADR 0025](0025-resource-packs-and-skill-admission.md#concept) to add that charge separately while preserving ADR 0017/0025 descriptor totals and old v2/v3 equations. Also explicitly amends [ADR 0021](0021-compacted-provider-accounting-provenance.md#concept) through a new v3 settlement and its monotonic v3-only writer cutover, preserving its accounting-provenance rules and the existing v2 meaning. Qualifies ADR 0011's continuation-material exclusion solely for verified provider summary text in existing transient reasoning progress. Extends [ADR 0039](0039-ephemeral-embedded-profile.md#concept)'s closed startup options with reasoning configuration; its buffered transport and cleanup remain unchanged.
- **Requires:** acceptance of the labelled [vision continuation amendment](../vision.md#concept-vision-model-boundary) and [section 13.4](../vision-technical.md#technical-vision-model-boundary), under the [authorized scope](../developer/agent-context-map.md#disposition-m7-continuation-vision-amendment-2026-09-30)
- **Depends on:** [ADR 0041](0041-session-lineage-projection-and-context-budget.md#concept), [ADR 0042](0042-host-composed-instructions.md#concept), [ADR 0043](0043-context-compaction-checkpoint.md#concept), [ADR 0045](0045-model-originated-questions.md#concept) and [ADR 0046](0046-child-session-tool.md#concept)
- **Requires with multi-provider use:** [ADR 0048](0048-host-provider-routing-and-credential-bindings.md#concept)
- **Prerequisite for:** M7 outcomes 4 and 7
- **Coordinated wire amendment:** Replaces [ADR 0023](0023-experimental-public-session-protocol.md#concept)/[ADR 0032](0032-daemon-attachment-residency-and-replay.md#concept)'s served generations and schema-digest inputs through the M7 contract below; their authority, framing and connection-lifecycle rules remain

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
same complete native data before returning a reply. Versioned replies also
classify completion as natural, limit-stopped or unknown. Maintenance accepts
only a naturally completed reply; valid-looking truncated JSON cannot create
a checkpoint. Validated reply usage is still charged. On a mode that requires
continuation, a reply that stops at the reply limit, or with any stop other than
a tool request or a natural end, is a failed call under the existing
conservative accounting; it is never delivered as a truncated answer.

The maintainer selected verified public reasoning summaries. When the exact
provider/model mode establishes that returned text is a user-facing summary,
the adapter may project that text through existing transient reasoning progress.
Otherwise it hides the reasoning text. A reply whose reported model differs
from the response identity its registered row pins fails that call; it is not answered with the
summary merely hidden. Native blocks, signatures and redacted
data remain private. Summary text can occur in both the private continuation
and the public projection; that overlap does not make the whole block public.
This narrowly qualifies ADR 0011's exclusion of continuation material while
preserving its summary-only payload and ADR 0023's existing wire shape. No
private block is summarized locally to create public output.

Configuration becomes a durable session fact. Creation and settled-only
`configure` commit an exact model identity, reasoning, instruction envelope and
context/reply limits with one version. It also retains the host-resolved
capability and provider-mapping descriptor as bounded gating data. Core checks
its closed shape, declared limits and generic continuation, thinking-disabled and terminal-tool-history flags; adapters alone
interpret thinking modes and translate native provider controls. A configuration
records the mapping rather than consulting a mutable catalog during replay. A run captures that version at admission
and keeps it through restart. No configuration change occurs inside a run or
unresolved maintenance operation. Ephemeral `start_session/1` and one-shot
`run/2` accept explicit initial instructions, reasoning and system ceiling;
`ask/3` cannot override those startup choices. Their existing defaults and
buffered delivery remain.
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

The initial Claude verification set pairs the dated Haiku 4.5 model, with manual
thinking and a thinking-off maintenance mode, with Fable 5.1 for always-on
adaptive conversation. Haiku manual modes return verified native summary text;
explicit adaptive levels request verified summaries;
`default` preserves the provider's default display. Other combinations require
their own exact verified mapping. Manual `high` conflicts with the existing
4,096 reply default and refuses unless the operator explicitly configures a
larger permitted reply limit. M7 does not raise that default or promise every
current Claude model.

The maintainer selected ordinary availability at M7 closure. After per-cell
deterministic conformance, the tested implementation bytes register all nine
selected model/level cells for ordinary host resolution. One further row is
registered in the same bytes: provider B's thinking-off summarizer, whose exact
model is pinned before any dispatch and whose counted witness is the
cross-provider maintenance case. The nine cells' counted live
continuation, post-terminal and summary witnesses must pass before closure. The
post-terminal witness proves the provider accepts the canonical request and, on
each cell that requires continuation, that thinking resumes on the following
exchange; the two Haiku cells without thinking prove that both requests stay
without it. There is no candidate-only resolver or source registration after testing. A
failed witness blocks closure under the fixed disposition procedure. It grants
no calibration run, omitted cell or failed-case retry.
Before a new thinking exchange, leave half the complete request-record capacity
and up to 8,192 estimated input tokens available for its continuation. Earlier
eligible history may need compaction even when the first request would fit the
hard limits. Required current content that cannot leave this reserve refuses
before the first ordinary provider call, including a large first prompt in a
fresh session. A terminal run's newest completed group is eligible for ADR 0043's
bounded compaction when retaining it would prevent this preparation. Existing summary attempts, spending
and deadlines still bound preparation. The reserve does not guarantee a number
of tool rounds or make an oversized reply acceptable.
Preserve the complete rendered conversation
prefix while a thinking tool exchange is open. Compaction waits until it ends;
if the next request cannot fit, stop with a named bound failure rather than
dropping or changing required blocks. A new run starts from canonical history
and never resurrects old thinking state. If its exact mapping cannot render a
retained terminal tool turn without that private state, refuse before dispatch
with `canonical_history_rendering_unsupported`. The operator may explicitly
compact that group, even when it fits ordinary limits, or select a verified
compatible mapping; no assistant completion is invented.

Private continuation has a 16-KiB cap on both stored and expanded envelopes,
and remains within the existing
64-KiB request and settlement record limits. Durable copies use the private
store's access controls and remain with raw session history until the host
retires that history; ephemeral copies end with their runtime. Local storage
remains plaintext under the existing host protection model. M7 adds no key
service or selective deletion. Public events, snapshots, tool results,
compaction input and diagnostics exclude the private blocks. A client may
display or record the permitted summary projection as transient progress;
reopening history does not replay it as a durable answer.

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
thinks is possible, including when a mode emits no verified summary. Clients
label any permitted reasoning summary separately from answer text. Loopex does
not invent progress text or expose private blocks to fill a silent interval.

<a id="concept-adr-0044-compatibility"></a>
### Compatibility and Rollback

Technical depth: [Compatibility mechanics](0044-run-model-and-reasoning-configuration-technical.md#technical-adr-0044-compatibility).

New configuration records/events, private continuation replies/settlements and
snapshot fields require an M7 reader. Provider settlements use only v3 under
the maintainer's [pre-1.0 current-contract rule](../developer/agent-context-map.md#disposition-pre1-current-contract-2026-10-02).
The v1/v2 readers and their cross-generation cutover bookkeeping are retired;
current accounting, restart/replay and effect safety remain required. Private continuation is retained in recovery state, never
in public configuration snapshots. A Model adapter must now return every
version-2 reply member, including a nil response identity; an embedder's adapter
that omits that formerly optional member has its replies refused as unreadable
until it is updated. A model with a registered row accepts only its registered
levels; any other level, including `default`, refuses. A model with no registered row is usable at `default`
only, without private continuation; on an Anthropic route, a reply that carries
thinking blocks fails that call and is never silently stripped. After a tool run
that ends without a final assistant reply, whether by a bound, cancellation or
failure, a session on such a model refuses the next prompt with `canonical_history_rendering_unsupported`
until that group is explicitly compacted or a model whose registered mapping
supports that history is configured.
The reference default becomes the dated model identity, and its old alias
resolves to it.
The maintainer selected updated wire clients only. M7's foreground server serves
`loopex.experimental/3`; its daemon serves `loopex.experimental/4`. Both refuse
older generations through the existing unsupported-generation handshake. The
coordinated schema includes compaction, configuration, host instructions,
immutable create-time tool/defer selections, questions and the generic deadline
additions, with complete payload definitions in each digest. Bundled
clients and examples upgrade together. This changes no historical schema meaning,
readable journal history or frozen tool definition, and adds no dual service.
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
| Acceptance | Maintainer | [disposition](../developer/agent-context-map.md#disposition-m7-acceptance-2026-09-30) | candidate `2986150b878151524ecdd9bac5a9779e69e196b4`; concept `sha256:af0d0229529021f69920f5ebdaeb5a10d3dba8f351dc41d5e3ee5cc77afcf82c`; technical `sha256:8b3417a2c310e1c298c3944cecf445f9d9031f710c3151919b94e9f47114edb0` |
