<a id="concept"></a>
## Concept

Technical depth: [Host configuration preparation](0050-host-configuration-preparation-technical.md#technical-depth).

- **Status:** Proposed
- **Date:** 2026-10-04
- **Decision owner:** Maintainer
- **Amends:** [ADR 0044](0044-run-model-and-reasoning-configuration.md#concept)'s host preparation boundary; its configuration, authority and transaction semantics remain.

<a id="concept-preparation"></a>
### Decision

Technical depth: [Boundary and lifecycle](0050-host-configuration-preparation-technical.md#technical-preparation).

A settled session's configure command needs the host to resolve model metadata
and admitted provider routes. The runtime retains committed configuration;
transport constructors receive only the runtime. Add a separate optional host
configuration-preparation port installed at runtime startup. It prepares a
candidate in an owned worker; the serial session owner alone validates and
commits it. Catalog access remains a host effect. Preparation acquires no
provider credential and dispatches no model or executor operation.

This is the proposed choice A. Choice B extends the existing Model port with an
optional preparation callback instead. B uses its existing adapter options but
couples configuration support to the selected model adapter. A lets hosts reuse
one configuration resolver across different model adapters and makes that
responsibility explicit. It adds one startup option and one small behaviour.
The recommendation is A.

Bound preparation to 60,000 milliseconds captured once when it starts. Owner
loss, caller loss, cancellation or expiry ends its owned work before a success
or confirmed cleanup reply. Cleanup uses the session's retained cleanup grace;
uncertain cleanup cannot admit the candidate. A late result or a changed owner
or configuration version refuses rather than merging silently.

Unprepared configure without an installed port refuses. The already-approved
prepared-candidate facade remains available to hosts that prepare externally.
Neither path reconstructs a pending unknown transaction or reruns preparation
when replay has already retained the command disposition.

<a id="concept-contract-impact"></a>
### Contract impact and verification

Technical depth: [Evidence and proof](0050-host-configuration-preparation-technical.md#technical-contract-impact).

The startup option and callback are a new cross-application contract. Core
imports only the port; composition implements catalog and provider-route
resolution. Foreground and daemon hosts install it through composition without
adding transport constructor arguments. Remote instruction and session-option
schemas remain separately governed decisions; this port does not select them.

Only the current contract is required before 1.0. There is no old-adapter
fallback or older-root migration. Current captures remain replayable without
this port. Removing the optional port disables new unprepared configure;
retained configured sessions and prepared-candidate commands keep their current
semantics. This proposal does not authorize milestone closure or publication.

## Governance Record

| Decision | Authority | Authority evidence | Bound bytes |
| --- | --- | --- | --- |
| Acceptance | — | — | — |
