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

**A lease owner's failure is fatal to that daemon instance, deliberately.**
The owner holds the session's in-flight admission set in its own memory, and
that set is the whole basis of the expiry rule below: a takeover is granted
only when it is empty. An owner that dies takes the set with it, so a
restarted owner cannot know whether an admission is still on its way into
core. An earlier draft had the daemon restart the owner and carry on with its
sockets intact; that was withdrawn on 2026-09-20, on an independent review's
finding, because a successor acquire
could then be granted while a forgotten admission was still able to settle.

So a lease owner's failure is fatal to the daemon instance, and the daemon's
own structure supplies that without special-case code: the lease owner is one
of four processes the daemon's owner process `start_link`s, the owner traps
exits, and its `{:EXIT, pid, reason}` clause treats **any** linked exit as
fatal. There are no restarts to configure and no strategy to get wrong. The
owner classifies the exit as `fatal:supervision_fault`, has the listener tell
every client, closes them, unlinks the socket and exits non-zero; the daemon
comes back with no lease anywhere, no connection and no session activated. No
successor acquire exists to be granted wrongly, because no connection
survives to make one.

That rule stands on its own, and this pair does not lean on core to help it.
An earlier draft said core would fence the forgotten admission by epoch
regardless, making the daemon-fatal rule defence in depth. The maintainer
withdrew that on 2026-09-20 because it was not true: core never sees the
writer epoch, as the lease record above sets out, and the fences core does
have protect against a stale *coordinator owner* rather than a stale
*controller* — which is the gap this ADR exists to fill. So the daemon rule
is the only thing preventing a successor's grant from racing a forgotten
admission, and it has to be absolute for that reason.

Retaining the in-flight set in a survivor was the alternative and was
rejected: whichever process held it would then be the process whose failure
loses it, so the window moves up one level rather than closing, and a daemon
that cannot lose the set is a daemon that has made the set durable — a durable
lease record by another name, which this decision rejects for its own reasons.
The cost is real and is stated: one supervision fault takes the daemon down
and every client reconnects. That is the honest price of not inventing a
recovery for state whose whole purpose is to be exact.

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
  with `control_held` naming the current epoch otherwise. The result carries
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
left to the implementation. The per-session owner serializes a lease
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
   exceeds it refuses with a stable reason naming the in-flight admission, and
   the client may acquire again.
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
mutation refused at the deadline, the acquiring request refusing with its
stable reason when its own deadline elapses first, the holder's connection
disconnecting while its mutation is in flight, and the per-session lease owner
failing while a mutation is in flight — in every case exactly one of settle or
refuse, never both, and no epoch reused; takeover only after release or expiry
with a fresh epoch minted before the successor's first command; the three ways
a controller stops holding proved separately, because only one of them is
early and the transport cannot tell the other two apart — an explicit
`session.release_control` frees the lease at once, while an EOF from a politely
closed client and a killed client both wait for expiry, with a takeover
refused before the deadline and granted after it in both cases; a controller
killed mid-run fenced after takeover, its late commands refused; a
per-session lease owner killed while a mutation is in flight taking the
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
