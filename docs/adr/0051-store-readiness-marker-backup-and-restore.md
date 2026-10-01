<a id="concept"></a>
## Concept

Technical depth: [Marker, reader boundary, archive and evidence](0051-store-readiness-marker-backup-and-restore-technical.md#technical-depth).

- **Status:** Proposed
- **Date:** 2026-09-30
- **Decision owner:** Maintainer
- **Supersedes:** nothing; it takes the format marker, reader boundary, backup and restore out of Proposed [ADR 0036](0036-daemon-grade-store-engine-and-migration.md#concept), which keeps the engine selection, migration and capacity refusal
- **Depends on:** [ADR 0031](0031-daemon-grade-store-selection-and-migration.md#concept) for the local adapter and its limits, and the delivered M7 record inventory
- **Prerequisite for:** M8 outcomes 3 and 7, accepted before any marker, reader-boundary, backup or restore code is written

<a id="concept-adr-0051-decision"></a>
### Context and Decision

Technical depth: [Contract](0051-store-readiness-marker-backup-and-restore-technical.md#technical-adr-0051-decision).

ADR 0036 proposed two things in one record: which store engine replaces the
local log, and the readiness work an installed release needs whichever engine
wins. It may be accepted only with the engine chosen from a measured
experiment, and no marker or backup code may be written before it is accepted.
That ties the installed release to an experiment whose result it does not use.

M7 also made backup and restore load-bearing. Under accepted ADR 0046, one
unreadable session history keeps the durable host closed until the root is
restored from backup, and M7 ships no backup command. Its fixtures copy quiet
directories by hand.

This record decides the readiness work alone, on the existing local adapter.
ADR 0036 continues to decide the engine and the migration, for the store
successor milestone.

**The decision.**

1. **A root carries a container-format marker.** The installed candidate
   writes it into a supported local root without rewriting any record. A root
   without a marker is a legacy container and says nothing about which records
   it holds.
2. **The reader checks record support before serving a root.** The candidate
   holds a closed inventory of the durable-record kinds and versions it reads.
   An unknown container format, or a record outside that inventory, is refused
   by name before any write.
3. **Released readers are tested as they are.** No older build is claimed to
   honor a marker or emit a refusal it never implemented. Where an older build
   cannot safely refuse a newer root, the procedure prevents the reopening.
4. **Backup is an operator command on a closed root.** It produces one archive
   with a manifest of every file, size and digest. It refuses a root that a
   daemon or an offline command holds, and says what it will do before doing it.
5. **Restore is an operator command into an empty target.** It verifies every
   digest before publishing the root, refuses a nonempty or live target, and
   leaves an ordinary root layout that the matching build opens.
6. **A backup is the whole host root's durable truth.** It includes Store
   records, artifacts, M7's host ledger, role snapshots and child sessions,
   with their root-relative layout. It excludes sockets, locks and caches that
   are rebuilt from durable records. The configuration file is not part of the
   root and is not archived.
7. **Restore is the rollback and the recovery procedure.** A previous build is
   not a rollback plan once newer records exist. Rolling back means restoring
   the pre-upgrade backup for the matching build, and it discards later facts.
   The same command is the exit ADR 0046 names for a root that cannot be
   served.
8. **The diagnostic command reports readiness.** It shows the marker, whether
   the root is held, and, when durable admission is closed, the session whose
   history could not be read.

<a id="concept-adr-0051-consequences"></a>
### Observable Consequences

Technical depth: [Evidence](0051-store-readiness-marker-backup-and-restore-technical.md#technical-adr-0051-evidence).

`loopex store backup` and `loopex store restore` exist in the installed
candidate. An operator takes a backup before an upgrade, and can return to
exactly that state. An operator whose service reports a closed root learns
which session is unreadable and restores the most recent good backup; work
since that backup is lost, and the documentation says so plainly. The first
start after any restore repeats M7's helper-history classification, so durable
admission opens only when that scan completes.

Opening a supported M7 root with the candidate needs no migration. The marker
appears and no record changes. The 256 MiB log ceiling and its retirement
procedure are unchanged.

<a id="concept-adr-0051-compatibility"></a>
### Compatibility and Rollback

Technical depth: [Compatibility mechanics](0051-store-readiness-marker-backup-and-restore-technical.md#technical-adr-0051-compatibility).

Container format, durable-record capability and binary version are three
separate facts, and each supported combination is proved by a fixture rather
than inferred. The private Store ports, session and command identity, public
event schemas and the daemon's placement rules do not change. The archive is
an experimental operator format with a version of its own; a later engine
migration consumes it under ADR 0036.

This decision is removed by not shipping the two commands and the marker
writer. A root that already carries a marker stays readable by the candidate.

## Governance Record

| Decision | Authority | Authority evidence | Bound bytes |
| --- | --- | --- | --- |
| Acceptance | — | — | — |
