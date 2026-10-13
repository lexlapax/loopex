<a id="concept"></a>
## Concept

Technical depth: [Marker, backup and restore commands, and evidence](0072-store-readiness-marker-backup-and-restore-technical.md#technical-depth).

- **Status:** Proposed
- **Date:** 2026-09-30; reconciled with the delivered M7 baseline on 2026-10-13
- **Decision owner:** Maintainer
- **Supersedes:** nothing. It narrowly amends accepted [ADR 0051](0051-current-format-physical-restore.md#concept) in one clause only: its statement that no backup CLI is added. It adds operator commands in front of ADR 0051's unchanged transition. It also takes the operator backup and restore work out of Proposed [ADR 0036](0036-daemon-grade-store-engine-and-migration.md#concept), which keeps the engine selection, migration and capacity refusal. That split is M8's proposal P2 until the maintainer selects it
- **Depends on:** [ADR 0051](0051-current-format-physical-restore.md#concept) for the restore transition, its backup profile, inputs, limits and outcomes; [ADR 0070](0070-pre-1-superseded-surface-retirement.md#concept) and the current replay for record refusal; [ADR 0031](0031-daemon-grade-store-selection-and-migration.md#concept) for the local adapter and its limits; [ADR 0046](0046-child-session-tool.md#concept) for the closed-host rule restore answers; [ADR 0037](0037-host-configuration-and-path-discovery.md#concept) for the diagnostic command and readiness report
- **Prerequisite for:** M8 outcomes 3 and 7, accepted before any marker, backup or restore command code is written

<a id="concept-adr-0072-decision"></a>
### Context and Decision

Technical depth: [Contract](0072-store-readiness-marker-backup-and-restore-technical.md#technical-adr-0072-decision).

This record was first proposed before M7 was built, as a container marker, a
reader inventory and a backup archive with its own restore. M7 then settled
most of that.

- **Restore exists.** Accepted ADR 0051 delivers
  `LoopexComposition.Restore.restore/2` and `lookup/3`. They restore a
  complete, unexcluded, idle backup of a current-format root into an empty
  root on the same machine. The original source is retired, and the
  operation never redispatches an uncertain effect. The host owns backup
  creation, the capture record, plan construction and the latestness and
  exclusion attestation. There is no command an operator can run.
- **Unknown records are refused.** Session replay refuses a record kind outside
  the current inventory as `invalid_private_history`. ADR 0070 refuses a root
  that has only the retired session catalogue and deletes the index-preparation
  step. Before 1.0 no older root, reader or client is supported.

Two gaps remain for an installed operator. Backup and restore need a host
program. And an unsupported root is refused only after the Store has written
to it: the Store takes its writer marker, and may repair a torn tail, before
replay can refuse anything.

This record now decides only those gaps. ADR 0051 decides the restore and
ADR 0070 decides the retirements. Older readers, cross-version rollback and a
separate record inventory are no longer part of it.

**The decision.**

1. **A root carries a current-format marker.** The installed build writes one
   small marker naming the root format and its version into a new root before
   any other write. Every command that opens a root checks it first. A
   missing or unknown marker is refused by name before any write, including
   the placement lock, the Store's writer marker and any torn-tail repair. A
   root without a marker, such as one an M6 or M7 source build wrote, is never
   marked in place, because marking it would be an upgrade.
2. **Backup is an operator command on a stopped root.**
   `loopex store backup` carries out ADR 0051's capture steps for a root no
   process holds. It says what it will do before doing it. It writes a backup
   that ADR 0051's restore accepts, holding the complete copy and the capture
   record. It refuses a held root, and a root whose writer marker shows an
   unclean stop.
3. **Restore is an operator command into an empty target.**
   `loopex store restore` builds ADR 0051's plan from the capture record and
   the operator's explicit statements. It calls the delivered restore and
   reports its outcome. An uncertain result is resolved by presenting the same
   transaction again. The command adds no copy, audit or transition of its own.
4. **Restore is the recovery procedure.** It is the exit ADR 0046 names for a
   root that cannot be served. It is also the only way back from a root this
   build refuses: restore a backup under the build whose format it is. Work
   done after the backup is lost.
5. **The installed host reports readiness facts.** ADR 0037's diagnostic
   command shows the marker, whether the root is held and the backup format
   this build writes. When a running service has closed durable admission, its
   readiness report names the session whose history could not be read, or the
   reason when no session is named.

<a id="concept-adr-0072-consequences"></a>
### Observable Consequences

Technical depth: [Evidence](0072-store-readiness-marker-backup-and-restore-technical.md#technical-adr-0072-evidence).

`loopex store backup` and `loopex store restore` exist in the installed
release. An operator stops the service, takes a backup, and can later restore
it into a new root on the same machine. The original workspace must still be
at its recorded physical identity. Restore leaves workspace contents and
external effects alone, and the documentation says so plainly.

An operator whose service reports a closed root learns which session is
unreadable and restores the most recent good backup. An operator who points
the installed release at a root it does not support gets a named refusal and
an unchanged root, never a partial upgrade.

<a id="concept-adr-0072-compatibility"></a>
### Compatibility and Rollback

Technical depth: [Compatibility mechanics](0072-store-readiness-marker-backup-and-restore-technical.md#technical-adr-0072-compatibility).

The private Store ports, session and command identity, public event schemas,
the daemon's placement rules and ADR 0051's inputs, records and outcomes do not
change. The marker and the backup layout are experimental current-format
contracts with versions of their own. Before 1.0 only the current version of
each is kept. A later engine migration reads its source root through the
marker check; how its retired source relates to these backups is ADR 0036's to
state.

This decision is removed by not shipping the two commands and the marker
writer. A root that already carries a marker stays readable by the build that
wrote it.

## Governance Record

| Decision | Authority | Authority evidence | Bound bytes |
| --- | --- | --- | --- |
| Acceptance | — | — | — |
