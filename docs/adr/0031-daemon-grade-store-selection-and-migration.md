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
an ADR-selected store, and a service makes operational claims that the
bootstrap adapters were never asked to make: bounded replay, an index, a
migration pair with interrupted-migration recovery, backup and restore, and
a stated oldest binary that may reopen a migrated root. The vision freezes
the store contract, not an engine, and says adapters are selected by
evidence. None of those operational claims is made for `0.2.0`; what has to
be decided now is which store the daemon runs on and what the operator is
owed about its limits.

**Select the existing local adapter as the daemon's store for `0.2.0`.** The
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

**What this pair does not decide.** An earlier draft also prescribed the
successor milestone's engine candidates, its experiment procedure and its
migration, then said that half bound nothing — while its companion said
acceptance binds the pair. Those cannot both be true, and an ADR that carries
a non-binding half is not one decision. The successor half is withdrawn on
2026-09-19. A daemon-grade adapter behind the unchanged private Store ports
remains an open question, and the questions it must answer — which engine, on
what measured evidence, with what migration, what interrupted-import recovery,
what backup and restore, and which binary is the oldest reader of the new root
— are named in the companion as open, prescribed nowhere. They are settled by
their own ADR, proposed with the successor milestone's plan, accepted on its
own review, declaring `Supersedes: 0031` for the selection this pair makes.
Nothing about that work binds M5, and nothing in M5 forecloses it: the local
adapter, its format and its ports are unchanged, so any successor starts from
exactly the root M5 leaves.

**Alternatives rejected.** Deferring this decision out of M5 entirely was
rejected on 2026-09-14: the reference daemon still needs a recorded store
selection, and the local adapter's ceilings are a fact the operator must be
told rather than an absence of decision. Building the daemon-grade adapter
inside M5 was rejected because it doubles the milestone's evidence — a new
engine, its fault matrix, its migration and its rollback — without adding a
proved capability to the durable-service question M5 exists to answer.
Deciding the successor's engine and migration procedure here, ahead of the
experiments that would inform them, was rejected on 2026-09-19: a decision
recorded before its evidence is a preference, and one that has to call itself
non-binding to be tolerable is not a decision at all.
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
behaviour is the adapter's, stated plainly rather than promised away.

**Evidence its acceptance requires.** The M5 half is a durability claim, so
its class is process and store fault injection on the real adapter plus a
rollback proof: a root driven to capacity refuses the append with the store's
own reason, terminates the store, and the daemon closes the listener and every
connection and exits naming the capacity, with nothing committed lost; a root
already past the bound refuses at open; and after an orderly stop on a root
below the bound the foreground server and reference CLI reopen it. No new
conformance evidence is required, because the adapter and its suites are
unchanged — which is the point of selecting it. That is the whole of the
evidence this pair owes, because that selection is the whole of what it
decides.

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
same root under the same placement identity. There is no forward migration to
roll back, because M5 introduces none.

Technical depth: [Compatibility mechanics](0031-daemon-grade-store-selection-and-migration-technical.md#technical-adr-0031-compatibility).

## Governance Record

| Decision | Authority | Authority evidence | Bound bytes |
| --- | --- | --- | --- |
| Acceptance | — | — | — |
