<a id="concept"></a>
## Concept

Technical depth: [Development floor refresh mechanics](0026-development-floor-refresh-technical.md#technical-depth).

- **Status:** Proposed
- **Date:** 2026-09-09
- **Decision owner:** Maintainer
- **Prerequisite for:** M3 acceptance

<a id="concept-adr-0026-decision"></a>
### Context and Decision

The draft floor change bound its own future edit and therefore required an
avoidable amendment to Accepted M3. The bootstrap's original lowest-patch
selection rule also cannot truthfully derive the proposed patched floor.

Supersede ADR 0002's pin-selection rule for development validation with explicit
chosen pairs: floor Elixir 1.18.5 / OTP 27.3.4, current Elixir 1.20.3 / OTP
29.0.5. Preserve separate floor and current lanes and the core stdlib budget.
Settle the decision and all three Closed-gate generations before accepting M3.
No public supported-runtime statement or automatic moving-latest policy is added.

Technical depth: [Contract and evidence](0026-development-floor-refresh-technical.md#technical-adr-0026-decision).

<a id="concept-adr-0026-consequences"></a>
### Consequences, Compatibility and Rollback

The subsequent protocol can use the standard-library JSON capability on both
validation pairs. Pinned environments remain reproducible and their patch choice
is honest. Acceptance requires real matrix evidence and does not make old gate
records mutable.

No persistent data changes. Historical evidence still names its original
runtime. Restoration is a new accepted decision and gate-generation transaction,
not deletion or reversion of old Acceptance/Closure records. Future public
runtime support and its breaking-change policy remain separately governed.

Technical depth: [Compatibility mechanics](0026-development-floor-refresh-technical.md#technical-adr-0026-compatibility).

## Governance Record

| Decision | Authority | Authority evidence | Bound bytes |
| --- | --- | --- | --- |
| Acceptance | — | — | — |
