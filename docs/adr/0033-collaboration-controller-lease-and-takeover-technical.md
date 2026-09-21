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
at every grant and never reused: not across grants to the same connection,
not across the fresh owner a lease owner's death leaves behind — that failure
is **session-scoped**, as this pair sets out below — and not across a restart
of the daemon. Clients treat the epoch as opaque and compare it
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
but whose relay ticket is unresolved; the relay accounts for that admission
first, or the daemon's own holder-and-epoch check refuses it before it ever
reaches core.

A revision of 2026-09-20 proposed collapsing these into one process for the
daemon holding a record per session. The maintainer rejected that on
2026-09-20 and kept the process per session: the process *is* the lease
serialization boundary and failure-isolation unit, while the fixed relay owns
the cross-owner ticket ledger. Collapsing the lease owners would put every
session's lease transitions behind one mailbox. The plan's companion states
the population and its bound.

**A lease owner's failure ends that session's collaboration state, not the
daemon**, on the maintainer's decision of 2026-09-20. The owner loses its
transient lease record, but it does not take admitted work with it: the fixed
relay retains the session's ticket set and a successor queries that set before
grant. What happens is:

- the daemon writes `control_owner_lost` to that session's **controller**
  connection and closes it with its attachment, under the daemon-initiated
  detach rule ADR 0032's generation-2 inventory fixes for exactly this, and
  leaves every observer attached, because an observer
  holds no lease, is on a connection of its own and loses nothing;
- the lease itself is gone, held by nobody;
- the next `session.acquire_control` for that session starts a **fresh**
  owner holding no lease, waits until the relay reports no unresolved mutation
  ticket for the session, and then mints a **fresh epoch**.

The fresh epoch alone is **not** what orders the old and new tenures, and an
earlier revision of this section said it was. It stops a *later* command from
the old tenure, which is different from accounting for a call already on its
way. The relay's retained ticket is what keeps a successor's first call from
overtaking that older call; core orders what it receives and never sees the
writer epoch.

**The daemon closes that window with one fixed process, the admission relay**,
added on the maintainer's decision of 2026-09-20. Every post-initialize method
request takes an admission permit from it, which gives orderly stop one linearization point.
Ten calls also take retained tickets: the eight lease-authorized core mutations
that carry `writer_epoch`, `session.create`, and `session.attach`. Reads and the
three artifact-transfer methods take unticketed permits: they grant no lease,
touch neither Control nor the journal, and cannot disturb the session census,
but sharing the permit gate prevents them from slipping past a connection-side
check while the relay cuts admission.

For a lease-authorized call, the per-session lease owner validates the combined
gate and sends the complete core-call descriptor to the relay. For create, the
connection sends the descriptor and its request-bound activation reservation.
For attach, the connection sends its stable holder pid and reserved attachment
slot; the relay task invokes `Runtime.attach_for_holder/4`, so the task that
executes the call never becomes the lifetime holder. In every ticketed case the
relay performs this sequence before its caller receives an admission reply:

1. allocate and retain the ticket row, including session where one exists,
   request identity and canonical request digest;
2. start and monitor the task that will make the core call;
3. only then answer `admitted` with the ticket identity.

The task can begin or even finish before the acknowledgement is delivered;
what cannot happen is an acknowledged mutation with no retained ticket or no
started, monitored executor. That is the maintainer's selected order. A
connection or lease owner that dies after acknowledgement does not cancel the
core call. The relay keeps the ticket until the task returns the real core
result, refusal included, and routes the result to the connection only if it
still exists.

A task that dies without a result settles nothing. The relay cannot infer
whether core received the call, so it exits `relay_lost` and makes the daemon
fail-stop rather than delete the ticket or grant a successor over it. The relay
monitors every lease owner; signal ordering puts a ticket request an owner sent
before the corresponding owner `DOWN`. A replacement owner's first grant for
a session waits until that session's mutation tickets settle. Create names no
existing session and attach grants no control, so neither blocks an unrelated
lease grant; both remain visible to the drain.

The relay's `cut` changes it to closed and acknowledges immediately. Requests
linearized before the cut retain their permits and may enter or remain in core;
requests processed after it refuse. Ticket settlement is a separate bounded
drain step. This is an admission cut, not a claim that every admitted call has
finished or that no pre-cut task can enter core after the acknowledgement.

