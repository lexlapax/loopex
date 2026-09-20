<a id="concept"></a>
## Concept

Technical depth: [Daemon-grade store mechanics](0031-daemon-grade-store-selection-and-migration-technical.md#technical-depth).

- **Status:** Proposed
- **Date:** 2026-09-14
- **Decision owner:** Maintainer
- **Supersedes:** nothing; refines the store posture in vision §12.2
- **Prerequisite for:** M5 acceptance, for the local-adapter selection and
  its documented limits; the successor milestone that adopts the daemon-grade
  adapter, for the selection experiment and migration

<a id="concept-adr-0031-decision"></a>
### Context and Decision

The local Store that M1 through M4 use is one append-only framed log per
state root, replayed in full at every open, held by one operating-system
process through a writer marker, with a hard capacity, no compaction and no
session index. That is exactly right for a foreground process that owns one
session at a time and exits with it. The vision's reference daemon runs on
an ADR-selected store, and a service makes operational claims that the
bootstrap adapters were never asked to make: bounded replay, an index, a
migration pair with interrupted-migration recovery, backup and restore, and
a stated oldest binary that may reopen a migrated root. The vision freezes
the store contract, not an engine, and says adapters are selected by
evidence.

This ADR decides two things at two times.

**For M5, select the existing local adapter as the daemon's store.** The
daemon holds the local writer marker for its process's lifetime and inherits
the adapter's exact, documented limits: one append-only log per state root
with a hard 256 MiB capacity, a 4 MiB frame ceiling, full-history retention
with no compaction, full replay at open, and one writer per root. Reaching
capacity is a truthful refusal, never a silent loss: the adapter answers
`store_capacity_exceeded`, the daemon refuses further mutation with that
reason while observers stay attached and an orderly stop still succeeds, and
the operator retires the root by stopping the daemon, moving the root aside
and starting a fresh root. Sessions in a retired root are resumable only by
reopening that root. This is a bounded, experimental selection made on
evidence the local adapter already carries; it is not a daemon-grade store,
and the 0.2.0 daemon's operator documentation states these limits and the
retirement procedure. The maintainer chose this on 2026-09-14 over deferring
the ADR entirely: the reference daemon needs a recorded store selection even
when the selected adapter is the existing one, and documenting the ceilings
makes the durable-service claim truthful without adding an engine.

**For the successor milestone, decide the selection procedure now and let its
evidence fix the engine before that milestone's acceptance.** The
daemon-grade store is a new adapter, `loopex_store_daemon`, behind the
unchanged private session Store ports. After M5 closes and the successor's
opening gate is refreshed red on that closed base, isolated, disposable
contract experiments on separate task roots compare a BEAM-native segmented
log and a SQLite-backed NIF adapter against the same conformance and
fault-injection suites. Neither experiment becomes product implementation,
enters that milestone's Open candidate, or integrates to `main`. This pair is
then revised to name the selected engine, both exact experiment revisions and
their measured evidence before independent review and acceptance of those
exact bytes. The current recommendation is the BEAM-native adapter because it
avoids a compiled dependency and VM-level NIF risk while reusing proven local
framing and repair; these are hypotheses to test, not a categorical veto of
SQLite. Any candidate that fails a required fault case is ineligible.

Migration is one-way and explicit: the successor's daemon imports a local log
written by the M4 foreground server, the reference CLI or the M5 daemon into
its own root, retains the original untouched beside it as the rollback pair,
records every step so an interrupted import is detected and completed or
rolled back on the next open, and stamps the new root with a format version.
Every previous release binary must safely refuse that root with its existing
error; it cannot report a version it does not know. No in-place rewrite and
no silent upgrade on first open.

Technical depth: [Contract and evidence](0031-daemon-grade-store-selection-and-migration-technical.md#technical-adr-0031-decision).

<a id="concept-adr-0031-consequences"></a>
### Consequences, Compatibility and Rollback

The daemon and its clients see the same durable session truth the embedded
API and the foreground server see; the store adapter is a host choice, not a
semantic one. In M5 the foreground server, the reference CLI and the daemon
all run on the local adapter and can reopen one another's roots. A root that
reaches the local log's capacity stops accepting mutation and is retired by
the operator; nothing already committed is lost. The private journal format
is a separate compatibility surface: adding an adapter later freezes no wire,
artifact or embedded contract, and the exact private format stays
experimental in 0.x.

M5 rollback is stopping the daemon: the foreground server and CLI reopen the
same root under the same placement identity. Successor rollback is the
retained original local log plus the previous binary. A previous binary
cannot open the daemon-grade root; when pointed at that directory, its
existing local reader returns `store_file_invalid`, without claiming to
understand the new format. The selected successor daemon binary is the oldest
reader of the daemon-grade root. The imported original is never modified, so
restoring it is a copy, not a reverse migration. Backup is a quiescent copy
of the root verified by the adapter's own integrity check; restore reopens
that copy under the same placement identity.

Technical depth: [Compatibility mechanics](0031-daemon-grade-store-selection-and-migration-technical.md#technical-adr-0031-compatibility).

## Governance Record

| Decision | Authority | Authority evidence | Bound bytes |
| --- | --- | --- | --- |
| Acceptance | — | — | — |
