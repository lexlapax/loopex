<a id="concept"></a>
## Concept

Technical depth: [Local adapter limits and what stays open](0031-daemon-grade-store-selection-and-migration-technical.md#technical-depth).

- **Status:** Proposed
- **Date:** 2026-09-14
- **Decision owner:** Maintainer
- **Supersedes:** nothing; refines the store posture in vision §12.2
- **Prerequisite for:** M5 outcomes 1 and 5, accepted before the daemon opens
  a state root

This pair decides one thing: which store the `0.2.0` daemon runs on, and what
that choice costs. The file names keep the word *migration* because an ADR's
name is its permanent identity and is not rewritten; the decision no longer
prescribes one. See *What this pair does not decide*.

<a id="concept-adr-0031-decision"></a>
### Context and Decision

The local Store that M1 through M4 use is one append-only framed log per
state root, replayed in full at every open, held by one operating-system
process through a writer marker, with a hard capacity, no compaction and no
session index. That is exactly right for a foreground process that owns one
session at a time and exits with it. The vision's reference daemon runs on
an ADR-selected store, and a daemon-grade Store engine makes operational
claims that the bootstrap adapters were never asked to make: bounded replay,
a Store-owned index, a Store/journal-format migration pair with
interrupted-migration recovery, backup and restore, and a stated oldest binary
that may reopen a migrated root. The vision freezes the store contract, not an
engine, and says adapters are selected by evidence. None of those
**Store-engine** claims is made for `0.2.0`; what has to be decided now is
which store the daemon runs on and what the operator is owed about its limits.
ADR 0032 separately adds a daemon-owned bounded listing index and explicit
offline compatibility import over the unchanged journal. That projection is
not a Store index or Store migration.

**Select the existing local adapter as the daemon's store for `0.2.0`.** The
Store process claims the local writer marker for that Store process's lifetime,
while the daemon owns and watches that process, and the daemon inherits
the adapter's exact, documented limits: one append-only log per state root
with a hard 256 MiB capacity, a 4 MiB frame ceiling, full-history retention
with no compaction, full replay at open, and one writer per root. Reaching
capacity is a truthful stop, never a silent loss, and it is not survivable on
this adapter. The append is refused before a byte is written, with
`store_capacity_exceeded`; the adapter then terminates its Store process and
the caller receives `commit_unknown` for that transaction, because that is
what this adapter does with every append error. An abnormal Store self-stop
runs its marker-release path before the daemon can react, but that path is best
effort: its success result does not prove that the marker was removed. The
daemon therefore holds the **host placement lock** accepted ADR 0008 requires
independently of that marker. It acquires the same crash-reclaimable root lock
the reference CLI uses before opening the Store, and an orderly teardown
attempts its acquisition-specific release only after the old Control is gone
and the Store has stopped. That release runs in a monitored helper under a
fixed five-second deadline; completion is still only a best-effort attempt, and
a timeout hard-halts. A residual remains safe and the next acquirer reclaims it
after the daemon's operating-system incarnation is dead. Fatal exit leaves the
same recovery obligation. This keeps
a successor out while the old Runtime Control may still route consequences
without changing the adapter for every embedded host. So the daemon meets
capacity as a loss of the store, not as a recoverable refusal: it closes the listener
and every connection and exits, naming the capacity in the close, and the
operator retires the root. A log already past the bound is refused at open as
`store_log_too_large` rather than opened and truncated. Nothing committed is
lost and nothing false is recorded, which is what the truthfulness claim
means here. Sessions in a retired root are resumable only by reopening that
root.

The existing marker implementation can leave a residual in two ways the daemon
cannot classify from a release result. Marker creation may fail after exclusive
create but before a Store pid or lock handle is returned. A completed Store
`terminate/2` can also leave the complete marker because `WriterLock.release/1`
ignores marker-unlink and parent-sync failures and always returns `:ok`. A
complete marker follows the adapter's existing live, dead and unverifiable
holder rules; an empty or partial startup marker is unverifiable and requires
the documented operator inspection and removal while no holder is live. The
daemon reports a failed acquisition, keeps placement through cleanup and never
touches the socket. On the healthy release path, marker absence and an immediate
reopen without recovery are the evidence; callback completion alone is not.
This limit is part of selecting the adapter unchanged.

This is a bounded, experimental selection made on
evidence the local adapter already carries; it is not a daemon-grade store,
and the 0.2.0 daemon's operator documentation states these limits and the
retirement procedure. The maintainer chose this on 2026-09-14 over deferring
the ADR entirely: the reference daemon needs a recorded store selection even
when the selected adapter is the existing one, and documenting the ceilings
makes the durable-service claim truthful without adding an engine.

**What this pair does not decide.** An earlier draft also prescribed the
successor milestone's engine candidates, its experiment procedure and its
migration, then said that half bound nothing — while its companion said
acceptance binds the pair. Those cannot both be true, and an ADR that carries
a non-binding half is not one decision. The successor half was withdrawn in
this pair's revision of 2026-09-20, on an independent review's finding. A daemon-grade adapter behind the unchanged private Store ports
remains an open question, and the questions it must answer — which engine, on
what measured evidence, with what migration, what interrupted-import recovery,
what backup and restore, and which binary is the oldest reader of the new root
— are named in the companion as open, prescribed nowhere. They are settled by
their own ADR, proposed with the successor milestone's plan, accepted on its
own review, declaring `Supersedes: 0031` for the selection this pair makes.
Nothing about that work binds M5, and nothing in M5 forecloses it: the local
durable format and private port shape are unchanged. ADR 0032's daemon-owned
listing index and legacy-root import remain an external compatibility
projection, not part of this adapter or its journal. M5 adds the missing read
projection for a retained create through the existing `runtime_command/2`
callback and result union. The daemon also reuses the reference CLI's existing
placement-lock mechanism through a shared host utility; this changes no Store
callback, transaction or durable byte and preserves the lock's current path,
record and recovery rules. The read-only marker query an earlier revision proposed is
gone with the unlink it was invented for, so any successor starts from
exactly the root M5 leaves.

**Alternatives rejected.** Deferring this decision out of M5 entirely was
rejected on 2026-09-14: the reference daemon still needs a recorded store
selection, and the local adapter's ceilings are a fact the operator must be
told rather than an absence of decision. Building the daemon-grade adapter
inside M5 was rejected because it doubles the milestone's evidence — a new
engine, its fault matrix, its migration and its rollback — without adding a
proved capability to the durable-service question M5 exists to answer.
Deciding the successor's engine and migration procedure here, ahead of the
experiments that would inform them, was rejected on 2026-09-20: a decision
recorded before its evidence is a preference, and one that has to call itself
non-binding to be tolerable is not a decision at all.
Raising or removing the local log's 256 MiB capacity to postpone retirement
was rejected because a silently growing log trades a truthful refusal for an
unbounded replay at open. Changing the local adapter so that a capacity
refusal is definite and survivable — answered as a plain refusal without
terminating the Store, so a daemon could keep its observers attached and stop
in an orderly way — was rejected for M5 on 2026-09-20. It is a change to the
Store's own behaviour at the one point where that behaviour is most
load-bearing: today every append error is commit-ambiguous, and separating one
error class from the rest means proving, through the shared conformance suite
and the fault matrix on every adapter, that the separated class is definite in
every injection and that no other class quietly joins it. That is the
successor adapter's evidence, and buying it here would double M5's store
evidence to make one operator message nicer. Until then the daemon's capacity
behaviour is the adapter's, stated plainly rather than promised away.

**Implementation and milestone-closure evidence.** The M5 half is a durability claim, so
its class is process and store fault injection on the real adapter plus a
rollback proof: a root driven to capacity refuses the append with the store's
own reason, terminates the store, and the daemon closes the listener and every
connection and exits naming the capacity, with nothing committed lost; a root
already past the bound refuses at open; and after a healthy orderly stop on a
root below the bound the marker is absent and the foreground server and
reference CLI immediately reopen it without recovery. Recovery evidence covers
a complete residual marker whose holder is live, proved dead or unverifiable;
the Store's `terminate/2` result itself cannot say which filesystem action
failed when the residual remains. The existing
Store conformance lane gains the exact create-history projection case on the
real local adapter and its controllable test Store: an exact canonical create
binding returns `{:completed, %{result: session_id}}`, while changed options and
a cross-kind command ID return `runtime_command_conflict`, with byte-identical
durable storage. No new Store callback or persistence conformance class is
required. That is the whole of the evidence this pair owes, because that
selection is the whole of what it decides.

Technical depth: [Contract and evidence](0031-daemon-grade-store-selection-and-migration-technical.md#technical-adr-0031-decision).

<a id="concept-adr-0031-consequences"></a>
### Consequences, Compatibility and Rollback

The daemon and its clients see the same durable session truth the embedded
API and the foreground server see; the store adapter is a host choice, not a
semantic one. In M5 the foreground server, the reference CLI and the daemon
all run on the local adapter and can reopen the same journal bytes. ADR 0032's
separate daemon index means a populated legacy root needs its one-time offline
import before the first M5 daemon start; daemon-to-foreground rollback and
later switches after that import need no Store or journal conversion. A root that
reaches the local log's capacity takes its daemon down with it and is retired
by the operator; nothing already committed is lost, and the operator
documentation says plainly that capacity is an outage rather than a
degradation, so that the ceiling is planned for rather than discovered. The private journal format
is a separate compatibility surface: adding an adapter later freezes no wire,
artifact or embedded contract, and the exact private format stays
experimental in 0.x.

M5 rollback is stopping the daemon in its ordered Store-last path, which runs
the Store marker's best-effort release and then attempts the placement lock's
exact-handle release, under its fixed helper deadline, only after the old
Control and Store are gone. The healthy
path proves release by marker absence and immediate foreground-server and CLI
reopen, rather than by either release function's unconditional `:ok`. A Store
that exits abnormally on its own attempts its marker release, but the placement
lock still names the live daemon process and refuses a contender until the
daemon halts. Either release can leave a complete residual after an ignored
unlink failure: Store-marker recovery applies the existing live, dead and
unverifiable classifications, and the next placement acquirer reclaims a stale
lock only after proving the old operating-system incarnation dead. A kill or
power loss leaves the same recovery obligations. There is no forward Store or
journal-format migration to roll back. ADR 0032's offline daemon-index import
can leave only the complete bounded projection states and residuals that its
own rollback contract names; it never rewrites the journal.

Technical depth: [Compatibility mechanics](0031-daemon-grade-store-selection-and-migration-technical.md#technical-adr-0031-compatibility).

## Governance Record

| Decision | Authority | Authority evidence | Bound bytes |
| --- | --- | --- | --- |
| Acceptance | — | — | — |
