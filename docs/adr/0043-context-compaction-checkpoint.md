<a id="concept"></a>
## Concept

Technical depth: [Bounded context compaction checkpoints](0043-context-compaction-checkpoint-technical.md#technical-depth).

- **Status:** Proposed
- **Date:** 2026-09-30
- **Decision owner:** Maintainer
- **Supersedes:** [ADR 0010](0010-provider-continuation-and-context-staging.md#concept) raw-only projection and compaction deferral; [ADR 0011](0011-session-input-algebra-and-streaming.md#concept) closed input set to add `compact`; [ADR 0017](0017-durable-context-admission-budget.md#concept) immediate required-context failure to allow bounded maintenance first and its closed receipt source-reference union for maintenance and checkpoint provenance. Extends [ADR 0018](0018-provider-attempt-authority-and-recovery.md#concept) to maintenance operations, preserving its dispatch and two-attempt rules.
- **Depends on:** [ADR 0041](0041-session-lineage-projection-and-context-budget.md#concept), [ADR 0042](0042-host-composed-instructions.md#concept), [ADR 0044](0044-run-model-and-reasoning-configuration.md#concept) and [ADR 0048](0048-host-provider-routing-and-credential-bindings.md#concept)
- **Also extends:** [ADR 0039](0039-ephemeral-embedded-profile.md#concept)'s closed startup options with explicit maintenance instructions and model selection; its one-shot interface, credential audience and cleanup guarantees remain unchanged
- **Maintenance resource receipts:** Narrowly amends [ADR 0017](0017-durable-context-admission-budget.md#concept) and [ADR 0025](0025-resource-packs-and-skill-admission.md#concept) so a successful maintenance request can explicitly record that optional resource intake was skipped; ordinary admission and older receipt validation remain unchanged
- **Prerequisite for:** M7 outcome 3

<a id="concept-adr-0043-decision"></a>
### Context and Decision

Technical depth: [Contract](0043-context-compaction-checkpoint-technical.md#technical-adr-0043-decision).

Compaction substitutes a model-written summary for an old contiguous range of
conversation while retaining all raw facts. It never changes receipts, authority,
outcomes or tool evidence. The session owner commits each checkpoint before it
publishes or stages against it.

Automatic compaction runs at initial or later model staging when eligible
history would exceed a token or record-byte limit. It does not change prompt
admission or require a host to resubmit a command. Explicit `compact` is admitted
only while settled. Both use a bounded maintenance episode with an explicitly
configured summarizer and no tools. Its model may equal the conversation model
or use a different admitted provider. This allows an always-on thinking model
to remain the conversation model while summaries use verified thinking-off
settings. There is no automatic model choice or fallback. This is a maintenance
call under the session owner, not a helper session or scheduler.
The host supplies a versioned compaction instruction
block describing the summary's goal, constraints, progress, decisions, next
steps and critical context as an explicit runtime option. Each episode captures
that block and the resolved summarizer configuration before work begins;
recovery uses them even if the host's new startup configuration differs.
Missing model or instructions permit ordinary work but refuse new maintenance
before any provider call; invalid supplied configuration refuses host startup. Core
does not substitute the ordinary session instructions. The six sections guide
the summary text; they are not six separate output fields.
Maintenance uses an explicitly recorded, verified
thinking-off setting so its fixed reply reserve remains valid. Unsupported
maintenance settings refuse before dispatch. No executor work or pending
interaction overlaps it. ADR 0044's open thinking exchange also blocks
compaction: its complete earlier prefix must remain unchanged. If that exchange
cannot fit, stop truthfully; a later run can compact canonical history.

Keep the current input and a recent complete tail verbatim. Each checkpoint
covers whole eligible groups, including settled input-only runs. Prefer complete
source. When the oldest eligible group is too large, give the summarizer marked
excerpts from its beginning and end, retaining the complete original. This also
covers large user prompts, generated tool arguments and group metadata. The
checkpoint and subsequent summaries disclose that source was omitted; coverage
of a raw range does not mean the summarizer saw every byte. This exception applies
only to maintenance input, not ordinary tool results or private thinking data.
Versioned receipts bind the maintenance source and later summary to their owning
records. Their committed provenance grants no authority over future effects.
Maintenance admits no fresh project resources; its receipt explicitly records
that omission rather than claiming an ordinary resource-admission pass.

Source and output remain bounded. Every checkpoint must strictly reduce both
projected token count and exact record size. Insufficient room for the minimum
excerpt, invalid summary, no progress or exhausted episode produces a named
refusal. Useful checkpoints already committed remain; failed work cannot roll
them back.

Active maintenance consumes the run's call/turn, token and deadline budgets.
Standalone maintenance requires explicit limits and cannot exceed four attempts,
60,000 ms or 32,768 tokens. Recovery retains attempts and usage; an uncertain
provider result or checkpoint commit never authorizes another summarization.

<a id="concept-adr-0043-consequences"></a>
### Observable Consequences

Technical depth: [Evidence](0043-context-compaction-checkpoint-technical.md#technical-adr-0043-evidence).

The operator sees the selected summarizer and its usage, when compaction occurs,
whether maintenance used excerpts,
and can inspect the summary and its covered raw records. Long conversations
can continue when bounded summaries make room. Details outside the excerpts
are unavailable to the summarizer; even complete source can lose detail in a
summary. Raw records remain readable through existing host inspection. There
is no promise that every conversation can fit.

<a id="concept-adr-0043-compatibility"></a>
### Compatibility and Rollback

Technical depth: [Compatibility mechanics](0043-context-compaction-checkpoint-technical.md#technical-adr-0043-compatibility).

Checkpoints, maintenance state and usage are new durable records, with a new
public event and progress kind. An unsupported reader must refuse before
mutation where its decoder supports that guarantee; exact old-reader fixtures
establish actual behavior. Rollback uses a retained pre-upgrade backup with its
matching binary, not removal of checkpoint records.

## Governance Record

| Decision | Authority | Authority evidence | Bound bytes |
| --- | --- | --- | --- |
| Acceptance | — | — | — |
