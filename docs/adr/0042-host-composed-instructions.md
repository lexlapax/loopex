<a id="concept"></a>
## Concept

Technical depth: [Host-composed instructions](0042-host-composed-instructions-technical.md#technical-depth).

- **Status:** Proposed
- **Date:** 2026-09-30
- **Decision owner:** Maintainer
- **Supersedes:** [ADR 0010](0010-provider-continuation-and-context-staging.md#concept) only the fixed source of system text; [ADR 0017](0017-durable-context-admission-budget.md#concept) only the fixed system-class token ceiling, now a host value with the existing 1,000 default
- **Depends on:** [ADR 0044](0044-run-model-and-reasoning-configuration.md#concept) for settled updates
- **Prerequisite for:** M7 outcomes 2 and 7

<a id="concept-adr-0042-decision"></a>
### Context and Decision

Technical depth: [Contract](0042-host-composed-instructions-technical.md#technical-adr-0042-decision).

The host supplies exact instruction bytes as plain bounded data. Core owns
staging, provenance, receipt and digest, not task prompt selection. It retains
only the immutable legacy fallback for callers that supply no instructions.

The block has base instructions, environment facts and an optional trusted
appendix, in that order. Project files and skills keep their separate provenance
and admission. Environment facts such as workspace, platform and date grant
nothing. The reference host uses one default across models and tasks; its
default block plus default active tool definitions measures below 1,000 estimated
tokens. Opt-in tool configurations are measured separately and refuse unless
the explicitly selected ceiling accommodates them.

Commit exact bytes, version and digest with session configuration. Replace
them only through ADR 0044's atomic settled `configure` command. An active run
retains its configuration; restart never rereads a file to reconstruct it.
A host may explicitly raise the system-class ceiling within the context budget.
The strict admission rule remains observed tokens less than the ceiling.

<a id="concept-adr-0042-consequences"></a>
### Observable Consequences

Technical depth: [Evidence](0042-host-composed-instructions-technical.md#technical-adr-0042-evidence).

Operators can replace or append host text and inspect what reached each model
call. A host that selects untrusted bytes as system instructions makes its own
trust decision; a filename alone never promotes project content.

<a id="concept-adr-0042-compatibility"></a>
### Compatibility and Rollback

Technical depth: [Compatibility mechanics](0042-host-composed-instructions-technical.md#technical-adr-0042-compatibility).

Missing legacy instructions use the existing fallback and 1,000-token ceiling.
Already committed model requests are unchanged. New configuration records carry
instructions; old readers must be checked against exact fixtures before any
rollback claim. New projections can differ under ADR 0041.

## Governance Record

| Decision | Authority | Authority evidence | Bound bytes |
| --- | --- | --- | --- |
| Acceptance | — | — | — |
