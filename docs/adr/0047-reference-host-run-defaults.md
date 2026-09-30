<a id="concept"></a>
## Concept

Technical depth: [Explicit conversational run limits](0047-reference-host-run-defaults-technical.md#technical-depth).

- **Status:** Proposed
- **Date:** 2026-09-30
- **Decision owner:** Maintainer
- **Supersedes:** nothing
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

Every effective limit is visible before a run. There is no unbounded mode.
An operator may explicitly configure other supported positive values. Changing
the documented baseline requires retained task measurements and maintainer
disposition. Helper spending is separately declared under ADR 0046.

<a id="concept-adr-0047-consequences"></a>
### Observable Consequences

Technical depth: [Evidence](0047-reference-host-run-defaults-technical.md#technical-adr-0047-evidence).

A file omission cannot silently authorize a large conversation. The operator
sees turns, deadline, run token threshold and reply limit before submitting work.
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
| Acceptance | — | — | — |
