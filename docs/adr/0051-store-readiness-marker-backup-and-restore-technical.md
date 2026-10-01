<a id="technical-depth"></a>
## Technical depth

Concept: [Store readiness: marker, reader boundary, backup and restore](0051-store-readiness-marker-backup-and-restore.md#concept).

<a id="technical-adr-0051-decision"></a>
### Contract

Concept: [Context and decision](0051-store-readiness-marker-backup-and-restore.md#concept-adr-0051-decision).

**What stays fixed.** The `Loopex.Store` behaviour, its transactions and
result unions, `Loopex.Store.Local`'s record format and ceilings, the placement
lock and writer marker rules ADRs 0031 and 0032 fixed, and core's dependency
list. Marker, backup and restore are host and adapter code. Core gains no
callback for them.

**Marker.** One small versioned file in the local adapter's root, written
with an exclusive temporary, `fsync`, rename and directory `fsync`. It names
the container format and its version and nothing else. It is written under
the placement lock by the first candidate process that opens the root for
writing, before any other write. A crash before the rename leaves a legacy
root; a crash after it leaves a marked root; both are valid. Its file name and
exact bytes are fixed before acceptance.

**Reader boundary.** At open, in this order and before any write:

1. Read the marker. An unknown format or version refuses with a named class.
2. A missing marker identifies a legacy container only.
3. Check durable-record support against the candidate's closed inventory. The
   inventory is the delivered
   [M7 compatibility inventory](../plans/M7-technical.md#technical-plan-compatibility)
   plus every earlier supported record: child sessions, receipts,
   continuation, command revisions, immutable selections, checkpoints,
   maintenance request, attempt and settlement records, and version-3
   settlements with their monotonic cutover.
4. A record outside the inventory refuses with a named class that identifies
   the session and record kind without printing record content.

The local adapter replays in full at open, so the check adds no second pass.
It reads through the adapter's own reader, never a private copy of the format.

**Backup.** `loopex store backup <root> <archive>`:

1. Refuses while the placement lock or writer marker is held, with the classes
   daemon startup already uses.
2. Prints the root, the target and the inventory size, then proceeds.
3. Writes one archive beside its final name and publishes it by rename. A
   failed run leaves no archive at the final name.
4. Includes a manifest naming the archive-format version, the container
   marker, the producing source commit, and every file with its root-relative
   path, size and SHA-256.

**Inventory.**

| Included | Excluded, rebuilt after restore |
| --- | --- |
| Store log and its records | Daemon socket, placement lock and writer marker |
| Artifact objects | The daemon's listing index (ADR 0032) |
| M7 host ledger and role snapshots | The helper job-index cache |
| Child sessions | Helper-history coverage entries |
| The container marker | Bounded diagnostics and trace output |

The host ledger is outside `Loopex.Store`. Backup copies it byte for byte at
its root-relative path and passes it to no Store decoder. Because coverage
entries are excluded, the first start after a restore performs ADR 0046's
resumable helper-history classification again. The configuration file is not
part of the root and is not archived; the runbook tells the operator to keep
it with the backup.

**Restore.** `loopex store restore <archive> <root>`:

1. Refuses a target that exists and is nonempty, or that any process holds.
2. Verifies the manifest and every digest in a temporary sibling directory.
3. Publishes the root with one rename. A failed or interrupted run leaves no
   root at the target name, and a rerun converges.
4. Writes root-relative paths only; an entry that escapes the target, a link,
   or an entry absent from the manifest refuses the whole archive.

The restored root is an ordinary root layout. It needs no installed layout to
open, so a prior source build can open a restored root it supports.

**Diagnostics.** ADR 0037's diagnostic command reports the marker and its
version, whether the root is held, the archive-format version this build
writes, and, when durable admission is closed by an unreadable history, the
session identifier from ADR 0046's refusal. It resolves no credential and
prints no record content.

**Open before acceptance.**

- The marker's file name and exact bytes.
- The archive container and its format version.
- The inventory's exact record list against delivered M7.
- The named refusal classes and their exit statuses.
- Whether artifact objects larger than a stated bound are streamed or
  refused, with the bound.

<a id="technical-adr-0051-evidence"></a>
### Evidence

Concept: [Observable consequences](0051-store-readiness-marker-backup-and-restore.md#concept-adr-0051-consequences).

M8 must prove:

- marker write ordering under the placement lock, with a kill before and
  after the rename;
- an unknown format, an unknown version and an out-of-inventory record each
  refused before any write, on roots with and without a marker;
- a legacy M6 root and an M7 root with the complete compatibility inventory
  opened by the candidate with no record changed;
- backup refused on a held root; backup of a closed root whose manifest
  matches an independent walk of the inventory;
- restore refused on a nonempty target, on a digest mismatch, on an escaping
  path and on an unlisted entry; an interrupted restore converging on rerun;
- restored record order and digests identical to the source, host ledger and
  role snapshots byte-identical at their relative paths, caches rebuilt;
- the closed-root case: a root with one unreadable session history, the
  diagnostic naming it, and restore of an earlier backup reopening admission;
- the upgrade case in the M8 plan: the pre-upgrade backup restored by the
  candidate's tool and opened by the prior build.

Store conformance and the process and store fault matrix run unchanged.

<a id="technical-adr-0051-compatibility"></a>
### Compatibility Mechanics and Alternatives

Concept: [Compatibility and rollback](0051-store-readiness-marker-backup-and-restore.md#concept-adr-0051-compatibility).

Retain exact prior builds to test their real behavior. Never claim an old
build emits a new refusal class or honors a marker it never understood. An
unsupported downgrade restores a pre-upgrade backup with a matching reader; it
loses later facts and is never described as reopening the newer root.

When ADR 0036's engine ships, its migration reads a marked local root through
this reader boundary and retires the source under an archive name this
restore command accepts. That join is ADR 0036's to state.

**Alternatives rejected.**

- *Keeping readiness inside ADR 0036.* It blocks backup and restore on an
  engine experiment whose result they do not use.
- *Per-session quarantine instead of restore.* It needs a durable exclusion
  record, a helper-ledger rule for a quarantined parent or child and a
  recovery path back. Accepted ADR 0046 chose whole-root restore; revisiting
  that waits for evidence that operators meet the case.
- *Backing up a live root.* A consistent copy of a root with an active writer
  needs a snapshot protocol the local adapter does not have.
- *Marking by migration.* A marker that required rewriting records would turn
  an upgrade into a migration with its own interrupted-import matrix.
- *Archiving derived caches.* They would need their own compatibility
  promise, and they are rebuilt from records by accepted rules.
