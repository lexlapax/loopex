<a id="concept"></a>
## Concept

Technical depth: [Bounded context compaction checkpoints](0043-context-compaction-checkpoint-technical.md#technical-depth).

- **Status:** Proposed
- **Date:** 2026-09-30
- **Decision owner:** Maintainer
- **Supersedes:** [ADR 0010](0010-provider-continuation-and-context-staging.md#concept) raw-only projection and compaction deferral; [ADR 0011](0011-session-input-algebra-and-streaming.md#concept) closed input set to add `compact`; [ADR 0017](0017-durable-context-admission-budget.md#concept) immediate required-context failure to allow bounded maintenance first. Extends [ADR 0018](0018-provider-attempt-authority-and-recovery.md#concept) to maintenance operations, preserving its dispatch and two-attempt rules.
- **Depends on:** [ADR 0041](0041-session-lineage-projection-and-context-budget.md#concept), [ADR 0042](0042-host-composed-instructions.md#concept) and [ADR 0044](0044-run-model-and-reasoning-configuration.md#concept)
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
only while settled. Both use a bounded maintenance episode with the session's
frozen model and no tools. No executor work or pending interaction overlaps it.

Keep the current input and a recent complete tail verbatim. Summarize only whole
eligible turns, with bounded source and output. Every checkpoint must strictly
reduce both projected token count and exact record size. An oversized indivisible
turn, invalid summary, no progress or exhausted episode produces a named refusal.
Useful checkpoints already committed remain; failed work cannot roll them back.

Active maintenance consumes the run's call/turn, token and deadline budgets.
Standalone maintenance requires explicit limits and cannot exceed four attempts,
60,000 ms or 32,768 tokens. Recovery retains attempts and usage; an uncertain
provider result or checkpoint commit never authorizes another summarization.

<a id="concept-adr-0043-consequences"></a>
### Observable Consequences

Technical depth: [Evidence](0043-context-compaction-checkpoint-technical.md#technical-adr-0043-evidence).

The operator sees when compaction occurs and can inspect the summary and its
covered raw records. Long conversations can continue when bounded summaries
make room. Some detail may be omitted; raw records remain readable. There is
no promise that every conversation can fit.

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
