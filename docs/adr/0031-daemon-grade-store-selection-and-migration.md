<a id="concept"></a>
## Concept

Technical depth: [Daemon-grade store mechanics](0031-daemon-grade-store-selection-and-migration-technical.md#technical-depth).

- **Status:** Proposed
- **Date:** 2026-09-14
- **Decision owner:** Maintainer
- **Supersedes:** nothing; refines the store posture in vision §12.2
- **Prerequisite for:** the successor milestone that adopts the daemon-grade
  store; not M5, which runs its daemon on the local adapter under the
  revision the [M5 plan](../plans/M5.md#concept) records

<a id="concept-adr-0031-decision"></a>
### Context and Decision

The local Store that M1 through M4 use is one append-only framed log per
path, replayed in full at every open, held by one operating-system process
through a writer marker, with no session index and no snapshot-bounded replay.
That is exactly right for a foreground process that owns one session at a
time and exits with it, and it is enough for the first daemon: M5's daemon
holds that marker for the root's lifetime, recovers by full replay, and lists
sessions from the existing session directory. A daemon whose root has grown
over days of use, that serves many sessions and lists them on request, needs
what the vision's store posture names beyond that: bounded replay, an index,
a migration pair with interrupted-migration recovery, backup and restore, and
a stated oldest binary that may reopen a migrated root. The vision freezes the
store contract, not an engine, and says adapters are selected by evidence.

Decide the selection procedure now and let its evidence fix the engine before
the successor milestone's acceptance. The daemon-grade store is a new adapter,
`loopex_store_daemon`, behind the unchanged private session Store ports. After
M5 closes and the successor's opening gate is refreshed red on that closed
base, isolated, disposable contract experiments on separate task roots compare
a BEAM-native segmented log and a SQLite-backed NIF adapter against the same
conformance and fault-injection suites. Neither experiment becomes product
implementation, enters that milestone's Open candidate, or integrates to
`main`. The Proposed pair is then revised to name the selected engine, both
exact experiment revisions and their measured evidence before independent
review and acceptance of those exact bytes. The current recommendation is the
BEAM-native adapter because it avoids a compiled dependency and VM-level NIF
risk while reusing proven local framing and repair; these are hypotheses to
test, not a categorical veto of SQLite. Any candidate that fails a required
fault case is ineligible.

Migration is one-way and explicit: a daemon imports a local log written by
the M4 foreground server, the reference CLI or the M5 daemon into its own
root, retains the original untouched beside it as the rollback pair, records
every step so an interrupted import is detected and completed or rolled back
on the next open, and stamps the new root with a format version. Every
previous release binary must safely refuse that root with its existing error;
it cannot report a version it does not know. No in-place rewrite and no silent
upgrade on first open.

Technical depth: [Contract and evidence](0031-daemon-grade-store-selection-and-migration-technical.md#technical-adr-0031-decision).

<a id="concept-adr-0031-consequences"></a>
### Consequences, Compatibility and Rollback

The daemon and its clients see the same durable session truth the embedded
API and the foreground server see; the store adapter is a host choice, not a
semantic one. The foreground server, the reference CLI and the M5 daemon keep
working on the local adapter, and any of them may later run on the
daemon-grade adapter. The private journal format is a separate compatibility
surface: adding an adapter freezes no wire, artifact or embedded contract, and
the exact private format stays experimental in 0.x.

Rollback is the retained original local log plus the previous binary. A
previous binary cannot open the daemon root; when pointed at that directory,
its existing local reader returns `store_file_invalid`, without claiming to
understand the new format. The selected successor daemon binary is the oldest
reader of the daemon root. The imported original is never modified, so
restoring it is a copy, not a reverse migration. Backup is a quiescent copy
of the root verified by the adapter's own integrity check; restore reopens
that copy under the same placement identity.

Technical depth: [Compatibility mechanics](0031-daemon-grade-store-selection-and-migration-technical.md#technical-adr-0031-compatibility).

## Governance Record

| Decision | Authority | Authority evidence | Bound bytes |
| --- | --- | --- | --- |
| Acceptance | — | — | — |
