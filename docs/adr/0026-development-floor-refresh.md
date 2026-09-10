<a id="concept"></a>
## Concept

Technical depth: [Development floor refresh mechanics](0026-development-floor-refresh-technical.md#technical-depth).

- **Status:** Proposed
- **Date:** 2026-09-09
- **Decision owner:** Maintainer
- **Supersedes:** 0002
- **Prerequisite for:** M4 acceptance

<a id="concept-adr-0026-decision"></a>
### Context and Decision

M4's protocol needs a codec on both validation pairs. Standard-library JSON
motivates the floor refresh; M3's skills and core repairs need no new floor.
The bootstrap's original lowest-patch selection rule cannot derive the proposed
patched floor honestly.

Supersede ADR 0002's pin-selection rule for development validation with explicit
chosen pairs: floor Elixir 1.18.5 / OTP 27.3.4, current Elixir 1.20.3 / OTP
29.0.5. Preserve separate floor/current lanes and the core stdlib budget. Settle
this decision and every affected Closed holder before M4 acceptance. M0/M1/M2
are known holders; include M3 if its final lock binds changed artifacts. Do not
promise exactly three transactions. No public runtime-support or moving-latest
policy is added. Current pins remain unchanged by this proposal.

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
