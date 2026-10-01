<a id="concept"></a>
## Concept

Technical depth: [Prerequisites and evidence](m9-store-engine-successor-technical.md#technical-depth).

**Draft, not a registered plan.** This draft comes from the maintainer's
reframing of 2026-09-26 and is refined as M7 and M8 proceed. It moves into
`docs/plans/` as the Open lookahead once M8 closes.

<a id="concept-plan-purpose"></a>
### Purpose

Technical depth: [Prerequisites](m9-store-engine-successor-technical.md#technical-plan-prerequisites).

**M9 is the store engine successor.** Its product question is:

> Can a durable Loopex root grow past the `0.2` log's 256 MiB ceiling, and be
> moved onto a daemon-grade engine by an explicit, interruptible migration that
> never loses a committed fact?

The `0.2` local store is a full-replay log. It stops at 256 MiB and asks the
operator to retire the root. The Open [M8 plan](../plans/M8.md#concept) adds a
format marker, a reader boundary, and backup and restore under
[ADR 0051](../adr/0051-store-readiness-marker-backup-and-restore.md#concept).
M9 takes the engine decision from a retained measured experiment under
[ADR 0036](../adr/0036-daemon-grade-store-engine-and-migration.md#concept)
and builds what that decision selects.

<a id="concept-plan-outcomes"></a>
### Outcomes

Technical depth: [Evidence](m9-store-engine-successor-technical.md#technical-plan-evidence).

| # | Outcome |
| --- | --- |
| 1 | **The engine adapter.** One store application behind the unchanged private store port, passing the store conformance suite and the process and store fault-injection suites |
| 2 | **Explicit migration.** `loopex store migrate`: offline, idempotent and resumable when interrupted, marker-first and remove-last, from the supported local log, including valid M7 records, to the new engine |
| 3 | **Definite capacity refusal.** A named, survivable refusal at the engine's documented bound, never a silent stop |
| 4 | **Upgrade and rollback.** The previous release still opens a root it can read. The specifically supported predecessor must prove refusal before writes on the migrated format; other old binaries are governed by the exact-reader matrix. Unsupported downgrade restores the matching pre-upgrade backup |

<a id="concept-plan-scope"></a>
### Scope and Non-Goals

Technical depth: [Evidence](m9-store-engine-successor-technical.md#technical-plan-evidence).

**Scope.** The adapter, the migration command, the capacity refusal, the
operator documentation and the release lanes for them. Capacity configuration
uses a versioned successor to ADR 0049's closed schema or an explicit amendment.
M7's host delegation ledger remains outside Store and unchanged in place during
engine migration; complete backup/restore includes it and its child sessions.

**Non-goals.**

- **Store:** no compaction, retention or history rewrite beyond what ADR 0036
  decides, and no second engine.
- **Protocol:** no protocol change.
- **Extensions:** no extension state.

<a id="concept-plan-decisions"></a>
### Design Decisions

Technical depth: [Prerequisites](m9-store-engine-successor-technical.md#technical-plan-prerequisites).

[ADR 0036](../adr/0036-daemon-grade-store-engine-and-migration.md#concept) is the governing
decision. Under the Open M8 plan's proposal P2, which the maintainer has not
yet selected, its measured selection experiment runs as M9 is prepared and the
pair is accepted with M9, once its engine cell is filled from the experiment
record. M9 implements the engine, migration and capacity refusal it names. The
earlier framing had M8 run the experiment and accept the pair.
