<a id="concept"></a>
## Concept

Technical depth: [Serial read-only child sessions](0046-child-session-tool-technical.md#technical-depth).

- **Status:** Proposed
- **Date:** 2026-09-30
- **Decision owner:** Maintainer
- **Supersedes:** [ADR 0013](0013-run-deadline-commitment-at-first-request-staging.md#concept) relative-only, first-staging deadline for an explicitly supplied absolute ceiling; [ADR 0011](0011-session-input-algebra-and-streaming.md#concept) and [ADR 0017](0017-durable-context-admission-budget.md#concept) closed prompt/follow-up bounds for that optional field and their normalized command identity for newly authored bounds, preserving historical digests and ordinary follow-up inheritance; [ADR 0024](0024-durable-interaction-lifecycle-and-host-policy-authority.md#concept) unconditional defer admission for a host-selected immutable refusal mode. Extends [ADR 0009](0009-tool-executor-and-grant-contracts.md#concept) with explicit per-create tool selection, preserving its session-local mapping and append-only registry. ADR 0044 owns the shared genesis amendment. Extends [ADR 0008](0008-owner-succession-recovery-and-runtime-placement.md#concept) with runtime-private read-only effect-intent/terminal and creation-provenance queries, including a Store read callback, without granting activation or mutation authority. Also adds a shared pure genesis resolver and a host-private live create variant accepting its validated complete payload; helper recovery cannot invoke that variant. Amends [ADR 0016](0016-configured-cancellation-observation.md#concept) to permit exact retained v2/v3 genesis in historical lookup and the live exact-genesis create variant; committed cleanup values and observation bounds remain unchanged.
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
explicit limits. The host freezes the role catalog and complete delegation declaration
at parent-session creation. Each new parent run starts a separate allowance from
that declaration; resume never substitutes edited file limits or resets a run.
Each role supplies exact instructions, provider/model and reasoning. The child
receives the task and those instructions, with fresh context. It never inherits
the parent's conversation or reads a changed role file during recovery.

Only one child operation is active per parent conversation (session), including
unfinished cleanup from an earlier run. Independent parent sessions may run
helpers concurrently; there is no runtime-wide helper slot or queue.
Children cannot delegate or
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
Clients may inspect child evidence but cannot independently mutate a helper,
including abort, reconfiguration, compaction or further work. Cancel its owning
parent operation to stop it; when that owner is unavailable, use host restart
and stop-only recovery. Its owning operation controls mutation and cleanup,
including after settlement. Child cleanup can finish after the parent's
observation window; the parent then remains unknown even after a clean child stop.

The router classifies every forwarded local or helper job. Cancelling a known
local job leaves helper admission open. Its bounded active-job registry reclaims
capacity as jobs settle; ordinary sequential work cannot exhaust a lifetime
registration quota. A cancel without classification fences that exact job ID
against delayed launch and reports uncertainty. Only exhaustion of the separate
bounded cancellation-tombstone table closes helper admission across the host
until full restart. Durable helper bindings route historical receipts after
active rows leave the registry.
An unresolved host-ledger commit separately fences that adapter's mutations,
including settlement for other parent sessions, until recovery resolves it.
These limits do not change local request or receipt bytes.

Read-only core queries supply committed effect intents and creation provenance
without starting a session. The host uses them to distinguish a crash before
child creation from missing evidence for an existing child. Proven absence may
close an interrupted operation without dispatch; it never resets an uncertain
reservation's count or authorizes a replacement child.

New command identities bind the caller's explicit limits, so reusing an ID
with different limits refuses. Repeating the original command keeps its first
result even if host defaults changed. Historical command identities retain
their original meaning. A queued follow-up may add an absolute cutoff, while
its ordinary limits still inherit from the active run.

This proposal depends on acceptance of the narrow M7 amendment to both vision
files. It explicitly permits this opt-in host helper while retaining the bans
on a core scheduler, parallel children within one parent session and writable helpers.

A committed refusal before child work starts consumes no delegation allowance
and requires no ledger reservation. Restart joins that terminal fact to the
intent; it cannot treat the refused call as lost work or fence its parent. A
call whose refusal was not yet recorded when the host stopped is charged
conservatively; if that exceeds the allowance, the parent keeps working without
further helpers and the call stays unknown.

Every durable host start classifies retained helper history before it admits
work, even when new delegation is disabled, so an old
helper is never adopted as ordinary work. That scan has a fixed 60-second bound
per start and keeps its progress: a long history finishes over later starts, or
in the background of a resident host. Two cases finish only under a resident
host: a root whose listing alone exceeds one bound, and a session with more
records than one start can read behind a call whose outcome the scan has not yet
reached. Until the scan finishes the durable host admits no
session work and reports a count of what remains; reading existing sessions and
the ephemeral profile, which has no helpers, stay available. One unreadable
session history keeps the durable host closed until the root is restored from
backup. A parent whose retained
calls exceed its allowance keeps working but can start no further helper.

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

The generic deadline addition joins ADR 0044's coordinated new-generation-only
wire contract. Updated clients retain the existing foreground and daemon
authority rules; old negotiation refuses before session work.

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
