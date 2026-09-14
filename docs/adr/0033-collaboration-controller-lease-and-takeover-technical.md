<a id="technical-depth"></a>
## Technical depth

Concept: [Collaboration: controller lease and takeover](0033-collaboration-controller-lease-and-takeover.md#concept).

<a id="technical-adr-0033-decision"></a>
### Contract and Evidence

Concept: [Context and decision](0033-collaboration-controller-lease-and-takeover.md#concept-adr-0033-decision).

### Lease record

The daemon keeps one lease record per session in its runtime-control
namespace of the daemon-grade store, never in the session journal:

```text
session_id, writer_epoch, holder (connection identity), granted_at,
renewed_at, expires_at, state ∈ {held, released, expired}
```

`writer_epoch` starts at 1 when a session is first controlled under a daemon
and increases by one at every takeover. The record is committed before the
grant is acknowledged and before any command under the new epoch is admitted,
so a crash between grant and acknowledgement leaves either the old epoch or
the new one durable, never both. It is a daemon fact: core session epochs,
owner incarnations and receipts are unchanged and remain the commit-authority
fence.

### Methods and fields

- `session.acquire_control` (`session_id`, `request_id`): grants control when
  no lease is held, or when the held lease is released or expired; refuses
  with `control_held` naming the current epoch otherwise. The result carries
  the new `writer_epoch` and `expires_at`.
- `session.release_control` (`session_id`, `request_id`): releases the
  caller's own lease; a non-holder refuses.
- Renewal is implicit on any admitted command and explicit through
  `session.acquire_control` from the holder, which extends `expires_at`
  without changing the epoch.
- Every mutating session method in generation 2 carries `writer_epoch`. The
  daemon compares it to the current lease before forwarding the command to
  core; a mismatch refuses with `stale_writer_epoch` and no durable write
  happens. Queries and attach carry no epoch.
- An orderly connection close by the holder releases the lease; an abrupt
  loss leaves it to expire.

Proposed terms bound at acceptance: lease length 30 seconds, renewal interval
10 seconds for the reference clients, takeover admitted as soon as
`expires_at` is in the past by the daemon's clock, no grace period beyond the
lease itself.

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

### Evidence

Tests prove: exactly one controller with any number of observers; a stale
epoch refused before core admission with the current controller unaffected;
takeover only after release or expiry with a durable epoch advance; a
controller killed mid-run fenced after takeover, its late commands refused;
an abort from the new controller cancelling work dispatched under the old
controller's command with a truthful cleanup outcome; an observer never
acquiring authority through content, metadata, answers or order; the lease
record surviving a daemon restart with its epoch intact.

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
the experimental protocol; generation 1 connections are their own controller
by construction, as under the M4 foreground server, and see none of this.
Core session records, events and snapshots are unchanged. Removing the daemon
removes the lease namespace with it; no session journal depends on it.

Acceptance binds this complete pair at an exact candidate. Its evidence and
compatibility claims remain unproved until the M5 gate's required paths execute.
