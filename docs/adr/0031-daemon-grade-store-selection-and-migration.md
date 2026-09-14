<a id="concept"></a>
## Concept

Technical depth: [Daemon-grade store mechanics](0031-daemon-grade-store-selection-and-migration-technical.md#technical-depth).

- **Status:** Proposed
- **Date:** 2026-09-14
- **Decision owner:** Maintainer
- **Supersedes:** nothing; refines the store posture in vision §12.2
- **Prerequisite for:** M5 acceptance

<a id="concept-adr-0031-decision"></a>
### Context and Decision

The local Store that M1 through M4 use is one append-only framed log per
path, replayed in full at every open, held by one operating-system process
through a writer marker, with no session index and no snapshot-bounded replay.
That is exactly right for a foreground process that owns one session at a
time and exits with it. A daemon that owns session lifetime for every session
in a state root, stays up for days, serves several client processes and lists
sessions on request needs what the vision's store posture names: bounded
replay, writer fencing that survives its own crash, torn-write repair,
corruption made visible, an index, a migration pair with interrupted-migration
recovery, backup and restore, and a stated oldest binary that may reopen a
migrated root. The vision freezes the store contract, not an engine, and says
adapters are selected by evidence.

Decide the selection procedure now and let its evidence fix the engine before
acceptance. The daemon-grade store is a new adapter, `loopex_store_daemon`,
behind the unchanged private session Store ports. After M4 closes and M5's
opening gate is refreshed red on that closed base, isolated, disposable
contract experiments on separate task roots compare a BEAM-native segmented
log and a SQLite-backed NIF adapter against the same conformance and
fault-injection suites. Neither experiment becomes M5 product implementation,
enters the Open M5 candidate, or integrates to `main`. The Proposed pair is
then revised to name the selected engine, both exact experiment revisions and
their measured evidence before independent review and acceptance of those
exact bytes. The current recommendation is the BEAM-native adapter because it
avoids a compiled dependency and VM-level NIF risk while reusing proven local
framing and repair; these are hypotheses to test, not a categorical veto of
SQLite.
Any candidate that fails a required fault case is ineligible.

The daemon's durable controller leases use a separate private daemon-control
storage surface. Its first implementation lives in the minimal
`loopex_store_daemon` application while the existing local adapter supplies
session truth; the selected daemon-grade session adapter later implements the
same lease transition contract. The daemon acquires exclusive ownership of
the state root before opening either storage surface. No lease operation is
added to the accepted session Store transaction algebra or written into a
session journal.

Migration is one-way and explicit: a daemon imports an M4-era local log into
its own root, retains the original untouched beside it as the rollback pair,
records every step so an interrupted import is detected and completed or
rolled back on the next open, and stamps the new root with a format version.
The exact M4 binary must safely refuse that root with its existing error;
it cannot report a version it does not know. No in-place rewrite and no silent
upgrade on first open.

Technical depth: [Contract and evidence](0031-daemon-grade-store-selection-and-migration-technical.md#technical-adr-0031-decision).

<a id="concept-adr-0031-consequences"></a>
### Consequences, Compatibility and Rollback

The daemon and its clients see the same durable session truth the embedded
API and the M4 foreground server see; the store adapter is a host choice, not
a semantic one. The foreground server and the reference CLI keep working on
the local adapter, and either may run on the daemon-grade adapter. The private
journal format is a separate compatibility surface: adding an adapter freezes
no wire, artifact or embedded contract, and the exact private format stays
experimental in 0.x.

Rollback is the retained original local log plus the old binary. An M4 binary
cannot open the daemon root; when pointed at that directory, its existing local
reader returns `store_file_invalid`, without claiming to understand the new
format. The selected M5 daemon binary is the oldest reader of the daemon root.
The imported original is never modified, so restoring it is a copy, not a
reverse migration. Backup is a quiescent copy of the root verified by the
adapter's own integrity check; restore reopens that copy under the same
placement identity.

Technical depth: [Compatibility mechanics](0031-daemon-grade-store-selection-and-migration-technical.md#technical-adr-0031-compatibility).

## Governance Record

| Decision | Authority | Authority evidence | Bound bytes |
| --- | --- | --- | --- |
| Acceptance | — | — | — |
