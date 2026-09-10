<a id="technical-depth"></a>
## Technical depth

Concept: [Development floor refresh](0026-development-floor-refresh.md#concept).

<a id="technical-adr-0026-decision"></a>
### Contract and Evidence

Concept: [Context and decision](0026-development-floor-refresh.md#concept-adr-0026-decision).

### Transaction order and evidence

Retain original ADR 0002 and `.tool-versions` until this proposal is accepted.
Then settle M0, M1 and M2 additive v2 generations in that order, each as atomic
proposal A followed immediately by explicitly accepted rebind R. The first
proposal carries changed toolchain bytes and its own gate generation together;
subsequent holders settle their bindings sequentially. No fourth M3 holder is
created before this finishes. Fold the already-needed M0 outcome-1 diagnostic
repair and any confirmed bound corpus fix into their holder's reviewed proposal.

At each revision retain the prescribed stale-binding and binding-independent
evidence, and at completion prove every inherited gate green. Run both pairs
on Darwin and current on Linux with disjoint clean build/dependency roots.
Record actual versions; unavailable images/downloads are not PASS. An identical
pair in both lanes is not two environments. Candidate pin existence and JSON
behavior, including duplicate-key rejection at the future framing boundary,
are proved in readiness rather than inferred from version strings.

Keeping the existing floor is a viable alternative but requires a different
accepted M4 codec/dependency decision. Making floor equal current loses the
compatibility discriminator. Updating pins after M3 acceptance adds a needless
self-amendment. The chosen ordering avoids that transaction without relaxing a gate.

<a id="technical-adr-0026-compatibility"></a>
### Compatibility and Rollback Mechanics

Concept: [Consequences and rollback](0026-development-floor-refresh.md#concept-adr-0026-consequences).

No persistent data changes. Historical evidence still names its original
runtime. Restoration is a new accepted decision and gate-generation transaction,
not deletion or reversion of old Acceptance/Closure records. Future public
runtime support and its breaking-change policy remain separately governed.

Acceptance binds this complete pair at an exact candidate. Its evidence and
compatibility claims remain unproved until the M3 gate's required paths execute.
