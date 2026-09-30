<a id="concept"></a>
## Concept

Technical depth: [Serial read-only child sessions](0046-child-session-tool-technical.md#technical-depth).

- **Status:** Proposed
- **Date:** 2026-09-30
- **Decision owner:** Maintainer
- **Supersedes:** [ADR 0013](0013-run-deadline-commitment-at-first-request-staging.md#concept) relative-only, first-staging deadline for an explicitly supplied absolute ceiling; [ADR 0011](0011-session-input-algebra-and-streaming.md#concept) and [ADR 0017](0017-durable-context-admission-budget.md#concept) closed prompt/follow-up bounds for that optional field; [ADR 0024](0024-durable-interaction-lifecycle-and-host-policy-authority.md#concept) unconditional defer admission for a host-selected immutable refusal mode. Extends [ADR 0009](0009-tool-executor-and-grant-contracts.md#concept) with explicit per-create tool selection, preserving its session-local mapping and append-only registry. ADR 0044 owns the shared genesis amendment.
- **Depends on:** [ADR 0041](0041-session-lineage-projection-and-context-budget.md#concept), [ADR 0042](0042-host-composed-instructions.md#concept), [ADR 0044](0044-run-model-and-reasoning-configuration.md#concept), [ADR 0048](0048-host-provider-routing-and-credential-bindings.md#concept) and [ADR 0049](0049-explicit-host-configuration.md#concept)
- **Prerequisite for:** M7 outcome 7

<a id="concept-adr-0046-decision"></a>
### Context and Decision

Technical depth: [Contract](0046-child-session-tool-technical.md#technical-adr-0046-decision).

A helper can investigate a repository or review code without filling the
parent's context. M7 provides an opt-in host executor adapter over ordinary
sessions. Core gains no parent field, role type, delegation counter or scheduler. It gains
explicit immutable per-session tool selection and policy-defer handling at
creation, shared session mechanics that ordinary embedded hosts can also use.

The parent may automatically choose a host-enabled role within policy and
explicit limits. The host freezes the role catalog at parent-session creation.
Each role supplies exact instructions, provider/model and reasoning. The child
receives the task and those instructions, with fresh context. It never inherits
the parent's conversation or reads a changed role file during recovery.

Only one child operation is active per parent run. Children cannot delegate or
ask questions. Their fixed tools are read, grep, find and ls. M7 admits no
widening to write, edit or bash. Parent and child use the same underlying host policy and
workspace. The child selects an immutable mode that preserves allow/deny and
turns policy defer into `interaction_unsupported`, without opening a question; unrelated sessions can still modify that workspace. This is a tool
restriction, not OS isolation or workspace exclusivity.

The host keeps a durable private ledger for role snapshots, operation identity,
child evidence and a separate per-parent-run delegation allowance. Reservation
precedes child creation. Parent and delegation counters stay distinct; their
combined reported usage is visible. Token thresholds stop subsequent work and
are not hard provider billing ceilings. An uncertain usage result cannot release
reserved budget. Child count also bounds repeated low-token calls.

A generic committed absolute-deadline ceiling, available to any bounded run,
enforces the child cutoff no later than its parent job's cutoff. Core gains
this bound but no child-specific mechanism. Parent cancellation aborts the child and waits for truthful cleanup
within the existing grace; uncertainty remains unknown. Stable logical identities
prevent duplicate live create/prompt admission. After the helper manager
crashes, recovery is stop-only for unfinished operations. Recover completed
results; abort unfinished children without replaying their create/prompt or
activating recovered work. Some interrupted tasks therefore need a new request.
This is the maintainer's selected recovery boundary. A still-live child may
continue until abort is admitted; no instantaneous stop is promised at the
parent's earlier abort commit. Only confirmed cleanup permits a cleaned result.
Cancellation before a job can be identified closes new helper admission for
that host instance and reports uncertainty. A host restart restores admission
through normal fencing and recovery; ordinary local-tool behavior stays intact.

This proposal depends on acceptance of the narrow M7 amendment to both vision
files. It explicitly permits this opt-in host helper while retaining the bans
on a core scheduler, parallel children within one parent run and writable helpers.

<a id="concept-adr-0046-consequences"></a>
### Observable Consequences

Technical depth: [Evidence](0046-child-session-tool-technical.md#technical-adr-0046-evidence).

The operator can inspect the role, task, provider/model, child identity,
terminal outcome and usage. A result returns bounded text plus that evidence.
No additional approval is mandatory for an already allowed delegation. Unknown
roles, exhausted allowances and unavailable recovery evidence refuse safely.

<a id="concept-adr-0046-compatibility"></a>
### Compatibility and Rollback

Technical depth: [Compatibility mechanics](0046-child-session-tool-technical.md#technical-adr-0046-compatibility).

The ledger is new host-owned persistent state and has its own versioned reader
and backup procedure. Core child sessions remain ordinary sessions. Removing
the adapter does not make an unresolved delegated operation safe to repeat.
M7 readers refuse unsupported host state before dispatch. Exact M6 fixtures
determine older-reader behavior; a new host directory cannot fence an old
binary that ignores it. The supported rollback prevents that binary from
opening the upgraded root and restores its matching pre-upgrade backup. Ephemeral
embedding does not offer helpers in M7.

## Governance Record

| Decision | Authority | Authority evidence | Bound bytes |
| --- | --- | --- | --- |
| Acceptance | — | — | — |
