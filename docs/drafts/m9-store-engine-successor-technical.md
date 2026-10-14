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

M8 closes first. Under ADR 0072 it supplies the format marker with its
format-number rule, the reader boundary, `store adopt` for roots the M7
source build wrote, and backup and restore that the migration starts from; the backup is
ADR 0072's directory (`state/`, `manifest`, `capture`) under ADR 0051's
complete manifest, which migration's rollback restores. The selection
experiment is M9 preparation, not M8 evidence. Both statements follow the M8
plan's accepted proposal P2 (decision D5).

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
| 2 | A migration interrupted at every recorded step converges on rerun to the same root; marked format-1 fixtures at the local adapter's capacity boundary and covering every format-1 golden vector ADR 0072's `root_format_vectors_test.exs` pins have their Store records migrate with identical bytes/order and serve their sessions; an unmarked root is refused by name with the root byte-identical; host ledgers are verified unchanged in place outside the Store and remain in whole-root backup/restore |
| 3 | A root driven to the engine's bound refuses by name and stays openable |
| 4 | The migrated root's marker carries the successor format number, and the M9 build reads a format-1 root only through `store migrate`; every other entry point refuses it by name before any write. No earlier binary is run against the migrated root. The retained pre-migration backup restores under the `0.5.x` build with ADR 0072's `store restore` and serves |

If the engine brings a native dependency, it enters the new store application
alone and is compiled per platform by M8's release recipes. Core's dependency
list stays `:telemetry` alone.
