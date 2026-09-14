<a id="technical-depth"></a>
## Technical depth

Concept: [Collaboration: controller lease and takeover](0033-collaboration-controller-lease-and-takeover.md#concept).

<a id="technical-adr-0033-decision"></a>
### Contract and Evidence

Concept: [Context and decision](0033-collaboration-controller-lease-and-takeover.md#concept-adr-0033-decision).

### Lease record

The daemon keeps one lease record per session in the separate private
daemon-control storage surface defined by ADR 0031, never in the session
journal. Its first implementation lives in `loopex_store_daemon` while the
local adapter still supplies session truth; the daemon-grade session adapter
later shares the same state root without changing the lease contract:

```text
session_id, writer_epoch, holder (connection identity), granted_at_utc,
renewed_at_utc, expires_at_utc, state ∈ {held, released, expired}
```

`writer_epoch` starts at 1 when a session is first controlled under a daemon
and increases by one at every new grant after release or expiry. The record is
committed before the grant is acknowledged and before any command under the new
epoch is admitted, so a crash between grant and acknowledgement leaves either
the old epoch or the new one durable, never both. It is a daemon fact: core session epochs,
owner incarnations and receipts are unchanged and remain the commit-authority
fence.

Lease read, grant, renewal, release and expiry transitions use an atomic
compare-and-transition with request-ID resolution in that daemon-control
surface. Each transition compares the prior holder, epoch, state and expiry
with the same observed record; an ambiguous acknowledgement is resolved by
request ID before another transition is allowed. Persisted timestamps are UTC
instants. During one daemon lifetime, a monotonic deadline set only after a
successful grant or renewal governs expiry and command admission; a wall-clock
jump cannot shorten or extend a live holder's authority. The persisted UTC
expiry is a durable record and client-facing estimate, not a VM-local
monotonic timestamp or an independent authorization test. At restart, the
daemon first proves the previous root writer gone and takes the root marker,
then durably changes every previously held lease to `expired` before accepting
socket clients. It preserves each epoch so the next grant advances it. It does
not infer an old connection's liveness from the UTC timestamp or reconstruct
the old monotonic deadline. If writer death or that expiry transition cannot
be established, startup refuses rather than granting control.
The daemon serializes a session's lease transition with its mutation-admission
handoff. A takeover cannot pass a mutation whose previous holder check has
already started but whose core admission is unresolved; that admission first
resolves or remains fenced.

### Methods and fields

- `session.acquire_control` (`session_id`, `request_id`): grants control when
  no lease is held, or when the held lease is released or expired; refuses
  with `control_held` naming the current epoch otherwise. The result carries
  the new `writer_epoch` and UTC `expires_at`. For a known dormant session, a
  generation-2 connection may acquire by session ID before attach. The daemon
  validates durable session existence first; the held lease lets that
  connection call `session.resume` and then attach. Daemon-internal startup
  recovery is a separate root-owner operation, never a client mutation and
  never a grant of controller authority.
- `session.release_control` (`session_id`, `request_id`): releases the
  caller's own lease; a non-holder refuses.
- Renewal is implicit on any admitted command and explicit through
  `session.acquire_control` from the holder, which extends `expires_at`
  without changing the epoch.
- Every existing-session mutation in generation 2, including
  `session.resume`, `session.stop`, `session.prompt`, `session.steer`,
  `session.follow_up`, `session.abort`, `session.respond_interaction`,
  `session.admit_resources` and `session.activate_skill`, carries
  `writer_epoch`. The daemon admits it only if the sending connection is the
  recorded holder, the epoch matches, the lease state is `held`, the expiry is
  later than the live daemon's monotonic admission time, and the connection
  holds a controller-capable attachment, except that a verified dormant
  session's `session.resume` may precede attach under that connection's held
  lease.
  The check and core handoff are serialized against lease transitions for the
  session. A mismatch or failed condition refuses
  before core admission and before a session write; an observer who copied
  the visible current epoch still refuses. Queries and attach carry no epoch.
- Generation-2 `session.create` has no `writer_epoch` because the session
  lease does not exist. It creates an uncontrolled session. The caller must
  attach, acquire control explicitly, and use the returned epoch for its
  first session command. Creation never implicitly grants control.
- Generation-1 `session.resume` first takes an internal lease for that
  connection through the same durable transition, after checking that no
  attachment of either generation and no unexpired held lease exists. It then
  forwards resume and returns its ordinary admission without attaching. A
  later `session.attach` from that connection reuses the held internal lease.
  A known refusal releases the lease; an unknown admission must resolve before
  release or takeover.
  Generation-1 create remains uncontrolled until its exclusive attach grants
  an internal lease. Neither wire method gains an epoch field.
- An orderly connection close by the holder releases the lease; an abrupt
  loss leaves it to expire.
- At expiry of a generation-1 internal lease, a still-connected generation-1
  attachment is detached and fenced in the same serialized transition before
  a successor of either generation acquires or attaches. An expired
  generation-1 connection cannot renew through a late command.

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
a stale epoch, copied current epoch, non-holder connection, released state and expired
state each refused before core admission with the current controller
unaffected; a lease transition racing command admission preserves this order;
takeover only after release or expiry with a durable epoch advance; a
controller killed mid-run fenced after takeover, its late commands refused;
an abort from the new controller cancelling work dispatched under the old
controller's command with a truthful cleanup outcome; an observer never
acquiring authority through content, metadata, answers or order; the lease
record surviving a daemon restart with its epoch intact, prior holders
durably expired after writer-death proof, and startup refusing when that proof
or transition is uncertain; forward and backward wall-clock jumps not changing
live admission or takeover timing; creation yielding an uncontrolled session
and requiring attach plus explicit acquire before prompt; a dormant
generation-2 session acquired by ID, then resumed with epoch and attached;
generation-1 resume gaining an internal exclusive lease before admission and
generation-1 attachment exclusivity across connections of either generation,
with command authority scoped to its internal lease; an idle but connected
generation-1 attachment detached and fenced at expiry before a generation-2
takeover and attach.

### Alternatives

Placing the lease in core was rejected because the vision keeps collaboration
policy above core and another host may choose a different rule. Last-writer-
wins without an epoch was rejected because a killed controller's late command
would interleave with the successor's. A lease with no expiry was rejected
because a crashed controller would hold the session forever.

<a id="technical-adr-0033-compatibility"></a>
### Compatibility and Rollback Mechanics

Concept: [Consequences and rollback](0033-collaboration-controller-lease-and-takeover.md#concept-adr-0033-consequences).

The lease methods and the `writer_epoch` field exist only in generation 2 of
the experimental protocol. A successful generation-1 daemon attach grants an
internal lease to its exclusive connection; the daemon checks that holder,
held state and expiry for each mutation, without changing its wire frames.
Generation-1 resume can acquire the lease before attach; a held generation-1
lease excludes attachments of either generation even after abrupt connection
loss until it is durably expired. The M4 foreground server still
has its own single connection and no daemon lease.
Core session records, events and snapshots are unchanged. Removing the daemon
removes the lease namespace with it; no session journal depends on it.

Acceptance binds this complete pair at an exact candidate. Its evidence and
compatibility claims remain unproved until the M5 gate's required paths execute.
