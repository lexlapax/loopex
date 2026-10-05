<a id="concept"></a>
## Concept

Technical depth: [Host configuration preparation](0050-host-configuration-preparation-technical.md#technical-depth).

- **Status:** Proposed
- **Date:** 2026-10-04
- **Decision owner:** Maintainer
- **Amends:** [ADR 0044](0044-run-model-and-reasoning-configuration.md#concept)'s host preparation boundary and authored-to-canonical configure binding; authority and single-transaction admission remain.

<a id="concept-preparation"></a>
### Decision

Technical depth: [Boundary and lifecycle](0050-host-configuration-preparation-technical.md#technical-preparation).

A settled session's configure command needs host-resolved model metadata and
admitted provider routes. The runtime retains committed configuration;
transport constructors receive only the runtime. Extend `Loopex.Model` with an
optional configuration-preparation callback using its existing private adapter
options. It prepares a candidate in an owned worker; the serial session owner
alone validates and commits it. Preparation acquires no provider credential and
dispatches no model or executor operation. Shared catalog services retain their
already accepted host-owned network/cache lifecycle; per-preparation work stays
owned and joined.

The maintainer selected direction B on 2026-10-04. This revised pair proposes its
concrete contract; that direction choice does not accept the earlier choice-A
pair. A composition-owned Model wrapper resolves configuration centrally and
delegates completion to the selected model adapter with its exact original
options. Provider implementations never import composition. The alternative is
a separate preparation behaviour and startup option; B keeps one model boundary
while making configuration support a capability of that boundary.

The maintainer requested runtime aliases on 2026-10-04. This revised proposal
supports aliases through the same trusted host resolution as canonical model
names. Preparation preserves the authored normalized changes and returns only a
candidate. The command digest identifies that authored request; the retained
candidate identifies its resolved canonical model. A duplicate returns its
original disposition even if the alias later resolves differently. A fresh
command may capture a new resolution. The CLI also preserves its authored model
name while constructing the canonical candidate. Wire instructions use ADR
0042's existing raw four-field grammar and are captured purely before command
normalization.

The reference wrapper requires explicit admitted provider routes from validated
host bindings or a borrowed credential plane. A single-token startup without
that route inventory has no unprepared-configuration capability. Existing
prepared-candidate calls and model completion remain available.

Bound preparation to 60,000 milliseconds captured once when it starts. Owner
loss, caller loss, cancellation or expiry ends its owned work before a success
or confirmed cleanup reply. Cleanup uses the session's retained cleanup grace;
uncertain cleanup cannot admit the candidate. A late result or a changed owner
or configuration version refuses rather than merging silently.

Unprepared configure without the callback or its required host resolution inputs
refuses. The already-approved prepared-candidate facade remains available to hosts that prepare externally.
Neither path reconstructs a pending unknown transaction or reruns preparation
when replay has already retained the command disposition.

<a id="concept-alias-identity"></a>
### Authored identity and retained resolution

Technical depth: [Alias binding and replay](0050-host-configuration-preparation-technical.md#technical-alias-identity).

Retain authored changes and the complete canonical candidate together in the
existing owner transaction. The new current private configure record is
`session_configuration_admitted_v2`, with the same eight fields. Its new
semantics allow an explicitly authored model alias to differ from the candidate's
canonical model. No second changes map or resolver receipt is added. Recovery
verifies the authored command digest and the exact candidate using retained
facts, without reloading the catalog or resolving the alias again.

Omitting a model change cannot retarget the model, and resolution cannot rewrite
other authored settings. Alias and canonical spellings remain distinct command
payloads; reusing one command ID with a different spelling conflicts. Both the
optional callback and the existing prepared-candidate facade use this rule.
An unknown transaction keeps its original complete proposal and never repeats
resolution. Public configuration events and snapshots retain canonical models.

Before 1.0, replace the configure v1 writer and readers together. Superseded v1
configure histories refuse; no migration or existing-journal rewrite is proposed.
Current v2 restart, replay and exact unknown-transaction recovery are required.
Acceptance of this revised pair is required before implementing this persistent
semantic change.

<a id="concept-contract-impact"></a>
### Contract impact and verification

Technical depth: [Evidence and proof](0050-host-configuration-preparation-technical.md#technical-contract-impact).

The optional callback extends the existing cross-application Model contract.
Core imports only Model; composition implements catalog, alias and provider-route
resolution in its Model wrapper. Foreground and daemon hosts select that wrapper
through composition without adding transport constructor arguments. Wire
instructions reuse ADR 0042's closed input grammar. The complete remote
session-option grammar remains a separate governed decision; this callback does not select it.

Only the current contract is required before 1.0. There is no old-adapter
fallback, configure-v1 reader or older-root migration. Current v2 captures remain
replayable without this callback. Removing the optional callback disables new unprepared configure;
retained configured sessions and prepared-candidate commands keep their current
semantics. This proposal does not authorize milestone closure or publication.

## Governance Record

| Decision | Authority | Authority evidence | Bound bytes |
| --- | --- | --- | --- |
| Acceptance | — | — | — |
