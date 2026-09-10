<a id="concept"></a>
## Concept

Technical depth: [Provider permit retirement mechanics](0027-provider-permit-retirement-technical.md#technical-depth).

- **Status:** Proposed
- **Date:** 2026-09-09
- **Decision owner:** Maintainer
- **Prerequisite for:** M3 acceptance

<a id="concept-adr-0027-decision"></a>
### Context and Decision

ADR 0018 explicitly retains every spent attempt and worker/reference for an
entire ownership generation. Long-lived Control memory therefore grows with
historical attempts, but simply deleting entries would make a delayed old
request look unspent.

Narrowly supersede ADR 0018's whole-generation in-memory retention sentence.
Control retains full worker/reference evidence only for live unresolved work.
A settled attempt is retired only after durable session evidence closes it and
an authoritative current-attempt fence makes every earlier identity ineligible.
Retirement never grants a permit and does not change provider accounting,
not_dispatched retry or unknown-effect semantics.

Technical depth: [Contract and evidence](0027-provider-permit-retirement-technical.md#technical-adr-0027-decision).

<a id="concept-adr-0027-consequences"></a>
### Consequences, Compatibility and Rollback

Control memory can scale with active sessions and live attempts instead of
lifetime attempts. Late or replayed permit requests remain refused, including
after coordinator replacement. The change requires a proof at the authorization
boundary, not merely a memory observation.

No new durable provider record is necessary: use existing attempt-open and
settlement-v2 evidence plus current ownership. Existing readers and journals
keep their semantics. Rollback retains more evidence and preserves the same
fence; it must not reinstate a path that treats a retired identity as fresh.

Technical depth: [Compatibility mechanics](0027-provider-permit-retirement-technical.md#technical-adr-0027-compatibility).

## Governance Record

| Decision | Authority | Authority evidence | Bound bytes |
| --- | --- | --- | --- |
| Acceptance | — | — | — |
