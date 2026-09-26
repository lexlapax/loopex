<a id="concept"></a>
## Concept

Technical depth: [Prerequisites and evidence](m8-store-engine-successor-technical.md#technical-depth).

**Draft, not a registered plan.** This draft comes from the maintainer's
reframing of 2026-09-26 and is refined as M6 and M7 proceed. It moves into
`docs/plans/` as the Open lookahead once M7 closes.

<a id="concept-plan-purpose"></a>
### Purpose

Technical depth: [Prerequisites](m8-store-engine-successor-technical.md#technical-plan-prerequisites).

**M8 is the store engine successor.** Its product question is:

> Can a durable Loopex root grow past the `0.2` log's 256 MiB ceiling, and be
> moved onto a daemon-grade engine by an explicit, interruptible migration that
> never loses a committed fact?

The `0.2` local store is a full-replay log. It stops at 256 MiB and asks the
operator to retire the root. M7 adds a format marker, a reader boundary, and
backup and restore. It also takes the engine decision from a retained measured
experiment under [ADR 0036](../adr/0036-daemon-grade-store-engine-and-migration.md#concept).
M8 builds what that decision selects.

<a id="concept-plan-outcomes"></a>
### Outcomes

Technical depth: [Evidence](m8-store-engine-successor-technical.md#technical-plan-evidence).

| # | Outcome |
| --- | --- |
| 1 | **The engine adapter.** One store application behind the unchanged private store port, passing the store conformance suite and the process and store fault-injection suites |
| 2 | **Explicit migration.** `loopex store migrate`: offline, idempotent and resumable when interrupted, marker-first and remove-last, from the `0.2` log to the new engine |
| 3 | **Definite capacity refusal.** A named, survivable refusal at the engine's documented bound, never a silent stop |
| 4 | **Upgrade and rollback.** The previous release still opens a root it can read. A migrated root is refused by name by any binary that does not know its format, and restoring the backup is the rollback |

<a id="concept-plan-scope"></a>
### Scope and Non-Goals

Technical depth: [Evidence](m8-store-engine-successor-technical.md#technical-plan-evidence).

**Scope.** The adapter, the migration command, the capacity refusal, the
operator documentation and the release lanes for them.

**Non-goals.**

- **Store:** no compaction, retention or history rewrite beyond what ADR 0036
  decides, and no second engine.
- **Protocol:** no protocol change.
- **Extensions:** no extension state.

<a id="concept-plan-decisions"></a>
### Design Decisions

Technical depth: [Prerequisites](m8-store-engine-successor-technical.md#technical-plan-prerequisites).

[ADR 0036](../adr/0036-daemon-grade-store-engine-and-migration.md#concept) is the governing
decision. It is accepted by M7, once its engine cell is filled from the
experiment record, and M8 implements the successor half it names.
