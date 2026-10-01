<a id="technical-depth"></a>
## Technical depth

Concept: [M9 store engine successor](m9-store-engine-successor.md#concept).

<a id="technical-plan-prerequisites"></a>
### Prerequisites

Concept: [Purpose](m9-store-engine-successor.md#concept-plan-purpose).

Concept: [Design decisions](m9-store-engine-successor.md#concept-plan-decisions).

| Decision | Acceptance point |
| --- | --- |
| [ADR 0036](../adr/0036-daemon-grade-store-engine-and-migration.md#concept) | Accepted with M9, its engine cell filled from the retained experiment record on both toolchain pairs, before any M9 adapter code |

M8 closes first. Under ADR 0051 it supplies the format marker, the reader
boundary, and backup and restore that the migration starts from. The selection
experiment is M9 preparation, not M8 evidence.

Capacity configuration follows ADR 0036's versioned successor-schema or explicit
ADR 0049 amendment path. Version-1 config keeps its closed members; migration
must prove installed writer/reader behavior without a second resolver.

<a id="technical-plan-evidence"></a>
### Evidence

Concept: [Outcomes](m9-store-engine-successor.md#concept-plan-outcomes).

Concept: [Scope and non-goals](m9-store-engine-successor.md#concept-plan-scope).

| # | Evidence |
| --- | --- |
| 1 | The store conformance suite and the fault-injection suites run against the new adapter on both toolchain pairs |
| 2 | A migration interrupted at every recorded step converges on rerun to the same root; fixtures at the local adapter's capacity boundary and with the complete [M7 compatibility inventory](../plans/M7-technical.md#technical-plan-compatibility) have their Store records migrate with identical bytes/order and serve their sessions; host ledgers are verified unchanged in place outside the Store and remain in whole-root backup/restore |
| 3 | A root driven to the engine's bound refuses by name and stays openable |
| 4 | The exact supported predecessor binary refuses the migrated root before writes; the retained pre-migration backup restores through a compatible tool and opens under its matching binary |

If the engine brings a native dependency, it enters the new store application
alone and is compiled per platform by M8's release recipes. Core's dependency
list stays `:telemetry` alone.
