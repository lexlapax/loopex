<a id="technical-depth"></a>
## Technical depth

Concept: [M8 store engine successor](m8-store-engine-successor.md#concept).

<a id="technical-plan-prerequisites"></a>
### Prerequisites

Concept: [Purpose](m8-store-engine-successor.md#concept-plan-purpose).

Concept: [Design decisions](m8-store-engine-successor.md#concept-plan-decisions).

| Decision | Acceptance point |
| --- | --- |
| [ADR 0036](../adr/0036-daemon-grade-store-engine-and-migration.md#concept) | Accepted in M7 with its engine cell filled from the retained experiment record, before any M8 adapter code |

M7 closes first. It supplies the format marker, the reader boundary, and backup
and restore that the migration starts from.

<a id="technical-plan-evidence"></a>
### Evidence

Concept: [Outcomes](m8-store-engine-successor.md#concept-plan-outcomes).

Concept: [Scope and non-goals](m8-store-engine-successor.md#concept-plan-scope).

| # | Evidence |
| --- | --- |
| 1 | The store conformance suite and the fault-injection suites run against the new adapter on both toolchain pairs |
| 2 | A migration interrupted at every recorded step converges on rerun to the same root; a fixture root at the `0.2` ceiling migrates and serves its sessions |
| 3 | A root driven to the engine's bound refuses by name and stays openable |
| 4 | The previous release refuses the migrated root by name and writes nothing; the backup restores under the previous release |

If the engine brings a native dependency, it enters the new store application
alone and is compiled per platform by M7's release recipes. Core's dependency
list stays `:telemetry` alone.
