<a id="concept"></a>
## Concept

Technical depth: [Model-originated questions](0045-model-originated-questions-technical.md#technical-depth).

- **Status:** Proposed
- **Date:** 2026-09-30
- **Decision owner:** Maintainer
- **Supersedes:** [ADR 0024](0024-durable-interaction-lifecycle-and-host-policy-authority.md#concept) only policy-defer-only production and choice-only kind; [ADR 0009](0009-tool-executor-and-grant-contracts.md#concept) only executor dispatch for every allowed tool; [ADR 0039](0039-ephemeral-embedded-profile.md#concept) only refusal of host-answered model questions within one ephemeral call
- **Prerequisite for:** M7 outcome 5

<a id="concept-adr-0045-decision"></a>
### Context and Decision

Technical depth: [Contract](0045-model-originated-questions-technical.md#technical-adr-0045-decision).

An opt-in `loopex.ask` tool lets the model request bounded text or a choice.
Host policy decides first. An allowed interaction-class call creates a question
through the serial session owner; it issues no executor grant or job. An answer
is content and grants nothing. Later effects still consult host policy.

Durable questions survive restart with the same identity. An ephemeral host may
supply a responder for questions within one call; that state vanishes with its
runtime and cannot be resumed. Absent responder denies before question admission.
Unattended `ask` keeps its current behavior and gains no implicit terminal prompt.

Answered, declined or expired questions can produce distinct tool results while
remaining run bounds allow continuation. Run abort or deadline remains terminal.
Waiting never pauses a deadline. A failed or late responder cannot grant authority
or keep the runtime alive after cleanup.

This proposal treats an interaction tool without an executor implementation as
outside the vision's seven executor-tool implementation budget. Maintainer
acceptance must confirm that interpretation before implementation.

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
with configuration/compaction; reject unsupported clients before exposing new
shapes. Legacy effect-tool definitions keep their behavior and do not acquire
a new serialized member implicitly.

## Governance Record

| Decision | Authority | Authority evidence | Bound bytes |
| --- | --- | --- | --- |
| Acceptance | — | — | — |
