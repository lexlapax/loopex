<a id="concept"></a>
## Concept

Technical depth: [Explicit conversational run limits](0047-reference-host-run-defaults-technical.md#technical-depth).

- **Status:** Accepted
- **Date:** 2026-09-30
- **Decision owner:** Maintainer
- **Supersedes:** nothing
- **Depends on:** [ADR 0044](0044-run-model-and-reasoning-configuration.md#concept) for committed session configuration and [ADR 0049](0049-explicit-host-configuration.md#concept) for effective inspection and startup reporting
- **Prerequisite for:** M7 outcomes 6 and 8

<a id="concept-adr-0047-decision"></a>
### Context and Decision

Technical depth: [Contract](0047-reference-host-run-defaults-technical.md#technical-adr-0047-decision).

Conversational work must declare its spending and lifetime bounds. The
maintainer selected the current baseline plus mandatory configuration, not the
earlier proposed larger defaults.

The selected configuration file must contain `max_turns`, `deadline_ms` and
`token_budget` for conversational runs. Missing values refuse before startup;
flags may override valid file values but cannot supply missing declarations.
Document 16 turns, 600,000 ms and 1,000,000 tokens as starting values an operator
can select. Retain the 4,096 reply-token default. Core, reusable composition and
one-shot `ask` keep their existing defaults.

Every effective limit is inspectable. Chat attempts ADR 0049's best-effort
startup report; a stalled diagnostic reader does not block work. There is no
unbounded mode.
An operator may explicitly configure other supported positive values. Changing
the documented baseline requires retained task measurements and maintainer
disposition. Helper spending is separately declared under ADR 0046.

<a id="concept-adr-0047-consequences"></a>
### Observable Consequences

Technical depth: [Evidence](0047-reference-host-run-defaults-technical.md#technical-adr-0047-evidence).

A file omission cannot silently authorize a large conversation. The operator
can inspect turns, deadline, run token threshold and reply limit. Chat's startup
report is best-effort, so delivery before submitting work is not guaranteed.
Waiting for an answer and compaction consume their applicable deadlines and
budgets. A token threshold is checked between calls and may be exceeded by the
last completed provider call; it is not an exact invoice cap.

<a id="concept-adr-0047-compatibility"></a>
### Compatibility and Rollback

Technical depth: [Compatibility mechanics](0047-reference-host-run-defaults-technical.md#technical-adr-0047-compatibility).

Committed run limits survive restart. New file defaults affect new runs only;
they do not change an in-flight run. This decision changes no core accounting
or one-shot defaults. Reverting host recommendations cannot undo consumed usage.

## Governance Record

| Decision | Authority | Authority evidence | Bound bytes |
| --- | --- | --- | --- |
| Acceptance | Maintainer | [disposition](../developer/agent-context-map.md#disposition-m7-acceptance-2026-09-30) | candidate `2986150b878151524ecdd9bac5a9779e69e196b4`; concept `sha256:4640a5289968c68bbc3389a1c131404484e0b9ec2a1eec4e08707a15a27860bb`; technical `sha256:d48a97c9cbed63e880252560c781bb3f49040c811f0a7a6b41a77daefb235c21` |
