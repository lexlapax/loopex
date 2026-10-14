<a id="technical-depth"></a>
## Technical depth

Concept: [Current-format marker and operator backup and restore](0072-store-readiness-marker-backup-and-restore.md#concept).

<a id="technical-adr-0072-decision"></a>
### Contract and Ownership

Concept: [Context and decision](0072-store-readiness-marker-backup-and-restore.md#concept-adr-0072-decision).

**What stays fixed.** The `Loopex.Store` behaviour, its transactions and
result unions, `Loopex.Store.Local`'s record format, log and frame ceilings
(`log.ex` `@max_log_bytes` 256 MiB, `@max_frame_bytes` 4 MiB), the placement
lock (`LoopexComposition.Placement`, `placement.lock` inside the root) and the
writer marker (`Loopex.Store.Local.WriterLock`, `store.log.writer`, record
`loopex_store_writer_v2`). ADR 0051's signatures, invocation schema,
canonical manifest, lineage records, limits, cleanup cutoffs, refusal codes
and outcomes are used as accepted. Its plan schema is used as accepted except
for the one alternative `host_attestation` form the
[amendment](#technical-adr-0072-amendment) adds. Core (`apps/loopex`) gains no
callback, module or dependency. Every piece below is host code in
composition, the Local executor's restore codec, the CLI and the daemon.

**What this record no longer decides.**

| Earlier proposal | Now |
| --- | --- |
| Backup archive with an exclusion list, and its own restore by rename | ADR 0051's complete, unexcluded backup copy and its restore transition |
| Closed record inventory checked at open | Current replay's `invalid_private_history` and ADR 0070's retired-catalogue refusal |
| Prior builds tested as they are, and a restored root opened by the prior build | Retired by the pre-1.0 rule |
| No marking of an existing unmarked root | Superseded by the maintainer's `store adopt` decision; adoption decodes and changes no record |

**Module ownership.** Paths are relative to the repository root.

| Piece | Module | App | New or existing |
| --- | --- | --- | --- |
| Marker constants, `check/1`, `admit/1`, `report/1`, marker publication | `LoopexComposition.RootFormat` (`lib/loopex_composition/root_format.ex`) | `loopex_composition` | New |
| Marker check before the placement lock | `LoopexComposition.Placement.acquire/2`, first step | `loopex_composition` | Existing, changed |
| Marker check before composition starts a Store | `LoopexComposition.compose/1`, before `RestoreGuard.state/1` | `loopex_composition` | Existing, changed |
| Closed-root checks, adopt, backup, restore plan construction and continuation; closed result maps, no printing | `LoopexComposition.StoreAdmin` (`lib/loopex_composition/store_admin.ex`) | `loopex_composition` | New |
| Capture, attestation and continuation record codec | `LoopexComposition.StoreAdmin.Codec` | `loopex_composition` | New |
| Read-only inventory and audit of a live root path; whole-tree backup copy | Two operations added to `LoopexComposition.Restore.IO`: `{:root_inventory, root, manifest, workspace_ref, mode}` and `{:backup_copy, root, staging_state, manifest}` | `loopex_composition` | Existing guardian, new operations |
| Session-identifying failure of the audit | `LoopexComposition.Restore.Audit` and `Restore.IO.audit_store_bytes/1` return the failing session identifier privately; `restore/2`'s public results are unchanged | `loopex_composition` | Existing, changed |
| `store backup|restore|adopt` grammar, output, exit statuses | `LoopexCli.Store` (`lib/loopex_cli/store.ex`), dispatched from `LoopexCli.dispatch/2` as `"store"` | `loopex_cli` | New |
| Marker check for read-only commands (`sessions`, `artifact`) | `LoopexCli` before `SessionCatalog.list/1` and `LoopexComposition.artifacts/1` | `loopex_cli` | Existing, changed |
| Daemon exit statuses for marker refusals | `LoopexDaemon.ExitStatus`, `LoopexDaemon.Service.acquire_placement/1` | `loopex_daemon` | Existing, changed |
| Discard-later-work attestation form of the ADR 0051 plan | `Loopex.Executor.Local.RestoreCodec` (`apps/loopex_executor_local/lib/restore_codec.ex`), its `attestation` grammar | `loopex_executor_local` | Existing, changed |
| Refusal of the discard form with an available source | The plan validation in `LoopexComposition.Restore.Workflow` (`lib/loopex_composition/restore/workflow.ex`) | `loopex_composition` | Existing, changed |
| Unreadable-session code kept by helper classification | `LoopexComposition.Delegation.Helper` (`classify_sessions/4`, `classify_session/4`), `LoopexComposition.Delegation.incomplete/1` | `loopex_composition` | Existing, changed |

The `store` commands compose no runtime, so `LoopexCli` removes the provider
credential before they run, as it does for every non-composing command. No
command in this record reads a credential, starts a provider, or prints record
content.

<a id="technical-adr-0072-marker"></a>
### Marker Path, Bytes, Write Procedure and Check

Concept: [The current-format marker](0072-store-readiness-marker-backup-and-restore.md#concept-adr-0072-marker).

**Path and states.** `STATE_ROOT/loopex-root-format`, a regular file of mode
`0600`. This build writes exactly two contents, one per marker state:

```text
current   (21 bytes)  loopex-root-format 1\n
          hex: 6c 6f 6f 70 65 78 2d 72 6f 6f 74 2d 66 6f 72 6d 61 74 20 31 0a
adopting  (30 bytes)  loopex-root-format 1 adopting\n
          hex: the first 20 bytes above, then 20 61 64 6f 70 74 69 6e 67 0a
```

The marker grammar is closed:

```text
marker   = "loopex-root-format " version [ " adopting" ] LF
version  = %x31-39 *8DIGIT        ; 1 to 9 digits, no leading zero
```

Version `1` without the suffix is `current`; version `1` with the suffix is
`adopting`; any other version, with or without the suffix, is an unknown
format carrying its digits; bytes outside the grammar are an unknown format
`"unrecognized"`. The marker carries nothing else: no build, path, time,
host or adoption identifier. The backup capture record carries the producing
build instead. Only `store adopt` writes the `adopting` form, and only adopt
replaces an existing marker; every other writer publishes `current` into a
new root by no-replace link and never changes an existing marker.

**Marker temporaries.** A temporary is a regular file named
`loopex-root-format.tmp-` followed by exactly 32 lowercase hexadecimal
characters, 16 random bytes from `:crypto.strong_rand_bytes/1`. The name
prefix is the only ownership rule: every marker temporary is disposable,
regardless of age or creator, and whoever removes one tolerates `:enoent`.

**Publication** (`RootFormat`, private `publish/2`, taking the root and the
state to publish), the same no-replace discipline as
`Loopex.SessionDirectory`'s `runtime_id`:

1. If the root path is absent, create it and any missing ancestors with
   `File.mkdir_p/1` (process umask, as `Placement.acquire/2` does today), then
   `fsync` each newly created directory's parent, bottom-up.
2. Open the temporary `[:write, :exclusive, :raw, :binary]`, set mode `0600`
   with `:prim_file.write_file_info/2`, write the state's bytes,
   `:file.sync/1`, close.
3. `File.ln(temporary, marker)`. Hard-link creation never replaces: `:ok`
   publishes; `{:error, :eexist}` reads the existing marker and returns its
   classification (Check step 4) to the caller, which decides; `{:error,
   :enoent}` on the temporary (a concurrent cleaner removed it) re-runs
   `check/1` and returns its answer.
4. `fsync` the root directory, remove the temporary (tolerating `:enoent`),
   `fsync` the root directory again, then read the marker back.

**Read-back** (Publication step 4, and the same rule wherever a publisher
verifies the marker). List the root's marker temporaries, recording each
one's device and inode from `File.lstat/1`, and only then `File.lstat/1` and
read the marker. Require a regular file, mode `0600`, the exact bytes of the
requested state, and `nlink` either 1, or 2 with exactly one listed temporary
on the marker's device and inode. That second name can only be the temporary
of the publisher that won the link and has not yet removed it: once the
marker exists every later link attempt fails with `:eexist`, so the names of
the marker's inode only decrease, and a listing taken before the `lstat` can
only overcount them. Any other `nlink` returns
`{:root_marker_write_failed, root, :readback}`.

A publisher therefore never requires `nlink` 1. `nlink` 1 is required only
by ADR 0051's manifest, which refuses a regular file with `nlink` other than
1. Both commands that take that manifest of a live root, backup and adopt,
first run the cleanup below, so the marker's `nlink` is 1 when they take it;
a temporary created after the cleanup changes the next manifest and refuses
as a changed root. A backup's `state/` therefore holds no temporary, and
restore copies it unchanged.

A failure at any step returns `{:root_marker_write_failed, root, step}` with
`step` in `create_root`, `temporary`, `sync`, `link`, `directory_sync` or
`readback`, and removes only its own temporary.

**Check** (`RootFormat.check/1`, read-only, writes nothing):

1. `File.stat(root)`: `:enoent` returns `{:ok, :absent}`; a non-directory or
   any other error returns `{:state_root_unusable, root}`.
2. List the root's top-level entries. Ignore marker temporaries.
3. No marker entry: zero remaining entries returns `{:ok, :empty}`; otherwise
   `{:error, {:root_unmarked, root}}`.
4. A marker entry: `File.lstat/1` must report a regular file of at most 64
   bytes, else `{:error, {:root_marker_unreadable, root, :not_regular |
   :too_large}}`; a read error is `{:root_marker_unreadable, root,
   :read_failed}`. The bytes are classified by the grammar above: `current`
   returns `{:ok, :current}`; `adopting` returns `{:error, {:root_adopting,
   root}}`; another version returns `{:error, {:root_format_unknown, root,
   digits}}`; bytes outside the grammar return `{:error,
   {:root_format_unknown, root, "unrecognized"}}`.

**Cleanup of temporaries** (private `sweep/1`). Remove every top-level marker
temporary, tolerating `:enoent`, and `fsync` the root once if any was
removed. It runs only on a root whose marker is `current`, or inside adopt on
a root adopt has just fenced with `adopting`. Removing a temporary that
another publisher still holds is safe under every interleaving:

- not yet linked: that publisher's link fails `:enoent`, it re-runs
  `check/1`, sees `current` and succeeds;
- linked and not yet removed (publisher A paused between Publication steps 3
  and 4): the marker keeps its own name; A's removal gets `:enoent`, which it
  tolerates, and A's read-back sees `nlink` 1. A publisher B that loses the
  link to A meanwhile gets `:eexist`, reads `current`, removes its own
  temporary and passes read-back with `nlink` 2 and A's temporary listed, or
  with `nlink` 1 if A or a sweeper removed it first.

**Admit** (`RootFormat.admit/1`): `check/1`; `:absent` or `:empty` publishes
`current`, where `:eexist` with a `current` marker is success (a concurrent
creator) and any other classification is returned as its refusal; success
returns `{:ok, :created}`. `:current` runs `sweep/1` and returns
`{:ok, :current}`. Every error, `root_adopting` included, is returned
unchanged with nothing written. `sweep/1` on a current root is the only write
`admit/1` makes there; it clears the residue a crash between Publication
steps 3 and 4 leaves, including a temporary that is a second link to the
marker.

**Where it runs, in order.**

| Path | First root write today | Admit or check placed before it |
| --- | --- | --- |
| `Placement.acquire/2`, used by `run`, `resume`, `skill`, `chat`, durable `ask`, the daemon (`Service.acquire_placement/1`) and the app server (`Host`) | `File.mkdir_p!` of the root, then `placement.lock` | `admit/1` replaces the `mkdir_p!` as the first statement; its error becomes the returned refusal |
| `LoopexComposition.compose/1`, reached by every embedded or composed start including `cancel` (which takes no lock) | `File.mkdir_p(root)`, resource-pack retention, then `Store.Local` (`Log.prepare_path`, `WriterLock.acquire`, `repair_torn_tail`) | `admit/1` before `RestoreGuard.state/1` |
| `Loopex.runtime_placement_id/1` (`runtime_id` file) | Called only after `Placement.acquire/2` in the CLI, chat and daemon | Covered by the row above |
| `sessions` offline listing, `artifact` | No write intended; `Artifacts.open/1` may create directories | `check/1`; `:absent` or `:empty` keeps today's empty answer without creating anything; any error refuses |
| `store backup`, `store restore` (source and backup) | Their own steps below | `check/1`, never `admit/1`; `root_adopting` refuses |
| `store adopt` | Its own steps below | `check/1`, then the two-phase marker of the adopt section |
| Ephemeral `ask` | Its own temporary root, never reopened | Unchanged |

`store restore` never admits its destination: the destination must be empty
and receives the backup's own marker through ADR 0051's copy.

**Refusals and exit statuses.**

| Code | Meaning | Foreground commands | Daemon exit |
| --- | --- | --- | --- |
| `state_root_unusable` | Root exists and is not a usable directory | 1 | 66 (existing) |
| `root_unmarked` | Nonempty root without the marker | 1 | 116 |
| `root_format_unknown` | Marker names another format or version | 1 | 117 |
| `root_marker_unreadable` | Marker is not a regular file, exceeds 64 bytes or cannot be read | 1 | 118 |
| `root_marker_write_failed` | A new root's marker could not be published | 1 | 119 |
| `root_adopting` | Marker in its `adopting` form: an adoption started and has not completed | 1 | 124 |

ADR 0071 takes daemon statuses 111 to 115 and retires 114 before use; ADR
0073 takes 120 to 123. This record takes 116 to 119 and 124. The daemon's
assigned statuses are therefore 65 to 124 except 114: every integer in that
range other than 114 maps to exactly one class, and no class maps to 114.
`LoopexDaemon.ExitStatus` gains this record's five classes; its moduledoc
range and `fetch/1` spec extend through the highest assigned status. The
assertion in `apps/loopex_daemon/test/command_test.exs`, which today checks
`Enum.to_list(65..110)`, becomes the list of 65 to 124 without 114, each
used exactly once. `Service.acquire_placement/1` maps each class to
`{:fatal, class}`; the daemon's fatal line names the class, so
`root_adopting` is named on standard error as well as by its status.
Foreground commands print one line to standard error,
`loopex: CODE: SENTENCE`, where the sentences are:

- `root_unmarked`: `STATE_ROOT has files but no loopex-root-format marker; nothing was written. If a Loopex source build wrote it, run loopex store adopt; otherwise choose an empty directory.`
- `root_format_unknown`: `STATE_ROOT is format DIGITS; this build reads format 1. Restore a backup under the build that wrote it.`
- `root_marker_unreadable`: `STATE_ROOT/loopex-root-format cannot be read (REASON); nothing was written.`
- `root_marker_write_failed`: `the new root STATE_ROOT could not be marked (STEP).`
- `root_adopting`: `STATE_ROOT is being adopted and is not yet usable; nothing was written. Stop every process of the build that wrote it and run loopex store adopt --old-writer stopped again.`

<a id="technical-adr-0072-adopt"></a>
### Adopt Algorithm, Limits and Crash Safety

Concept: [Adopting a root the source build wrote](0072-store-readiness-marker-backup-and-restore.md#concept-adr-0072-adopt).

**Grammar.**

```text
loopex store adopt --old-writer stopped [--config FILE] [--state-root DIR] [--workspace DIR] [--work-ms N] [--cleanup-grace-ms N]
```

`--old-writer` is required and accepts only `stopped`: the operator's
statement that no process of the build that wrote the root, typically the M7
source build, is running or will start until adopt exits. That build does not
read the marker, so the statement is its only fence. A missing or other value
refuses `attestation_required` before any check, with nothing written. The
root and workspace are selected exactly as ADR 0037 selects them for the
service (`--state-root` > `LOOPEX_HOME` > the configuration file's
`/paths/state_root` > the installed home; `--workspace` > `/paths/workspace`),
and each value is printed with its origin. `--work-ms` defaults to 3,600,000
and `--cleanup-grace-ms` to 5,000; both are positive integers, passed as the
explicit limits ADR 0051's owned IO requires. They are this command's host
choices; ADR 0051's embedded API keeps no default.

**Algorithm** (`StoreAdmin.adopt/2`). Steps 1 to 5 write nothing. Step 6 is
the fence; from step 6 on, every exit except the success of step 12 leaves the
marker `adopting`.

1. Resolve the root and workspace to physical paths with
   `WorkspaceIdentity.resolve_path/1`; refuse a path that is not absolute
   UTF-8 without NUL, or longer than 8,192 bytes, as `usage`.
2. `RootFormat.check/1`: `:current` prints `already marked` and exits 0 with no
   write; `:absent` or `:empty` refuses `root_empty`; `root_unmarked` and
   `root_adopting` continue (the second is a rerun after a killed or refused
   adopt, which repeats every step and trusts nothing from the earlier run);
   any other error refuses with its code.
3. `STATE_ROOT/sessions` present as a directory refuses
   `session_catalog_retired`.
4. Closed-root checks (`StoreAdmin.closed/1`, shared with backup):
   `Placement.live_owner/1` returns `{:ok, pid}` → `root_held`; `:none` with
   `placement.lock` or any `placement.lock.owner-*` present → `root_unclean`;
   `{:error, _}` → `root_held`. `store.log.writer` present → `root_unclean`.
   Any `delegation/*/objects.writer` present → `root_unclean`. A socket or
   other special node at `daemon/daemon.sock` → `root_unclean`.
   `RestoreGuard.state/1` other than `{:ok, _}` refuses with its code
   (`source_retired`, `restore_incomplete`, `history_invalid`), which includes
   a restore claim beside the root.
5. `WorkspaceIdentity.reference/1` of the workspace; failure refuses
   `workspace_unavailable`.
6. **Fence.** On an unmarked root, publish the `adopting` marker
   (`RootFormat` Publication with state `adopting`). On `:eexist` an
   `adopting` marker continues (a concurrent adopt fenced first), a `current`
   marker prints `already marked` and exits 0, and any other classification
   refuses with its code. On a root already `adopting`, nothing is published.
   Then `sweep/1` removes every marker temporary, so the marker's `nlink` is 1
   for the manifest. From here every entry point of this build refuses the
   root as `root_adopting`.
7. Audit manifest A: `Restore.IO.run({:manifest, root, 2^64 - 1}, limits)`.
   A includes the `adopting` marker entry. The manifest's own caps apply:
   65,536 entries and 4 MiB encoded; beyond them refuse
   `inventory_limit_exceeded`.
8. Inventory and audit: `Restore.IO.run({:root_inventory, root, A,
   workspace_ref, :adopt}, limits)`. This runs ADR 0051's
   `Restore.Audit.complete/4` over the live root path with a draft plan whose
   descriptors it derives (see Backup step 7) inside the same owned worker. In
   `:adopt` mode, and only there, entries under `delegation/*/job-index-v1/`
   and the marker entry are removed from the index given to the audit; the
   job index is a disposable cache, is not decoded and is left on disk. The
   audit decodes every Store frame (`Log.decode_bytes/1`, requiring a complete
   tail), replays the Store (`State.replay/1`), recovers every session in
   sorted order (`SessionState.recover/3`), and validates every Local
   generation, marker, open entry and receipt, every artifact use and object,
   every resource record and every helper object and log. It stops at the
   first failure, which refuses with its inventory code.
9. Final manifest C; require C = A byte for byte, else `root_changed`.
10. Commit. Write a marker temporary holding the `current` bytes (Publication
    step 2), read the marker and require the exact `adopting` bytes (else
    `root_changed`), then `rename(temporary, marker)`, which atomically
    replaces `adopting` with `current`, and `fsync` the root.
11. Post-commit manifest D; require D = A with only the marker entry changed
    to `regular`, mode `0600`, size 21, `nlink` 1 and the `current` bytes'
    SHA-256. Otherwise put `adopting` back by the same temporary-and-rename
    step, `fsync` the root, and exit 2 with `root_changed`: another process
    wrote around the commit, and the operator must stop it, run `doctor` and
    rerun adopt.
12. Print `adopted STATE_ROOT as loopex-root-format 1` with the counts of
    sessions, Store frames, ledgers and artifact objects decoded. Exit 0.

**Inventory failure codes** reported by step 8, each with an optional detail:
`invalid_current_history` with the session identifier when a session's replay
failed, or the relative path of the failing member otherwise;
`store_log_torn`, which the command reports as `root_unclean`;
`workspace_mismatch` when a retained session genesis names a different
workspace than step 5's reference; `inventory_limit_exceeded`;
`inventory_mismatch`; `inventory_unavailable` for an IO error. The detail is
a bounded identifier or path, at most 8,192 bytes, never record content.

**Limits.** Everything ADR 0051's audit enforces: 65,536 manifest entries,
4 MiB manifest, 256 MiB Store log, 4 MiB frame, 2,048-byte generation,
65,536-byte receipts and Local records, 1,024-entry and 4 MiB open index,
1 MiB helper bindings, 16 MiB helper run logs, 256 runtime identifiers, 1,024
Stores and 128 ledgers.

**Crash safety, reruns and concurrent writers.** The marker moves only
absent → `adopting` (no-replace link, step 6) and `adopting` → `current`
(rename, step 10), plus the step 11 return to `adopting`. `current` is
written only after a complete audit of manifest A and a final manifest C
equal to A, so no root reaches `current` with a change the audit did not
read:

| Cut | Root left | Next invocation |
| --- | --- | --- |
| Refused before step 6 | Unchanged byte for byte; at most a temporary of an earlier run, which `check/1` ignores | Any 0.5.0 start refuses `root_unmarked`; adopt starts over |
| Killed before the step 6 link | Unmarked, at most one temporary | As above |
| Killed after the step 6 link, before or after the sweep | `adopting`, at most one temporary | Every entry point refuses `root_adopting`; adopt reruns the full audit |
| Concurrent writer after step 6, before manifest A | `adopting`; the write is in A and is audited, or is torn and refused by the audit | Refused or adopted only on the audited bytes |
| Concurrent writer after manifest A | `adopting`; C ≠ A refuses `root_changed` (exit 2) | Every entry point refuses `root_adopting`; adopt reruns from the start |
| Audit refusal (`invalid_current_history` and the other inventory codes) | `adopting` | Refused; recovered by a backup restored under the build that wrote it |
| Killed after the step 10 rename | `current`, audited and unchanged at C | Ordinary use; adopt reports `already marked` |
| Concurrent writer around the step 10 rename, observed by step 11 | `adopting` again; exit 2 `root_changed` | Every entry point refuses `root_adopting` |

The one window adopt cannot observe is a writer of the old build that runs
between manifest C and the end of manifest D while adopt is killed before
step 11 completes. The `--old-writer stopped` statement covers that window
and only that window; a 0.5.0 start in it is not unaudited history, because
it opens through the marker check and replay. Adopt never takes the placement
lock, because taking it writes into an unadopted root; steps 4, 9 and 11
detect a concurrent start instead. `doctor` reports `marker: adopting` for
every root left in that state.

<a id="technical-adr-0072-backup"></a>
### Backup Capture, Layout and Verification

Concept: [Backup](0072-store-readiness-marker-backup-and-restore.md#concept-adr-0072-backup).

**Grammar.**

```text
loopex store backup [--config FILE] [--state-root DIR] [--workspace DIR] [--work-ms N] [--cleanup-grace-ms N] BACKUP
```

Root, workspace and limits are selected as for adopt (adopt's `--old-writer`
statement excepted). `BACKUP` is required.

**No exclusion.** Backup copies every file of the root under ADR 0051's
complete manifest; it excludes nothing. Provider sign-in tokens stay out of
the copy because ADR 0037's
[separation invariant](0037-host-configuration-and-path-discovery-technical.md#technical-depth)
keeps the token directory physically outside every state root, not because
backup filters files. The disposable job-index cache removed at step 6 is
deleted from the source before the manifest, not left out of the copy.

**Layout.**

```text
BACKUP/                 mode 0700
  capture               0600  capture record, canonical ETF, at most 131,072 bytes
  manifest              0600  the exact canonical manifest bytes of the source at the cut
  state/                the complete copy; ADR 0051's backup_state_root; root mode as the source root
  restores/             0700, created by the first restore
    TX_ID/              0700, one per restore transaction
      plan              0600  exact canonical ADR 0051 plan bytes
      attestation       0600  canonical ETF attestation record
      continuation-N    0600  one per re-presentation, N = 1 to 1,024
```

**Capture record** (`loopex_store_backup_capture_v1`), a closed string-key map,
deterministic uncompressed ETF, decoded with `:erlang.binary_to_term(bytes,
[:safe])` and accepted only when re-encoding yields the same bytes, the
discipline of ADR 0051's private records:

```text
capture = {
 "kind": "loopex_store_backup_capture_v1",
 "root_format": 1,
 "producer_version": VERSION file contents, 1..64 bytes,
 "captured_at_ms": u64 system time, informational only,
 "cut_id": hex64,
 "manifest_sha256": hex64,
 "entry_count": 1..65536,
 "total_regular_bytes": u64,
 "source_state_root": absolute_path,
 "source_state_placement": placement,
 "prior_restore_count": 0..63,
 "prior_lineage_sha256": hex64,
 "runtime_ids": [...], "stores": [...], "ledgers": [...],
 "workspace": {"root": absolute_path, "workspace_ref": current_workspace_ref},
 "removed_caches": [relative_path], at most 256, sorted
}
```

`placement`, the descriptor lists and `workspace` use ADR 0051's exact grammar.
`cut_id` is the SHA-256 hex of `<<"loopex:store-backup-cut:v1", 0,
manifest_sha256, nonce>>` with a 32-byte random nonce, so two captures of the
same bytes have distinct cuts.

**Procedure** (`StoreAdmin.backup/3`).

1. Resolve root, workspace and `BACKUP` to physical paths. `BACKUP` must be
   absent (`backup_exists`), its parent an existing directory, and `BACKUP`,
   the root and the workspace pairwise distinct and nonnested, with existing
   ancestors free of symlinks after resolution (`backup_path_invalid`).
2. `RootFormat.check/1` must be `:current`; `:absent` or `:empty` refuse
   `root_empty`; errors refuse with their code.
3. `StoreAdmin.closed/1` as in adopt step 4. A torn tail is found at step 7.
4. `RestoreGuard.state/1` gives the prior restore count (0 for an ordinary
   root, else the committed ordinal); count 64 refuses
   `inventory_limit_exceeded`, because ADR 0051 refuses transition 65.
5. Print `backing up STATE_ROOT (format 1, closed) to BACKUP; workspace
   WORKSPACE; limits WORK_MS/GRACE_MS`, then proceed without a prompt.
6. Remove each `delegation/*/job-index-v1` directory, recursively, then `fsync`
   its parent. Remove marker temporaries (`RootFormat.admit/1` on a current
   root). These are the only source writes.
7. Manifest A. Derive the descriptors from A and the root, by the rules ADR
   0051's audit checks: `stores` is `[%{"relative_path" => "store.log",
   "sha256" => A's entry}]` when `store.log` exists, else `[]`; `ledgers` is
   every directory `R` with both `R/markers` and `R/open` directories, sorted,
   each with `executor_identity` decoded from `R/generation` by
   `RestoreCodec.decode(:generation, _)`, `source_generation_sha256` of those
   bytes, and `source_placement` from `File.lstat/1` of the source ledger
   directory; `runtime_ids` is the sorted unique union the audit computes from
   the replayed Store. `prior_lineage_sha256` is
   `RestoreCodec.lineage_digest/1` of A's `.loopex-restore` and
   `restore-lineage` entries. The source placement is the root's physical
   path with `major_device` and `inode` from `File.lstat/1`.
8. Stage `BACKUP`'s parent `/.NAME.loopex-backup-HEX32` (mode `0700`) and run
   `Restore.IO.run({:backup_copy, root, STAGING/state, A}, limits)`. It creates
   directories top-down at `0700`, copies each regular entry with the existing
   `{:copy_file, ...}` primitive (exclusive create, exact mode reapplied after
   the last write, file `fsync`, close, digest check), then sets each
   directory's exact mode and `fsync`s directories bottom-up. Symlinks, special
   nodes and regular files with `nlink` other than 1 refuse, as ADR 0051's
   manifest does.
9. Manifest B of the source and C of `STAGING/state`; require A = B = C, else
   `source_changed` (B) or `inventory_mismatch` (C). A root holding a sticky
   bit fails here exactly as it fails restore today; Proposed ADR 0060 would
   lift both.
10. `Restore.IO.run({:root_inventory, STAGING/state, C, workspace_ref,
    :backup}, limits)` audits the copy as restore will; its descriptors must
    equal step 7's. Any failure refuses with the inventory code.
11. Build the capture record and the plan ADR 0051 would receive for a
    placeholder destination and attestation, and require
    `RestoreCodec.encode(:plan, _)` to succeed and the plan to be at most
    65,536 bytes; otherwise `inventory_limit_exceeded`. No published backup can
    be one restore refuses on size.
12. Write `capture` and `manifest` (exclusive, `0600`, `fsync`, close),
    `fsync` the staging directory, rename it to `BACKUP`, `fsync` the parent,
    and read back both files and the capture's digests.
13. Print `backup BACKUP: ENTRIES entries, BYTES bytes, manifest SHA, cut CUT`
    and the reminder that the configuration file and workspace contents are not
    included. Exit 0.

On any failure after step 8 the staging directory is removed; if removal
fails, the command prints its path and exits 1. Nothing ever exists at
`BACKUP` unless step 12 completed. The command never takes the placement lock:
its `placement.lock` and owner link would enter the manifest and refuse. A
service or command started during the backup writes its lock and is caught by
step 9.

<a id="technical-adr-0072-restore"></a>
### Plan Construction, Attestation, Checks and Output

Concept: [Restore](0072-store-readiness-marker-backup-and-restore.md#concept-adr-0072-restore).

**Grammar.**

```text
loopex store restore --source available|lost --old-writer stopped|rebooted
                     [--discard-later-work]
                     [--work-ms N] [--cleanup-grace-ms N] BACKUP DESTINATION
loopex store restore --resume TX_ID --previous-restore stopped|rebooted
                     [--work-ms N] [--cleanup-grace-ms N] BACKUP DESTINATION
```

`--source` and `--old-writer` have no default; either missing or misspelled
refuses `attestation_required` before any check. `--old-writer stopped` means
every process that used the root was stopped and seen to exit; `rebooted`
means the machine restarted since the root was last used. They map to ADR
0051's `old_authority_termination` `"joined"` and `"host_rebooted"`. Limits
default as for adopt. Restore takes no `--state-root`: its source is the one
the capture names.

`--discard-later-work` takes no value and has no negative form. It is the
operator's statement that the backup may predate work on the root and that
this work is abandoned. It is admitted only with `--source lost`; with
`--source available` the command refuses `discard_requires_lost_source`
before any check, because ADR 0051's available branch requires the source to
be unchanged since the cut and retires it. With `--resume` it is a `usage`
refusal: a re-presentation reuses the retained plan, which already carries the
statement. Without the flag the command is strict, as before: the operator
states the backup is the latest state, which the command cannot verify for a
lost source; ADR 0051 notes that a backup hash does not prove latestness.

**Checks, in order** (`StoreAdmin.restore/3`). Each refusal writes nothing.

1. Read `BACKUP/capture`; decode and re-encode it exactly
   (`backup_invalid`). Read `BACKUP/manifest`; its SHA-256 must equal the
   capture's (`backup_changed`). Manifest of `BACKUP/state` must equal those
   bytes (`backup_changed`). `RootFormat.check(BACKUP/state)` must be
   `:current` (its code otherwise).
2. Destination: absent, or an existing empty directory (`destination_not_empty`);
   parent an existing directory; destination, `BACKUP`, the source path and
   the workspace pairwise distinct and nonnested, with symlink-free existing
   ancestors (`destination_path_invalid`).
3. Workspace: `WorkspaceIdentity.reference/1` of the captured workspace root
   must equal the captured reference (`workspace_changed`).
4. Source, `--source available`: the captured path must exist
   (`source_absent`) and `RootFormat.check/1` be `:current`. Observe
   `Placement.live_owner/1`, `store.log.writer`, every helper
   `objects.writer` and the restore claim. A live placement holder, or a
   Store writer marker whose recorded holder `WriterLock`'s probe reports live,
   refuses `old_writer_running`. Every other observation, including a stale
   lock or marker, is only reported.
5. Source, `--source lost`: `File.lstat/1` of the captured path must return
   `{:error, :enoent}`; any other answer, including `:eacces`, refuses
   `source_not_absent` and names the answer.
6. Print the observations and the statements being made:

   ```text
   restore BACKUP (cut CUT, captured CAPTURED_AT) into DESTINATION
   source SOURCE: available|lost (stated); observed: placement lock free|stale|held,
     store writer marker absent|present, helper writer markers N, restore claim absent|present
   old writer: stopped|rebooted (stated). Observations are reported, not proof.
   you state: this backup is the latest state to keep; no other copy of the root
     will be used; work after the backup is lost; workspace contents are unchanged
   ```

   With `--discard-later-work` the last two lines are instead:

   ```text
   you state: work after this backup is discarded; its sessions, records and
     approvals are abandoned, and its external effects stand unrecorded and
     unreconciled; no other copy of the root will be used; workspace contents
     are left as they are, including changes made after the backup
   ```

**Plan construction.** `tx_id` is lowercase hex of 32 random bytes. The plan
is ADR 0051's version 1 map, filled entirely from the capture except:

| Field | Value |
| --- | --- |
| `tx_id` | as above |
| `source_status` | `--source` |
| `backup_state_root` | physical `BACKUP/state` |
| `destination_state_root` | physical `DESTINATION` |
| `host_attestation` | Without `--discard-later-work`: `latest_cut`, `no_post_cut_activity`, `all_other_copies_excluded` and `host_ledgers_validated` all `true` as the operator's statements. With it: the amendment's discard form, `discard_later_work` `true` in place of `latest_cut` and `no_post_cut_activity`, with the other members as before. In both: `old_authority_termination` from `--old-writer`; `evidence_sha256` the SHA-256 of the attestation record |

The invocation is `work_ms`, `cleanup_grace_ms`, `max_total_file_bytes` equal
to the capture's `total_regular_bytes`, `prior_admin_authority` `"none"` and
`prior_admin_evidence_sha256` nil.

**Attestation record** (`loopex_store_restore_attestation_v1`, canonical ETF,
at most 4,096 bytes):

```text
{"kind", "tx_id", "capture_sha256", "source_status", "old_writer",
 "discard_later_work": true | false,
 "observed": {"source_path": "present"|"absent",
              "placement": "free"|"stale"|"held"|"not_applicable",
              "store_writer_marker": "absent"|"present"|"not_applicable",
              "helper_writer_markers": 0..256,
              "restore_claim": "absent"|"present"|"not_applicable"},
 "invoker": {"os_pid": decimal string, "start_identity": 1..256 bytes},
 "producer_version", "recorded_at_ms": u64}
```

`start_identity` is what `Placement.process_incarnation/3` reports for the
command's own process. `discard_later_work` is `true` exactly when the flag was
given, and then the plan carries the discard form; `false` with the latest
form. A retained attestation and plan that disagree are `backup_invalid` on
`--resume`. The retained `attestation` and `plan` files are the durable record
that later work was deliberately discarded; they stay beside the backup.

**Retention, then one call.**

1. Create `BACKUP/restores/TX_ID/`, write `attestation` then `plan` (the exact
   `RestoreCodec.encode(:plan, _)` bytes) with exclusive create, `0600`,
   `fsync`, close, and `fsync` both directories. Failure refuses
   `backup_write_failed` and leaves no destination change.
2. Create `DESTINATION` at `0700` if absent and `fsync` its parent. ADR 0051's
   copy then sets the root's exact backed-up mode.
3. Call `LoopexComposition.Restore.restore(plan, invocation)` once.

**Output by outcome.**

| Result | Output | Exit |
| --- | --- | --- |
| `{:committed, receipt}` | `restored TX_ID ordinal N into DESTINATION`; then `Restore.lookup(DESTINATION, TX_ID, limits)`, which must answer committed and `current`; then the selection lines below | 0 |
| `{:not_committed, refusal}` | `not restored: CODE at PHASE; claim none|retained`. With `claim` retained, the re-presentation command below | 1 |
| `{:cleanup_unconfirmed, observation}` or `{:commit_unknown, observation}` | `restore TX_ID is unresolved: PHASE, intent INTENT, cleanup CLEANUP, reason REASON`, the instruction to keep every process away from the source, backup and destination, and the re-presentation command | 2 |

Selection lines, printed after a committed restore. The command never writes
the configuration file:

```text
to use the restored root, run:
  ADR_0037_STATE_ROOT_WRITER DESTINATION
```

`ADR_0037_STATE_ROOT_WRITER` is the exact command ADR 0037's accepted grammar
defines for setting `/paths/state_root`, produced by the same function ADR
0037's writer uses to name itself, so the printed text cannot drift from the
parser. When `LOOPEX_HOME` is set, or `--state-root` is in use, the command
adds that each takes precedence over the file and must name `DESTINATION`
instead. For an available source it adds that the old root is retired and will
refuse to open.

**Re-presentation.** `--resume TX_ID` reads `BACKUP/restores/TX_ID/plan`
exactly and decodes it (`backup_invalid` if it does not round-trip). It
probes every earlier invoker recorded in `attestation` and each
`continuation-N` with `Placement.process_incarnation/3`; one still alive
refuses `previous_restore_running`. It writes `continuation-N`
(`loopex_store_restore_continuation_v1`: `tx_id`, `n`, `previous_restore`, the
observed earlier invokers and their status `gone`, `alive` or
`unverifiable`, and its own invoker), then calls `restore/2` with the same plan
bytes and an invocation whose `prior_admin_authority` is `"joined"` for
`--previous-restore stopped` or `"host_rebooted"` for `rebooted`, and whose
`prior_admin_evidence_sha256` is that record's SHA-256. ADR 0051 resolves the
original transaction; a changed plan file answers `restore_conflict`. Before
calling, the command prints `Restore.lookup/3`'s answer for the destination.
Output and exits follow the table above.

<a id="technical-adr-0072-readiness"></a>
### Root Facts and Service Readiness Fields

Concept: [Readiness facts](0072-store-readiness-marker-backup-and-restore.md#concept-adr-0072-readiness).

**Root facts.** `RootFormat.report/1` is read-only and bounded. ADR 0037's
`doctor` calls it and prints its fields:

| Field | Values |
| --- | --- |
| `root` | the selected root's physical path |
| `marker` | `current`, `adopting`, `absent`, `empty`, `unmarked`, `unknown`, `unreadable`; `adopting` is printed with the instruction to stop the old build and rerun `store adopt --old-writer stopped` |
| `format` | `1` when current or adopting; the observed digits or `unrecognized` when unknown; absent otherwise |
| `marker_temporaries` | count, 0 to 1,024; more reports 1,024 |
| `placement` | `free`, `held` with holder pid, `stale`, `unverifiable` |
| `store_writer_marker` | `absent`, `present` |
| `helper_writer_markers` | count of `delegation/*/objects.writer`, 0 to 256 |
| `restore` | `ordinary`, `restored` with its ordinal, `source_retired`, `restore_incomplete`, `history_invalid`, from `RestoreGuard.state/1` |
| `readable_format` | `1`, the root format this build reads |
| `backup_format` | `loopex_store_backup_capture_v1`, the capture format this build writes and reads |

It decodes no Store frame and scans no session history.

**Service readiness fields.** ADR 0037 owns the readiness record, its four
states, its transport and its wait bound. This record fixes the content of the
fields that recovery depends on:

| State | Fields fixed here |
| --- | --- |
| `closed` | `code`: `invalid_history`, `history_unavailable` or `session_absent`; `session_id`: the session whose scan returned it, at most 256 bytes; `recovery`: the constant `restore_from_backup` |
| `unavailable` | `code`: `store_unavailable`, `unexpected` or `runtime_unavailable`; no `session_id` |
| every state | `project_resources`, with ADR 0037's values: `absent` when the workspace offers none, `unadmitted` when the operator declined at an explicit start or the service was started on demand, which never asks, else `admitted` |

The helper classification already stops at the first such session but keeps
only its identifier (`Helper.classify_sessions/4` returns `[row.session_id]`,
and `classify_session/4` collapses every error to `:failed`). It is changed to
keep `%{session_id, code}`, where the code is the
`Runtime.effect_intents/4` error and a failure to load the retained parent
capture is `invalid_history`. `Delegation.incomplete/1` passes that map, and
the service maps it into the fields above. A closed root stays closed until
restore; nothing quarantines, skips or rewrites the session.

<a id="technical-adr-0072-failures"></a>
### Failure Modes and Exit Statuses

Concept: [Observable consequences](0072-store-readiness-marker-backup-and-restore.md#concept-adr-0072-consequences).

Every `store` command prints one line to standard error for a refusal,
`loopex: store COMMAND: CODE: SENTENCE`, where `CODE` is stable and the
sentence names the path or session and the operator's next step.

| Exit | Meaning |
| --- | --- |
| 0 | Done: backup published; restore committed with current lookup; root adopted or already marked |
| 1 | Refused or not done, with nothing written that the operator must resolve, except a `not_committed` restore whose claim is retained, which prints the re-presentation command, and an adopt refused after its fence, which leaves the marker `adopting` and prints the rerun command |
| 2 | Uncertain: restore `commit_unknown` or `cleanup_unconfirmed`; adopt `root_changed`. Do not proceed; follow the printed command |

Parser errors are `usage` and exit 1, as for every `loopex` command.

| Code | Commands | Cause | Operator next step |
| --- | --- | --- | --- |
| `root_empty` | backup, adopt | Root absent or empty | Nothing to back up or adopt |
| `root_unmarked`, `root_format_unknown`, `root_marker_unreadable` | backup, restore (backup copy or source) | Marker check | Adopt, or restore under the matching build |
| `root_adopting` | backup, restore (backup copy or source) | An adoption started and has not completed | Stop the old build's processes and rerun `store adopt --old-writer stopped` |
| `root_held` | backup, adopt | Live or unverifiable placement holder | Stop the service or command |
| `root_unclean` | backup, adopt | Stale lock or owner link, Store or helper writer marker, socket left, or torn Store tail | Start and stop the root once under the build that wrote it; that start recovers a dead holder and repairs the tail |
| `session_catalog_retired` | adopt | Only the retired catalogue | Restore under the build that wrote it |
| `source_retired`, `restore_incomplete`, `history_invalid` | backup, adopt | Restore metadata state | Resolve the earlier restore |
| `workspace_unavailable`, `workspace_mismatch`, `workspace_changed` | all | Workspace missing or not the root's | Select the root's workspace |
| `invalid_current_history` | backup, adopt | First undecodable record; names the session or member | Restore an earlier backup |
| `inventory_limit_exceeded`, `inventory_mismatch`, `inventory_unavailable` | backup, adopt | ADR 0051 limits, a copy mismatch or an IO error | Stop other processes; retry |
| `source_changed` | backup | A concurrent writer during the copy | Stop other processes; retry |
| `backup_exists`, `backup_path_invalid`, `backup_write_failed` | backup, restore | Target path rules or write failure | Choose another path |
| `backup_invalid`, `backup_changed` | restore | Capture or copy differs from its manifest | Use another backup |
| `attestation_required` | restore, adopt | Restore: `--source` or `--old-writer` missing. Adopt: `--old-writer stopped` missing | State them |
| `discard_requires_lost_source` | restore | `--discard-later-work` with `--source available` | Move the original root aside and restore with `--source lost`, or drop the flag if the backup is the latest state |
| `old_writer_running`, `previous_restore_running` | restore | A live holder or earlier restore process | Stop it |
| `source_absent`, `source_not_absent` | restore | Path contradicts `--source` | State the true branch |
| `destination_not_empty`, `destination_path_invalid` | restore | Destination rules | Choose a new empty directory |
| ADR 0051 refusal codes | restore | Passed through verbatim from `{:not_committed, refusal}` | As the operator runbook's outcome table says |
| `root_changed` | adopt | Root changed after the audit manifest, or around the commit; the marker is left `adopting` | Stop other processes; run `doctor`; rerun adopt |

A crash of any `store` command leaves: for adopt, an unmarked root, an
`adopting` marker every entry point refuses, or a current marker written only
after a complete, unchanged audit (the cut table above); for backup, at most a staging directory beside
`BACKUP`, never a partial `BACKUP`; for restore, the retained plan and ADR
0051's own uncertainty, resolved by `--resume`.

<a id="technical-adr-0072-evidence"></a>
### Evidence and Test Plan

Concept: [Observable consequences](0072-store-readiness-marker-backup-and-restore.md#concept-adr-0072-consequences).

Fault cuts use seams that already exist or mirror existing ones: a private
`:before_publish` hook in `RootFormat`, as `Loopex.SessionDirectory` has;
`Restore.test_restore/3` and `Restore.IO`'s probe gates for restore and the new
IO operations; process kill through the existing fixture helpers. Every
"unchanged" assertion compares a complete independent recursive `File.lstat/1`
walk of the root (path, kind, mode, size, SHA-256, `nlink`), not `Restore.IO`'s
own manifest.

| Test file | Cases |
| --- | --- |
| `apps/loopex_composition/test/root_format_test.exs` | Exact path, 21 bytes and mode `0600`; absent root created and marked; empty directory marked; directory holding only temporaries marked; unmarked nonempty root, `adopting` marker, other version with and without the suffix, unrecognized bytes, symlink, directory, oversized and unreadable markers each refused with its code and the root unchanged; the grammar's classification of every listed form; 16 concurrent `admit/1` calls on one empty root yield one marker and every call returns `{:ok, :created}` or `{:ok, :current}`, none `root_marker_write_failed`; deterministic link-before-unlink gate: publisher A blocked by a private `:after_link` hook between Publication steps 3 and 4, then (a) publisher B completes against A's link and succeeds with read-back `nlink` 2 and A's temporary listed, (b) a sweeper runs `admit/1` on the now-current root and removes A's temporary, then A resumes, tolerates `:enoent` and succeeds with `nlink` 1, (c) both orders of (a) and (b); read-back refuses `nlink` 2 when the second name is not a listed temporary, and `nlink` 3; kill after the temporary is written, after the link and before the removal, each followed by `admit/1` (unmarked then created, or current with residue removed and `nlink` 1); read-only parent gives `root_marker_write_failed` with no marker; `report/1` fields for each root state, `adopting` included |
| `apps/loopex_composition/test/placement_root_format_test.exs` | `Placement.acquire/2` on unmarked, adopting, unknown and unreadable roots refuses and creates no `placement.lock`, owner link or guard; on a new root the marker exists before the lock (hook observes no lock at publication) |
| `apps/loopex_composition/test/composition_root_format_test.exs` | `compose/1` refuses an unmarked root holding a torn `store.log` and a stale `store.log.writer`: the tail, the writer marker, `runtime_id` and `resource-packs` are unchanged; an embedded durable start on an `adopting` root refuses `root_adopting` with the root unchanged; an embedded start on an empty root marks it |
| `apps/loopex_cli/test/store_marker_entrypoints_test.exs` | For `run`, `resume`, `cancel`, `skill`, `chat`, durable `ask`, `sessions` and `artifact`: an M7-shaped unmarked root, a root with only `sessions/`, an `adopting` marker, an unknown marker and an unreadable marker each exit 1 with the named code and leave the root unchanged; `sessions` on an absent root creates nothing |
| `apps/loopex_daemon/test/daemon_root_format_test.exs` | Daemon start exits 116, 117, 118, 119 and 124 for the five codes with the root unchanged, no socket, and the fatal line naming the class |
| `apps/loopex_daemon/test/command_test.exs` (extended) | `ExitStatus.classes/0` maps every status from 65 to 124 except 114 exactly once and none to 114; its assertion grows from `65..110` to that list (ADR 0071, this record and ADR 0073) |
| `apps/loopex_composition/test/store_adopt_test.exs` | A root built by the current code with its marker removed is adopted and differs only by the marker; idempotent second run writes nothing; job-index caches tolerated and left; without `--old-writer stopped`, `attestation_required` with no write; refusals with no write for a retired catalogue, a live lock, a stale lock, a writer marker, a helper writer marker and a restore claim; audit refusals for a corrupt frame, a torn tail, a session with an unknown record kind (session named), a receipt without its marker, a missing artifact object and a workspace mismatch, each leaving only the `adopting` marker added; fault cuts through private hooks at each cut, each with a concurrent writer that appends a valid Store frame and creates a file: after the `adopting` publication and before manifest A (the write is audited, the root is adopted, and manifest D equals the audited bytes), after manifest A (`root_changed`, marker `adopting`), and after the step 10 rename (step 11 restores `adopting`, exit 2); kill before the step 6 link, after it, after manifest A, during the audit and after the rename; after every cut whose root is left `adopting`, `admit/1`, `Placement.acquire/2`, `compose/1`, `store backup` and `store restore` with that root as source refuse `root_adopting` with the root unchanged, `report/1` says `adopting`, and a rerun of adopt repeats the full audit (observed by its decode count) before reaching `current`; no cut ever leaves `current` on a root whose final bytes differ from the audited manifest A apart from the marker |
| `apps/loopex_composition/test/store_backup_test.exs` | Backup of a closed root with sessions, receipts, artifacts, resources, a helper namespace and earlier restore lineage: `state/` equals an independent walk of the source; capture fields equal an independent derivation; refusals for held, stale, writer-marker, helper-marker, claim, unmarked, existing, nested and symlinked targets, a changed workspace and 65,537 entries; a source write during the copy gives `source_changed` and no `BACKUP`; kill during copy, before rename and after rename leave no `BACKUP` or a complete one; job-index removal is the only source change |
| `apps/loopex_composition/test/store_restore_command_test.exs` | Round trips for `lost` (after moving the source aside) and `available`, each committed with lookup current, and the restored root started by composition serving the same sessions; second restore of a restored root (lineage 2); each attestation refusal and each path refusal; `old_writer_running` for a live holder, report-only for a stale one; changed backup byte, changed capture, changed manifest; kill at each ADR 0051 phase, then `--resume` reaching committed with the same plan bytes; `previous_restore_running`; an edited plan file gives `restore_conflict`. Older backup: a session runs further after the backup, the root is moved aside, and `--source lost --discard-later-work` commits; the restored root serves the sessions as they were at the cut, and the retained `attestation` has `discard_later_work` `true` and the retained plan the discard form, both read back byte for byte; `--resume` of that transaction reuses those bytes. Refusals with nothing written: the flag with `--source available` (`discard_requires_lost_source`), the flag with `--resume` (`usage`), and a retained attestation whose flag disagrees with its plan (`backup_invalid`). Without the flag the plan carries the latest form unchanged |
| `apps/loopex_executor_local/test/restore_codec_test.exs` (extended) | The discard attestation form round-trips exactly; a form carrying both `discard_later_work` and `latest_cut`, or `discard_later_work` `false`, is refused; the latest form's bytes are unchanged |
| `apps/loopex_composition/test/restore_workflow_test.exs` (extended) | A plan with the discard form and `source_status` `available` refuses `invalid_plan` before any claim; with `lost` it commits and its receipt equals a latest-form restore's apart from the plan digest |
| `apps/loopex_cli/test/store_command_test.exs` | Grammar, defaults, exit statuses 0, 1 and 2, exact output lines including both statement forms, the printed ADR 0037 writer command parsed by ADR 0037's own parser to `/paths/state_root` = destination, the `LOOPEX_HOME` precedence note, and the configuration file byte-identical after restore |
| `apps/loopex_composition/test/delegation_readiness_code_test.exs` | Classification keeps `%{session_id, code}` for each of the three codes and names no session for runtime-page failures |
| `apps/loopex_daemon/test/readiness_closed_root_test.exs` | A root on which the service did further work after a backup, then had one session history made unreadable: readiness `closed` with that session and `invalid_history`; the root moved aside and the earlier backup restored with `--source lost --discard-later-work`; the service on the restored root reports `serving`; an on-demand start reports `project_resources` `unadmitted`. A second case with no activity after the backup restores without the flag |

The installed lane of M8 outcomes 6 and 7 runs backup, restore and the
refusal of an unmarked root under the installed artifact. Store conformance,
ADR 0051's restore suites and the process and store fault matrix run
unchanged. All of it runs on both supported toolchain pairs.

<a id="technical-adr-0072-compatibility"></a>
### Compatibility Mechanics and Alternatives

Concept: [Compatibility and rollback](0072-store-readiness-marker-backup-and-restore.md#concept-adr-0072-compatibility).

Before 1.0 the marker, the capture, attestation and continuation records and
the backup layout each keep only their current version. A build refuses
another version rather than reading it. An unsupported root is recovered by
restoring a backup under the build that wrote it, which loses work done after
the backup and is never described as opening the root. Adopt is not an
upgrade: it marks only a root that the current decoders already read in full.

M8 carries the installed operator commands, backup and restore; the store
engine's measured selection and migration are M9's under ADR 0036, the split
the maintainer selected as M8 proposal P2. A backup is the directory this
record lays out: the complete copy, ADR 0051's canonical manifest and the
capture record, with no archive form. When ADR 0036's engine ships, its
migration reads a marked local root through the marker check and would write
a new format version; its rollback is a restore of the pre-migration backup
directory taken by `store backup`, as ADR 0036 states.

**Alternatives rejected.**

- *An archive format and restore of this record's own.* They would duplicate
  ADR 0051's transition and contradict its complete, unexcluded manifest.
- *A single-file archive around the backup.* ADR 0051 restores from a
  directory on the same machine; a packer adds a dependency and an
  extraction step without adding recovery.
- *Restore by copying the backup into place.* ADR 0016 and ADR 0051 refuse
  activation of a copied root; only the transition installs fresh ledger
  generations.
- *A separate record inventory checked at open.* Replay already refuses
  unknown kinds; a second inventory would drift from it.
- *No marker, with a full decode before every write.* It reads the log twice
  on every start and still leaves the non-Store members unchecked.
- *Marker written under the placement lock.* The lock file is itself a write
  into a root not yet known to be supported.
- *Marker published by rename.* Rename replaces an existing marker; hard-link
  publication cannot, which keeps a concurrent different-format marker intact.
- *Adopt taking the placement lock.* Its lock file would be a write to the
  unmarked root besides the marker.
- *Backup taking the placement lock.* Its lock and owner link would enter the
  complete manifest and refuse under ADR 0051's link rule.
- *Rewriting configuration after restore.* The maintainer decided the command
  prints the selection instead.
- *Keeping this work inside ADR 0036.* It blocks backup and restore on an
  engine experiment whose result they do not use.
- *Per-session quarantine instead of restore.* Accepted ADR 0046 chose
  whole-root restore, and the maintainer confirmed it.
- *Backing up a live root.* A consistent copy of a root with an active writer
  needs a snapshot protocol the local adapter does not have.

<a id="technical-adr-0072-amendment"></a>
### ADR 0051 Amendment Text

Concept: [Amendment of ADR 0051](0072-store-readiness-marker-backup-and-restore.md#concept-adr-0072-amendment).

ADR 0051's accepted files are not edited. The two amended clauses are:

1. **Backup CLI.**
   - ADR 0051 Concept, scope paragraph: "No Runtime command, executor effect
     envelope, backup CLI, generic migration engine or vision change is
     added."
   - ADR 0051 Technical depth, opening paragraph ("This proposal adds no Core
     public mutation/query, executor effect envelope, generic migration
     engine or backup CLI") and the closing scope paragraph ("It does not add
     a Runtime API, generic migration layer, backup CLI, transport route or
     extra provider attempt").
   - Amended: the host's `store backup`, `store restore` and `store adopt`
     commands of this record are added in front of the transition. They add
     no copy, audit or transition of their own. The other exclusions in those
     sentences stand.
2. **Latest backup only.**
   - ADR 0051 Concept, scope paragraph: "Another-host recovery, a
     lost/recreated workspace, arbitrary historical snapshot rewind, …
     are outside this decision." Amended: restoring a complete, idle,
     current-format backup that is older than the root's last state is inside
     the decision when, and only when, the plan's `source_status` is `lost`
     and its `host_attestation` takes the discard form below. Another-host
     recovery, a lost or recreated workspace, partial or selective rewind and
     automatic removal of uncertain effects stay outside.
   - ADR 0051 Technical depth, the plan grammar's `host_attestation` member,
     `"latest_cut": true, "no_post_cut_activity": true,`. Amended: the member
     is exactly one of two closed forms.

     ```text
     latest form (unchanged):
       {"latest_cut": true, "no_post_cut_activity": true,
        "all_other_copies_excluded": true,
        "old_authority_termination": "joined" | "host_rebooted",
        "host_ledgers_validated": true, "evidence_sha256": hex64}
     discard form (new, source_status "lost" only):
       {"discard_later_work": true,
        "all_other_copies_excluded": true,
        "old_authority_termination": "joined" | "host_rebooted",
        "host_ledgers_validated": true, "evidence_sha256": hex64}
     ```

     A form mixing members of both, or `discard_later_work` other than
     `true`, is `invalid_plan`. The discard form with `source_status`
     `available` is `invalid_plan`. The plan stays version 1 and its digest
     rule is unchanged, so a latest-form plan's bytes and digest do not
     change.
   - ADR 0051 Technical depth, "Host attestation is necessary in both source
     branches: no post-cut effects, competing roots or stale snapshot activity
     can be inferred from a manifest." Amended for the discard form: the host
     attests that activity after the cut is abandoned rather than absent.
     The restored root's history ends at the cut. Effects dispatched after the
     cut have no record in it and are never reconciled by Loopex. An effect
     open at the cut stays open or unknown in the restored root, exactly as
     ADR 0051 restores it, and is never redispatched. Clients that saw later
     events find a history that ends at the cut.

Everything else ADR 0051 decides applies unchanged to both forms: same machine,
same workspace identity, a complete unexcluded backup, an empty destination,
exclusion of every other copy, fresh ledger generations, the lineage and its
64-restore limit, the refusal order and the outcomes.

<a id="technical-adr-0072-open"></a>
### Resolved Choice

Concept: [Open for the maintainer](0072-store-readiness-marker-backup-and-restore.md#concept-adr-0072-open).

The earlier choice between a strict command and a `--discard-later-work`
statement was decided on 2026-10-13 for the statement, with strict behavior
kept whenever the flag is absent. Its grammar, refusals, retained bytes and
tests are specified in the restore, failure and evidence sections above, and
its ADR 0051 text in the amendment section. Nothing remains open.
