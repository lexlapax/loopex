<a id="technical-depth"></a>
## Technical depth

Concept: [Development floor refresh](0026-development-floor-refresh.md#concept).

<a id="technical-adr-0026-decision"></a>
### Contract and Evidence

Concept: [Context and decision](0026-development-floor-refresh.md#concept-adr-0026-decision).

### Transaction order and evidence

Retain original ADR 0002 and `.tool-versions` until this proposal is accepted.
Derive the exact holder inventory on integrated Closed M3. Settle M0, M1 and M2
and any M3 holder in order, each as atomic v2 proposal A followed immediately by
explicitly accepted rebind R. Each holder's proposal includes its changed bound
artifacts and generation row together. Account for overlapping floor, app and
version inventory edits before acceptance to avoid locking known future changes.
No M4 holder exists yet. Moving the floor later reduces M3 prerequisites but
may add a Closed M3 transaction; retain that cost explicitly. Unrelated fixes
need their own scope and evidence rather than automatic inclusion in a floor
proposal.

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
