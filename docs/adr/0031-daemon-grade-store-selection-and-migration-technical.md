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
API and every public event are unchanged by the adapter choice. Neither core
nor `loopex_store_local` depends on the adapter, and the daemon's controller
lease stays in daemon memory under ADR 0033; this adapter stores no lease.

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
- The root-scoped daemon writer marker held for the whole root, using the
  local adapter's liveness-probe discipline and the same
  `store_writer_active` and `store_writer_unverifiable` refusals.

### Candidate two: SQLite through a NIF binding

One database per state root with tables for sessions, private records,
public outbox rows, snapshots and idempotency; transactions through the
engine's journal; the same port mapping. Both candidates use a root manifest
with format version, placement identity and migration ledger; SQLite keeps its
session index as database lookup state rather than a separate index file. It
is evaluated on the same suite with three additional obligations: the NIF's
failure containment (a crash or
a blocked scheduler is a VM-level risk the native candidate does not carry),
its packaging (a compiled dependency joins the version train and the release
archive), and equivalent crash and corruption outcomes under its own journal
and database file format.

### Selection experiment and evidence

After M5 closes and the successor milestone's refreshed opening gate is
established red on that closed base, both candidates run in separate
isolated, disposable contract branches and task roots. The experiments may
build only the adapter slices and fixtures necessary to measure this
decision; they do not enter that milestone's Open candidate, integrate to
`main`, become accepted product bytes, or claim an inherited-gate result for
the milestone branch. The gate-first checkpoint permits bounded contract
experiments only after the one-lookahead planning restriction ends with M5
closure. Both run:

- the shared store conformance suite that the local and in-memory adapters
  already pass, unchanged;
- common semantic fault cut points: kill before durable commit, after durable
  commit but before acknowledgement, and during snapshot or checkpoint write;
  corrupt or incomplete durable bytes, missing or corrupt derived lookup state,
  and a marker left by a dead writer. Each candidate uses physical injections
  appropriate to its representation and proves the same Store-level recovery
  or refusal outcomes. The native candidate additionally runs literal torn
  last frame, corrupt middle frame, and missing or corrupt session-index
  fixtures; SQLite runs its corresponding database and journal corruption and
  index-rebuild fixtures. The decision packet records the exact injection and
  observed outcome for each candidate and cut point;
- commit-ambiguity resolution: a `transact` whose acknowledgement was lost is
  resolved by `transaction_status` to exactly one outcome;
- bounded replay: open time and memory grow with the snapshot interval, not
  with session length, measured on a session with at least one hundred
  thousand records;
- backup and restore: a quiescent copy reopens with every session identity and
  public sequence intact and the integrity check clean.

Record each experiment's exact candidate SHA, commands, platform and measured
results in the decision packet. Revise this still-Proposed ADR pair to name the
winner, both experiment SHAs, its evidence and any packaging cost;
independently review that candidate before the maintainer accepts it.
Selection does not itself accept the successor milestone. Product
implementation starts only after this ADR and that milestone's plan are
accepted.

### Migration

Supported pair: local adapter format `loopex_store_writer_v2` log, as the M4
foreground server, the reference CLI and the M5 daemon write it, to
`loopex_store_daemon_v1` root. The import reads the original log through the
local adapter's own reader, writes each session and derived lookup state through
the selected adapter into a new root, records `started`,
`session <id> imported`, `verified` and `completed`
in the manifest's migration ledger with the source log digest, and refuses to
serve until `completed` is present. Reopen after interruption reads the
ledger: a root without `completed` is either resumed from the last recorded
session or discarded and restarted, both without touching the source log. The
original log is never modified, moved or deleted by the import.

Every previous local-reader binary, the M5 daemon release included, treats
the daemon root directory as an invalid store file and returns its existing
`store_file_invalid` reason. It cannot name `loopex_store_daemon_v1` or
advertise a maximum format it never implemented. The successor daemon reader
validates the root manifest version and refuses unknown versions explicitly;
it is the oldest reader of this new root. A daemon binary opening a local log
serves it only through explicit import; it never upgrades in place.

### Evidence and alternatives

Tests cover forward migration of a genuine local session log with identical
replay afterwards, interruption at each ledger step with detection on reopen,
safe refusal by the exact previous binary with its actual reason, and backup
and restore. Mnesia and DETS were rejected: DETS carries a two-gigabyte table
limit and no tail-repair story, and Mnesia's schema is VM-global state that
contradicts the runtime-instance rule. A hosted PostgreSQL adapter remains a
later choice under the same ports and is not evaluated here.

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
compatibility claims remain unproved until the adopting milestone's gate
executes its required paths.
