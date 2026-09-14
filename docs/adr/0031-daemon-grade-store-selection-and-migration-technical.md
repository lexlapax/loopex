<a id="technical-depth"></a>
## Technical depth

Concept: [Daemon-grade store selection and migration](0031-daemon-grade-store-selection-and-migration.md#concept).

<a id="technical-adr-0031-decision"></a>
### Contract and Evidence

Concept: [Context and decision](0031-daemon-grade-store-selection-and-migration.md#concept-adr-0031-decision).

### Boundary

`loopex_store_daemon` implements the same private port set `Loopex.Store`
already fixes for the local adapter: `transact/2`, `transaction_status/4`,
`runtime_command/2`, `ownership_head/3`, `load_records/4` and
`load_events/4`, plus the snapshot store and load calls the port declares.
It changes no callback arity or result shape; ADR 0006 owner epochs and
incarnation identities remain the commit-authority fence and the writer
marker remains physical writer exclusion. The public protocol, the embedded
API and every public event are unchanged by the adapter choice.

### Candidate one: BEAM-native segmented log

- One root directory per state root with a `manifest` file naming the format
  version `loopex_store_daemon_v1`, the placement identity the root was
  created under, and the migration ledger.
- One append-only frame log per session, reusing the local adapter's
  length-prefixed, digest-checked frame and its sync-after-commit rule, so a
  torn tail is detected and truncated at the last complete frame exactly as
  today.
- Private and public snapshots written every N private records or M seconds,
  whichever first, each naming the journal version and public sequence it
  covers; open replays only records after the newest verified snapshot, so
  replay is bounded by the snapshot interval rather than session age.
- A session index file listing session identity, source and fork lineage,
  genesis and tombstone state and the last known public sequence, rebuilt from
  the logs when absent or inconsistent rather than trusted.
- The local adapter's writer marker held for the whole root, with the same
  liveness probe and the same `store_writer_active` and
  `store_writer_unverifiable` refusals.

### Candidate two: SQLite through a NIF binding

One database per state root with tables for sessions, private records,
public outbox rows, snapshots and idempotency; transactions through the
engine's journal; the same port mapping. It is evaluated on the same suite
with three additional obligations: the NIF's failure containment (a crash or
a blocked scheduler is a VM-level risk the native candidate does not carry),
its packaging (a compiled dependency joins the version train and the release
archive), and its behaviour under the same torn-write and kill fixtures.

### Selection evidence

Before this decision is accepted, both candidates run:

- the shared store conformance suite that the local and in-memory adapters
  already pass, unchanged;
- fault injection at every commit cut: kill between frame write and sync,
  between sync and acknowledgement, and during snapshot write; a torn last
  frame; a corrupt middle frame; a missing or corrupt index; a marker left by
  a dead writer;
- commit-ambiguity resolution: a `transact` whose acknowledgement was lost is
  resolved by `transaction_status` to exactly one outcome;
- bounded replay: open time and memory grow with the snapshot interval, not
  with session length, measured on a session with at least one hundred
  thousand records;
- backup and restore: a quiescent copy reopens with every session identity and
  public sequence intact and the integrity check clean.

The maintainer selects the adapter at acceptance on that evidence. Selection
does not itself accept M5; M5 accepts only with this ADR accepted.

### Migration

Supported pair: local adapter format `loopex_store_writer_v2` log to
`loopex_store_daemon_v1` root. The import reads the original log through the
local adapter's own reader, writes per-session logs and the index into a new
root, records `started`, `session <id> imported`, `verified` and `completed`
in the manifest's migration ledger with the source log digest, and refuses to
serve until `completed` is present. Reopen after interruption reads the
ledger: a root without `completed` is either resumed from the last recorded
session or discarded and restarted, both without touching the source log. The
original log is never modified, moved or deleted by the import.

An M4 binary opening a `loopex_store_daemon_v1` root refuses with
`store_format_unsupported` naming the version it found and the newest it can
read. A daemon binary opening a local log serves it only through explicit
import; it never upgrades in place.

### Evidence and alternatives

Tests cover forward migration of a genuine M4 session log with identical
replay afterwards, interruption at each ledger step with detection on reopen,
the previous binary's refusal, and backup and restore. Mnesia and DETS were
rejected: DETS carries a two-gigabyte table limit and no tail-repair story,
and Mnesia's schema is VM-global state that contradicts the runtime-instance
rule. A hosted PostgreSQL adapter remains a later choice under the same ports
and is not evaluated here.

<a id="technical-adr-0031-compatibility"></a>
### Compatibility and Rollback Mechanics

Concept: [Consequences and rollback](0031-daemon-grade-store-selection-and-migration.md#concept-adr-0031-consequences).

The private journal is a separate compatibility surface and stays experimental
in 0.x; the adapter adds no public event, snapshot field, wire method or
embedded function. Rollback is the retained original log plus the previous
binary, which is a copy back, not a reverse migration. Backup is a quiescent
copy of the root plus the adapter's integrity check; restore reopens the copy
under the same placement identity and refuses a placement mismatch exactly as
resume does today.

Acceptance binds this complete pair at an exact candidate. Its evidence and
compatibility claims remain unproved until the M5 gate's required paths execute.
