<a id="technical-depth"></a>
## Technical depth

Concept: [Daemon-grade store selection and migration](0031-daemon-grade-store-selection-and-migration.md#concept).

<a id="technical-adr-0031-decision"></a>
### Contract and Evidence

Concept: [Context and decision](0031-daemon-grade-store-selection-and-migration.md#concept-adr-0031-decision).

### M5 selection: the local adapter and its limits

The M5 daemon opens the state root through `loopex_store_local` exactly as
the foreground server does, and holds its writer marker from before the
socket is bound until the daemon process exits. The adapter's limits are the
daemon's limits, and every one is an existing constant or refusal of
`Loopex.Store.Local.Log`:

- one append-only, length-prefixed, digest-checked log per state root, held
  by one operating-system process through the writer marker with the
  `store_writer_active` and `store_writer_unverifiable` refusals;
- a hard log capacity of 256 MiB (`@max_log_bytes`): the size admission at
  `Loopex.Store.Local.Log.append/3` refuses with `store_capacity_exceeded`
  before the log is opened for writing, and a log already larger than the
  bound refuses at open with `store_log_too_large`;
- one consequence of that refusal, which the daemon inherits and must state:
  `Loopex.Store.Local` treats every `append` error alike. The refusal falls
  through the `commit_new` clause to `{:stop, reason, commit_unknown, state}`,
  so the Store process terminates and the caller is told `commit_unknown`.
  Physically nothing was written; contractually the transaction is ambiguous
  and the store is gone. The daemon therefore cannot keep observers attached
  past a capacity refusal, and does not claim to: it closes the listener and
  every connection and exits, naming the capacity. Changing that would be a
  change to the adapter's own contract, which this ADR does not make;
- a 4 MiB frame ceiling (`@max_frame_bytes`) on any single record;
- full-history retention: no compaction, no retention cutoff, and full replay
  at every open, so replay time and memory grow with the root's history until
  the root is retired;
- stale-writer recovery off by default. `:recover_stale_writer` defaults to
  `false` in `Loopex.Store.Local` and in `LoopexComposition`, so a marker left
  by a daemon that was killed refuses every later open with
  `store_writer_active` until something asks for recovery. The daemon asks for
  it explicitly, which is what makes kill-and-restart work, and inherits the
  adapter's discipline unchanged: the marker is reclaimed only where its own
  recorded holder is probed and found dead, an unverifiable holder leaves the
  marker in place with `store_writer_unverifiable`, and a live holder refuses
  with `store_writer_active`;
- session discovery through the existing session directory beside the log.
  That directory is plain files, not Store truth: `Loopex.SessionDirectory`
  says so itself, and a host writes an entry after `create_session/3` commits,
  so a process that dies in between leaves a session the Store holds and the
  directory does not. Nothing is lost — the Store remains the authority and
  the session is reached by its ID — but no enumeration built on the directory
  may claim to list every session the root contains, and the daemon's index
  does not.

Root retirement is an operator procedure, not a store operation: stop the
daemon so the marker is released; move the root directory aside under a name
of the operator's choosing; start the daemon on a fresh root with the same
placement identity source. A session in a retired root is resumed only by
stopping the daemon and reopening that root, with the daemon or the
foreground server. The daemon's operator documentation states the capacity,
the refusal reason, the frame ceiling, full retention and this procedure.

Evidence for the M5 selection is the M5 plan's Outcome 1 obligation, not a
second copy here: a root driven to the capacity ceiling refuses the append
with the store's own reason and takes the daemon's listener and connections
down with it, a root already past the bound refuses at open, a stale marker is
recovered where its holder is proved dead and refused where it is not, and
after an orderly stop the foreground server reopens the same root. No new
conformance evidence is required, because the adapter and its suites are
unchanged.

### Boundary

`loopex_store_daemon`, the successor's adapter, implements the same private
port set `Loopex.Store` already fixes for the local adapter: `transact/2`,
`transaction_status/4`, `runtime_command/2`, `ownership_head/3`,
`load_records/4` and `load_events/4`, plus the snapshot store and load calls
the port declares. It changes no callback arity or result shape; ADR 0006
owner epochs and incarnation identities remain the commit-authority fence and
the writer marker remains physical writer exclusion. The public protocol, the
embedded API and every public event are unchanged by the adapter choice.
Neither core nor `loopex_store_local` depends on the adapter, and the
daemon's controller lease stays in daemon memory under ADR 0033; no adapter
stores a lease.

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

After M5 closes, both candidates run in separate disposable branches and
worktrees. The experiments may build only the adapter slices and fixtures
necessary to measure this decision; they do not merge to `main` or become
accepted product bytes. Both run:

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
results in the decision packet. The winner, both experiment SHAs, its
evidence and any packaging cost are then written into a new ADR that declares
`Supersedes: 0031` for this successor half, not into these bytes: once this
pair is accepted as an M5 prerequisite it is anchored, and its one Acceptance
row already binds the M5 local-adapter selection. That successor ADR is
independently reviewed and accepted on its own. Selection does not itself
accept the successor milestone. Product implementation of the adapter starts
only after that successor ADR and that milestone's plan are accepted.

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
the daemon-grade root directory as an invalid store file and returns its
existing `store_file_invalid` reason. It cannot name `loopex_store_daemon_v1`
or advertise a maximum format it never implemented. The successor daemon
reader validates the root manifest version and refuses unknown versions
explicitly; it is the oldest reader of this new root. A daemon binary opening
a local log serves it only through explicit import; it never upgrades in
place.

### Evidence and alternatives

Successor tests cover forward migration of a genuine local session log with
identical replay afterwards, interruption at each ledger step with detection
on reopen, safe refusal by the exact previous binary with its actual reason,
and backup and restore. Mnesia and DETS were rejected: DETS carries a
two-gigabyte table limit and no tail-repair story, and Mnesia's schema is
VM-global state that contradicts the runtime-instance rule. A hosted
PostgreSQL adapter remains a later choice under the same ports and is not
evaluated here. Deferring this ADR entirely from M5 was rejected on
2026-09-14: the daemon still needs a recorded selection, and the local
adapter's ceilings are a fact the operator must be told rather than an
absence of decision.

<a id="technical-adr-0031-compatibility"></a>
### Compatibility and Rollback Mechanics

Concept: [Consequences and rollback](0031-daemon-grade-store-selection-and-migration.md#concept-adr-0031-consequences).

In M5 no journal format changes; the daemon, the foreground server and the
CLI reopen one another's roots, and rollback is stopping the daemon. The
private journal is a separate compatibility surface and stays experimental
in 0.x; the successor adapter adds no public event, snapshot field, wire
method or embedded function. Successor rollback is the retained original log
plus the previous binary, which is a copy back, not a reverse migration.
Backup is a quiescent copy of the root plus the adapter's integrity check;
restore reopens the copy under the same placement identity and refuses a
placement mismatch exactly as resume does today.

Acceptance of the M5 selection binds this pair at the exact candidate the
maintainer names in the governance record, and that is the only disposition
this pair carries. The successor selection is a separate disposition on a
separate ADR that supersedes this one's successor half, recorded the same way
once its experiment evidence exists; this pair is not edited again.
