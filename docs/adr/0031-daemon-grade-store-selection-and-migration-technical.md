<a id="technical-depth"></a>
## Technical depth

Concept: [Daemon store selection for `0.2.0`](0031-daemon-grade-store-selection-and-migration.md#concept).

<a id="technical-adr-0031-decision"></a>
### Contract and Evidence

Concept: [Context and decision](0031-daemon-grade-store-selection-and-migration.md#concept-adr-0031-decision).

### M5 selection: the local adapter and its limits

The M5 daemon opens the state root through `loopex_store_local` exactly as
the foreground server does.

**The marker invariant, stated as it actually works.** The daemon does not
hold the marker itself and cannot release it itself: `Loopex.Store.Local`
takes it at start and invokes `WriterLock.release/1` from its own
`terminate/2`. What the daemon owns is the Store *process*. It starts it before
the socket is bound. In an **orderly** shutdown it stops the Store last — after
the listener is closed, every connection is closed and the runtime is stopped
— so the marker is claimed for as long as any operation **the daemon can end**
could still need it. Failed-start reverse cleanup likewise stops a returned
Store pid after every edge that start acquired. A fatal fail-stop is a separate
bounded tail: it stops the executor and then the still-live Store under the
35-second watchdog, while the remaining VM-local components end at
`System.halt/1`; Store-last is not claimed on that path. Those orderings are
fixed in the M5 plan's lifecycle section.

Release is best effort, not a proof of removal. `WriterLock.release/1` first
compares the path's bytes with the exact marker for this acquisition. On a
match it calls `File.rm/1` and syncs the parent, ignores both results and always
returns `:ok`; an unreadable, absent or foreign path also returns `:ok`
(`writer_lock.ex:105-115`). A completed Store `terminate/2` therefore proves
only that this release path was invoked. The healthy-path evidence separately
asserts marker absence and an immediate reopen without recovery. An ignored
unlink failure can leave a complete residual, and an ignored parent-sync
failure means the callback cannot classify the durable removal outcome.

**Acquisition can fail after the marker file is exclusively created but before
there is a Store pid or returned lock handle.** `WriterLock.write_marker/2`
creates the path first and returns an error on a later marker write, file sync,
close or parent-directory sync without unlinking it
(`writer_lock.ex:200-225`). `Local.init/1` then returns `{:stop, reason}` before
its state contains `writer_lock`, so `terminate/2` has no handle to release
(`local.ex:152-168`), and the daemon receives no Store pid it could stop. This
is an existing local-adapter limit, not a cleanup action M5 can perform. A
complete residual marker is handled by the adapter's verified stale-writer
recovery after its recorded Store process or OS process is dead. An empty or
partial marker is undecodable and correctly refuses automatic recovery as
`store_writer_unverifiable`; the operator runbook requires inspection and
explicit removal while no holder is live. The daemon keeps placement through
its failed-start cleanup, reports `store_writer_acquisition_failed`, touches no
socket and makes no claim that reverse cleanup removed this residual.

The qualification is deliberate and is the strongest true form. Where the
runtime does not stop within its grace the daemon kills its supervisor, and a
*trapping* descendant — an owner group, or a trapping worker beneath one —
may still be unwinding when the Store goes. **What refuses such a straggler is the drain's fence, not a stopped Store**,
and an earlier revision of this paragraph had it the other way round. The
Store is *not* stopped while a straggler is most likely to be unwinding: on an
orderly stop the daemon stops it last, in its own phase, so there is a window in which the
Store is alive and accepting. The drain therefore reports the exact fence
disposition rather than claiming every epoch moved. A committed fence moves the
epoch and refuses the straggler as `:stale_owner_epoch`; `:superseded` proves
the sole old transaction won first; an unknown fence remains `unsettled` and
may still resolve while the Store is alive. The marker is never held open by a
straggler, but orderly stop makes no stronger append claim than those reported
dispositions support. The daemon also does not promise that every process has
finished before it exits.

The adapter **traps exits**, but that does not turn owner death into a Store
stop. It defines no `handle_info({:EXIT, ...})`, so the linked owner's abnormal
exit becomes an unhandled mailbox message and `terminate/2` does not run. The
command process then observes owner `DOWN` and halts the VM, which also runs no
termination callback. So **owner loss is crash-equivalent for the marker** and
leaves it stale. The successor's liveness-probed recovery handles that exact
case: a marker whose recorded holder is proved dead is reclaimed, one whose
liveness cannot be decided refuses `store_writer_unverifiable`, and a live
holder refuses `store_writer_active`. A kill, power loss, or bounded Store stop
ended with `Process.exit(pid, :kill)` leaves the same recovery obligation. Any
Store stop that reaches `terminate/2`, deliberate or self-initiated, attempts
the adapter's exact-marker release. On the healthy path the marker is removed;
because the unlink and parent-sync results are discarded, callback completion
cannot distinguish that path from a complete residual or an uncertain durable
removal. A later recovery request applies the existing classifications: a live
holder refuses `store_writer_active`, a proved-dead holder is reclaimed, and a
holder whose liveness cannot be established refuses
`store_writer_unverifiable`.

**The Store marker is physical-writer exclusion; the host placement lock keeps
Runtime Controls from overlapping.** Accepted ADR 0008 distinguishes those
facts, and `LoopexCli.Placement` already implements the latter for the reference
host as a crash-reclaimable `placement.lock` bound to OS pid and process start
identity. M5 moves that implementation without changing its file path, record,
guard, owner-handle or liveness rules into a host utility in
`loopex_composition`; the CLI uses that utility through its existing surface and
the daemon uses the same one. This is reuse of an accepted host invariant, not a
second lock protocol.

The daemon acquires the placement lock **before** it opens the Store or reads,
removes or binds the socket path. On an orderly stop it attempts the
acquisition-specific release only after every Runtime Control is known gone and
the Store has stopped. An unlinked, monitored helper owns that exact call under
one absolute `placement_release_ms: 5_000` deadline. Exact `:ok` followed by the
helper's normal `DOWN` proves only that the attempt completed; a missing,
malformed or abnormal result selects `placement_lock_failed`, and expiry hard
halts without waiting further. Failed-start cleanup and the offline
`prepare-index` command use the same helper and deadline, preserving an earlier
failure class when one is already latched.

`LoopexComposition.Placement.release/1` compares the owner handle and canonical lock
inode before removing the canonical path, then removes the handle; it ignores
both removal results and always returns `:ok` (`placement.ex:77-99,233-241`). A
completed call therefore does not prove either pathname absent. The exact-handle
comparison prevents a delayed release from removing a successor's lock, so a
residual is safe; once the old daemon's operating-system incarnation is proved
dead, the next acquirer reclaims it. On every fatal path other than a final
placement-release failure the daemon instead keeps the lock through
`System.halt/1` and leaves that same recovery to the next process. A second acquisition in the
same VM also refuses while that OS holder is live, which closes the hole a
Store marker cannot close: `WriterLock` deliberately treats a dead recorded
Store pid in the current VM as reclaimable. The supported daemon topology is
therefore safe both across VMs and inside one VM without changing the local
adapter's behaviour for embedded hosts.

**Store loss attempts marker release early but does not release placement.** This
adapter answers an append error with `{:stop, reason, commit_unknown, state}` —
it terminates *itself* — so any sequence ending "then stop the Store" is
unrunnable because the Store is what died. Its existing `terminate/2` invokes
the best-effort writer-marker release; the result cannot prove the marker
absent. The still-live daemon process continues to hold
`placement.lock`, so another daemon or the reference CLI refuses before opening
the Store and before touching the socket. After the daemon halts, the placement
lock is stale and its existing liveness-probed recovery may reclaim it. This
preserves ADR 0008's one active Control per `{Store identity, runtime_id}`
instead of treating Store commit fencing as permission for overlapping
runtime-local caches.

The daemon's only correct response is a fail-stop, and it arranges to be able to make it: the
daemon **start_links the adapter itself**, from an owner process that traps
exits and keeps the adapter's pid, so the termination arrives as
`{:EXIT, store_pid, reason}` at a clause the daemon wrote — carrying the
store's own reason, which is what separates `store_capacity_exceeded` from
`store_lost`. An OTP supervisor would not do: it reports no child's exit
reason to any callback. Nor does the daemon use
`LoopexComposition.with_runtime/2`, whose bracket takes the `start_link`
inside a process `RuntimeOwner` spawns and returns no adapter pid — a daemon
on that bracket could not observe this failure at all. It **does** compose
through `LoopexComposition`: M5 gives that application a caller-owned entry
point which runs the same edge-assembly sequence **in the caller's process**
and returns every pid it linked, so the adapter is started by the composition
code as it always was and the link lands on the daemon's owner. An earlier
revision of this paragraph said the daemon bypasses composition entirely,
which would have meant a second copy of the wiring layer. On the reported exit it
refuses service, closes every connection with `store_lost`, or
`store_capacity_exceeded` where that was the store's own reason, and exits
non-zero. It does **not** unlink the socket — and neither does any other exit path,
orderly or otherwise: a daemon's claim on that pathname is the joint authority
of its host placement lock and its successfully opened Store, and ADR 0032
makes removing the pathname the next verified placement-lock and marker holder's job
precisely so that no departing daemon can remove a successor's socket. A
contender before the old daemon halts cannot acquire the placement lock and
therefore cannot touch the pathname. A contender after the halt recovers the
stale placement lock, then acquires or recovers the Store marker as needed and
removes the stale pathname before it binds.

An abrupt kill of the daemon runs no `terminate/2` at all, which is why it
leaves a marker behind and why the next daemon's verified stale-writer recovery
exists. A failed acquisition after exclusive create can leave the same complete
stale marker or an undecodable partial marker without ever producing a Store
pid. The cases are distinct and the operator documentation keeps them so: a
daemon that stops the Store attempts marker release in order — whether that is
an orderly shutdown or a fatal class where the Store is still alive and the
daemon stops it before halting; a Store self-stop attempts it early; and an
ignored unlink failure, kill, power loss, expired stop or failed acquisition
may retain a complete marker for recovery. A partial startup marker remains an
operator-inspection case. In all fatal cases the independent
placement lock stays until the daemon OS process is gone. The adapter's limits are the
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
  every connection and exits, naming the capacity. The Store attempts its
  best-effort marker release while the daemon's placement lock continues to
  exclude a successor, without changing the refusal or result;
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
daemon; on the healthy path verify marker absence before moving the root
directory aside under a name of the operator's choosing; then start the daemon
on a fresh root with the same placement identity source. A complete residual
uses the existing verified stale-writer recovery or, where liveness is
unverifiable, the documented inspection procedure. A session in a retired root
is resumed only by stopping the daemon and reopening that root, with the daemon
or the foreground server. The daemon's operator documentation states the
capacity, the refusal reason, the frame ceiling, full retention and this
procedure.

Evidence for the M5 selection is the M5 plan's Outcome 1 obligation, not a
second copy here: a root driven to the capacity ceiling refuses the append
with the store's own reason and takes the daemon's listener and connections
down with it and its Store attempts marker release. A contender held at that
cut receives the placement-lock live-owner refusal while the predecessor VM
and Control are live. Only after that daemon halts may verified stale-owner
recovery acquire the placement lock; a same-VM second acquisition refuses by
the same rule. A root already past the bound refuses at open. After a healthy
orderly stop, evidence asserts marker absence and the foreground server's
immediate reopen without recovery; it does not infer either fact from
`terminate/2` returning. A prepared complete residual separately proves the
writer recovery's live, proved-dead and unverifiable branches. The shared
placement-lock tests prove atomic exclusion, same-VM live refusal, cross-VM
live refusal, dead-owner recovery, healthy acquisition-specific release and
that a residual ignored by best-effort release is reclaimed only after the old
operating-system incarnation is dead. The durable format,
callback inventory, arities and result union remain unchanged. The local adapter
and the M1 controllable test Store also gain one conformance case
for the existing `runtime_command/2` read projection: an exact retained create
binding returns `{:completed, %{result: session_id}}`; changed create inputs or
a cross-kind command ID return `runtime_command_conflict`; every query leaves
the root byte-identical. That is a projection correction, not a new persistence
or migration contract.

### What this pair leaves open

A daemon-grade adapter is not decided here, and nothing below prescribes one.
What is recorded is only the shape of the question, so the successor ADR knows
what it has to answer rather than inheriting a preference:

- **Which engine**, chosen on measured evidence rather than on argument. The
  candidates are open; the obvious ones have been named informally and none is
  eliminated or selected here.
- **The unchanged boundary it must implement.** Whatever the engine, it sits
  behind the private port set `Loopex.Store` already fixes for the local
  adapter — `transact/2`, `transaction_status/4`, `runtime_command/2`,
  `ownership_head/3`, `load_records/4`, `load_events/4` and the snapshot store
  and load calls — with no change to callback arity or result shape. ADR 0006
  owner epochs and incarnation identities remain the commit-authority fence,
  the writer marker remains physical writer exclusion, and no adapter stores a
  lease. This much follows from decisions already accepted, so it is a
  constraint on the successor rather than a choice this pair is making.
- **What evidence selects it**: the shared store conformance suite unchanged,
  a semantic fault matrix, commit-ambiguity resolution, bounded replay
  measured rather than claimed, and backup and restore.
- **What migration means**, if any: whether a local root is imported at all,
  how an interrupted import is detected on reopen, what the rollback pair is,
  and which binary is the oldest reader of the new root.

Each of those is settled by the successor's own ADR, proposed with the
successor milestone's plan and accepted on its own review. Until then they
are questions, and this pair does not answer them.

<a id="technical-adr-0031-compatibility"></a>
### Compatibility and Rollback Mechanics

Concept: [Consequences and rollback](0031-daemon-grade-store-selection-and-migration.md#concept-adr-0031-consequences).

No journal format changes; at the Store and journal layer the daemon, the
foreground server and the CLI replay the same bytes, and Store rollback is
stopping the daemon. The private journal is a separate compatibility surface
and stays experimental in 0.x. There is no forward Store or journal-format
migration, so there is no engine migration to roll back and no
oldest-journal-reader claim to defend. ADR 0032's daemon-owned bounded index
and explicit offline legacy import are a compatibility projection outside the
Store adapter: a populated legacy root requires that import before its first
M5 daemon start, while daemon-to-foreground rollback and later switches after
the import need no Store conversion. The index's interrupted-write and
rollback mechanics belong to that decision and never rewrite a journal record.

Acceptance binds this complete pair at the exact candidate the maintainer
names in the governance record, and it carries exactly one disposition: the
`0.2.0` selection of the local adapter and its documented limits. A successor
adapter is a separate disposition on a separate ADR declaring
`Supersedes: 0031`, recorded once its evidence exists.
