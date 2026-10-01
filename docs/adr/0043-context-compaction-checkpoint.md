<a id="concept"></a>
## Concept

Technical depth: [Bounded context compaction checkpoints](0043-context-compaction-checkpoint-technical.md#technical-depth).

- **Status:** Proposed
- **Date:** 2026-09-30
- **Decision owner:** Maintainer
- **Supersedes:** [ADR 0010](0010-provider-continuation-and-context-staging.md#concept) raw-only projection and compaction deferral; [ADR 0011](0011-session-input-algebra-and-streaming.md#concept) closed input set to add `compact`; [ADR 0017](0017-durable-context-admission-budget.md#concept) immediate required-context failure and closed refusal/failure shapes to allow bounded maintenance first and versioned preparation failures and its closed receipt source-reference union for maintenance and checkpoint provenance. Extends [ADR 0018](0018-provider-attempt-authority-and-recovery.md#concept) to maintenance operations, preserving its dispatch and two-attempt rules. Also amends ADR 0011's exhaustive admission/abort rules for standalone maintenance and adds discoverable completion. Extends [ADR 0013](0013-run-deadline-commitment-at-first-request-staging.md#concept) so the first run-owned maintenance request may commit the run deadline before an ordinary request. Also amends ADR 0010's turn-bound check so each summary dispatch spends one turn unit, and the exact row count of ADR 0017's deadline-staging and ADR 0018's settlement-terminal transactions by one leading episode-terminal row for a run-owned episode, admitting the `maintenance` stage in the deadline-staging validator.
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
history would exceed a token or record-byte limit, or would leave insufficient
space for a new thinking exchange under ADR 0044. That preparation continues
until the initial reserve fits, even if a smaller reduction already fits the
hard limits. It does not change prompt
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
recovery uses them even if the host's new startup configuration differs. A
missing captured route or renderer, when recovery must dispatch, makes the
session unavailable without mutation; restoring it and restarting resumes the
same episode. A summary already settled needs no route and still finishes its
checkpoint, unless an abort, an elapsed deadline or a failed progress check
prevents it.
Direct core startup accepts a well-formed summarizer map that lacks a required
thinking-off setting; each new episode then refuses before any provider call.
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

Keep the current input verbatim and prefer a recent complete tail for automatic
size preparation. A short unit in front of one too large to join it is
summarized together with that unit from marked excerpts, so a small leading
exchange cannot block progress. A lone short unit in front of the protected
tail can still fail to shrink; explicit compact is the remedy. Explicit compact releases eligible terminal-run tail units;
failed/cancelled input-only units follow the same oldest-first release rule. Each checkpoint
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

Source and output remain bounded. A completed group from a terminal run may be summarized even when it is the
newest group, if retaining it would block the next request by size or unsupported canonical
tool-history rendering. Explicit compact can also cover it to prepare for a
smaller model. Current-run inputs, the groups that follow them in the same run,
and open exchanges remain protected, so compaction during a run covers only
history from before that run. Failure projections are versioned and name
either the measured ordinary/maintenance bound or the precise preparation failure; old records keep
their old validation. Size preparation must strictly reduce both projected
token count and exact record size. Explicit repair of unsupported terminal
rendering instead advances coverage past offending groups within hard limits
until rendering passes; a small group may become a larger summary. Insufficient room for the minimum
excerpt, invalid or incompletely generated summary, no progress or exhausted episode produces a named
refusal. An abort committed, or a deadline elapsed, while a settled summary still
awaits its checkpoint commit wins: no checkpoint is committed and the summary
remains evidence only. Progress and applicable hard limits are checked on the pending summary before
checkpoint commitment; a failed check cannot make an unusable summary durable.
Useful checkpoints already committed remain; failed work cannot roll them back.

Active maintenance consumes the run's call/turn, token and deadline budgets.
In a helper session, that usage is part of the child's total and therefore its
delegation charge. Maintenance in the delegating parent spends only that parent's
run budget, not the separate helper allowance.
Run-owned source preparation before each episode's first maintenance request
also has its own fixed 60-second cutoff, independent of the run's declared
deadline; its expiry ends the run with a named preparation failure, not a
fabricated bound. Preparation for that episode's later prefixes is bounded only
by the run deadline. If a maintenance request is the run's first request and the
run deadline cannot be represented there, the run ends with its existing
deadline-staging failure.
Standalone maintenance has a closed completion result, including truthful
cleanup and partial-checkpoint identity after failure. Abort cancels an active
standalone episode without inventing a run. While it is active, every other new
command is refused as `maintenance_active`; nothing queues behind it. An
ordinary explicit compact, of history that already fits and renders, makes at
most one checkpoint and stops; a later command may cover more. When settled
history exceeds a hard limit, the same command keeps summarizing until it fits
or its declared limits end it; if that history then still cannot be rendered,
the command ends with the named rendering refusal,
`canonical_history_rendering_unsupported`, and a later command repairs it. When
settled history fits but cannot be rendered, the same command keeps summarizing
until it renders or its declared limits end it.
Standalone maintenance requires explicit limits and cannot exceed four attempts,
60,000 ms or 32,768 tokens. The reference `/compact` submits exactly those
maximum limits and displays them before submission. Recovery retains attempts and usage; an uncertain
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

Wire compaction joins ADR 0044's coordinated new-generation-only contract.
Operators update clients with the server; old negotiation refuses before session work.

Checkpoints, maintenance state and usage are new durable records, with two new
public events (checkpoint committed, standalone completion), a new progress kind
and new snapshot members for the checkpoint, active maintenance and the last
standalone result. An unsupported reader must refuse before
mutation where its decoder supports that guarantee; exact old-reader fixtures
establish actual behavior. Rollback uses a retained pre-upgrade backup with its
matching binary, not removal of checkpoint records.

## Governance Record

| Decision | Authority | Authority evidence | Bound bytes |
| --- | --- | --- | --- |
| Acceptance | — | — | — |