So the ordering claim rests on the relay, and the session-scoped rule gives
the rest: the successor is granted a fresh epoch, the dead controller's
connection is closed with `control_owner_lost`, and no command from the old
tenure can be admitted afterwards. The cost is still stated honestly: the
daemon does not tell a new controller what an earlier mutation did, only that
nothing of it is still unaccounted for.

An earlier draft had the daemon restart the owner and carry on with its
sockets intact, and a 2026-09-20 revision made the failure fatal to the whole
daemon instance. Both are superseded: the restart was wrong because a
restarted owner would claim the lease record it cannot know, and daemon-fatal
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

Retaining the **lease** in a survivor was rejected: it would make a replacement
process claim collaboration state it cannot reconstruct. The relay retains
only tickets for calls it itself started, holds no lease or authority, and is
not restarted. Its own failure is daemon-fatal, which is the fail-closed edge
that lets its volatile accounting be sufficient without turning it into a
durable lease record.

**One lease per connection.** A connection holds at most one controller lease
at a time, so a client that wants to drive two sessions opens two connections.
That is the same shape ADR 0032 already gives attachments — one per
connection — and it is what makes the session-scoped close exact: when a lease
owner dies, "close the controller's connection" names one session's controller
and cannot take a second session's control down with it. Without the rule the
close would be ambiguous, and a second acquisition on a connection that
already holds a lease refuses `control_held` for its own session rather than
being quietly admitted.

A holder's connection is **exempt from ADR 0032's idle eviction while the
lease is held**, for the reason that decision states: evicting it would close
the connection the lease is bound to, and only an explicit
`session.release_control` frees a lease early, so the session would be
uncontrollable until the term ran out. A holder that stops renewing loses the
lease on its own clock and becomes an ordinary observer, evictable like any
other.

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
  no lease is held, or when the held lease is released or expired; **renews**
  it when the caller is the recorded holder of a held, unexpired lease — see
  the renewal branch below; and refuses
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
- `session.release_control` (`session_id`, `request_id`, **`writer_epoch`**):
  releases the caller's own lease. It carries `writer_epoch` like every other
  lease-authorized call, and ADR 0032's DTO table is the contract for it; an
  earlier revision of this line omitted the field the table already required,
  which would have left two documents describing one request. A caller that is
  not the recorded holder, or whose epoch does not match, refuses
  `control_not_held` and changes nothing.
- **Renewal is a branch of `session.acquire_control`, and it has to be stated
  because the refusal rule would otherwise swallow it.** Acquire from the
  connection that **is** the recorded holder of a lease that is `held` and
  unexpired is a **renewal**: the deadline moves to the full term from the
  admission instant, the **epoch does not change**, and the result carries
  that same `writer_epoch` with the new `expires_in_ms`. Acquire from any
  other connection while such a lease exists refuses `control_held`. The two
  branches are told apart by the connection identity alone — acquire carries
  no epoch on the wire, and needs none, because the holder is recorded against
  the connection. An earlier revision said both "refuses with `control_held`
  otherwise" and "renewal is explicit through `session.acquire_control` from
  the holder" without saying which clause a holder's own acquire took.
  Renewal is also implicit on any admitted mutation, which extends the
  deadline the same way and likewise never changes the epoch.
