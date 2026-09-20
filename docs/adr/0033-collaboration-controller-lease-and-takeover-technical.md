<a id="technical-depth"></a>
## Technical depth

Concept: [Collaboration: controller lease and takeover](0033-collaboration-controller-lease-and-takeover.md#concept).

<a id="technical-adr-0033-decision"></a>
### Contract and Evidence

Concept: [Context and decision](0033-collaboration-controller-lease-and-takeover.md#concept-adr-0033-decision).

### Lease record

The daemon keeps one lease record per session in its own process memory,
never in the session journal, in a file or in any store:

```text
session_id, writer_epoch, holder (connection identity), granted_at (monotonic),
deadline (monotonic), state ∈ {held, released, expired}
```

`writer_epoch` is an opaque string from ADR 0023's identifier alphabet, at
most 64 bytes, carrying at least 128 bits of fresh randomness. It is minted
at every grant and never reused: not across grants to the same connection and
not across a restart of the daemon, which is the only restart that exists
because a lease owner's failure takes the daemon with it. Clients treat the epoch as opaque and compare it
only for equality. The daemon incarnation is a fresh opaque identifier
generated at each daemon start and reported by `daemon.status` as a
diagnostic; it confers nothing and is not part of the epoch.

The writer epoch is a **daemon** fact and stays one. Core never receives it,
never stores it and never checks it; the daemon checks it before forwarding a
mutation and core is handed an ordinary command afterwards. Core's own
fences are untouched and unrelated: the Store's `{owner_epoch,
owner_incarnation_id}` pair under ADR 0006, runtime control's post-commit
fence admitting the exact generation and owner pair, and command identity for
idempotency. Those remain the commit-authority fence, and they answer a
different question — which coordinator owner may commit — than the writer
epoch does, which is which client may drive.

One owner process per session serializes every lease read, grant, renewal,
release and expiry transition with that session's mutation-admission handoff,
so a takeover cannot pass a mutation whose holder check has already started
but whose core admission is unresolved; that admission first resolves, or the
daemon's own holder-and-epoch check refuses it before it ever reaches core.

A revision of 2026-09-20 proposed collapsing these into one process for the
daemon holding a record per session. The maintainer rejected that on
2026-09-20 and kept the process per session: the process *is* the
serialization boundary and the holder of that session's in-flight admission
set, and collapsing it would put every session's lease transitions behind one
mailbox. The plan's companion states the population and its bound.

**A lease owner's failure ends that session's collaboration state, not the
daemon**, on the maintainer's decision of 2026-09-20. The owner holds the
session's in-flight admission set in its own memory, and that set is the basis
of the expiry rule below: a takeover is granted only when it is empty. An
owner that dies takes the set with it, so no successor owner can inherit it —
and none tries to. What happens instead is exactly what happens when a lease
is gone by any other route:

- the daemon closes that session's **controller** attachment with
  `control_owner_lost`, the wire reason ADR 0032's generation-2 inventory
  carries for it, and leaves every observer attached, because an observer
  holds no lease and loses nothing;
- the lease itself is gone, held by nobody;
- the next `session.acquire_control` for that session starts a **fresh**
  owner, holding no lease and no admission set, and mints a **fresh epoch** —
  the same takeover mechanics this ADR already defines for a lease that has
  been released.

The fresh epoch alone is **not** what makes the lost set harmless, and an
earlier revision of this section said it was. It stops a *later* command from
the old tenure, which is a different thing from ordering: a successor's first
call could still reach a coordinator ahead of an older call that was already
on its way, because core orders what it receives rather than what is in
flight, and core never sees the writer epoch at all.

**The daemon closes that window with one fixed process, the admission relay**,
added on the maintainer's decision of 2026-09-20. Every **lease-authorized
existing-session mutation** — the set this pair lists below, each carrying
`writer_epoch` and admitted only from the recorded holder — is routed through
it, and nothing else is: reads are not ticketed, since a read grants nothing,
orders nothing, and a blocking read would otherwise hold a takeover for as
long as an observer sat on it.

The lease owner **calls** the relay and waits for the acknowledgement before
the core call is made, so no mutation exists that the relay has not recorded;
the relay **monitors** every lease owner, so the BEAM's per-sender message
ordering puts every ticket an owner sent ahead of that owner's `DOWN`; it
survives lease-owner death, being fixed rather than per-session; and **a
replacement owner's first grant for a session blocks until that session's
outstanding tickets have settled**.

A ticket settles **only** when the relay has the call's real outcome — its
task returning core's answer, refusal included. A task that dies **without**
one settles nothing and keeps its ticket: a delivered call completes whether
or not its caller lives, so a dead task says nothing about whether core
received the mutation, and the relay exits `relay_lost` rather than admit a
successor over a mutation it can no longer account for. A connection
disappearing settles nothing either, because the call it made is still
running.

So the ordering claim rests on the relay, and the session-scoped rule gives
the rest: the successor is granted a fresh epoch, the dead controller's
connection is closed with `control_owner_lost`, and no command from the old
tenure can be admitted afterwards. The cost is still stated honestly: the
daemon does not tell a new controller what an earlier mutation did, only that
nothing of it is still unaccounted for.

An earlier draft had the daemon restart the owner and carry on with its
sockets intact, and a 2026-09-20 revision made the failure fatal to the whole
daemon instance. Both are superseded: the restart was wrong because a
restarted owner would claim an admission set it cannot know, and daemon-fatal
was the smaller design the maintainer declined on 2026-09-20 — it ends every
other session's work for one session's fault, where the relay ends none of it.

So a lease owner's failure is **session-scoped**, and the daemon's own
structure supplies that without special-case code: each lease owner is
`start_link`ed by the daemon's owner process, which traps exits, and its
`{:EXIT, pid, reason}` clause maps the pid to the session it belonged to
rather than to a daemon-wide class. Every other linked process the daemon
holds is still daemon-fatal — the relay included, because a daemon without it
can no longer honour the ordering rule for any session. The lease owners are
the one class with a session-scoped rule. There are no restarts to configure
and no strategy to get wrong: nothing is restarted, and the next acquisition
starts a new owner from nothing.

**When an owner exists at all.** One starts on the **first lease operation for
that session after its existence has been validated**, not at activation: a
dormant session is acquired *before* it is resumed, and `attach --take-over`
may acquire and release a session it never activates, so an activation-scoped
owner would not exist when the lease it serves does. One retires when the
lease is free, no acquisition is waiting, and the relay holds no outstanding
ticket for that session — all three, since any one alone would retire an owner
something still depends on.

Retaining the in-flight set in a survivor was the alternative and was
rejected: whichever process held it would then be the process whose failure
loses it, so the window moves up one level rather than closing, and a daemon
that cannot lose the set is a daemon that has made the set durable — a durable
lease record by another name, which this decision rejects for its own
reasons. The relay is not that: it holds no lease and no authority, only the
fact that a call it made has not yet been accounted for.

Expiry and
admission use the daemon's monotonic clock: a deadline is set only by a
successful grant or renewal, and a wall-clock jump cannot shorten or extend
a live holder's authority. Nothing about a lease is persisted or recovered.
After a daemon restart no lease exists, every session is uncontrolled, the
previous socket and its connections are gone, and a client presenting an old
epoch is refused both because it can never match and because it is not a
holder connection. Writer exclusion between two daemons on one state root is
the local store's writer marker, unchanged.

### Methods and fields

- `session.acquire_control` (`session_id`, `request_id`): grants control when
  no lease is held, or when the held lease is released or expired; refuses
  with `control_held` otherwise, **carrying no epoch** — an epoch is
  authority-shaped, and a client that was just refused control is the last one
  that should be handed the current one. An earlier revision of this sentence
  said the refusal named it; ADR 0032's error table is the contract and it
  carries nothing beyond the envelope. The result carries
  the new `writer_epoch` and `expires_in_ms`, the remaining term on the
  daemon's clock. For a known dormant session, a connection may acquire by
  session ID before attach. The daemon validates durable session existence
  first, and it does so with core's read-only session-existence query — the
  one that asks only whether the root holds that ID, with no attach, no
  resume and no side effect. Its answer is one of the five in
  ADR 0032's closed set and nothing more — it says whether the root holds the
  session, not whether this daemon has activated it, which is a daemon fact
  core does not carry. Acquisition therefore does **not** refuse a dormant
  session: a dormant session is acquired here precisely so it can be resumed,
  which is the sequence this ADR's concept sets out. That matters here more than anywhere: acquire
  must be safe to call on an ID that turns out to be unknown, and an earlier
  draft that learned existence by calling `attach` or `resume` would have
  taken a durable or attaching side effect to answer a question. The
  maintainer rejected that on 2026-09-20. An unknown ID refuses with nothing
  created, nothing attached and no lease granted; a known one grants, and the
  held lease lets that connection call `session.resume` and then attach. Daemon startup recovery of sessions is a root-owner operation under
  the store's writer marker, never a client mutation and never a grant of
  controller authority.
- `session.release_control` (`session_id`, `request_id`): releases the
  caller's own lease; a non-holder refuses.
- Renewal is implicit on any admitted command and explicit through
  `session.acquire_control` from the holder, which extends the deadline
  without changing the epoch.
- Every existing-session mutation in generation 2, including
  `session.resume`, `session.prompt`, `session.steer`,
  `session.follow_up`, `session.abort`, `session.respond_interaction`,
  `session.admit_resources` and `session.activate_skill`, carries
  `writer_epoch`. The daemon admits it only if the sending connection is the
  recorded holder, the epoch matches, the lease state is `held`, the deadline
  is later than the live daemon's monotonic admission time, and the
  connection holds a controller-capable attachment, except that a verified
  dormant session's `session.resume` may precede attach under that
  connection's held lease. The check and core handoff are serialized against
  lease transitions for the session. A mismatch or failed condition refuses
  before core admission and before a session write; an observer who copied
  the visible current epoch still refuses. Queries and attach carry no epoch.
- `session.create` has no `writer_epoch` because the session lease does not
  exist. It creates an uncontrolled session, and creation never implicitly
  grants control. The caller must acquire control explicitly and use the
  returned epoch for its first session command. Acquire and attach may be
  sent in either order, because acquire is keyed by session ID and validates
  only durable session existence, through the read-only query; the
  constraint is on the first mutation,
  not on the two calls that precede it, and that mutation refuses unless the
  sending connection is the holder, the epoch matches and the connection
  holds a controller-capable attachment.
- **Only an explicit release releases early.** A successful
  `session.release_control` from the holder frees the lease at once. Every
  other way a connection ends — an orderly close, an EOF, a killed client, a
  severed socket — leaves the lease to expire on its term.

  An earlier draft said an orderly close released the lease while an abrupt
  loss waited. That cannot be implemented over a Unix-domain socket and is
  withdrawn: the daemon sees EOF, and EOF is EOF. A client that closed
  politely and a client that was killed present the reading end with exactly
  the same event, so a rule that distinguishes them is a rule the daemon
  cannot execute. Binding early release to a message the client actually sent
  is the only version of this the transport can support, and it is also the
  more honest one — a controller that wants to hand over says so.

### Expiry against an in-flight admission

Two rules above meet at the deadline and their order has to be stated, not
left to the implementation. The lease owner serializes a lease
transition against a mutation whose holder check has already started, so a
takeover cannot pass an admission core has not yet resolved; and takeover is
admitted at expiry with no grace. The linearization rule is:

1. A mutation whose holder, epoch, state and deadline check *completed* while
   the deadline was still in the future is **in flight** and settles under
   that lease, even if the deadline passes while core's admission is
   unresolved. It completes or fails on its own terms; it is neither retried
   nor fenced by the expiry.
2. At the deadline the lease state becomes `expired` and the holder gains
   nothing further: every mutation whose check begins at or after the deadline
   refuses, including one from the holder, and renewal no longer extends it.
3. A takeover becomes **eligible** at the deadline and is **granted** only
   once every in-flight mutation for that session has resolved. Until then the
   acquire waits, bounded by the acquiring request's own deadline; a wait that
   exceeds it refuses with **`control_pending`**, the stable reason ADR 0032's
   generation-2 error inventory carries for exactly this case, and the client
   may acquire again. It is distinct from `control_held`, which says another
   client holds the lease; `control_pending` says only that this acquisition
   ran out of time behind an admission that had not resolved.
4. The grant then mints a fresh epoch, so nothing admitted under the previous
   lease can be confused with anything after it.

This adds no grace to the lease. The expired holder gains no new authority; it
only finishes what it had already started, which is the same guarantee the
serialization rule gives at every other moment. A holder cannot extend its
tenure by starting work, because rule 2 refuses every new check at the
deadline and the in-flight set can only shrink.

Proposed terms bound at acceptance: lease length 30 seconds, renewal interval
10 seconds for the reference clients, takeover eligible when the live daemon's
monotonic deadline is reached and granted when the in-flight set is empty, no
grace period beyond the lease itself.

### Cancellation across processes

`session.abort` is the durable abort command the core already accepts. The
daemon forwards it from the current controller regardless of which
connection or process admitted the command that started the running work,
because dispatch, cancellation and the two-phase abort with its truthful
`cancelled` or `outcome_unknown` terminal belong to the core's coordinator,
not to the client that prompted. An observer's abort refuses before
admission.

### Authority

Control is a daemon-owned scheduling fact. It grants no effect: host policy,
grants, fences and executor validation apply to a controller's tool calls
exactly as to a single-client session. The daemon's configuration may
restrict takeover to the daemon's own operating-system user, which the socket
already enforces, and to an operator-supplied allow rule; it cannot admit a
command that host policy would refuse. No client content, model output,
interaction answer, metadata, request identity or attachment order confers
control, and a read-only attachment never admits a command whatever it sends.
The daemon's observer role is connection authorization. An explicit successful
acquire grants that connection a controller role scoped to the lease; neither
the existing core attachment handle nor an observer's knowledge of the epoch
is itself command authority.

### Evidence

Tests prove: exactly one controller with observers within the ADR 0032 bounds;
a stale epoch, copied current epoch, non-holder connection, released state
and expired state each refused before core admission with the current
controller unaffected; a lease transition racing command admission preserves
this order; the expiry linearization above, with a mutation blocked inside
core across the deadline settling under its own lease while the eligible
takeover waits and is granted only after it resolves, the holder's next
mutation refused at the deadline, the acquiring request refusing with
`control_pending` when its own deadline elapses first, the holder's connection
disconnecting while its mutation is in flight, and the lease owner
failing while a mutation is in flight — in every case exactly one of settle or
refuse, never both, and no epoch reused; takeover only after release or expiry
with a fresh epoch minted before the successor's first command; the three ways
a controller stops holding proved separately, because only one of them is
early and the transport cannot tell the other two apart — an explicit
`session.release_control` frees the lease at once, while an EOF from a politely
closed client and a killed client both wait for expiry, with a takeover
refused before the deadline and granted after it in both cases; a controller
killed mid-run fenced after takeover, its late commands refused; a
lease owner killed while a mutation is in flight taking the
listener, every connection and the daemon down with it, after which the
restarted daemon holds no lease, has activated nothing, and the previous
holder's delayed command is refused on both the holder and the epoch check;
an abort from the new
controller cancelling work dispatched under the old controller's command
with a truthful cleanup outcome; an observer never acquiring authority
through content, metadata, answers or order; after a daemon restart every
session uncontrolled, an epoch from before the restart refused, and the
first acquire granting a fresh epoch; forward and backward wall-clock jumps
not changing live admission or takeover timing; creation yielding an
uncontrolled session and requiring both attach and explicit acquire before
prompt, proved in both orders, with the prompt refused while either is
missing; a dormant session acquired by ID, then resumed with epoch and
attached.

### Alternatives

Placing the lease in core was rejected because the vision keeps collaboration
policy above core and another host may choose a different rule. Last-writer-
wins without an epoch was rejected because a killed controller's late command
would interleave with the successor's. A lease with no expiry was rejected
because a crashed controller would hold the session forever. A durable lease
record was rejected: after a daemon restart every connection is gone with its
socket and admission already requires the holder connection, so durability
could only preserve an epoch counter that nothing needs. A counter-based
epoch scoped to the daemon incarnation was rejected on 2026-09-14 because a
lease-owner process restart under the same incarnation would mint values
already issued, and a connection re-acquiring after such a restart could
have its own earlier delayed command admitted; a fresh random epoch per
grant costs nothing and closes that hole.

<a id="technical-adr-0033-compatibility"></a>
### Compatibility and Rollback Mechanics

Concept: [Consequences and rollback](0033-collaboration-controller-lease-and-takeover.md#concept-adr-0033-consequences).

The lease methods and the `writer_epoch` field exist only in generation 2 of
the experimental protocol, which is the only generation the daemon serves.
The M4 foreground server still has its own single connection and no daemon
lease. Core session records, events and snapshots are unchanged. Removing the
daemon removes the lease with it; no journal or file depends on it.

Acceptance binds this complete pair at the exact candidate the maintainer
names in the governance record. Its evidence and compatibility claims remain
unproved until the tests the M5 plan maps to Outcome 3 exist and pass.
