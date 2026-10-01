<a id="concept"></a>
## Concept

Technical depth: [Selection procedure, migration contract and candidate evidence](0036-daemon-grade-store-engine-and-migration-technical.md#technical-depth).

- **Status:** Proposed
- **Date:** 2026-09-21
- **Decision owner:** Maintainer
- **Supersedes:** [ADR 0031](0031-daemon-grade-store-selection-and-migration.md#concept)
  for the store selection only, once this pair is accepted; ADR 0031's local
  adapter, its documented ceilings and its root-retirement procedure remain
  the historical `0.2` record; migration fixtures also include valid post-M7 records
- **Prerequisite for:** the M9 draft's engine adapter, migration and capacity
  refusal, accepted with its engine cell filled before any adapter or
  migration code is written. The format marker, reader boundary, backup and
  restore this record first proposed are decided separately by
  [ADR 0051](0051-store-readiness-marker-backup-and-restore.md#concept)
  for M8

<a id="concept-adr-0036-decision"></a>
### Context and Decision

Technical depth: [Selection procedure](0036-daemon-grade-store-engine-and-migration-technical.md#technical-adr-0036-decision).

**Scope split, proposed 2026-09-30.** This is proposal P2 of the Open
[M8 plan](../plans/M8.md#concept), an author proposal until the maintainer
selects it; this record's earlier framing had M8 accept it with the engine
chosen. This record first proposed the store engine and
the installed release's readiness work together. Under the proposal the
readiness work is
Proposed [ADR 0051](0051-store-readiness-marker-backup-and-restore.md#concept),
so that backup and restore do not wait on the engine experiment. This record
keeps the engine selection, the migration and the capacity refusal. Where the
text below mentions the marker, the reader boundary, backup or restore, ADR
0051 owns their contract and this record states only how migration uses them.

ADR 0031 selected the existing local adapter for `0.2.0` and stated its
ceilings plainly: a hard 256 MiB log capacity, a 4 MiB frame ceiling, full
replay at open, and a root-retirement procedure when the capacity is reached.
It withdrew its own successor half on 2026-09-20 because a decision recorded
before its evidence is a preference, and it named the questions the successor
must answer: which engine, on what measured evidence, with what migration,
what interrupted-import recovery, what backup and restore, and which binary is
the oldest reader of the new root. This pair answers those questions in the
only order that is not circular: it fixes the **procedure, the criteria and
the migration contract now**, and it leaves the **engine cell** to be filled
from retained measured evidence before acceptance. An engine chosen before the
measurement would repeat the mistake ADR 0031 corrected.

**The decision.**

1. **The private Store ports do not change.** The daemon-grade adapter is a
   new implementation behind the same `Loopex.Store` callbacks, transactions
   and result unions the local adapter satisfies today. It runs the shared
   conformance suite and the process and store fault matrix unchanged. Core
   gains no dependency: the engine and any library it needs live in one new
   adapter application, under the dependency direction ADR 0001 fixes and the
   core budget the vision names. Its port inventory includes accepted M7
   additions, including read-only creation provenance and complete stable-ordinal
   paging; a missing implementation is unavailable rather than absence.
2. **The engine is selected by a measured experiment on the private ports**,
   run on both supported toolchain pairs, whose retained record is attached to
   this pair before acceptance. The candidates and the measurements are named
   in the companion. The recommendation, recorded here so the maintainer sees
   it before the evidence rather than after, is the **segmented indexed log in
   pure OTP**: it adds no native dependency, keeps the adapter readable by the
   people who read the local adapter today, and is the smallest change that
   removes the two ceilings the operator meets. SQLite is the alternative if
   the measured replay or index bounds are not met, and choosing it is also a
   dependency decision, taken in the same acceptance.
3. **Every supported local-format root migrates forward, once, explicitly.** Migration is an
   operator command, never a side effect of opening a root. It converges when
   interrupted, it never destroys the source until the target verifies, and
   the oldest reader of a migrated root is the release that ships the engine.
   The installed candidate's format marker and unknown-format refusal come
   from ADR 0051. They cannot retrofit released readers. Container format, durable
   record capabilities and binary version are distinct; exact reader fixtures
   must establish supported combinations before acceptance. Store records migrate;
   M7's host ledger remains byte-for-byte at its
   host-root paths outside the Store. Whole-root backup and restore include them.
4. **Restore is the migration's rollback procedure.** ADR 0051 supplies
   backup and restore as operator commands on a closed root. A previous binary
   is not a rollback plan when storage has changed, so the engine milestone's
   rollback proof is a restore of the pre-migration backup under the previous
   release.
5. **A capacity refusal is definite and survivable** on the new adapter: the
   Store answers a refusal without terminating, so a daemon keeps its
   attachments and stops in an orderly way. ADR 0031 rejected this change for
   the local adapter because it doubled M5's store evidence; it is exactly the
   successor's evidence, proved through the conformance suite and the fault
   matrix on every adapter.

<a id="concept-adr-0036-consequences"></a>
### Observable Consequences

Technical depth: [Migration and interrupted-import contract](0036-daemon-grade-store-engine-and-migration-technical.md#technical-adr-0036-migration).

Backup, restore and the marker report arrive with the installed candidate
under ADR 0051. From the release that ships the engine, an
operator opens a root and it opens in bounded time whatever its history
length, because replay is bounded by the index rather than by the log; the
256 MiB retirement procedure disappears for migrated roots; `loopex store
migrate` exists under the same rules and is, with the daemon, the only writer
of the new format; `doctor` reports whether a migration is pending; and the installed candidate's
daemon pointed at a migrated root exits with a named class rather than
serving it.

What does not change: session identity, command identity, the journal's
public event schema and wire records of its accepted predecessor, the placement lock and
writer marker rules ADR 0031 and ADR 0032 fixed, and the daemon-owned listing
index ADR 0032 owns, which is rebuilt from the migrated root rather than
migrated itself.

<a id="concept-adr-0036-compatibility"></a>
### Compatibility and Rollback

Technical depth: [Compatibility and rollback mechanics](0036-daemon-grade-store-engine-and-migration-technical.md#technical-adr-0036-compatibility).

The release that ships the engine is the first durable migration milestone,
so the vision's list applies to it in full: supported source and target
versions, forward migration, interrupted-migration detection and recovery,
backup and restore as the downgrade policy, the previous-binary reopening
boundary, and an exact packaged rollback procedure. The installed candidate retains the local storage container and discharges
its own reader-capability obligations under ADR 0051: the format marker,
the reader boundary, and backup and restore. The private journal schema is
surface 1 in the vision's list and freezes nothing here; the public protocol
is untouched. Rejected alternatives and the reasons are in the companion.

## Governance Record

| Decision | Authority | Authority evidence | Bound bytes |
| --- | --- | --- | --- |
| Acceptance | — | — | — |