- Every existing-session mutation in generation 2, including
  `session.resume`, `session.prompt`, `session.steer`,
  `session.follow_up`, `session.abort`, `session.respond_interaction`,
  `session.admit_resources` and `session.activate_skill`, carries
  `writer_epoch` — a **required** binary identity of at most 64 bytes, exactly
  as ADR 0032's request table fixes it, together with
  `session.release_control`, which is lease-authorized in the same way though
  it starts no core call. A request of those nine that omits it is malformed
  and answered with ADR 0023's `invalid_request`
  (`0023-…-technical.md:304-307`), never with `control_not_held`: the gate is
  not reached, because there is nothing well-formed to put through it. The daemon admits it only if the sending connection is the
  recorded holder, the epoch matches, the lease state is `held`, the deadline
  is later than the live daemon's monotonic admission time, and the
  connection holds a live attachment for its pinned session, except that a verified
  dormant session's `session.resume` may precede attach under that
  connection's held lease. The check and core handoff are serialized against
  lease transitions for the session.

  **Every way that gate can fail answers one code, `control_not_held`, and it
  says nothing about which condition failed.** The gate has five conditions —
  holder connection, epoch equality, `held` state, unexpired deadline,
  live attachment for the pinned session — and an earlier revision required each of
  them without naming the result any of them produces, which left the one
  refusal a client actually meets undefined and ADR 0032's error table
  incomplete. It is deliberately **non-oracular**: a stale epoch, a copied
  current epoch, a non-holder connection, a released lease, an expired lease
  and an observer's mutation are **indistinguishable on the wire**, because
  telling a caller *which* condition it failed tells it something about the
  lease it does not hold — whether one exists, whether its epoch was right,
  whether it was merely late — and an epoch oracle is exactly what a refusal
  must not be. It refuses before core admission and before any session write,
  carries the request's `request_id` and nothing else, and changes nothing
  about the current holder's lease, epoch or deadline. Queries and attach
  carry no epoch and pass no **lease** gate; they still take the relay permit,
  and attach takes a relay ticket under the rule above.

  **Five conditions, six cases**, and the mapping is written out so the two
  numbers stop reading as a disagreement:

  | Case | Condition it fails |
  | --- | --- |
  | A stale epoch from the previous tenure | epoch equality |
  | An observer replaying the **current** epoch it saw | holder connection — the epoch matches, the connection is not the holder |
  | A mutation from a connection that never acquired | holder connection |
  | A mutation after `session.release_control` | `held` state |
  | A mutation after the term elapsed | unexpired deadline |
  | A mutation from the holder connection after its attachment ended, or before it attached | live attachment |

  The witnesses assert each case separately in the daemon's own state — which
  condition it constructed — and assert that all six produce the
  **same** code and the same fields on the wire, which is what stops a later
  revision from helpfully differentiating them.
- `session.create` has no `writer_epoch` because the session lease does not
  exist. It creates an uncontrolled session, and creation never implicitly
  grants control. The caller must acquire control explicitly and use the
  returned epoch for its first session command. Acquire and attach may be
  sent in either order, because acquire is keyed by session ID and validates
  only durable session existence, through the read-only query; the
  constraint is on the first mutation,
  not on the two calls that precede it, and that mutation refuses unless the
  sending connection is the holder, the epoch matches and the connection
  holds a live attachment for its pinned session.
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
left to the implementation. The lease owner serializes the gate and relay
ticket handoff against lease transitions; the relay then retains the admitted
call until its real result. Takeover is admitted at expiry with no grace. The
linearization rule is:

1. A mutation whose holder, epoch, state, deadline and attachment check
   completed while the deadline was still in the future, and whose relay
   ticket was admitted, is **in flight** and settles under that lease even if
   the deadline passes while core is unresolved. It completes or fails on its
   own terms; it is neither retried nor fenced by the expiry.
2. At the deadline the lease state becomes `expired` and the holder gains
   nothing further: every mutation whose check begins at or after the deadline
   refuses, including one from the holder, and renewal no longer extends it.
3. A takeover becomes **eligible** at the deadline and is **granted** only
   once the relay reports every mutation ticket for that session settled. Until then the
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
expired state and a holder lacking a live attachment each refused before core admission with the current
controller unaffected; a lease transition racing command admission preserves
this order; every ticketed call has both its retained row and monitored task
before the sender receives `admitted`; attach's task uses the connection as
stable holder; killing that task before a result makes the relay and daemon
fail-stop; a cut answers immediately, carries pre-cut calls to their real
results, and refuses every post-cut permit; the expiry linearization above, with a mutation blocked inside
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
lease owner killed while a mutation is in flight taking neither the daemon nor
any other session down: that session's controller connection is sent
`control_owner_lost` and closed with its attachment, its observers stay
attached on their own connections, the relay retains the
outstanding ticket, the replacement owner's first grant waits until it
settles, and the previous holder's delayed command is refused on both the
holder and the epoch check;
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
