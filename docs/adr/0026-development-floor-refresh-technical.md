<a id="technical-depth"></a>
## Technical depth

Concept: [Development floor refresh](0026-development-floor-refresh.md#concept).

<a id="technical-adr-0026-decision"></a>
### Contract and Evidence

Concept: [Context and decision](0026-development-floor-refresh.md#concept-adr-0026-decision).

### Transaction order and evidence

Retain original ADR 0002 and `.tool-versions` until this proposal is accepted.
On the integrated Closed M3 base, `.tool-versions` is bound by Closed M0, M1,
M2 and M3 gates and by the Open M4 gate. Settle Closed M0–M3 in register order,
each as atomic v2 proposal A followed immediately by explicitly accepted
rebind R. Each holder's proposal includes its changed bound artifact and gate
generation row together. Then refresh Open M4's bound-artifact table directly
on the settled base, re-prove the inherited gates green and M4's distinct red,
and submit the M4 candidate for independent review. App and version inventory
edits remain in M4's separately governed later phases. Unrelated fixes need
their own scope and evidence rather than automatic inclusion in a floor proposal.

At each revision retain the prescribed stale-binding and binding-independent
evidence, and at completion prove every inherited gate green. Run both pairs
on Darwin and current on Linux with disjoint clean build/dependency roots.
Record actual versions; unavailable images/downloads are not PASS. An identical
pair in both lanes is not two environments. Candidate pin existence and JSON
behavior, including duplicate-key rejection at the future framing boundary,
are proved in readiness rather than inferred from version strings.

Keeping the existing floor is a viable alternative but requires a different
accepted M4 codec/dependency decision. Making floor equal current loses the
compatibility discriminator. The chosen order settles the floor before M4 acceptance and avoids an M4
self-amendment. Every existing holder still receives its required transaction.

<a id="technical-adr-0026-compatibility"></a>
### Compatibility and Rollback Mechanics

Concept: [Consequences and rollback](0026-development-floor-refresh.md#concept-adr-0026-consequences).

No persistent data changes. Historical evidence still names its original
runtime. Restoration is a new accepted decision and gate-generation transaction,
not deletion or reversion of old Acceptance/Closure records. Future public
runtime support and its breaking-change policy remain separately governed.

Acceptance binds this complete pair at an exact candidate. Its evidence and
compatibility claims remain unproved until the M4 gate's required paths execute.
