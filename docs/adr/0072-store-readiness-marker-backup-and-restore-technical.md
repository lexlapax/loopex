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
[amendment](#technical-adr-0072-amendment) adds. Core (`apps/loopex`) and the
store application gain no callback, module, function or dependency; the
[format number rule](#technical-adr-0072-format-number) checks their formats
against retained roots their existing codecs decode. Every other
piece below is host code in composition, the Local executor's restore codec,
the CLI and the daemon.

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
| Marker constants, `check/1`, `admit/1`, `report/1` and marker publication | `LoopexComposition.RootFormat` (`lib/loopex_composition/root_format.ex`) | `loopex_composition` | New |
| The retained format-1 root, its producer and its audit, re-encode and boundary checks | `apps/loopex_cli/test/root_format_fixture_test.exs`, `apps/loopex_cli/test/fixtures/root_format/format-1.tar` with its `README.md` and `produce.exs` | `loopex_cli` (test only) | New |
| Marker check before the placement lock | `LoopexComposition.Placement.acquire/2`, first step | `loopex_composition` | Existing, changed |
| Marker check before composition starts a Store | `LoopexComposition.compose/1`, before `RestoreGuard.state/1` | `loopex_composition` | Existing, changed |
| Closed-root checks, adopt, backup, restore plan construction and continuation; closed result maps, no printing | `LoopexComposition.StoreAdmin` (`lib/loopex_composition/store_admin.ex`) | `loopex_composition` | New |
| Capture, attestation and continuation record codec | `LoopexComposition.StoreAdmin.Codec` | `loopex_composition` | New |
| Read-only inventory and audit of a live root path; adopt's manifest without the placement lock's entries; whole-tree backup copy | Three operations added to `LoopexComposition.Restore.IO`: `{:root_inventory, root, manifest, workspace_ref, mode}`, `{:adopt_manifest, root, max_total}` and `{:backup_copy, root, staging_state, manifest}` | `loopex_composition` | Existing guardian, new operations |
| Adopt's hold of the root's placement lock | The extracted placement lock primitive on `STATE_ROOT/placement.lock`, called by `StoreAdmin.adopt/2`; never `Placement.acquire/2` | `loopex_composition` | Existing primitive, new caller |
| Session-identifying failure of the audit | `LoopexComposition.Restore.Audit` and `Restore.IO.audit_store_bytes/1` return the failing session identifier privately; the public results of `restore/2` are ADR 0051's | `loopex_composition` | Existing, changed |
| The disposable job index left out of the audit index in every mode (D29): `:adopt`, `:backup` and ADR 0051's restore through `restore/2` | `LoopexComposition.Restore.Audit`'s helper-namespace rule and `Restore.Workflow`'s baseline shape check, which skip every entry under `delegation/*/job-index-v1/`, the directory included, unconditionally; no option, no new entry point; `restore/2`, `test_restore/3`'s options and `Restore.IO.run/3`'s options are otherwise unchanged | `loopex_composition` | Existing, changed |
| Separation of an available restore source | `StoreAdmin.restore/3` calls ADR 0037's `LoopexComposition.SignIn.Separation.check/1` on the command's sign-in context with the captured source appended (restore check 1) | `loopex_composition` | New caller |
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

<a id="technical-adr-0072-format-number"></a>
**Format number rule (D28).** The number names the complete set of durable
shapes a build writes into or reads from a root. Any change to a durable
member, shape or encoding advances it: a new record kind, a removed kind, a
changed member, nested shape, encoding, version constant or limit of any of
them, including a shape a record delegates to another module. The rule holds
in every release, a `0.5.x` patch included. A build that changes one
publishes format 2, whose roots `0.5.0` refuses as `root_format_unknown`
before any write, and which itself refuses a format-1 root the same way until
a separately decided migration exists. Version constants inside a record
stay as they are; the number is the root-level summary of all of them.

*Owners.* Format 1 is owned by these modules, each through the encoder and
decoder that write and admit its shapes, with every module a shape
delegates to. A change to any of them is reviewed under D28 for whether it
advances the number:

| Durable member | Owners |
| --- | --- |
| Store log and transactions | `Loopex.Store.Local.Log` (frames, `@max_frame_bytes`, `@max_log_bytes`, `decode_bytes/1`); `Loopex.Store` (`loopex_store_transaction_v1` under `:erlang.term_to_binary/2` with `:deterministic`, the creation, owner, runtime and command records, and the item limits of `normalize_and_measure_item/2`); `Loopex.Store.Local.State` (`replay/1`, `@schema_version` 2 of the snapshot it replays into, and a creation transaction's genesis) |
| Private session records and public outbox events | `Loopex.Runtime.SessionState` (every record kind `recover/3` admits, with its admitted failure categories, and every outbox event it derives); `session_genesis_v3`, retained in a session record, a creation transaction and a helper's retained genesis, delegated to `Loopex.Runtime.SessionGenesis` (`@v3_keys`, `@max_bytes` 65,536), whose members are further delegated to `Loopex.Runtime.SessionConfiguration`, `LoopexProtocol.ToolDefinition` and `Loopex.Runtime.ArtifactReadCapabilities` |
| Store writer marker and artifacts | `Loopex.Store.Local.WriterLock` (`loopex_store_writer_v2`); `Loopex.ArtifactStore` and `Loopex.Store.Local.Artifacts` (object and `artifact-use-v2` layout, `@max_bytes`) |
| Resources | `Loopex.ResourcePack`; `LoopexComposition.ResourcePacks` (retained pack layout) |
| Executor and restore ledgers | `Loopex.Executor.Local.Ledger` (`local_executor_generation_v1`, `local_open_effect_v1`, `local_effect_admission_v1`, `local_pre_effect_refusal_v1`, receipts and markers); `Loopex.Executor.Local.RestoreCodec` (ADR 0051's `loopex_current_restore_*_v1` records, the plan version and both attestation forms) |
| Helper ledgers | `LoopexComposition.Delegation.LedgerCodec` (frames, headers and log versions); `RunMutation`, `ParentBinding`, `Receipt` and `GenesisCodec` (delegating to `SessionGenesis`); `RetainedObjects` (object naming, `@cap`, `@run_cap`); `JobIndex` (`job-index-v1`) |
| Session catalogue and runtime identity | `LoopexDaemon.SessionIndex.Codec` and `LoopexDaemon.SessionIndex.Storage` (`session-index-v1`, `@max_entries`, `@max_file_bytes`, `@max_row_bytes_including_lf`); `Loopex.SessionDirectory` (`runtime_id`, `@max_runtime_id_file_bytes`, `@max_identifier_bytes`) |
| Placement lock record | `LoopexComposition.Placement` (`loopex-placement-v1`), which a stale lock leaves in a root |
| Backup records and marker | `LoopexComposition.StoreAdmin.Codec` (`loopex_store_backup_capture_v1`, `loopex_store_restore_attestation_v1`, `loopex_store_restore_continuation_v1` and the backup layout); `LoopexComposition.RootFormat` (both marker states) |

*Format-1 fixture.* W4 produces one format-1 root once, at M8
implementation step 6, once `store backup` exists to write its capture, and
no check regenerates it; the marker and the retained M7 root's refusals land
earlier, at step 3. The producer is
`apps/loopex_cli/test/fixtures/root_format/produce.exs` (new), run by hand
with `mix run` from the candidate tree and never by a check. In a temporary
directory it drives the candidate's real runtime, Local Store, Local
executor, helper and session catalogue with only the model scripted by
`Loopex.AgentLoopTestModel` (`apps/loopex/test/support/agent_loop_adapters.exs`),
as the delivered `apps/loopex_cli/test/receipt_round_trip_test.exs` drives
the real Local executor and `apps/loopex_cli/test/chat_helpers_test.exs`
drives a helper run. The root it leaves holds the marker `RootFormat.admit/1`
published, one conversation session with one Local executor effect whose
result is retained as an artifact, one helper run with its binding and run
logs and its child session, one admitted resource pack, the session
catalogue and the runtime identity, with no placement lock or writer marker
left. The producer then takes one `store backup` of that root and keeps its
`capture` file; the backup's `state/` copy equals the root and is not kept.
The root, its workspace and that `capture` become one canonical archive,
`apps/loopex_cli/test/fixtures/root_format/format-1.tar`, written by
`scripts/fixtures/m7-root-archive.exs` in the canonical form the
[retained M7 root](#technical-adr-0072-m7-fixture) uses. A `README.md` beside it
records the producing commit, the command, the toolchain pair, the session
identifiers, the workspace reference the genesis records and the archive's
SHA-256, which the test also pins. `loopex_cli` holds the fixture and its
test because it is the one application that depends on every owner above.

*Fixture test.* `apps/loopex_cli/test/root_format_fixture_test.exs` (new)
extracts `format-1.tar` and the retained M7 root
(`apps/loopex_composition/test/fixtures/m7_root/m7-root-v0.4.0.tar`) into
temporary directories, after checking each archive's SHA-256 against the
value pinned in the test, and then:

1. **Full audit.** Each root is decoded by the audit adopt runs: manifest A
   by `Restore.IO.run({:adopt_manifest, root, 2^64 - 1}, limits)`, then
   `Restore.IO.run({:root_inventory, root, A, workspace_ref, mode},
   limits)` with the workspace reference the root's genesis records, which
   the operation takes as its argument, so no test option is needed. The
   format-1 root is audited in `:backup` mode, being marked, and the M7 root
   in `:adopt` mode, being unmarked. The audit decodes every Store frame,
   replays the Store, recovers every session, and validates every Local
   generation, marker, open entry and receipt, every artifact use and
   object, every resource record and every helper object and log
   (`Restore.Audit.complete/4`); both roots must pass. Beside it, for the
   format-1 root, `RootFormat.check/1` answers `:current`,
   `LoopexDaemon.SessionIndex.Codec.decode/1` admits the catalogue image,
   `Loopex.SessionDirectory.runtime_id/1` returns the retained identifier,
   and `StoreAdmin.Codec` admits the `capture` record.
2. **Exact re-encoding of the pure codecs.** Only codecs whose output is a
   function of their input are re-encoded. `Loopex.Store.Local.Log`: the
   frames `decode_bytes/1` returns, each re-encoded by `encode/1`
   (`log.ex:281-296`), concatenate to the exact `store.log` bytes.
   `LoopexComposition.Delegation.LedgerCodec`: the payloads `decode_frame/1`
   returns from each helper binding and run log, each re-encoded by
   `encode_frame/1` (`ledger_codec.ex:100-107`), concatenate to the exact
   log bytes. `LoopexDaemon.SessionIndex.Codec.encode/1` (`codec.ex:38-55`)
   of the decoded catalogue rows equals the image. The marker equals
   `loopex-root-format 1` and a line feed. `StoreAdmin.Codec`'s encoding of
   the decoded `capture` record equals its bytes. The Store and helper
   frames are re-encoded for both roots, so the current pure codecs must
   also reproduce what the M7 build wrote. The other owners are not
   re-encoded, because their bytes are not a function of a decoded value:
   the Local executor ledger draws a random generation epoch and admission
   nonce inside its writer (`ledger.ex:831-836`, `:616`) and its
   `decode_bytes/2` adds `ledger_kind`; `SessionDirectory`'s runtime
   identity, the placement lock record, the artifact store and the
   resource packs are written inside their writers. Those are held by the
   audit only.
3. **Named boundary checks.** A closed list, each refused one unit over its
   limit and, except the Store log, admitted at it:

   | Limit | At the limit | One over | Where |
   | --- | --- | --- | --- |
   | Session genesis, 65,536 normalized bytes (`SessionGenesis` `@max_bytes`) | The fixture's genesis padded in `options` to exactly 65,536 bytes as `Store.normalize_and_measure_item/2` measures them is admitted by `SessionGenesis.normalize/1` | 65,537 bytes refused `session_configuration_too_large` | This test, and the delivered `apps/loopex/test/session_genesis_test.exs:101-112` |
   | Store frame, 4 MiB deterministic payload (`Log` `@max_frame_bytes`) | A frame whose payload is exactly 4,194,304 bytes encodes with `Log.encode/1` and decodes complete with `Log.decode_bytes/1` | 4,194,305 bytes refused `store_frame_too_large` | This test |
   | Store log, 256 MiB (`Log` `@max_log_bytes`) | Not built: no valid 256 MiB log is admitted in the fast check | An append that would pass the ceiling, on a sparse file sixteen bytes under it, refused `store_capacity_exceeded` with the file unchanged; a 256 MiB + 1 image refused `store_log_too_large` by `decode_bytes/1` before decoding | Delivered `apps/loopex_store_local/test/log_capacity_test.exs:12-32` and `log_encoding_test.exs:56-66` |
   | Helper ledger frame, 65,536 payload bytes (`LedgerCodec` `@payload_bytes`) | 65,535 and 65,536 bytes encode and decode | 65,537 refused `invalid_frame` | Delivered `apps/loopex_composition/test/delegation_ledger_codec_test.exs:185-203` |
   | Session catalogue, 4,096 entries (`SessionIndex.Codec` `@max_entries`) | 4,096 rows encode and decode | 4,097 refused `session_index_full` | Delivered `apps/loopex_daemon/test/session_index_codec_test.exs:47-60` |

   Every other limit an owner enforces is outside this list and is held by
   that owner's own tests and by review.

There is no completeness scan of the source, no in-test generator and no
format history: the number the marker writes stays one constant in
`RootFormat`, and the archive's pinned SHA-256 is the fixture's only pin.

*Mutations that must fail.* With the marker's number left at 1, each in a
scratch copy: raising `Loopex.Runtime.SessionGenesis`'s `@max_bytes`
(`session_genesis.ex:26`) from 65,536 to 131,072 makes `normalize/1`
(`:125-134`) admit the 65,537-byte genesis the boundary check requires
refused; and adding a member to `@v3_keys` (`:28-35`) and to `resolve/2`'s
payload makes `validate/1`'s key comparison (`:151`) refuse every retained
genesis of both fixture roots as `invalid_session_genesis`, so session
recovery inside the full audit refuses. Each fails
`root_format_fixture_test.exs`.

*What the check does not prove.* It holds what the two retained roots
reach, the pure codecs' bytes and the five listed limits. It does not see a
shape no retained record reaches, a change to what a writer-process owner
writes while the retained bytes still decode, such as a new optional member
or a new branch, or a limit outside the list. Under D28 those are caught by
review of any change to an owner above, which decides whether the change
advances the number. A regenerated `format-1.tar` under an unchanged number
changes the pinned digest in the same diff and is likewise a review matter;
the fixture of a number a release has shipped is never regenerated.

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
| `store adopt` | The root's placement lock (adopt step 4) | `check/1` before the lock and again under it, then the two-phase marker of the adopt section |
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
0073 takes 120 to 123 and ADR 0037 takes 125 (D31). This record takes 116 to
119 and 124. The table lands in three blocks so that every interim table is
gap-free: 111 to 115, then this record's 116 to 119 with the marker, then 120
to 125, ADR 0073's four, this record's 124 and ADR 0037's 125, before `store
adopt`, the only writer of the
`adopting` marker, merges. Until that last block the daemon has no
`root_adopting` class; its mapping and `daemon_root_format_test.exs`'s 124
case land with it. The daemon's
assigned statuses are therefore 65 to 125 except 114: every integer in that
range other than 114 maps to exactly one class, and no class maps to 114.
`LoopexDaemon.ExitStatus` gains this record's five classes; its moduledoc
range and `fetch/1` spec extend through the highest assigned status. The
assertion in `apps/loopex_daemon/test/command_test.exs`, which today checks
`Enum.to_list(65..110)`, becomes the list of 65 to 125 without 114, each
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
source build, is running or will start until adopt exits. The delivered M7
daemon and CLI hosts take the same `STATE_ROOT/placement.lock`
(`LoopexDaemon.Service.acquire_placement/1` and `LoopexCli`'s foreground
starts call `Placement.acquire/2`), so they are excluded while adopt holds
it. That build does not read the marker, so the statement is its only fence
once adopt releases the lock, and against an embedded or non-cooperating host
that takes no lock. A missing or other value
refuses `attestation_required` before any check, with nothing written. The
root and workspace are selected exactly as ADR 0037 selects them for the
service (`--state-root` > `LOOPEX_HOME` > the configuration file's
`/paths/state_root` > the installed home; `--workspace` > `/paths/workspace`),
and each value is printed with its origin. `--work-ms` defaults to 3,600,000
and `--cleanup-grace-ms` to 5,000; both are positive integers, passed as the
explicit limits ADR 0051's owned IO requires. They are this command's host
choices; ADR 0051's embedded API keeps no default.

**Algorithm** (`StoreAdmin.adopt/2`). Steps 1 to 3 write nothing. Step 4
takes the root's placement lock and writes only the lock's own files. Step 7
is the fence and step 11's rename is the commit: every exit between them
leaves the marker `adopting`, and every exit after the rename leaves it
`current`. Adopt holds the placement lock from step 4 through the rename and
releases it on every exit after step 4, success or refusal.

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
4. **Placement lock.** Take the lock at `STATE_ROOT/placement.lock` with the
   extracted placement lock primitive: the same file, owner record, owner
   handle, guard and stale-incarnation rule `Placement.acquire/2` uses after
   its first step, so adopt excludes, and is excluded by, every daemon, app
   server and lock-taking command on the root. Adopt never calls
   `Placement.acquire/2` itself, whose `admit/1` first step refuses this root.
   The primitive's existing refusals apply and it does not wait:
   `placement_active` (a live holder, a concurrent adopt included) and
   `placement_unverifiable` refuse `root_held`, naming the holder's PID where
   known; `placement_lock_failed` refuses `inventory_unavailable`. A lock whose
   recorded process incarnation is gone is reclaimed by the primitive exactly
   as any start reclaims it. That stale lock is the residue a killed adopt
   leaves; every other trace of an unclean stop is still refused at step 5 or
   by the audit.
5. Under the lock, `RootFormat.check/1` again: `:current` prints `already
   marked`, releases the lock and exits 0 (a concurrent adopt committed and
   released first); `root_unmarked` and `root_adopting` continue; any other
   result refuses with its code. Then the closed-root checks of
   `StoreAdmin.closed/1` other than the placement lock, which step 4 owns:
   `store.log.writer` present → `root_unclean`; any
   `delegation/*/objects.writer` present → `root_unclean`; a socket or other
   special node at `daemon/daemon.sock` → `root_unclean`;
   `RestoreGuard.state/1` other than `{:ok, _}` refuses with its code
   (`source_retired`, `restore_incomplete`, `history_invalid`), which includes
   a restore claim beside the root.
6. `WorkspaceIdentity.reference/1` of the workspace; failure refuses
   `workspace_unavailable`.
7. **Fence.** On an unmarked root, publish the `adopting` marker
   (`RootFormat` Publication with state `adopting`). `:eexist` cannot come from
   another adopt, which the lock excludes, or from a start of this build, whose
   `admit/1` refuses a nonempty unmarked root without publishing; any marker
   found there refuses `root_changed` and is left as found. On a root already
   `adopting`, nothing is published. Then `sweep/1` removes every marker
   temporary, so the marker's `nlink` is 1 for the manifest. From here every
   entry point of this build refuses the root as `root_adopting` before it
   reaches the lock.
8. Audit manifest A: `Restore.IO.run({:adopt_manifest, root, 2^64 - 1},
   limits)`, ADR 0051's manifest of the root with exactly the placement lock's
   own top-level entries omitted: `placement.lock` and every entry whose name
   begins `placement.lock.` (adopt's owner handle and the transient guard).
   They are lock state, not records, and the owner handle is a second link to
   the lock file, which ADR 0051's `nlink` rule would refuse. Every other
   entry, rule and encoding is ADR 0051's. A includes the `adopting` marker
   entry. The manifest's own caps apply: 65,536 entries and 4 MiB encoded;
   beyond them refuse `inventory_limit_exceeded`. ADR 0037's path check of
   the root ran when the command's configuration was resolved, before step
   1; the walk adds no separation rule of its own and refuses symbolic links
   and hard-linked files as ADR 0051's manifest does.
9. Inventory and audit: `Restore.IO.run({:root_inventory, root, A,
   workspace_ref, :adopt}, limits)`. This runs ADR 0051's
   `Restore.Audit.complete/4` over the live root path with a draft plan whose
   descriptors it derives (see Backup step 7) inside the same owned worker. In
   `:adopt` mode, and only there, the marker entry is removed from the index
   given to the audit. The audit never indexes the job index, in every
   mode (D29): every entry under `delegation/*/job-index-v1/`, the directory
   included, is left out of the index in `:adopt` and `:backup` mode and in
   ADR 0051's own restore through `restore/2`, and is exempt from
   `Restore.Workflow`'s baseline shape check. The job index is a disposable
   cache, is not decoded and is left on disk. Manifests are never filtered
   by it. The
   audit decodes every Store frame (`Log.decode_bytes/1`, requiring a complete
   tail), replays the Store (`State.replay/1`), recovers every session in
   sorted order (`SessionState.recover/3`), and validates every Local
   generation, marker, open entry and receipt, every artifact use and object,
   every resource record and every helper object and log. It stops at the
   first failure, which refuses with its inventory code.
10. Final manifest C by the same operation; require C = A byte for byte,
    else `root_changed`.
11. **Commit.** Write a marker temporary holding the `current` bytes
    (Publication step 2), read the marker and require the exact `adopting`
    bytes (else `root_changed`), then `rename(temporary, marker)`, which
    atomically replaces `adopting` with `current`, and `fsync` the root. This
    rename, performed while adopt holds the placement lock and after the full
    audit and C = A, is the linearization point of adoption. Nothing is
    checked after it and nothing puts `adopting` back.
12. Release the placement lock with the primitive's release and adopt's owner
    handle. A release failure leaves a stale lock that the next start
    reclaims; the root is committed, so adopt still succeeds and names the
    lock on standard error.
13. Print `adopted STATE_ROOT as loopex-root-format 1` with the counts of
    sessions, Store frames, ledgers and artifact objects decoded. Exit 0.

**Inventory failure codes** reported by step 9, each with an optional detail:
`invalid_current_history` with the session identifier when a session's replay
failed, or the relative path of the failing member otherwise;
`store_log_torn`, which the command reports as `root_unclean`;
`workspace_mismatch` when a retained session genesis names a different
workspace than step 6's reference; `inventory_limit_exceeded`;
`inventory_mismatch`; `inventory_unavailable` for an IO error. The detail is
a bounded identifier or path, at most 8,192 bytes, never record content.

**Limits.** Everything ADR 0051's audit enforces: 65,536 manifest entries,
4 MiB manifest, 256 MiB Store log, 4 MiB frame, 2,048-byte generation,
65,536-byte receipts and Local records, 1,024-entry and 4 MiB open index,
1 MiB helper bindings, 16 MiB helper run logs, 256 runtime identifiers, 1,024
Stores and 128 ledgers.

**Crash safety, reruns and concurrent writers.** The marker moves only
absent → `adopting` (no-replace link, step 7) and `adopting` → `current`
(rename, step 11), and both moves happen while adopt holds the placement
lock. `current` is written only after a complete audit of manifest A and a
final manifest C equal to A. The rename is the commit: a crash before it
leaves `adopting`, and a crash after it leaves a committed `current` root. The
rename is durable once step 11's root `fsync` returns; a power loss between
the two leaves either marker, and each is a row of this table.

| Cut | Root left | Next invocation |
| --- | --- | --- |
| Refused before step 4 | Unchanged byte for byte; at most a temporary of an earlier run, which `check/1` ignores | Any 0.5.0 start refuses `root_unmarked`; adopt starts over |
| Refused at steps 4 to 6 | Unchanged byte for byte apart from a stale placement lock that step 4 reclaimed; the lock is released | As above |
| Killed after step 4, before the step 7 link | Unmarked; adopt's stale placement lock; at most one temporary | Any 0.5.0 start refuses `root_unmarked` before the lock; adopt reclaims the lock and starts over |
| Killed after the step 7 link, before the rename (during the sweep, a manifest or the audit) | `adopting`; adopt's stale placement lock; at most one temporary | Every entry point refuses `root_adopting` before the lock; adopt reclaims the lock and reruns the full audit |
| Old-build writer after step 7, before manifest A | `adopting`; the write is in A and is audited, or is torn and refused by the audit | Refused or adopted only on the audited bytes |
| Old-build writer after manifest A, before manifest C | `adopting`; C ≠ A refuses `root_changed` (exit 2); the lock is released | Every entry point refuses `root_adopting`; adopt reruns from the start |
| Audit refusal (`invalid_current_history` and the other inventory codes) | `adopting`; the lock is released | Refused; recovered by a backup restored under the build that wrote it |
| A 0.5.0 start or a second adopt after step 7, before the rename | `adopting`, unchanged by it | The start refuses `root_adopting` at `admit/1`; a second adopt refuses `root_held` at step 4 |
| A 0.5.0 start or a second adopt after the rename, before step 12 | `current`, unchanged by it | `Placement.acquire/2` refuses `placement_active` (daemon exit 76) and a second adopt refuses `root_held` at step 4; after step 12 both are admitted as on any current root, the second adopt reporting `already marked` |
| Killed after the rename, before or during step 12 | `current`, audited and unchanged at C; at most adopt's stale placement lock | Ordinary use: the next start reclaims the stale lock; adopt reports `already marked` |

No process of this build writes the root between the fence and the release:
before the rename every entry point refuses the marker, and between the rename
and the release every lock-taking start is refused by the lock. A lockless
path such as `cancel`, admitted by the marker only after the rename, opens a
committed current root. Two adopters overlap only up to step 4: exactly one
holds the lock, and the other refuses `root_held` or, once the first has
committed and released, reports `already marked` at step 5.

The delivered M7 daemon and CLI hosts take this same placement lock through
the same `Placement.acquire/2` and lock file, so while adopt holds the lock
an M7 start is refused `placement_active` like a `0.5.0` start. The
`--old-writer stopped` statement remains required because the M7 build does
not read the marker: once adopt releases the lock, after a refusal or kill
that leaves `adopting` or after the commit, an M7 process can open the root;
and an embedded or other non-cooperating host, or a lockless M7 path such as
`cancel`, never takes the lock. Such a writer during the audit is detected by
C ≠ A; one after the release writes to a root the statement says no old
process will touch. `doctor` reports `marker: adopting` for every root left in that
state.

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
[separation invariant](0037-host-configuration-and-path-discovery-technical.md#technical-0037-auth-separation)
keeps the protected credential directories, the sign-in directory and
gcloud's Application Default Credentials directory, outside every state
root by path, not because backup filters files. ADR 0037's
[separation check](0037-host-configuration-and-path-discovery-technical.md#technical-0037-where-it-runs)
compares the root and `BACKUP` with them when the command's configuration
is resolved, before step 1, and the walks below add no separation rule of
their own (D27); mounts are outside the guarantee, under ADR 0037's
[operator limit](0037-host-configuration-and-path-discovery-technical.md#technical-0037-operator-limit).

**The job index stays.** ADR 0046's disposable `delegation/*/job-index-v1`
cache is neither deleted from the source nor left out of the copy: it is in
manifests A, B and C and in `state/` byte for byte, like every other file.
Only the audit's index omits it, in every mode (adopt step 9, D29), because
the audit cannot decode a cache that grants nothing. A restore through
`restore/2` copies it into the destination under the same complete manifest
and omits it from its audit the same way. A
service started on the restored root validates each entry at startup under
ADR 0046's classification bound and discards and rebuilds any that does not
validate, so a stale or damaged index costs a rescan, never a refusal or a
false classification. An earlier draft deleted the index from the source at
backup, a recursive delete inside a root backup holds no lock on, which also
cost every backed-up root a full rescan at its next start; it is withdrawn.

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
 "workspace": {"root": absolute_path, "workspace_ref": current_workspace_ref}
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
3. `StoreAdmin.closed/1`: `Placement.live_owner/1` returns `{:ok, pid}` →
   `root_held`; `:none` with `placement.lock` or any `placement.lock.owner-*`
   present → `root_unclean`; `{:error, _}` → `root_held`; then the writer
   marker, socket and `RestoreGuard` checks of adopt step 5. A torn tail is
   found at step 7.
4. `RestoreGuard.state/1` gives the prior restore count (0 for an ordinary
   root, else the committed ordinal); count 64 refuses
   `inventory_limit_exceeded`, because ADR 0051 refuses transition 65.
5. Print `backing up STATE_ROOT (format 1, closed) to BACKUP; workspace
   WORKSPACE; limits WORK_MS/GRACE_MS`, then proceed without a prompt.
6. Remove marker temporaries (`RootFormat.admit/1` on a current root). This
   is the only source write; the job index is left as it is.
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
    :backup}, limits)` audits the copy as `restore/2` will, with the job
    index omitted from the audit's index only; its descriptors must equal
    step 7's. Any failure refuses with the inventory code.
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
   (`backup_invalid`). With `--source available`, or on `--resume` when the
   retained plan's `source_status` is `available`, call ADR 0037's
   `Separation.check/1` at once on the command's sign-in context with
   `{"/capture/source_state_root", SOURCE}` appended to its `state_roots`,
   `SOURCE` being the capture's source path; an overlap refuses
   `auth_root_overlap /capture/source_state_root` before anything else is
   read. `BACKUP` and `DESTINATION` were already checked when the
   configuration was resolved. Read `BACKUP/manifest`; its SHA-256 must
   equal the capture's (`backup_changed`). Manifest of `BACKUP/state` must
   equal those bytes (`backup_changed`). `RootFormat.check(BACKUP/state)`
   must be `:current` (its code otherwise).
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
3. Call `LoopexComposition.Restore.restore(plan, invocation)` once. Its
   audit omits the job index, which the backup keeps, from its index, and
   its copy and manifests carry it like any file (the backup section's
   [job index rule](#technical-adr-0072-backup) and the
   [job index audit rule](#technical-adr-0072-job-index-audit), D29). ADR
   0051's walks, phases and outcomes are otherwise exactly as accepted.

   A `commit_unknown` observation alone does not say which phase stopped,
   so the command does not infer noncommit from it. After any
   `cleanup_unconfirmed` or `commit_unknown` result it calls
   `Restore.lookup(DESTINATION, TX_ID, limits)`, which is read-only, and
   prints its answer; at `claim_release` it adds `restore TX_ID is
   committed in DESTINATION; claim cleanup is pending and the root stays
   closed until --resume finishes it`. The exit status is the table's.

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
exactly and decodes it (`backup_invalid` if it does not round-trip). The
plan, not the arguments, names what the transition walks and writes, so the
command then requires the canonical `BACKUP/state` to equal the plan's
`backup_state_root` (`backup_invalid`) and the canonical `DESTINATION` to
equal its `destination_state_root` (`destination_path_invalid`); the
separation check of ADR 0037 that ran on the arguments has therefore run on
exactly the paths the transition uses, under this invocation's `HOME`. It
probes every earlier invoker recorded in `attestation` and each
`continuation-N` with `Placement.process_incarnation/3`; one still alive
refuses `previous_restore_running`. It writes `continuation-N`
(`loopex_store_restore_continuation_v1`: `tx_id`, `n`, `previous_restore`, the
observed earlier invokers and their status `gone`, `alive` or
`unverifiable`, and its own invoker), then calls `restore/2` with the same plan
bytes and an invocation whose `prior_admin_authority` is `"joined"` for
`--previous-restore stopped` or `"host_rebooted"` for `rebooted`, and whose
`prior_admin_evidence_sha256` is that record's SHA-256. ADR 0051 resolves the original
transaction; a changed plan file answers `restore_conflict`. Before calling,
the command prints `Restore.lookup/3`'s answer for the destination. Check 1,
with its source separation check, runs before the continuation record is
written: a refusal there exits 1, writing nothing and leaving the transaction
as the printed lookup answer shows it, so a committed root with cleanup
pending stays committed and closed. Output and exits follow the table above.

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
| `root_held` | backup, adopt | Live or unverifiable placement holder, including a concurrent adopt | Stop the service or command, or let the other adopt finish |
| `root_unclean` | backup, adopt | Stale lock or owner link (backup only; adopt reclaims a stale lock), Store or helper writer marker, socket left, or torn Store tail | Start and stop the root once under the build that wrote it; that start recovers a dead holder and repairs the tail |
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
| `auth_root_overlap` | backup, adopt, restore | ADR 0037: the root, `BACKUP`, `DESTINATION` or an available source the capture names is, contains or lies inside a protected credential directory by resolved path; names the pointer | Select a separate path |
| ADR 0051 refusal codes | restore | Passed through verbatim from `{:not_committed, refusal}` | As the operator runbook's outcome table says |
| `root_changed` | adopt | Root changed between the audit manifest and the final manifest, or a marker appeared at the fence; the marker is left `adopting` or as found | Stop other processes; run `doctor`; rerun adopt |

A crash of any `store` command leaves: for adopt, before its rename, an
unmarked root or an `adopting` marker every entry point refuses, and after
it, a committed current marker written under the placement lock only after a
complete, unchanged audit, in each case with at most adopt's stale placement
lock (the cut table above); for backup, at most a staging directory beside
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
| `apps/loopex_daemon/test/daemon_root_format_test.exs` | Daemon start exits 116, 117, 118, 119 and 124 for the five codes with the root unchanged, no socket, and the fatal line naming the class, the 116 case also on the extracted [retained M7 root](#technical-adr-0072-m7-fixture); the 124 case lands with the 120 to 125 block |
| `apps/loopex_cli/test/root_format_fixture_test.exs` | The [format-1 fixture](#technical-adr-0072-format-number) and the retained M7 root, each extracted after its pinned archive SHA-256 is checked, pass the full audit (`{:adopt_manifest, ...}` then `{:root_inventory, ...}` in `:backup` and `:adopt` mode respectively, with the workspace reference each genesis records); on the format-1 root `RootFormat.check/1` answers `:current` and the catalogue image, runtime identity and `capture` record decode; the Store log's frames and every helper log's frames of both roots re-encode by `Log.encode/1` and `LedgerCodec.encode_frame/1` to the exact retained bytes, and the catalogue image, the marker and the `capture` record of the format-1 root by `SessionIndex.Codec.encode/1`, the marker constant and `StoreAdmin.Codec`; the genesis at 65,536 normalized bytes is admitted and at 65,537 refused `session_configuration_too_large`, and a Store frame with a 4,194,304-byte payload encodes and decodes while one byte more is refused `store_frame_too_large`. W4's closure evidence retains the test's failing output against each of the two named [mutations](#technical-adr-0072-format-number), each applied in a scratch copy with the marker's number left at 1 |
| `apps/loopex_daemon/test/command_test.exs` (extended) | `ExitStatus.classes/0` maps every status from 65 to 125 except 114 exactly once and none to 114; its assertion grows from `65..110` to that list (ADRs 0071, 0037, this record and ADR 0073) |
| `apps/loopex_composition/test/store_adopt_test.exs` | A root built by the current code with its marker removed is adopted and differs only by the marker; idempotent second run writes nothing; job-index caches tolerated and left; without `--old-writer stopped`, `attestation_required` with no write; refusals with no write for a retired catalogue, a live lock (`root_held`), a writer marker, a helper writer marker and a restore claim, each releasing adopt's lock; a stale lock of a dead incarnation reclaimed at step 4 and the root adopted with no lock left; manifests A and C omit exactly `placement.lock` and the `placement.lock.*` entries and include everything else; audit refusals for a corrupt frame, a torn tail, a session with an unknown record kind (session named), a receipt without its marker, a missing artifact object and a workspace mismatch, each leaving only the `adopting` marker added and the lock released; a non-cooperating old-build writer (an embedded host or lockless path, as `--old-writer stopped` covers) simulated by a test process that takes no placement lock, appending a valid Store frame and creating a file at a private hook after the `adopting` publication and before manifest A (the write is audited and the root adopted) and after manifest A (`root_changed`, marker `adopting`, lock released); real exclusion at private hooks that pause adopt: `Placement.acquire/2` and a real daemon start attempted immediately after the `adopting` publication are refused (`root_adopting`, daemon exit 124) with the root and the lock unchanged, and attempted immediately after the rename, before the release, are refused `placement_active` (daemon exit 76) and admitted, the daemon serving, only after adopt releases; two adopters started together on one unmarked root, one paused while holding the lock: exactly one reaches the fence and commits, and the other refuses `root_held` with nothing written or, started after the release, reports `already marked`; kill after step 4, after the step 7 link, after manifest A, during the audit, after the rename and before the release: before the rename the root is left `adopting` (or unmarked before the link) with a stale lock, and after it `current`; after every cut whose root is left `adopting`, `admit/1`, `Placement.acquire/2`, `compose/1`, `store backup` and `store restore` with that root as source refuse `root_adopting` with the root unchanged, `report/1` says `adopting`, and a rerun of adopt reclaims the stale lock and repeats the full audit (observed by its decode count) before reaching `current`; after the cut following the rename, the next `Placement.acquire/2` reclaims the stale lock and serves the root, and adopt reports `already marked`; in every successful run the marker becomes `current` only by the rename, while adopt holds the lock and after C = A; **delivered M7-style lock-taking writer**: a separate OS process running the delivered `Placement.acquire/2` path on the root, as the M7 daemon's `Service.acquire_placement/1` and the M7 CLI do, started while adopt is paused at a private hook holding the lock (before the fence, after it and after the rename), is refused `placement_active` with no write to the root, and the root is adopted only on the audited bytes; **retained M7 root** (D24): the [fixture](#technical-adr-0072-m7-fixture) extracted to a temporary directory and checked against its pinned digest is refused `root_unmarked` by `admit/1`, `Placement.acquire/2`, `compose/1` and `store backup` with an independent walk unchanged (the daemon's exit 116 on it is in `daemon_root_format_test.exs`), then adopted with `--old-writer stopped` through `StoreAdmin.test_adopt/3` supplying the workspace reference the fixture's genesis records, so this case is the audit-and-marker proof with the workspace check bypassed and the product path is the release check's [`m7-adopt` lane](#technical-adr-0072-m7-adopt) (D26): the full audit decodes its conversation session, which is the helper parent, the helper child session, the helper binding and run logs and every Store frame; the root differs from the extracted fixture only by the marker; offline `SessionCatalog.list/1` lists the conversation session, the only one the M7 build catalogued, and adds no row; and the read-only child audit of the `m7-adopt` lane's step 5 (`test/support/m7_child_audit.ex`) passes on the adopted fixture with the root unchanged |
| `apps/loopex_composition/test/m7_adopt_child_audit_test.exs` (cases tagged `m7_adopt: :shape` and `m7_adopt: :audit`; `:m7_adopt` excluded in `test_helper.exs`) | Run only by the [`m7-adopt` lane](#technical-adr-0072-m7-adopt), against `T/state`, through `test/support/m7_child_audit.ex` (listed in `test_ignore_filters`), with no runtime, Store, owner or placement started against `T/state` and no file under `T` opened for writing. `shape`, before adopt: exactly one run log under `delegation/*/runs/` and exactly one `settle` whose terminal `child_run_id` is non-null, else the one verdict line `m7-adopt shape: unavailable REASON` with the case passing; a run log that does not decode fails. `audit`, after adopt: the Store log decodes with a complete tail and replays, every session recovers, the one helper run log decodes with a complete tail under identifiers taken from its header as `Restore.Audit`'s `helper_log!/3` takes them, and its `settle` terminal's Base64 `child_session_id` and `child_run_id`, once decoded, name a Store session other than the conversation whose run's terminal record matches the settlement's state, journal version and terminal digest |
| `apps/loopex_composition/test/store_backup_test.exs` | Backup of a closed root with sessions, receipts, artifacts, resources, a helper namespace and earlier restore lineage: `state/` equals an independent walk of the source; capture fields equal an independent derivation; refusals for held, stale, writer-marker, helper-marker, claim, unmarked, existing, nested and symlinked targets, a changed workspace and 65,537 entries; a source write during the copy gives `source_changed` and no `BACKUP`; kill during copy, before rename and after rename leave no `BACKUP` or a complete one; an independent walk shows the source unchanged apart from removed marker temporaries, with a populated helper job index still in place, present in manifests A, B and C and copied into `state/` byte for byte, and absent only from the audit's index; a capture record carrying any member beyond the listed ones refuses `backup_invalid`; the separation refusals are ADR 0037's `auth_separation_test.exs` cases |
| `apps/loopex_composition/test/store_restore_command_test.exs` | Round trips for `lost` (after moving the source aside) and `available`, each committed with lookup current, and the restored root started by composition serving the same sessions; a backup of a root with helper history and its job index restores with the index copied byte for byte, and a service started on it with one job-index entry corrupted in the backup discards that entry, rescans its session and serves, never refusing; second restore of a restored root (lineage 2); each attestation refusal and each path refusal; `old_writer_running` for a live holder, report-only for a stale one; changed backup byte, changed capture, changed manifest; kill at each ADR 0051 phase, then `--resume` reaching committed with the same plan bytes; a `--resume` whose `DESTINATION` argument resolves to another directory than the plan's `destination_state_root` refuses `destination_path_invalid`, and one whose `BACKUP/state` differs from the plan's `backup_state_root` (a copied backup) refuses `backup_invalid`, each before the continuation record with nothing written; a first run under one `HOME` cut after intent, then `--resume` under a `HOME` whose `.loopex/auth` contains the plan's destination, refuses `auth_root_overlap /arguments/destination` with nothing written; `previous_restore_running`; an edited plan file gives `restore_conflict`. Older backup: a session runs further after the backup, the root is moved aside, and `--source lost --discard-later-work` commits; the restored root serves the sessions as they were at the cut, and the retained `attestation` has `discard_later_work` `true` and the retained plan the discard form, both read back byte for byte; `--resume` of that transaction reuses those bytes. Refusals with nothing written: the flag with `--source available` (`discard_requires_lost_source`), the flag with `--resume` (`usage`), and a retained attestation whose flag disagrees with its plan (`backup_invalid`). Without the flag the plan carries the latest form unchanged. After every `commit_unknown` and `cleanup_unconfirmed` the command prints `Restore.lookup/3`'s answer, and at `claim_release` the committed-with-cleanup-pending line, exit 2. The separation refusals, the available source's included, are ADR 0037's `auth_separation_test.exs` cases |
| `apps/loopex_executor_local/test/restore_codec_test.exs` (extended) | The discard attestation form round-trips exactly; a form carrying both `discard_later_work` and `latest_cut`, or `discard_later_work` `false`, is refused; the latest form's bytes are unchanged |
| `apps/loopex_composition/test/restore_workflow_test.exs` (extended) | A plan with the discard form and `source_status` `available` refuses `invalid_plan` before any claim; with `lost` it commits and its receipt equals a latest-form restore's apart from the plan digest. **Job index** (D29): a backup whose `state/` holds `delegation/<runtime>/job-index-v1/` job and `coverage/` entries commits through `restore/2`, the destination holding those entries byte for byte and every manifest the transition records listing them, where the delivered `restore/2` refused it `invalid_current_history`; a resumed transaction of such a backup, cut after intent and re-presented, commits the same way; a member under `delegation/` that is neither the job index nor an admitted helper shape, such as `delegation/<runtime>/job-index-v2/entry` or a writer marker, still refuses `invalid_current_history` with nothing published |
| `apps/loopex_cli/test/store_command_test.exs` | Grammar, defaults, exit statuses 0, 1 and 2, exact output lines including both statement forms, the printed ADR 0037 writer command parsed by ADR 0037's own parser to `/paths/state_root` = destination, the `LOOPEX_HOME` precedence note, and the configuration file byte-identical after restore |
| `apps/loopex_composition/test/delegation_readiness_code_test.exs` | Classification keeps `%{session_id, code}` for each of the three codes and names no session for runtime-page failures |
| `apps/loopex_daemon/test/readiness_closed_root_test.exs` | A root on which the service did further work after a backup, then had one session history made unreadable: readiness `closed` with that session and `invalid_history`; the root moved aside and the earlier backup restored with `--source lost --discard-later-work`; the service on the restored root reports `serving`; an on-demand start reports `project_resources` `unadmitted`. A second case with no activity after the backup restores without the flag |

The installed lane of M8 outcomes 6 and 7 runs backup, restore and the
refusal of the retained M7 root below under the installed artifact.

<a id="technical-adr-0072-m7-fixture"></a>
**Retained M7 root (D24).** W4 produces it once, at M8 implementation step 3,
and it is never regenerated by a check.

- **Producing build.** The `v0.4.0` source release: the commit
  `git rev-list -n1 v0.4.0` names,
  `9fe9618b0fbd89bdbcd5fc7e75ab0a5abb1ebe20`, whose `VERSION` reads `0.3.0`,
  built from a `git archive` extraction of that commit under the canonical
  scoped `umask 022` with `mix deps.get` and `MIX_ENV=prod mix cmd --app
  loopex_cli mix escript.build`, on the floor or current toolchain pair that
  commit's `.tool-versions` names.
- **Producing run.** In a temporary directory `T`: `T/workspace` is a copy of
  M7's `test/fixtures/m7/review/workspace`, and `T/config.json` is an ADR
  0049 file naming `T/workspace`, `paths.state_root` `T/state` and M7's
  `m7.review` profile, with delegation enabled and roles `investigate` and
  `review`, every credential an environment reference. The producer runs
  `apps/loopex_cli/bin/loopex chat --config T/config.json` from the
  extraction with the pinned providers' keys in the environment, asks one
  review that makes the parent call `task` once, waits for the run's
  terminal outcome, and quits, which ends the foreground process and with it
  the root's placement lock. It then checks that `Placement.live_owner/1`
  answers `:none`, that no `placement.lock`, `store.log.writer` or
  `objects.writer` remains, and that the root holds no marker. A run the
  [`m7-adopt` lane](#technical-adr-0072-m7-adopt)'s shape precheck would
  report `unavailable` is discarded and the run repeated.
- **Credential check.** Before archiving, every regular file under `T/state`
  and `T/workspace` is searched for each provider key value the run used,
  with the release runner's redaction match; any occurrence discards the
  run. No credential, token or keyring item is ever written into a root, and
  the fixture holds none.
- **Archive.** `T/state` and `T/workspace` become one canonical archive,
  `m7-root-v0.4.0.tar`: entries sorted bytewise by path, in `:erl_tar`'s
  ustar format, mode as found, `uid` and `gid` 0, owner names empty and `mtime` 0, written by
  `scripts/fixtures/m7-root-archive.exs` (new, W4), which uses
  `:erl_tar` and nothing else. The configuration file is retained beside it
  as `m7-root-v0.4.0.config.json`.
- **Retained location.** A repository test fixture,
  `apps/loopex_composition/test/fixtures/m7_root/`, holding the archive,
  the configuration file and a `README.md` that records the producing commit,
  the exact commands above, the toolchain pair, both providers and models,
  the session identifiers and the archive's SHA-256. A fixture in the
  repository is what the fast check's `store_adopt_test.exs` and the
  installed lane's step 5 can read from a fresh-source extraction; the
  evidence root holds only run outputs.
- **Use.** A test extracts the archive into a temporary directory and
  first checks its SHA-256 against the value pinned in the test. The
  extracted workspace has a new device and inode, so its
  `WorkspaceIdentity.reference/1` differs from the one the M7 genesis
  recorded. `store_adopt_test.exs` therefore adopts through
  `StoreAdmin.test_adopt/3` (new, `@doc false`, as `Restore.test_restore/3`
  is), whose `:workspace_reference` option replaces step 6's computed
  reference with the one the fixture's genesis records; product `adopt`
  takes no such option and always computes it. The installed lane's step 5
  needs no workspace: it proves the refusal of the extracted root and that
  the root stays byte-identical.

<a id="technical-adr-0072-m7-adopt"></a>
**Product-path adoption of a live M7 root (D26).** The fixture case above
bypasses step 6's workspace check, so it proves the audit and the marker,
not the product command. The release lane `m7-adopt`, which W4 owns and
which runs in the `serenity` full release check (and with `--only
m7-adopt`), proves the product path on a root the M7 build writes in the
same run:

1. **Build.** A `git archive` extraction of
   `9fe9618b0fbd89bdbcd5fc7e75ab0a5abb1ebe20`, the commit `v0.4.0` names,
   into a temporary tree under the canonical scoped `umask 022`, built as
   the fixture's producing build is, with `mix deps.get` and `MIX_ENV=prod
   mix cmd --app loopex_cli mix escript.build`, under the current toolchain
   pair `elixir 1.20.3-otp-29` with `erlang 29.0.5`. The tag's
   `.tool-versions` names that pair as its current pair beside the floor
   pair, so either is admitted and the lane uses the one the full check
   runs under. The lane refuses before staging when the tag does not name
   that commit.
2. **Write.** In a temporary directory `T` with its own `LOOPEX_HOME`,
   `T/workspace` is a fresh copy of M7's
   `test/fixtures/m7/review/workspace`, live on its own device and inode,
   and `T/config.json` is the fixture's configuration form for `T`. The M7
   build has no credential-free chat provider, so the lane runs the
   M7 launcher's `chat --config T/config.json` under the release check's
   delivered `with_m7_credentials`, using the real-provider credentials the
   full check already holds, sends one review that makes the parent call
   `task` once, waits for the helper run's terminal outcome and quits. It
   checks, as the fixture producer does, that no placement lock or writer
   marker remains and that the root holds no marker. It records the
   conversation's session identifier, which the M7 build's own `loopex
   sessions --state-root T/state` lists, and takes the first independent
   walk. Its transcript passes through the lane redactor.

   *Shape precheck.* A real provider decides how often the parent calls
   `task` and whether the helper prompts its child, so before adopting, the
   lane runs the child-audit test file's `shape` case (`mix test --only
   m7_adopt:shape`) from the candidate's extraction under
   `without_credential`, against `T/state`, read-only as step 5 is. It
   requires exactly one regular file under `T/state/delegation/*/runs/`,
   decodes it as step 5 does, and requires exactly one `settle` transaction
   whose `terminal`'s `child_run_id` is non-null. The M7 helper legitimately
   settles with `child_run_id` null when the child fails before it is
   prompted or is never created (`helper.ex:1766-1777` and `:1872-1880`,
   both admitted by `run_mutation.ex:286-300`), recovery records an
   uncreated child with both identifiers null (`helper.ex:1927-1938`), and a
   parent may call `task` zero times or twice; these lines are identical at
   `v0.4.0`. The case prints exactly one verdict line, `m7-adopt shape:
   available` or `m7-adopt shape: unavailable REASON`, where `REASON` is
   `run_logs=N` or `settle_child_run=null`, and fails only when a present
   run log does not decode. On `unavailable` the lane stops before step 3,
   leaves the root unadopted and reports its evidence unavailable with that
   reason, as provider variance, never as a failure of the candidate; the
   full check then lacks this lane's evidence until a rerun produces the
   shape. A decode failure is a failure of the candidate.
3. **Adopt.** The candidate's own launcher from the same run's fresh-source
   extraction runs `loopex store adopt --old-writer stopped --config
   T/config.json` with no test option, hook or seam, under
   `without_credential`. It must exit 0 with the root adopted, step 6
   computing the live workspace's reference and matching the one the M7
   genesis recorded, and an independent walk must show the root changed only
   by the marker.
4. **Open.** The candidate then runs `loopex doctor --config T/config.json`,
   which must report `marker: current`, and the read-only offline `loopex
   sessions --state-root T/state`, which opens the adopted root under the
   candidate's marker check and must list the recorded conversation session.
   That is the only session the M7 build catalogued: M7's `LoopexCli.Chat`
   records the parent with `LoopexCli.SessionCatalog.record/3` after
   creating it, while `LoopexComposition.Delegation.Helper`'s
   `create_child` creates the child through Core and the helper ledger
   only, and offline `sessions` lists the catalogue image through
   `SessionCatalog.list/1`, not the Store. Adopt adds only its marker, so it
   adds no catalogue row, and the child is not listed.
5. **Child audit.** No delivered product command reads an uncatalogued
   session offline without writing, so the helper child is checked through
   a read-only test boundary over the delivered decoders: the lane runs the
   `audit` case (`mix test --only m7_adopt:audit`) of
   `apps/loopex_composition/test/m7_adopt_child_audit_test.exs` (new; its
   cases tagged `m7_adopt: :shape` and `m7_adopt: :audit`) from the
   candidate's extraction under `without_credential`, given `T/state` and
   the recorded conversation identifier. The composition suite excludes the
   tag: `apps/loopex_composition/test/test_helper.exs:153`'s
   `ExUnit.start(exclude: [:real_provider, :long_bound])` gains
   `:m7_adopt`, and `--only` selects a case. It starts no runtime, Store,
   owner or placement against `T/state` and opens no file under `T` for
   writing; its shared helper
   `apps/loopex_composition/test/support/m7_child_audit.ex` (new), loaded by
   `Code.require_file` as the other support files are and therefore added to
   `test_ignore_filters` in `apps/loopex_composition/mix.exs:16-23`, reads
   the bytes and runs only pure decoders. It decodes `T/state/store.log`
   with `Loopex.Store.Local.Log.decode_bytes/1`, requiring a complete tail,
   and `Loopex.Store.Local.State.replay/1`, and recovers the conversation
   and every other session with `Loopex.Runtime.SessionState.recover/3`. It
   decodes the one helper run log under `delegation/*/runs/` with
   `RetainedObjects.decode_run/2`, taking its identifiers from the log's
   header exactly as `Restore.Audit`'s private `helper_log!/3`
   (`audit.ex:404-417`) does: `LedgerCodec.decode_frame/1`, then
   `decode_json(payload, :frame)`, then the header's `identity` list
   Base64-decoded. It requires a complete tail and the one `settle`
   transaction the precheck found. Its `terminal`'s `child_session_id` and
   `child_run_id` are Base64 text, as the helper writes them
   (`helper.ex:740`, `:755-756`, carried into the settlement at
   `:2023-2027`), and are decoded with `Base.decode64/1` before use. The
   decoded child must be a Store session other than the conversation whose
   journal recovers, and `SessionState.run_evidence/3` for the decoded run
   identifier must return a terminal record whose state, journal version
   and digest equal the settlement's `state`, `journal_version` and
   `terminal_record_sha256`. The independent walk after this step shows
   every record the M7 build wrote, the child's journal and the helper
   ledgers included, byte-identical to the first walk, the marker being the
   only addition, so the conversation and its helper run are intact.

The shape precheck and steps 3 to 5 contact no provider.

The lane is unattended, retains its complete redacted output and the
independent walks, and reports evidence unavailable, never a pass, when the
tag cannot be built, the M7 run cannot reach its provider, or the shape
precheck reports `unavailable`. The fast check keeps the fixture case,
which runs the same child audit's helper. Store conformance,
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
The [format number rule](#technical-adr-0072-format-number) keeps the marker
truthful across builds: a build whose durable inventory differs writes and
reads another number, so it refuses this build's roots, and this build
refuses its roots, by name before any write.

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
- *Adopt without the placement lock, re-checking the root after the commit.*
  Between publishing `current` and the re-check a legitimate start could
  acquire placement and write, and returning the marker to `adopting` would
  then strand a live writer; two adopters could also overlap. Holding the lock
  through the rename makes the rename the single commit point. The lock's
  files are transient lock state, left out of adopt's manifests.
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

<a id="technical-adr-0072-job-index-audit"></a>
**The job index in restore's audit, not an amendment (D29).** ADR 0051's text
names no job index and says nothing of what the audit's index holds. Its
nearest sentences are the manifest rule ("Preserve every baseline kind, mode,
relative path and file byte/hash without exclusions"), which this change keeps,
the audit's scope ("Audit complete current Store/Local/receipt/artifact/
host-ledger history"; "every shipped host-ledger grammar must validate"), of
which a derived cache is no part, and "Do not ... remove unknowns", which
concerns writes and is kept because nothing is removed. So the following
changes delivered code and no ADR 0051 sentence:

- Delivered `restore/2` refuses a job index in two places today, both
  `invalid_current_history`: `Restore.Workflow`'s private
  `driver_supported_baseline!/2`, whose `helper_shape?/1` admits under
  `delegation/` only runtime directories, digest-named objects and
  `bindings`/`runs` logs, so `job-index-v1` fails it before the audit, both
  on the staged baseline and on the retained baselines of a continuation;
  and `Restore.Audit`'s private `helper_namespace!/4`, whose catch-all
  `["delegation" | _]` clause refuses any other member.
- Both skip every entry whose path is `delegation/<runtime>/job-index-v1` or
  lies under it, unconditionally, so the audit never indexes the job index
  in any mode: adopt's and backup's `root_inventory` and ADR 0051's own
  restore through `restore/2`. The entries are still copied, listed in every
  manifest and compared byte for byte; a member under `delegation/` that is
  neither the job index nor an admitted helper shape still refuses.
- `restore/2` keeps its signature, plan, invocation and result grammar.
  There is no `restore/3`, no audit option and no new `Restore.IO.run/3`
  option; `test_restore/3`'s options stay `:probe` and `:pause_at`. No
  phase, record or outcome is added. The one changed result is that a
  current root holding a job index, which `restore/2` refused, now commits.
- Earlier texts of this record added `restore/3`, first with a
  credential-directory guard every manifest walk applied, which the
  maintainer's D27 removed with ADR 0037's walk rules, and then with an
  `omit_job_index` option, which D29 replaces with the unconditional rule.

<a id="technical-adr-0072-open"></a>
### Resolved Choice

Concept: [Open for the maintainer](0072-store-readiness-marker-backup-and-restore.md#concept-adr-0072-open).

The earlier choice between a strict command and a `--discard-later-work`
statement was decided on 2026-10-13 for the statement, with strict behavior
kept whenever the flag is absent. Its grammar, refusals, retained bytes and
tests are specified in the restore, failure and evidence sections above, and
its ADR 0051 text in the amendment section. Nothing remains open.
