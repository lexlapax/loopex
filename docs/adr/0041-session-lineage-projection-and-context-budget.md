# 0041. Session lineage projection and context budget

<a id="concept"></a>
## Concept

Technical depth: [Projection order, admission and evidence](0041-session-lineage-projection-and-context-budget-technical.md#technical-depth).

- **Status:** Proposed
- **Date:** 2026-09-29
- **Decision owner:** Maintainer
- **Supersedes:** nothing. It implements the lineage clause of
  [ADR 0010](0010-provider-continuation-and-context-staging.md#concept) and
  applies [ADR 0017](0017-durable-context-admission-budget.md#concept)
  unchanged
- **Prerequisite for:** M7 outcome 1 (draft), accepted before the projection
  changes

<a id="concept-adr-0041-decision"></a>
### Context and Decision

Technical depth: [Projection and admission](0041-session-lineage-projection-and-context-budget-technical.md#technical-adr-0041-decision).

ADR 0010 decides that a prompt to a settled session starts a new run with "a
projection over the whole retained lineage". The implementation does
something narrower. Each run's conversation starts with its own prompt alone,
and staging reads only the current run's elements. No test covers a second
prompt. An operator who asks a follow-up question therefore talks to a model
that has never seen the first answer.

Closing that gap meets a second fact. The context budget defaults to 8,192
estimated tokens, and a request over it ends the run as
`failed(context_budget_exceeded)`. A session that carries its history reaches
that ceiling within a few runs.

**The decision.**

1. **A new run projects the session's retained lineage.** The staged request
   for a prompt or a promoted follow-up carries every prior run's prompt,
   assistant messages and tool results in committed order, then the new
   prompt. This is ADR 0010's decision, now implemented.
2. **A run's accounting stays its own.** Turn count, token budget and
   deadline start fresh for each run, as ADR 0010 already fixes. Prior runs
   cost context, not budget.
3. **Every terminal outcome stays in the lineage.** A run that failed, was
   cancelled or reached a bound still happened. Its committed elements
   project, and an unanswered tool call projects with its committed terminal
   result.
4. **ADR 0017 applies unchanged.** The whole projected request is measured
   against the context budget. A prompt whose projection cannot fit is
   refused at admission with the existing context dimension, before any
   provider call.
5. **The default context budget becomes a host decision sized to the model.**
   The reference host raises its default from 8,192 to a value derived from
   the selected model's declared context window, less a reserve for the
   reply. The runtime keeps no default, as today.
6. **Refusal names the remedy.** A lineage refusal tells the operator that
   compaction, decided in
   [ADR 0043](0043-context-compaction-checkpoint.md#concept), makes room.

<a id="concept-adr-0041-consequences"></a>
### Observable Consequences

Technical depth: [Evidence](0041-session-lineage-projection-and-context-budget-technical.md#technical-adr-0041-evidence).

A second prompt can refer to the first. Requests grow with the session, so
each later run costs more input tokens. A long session is refused at
admission, not failed mid-run, once its history no longer fits. The
ephemeral profile is unaffected while one call is one run.

<a id="concept-adr-0041-compatibility"></a>
### Compatibility and Rollback

Technical depth: [Compatibility and rejected alternatives](0041-session-lineage-projection-and-context-budget-technical.md#technical-adr-0041-compatibility).

No record shape changes. The projection is derived from records that already
exist, so a root written before this decision projects its full history under
it. The staged request bytes change, and the staged request digest shows it.
Rolling back the binary restores the per-run projection with no data change.

## Governance Record

| Decision | Authority | Authority evidence | Bound bytes |
| --- | --- | --- | --- |
| Acceptance | — | — | — |
