# 0043. Context compaction checkpoint

<a id="concept"></a>
## Concept

Technical depth: [Checkpoint record, trigger and evidence](0043-context-compaction-checkpoint-technical.md#technical-depth).

- **Status:** Proposed
- **Date:** 2026-09-29
- **Decision owner:** Maintainer
- **Supersedes:** [ADR 0010](0010-provider-continuation-and-context-staging.md#concept)
  only in its clause that compaction stays out of scope, which it left to
  "the milestone whose long-lived sessions produce the measured token curve"
- **Depends on:** [ADR 0041](0041-session-lineage-projection-and-context-budget.md#concept)
- **Prerequisite for:** M7 outcome 3 (draft), accepted before any checkpoint
  record is written

<a id="concept-adr-0043-decision"></a>
### Context and Decision

Technical depth: [Record and trigger](0043-context-compaction-checkpoint-technical.md#technical-adr-0043-decision).

Once a session carries its history, its requests grow until they no longer
fit. Without a remedy the session stops being usable: the next prompt is
refused, or a long run fails when its own tool output fills the budget.

The vision specifies the remedy. A compaction checkpoint summarizes a range
of history. The projection may substitute the checkpoint for that range. Raw
records remain in durable history, and a summary cannot alter receipts,
outcomes, authority or facts.

**The decision.**

1. **Compaction is a session command.** `compact` is admitted while the
   session is settled. It commits a checkpoint through the serial session
   owner, like any other durable fact.
2. **The session's own model writes the summary.** Compaction is one model
   call with no tools. It uses the run model and the provider path of the
   session. There is no second model role.
3. **Compaction runs between runs by default.** When a prompt or follow-up
   would be refused for context, the reference host compacts first and then
   admits it. The operator sees that compaction happened.
4. **A run may compact once it is at risk.** When the next request of a run
   in flight would exceed the budget, the run compacts the history before
   its current turn boundary and continues. This replaces today's
   `failed(context_budget_exceeded)` when compaction can make room.
5. **Recent history is kept verbatim.** The checkpoint covers the oldest
   records. A recent tail, sized by a host value, projects unchanged.
6. **The summary has a fixed outline:** goal, constraints, progress,
   decisions, next steps and critical context. The compaction instructions
   are host content under
   [ADR 0042](0042-host-composed-instructions.md#concept), with a reference
   default.
7. **A checkpoint is provenance-typed.** The model sees the summary marked
   as a summary of earlier conversation, never as something it or the
   operator said.
8. **Failure leaves the session as it was.** A failed or interrupted
   compaction commits no checkpoint, and the prior projection stands.

<a id="concept-adr-0043-consequences"></a>
### Observable Consequences

Technical depth: [Evidence](0043-context-compaction-checkpoint-technical.md#technical-adr-0043-evidence).

A long session keeps working. The operator is told when history was
summarized and can compact on request. The model may lose detail that the
summary omitted; the full records remain readable by the operator. Each
compaction costs one model call, which is charged and recorded.

<a id="concept-adr-0043-compatibility"></a>
### Compatibility and Rollback

Technical depth: [Compatibility and rejected alternatives](0043-context-compaction-checkpoint-technical.md#technical-adr-0043-compatibility).

The checkpoint is a new record kind and a new public event. A root without a
checkpoint is unchanged. A binary that predates the record refuses a root
that carries one. Abandoned-branch summarization stays out of scope, as the
vision keeps it a separate operation.

## Governance Record

| Decision | Authority | Authority evidence | Bound bytes |
| --- | --- | --- | --- |
| Acceptance | — | — | — |
