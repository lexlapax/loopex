# 0009: Technical depth

<a id="technical-depth"></a>
## Technical depth

Concept: [Attachment, cursor, retention, and session residency](0009-attachment-cursor-and-residency.md#concept).

<a id="technical-adr-0009-context"></a>
## Why Residency Is a Separate Question From Durability

Concept: [Context](0009-attachment-cursor-and-residency.md#concept-adr-0009-context).

Durability answers what survives a crash. Residency answers what occupies memory
right now. `M1` never had to separate them because the two coincided: the caller
owned the runtime, so a session was resident exactly while its caller lived, and
durable exactly as the store recorded.

`M2` breaks the coincidence. A session is durable whether or not anyone is
attached, and resident whether or not anyone is attached — and those are now
independent. Leaving residency unspecified does not make it absent; it makes it
"forever," which is a policy nobody chose.

The failure is quiet and then sudden. Each abandoned session holds a coordinator,
its supervised children, cached projections, and dispatcher buffers. Nothing
looks wrong until the daemon's memory is exhausted, at which point every session
dies together and the cause is indistinguishable from a leak in any other
component.

The reverse error is equally available: evicting a session that still has work in
flight. That would contradict the milestone's purpose directly, since "the client
died and the work continued" is the thing being proved. So residency needs both a
release rule and a hold rule, and the hold rule is about work rather than
attachment.

<a id="technical-adr-0009-decision"></a>
## Exact Attach Transaction, Cursor Rules, and Residency States

Concept: [Decision](0009-attachment-cursor-and-residency.md#concept-adr-0009-decision).

The attach transaction, runtime-owned and race-free, follows the vision's
sequence:

```text
negotiate protocol and capabilities
-> host authorizes transport and read/write capability
-> dispatcher establishes an attachment barrier at committed sequence N
-> obtain an authoritative snapshot anchored at exactly N
-> buffer only durable events after N for that attachment
-> deliver snapshot, then buffered, then live, contiguously
-> deduplicate by session, event sequence, and event ID
```

The client never separately reads state and subscribes. That two-call shape is
the race this transaction exists to close, and it is the reason paged history
read must be a distinct API that cannot be composed into an attach.

Cursor rules:

| Rule | Consequence |
| --- | --- |
| A cursor is a committed public-event sequence position | It survives daemon restart with no stored state |
| A cursor carries no authority | Holding one never makes a client the controller |
| A cursor resolvable against retained history resumes contiguously | No gap across client restart or daemon restart |
| A cursor older than retained history returns `cursor_expired` | Explicit error plus a fresh snapshot and cursor; never silent truncation |
| Duplicates are permitted, gaps are not | At-least-once delivery, deduplicated by session, sequence, and event ID |

Retention is a configured bound on committed public-event history with a
documented default. The bound is expressed in a unit an operator can reason
about, and the boundary is provable: a test drives history past it and asserts
`cursor_expired` rather than a gap.

Residency states:

| State | Entered when | Holds |
| --- | --- | --- |
| `resident` | A session is created, attached to, or resumed | Coordinator and supervised children live |
| `idle` | Attachment count reaches zero with no active run | Grace timer runs; still fully resident |
| `non_resident` | Grace elapses while attachment count is zero and no run is active | Runtime resources released; durable truth untouched |

Hold rule: an active run pins `resident` regardless of attachment count. The
grace timer starts only when the session has no attachments *and* no work. A
session that is mid-run with a dead client stays resident until the run reaches a
durable terminal result, which is the milestone's purpose stated as a rule.

Eviction is observable — the transition is emitted so an operator and a test can
both see that it occurred and why, and it is not a committed public event,
because it is a residency fact rather than session truth.

Resume after eviction reconstructs from the store. The obligation is exact: a
snapshot served after eviction at sequence N must be byte-identical to one a
resident session would serve at sequence N. If they differ, residency has become
observable in session truth, which means the daemon has started being a source of
truth rather than a surface over one.

<a id="technical-adr-0009-alternatives"></a>
## Alternative Analysis

Concept: [Alternatives](0009-attachment-cursor-and-residency.md#concept-adr-0009-alternatives).

**Durable attachments.** A stored subscriber record lets a client resume by
identity. It buys nothing a cursor does not already provide, and it costs a
durable row per client that must be created, updated on every position advance,
and reaped when the client never returns. The reaping problem is the same
residency problem one layer down, now with storage writes on the hot path.

**Unbounded retention.** Removes `cursor_expired` from the protocol and makes
every cursor eternally valid. The bound still exists — it is the disk — so the
choice is between a named error and an unnamed failure.

**No eviction.** Correct until it is catastrophic. Worth noting it is also the
easiest thing to ship and the hardest failure to diagnose later, which is the
combination that makes it worth deciding now rather than after.

**Client-requested eviction only.** Residency becomes a client responsibility.
The client that should release is the one that crashed, so this is a policy that
works exactly when it is not needed.

**Evict on zero attachments immediately.** No grace period. Rejected because a
reconnecting client — an editor restarting, a network blip — would pay a full
reconstruction each time, and because a run in flight would need the hold rule
anyway.

<a id="technical-adr-0009-consequences"></a>
## Operational Consequences

Concept: [Consequences](0009-attachment-cursor-and-residency.md#concept-adr-0009-consequences).

Every client must handle `cursor_expired`, including the reference client. This
is a real obligation and it appears in the protocol vectors so a client author
cannot miss it.

The grace period and retention bound are configuration with no universally
correct values. Tests shorten the grace period so eviction is provable in seconds
rather than assumed; a test that waits out a production default is a test nobody
runs.

The byte-identical snapshot requirement is the strongest constraint here. It
rules out any daemon-side cache that could diverge, and it means reconstruction
must be deterministic from committed history. That is a desirable pressure: it
keeps the daemon a projection rather than an authority.

Residency and durability being independent means two things can now be true at
once that operators may find surprising — a session can be non-resident and
perfectly healthy, and a session can be resident with no attachments. Both are
correct, and the observable transition is what makes them legible.

<a id="technical-adr-0009-compatibility"></a>
## Compatibility and Rollback Mechanics

Concept: [Compatibility, migration, and rollback](0009-attachment-cursor-and-residency.md#concept-adr-0009-compatibility).

No public compatibility claim. No durable attachment or cursor record exists, so
there is nothing to migrate. Retention bound and grace period are configuration
with documented defaults and can change without a schema change.

`cursor_expired` is part of the protocol's closed error set, so adding or
changing it is an ADR 0008 version change rather than a local edit.

Rollback is removing the residency policy — sessions then stay resident, which is
the pre-decision behaviour — while no operator guidance depends on eviction.
