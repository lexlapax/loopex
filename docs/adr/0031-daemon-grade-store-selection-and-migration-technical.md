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
takes it at start and releases it in its own `terminate/2`. What the daemon
owns is the Store *process*. It starts it before the socket is bound and, in a
**daemon-initiated** shutdown, stops it last — after the listener is closed,
every connection is closed and the runtime is stopped — so the marker is held
for as long as any operation **the daemon can end** could still need it, and
is released by that `terminate/2` at the moment the daemon stops the Store.
That ordering is the whole mechanism; it is fixed in the M5 plan's lifecycle
section.

The qualification is deliberate and is the strongest true form. Where the
runtime does not stop within its grace the daemon kills its supervisor, and a
*trapping* descendant — an owner group, or a trapping worker beneath one —
may still be unwinding when the Store goes. **What refuses such a straggler is the drain's fence, not a stopped Store**,
and an earlier revision of this paragraph had it the other way round. The
Store is *not* stopped while a straggler is most likely to be unwinding: the
daemon stops it last, in its own phase, so there is a window in which the
Store is alive and accepting. What makes the straggler harmless is that the
drain moved that session's owner epoch before the runtime came down, so its
commit is refused `:stale_owner_epoch` like any other stale writer. The marker
is therefore never held open by a straggler and no straggler appends behind
the daemon's back — but for the fence's reason, which holds whether the Store
is alive or not, rather than for an absence that only begins later. What the
daemon does not promise is that every process has finished before it exits.

The adapter also **traps exits**, which this arrangement relies on: an owner
that crashes rather than stopping gives the Store's `terminate/2` the chance
to run, so the marker ordinarily comes back.

**Ordinarily, not always**, and the qualification is about process lifetime
rather than about the adapter. The Store runs `terminate/2` only while the VM
is alive, and the command process that monitors the daemon owner halts the VM
the moment it sees that owner's `DOWN` — a race the adapter cannot win from
inside. So **owner loss is crash-equivalent for the marker**: it is released
or it is stale, the daemon cannot tell which, and neither can this ADR. That
costs nothing, because the successor's liveness-probed recovery already
handles both — a marker whose recorded holder is proved dead is reclaimed, one
that cannot be decided refuses `store_writer_unverifiable`, and a live holder
refuses `store_writer_active`. Claiming the release always happens would have
been a claim about scheduling. What leaves it is a kill, a power loss, or a bounded stop
of the Store that expired and had to be ended with `Process.exit(pid, :kill)`
— the three cases the next daemon's verified stale-writer recovery is for.

**Store loss inverts it, and the daemon cannot order what it does not
control.** This adapter answers an append error with
`{:stop, reason, commit_unknown, state}` — it terminates *itself* — and its
`terminate/2` releases the marker as it goes. So on a store loss the marker is
released **before** the daemon can react, and any sequence ending "then stop
the Store" is unrunnable, because the Store is what died. The daemon's only
correct response is a fail-stop, and it arranges to be able to make it: the
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
orderly or otherwise: a daemon's claim on that pathname is its marker, and ADR
0032 makes removing the pathname the next verified marker holder's job
precisely so that no departing daemon can remove a successor's socket. The next daemon finds no marker to
recover, because the dying store already gave it back, and removes the stale
pathname before it binds.

An abrupt kill of the daemon runs no `terminate/2` at all, which is why *that*
leaves a marker behind and why the next daemon's verified stale-writer
recovery exists. The cases are distinct and the operator documentation keeps
them so: a daemon that stops the Store releases the marker in order — whether
that is an orderly shutdown or a fatal class where the Store is still alive
and the daemon stops it before halting; a store loss releases it early and
unexpectedly; and a kill, a power loss or an expired stop leaves it for
recovery. The adapter's limits are the
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

No journal format changes; the daemon, the foreground server and the CLI
reopen one another's roots, and rollback is stopping the daemon. The private
journal is a separate compatibility surface and stays experimental in 0.x.
There is no forward migration, so there is no migration to roll back and no
oldest-reader claim to defend.

Acceptance binds this complete pair at the exact candidate the maintainer
names in the governance record, and it carries exactly one disposition: the
`0.2.0` selection of the local adapter and its documented limits. A successor
adapter is a separate disposition on a separate ADR declaring
`Supersedes: 0031`, recorded once its evidence exists.
