<a id="technical-depth"></a>
## Technical depth

Concept: [Current-format marker and operator backup and restore](0072-store-readiness-marker-backup-and-restore.md#concept).

<a id="technical-adr-0072-decision"></a>
### Contract

Concept: [Context and decision](0072-store-readiness-marker-backup-and-restore.md#concept-adr-0072-decision).

**What stays fixed.** The `Loopex.Store` behaviour, its transactions and
result unions, `Loopex.Store.Local`'s record format and ceilings, the placement
lock and writer marker rules ADRs 0031 and 0032 fixed, and core's dependency
list. ADR 0051's signatures, plan and invocation schemas, canonical manifest,
lineage records, limits, cleanup cutoffs and outcomes are used as accepted.
The marker check and both commands are host code in the reference CLI and
composition; core gains no callback for them.

**What this record no longer decides.** These parts of the earlier proposal
are settled elsewhere or retired.

| Earlier proposal | Now |
| --- | --- |
| Backup archive with an exclusion list, and its own restore by rename | ADR 0051's complete, unexcluded backup copy and its restore transition |
| Closed record inventory checked at open | Current replay's `invalid_private_history` and ADR 0070's retired-catalogue refusal |
| Prior builds tested as they are, and a restored root opened by the prior build | Retired by the pre-1.0 rule |
| Restored root needing no `daemon prepare-index` step | ADR 0070 deleted the step; offline commands write the one catalogue |

**Marker.** One small regular file at a fixed name in the state root. It
holds the root format and its version and nothing else, as plain bytes. It is
written under the placement lock, before any other write, with an exclusive
temporary, `fsync`, rename and directory `fsync`, and at the same point
whoever creates the root: chat, an offline command or the daemon.

Every command that opens a root reads it first, before the placement lock, the
Store's writer marker, `Log.prepare_path` and any torn-tail repair:

1. An empty or absent root directory is new: create it and write the marker.
2. A nonempty root without the marker refuses as an unsupported root.
3. A marker naming another format or version refuses as an unsupported root.
4. Otherwise opening continues; replay's existing record refusals still apply.

No command adds a marker to an existing unmarked root. ADR 0051's restore
copies the marker with every other file, so a restored root is marked
exactly as its backup was.

**Backup.** `loopex store backup ROOT BACKUP`:

1. Checks the marker, then refuses while the placement lock or the Store's
   writer marker is held, and refuses a remaining helper `objects.writer`
   marker as an unclean stop, using the classes daemon startup already uses.
2. Prints the root, the target and the entry count, then proceeds.
3. Performs the capture steps of the
   [operator runbook](../operator/runtime.md#operator-runtime-backup-capture):
   removes each disposable `delegation/RUNTIME/job-index-v1` cache, then
   records the cut, the state root's and every Local ledger's placement and
   generation digest, the original workspace reference and the prior restore
   lineage.
4. Writes the backup directory beside its final name and publishes it by
   rename. A failed run leaves nothing at the final name.

```text
BACKUP/
  state/       the complete copy ADR 0051 restores from (its backup_state_root)
  manifest     the exact canonical manifest bytes of the source at the cut
  capture      the capture record: format version, producing build and
               source identity, manifest SHA-256, cut, placements, ledger
               descriptors, workspace reference, prior lineage count and digest
```

The copy follows ADR 0051's complete-copy profile. Its rules on modes, syncs,
links, special files and link counts apply unchanged, and the backup's
canonical manifest must equal the captured one. Backup never decodes or
repairs a record. The configuration file is outside the root and is not
copied; the runbook tells the operator to keep it with the backup. The backup
is excluded from ordinary startup.

**Restore.** `loopex store restore BACKUP DESTINATION`:

1. Refuses a destination that exists and is nonempty, and any path layout ADR
   0051 refuses.
2. Builds ADR 0051's plan from the capture record. The operator states the
   source branch explicitly, available or lost, and how old authority ended,
   joined or by host reboot. The host attestation is the operator's statement,
   made by those explicit choices; the command never infers latestness or
   exclusion from hashes.
3. Calls `LoopexComposition.Restore.restore/2`, prints the outcome, and for
   `commit_unknown` or unconfirmed cleanup prints the transaction identity and
   the command that re-presents it. Re-presenting goes through `lookup/3` and
   the same plan.
4. Never rewrites the home's configuration. After a committed restore it
   prints the destination for the operator to select through ADR 0037's
   writer.

**Diagnostics.** ADR 0037's diagnostic command reports the marker and its
version, whether the root is held, and the backup format version this build
writes. It does not scan session history. The unreadable-session identifier
comes from the running service's readiness report under ADR 0037, which
carries ADR 0046's refusal: a session identifier for `invalid_history`,
`history_unavailable` or `session_absent`, and a code with no session for a
store or runtime that is unavailable. It resolves no credential and prints no
record content.

**Open before acceptance.**

- The marker's file name and exact bytes, and how the empty-root case treats
  a directory the operator created in advance.
- The refusal classes and exit statuses for an unsupported root and for each
  command's refusals.
- The capture record's encoding and its exact fields against ADR 0051's plan.
- The operator grammar for the source branch and the termination statement,
  and whether `joined` may be stated when only a free placement lock and an
  absent writer marker are observed. The recommendation is to require the
  explicit statement and record it in the capture or restore output.
- Whether `store restore` refuses `lost` unless a separate flag confirms that
  the operator has checked the original path is absent.

<a id="technical-adr-0072-evidence"></a>
### Evidence

Concept: [Observable consequences](0072-store-readiness-marker-backup-and-restore.md#concept-adr-0072-consequences).

M8 must prove:

- marker write ordering under the placement lock, with a kill before and
  after the rename, for each command that can create a root;
- a nonempty unmarked root, an unknown marker and a retired-catalogue root
  each refused by every root-opening command, with the root's complete
  manifest unchanged afterward, including no writer marker and no lock file;
- backup refused on a held root and on a remaining writer marker; backup of a
  stopped root whose canonical manifest equals an independent walk of the
  source;
- restore of that backup returning a committed receipt into an empty root,
  with the restored root started by the service and serving the same sessions;
- restore refused on a nonempty destination, a changed backup and a held
  source, and a process kill during restore resolved by re-presenting the
  same transaction;
- the closed-root case: a root with one unreadable session history, the
  service's readiness report naming it, and restore of an earlier backup
  reopening admission;
- the installed demonstration's backup and restore under the installed
  artifact.

Store conformance, ADR 0051's restore suites and the process and store fault
matrix run unchanged.

<a id="technical-adr-0072-compatibility"></a>
### Compatibility Mechanics and Alternatives

Concept: [Compatibility and rollback](0072-store-readiness-marker-backup-and-restore.md#concept-adr-0072-compatibility).

Before 1.0 the marker, the backup layout and the capture record each keep
only their current version. A build refuses another version rather than
reading it. An unsupported root is recovered by restoring a backup under the
build that wrote it. That loses work done after the backup and is never
described as opening the root.

When ADR 0036's engine ships, its migration reads a marked local root through
the marker check. ADR 0036's text still describes this record's earlier
archive; whether migration writes its retired source as one of these backups
is restated when M9 is planned.

**Alternatives rejected.**

- *An archive format and restore of this record's own.* They would duplicate
  ADR 0051's transition and contradict its complete, unexcluded manifest.
- *A single-file archive around the backup.* ADR 0051 restores from a
  directory on the same machine; a packer adds a dependency and an
  extraction step without adding recovery.
- *Restore by copying the backup into place.* ADR 0016 and ADR 0051 refuse
  activation of a copied root; only the transition installs fresh ledger
  generations.
- *A separate record inventory checked at open.* Replay already refuses
  unknown kinds; a second inventory would drift from it.
- *No marker, with a full decode before any write.* It reads the log twice and
  still leaves the non-Store members, ledgers and catalogues unchecked.
- *Marking existing roots in place.* That is an upgrade, which the pre-1.0
  rule retires.
- *Keeping this work inside ADR 0036.* It blocks backup and restore on an
  engine experiment whose result they do not use.
- *Per-session quarantine instead of restore.* Accepted ADR 0046 chose
  whole-root restore; revisiting that waits for evidence that operators meet
  the case.
- *Backing up a live root.* A consistent copy of a root with an active writer
  needs a snapshot protocol the local adapter does not have.
