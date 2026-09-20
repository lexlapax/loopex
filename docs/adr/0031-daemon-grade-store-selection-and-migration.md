<a id="concept"></a>
## Concept

Technical depth: [Daemon-grade store mechanics](0031-daemon-grade-store-selection-and-migration-technical.md#technical-depth).

- **Status:** Proposed
- **Date:** 2026-09-14
- **Decision owner:** Maintainer
- **Supersedes:** nothing; refines the store posture in vision §12.2
- **Prerequisite for:** M5 outcomes 1 and 5, accepted before the daemon opens
  a state root — that is, before M5's workstream 1 lands — for the
  local-adapter selection and its documented limits. Its successor half binds
  nothing in M5; see the note on supersession below.

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
capacity is a truthful stop, never a silent loss, and it is not survivable on
this adapter. The append is refused before a byte is written, with
`store_capacity_exceeded`; the adapter then terminates its Store process and
the caller receives `commit_unknown` for that transaction, because that is
what this adapter does with every append error. So the daemon meets capacity
as a loss of the store, not as a recoverable refusal: it closes the listener
and every connection and exits, naming the capacity in the close, and the
operator retires the root. A log already past the bound is refused at open as
`store_log_too_large` rather than opened and truncated. Nothing committed is
lost and nothing false is recorded, which is what the truthfulness claim
means here. Sessions in a retired root are resumable only by reopening that
root.
This is a bounded, experimental selection made on
evidence the local adapter already carries; it is not a daemon-grade store,
and the 0.2.0 daemon's operator documentation states these limits and the
retirement procedure. The maintainer chose this on 2026-09-14 over deferring
the ADR entirely: the reference daemon needs a recorded store selection even
when the selected adapter is the existing one, and documenting the ceilings
makes the durable-service claim truthful without adding an engine.

**For the successor milestone, decide the selection procedure now and let its
evidence fix the engine before that milestone's acceptance.** The
daemon-grade store is a new adapter, `loopex_store_daemon`, behind the
unchanged private session Store ports. After M5 closes, isolated, disposable
contract experiments in their own worktrees compare a BEAM-native segmented
log and a SQLite-backed NIF adapter against the same conformance and
fault-injection suites. Neither experiment becomes product implementation or
merges to `main`. The current recommendation is the BEAM-native adapter
because it avoids a compiled dependency and VM-level NIF risk while reusing
proven local framing and repair; these are hypotheses to test, not a
categorical veto of SQLite. Any candidate that fails a required fault case is
ineligible.

**Where the selection is recorded.** Not here. Once this pair is accepted as
an M5 prerequisite its bytes are anchored: a decision is replaced additively,
by a successor that declares `Supersedes: 0031`, and the predecessor stays
exactly as accepted. This pair's single Acceptance row binds one disposition,
and that disposition is the M5 local-adapter selection. So the successor
milestone's engine, the two exact experiment revisions, their measured
evidence and the migration are recorded in a **new ADR superseding this one's
successor half**, proposed when the experiments have run and accepted on its
own review. What this pair decides now, and all it decides now, is the M5
selection and the procedure the successor's experiments must follow; nothing
in the successor half binds M5.

**Alternatives rejected.** Deferring this decision out of M5 entirely was
rejected on 2026-09-14: the reference daemon still needs a recorded store
selection, and the local adapter's ceilings are a fact the operator must be
told rather than an absence of decision. Building the daemon-grade adapter
inside M5 was rejected because it doubles the milestone's evidence — a new
engine, its fault matrix, its migration and its rollback — without adding a
proved capability to the durable-service question M5 exists to answer.
Raising or removing the local log's 256 MiB capacity to postpone retirement
was rejected because a silently growing log trades a truthful refusal for an
unbounded replay at open. Changing the local adapter so that a capacity
refusal is definite and survivable — answered as a plain refusal without
terminating the Store, so a daemon could keep its observers attached and stop
in an orderly way — was rejected for M5 on 2026-09-19. It is a change to the
Store's own behaviour at the one point where that behaviour is most
load-bearing: today every append error is commit-ambiguous, and separating one
error class from the rest means proving, through the shared conformance suite
and the fault matrix on every adapter, that the separated class is definite in
every injection and that no other class quietly joins it. That is the
successor adapter's evidence, and buying it here would double M5's store
evidence to make one operator message nicer. Until then the daemon's capacity
behaviour is the adapter's, stated plainly rather than promised away. Mnesia and DETS were rejected as successor
candidates for the reasons the companion records.

**Evidence its acceptance requires.** The M5 half is a durability claim, so
its class is process and store fault injection on the real adapter plus a
rollback proof: a root driven to capacity refuses the append with the store's
own reason, terminates the store, and the daemon closes the listener and every
connection and exits naming the capacity, with nothing committed lost; a root
already past the bound refuses at open; and after an orderly stop on a root
below the bound the foreground server and reference CLI reopen it. No new
conformance evidence is required, because the adapter and its suites are
unchanged — which is the point of selecting it. The successor half claims a new engine and a migration,
so its class is the full store conformance suite, the fault matrix, bounded
replay measurement, backup and restore, forward migration with interrupted-
import recovery, and safe refusal by the exact previous binary; none of it is
owed before the successor milestone's acceptance.

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
reaches the local log's capacity takes its daemon down with it and is retired
by the operator; nothing already committed is lost, and the operator
documentation says plainly that capacity is an outage rather than a
degradation, so that the ceiling is planned for rather than discovered. The private journal format
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
