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
   plus every earlier supported record, including receipts, continuation,
   command revisions, immutable selections, checkpoints, maintenance request,
   attempt and settlement records, and version-3 settlements with their
   monotonic cutover. Child sessions are ordinary sessions and need no
   separate entry.
4. A record outside the inventory refuses with a named class that identifies
   the session and record kind without printing record content.

The check reads through the adapter's own reader, never a private copy of the
format. Whether the adapter's existing replay at open already decodes every
record kind, so that the check adds no second pass, is confirmed against the
delivered adapter before acceptance.

**Backup.** `loopex store backup <root> <archive>`:

1. Refuses while the placement lock or writer marker is held, with the classes
   daemon startup already uses.
2. Prints the root, the target and the inventory size, then proceeds.
3. Writes one archive beside its final name and publishes it by rename. A
   failed run leaves no archive at the final name.
4. Includes a manifest naming the archive-format version, the container
   marker, the producing source commit, and every file with its root-relative
   path, size and SHA-256.

**Inventory.** The archive holds every regular file under the root except the
excluded list. It is defined by exclusion so that a directory a later change
adds is archived by default.

| Archived, among everything else under the root | Excluded |
| --- | --- |
| Store log, sessions and runtime-control records | The daemon socket |
| Artifact objects | The placement lock and writer marker |
| The local executor's receipt ledger | Temporary files of an interrupted atomic write |
| Private continuation and recovery state | |
| Resource packs and catalogs | |
| The daemon's session index (`daemon/session-index-v1`) | |
| M7's host ledger, role snapshots, job index and coverage entries | |
| The container marker and bounded diagnostic output | |

Backup passes no file to a decoder; it copies bytes. Entries that are derived
caches, such as the helper job index and coverage entries, are archived as
they are and revalidated at the next start by ADR 0046's existing rules. The
session index is archived because ADR 0032 does not rebuild it: a root with
sessions and no index refuses to start until `loopex daemon prepare-index` is
run, and a restore must not introduce that step. The exact excluded names are
fixed before acceptance against the delivered root layout. The configuration
file is outside the root and is not archived; the runbook tells the operator
to keep it with the backup.

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
version, whether the root is held, and the archive-format version this build
writes. It does not scan session history. The unreadable-session identifier
comes from the running service's readiness report under ADR 0037, which
carries ADR 0046's refusal: a session identifier for `invalid_history`,
`history_unavailable` or `session_absent`, and a code with no session for a
store or runtime that is unavailable. It resolves no credential and prints no
record content.

**Open before acceptance.**

- The marker's file name and exact bytes.
- The archive container and its format version.
- The inventory's exact record list against delivered M7.
- The exact excluded file names against the delivered root layout.
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
- a supported M6 root and an M7 root with the complete compatibility
  inventory opened by the candidate with no record changed;
- backup refused on a held root; backup of a closed root whose manifest
  matches an independent walk of the root minus the excluded list;
- restore refused on a nonempty target, on a digest mismatch, on an escaping
  path and on an unlisted entry; an interrupted restore converging on rerun;
- every archived file byte-identical at its relative path after restore;
- a restored root started by the service with no `prepare-index` step, and a
  deliberately stale derived entry discarded by its existing validation;
- the closed-root case: a root with one unreadable session history, the
  service's readiness report naming it, and restore of an earlier backup
  reopening admission;
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
this reader boundary. This restore accepts only a manifest-bearing archive
whose every entry is listed, so a source directory that migration merely
renames is not something it restores. Whether migration writes its retired
source as this archive format is ADR 0036's to state.

**Alternatives rejected.**

- *Keeping readiness inside ADR 0036.* It blocks backup and restore on an
  engine experiment whose result they do not use.
- *An inclusion list.* A list of what to archive silently omits whatever a
  later change adds under the root, and an omitted durable file is lost
  without a refusal.
- *Excluding derived caches and the session index.* The index is not rebuilt
  automatically, and excluding caches forces a rescan the backed-up root did
  not need.
- *Per-session quarantine instead of restore.* It needs a durable exclusion
  record, a helper-ledger rule for a quarantined parent or child and a
  recovery path back. Accepted ADR 0046 chose whole-root restore; revisiting
  that waits for evidence that operators meet the case.
- *Backing up a live root.* A consistent copy of a root with an active writer
  needs a snapshot protocol the local adapter does not have.
- *Marking by migration.* A marker that required rewriting records would turn
  an upgrade into a migration with its own interrupted-import matrix.
