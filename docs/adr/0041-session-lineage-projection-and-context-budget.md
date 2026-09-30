<a id="concept"></a>
## Concept

Technical depth: [Session lineage projection and context budget](0041-session-lineage-projection-and-context-budget-technical.md#technical-depth).

- **Status:** Proposed
- **Date:** 2026-09-30
- **Decision owner:** Maintainer
- **Supersedes:** [ADR 0017](0017-durable-context-admission-budget.md#concept) only its fixed 8,192-token reference-host default; implements [ADR 0010](0010-provider-continuation-and-context-staging.md#concept)'s retained-lineage clause. ADR 0043 separately amends required-context failure timing. Also amends [ADR 0009](0009-tool-executor-and-grant-contracts.md#concept)'s deferral of model-facing artifact retrieval and its validated-argument construction for a tool-specific resolved executor form and ADR 0010's tool-result projection to permit recorded excerpts/references. Preserves [ADR 0015](0015-artifact-object-and-use-identity.md#concept) and [ADR 0028](0028-bounded-artifact-retrieval.md#concept) object/use, retention and transfer guarantees.
- **Prerequisite for:** M7 outcome 1

<a id="concept-adr-0041-decision"></a>
### Context and Decision

Technical depth: [Contract](0041-session-lineage-projection-and-context-budget-technical.md#technical-adr-0041-decision).

A new prompt or promoted follow-up sees the session's retained conversation,
not only its own run. Prior prompts, assistant messages, committed tool results
and terminal facts project in committed order. Cancelled, failed and bound-reached
runs remain part of that history. Each new run still has its own accounting.
This repairs a current conformance defect against ADR 0010's retained-lineage
contract. Historical milestone evidence remains a record of its tested revision;
the defect is not a new permission to omit earlier conversation.

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
Bulky tool output is retained as an artifact before the model receives an
explicit bounded excerpt/reference. The existing read tool gains an authorized
range-retrieval branch, so the model can request more without expanding the
whole object into context. When several results share a request, their excerpts
may be shorter so the complete request fits; every result identity, outcome and
reference remains present. Required metadata alone can still exceed the bound.
When an eligible older group cannot fit as complete summary source, ADR 0043
permits marked excerpts with readable originals and retained omission provenance.
This maintenance-only rule does not shorten ordinary question answers or grant
artifact access. Compaction keeps those references retrievable; it
does not fetch them implicitly. An old frozen read generation is not silently
upgraded; if it lacks artifact reads, a projection needing that capability
refuses explicitly while host inspection remains available. Reference preparation
is a bounded, restart-stable episode. No artifact-backed request storage enters M7. ADR 0044's private thinking
continuation counts within the same limits and stays exact; it cannot use the
executor excerpt rule. An open thinking exchange freezes its earlier projection
until completion or a truthful bound failure.
Before a new thinking exchange, allocation and optional intake stay within
ADR 0044's lower initial targets to leave room for continuation. This can shorten
eligible result excerpts or trigger earlier compaction without raising any
hard limit or changing an already staged prefix.

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

Projection reads committed facts only. A new prepared-reference record may
retain exact legacy inline result bytes before projection, without rewriting
receipts. New read-tool and projection generations preserve old dispatch
definitions. Already staged requests retain exact bytes; newly staged requests
may use the new excerpt/reference representation.
Rollback may change later projection behavior; it cannot undo additional M7
records created by other decisions. Those records need the M7 reader contract.

## Governance Record

| Decision | Authority | Authority evidence | Bound bytes |
| --- | --- | --- | --- |
| Acceptance | — | — | — |
