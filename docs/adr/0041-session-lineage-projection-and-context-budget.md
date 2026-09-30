<a id="concept"></a>
## Concept

Technical depth: [Session lineage projection and context budget](0041-session-lineage-projection-and-context-budget-technical.md#technical-depth).

- **Status:** Proposed
- **Date:** 2026-09-30
- **Decision owner:** Maintainer
- **Supersedes:** nothing; implements [ADR 0010](0010-provider-continuation-and-context-staging.md#concept)'s retained-lineage clause and preserves [ADR 0017](0017-durable-context-admission-budget.md#concept)'s admission semantics
- **Prerequisite for:** M7 outcome 1

<a id="concept-adr-0041-decision"></a>
### Context and Decision

Technical depth: [Contract](0041-session-lineage-projection-and-context-budget-technical.md#technical-adr-0041-decision).

A new prompt or promoted follow-up sees the session's retained conversation,
not only its own run. Prior prompts, assistant messages, committed tool results
and terminal facts project in committed order. Cancelled, failed and bound-reached
runs remain part of that history. Each new run still has its own accounting.

Command admission remains unchanged. At initial and subsequent model staging,
core measures the whole projected request against token, record-byte, depth and
cardinality limits. Optional context retains ADR 0017's withholding behavior.
Eligible history can compact under ADR 0043 before dispatch; if required context
still cannot fit, retain the existing named staging failure. Do not silently
truncate history or invent missing terminal results.

The host derives the input token budget from the selected model window less
the reply reserve, or uses an explicit bounded override. An unknown window uses
the documented 8,192-token fallback. The exact normalized model-request record
still cannot exceed 65,536 bytes, regardless of the model's advertised window.
No artifact-backed request storage enters M7.

<a id="concept-adr-0041-consequences"></a>
### Observable Consequences

Technical depth: [Evidence](0041-session-lineage-projection-and-context-budget-technical.md#technical-adr-0041-evidence).

The next prompt can refer to earlier work. Long sessions consume more input
until compaction substitutes a retained summary. A failure names its context
dimension and available remedy without claiming that compaction can always fit
an oversized indivisible turn.

<a id="concept-adr-0041-compatibility"></a>
### Compatibility and Rollback

Technical depth: [Compatibility mechanics](0041-session-lineage-projection-and-context-budget-technical.md#technical-adr-0041-compatibility).

Projection uses existing facts and adds no record kind by itself. Already
staged requests retain exact bytes. New projections after upgrade can differ.
Rollback may change later projection behavior; it cannot undo additional M7
records created by other decisions. Those records need the M7 reader contract.

## Governance Record

| Decision | Authority | Authority evidence | Bound bytes |
| --- | --- | --- | --- |
| Acceptance | — | — | — |
