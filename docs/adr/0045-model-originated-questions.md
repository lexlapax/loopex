<a id="concept"></a>
## Concept

Technical depth: [Model-originated questions](0045-model-originated-questions-technical.md#technical-depth).

- **Status:** Proposed
- **Date:** 2026-09-30
- **Decision owner:** Maintainer
- **Supersedes:** [ADR 0024](0024-durable-interaction-lifecycle-and-host-policy-authority.md#concept) only policy-defer-only production and choice-only kind; [ADR 0009](0009-tool-executor-and-grant-contracts.md#concept) only executor dispatch for every allowed tool and its definition record, adding a versioned `class` member and an interaction-only zero artifact budget; [ADR 0039](0039-ephemeral-embedded-profile.md#concept) only refusal of host-answered model questions within one ephemeral call and its closed startup-option set for explicit question activation
- **Depends on:** [ADR 0044](0044-run-model-and-reasoning-configuration.md#concept) for the coordinated ephemeral option and wire unions
- **Prerequisite for:** M7 outcomes 5 and 6

<a id="concept-adr-0045-decision"></a>
### Context and Decision

Technical depth: [Contract](0045-model-originated-questions-technical.md#technical-adr-0045-decision).

An opt-in `loopex.ask` tool lets the model request bounded text or a choice.
Host policy decides first. An allowed interaction-class call creates a question
through the serial session owner; it issues no executor grant or job. An answer
is content and grants nothing. Later effects still consult host policy.

Durable questions survive restart with the same identity. The existing
ephemeral session API accepts host answers during its live session. The one-shot
`run/2` wrapper may additionally supply a responder within that call. Ephemeral
state vanishes with its runtime and cannot recover after process loss. In the
one-shot wrapper only, absent responder denies before model-question admission.
Unattended `ask` keeps its current behavior and gains no implicit terminal prompt.
Ephemeral startup and `run/2` require explicit `questions: true`; its default
is false, preserving existing tool sets. A live host supplies answers through
`answer/3`; an enabled one-shot wrapper uses its bounded responder. Expiry or
abort can terminate that host callback during its work. The host owns any
callback effects and must not recursively create sessions to answer a question.

Answered, declined or expired questions can produce distinct tool results while
remaining run bounds allow continuation. Run abort or deadline remains terminal.
Waiting never pauses a deadline. A failed or late responder cannot grant authority
or keep the runtime alive after cleanup.
Ordinary model continuation receives the exact bounded answer or disposition.
Later compaction may include it in marked source excerpts under ADR 0043;
the original answer remains readable and never becomes an authority grant.

This proposal depends on acceptance of the narrow M7 amendment to both vision
files. The question tool is an explicit addition to the seven workspace tools,
not an exemption inferred from its dispatch location.

<a id="concept-adr-0045-consequences"></a>
### Observable Consequences

Technical depth: [Evidence](0045-model-originated-questions-technical.md#technical-adr-0045-evidence).

The operator sees the model's question and can answer or decline. Durable clients
can reconnect to the same pending question. Ephemeral applications handle one
bounded callback per pending question within the call. Unknown, duplicate or late replies cannot
change a settled answer.

<a id="concept-adr-0045-compatibility"></a>
### Compatibility and Rollback

Technical depth: [Compatibility mechanics](0045-model-originated-questions-technical.md#technical-adr-0045-compatibility).

The interaction class, text kind, producer/disposition fields and snapshots
change the experimental protocol schema. Negotiate a new generation jointly
with configuration/compaction and ADR 0046's absolute deadline. ADR 0044's
selected new-generation-only policy requires updated clients and refuses old
negotiation before exposing new shapes. Legacy effect-tool definitions keep their behavior and do not acquire
a new serialized member implicitly.

## Governance Record

| Decision | Authority | Authority evidence | Bound bytes |
| --- | --- | --- | --- |
| Acceptance | — | — | — |
