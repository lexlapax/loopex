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
behind the unchanged private Store ports. Two candidates run the same shared
store conformance suite and the same fault-injection suite before this
decision is accepted: a BEAM-native segmented-log adapter that keeps one
append-only log per session under a root manifest, writes periodic private and
public snapshots so replay is bounded, keeps a small session index, and reuses
the local adapter's frame, sync and writer-marker discipline; and a
SQLite-backed adapter through a NIF binding, evaluated for the same properties
plus packaging and VM-safety risk. The recommendation is the BEAM-native
adapter, because it adds no external runtime dependency, no NIF that can block
or crash the VM, and no packaging cost, and because the local adapter's
framing and repair code is proven; the maintainer chooses at acceptance on the
measured evidence, and a candidate that fails a fault case is not chosen.

Migration is one-way and explicit: a daemon imports an M4-era local log into
its own root, retains the original untouched beside it as the rollback pair,
records every step so an interrupted import is detected and completed or
rolled back on the next open, and stamps the root with a format version that
the previous binary refuses with a stable reason. No in-place rewrite and no
silent upgrade on first open.

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

Rollback is the retained old root plus the old binary. A daemon-grade root is
not readable by an M4 binary, and the store says so instead of pretending; the
imported original is never modified by the import, so restoring it is a copy,
not a reverse migration. Backup is a quiescent copy of the root verified by
the adapter's own integrity check; restore reopens that copy under the same
placement identity.

Technical depth: [Compatibility mechanics](0031-daemon-grade-store-selection-and-migration-technical.md#technical-adr-0031-compatibility).

## Governance Record

| Decision | Authority | Authority evidence | Bound bytes |
| --- | --- | --- | --- |
| Acceptance | — | — | — |
