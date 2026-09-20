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
not across a restart of the per-session lease owner process, and not across
a restart of the daemon. Clients treat the epoch as opaque and compare it
only for equality. The daemon incarnation is a fresh opaque identifier
generated at each daemon start and reported by `daemon.status` as a
diagnostic; it confers nothing and is not part of the epoch. It is a daemon
fact: core session epochs, owner incarnations and receipts are unchanged and
remain the commit-authority fence.

One owner process per session serializes every lease read, grant, renewal,
release and expiry transition with that session's mutation-admission handoff,
so a takeover cannot pass a mutation whose holder check has already started
but whose core admission is unresolved; that admission first resolves or
remains fenced. If that owner process crashes and is restarted by the daemon
while the daemon and its client sockets survive, the restarted owner holds no
lease: the session is uncontrolled, the previous holder's epoch can never be
minted again, and its delayed commands refuse on both the holder and the
epoch check until it acquires again and receives a new epoch. Expiry and
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
  first; the held lease lets that connection call `session.resume` and then
  attach. Daemon startup recovery of sessions is a root-owner operation under
  the store's writer marker, never a client mutation and never a grant of
  controller authority.
- `session.release_control` (`session_id`, `request_id`): releases the
  caller's own lease; a non-holder refuses.
- Renewal is implicit on any admitted command and explicit through
  `session.acquire_control` from the holder, which extends the deadline
  without changing the epoch.
- Every existing-session mutation in generation 2, including
  `session.resume`, `session.stop`, `session.prompt`, `session.steer`,
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
  exist. It creates an uncontrolled session. The caller must attach, acquire
  control explicitly, and use the returned epoch for its first session
  command. Creation never implicitly grants control.
- An orderly connection close by the holder releases the lease; an abrupt
  loss leaves it to expire.

Proposed terms bound at acceptance: lease length 30 seconds, renewal interval
10 seconds for the reference clients, takeover admitted when the live daemon's
monotonic deadline is reached, no grace period beyond the lease itself.

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
this order; takeover only after release or expiry with a fresh epoch minted
before the successor's first command; a controller killed mid-run fenced
after takeover, its late commands refused; the per-session lease owner
process crashing and restarting while the daemon and client sockets survive,
after which the previous holder's delayed command is refused, no epoch is
ever reused, and a new acquire carries a new epoch; an abort from the new
controller cancelling work dispatched under the old controller's command
with a truthful cleanup outcome; an observer never acquiring authority
through content, metadata, answers or order; after a daemon restart every
session uncontrolled, an epoch from before the restart refused, and the
first acquire granting a fresh epoch; forward and backward wall-clock jumps
not changing live admission or takeover timing; creation yielding an
uncontrolled session and requiring attach plus explicit acquire before
prompt; a dormant session acquired by ID, then resumed with epoch and
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
