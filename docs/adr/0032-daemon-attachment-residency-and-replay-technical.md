<a id="technical-depth"></a>
## Technical depth

Concept: [Daemon attachment residency and replay](0032-daemon-attachment-residency-and-replay.md#concept).

<a id="technical-adr-0032-decision"></a>
### Contract and Evidence

Concept: [Context and decision](0032-daemon-attachment-residency-and-replay.md#concept-adr-0032-decision).

### Transport

The daemon listens on one Unix-domain socket, and where it puts it matters.
Its path is `<state root>/daemon/daemon.sock` by default, inside a
daemon-owned subdirectory the daemon creates mode `0700`, and it may be set
explicitly to another path under the same rule.

It is a subdirectory rather than the state root itself because the root is not
the daemon's to re-permission. `LoopexAppServer.Host` creates it with
`File.mkdir_p/1` and no mode, so under the ordinary umask of 022 an existing
M4 root is `0755` — measured, not assumed. Requiring the *root* to be `0700`
would have made the daemon refuse every root the foreground server and the CLI
have been writing since M4, which contradicts this milestone's central
compatibility claim that moving a root between the daemon and the foreground
surfaces is stopping one and starting the other. Tightening the root instead
would be an unannounced permission change to an operator's existing directory.
The daemon therefore owns one subdirectory and leaves the root's mode exactly
as it found it.

**The path bound is derived, not assumed.** `sun_path` is 104 bytes on Darwin
and 108 on Linux *including* the NUL terminator, so the usable path is one
byte shorter than the structure: at most 103 bytes on Darwin and 107 on Linux.
That is measured, not inferred — on the supported OTP 29 Darwin toolchain a
bind at 103 bytes succeeds and at 104 bytes is refused with
`{:invalid, {:sockaddr, …}}`. Each supported platform derives its own bound
the same way rather than carrying a constant, and a path beyond it is refused
at start with `socket_path_too_long` naming the derived bound, never
truncated. The tests bind at the bound and at one byte past it on every
platform the release check runs.

**Peer authorization has two layers, and the load-bearing one is the
filesystem.** The socket lives in that `0700` daemon-owned subdirectory and is
itself created mode `0600`. Both are verified after bind by reading back their
owner and mode and comparing them with the daemon's own effective user, and
the daemon refuses to serve if either is wrong, if the subdirectory is not
owned by that user, or if any component of the path below the state root is a
symbolic link it did not create. The state root above it is read, never
re-permissioned and never required to be `0700`. That is what actually keeps another user out:
connecting to a Unix-domain socket requires write permission on the socket and
traversal of its directory, so a foreign peer never reaches `accept`. It is
the same arrangement ADR 0019 already uses for the provider child's private
channel, proved there, and reused rather than reinvented.

**Peer-credential inspection is the second layer, and its mechanism is named
per platform** because the portable one does not exist. On the supported
OTP 29 Darwin toolchain `:socket.supports(:options, :socket)` reports
`peercred: false` and `passcred: false`, and `:socket.getopt(sock, :socket,
:peercred)` answers `{:error, {:invalid, {:socket_option, …}}}`; the named
option is simply not available there. What is available is the raw option:
`:socket.getopt_native(sock, {0, 1}, 128)` — Darwin's `SOL_LOCAL`,
`LOCAL_PEERCRED` — returns a `struct xucred` from which the peer's effective
uid is decoded, and it was confirmed to return the connecting process's uid on
that toolchain. On Linux the mechanism is `SO_PEERCRED` at `SOL_SOCKET`,
yielding `struct ucred`. Both are socket options, and the classic `inet`
backend exposes neither, so the listener uses OTP's own `:socket` API (or
`gen_tcp` over the socket backend, whose handle it can reach) rather than the
classic backend. A peer whose decoded uid differs from the daemon's is closed
before any frame is read.

**Fail closed.** Where a platform has a named mechanism, a credential read
that errors, returns a short or unrecognised structure, or reports a uid the
daemon cannot decode closes the connection before initialize; it is never
treated as permission. Where a platform has no mechanism at all, the daemon
says so in its diagnostics and the boundary is the verified filesystem layer
alone — which the daemon proves it has, because it refuses to serve when
ownership and mode cannot be verified.

The evidence follows the same split. The fast check proves the filesystem
layer and the fail-closed paths without needing a second user: a permissive
directory or socket mode, a parent the daemon does not own, and a path
component the daemon did not create are each refused at start; an unreadable
or undecodable peer credential closes the connection. The real cross-uid
refusal is a release-check case on the Linux lane, where a second unprivileged
user exists: a connection from another uid is refused before initialize and a
connection from the daemon's own uid succeeds, both recorded with the run.

Startup order is fixed. The daemon first opens the state root through the
local adapter and acquires its writer marker; a daemon that does not hold the
marker refuses with the adapter's `store_writer_active` or
`store_writer_unverifiable` reason and never reads, unlinks or binds the
socket path. The daemon opens the root with `recover_stale_writer: true`,
explicitly, because that option defaults to `false` in both
`Loopex.Store.Local` and `LoopexComposition` and a daemon that did not ask for
it could never restart after being killed. Asking for it is not asking to
ignore a holder: the adapter reclaims the marker only where it probes the
recorded holder and finds it dead, leaves it in place with
`store_writer_unverifiable` where the holder cannot be decided, and refuses
with `store_writer_active` where the holder is alive. All three are proved
before the socket path is read, unlinked or bound. Only the marker holder may remove a stale `daemon.sock` left by
a dead daemon and bind a new one, so two simultaneous starts on one root
resolve at the marker, exactly one listener exists, and the loser exits
without touching the socket.

**Removing the pathname is the successor's job, not the predecessor's**, and
that follows from the same rule read in the other direction. A daemon's claim
on the path is its marker, so the claim ends when the marker does — which can
happen without the daemon being asked, since the Store releases the marker in
its own `terminate/2`. **No daemon unlinks on its way out at all** — not on an orderly stop, not on
any fail-stop, not in reverse cleanup — because a daemon that checked its
ownership and then unlinked would be acting across a window in which the Store
can die, the marker can be released and a successor can bind, and the
predecessor would then delete the successor's socket. The next daemon to
acquire and verify the marker removes the stale pathname before binding, which
is the one moment at which removing a socket file is unambiguously correct. If the daemon's **Store process exits**, it closes the listener and every
connection before anything else and then exits; no connection outlives the
daemon's ownership of the root. An earlier revision wrote that as "its Store
child exits **or the marker can no longer be proved held**", which named a
check that does not exist: nothing polls the marker, and the read-only
ownership call a revision once invented for it was withdrawn with the unlink
it existed for. **The marker's lifetime is the Store process's lifetime** —
`Loopex.Store.Local` takes it at start and releases it in its own
`terminate/2` — so the Store's exit *is* the event, and there is no second
condition to observe.

Framing, the initialize handshake, admission records, snapshot,
event and progress records, the frame ceiling, the strict UTF-8/LF rule and
the unknown-field rule are reused from ADR 0023 unchanged. **Request records
have one generation-2 addition**: every existing-session mutation carries
`writer_epoch`. Attach keeps ADR 0023's optional boolean `replace`; because
each protocol connection holds at most one attachment, the adapter can map
that boolean to core's exact replacement selector without ambiguity.

**The addition, at the exactness a vector needs**, because "carries
`writer_epoch`" is not a type, an optionality or a list:

| Generation-2 request | `writer_epoch` |
| --- | --- |
| `session.resume` | **binary identity, ≤ 64 bytes, required** |
| `session.prompt` | the same |
| `session.steer` | the same |
| `session.follow_up` | the same |
| `session.abort` | the same |
| `session.respond_interaction` | the same |
| `session.admit_resources` | the same |
| `session.activate_skill` | the same |
| `session.release_control` | the same — it is lease-authorized like the eight, though it starts no core call and takes no relay ticket |
| `session.create`, `session.attach`, `session.list`, `daemon.status`, `session.acquire_control`, and every ADR 0023 query | **absent, and refused if present** — an unknown field refuses before a facade call under ADR 0023's own rule (`0023-…-technical.md:131-136`) |

It is **required**, not optional: an absent `writer_epoch` on one of the nine
is a malformed request, answered with ADR 0023's `invalid_request`, and never
`control_not_held` — the gate has not been reached, because there is nothing
well-formed to put through it. Every other field of those requests is ADR
0023's, unchanged. A connection is
one attachment after `session.attach`; generation 2 permits a connection to
hold at most one attachment at a time — **and at most one controller lease**,
which ADR 0033 fixes for the same reason and which is what makes closing "the
controller's connection" name exactly one session — and a client process to
hold as many connections as the residency limits admit. Its attach request
keeps optional `replace`: on either protocol generation `true` maps to that
connection's sole live attachment, while a second attach with `false` refuses
ADR 0023's existing `attachment_conflict`. Embedded callers are not subject to
the connection rule and use core's explicit `replace_attachment_id` option.

**An attachment never outlives its holder, and M5 makes the holder explicit.**
Today `Runtime.attach/3` uses the process that calls it as the transient scan
caller, the dispatcher drops that monitor after installation, and `Control`
keeps only one attachment per session. Those three facts cannot implement
multiple attachments, and a daemon relay task cannot stand in for the
connection whose lifetime the attachment must follow.

Core change 1 therefore has two entry paths with one implementation:

- `Runtime.attach/3` remains the embedded entry and uses `self()` as the
  holder;
- the daemon-only `Runtime.attach_for_holder/4` accepts the already-authorized
  connection pid as the stable holder. The admission relay starts the
  monitored attach task and passes that pid before acknowledging the ticket,
  so the task may end without changing whose lifetime owns the result.

Both EventDispatcher and Control install their **own** monitor of the stable
holder. A monitor is observed only by the process that creates it, so sharing
one reference or expecting Control to receive EventDispatcher's `DOWN` would
be an unrunnable design. Each component keeps a holder entry containing a set
of attachment IDs. EventDispatcher owns the cursor barriers, queues and open
transfers; Control owns command routing and repetition state. A holder may own
several attachments to the same session, and each ID resolves exactly one
entry in both components. On `DOWN`, EventDispatcher removes every attachment
in that holder set and calls `release_transfers/2` for each; Control removes
the same IDs and their repetition state. Each component demonitors only after
its set for that holder is empty.

The monitors are installed before the snapshot scan starts. A holder `DOWN`
marks every pending attach for that holder cancelled in each serial owner; an
install step rechecks that mark and refuses rather than publishing an
attachment for a process already known dead. This covers death before, during
and immediately after the relay task's core call.

**Replacement names one attachment.** Core attach options gain optional
`replace_attachment_id`; when present, the target must be a live attachment
owned by the same holder and session. Installation and removal are one serial
EventDispatcher transition: the named target is removed at its last emitted
cursor, its transfers are released, and the new attachment takes its place.
An absent, stale, foreign-holder or other-session target refuses
`:stale_attachment` in core, mapped to generation 2's inherited
`attachment_conflict`, and changes nothing. With no selector, a distinct request
installs another attachment even when that holder already owns one for the
session. Exact repetition of the same attach identity returns the same live
handle rather than installing a duplicate.

ADR 0023's boolean remains the wire field on both protocol adapters. Each
adapter permits only one connection attachment, so on `replace: true` it maps
the sole handle it already holds to core's `replace_attachment_id`; on
`replace: false` it keeps ADR 0023's second-attach refusal. Embedded callers
use the core selector directly and are the case for which several candidates
can exist.

**Holder cleanup and daemon ceiling release are one acknowledged sequence.**
The daemon registry owns connection and attachment reservations. When a
connection ends it marks that holder's installed and in-flight slots
`closing`; it does not release them merely because its own monitor fired. The
admission relay first accounts for every ticket from that holder. The registry
then calls the internal, idempotent `Runtime.release_holder/2`, which returns
only after EventDispatcher and Control contain no attachment for the holder;
a cleanup already caused by their monitors is success. Only that reply frees
the daemon slots. If core cannot confirm the cleanup, the slots remain charged
and the runtime failure follows the daemon's fatal path. A late attach cannot
appear after confirmation because the relay had already settled every holder
ticket. This ordering prevents the registry from admitting a replacement
while core still holds the old attachment and makes the 64-per-session and
512-per-daemon ceilings true at every instant rather than eventually.

The same path handles an orderly daemon close and an abrupt peer loss. For an
embedded caller no daemon counter exists; the two core monitors still remove
the whole holder set. The runtime-local pids and monitor references cross no
durable, public or executor boundary.

**Transfer cleanup remains mandatory.** `release_transfers/2` is currently
called only by unconditional same-session supersession. M5 moves that call to
each named-replacement removal and to every holder-set removal. The witness
opens transfers from two same-holder attachments, replaces one by ID and then
kills the holder: replacement releases only the target's transfers; holder
loss releases the survivor's; a different holder's attachments continue.

A general public `detach/1` remains rejected. It would require every caller to
remember cleanup precisely when the caller may already be dead. The two
internal operations above have narrower purposes: `attach_for_holder/4`
separates the relay task from the lifetime owner, and `release_holder/2` lets
the daemon retain resource reservations until the automatic monitor cleanup is
confirmed. Neither gives a client authority to detach another holder.

The core EventDispatcher and Control therefore retain multiple live attachment
IDs and incarnations for one session and multiple IDs for one holder. A new
distinct attachment does not implicitly detach another or cancel its pending
read. Snapshot barriers, queued durable delivery, stale-handle checks and
holder cleanup remain core operations. The daemon neither copies the snapshot
into a second fan-out owner nor reads coordinator state to repair an
attachment race.

### Queue ownership

Two bounded stages exist per attachment, with distinct owners. The core
dispatcher owns the per-attachment event-count queue that already exists,
configured by the daemon at 1,024 events through the runtime's
`attachment_capacity`; it never holds encoded bytes. The daemon owns a
per-connection socket output buffer of encoded frames not yet written to the
socket, bounded at 4 MiB, and the per-session resident window of encoded
recent events, bounded at 4,096 events and 16 MiB, and it enforces the
512 MiB aggregate across every output buffer and resident window it holds.
Neither daemon stage owns replay: core owns the cursor and decides what is
owed, and both daemon stages hold only bytes for events core has already
named.
When the next event would exceed the core count or a daemon byte bound, the
daemon detaches the attachment at its last completely emitted cursor with a
stable reason rather than letting either stage grow — which, under the
daemon-initiated detach rule above, means one best-effort `detached` record
and then the close of that connection. No byte limit is
enforced inside core.

### Generation 2 additions

Every table below is the wire contract at the exactness a literal vector
needs: the keys a request carries, the keys a result carries, which are
optional, and what type each is in ADR 0023's vocabulary — `binary identity`,
`u64` (a canonical unsigned decimal **string**), `bool`, `plain_object`. The
envelope is ADR 0023's unchanged: a request is a flat object with exactly
`method`, `request_id` and its row's fields, an optional field is **absent**
rather than `null`, and unknown fields refuse before a facade call
(`0023-…-technical.md:131-136`).

**`session.list`**

| Direction | Key | Type | Optionality |
| --- | --- | --- | --- |
| request | `limit` | integer 1 to 256 | required |
| request | `after_session_id` | binary identity | optional |
| result | `entries` | array of entry objects, at most `limit` | required |
| entry | `session_id` | binary identity | required |
| entry | `placement_identity` | binary identity | required |
| entry | `residency` | `"active"` \| `"dormant"` | required |
| entry | `controlled` | bool | required |
| result | `next_after_session_id` | binary identity | present **exactly when** more entries exist |
| result | `index_full` | bool `true` | present **exactly when** the index is at its 4,096-entry ceiling |

Entries are ordered by session ID bytes ascending, and carry nothing else —
no content, no durable session state.

**`daemon.status`**

| Direction | Key | Type | Optionality |
| --- | --- | --- | --- |
| request | — | — | takes no fields |
| result | `placement_identity` | binary identity | required |
| result | `daemon_incarnation` | binary identity | required |
| result | `socket_path` | string | required |
| result | `connections` | integer, accepted connections currently open | required |
| result | `connection_limit` | integer, 512 | required |
| result | `attachments` | integer | required |
| result | `attachment_limit` | integer, 512 | required |
| result | `active_sessions` | integer | required |
| result | `activation_limit` | integer, 64 | required |
| result | `activations_used` | integer, activations spent in this daemon lifetime **plus reservations in flight** — see below | required |
| result | `index_entries` | integer | required |
| result | `index_limit` | integer, 4,096 | required |
| result | `index_full` | bool | required |
| result | `uptime_ms` | `u64` | required |

**What the counts mean while a reservation is in flight**, which an earlier
revision left to the implementation and which two clients calling
`daemon.status` during a burst of creates would otherwise disagree about.
The rule is that **a reservation counts**:

- `activations_used` is `|activation set| + |reservations|` — the same
  quantity the ceiling invariant bounds, so `activations_used` and
  `activation_limit` are directly comparable and a client can never read
  `activations_used < activation_limit` on a daemon that would refuse its next
  create;
- `active_sessions` is `|activation set|` alone — **the sessions this daemon
  has activated in this lifetime**, which is what the set holds and what
  `residency: active` means. It is *not* "sessions with a live coordinator":
  activation is one-way and the daemon has no way to know a coordinator died,
  which this pair says twice elsewhere. It differs from `activations_used`
  only by the reservations in flight;
- `attachments` counts installed attachments plus reserved and
  cleanup-pending attachment slots, for the same reason `activations_used`
  does; a connection `DOWN` does not lower it before core confirms holder
  cleanup;
- `connections` counts accepted connections, reservation-free by nature.

So `activations_used` may exceed `active_sessions` for as long as a call is in
flight, and settles to it. Reporting the set alone would advertise headroom
the very next call would refuse.

**At the attachment ceiling a named replacement is net-zero, and it reserves
that way.** A replacing attach ends one attachment and installs one, so it
needs no free slot — but the daemon reserves before it calls core, and a naive
reservation would refuse at 512 a request that leaves the count at 512. So a
replacing attach takes an **atomic net-zero reservation**: in the daemon's
serial owner it claims the slot held by the exact
attachment ID to which the connection's `replace: true` was mapped, and it converts or releases that claim through the
same table every other reservation uses, so the count never moves and no
second caller can take the slot in between. A stale, foreign-holder or
other-session core selector refuses and releases the claim; an ordinary
attach with no selector reserves a new slot and is refused at the ceiling.

**Create reservations bind the request, not only the command identity.** The
reservation key retains `command_id` together with the canonical digest of all
creation inputs, including `session_options`. An exact retransmission may
coalesce behind the first ticket. Reusing the command ID with different input
refuses as a command conflict and never receives the first request's success.
The binding is retained until the relay has the real core result, so a caller
disconnect cannot free the slot while its create is still executing.

**`session.acquire_control`**

| Direction | Key | Type | Optionality |
| --- | --- | --- | --- |
| request | `session_id` | binary identity | required |
| result | `writer_epoch` | binary identity, ≤ 64 bytes | required |
| result | `expires_in_ms` | `u64`, the remaining term on the daemon's clock | required |
| result | `renewed` | bool | present **exactly when** the caller was already the holder of a held, unexpired lease |

A holder's own `session.acquire_control` is a **renewal**, not a refusal: the
deadline moves, the epoch stays, `writer_epoch` is the same value it held and
`renewed` is `true`. ADR 0033 owns the branch; the field is here so a client
can tell a renewal from a fresh grant without comparing epochs it treats as
opaque.

**`session.release_control`**

| Direction | Key | Type | Optionality |
| --- | --- | --- | --- |
| request | `session_id` | binary identity | required |
| request | `writer_epoch` | binary identity | required |
| result | `released` | bool `true` | required |

**Notification records — there are two**, and the Concept says two as well:

| Family | Key | Type | Optionality |
| --- | --- | --- | --- |
| `daemon.stopping` | `reason` | one of the closed set below | required |
| | `message` | bounded non-secret string | required |
| `daemon.notice` | `code` | closed set, today `"index_write_failed"` | required |
| | `session_id` | binary identity | required |
| | `message` | bounded non-secret string | required |

Neither is correlated and neither carries a cursor.

**The new error codes, with their shape.** All of these are **correlated**
errors answering one request: each carries that request's `request_id`, no
`event_cursor`, no session state, and closes nothing.

| Code | Answers | Carries beyond the envelope |
| --- | --- | --- |
| `control_held` | `session.acquire_control` | **Nothing.** It does *not* carry the current epoch: an epoch is authority-shaped, and handing one to a client that was just refused is exactly the value it must not have. An earlier revision of ADR 0033 said it named the current epoch; that is withdrawn |
| `control_not_held` | `session.release_control` from a non-holder, **and every lease-authorized existing-session mutation whose combined admission gate fails** — any of the **five** conditions ADR 0033 lists: wrong connection, wrong epoch, a lease that is not `held`, a deadline already passed, or no live attachment for the pinned session. A request missing `writer_epoch` altogether is `invalid_request` instead, being malformed before the gate | **Nothing**, deliberately: the five conditions are indistinguishable on the wire, because saying which one failed would make the refusal an epoch and lease oracle. ADR 0033 fixes the gate; this is the one answer it has |
| `control_pending` | `session.acquire_control` that waited out its deadline | nothing |
| `control_capacity_reached` | any lease operation beyond the 512 concurrent-owner cap | nothing |
| `session_dormant` | `session.attach` | nothing |
| `daemon_stopping` | any method arriving after the daemon's admission cut | nothing |
| `session_unknown`, `session_id_invalid`, `store_unavailable`, `existence_indeterminate` | any method that validates existence first | nothing |
| `activation_ceiling_reached` | `session.create`, `session.resume` | nothing |
| `composition_mismatch` | `session.resume` on a session this composition cannot serve | nothing |

The one **uncorrelated** error generation 2 adds is `control_owner_lost`,
defined below with its cursor and its close behaviour.

**The limits input is not unchanged**, which an earlier revision's digest
table said while this pair advertised residency limits a client can read. The
added keys are enumerated so the digest covers them:

| Limit key | Value |
| --- | --- |
| `connections_per_daemon` | 512 |
| `initialize_deadline_ms` | 30,000 |
| `attachments_per_session` | 64 |
| `attachments_per_daemon` | 512 |
| `session_list_page_max` | 256 |
| `session_index_entries` | 4,096 |
| `lease_term_ms` | 30,000 |

ADR 0023's own framing and input ceilings are unchanged; these are additions
beside them, and **all five** digest inputs therefore change in generation 2.

**A connection reserves its one session before asynchronous work begins.**
Its state is `unbound`, `reserving(session_id, request_id, request_digest)` or
`bound(session_id)`. The first well-formed `session.attach` or
`session.acquire_control` changes `unbound` to `reserving` atomically in the
connection process **before** it asks the relay, existence query or core to do
anything. An exact retransmission with the same request ID and canonical
digest coalesces on that result. Any different request while reservation is in
flight, and every later request naming another session after binding, refuses
with ADR 0023's existing `invalid_request` before any gate or side effect.

Success converts the reservation to `bound`. A definite refusal that created
neither attachment nor lease clears it back to `unbound`; an admitted relay
ticket keeps it reserved until the real result arrives, and an unaccounted
task makes the relay fatal rather than guessing. This closes the pipeline race
in which attach for one session and acquire for another could both pass while
the connection still appeared unpinned. Without the rule a connection could
hold a lease on one session and an attachment on another, and
`control_owner_lost` — whose close ends *the connection* — would take down an
attachment belonging to a session that had nothing to do with the lost owner.

**`control_owner_lost` therefore carries `event_cursor` exactly when there was
an attachment to carry one for.** It is an ADR 0023 `error` record with
required `code`, bounded non-secret `message` and `session_id`. A connection
that acquired and never attached has no emitted cursor, and inventing one
would be a lie about what it received; `event_cursor` is **absent** in that
case and present otherwise. Both shapes are generation-2 vectors — one with
the cursor, one without — because a client parser must accept both.

**Connections are bounded, and an earlier revision said they were bounded by
the attachment ceiling, which they are not.** A client may connect,
`initialize`, call `session.list`, `daemon.status` or
`session.acquire_control`, or sit idle, without ever attaching — so the
attachment ceilings bound nothing about the number of sockets the daemon
holds, and a daemon whose bound is "the attachment ceiling" has no bound on
connections at all. The ceiling is **512 concurrent accepted connections**,
the attachment number reused rather than a fourth 512 invented, and the
daemon reports it as `connection_limit` with the live count as `connections`
so an operator can see the headroom before it is gone.

**The slot is taken at `accept`, not at `initialize`.** A ceiling enforced
only at the handshake bounds nothing that matters: a peer that connects and
never speaks holds a socket, a process and a buffer, and the daemon would
count it as zero. So the listener **reserves a connection slot as it accepts**
and closes the socket immediately when none is free — before any frame is
read, before the peer check, with no record, because a connection that was
never admitted has no generation to be told anything in. The slot is released
when the connection process ends, which is the same `DOWN` everything else
about a connection hangs from.

**There is no `initialize`-time refusal for the connection ceiling, and an
earlier revision of this section kept one beside the accept-time slot.** The
two cannot both hold: a slot taken at `accept` means the 513th socket never
reaches `initialize` to be answered anything, and a ceiling answered at
`initialize` is the ceiling on nothing that the paragraph above rejects. The
accept-time slot is the rule. What is lost with the refusal is stated rather
than glossed: a peer beyond the ceiling is closed **without being told why**,
and cannot tell a full daemon from one that is wedged or gone. That is the
price of bounding sockets rather than handshakes, and `daemon.status` is where
an operator sees the headroom instead. The peer-credential and filesystem
checks are unaffected, running on connections that did get a slot; a foreign
peer is closed before any of this.

Its witness is the boundary pair that matches the rule: the **512th**
connection is accepted, initializes and is served; the **513th socket is
accepted and closed with no frame read and no record written**, asserted from
the client side as an immediate EOF rather than as an error record; and
closing one of the 512 lets the next one through. A witness asserting a
`capacity_exceeded` at `initialize` would be asserting a path this decision
does not have.

**An accepted connection that never initializes is closed on a deadline**, and
without one the ceiling would be a ceiling on nothing: a peer that connects
and then says nothing occupies a slot for as long as it likes, and 512 of
them would refuse every real client while the daemon held 512 silent sockets.
Nothing else releases such a connection — there is no attachment to evict, no
lease to expire, and ADR 0023's connection-state rules govern what a
connection may *do* before `initialize`, not how long it may take. So an
accepted connection that has not completed `initialize` within the **lease
term, 30 seconds**, is closed, under its **own** advertised limit key,
`initialize_deadline_ms`. It is a separate key carrying the same value as
`lease_term_ms`, and the separation is the point: one key meaning two
contracts would let a later change to the lease term silently move the
handshake deadline, or the reverse, and a client reading `lease_term_ms` to
decide when to renew would be reading a number that also governs something it
has nothing to do with. **The value is derived rather than chosen**: thirty
seconds because that is the one connection-lifetime bound this milestone
already fixes, so the daemon introduces no number — and if the two ever need
to differ, they can, which is what having two keys buys. An `initialize`
handshake is one frame each way on a local socket, so thirty seconds is a
ceiling no honest client approaches. Adding the key changes generation 2's
limits input and therefore its digest, which is stated here so the pinned
literal is computed over it. The close carries no record — the connection has
negotiated nothing, so there is no generation whose error shape it could be
sent in — exactly as the peer-credential refusal closes before initialize.

Its witness is the pair that must differ: a connection accepted and left
silent is asserted **closed** after the term and the slot it held asserted
free, while one that completes `initialize` inside it is asserted to stay open
indefinitely with no such close. It is a long-duration bound, so it is tagged
`long_bound` and injected where it is armed, with the production default
asserted once.

The tables above are the contract for both directions; an earlier revision
kept a second, prose summary of the same four methods beside them, which is
exactly how two descriptions of one wire drift apart. It is gone, and the
per-method tables are the only statement of what a request and a result
carry.

**The `daemon.stopping` record, field by field:**

| Field | Value |
| --- | --- |
| `reason` | One of `operator_stop`, `store_lost`, `store_capacity_exceeded`, or `fatal:<class>` for a live-registry fatal class. The set includes `fatal:listener_lost`: listener loss stops new accepts but leaves the connection registry and existing sockets available, so the registry can make the bounded write and close them. The set excludes `fatal:connections_lost`: once that registry is gone there is no live inventory or buffer-control interface through which to write. On that class the owner closes the listener, synchronously cuts relay admission, stops the remaining components and halts; existing sockets close with the VM. The ordinary component reasons remain `fatal:runtime_lost`, `fatal:transfers_lost`, `fatal:workspace_lease_lost`, `fatal:executor_lost`, `fatal:registry_lost`, `fatal:custody_lost`, `fatal:capability_lost`, and `fatal:relay_lost`. A lease owner's death is session-scoped and uses `control_owner_lost`. Startup classes have no socket, and `owner_lost` has no owner to write a record |
| `message` | A bounded non-secret sentence for an operator to read |

There is no `retry_after_ms`. Even on `operator_stop` the daemon does not know
when an external service manager or operator will start a successor, so any
numeric retry promise would be invented.

**Its delivery is bounded best-effort, and the bound is one the daemon already
has.** The daemon makes exactly **one** write attempt of the record into the
connection's existing 4 MiB output buffer and then closes the connection
regardless of what happened. If the buffer cannot accept it — a backpressured
client that has not been reading — the record is dropped and the connection is
closed anyway. A dead client receives nothing at all. **So a client may learn
of a shutdown only by its socket closing**, and this pair says so rather than
implying the record always arrives; a client that treats an unexplained close
as a defect would be wrong.

The bound is the buffer's, not a new timer: a millisecond deadline would be a
number this milestone introduces, and the minimalism budget requires every
number to come from an accepted or proposed decision. One non-blocking attempt
into a bound that already exists is the same guarantee with nothing new to
justify.

**This changes the generation-2 digest, and so do the error codes.**
`LoopexProtocol.Session.schema_digest/0` is taken over the generation, the
ordered methods, the ordered record families, the ordered error codes and the
limits — five inputs, and generation 2 changes **all five**:

| Digest input | Generation 2 |
| --- | --- |
| Generation | New string |
| Methods | Adds `session.list`, `daemon.status`, `session.acquire_control`, `session.release_control` |
| Record families | Adds `daemon.stopping` and `daemon.notice` |
| **Error codes** | Adds every refusal generation 2 can return and generation 1 cannot: `control_held`, `control_not_held`, `control_pending`, `control_capacity_reached`, `control_owner_lost`, `session_dormant`, `daemon_stopping`, the four existence-query refusals the daemon maps to the wire (`session_unknown`, `session_id_invalid`, `store_unavailable`, `existence_indeterminate`), and the activation and residency refusals (`activation_ceiling_reached`, `composition_mismatch`). **Not** `session_index_too_large`, `session_index_corrupt` or `session_index_upgrade_required`, which are startup exit classes and can reach no client, and **not** `capacity_exceeded`, which generation 1 already carries and generation 2 keeps for the two **attachment** ceilings — `attachments_per_session` and `attachments_per_daemon`, the "stable reason when exhausted" the attachment-lifecycle list names — and no longer for the connection ceiling, which is enforced at `accept` and therefore reaches no `initialize` |
| **Limits** | ADR 0023's framing and input ceilings are unchanged, and generation 2 **adds** the residency keys a client can read: `connections_per_daemon`, `initialize_deadline_ms`, `attachments_per_session`, `attachments_per_daemon`, `session_list_page_max`, `session_index_entries`, `lease_term_ms` |

**`control_owner_lost` closes a controller whose lease owner died.** ADR 0033
makes a lease owner's failure session-scoped: the daemon closes that session's
controller connection, leaves its observers attached on their own, and lets the next
acquisition start a fresh owner with a fresh epoch. The closing client is owed
a reason for a close it did not ask for, and this is it — distinct from
`control_held`, which refuses an acquisition, and from `control_pending`,
which times one out. It enters the ordered error list, the digest and the
generation-2 vectors with the others.

**`control_pending` is the acquisition timeout, and it was missing.** ADR 0033
refuses an acquisition whose own deadline elapses while it waits behind an
unresolved admission, with a stable reason — and the inventory above claimed
to be complete while having no code for it. `control_pending` is that code: it
says the lease is not held by anyone the client must wait for indefinitely,
only that this acquisition did not get it in time, which is a different fact
from `control_held` and deserves a different refusal. It enters the ordered
error list, the digest above, and the generation-2 vectors alongside the
others.

`control_capacity_reached` is the refusal for a lease operation that would
exceed the concurrent lease-owner cap — 512, the per-daemon ceiling this ADR
already fixes, reused rather than doubled by a second number. The plan's
companion states where that cap comes from and why the population it bounds is
not the activation count.

Listing the error codes matters because it is the input most easily forgotten:
a refusal reason invented at implementation time and not entered in the
ordered list would make the served contract differ from the digest the server
advertises, which is exactly the drift the digest exists to catch. The
generation-2 literal the conformance module pins is the digest of the contract
*including* all five changed inputs, and a build missing any of them computes
a different value and fails there. Generation 1 gains no method, no record family and no error code — but its
digest is **not** untouched, because M5 renames its generation string from
`loopex.session.v1-experimental` to `loopex.experimental/1` and the generation
is the digest's first input. That rename is the plan's decision, taken under
the vision's 0.x experimental policy; this ADR records its consequence here,
which is that generation 1's **schema digest** — and only that — is
recomputed and re-pinned alongside generation 2's, with every other input to
it byte-identical. Its two published manifests are not touched: they already
declare `loopex.experimental/1`, so the rename makes the code agree with them
rather than changing them. The
generations the two servers advertise are therefore `loopex.experimental/1`
from the foreground server and `loopex.experimental/2` from the daemon —
**neither advertises both**, each serving exactly one generation, which is what
the exact-generation rule means here — and neither carries the old name.


### Generation 2, at the precision literal vectors need

Every code and record below has to be written as bytes before the conformance
module can pin a digest, so each is fixed here rather than left to the
implementation. Seven were underspecified in an earlier revision, and this is
the whole of what was missing.

**`control_not_held`, the one answer the admission gate has.** It refuses
`session.release_control` from a connection that is not the current holder or
whose `writer_epoch` does not match, **and** every lease-authorized
existing-session mutation that fails ADR 0033's combined check on holder
connection, epoch, `held` state, unexpired deadline or a live attachment for
the pinned session. One code for all of them, carrying nothing beyond the envelope:
the refusals a client can provoke must not tell it whether a lease exists,
whether its epoch was right or whether it was merely late, because that is an
oracle for the value the gate protects. It is distinct from `control_held`,
which refuses an *acquisition* because
somebody else holds the lease, and from `control_owner_lost` below. The
refusal changes nothing: the current holder's lease, epoch and deadline are
untouched, which is the point — a release that could be issued by a non-holder
would be a way to take control away without taking it over.

**`control_pending` and the deadline behind it.** A request carries exactly
`method`, `request_id` and its row's fields (ADR 0023's request shape,
`0023-…-technical.md:131-133`), so there is **no deadline field on the wire**
and none is added. The deadline is the **daemon's**, it starts when the
acquisition request is admitted — not when the client sent it, which the
daemon cannot know — and it equals the **lease term**, 30 seconds, so no
number enters that ADR 0033 has not already fixed. A waiter that reaches it
refuses `control_pending` and the client may acquire again.

**A waiter whose connection disappears is cancelled**, and the lease owner
learns of it the same way it learns of any connection loss: the waiter is
bound to the connection that made the request, so when that connection is
gone the acquisition is abandoned, no grant is made, and no epoch is minted.
A grant to a connection that no longer exists would hold a lease nobody could
release until it expired.

**`control_owner_lost`, exactly.** It reuses the record family ADR 0023
already defines for post-admission writer loss rather than adding one: **one
uncorrelated `error`**, with

| Field | Value |
| --- | --- |
| `type` | `error` |
| `code` | `control_owner_lost` |
| `message` | bounded non-secret explanation |
| `session_id` | the session whose lease owner died |
| `event_cursor` | optional; present exactly when this connection held an attachment, carrying that attachment's last completely emitted durable cursor exactly as `detached` does |

It is uncorrelated because no request caused it. **Close behaviour:** it is one
instance of the daemon-initiated detach rule below — the daemon writes the
record best-effort into that connection's output buffer and then **closes that
connection**. Every other connection is untouched, so every observer keeps its
attachment and keeps receiving, which is what "the observers stay" means: an
observer is on a connection of its own, because generation 2 binds a
connection to at most one attachment. A client that sees it may reconnect and
acquire again; the next acquisition starts a fresh owner and mints a fresh
epoch.

**Every daemon-initiated detach is a record and a close, and the rule is one
rule.** A connection holds at most one attachment, so a daemon that "detaches"
a connection has left it holding nothing — no cursor position it can act on,
no way to be told what it may resume from except the record it is being sent,
and no mechanism to re-establish an attachment except a fresh `session.attach`
it could equally send on a fresh connection. An earlier revision left such a
connection open and declined a detach API in the same breath, which left the
client in a state neither side had defined. So:

| Occasion | Record written first | Then |
| --- | --- | --- |
| The controller's lease owner died | `error`, `control_owner_lost`, with required `message` and `session_id`, plus `event_cursor` exactly when the connection held an attachment | close that connection |
| Output-buffer or core-queue overflow | `error`, ADR 0023's `detached`, with `session_id` and `event_cursor` | close that connection |
| Aggregate byte pressure chose this attachment | the same `detached` | close that connection |
| Idle eviction at ten minutes | the same `detached` | close that connection |

Reusing `detached` for the three eviction rows is a **widening inside
generation 2**, stated rather than slipped in: ADR 0023 defines that code for
post-admission writer loss, and its own pressure rule already says to detach
at the last completely emitted cursor and say so
(`0023-…-technical.md:362`). Generation 2 extends the occasions, not the
record — same code, same fields, same uncorrelated shape — and generation 1's
use of it is untouched, so the foreground server's behaviour does not move and
the ordered error list gains nothing for it.

**Where `event_cursor` is present, it is the same quantity in all four**: the
**last completely emitted durable cursor** for that attachment — the highest
event sequence the daemon finished writing to that socket, never one it had
only encoded or buffered. A controller connection that never attached omits
it. The cursor is the position the client reconnects at, and delivery from it
is contiguous and at least once, so a duplicate at the seam is expected and a
gap is a defect.

**"Best-effort" is the bound `daemon.stopping` already has**, reused rather
than restated: exactly **one** non-blocking write attempt of the record into
the connection's existing 4 MiB output buffer, and the close happens whatever
that attempt did. A backpressured client — which is precisely the client an
overflow detach is about — will usually not receive it and learns by EOF
instead. No new timer and no new number.

**No other connection is affected by any of the four**, and that is the
property the witnesses assert: a case per occasion, each with a second
connection attached to the same session, asserting the first connection sees
the record where its buffer admits one and sees EOF either way, and the second
keeps receiving durable events across the whole of it. Each of the four is a
generation-2 vector: `control_owner_lost` under its own code, and three
`detached` vectors distinguished by nothing on the wire — the code and fields
are identical, which is deliberate, because why the daemon detached is an
operator fact in its logs and not authority-shaped information a client acts
on differently.

**`daemon_stopping`, the refusal after the admission cut.** Every
post-initialize method request takes a linearized permit from the admission relay. For the ten
state-changing calls ADR 0033 names, the relay records a ticket and starts the
monitored core task before returning the permit. For queries and artifact
transfer calls it returns an unticketed permit; those calls grant no lease and
change neither Control nor the journal, but using the same gate removes a
connection-layer check/use race.

An orderly stop sends `cut` to that relay. When the relay handles the message
it switches to closed and acknowledges immediately. The mailbox order is the
linearization order: a request admitted before the cut may enter or remain in
core and is allowed to finish; a request processed after the cut refuses with
the correlated `daemon_stopping` carrying its `request_id` and nothing else.
The acknowledgement means **no later request can be admitted**. It does not
mean admitted work has settled or that no pre-cut task will enter core after
the acknowledgement. The drain waits separately, to its absolute bound, for
the tickets that the cut returned as outstanding.

The connection stays open until the later close phase, so a post-cut frame can
still receive its correlated refusal. That refusal closes nothing by itself;
`daemon.stopping` is the subsequent uncorrelated best-effort notice that names
why the connection is closing. The two witnesses deliberately differ: a
pre-cut request completes on its own terms, while the same request admitted
after the cut receives `daemon_stopping` and never invokes its facade.

**Index startup failures are not wire codes.** `session_index_too_large`,
`session_index_corrupt` and `session_index_upgrade_required` all stop startup
before a socket exists, so no client can be holding a negotiated connection to
be told. They stay in the daemon's exit classes and out of generation 2's
ordered error inventory.

**A failed discoverability-index write is a notification, not an error.** Generation 2
adds a **second notification record family**, `daemon.notice`, beside
`daemon.stopping`:

| Field | Value |
| --- | --- |
| `code` | one of a closed set, today `index_write_failed` |
| `session_id` | the session the notice is about |
| `message` | a bounded non-secret sentence for an operator |

**It goes to the connection whose command caused it, and only that one**, and
it is written **after** that command's result rather than before: a client
that sees the notice first would be told about a session it has not yet been
told the identity of. If that connection is gone by then the notice is
**dropped** — it is about a command nobody is waiting on, the session is
reachable regardless, and the daemon's own `stderr` keeps the operator's copy.
It is never broadcast; other connections did not ask.

The activation it follows **succeeded**: the session is usable and reachable
by ID, and its persistent index row is missing, to be written by the retry the
plan already describes. The legacy directory entry is an independent rollback
artifact and its failure is logged separately. Reporting the index failure as an `error` would
tell a client its command failed when it did not, and saying nothing would
leave a session absent from `session.list` with no explanation. The family
enters the digest's record-families input beside `daemon.stopping`.

**Correlation, for the refusals above.** `control_not_held`,
`control_pending`, `control_capacity_reached`, `control_held`,
`session_dormant`, `daemon_stopping` and the four existence-query refusals are
ordinary **correlated** errors: each answers one request and carries that
request's `request_id`, no `event_cursor` and no session state, and none
closes anything **by itself** — the connection and every attachment on it are
untouched by the refusal, and where the connection is nonetheless closed a
moment later it is the stop sequence or the detach rule below doing it, not
the error. The uncorrelated cases in generation 2 are the ones named above,
`control_owner_lost`, ADR 0023's `detached` as this pair's detach rule reuses
it, and the `daemon.stopping` and `daemon.notice` records, and each states its
own close behaviour where it is defined. Stating this once is what lets the
vectors be written without guessing.

**The existence query's `unexpected` maps to `existence_indeterminate`.** Core
answers one of five results; the daemon maps `store_unavailable` to the wire's
`store_unavailable` and **`unexpected` to `existence_indeterminate`**, because
a result core did not recognise is exactly a case where existence could not be
decided, and inventing a distinct wire code for "core said something we do not
understand" would expose an internal disagreement a client cannot act on. The
two refuse identically in effect — nothing created, nothing attached, no lease
— and differ only in the reason a client is given.

### The session index, and what it may claim

`session.list` reads a daemon-owned persistent discoverability index loaded at
startup. It never enumerates `sessions/` and never reads the Store on either
the startup or request path. This is a **maintained index**, chosen because the
supported OTP file API exposes `File.ls/1` as a complete list and supplies no
portable incremental directory iterator: wrapping that call in a function
which stops after 4,097 valid rows would still materialize every filename and
could inspect arbitrarily many malformed rows before reaching the bound.

The file is `<state root>/daemon/session-index-v1`. It contains only durable
discoverability inputs: `session_id` and `placement_identity`. `residency` and
`controlled` are live daemon overlays and are rebuilt as `dormant` and `false`
at each start. The index is **not Store truth**. It neither proves existence nor
participates in create, resume, admission, replay or recovery. Core's read-only
existence query is the only yes/no authority the daemon uses for an exact ID.

**The persisted format is bounded before parsing.** The file is canonical
UTF-8 JSON Lines with one version header, zero to 4,096 rows sorted by session
ID bytes, and one SHA-256 trailer over the exact header-and-row bytes. Header,
row and trailer keys and their order are fixed; unknown keys, duplicate or
out-of-order IDs, invalid identity alphabets and bad digests are corruption.
Each line is at most 1,024 bytes and the complete file is at most 4 MiB. The
daemon opens without following a symbolic link, checks the regular-file
identity and byte size before reading, reads no more than 4 MiB plus the
single byte needed to prove overflow, and checks the identity again after the
read. Oversize refuses `session_index_too_large`; malformed content refuses
`session_index_corrupt`. Both occur before socket bind.

**Updates are atomic snapshots, not an append protocol.** The marker-holding
daemon serializes index changes, writes the complete next canonical image to a
mode-`0600` sibling created with exclusive creation, syncs that file, renames
it over `session-index-v1`, and syncs the `daemon/` directory before it reports
success. A crash before rename leaves the prior image; a crash after the
directory sync leaves the next one. Only a daemon that has acquired the Store
marker may remove an abandoned temporary. This adds no journal record and
changes no local Store byte. At 4,096 rows a new exact-ID session remains
usable but is not added; `session.list` reports `index_full: true` rather than
pretending completeness.

A successful activation or exact-ID recovery adds the row after durable
existence is established. The row becomes visible in memory only after the
snapshot is durable. A failed index write does not reverse the session
operation; the causing connection receives `daemon.notice` with
`index_write_failed`, the daemon logs it, and later commands carrying that ID
retry the same idempotent write. A retry with the same placement is idempotent;
a different placement conflicts. The independent legacy
`SessionDirectory.record_session/3` write remains for foreground rollback and
may succeed or fail separately.

**Upgrade is explicit so startup stays bounded.** A new root whose `sessions/`
directory does not exist gets an empty canonical index before bind. If
`sessions/` exists but the index does not, daemon startup performs only the
bounded `stat` needed to learn those two facts and refuses
`session_index_upgrade_required`; it never calls `File.ls/1`. The operator runs
`loopex daemon prepare-index` while no daemon or foreground server owns the
root. That offline command acquires the local Store marker, uses the legacy
session-directory enumeration, validates every non-temporary row, refuses
rather than truncates above 4,096 valid rows, writes the atomic index, and
releases the marker. Its scan is explicitly **not** a bounded service-start
operation: the command warns that legacy `File.ls/1` materializes the directory
and may need operator repair of a corrupt or oversized legacy directory. This
one-time cost is kept outside daemon availability rather than mislabeled as a
bound.

Rollback needs no reverse migration. The M4 foreground server ignores
`daemon/session-index-v1` and continues using `sessions/`; the index may remain.
A later daemon reuses and validates it, but `session.list` never claims that a
row absent from this advisory index is absent from Store truth. If a foreground
server created sessions while the daemon was absent, the operator reruns the
offline import before relying on a complete discoverability view; exact-ID
access works regardless. Deleting the index is not a repair: on a root with
`sessions/` it restores the upgrade refusal and requires another explicit
import.

The in-memory projection claims only facts its owners can keep true:

- `session_id` and `placement_identity` come from the validated persisted row
  or from an exact-ID operation after core answered `present`;
- `residency: active` means this daemon activated that session in this
  lifetime; `dormant` means it has not. It never claims a coordinator is live;
- `controlled` is updated by the one lease owner on grant, release, expiry and
  owner death. It names no durable controller.

Lineage, lifecycle state and committed sequence are deliberately absent. A
client that needs them attaches and reads the snapshot anchored by core.

**Recovery of an omitted row uses identity the client already owns.** Core's
existence query answers exactly `present`, `absent`, `invalid_id`,
`store_unavailable` or `unexpected`; only `present` permits an index write,
lease grant or later activation. The other four leave no attachment, lease,
activation or row and map to their distinct generation-2 refusals.

A client that lost the create reply and therefore lacks a session ID recovers
in this exact sequence:

1. Re-present `session.create` with the original `command_id` and byte-identical
   creation inputs.
2. The daemon reservation verifies the canonical request digest and forwards
   the replay without consulting the index.
3. Core returns the historical session ID; a changed request under that ID is
   a conflict, not a coalesced success.
4. Replayed create starts no coordinator.
5. The daemon asks core's read-only existence query for the returned ID and
   proceeds only on `present`.
6. It idempotently repairs the legacy directory entry and the daemon index row;
   either write may report its own failure without changing Store truth.
7. The client acquires control and receives a writer epoch.
8. It sends `session.resume` with a fresh resume `command_id` and that epoch.
9. The daemon activates the session and charges the lifetime ceiling.
10. The client attaches and drives it.

A client that already knows the session ID begins at step 5. If the index is
full, step 6 reports `index_full` and omits the row while steps 7 through 10
remain available. The witness injects the Store-commit/before-reply crash cut,
runs all ten steps, and proves one durable session, no coordinator from the
create replay, a repaired row, one charged activation and a subsequent prompt
on the recovered session.

A page is consistent with the in-memory index at the moment it is read and is
ordered by session ID bytes. Rows are added but never removed during one daemon
lifetime, so insertion before a page cursor can make a later page miss the new
row; rows do not vanish or repeat. A client that needs a refreshed view pages
again from the start. `limit` outside 1 to 256 and a malformed
`after_session_id` refuse `invalid_request`; an unknown but well-formed cursor
pages from its byte position.

The startup witness places more than 4,096 valid legacy entries and an
arbitrarily large population of malformed names beside a valid bounded index,
and proves that daemon start reads only the index bytes and performs no
`File.ls/1` call. Separate cases prove oversize, digest failure, duplicate ID,
interrupted snapshot replacement, missing-index upgrade refusal, successful
offline import and foreground rollback with the extra file present.

### Session residency: active, dormant, and their bounds

A session is **active** when this daemon activated it in this lifetime and
**dormant** when the root holds it durably and this daemon has not. Dormancy
is about activation and **not** about the index: a session the index does not
record — one past the 4,096-entry ceiling, or one whose directory entry was
never written — is dormant in exactly the same sense, and is reached by ID and
activated in exactly the same way. What the index controls is whether
`session.list` shows it, and nothing else. An earlier revision defined dormant
as "the index records it and this daemon has not", which made an unrecorded
session neither active nor dormant and made the listing bound look like a
bound on reachability, which this pair says twice that it is not. Nothing
durable distinguishes active from dormant, and neither is a claim about a live
coordinator: both are daemon facts, recorded when the daemon acted.

A dormant session costs less than an active one, but not nothing, and the
plan should not pretend otherwise. If indexed, it holds one row against the
4,096-entry ceiling, and its history sits in the root's single append-only log
against the 256 MiB capacity that every session in the root shares — so a
dormant session still consumes the two resources whose exhaustion stops the
daemon, and retiring a root is what actually frees them. What it costs nothing
in is the things activation buys: no coordinator, no replay at start, no
attachment, no window, no buffer.

**Activation is one-way for the daemon's lifetime.** A session the daemon has
activated keeps its coordinator until the daemon exits. Dormancy is *not*
deactivation, and the daemon has no operation that stops a coordinator.

That is a correction, not a simplification. An earlier draft let an idle
session "go dormant, releasing its slot", which is wrong twice over. The idle
condition it named — no attachment and no admitted command — is not the same
question as whether work is running: a session with every client detached can
still have a model request in flight, a tool effect dispatched, an interaction
awaiting an answer, a recovery in progress, an unresolved `commit_unknown`, or
an admission executing inside core. Stopping it would destroy exactly what
Outcome 1 exists to prove, that work progresses with zero attachments. And
there is no operation to stop one with: core owns coordinator lifetime, and
none of M5's five core changes (the complete concurrent-attachment lifecycle,
the read-only existence query, the trace exclusion, `quiesce/1`, and the
`disposition` and `control_entry` fields on the detailed create and resume
functions) stops a coordinator,
so a deactivation call would be a further core change this milestone does not
make.

- **What dormancy applies to.** Attachments, resident windows and socket
  output buffers, and nothing else. An idle attachment is evicted, its window
  may be reclaimed, its buffer is released — and the coordinator beneath them
  keeps running. Every byte ceiling in this decision is about those three and
  is unaffected.
- **Lazy recovery.** A restarted daemon activates no session. It acquires the
  writer marker, reads the index, binds the socket, and activates a session
  when a client first reaches it — by `session.resume`, or by `session.create`,
  which starts a coordinator for a session that did not exist before.
  **Creation counts as an activation** against the ceiling below, because it
  costs exactly what any other activation costs: a live coordinator the daemon
  holds for its lifetime. A ceiling that counted resumes but not creations
  would be a ceiling on the wrong thing.

  `session.acquire_control` and `session.attach` do **not** activate. Acquire
  is a lease over a session that durably exists, validated by the existence
  query, and attach is refused with `session_dormant` against a session this
  lifetime has not activated — which is exactly why the CLI's `resume` form
  exists and why `attach` alone cannot start work.
- **Activation ceiling.** At most 64 sessions are activated **per daemon
  lifetime**, not at once, because nothing gives a slot back. The 65th
  activation refuses with a stable reason naming the ceiling and the remedy,
  which is to restart the daemon. That is a real limitation rather than a
  design, it is recorded as one in the plan and in the operator page, and it
  is the honest cost of leaving coordinator lifetime alone in M5. Lifting it
  needs a core deactivation operation that can tell "quiescent" from "idle",
  which is a decision of its own.
- **Index bound.** The maintained index holds at most 4,096 recorded entries
  and its complete persisted image is at most 4 MiB. Startup refuses an
  oversize or corrupt index before bind; runtime discovery of an additional
  exact-ID session sets `index_full` and leaves the session usable. The daemon
  never scans the legacy session directory. A root that predates the index is
  prepared explicitly by the offline import described above, which refuses
  above 4,096 rather than writing a truncated image. This mechanism belongs to
  the daemon adapter and removes the proposed `Loopex.list_sessions/2` change
  from core.
- **Homogeneity.** One state root is one host composition for the daemon's
  process lifetime. The daemon is composed once, with one workspace, policy,
  provider configuration and set of project resources, and serves every
  session in the root under it. A recorded session the current composition
  cannot serve — a placement identity it does not hold, or retained
  configuration it cannot satisfy — is reported at *activation*, naming the
  session and the mismatch, with the existing refusal reasons; it is never a
  reason a start fails, because recovery is lazy and start never reads it. The
  operator documentation says that mixing compositions in one root means some
  sessions will refuse to activate, and that the remedy is one root per
  composition.

The client supplies its ordered supported generations in `initialize`. The
daemon supports exactly `loopex.experimental/2`: it selects that generation
when the client lists it, at any position, and otherwise refuses with
`unsupported_generation`, leaving the connection uninitialized with no second
attempt, exactly as ADR 0023 fixes for a foreground process. The successful
reply carries `selected_generation`, generation 2's own exact schema digest,
the generation-2 method inventory and limits. That digest is necessarily a new
value: the digest is taken over the generation, the ordered methods, the
ordered record families, the ordered error codes and the limits, and
generation 2 changes the generation and the method list, so it cannot and must
not equal generation 1's. It is written out as a literal beside generation
1's. Generation 1's **schema digest** is re-pinned in the same place rather
than asserted unchanged, because the rename above moves it — its two
manifest file digests do not move, those files already carrying the new
name — and the case that pins it asserts every *other* input to generation 1's
digest, its ordered methods, record families, error codes and limits, is
byte-identical to what `0.1.0` served. That is what still catches an accidental edit to
generation 1's contract: the inputs are compared, not just the result, so a
changed method list fails there instead of hiding behind a digest that was
expected to move anyway. The generation-2 schema and its
vectors are new files beside generation 1's, as
`apps/loopex_protocol/priv/schema/loopex-experimental-2.json` and
`apps/loopex_protocol/priv/vectors/loopex-experimental-2.json`, reviewed with
the change that adds them, and **each carries its own pinned file digest**
written into the conformance module beside the two generation 1 already pins —
so an independent client can fetch either file and verify its bytes, and an
edit to a generation-2 file fails the same way an edit to a generation-1 file
does. The digests are computed and pinned when the files are written;
generation 1's two file digests are **unchanged**, because those manifests
already carry `loopex.experimental/1` and never carried the retired name; only
its schema digest moves, the generation being one of that digest's inputs.
Every served generation is additionally asserted to have `Session.generation()`
equal to its own manifest's `/generation`, which is the check whose absence
let the released code and the released manifests disagree in the first place. A negotiation vector proves selection from a list
that also names generation 1 under its new string, refusal of a list naming
only generation 1, and refusal of a list naming only the retired
`loopex.session.v1-experimental`. The M4 foreground server keeps
serving generation 1 only, with its one-attachment-per-process rule.

### Attachment lifecycle

Attach is the runtime's race-free cursor transaction: the dispatcher
establishes the barrier at committed sequence N, the snapshot is anchored at
exactly N, and durable events after N are buffered for that attachment and
delivered contiguously after the snapshot. The daemon adds:

- a resident window of at most 4,096 durable events and 16 MiB of encoded
  events per session held in memory, defined as a **droppable encoding
  cache** and nothing else. It holds the encoded bytes of events core has
  already delivered to at least one attachment of that session, so a second
  attachment arriving at the same position is served without encoding them
  again. It is not a replay source: it never anchors a snapshot, never
  establishes or advances a cursor, and is never consulted to decide what a
  client is owed. Every attach, reattach and reconnect — including one whose
  position lies inside the window — goes through core's cursor transaction,
  and the window is used only to answer the bytes core has already named. It
  may be dropped whole at any instant; the only consequence is that the next
  delivery re-encodes. Correctness therefore cannot depend on it, and the
  tests prove that by running the residency cases twice, once with the window
  disabled, with identical delivery.

  Reclamation is deterministic so that it can be tested rather than observed.
  When the daemon's aggregate encoded-byte ceiling would be exceeded, windows
  are released in this fixed order: first every window whose session has zero
  attachments, in ascending order of the monotonic time of their last
  delivery, ties broken by session ID bytes ascending; then, if the ceiling is
  still exceeded, the window of the session whose slowest attachment is
  furthest behind **by encoded bytes owed** — the sum of encoded bytes for
  events core has named for that attachment and the daemon has not yet
  written, which is a daemon-owned quantity comparable across sessions because
  it is measured in bytes rather than in each session's own sequence numbers.
  A sequence-distance metric would not be comparable: sequence numbers are
  per-session and say nothing about how much memory an attachment is costing.
  Ties break by session ID bytes ascending. Each step is **repeated until the
  aggregate is below the ceiling**, not applied once: releasing one window may
  not be enough, so zero-attachment windows are released in that order until
  either the aggregate fits or none is left. Only when none is left does the
  daemon detach the slowest attachment at its last emitted cursor — sending
  that connection a `detached` record and closing it, under the detach rule
  above, so the bytes the attachment was holding are released with the
  connection rather than lingering behind an open socket nothing is reading —
  and that too repeats until the aggregate fits. Independently of pressure, a window whose session has had zero
  attachments for the idle interval is dropped. No reclamation stalls a
  journal transaction and none changes what any client is owed.

  On the local adapter every durable event is retained until the root is
  retired, so store replay always succeeds. `cursor_expired` with a fresh
  snapshot and cursor is the defined response a compacting adapter returns for
  a cursor older than its retained history; no M5 witness can produce it and
  none claims to;
- the core event-count queue and the daemon socket output buffer above; when
  the next event would exceed either, the attachment is detached at its last
  completely emitted cursor with a stable reason — a `detached` record and the
  close of that connection, under the detach rule above — and the client
  reconnects at that cursor on a new connection;
- at most 512 MiB of retained encoded events across the daemon's output
  buffers and resident windows; on aggregate pressure, evict or detach the
  slowest eligible attachment before admitting more bytes, without stalling
  a journal transaction, and by the same record-then-close;
- 64 attachments per session and 512 per daemon, refused at attach with
  **`capacity_exceeded`** when exhausted — ADR 0023's existing code, and after
  the connection ceiling moved to `accept` the only thing in generation 2 that
  produces it;
- eviction of an **observer** attachment that has consumed nothing for ten
  minutes; the
  `detached` record names the cursor the client may resume from and the
  connection is closed with it.

  **A connection holding a controller lease is exempt while it holds it**, and
  that exemption is a correction rather than a convenience. A controller of a
  quiet session — one waiting on a long model call, a slow tool or an
  unanswered interaction — consumes nothing for minutes at a time and is
  perfectly healthy; evicting it would close the connection its lease is bound
  to, and ADR 0033 frees a lease early only on an explicit
  `session.release_control`, so the session would then be uncontrollable until
  the term expired, with the outgoing controller told nothing it could act on.
  Renewals are that connection's activity, and they are already required every
  ten seconds against a thirty-second term, so a controller that has stopped
  renewing loses its lease on its own clock and becomes an ordinary observer,
  at which point the idle interval applies to it like any other.

  Its witness is the pair that must differ: a controller of a session with a
  long-running model call, consuming nothing for longer than the interval, is
  asserted **still attached and still holding its lease**, while an observer
  on the same session across the same interval is asserted evicted and closed.
  A second case stops the controller's renewals and asserts that once the term
  elapses it is evicted like any observer, so the exemption is proved to be
  the lease's and not the connection's.

  **What resets the interval**, stated because "consumed nothing" is not a
  mechanism: any **durable record the daemon completely emits to that
  connection**, and any **request that connection sends**. Either is evidence
  of a live peer. Progress that is coalesced or dropped does not reset it, and
  neither does a record the daemon buffered but did not finish writing — the
  cases where the client may be exactly the one that has stopped reading;
- transient progress coalesced per attachment and dropped first under
  pressure, with a counted drop; no progress item ever waits on a journal
  transaction.

A detached, evicted or reconnecting client that attaches at its retained
cursor receives every durable event after that cursor at least once and in
order; it never receives a gap, and it deduplicates by session ID, event
sequence and event ID.

### Evidence

Tests prove: two attachments from one embedded holder and attachments from two
holders keep independent handles, snapshots and cursors; named replacement
removes only its exact same-holder target and releases only that target's
transfers; a foreign, stale or other-session selector changes nothing; holder
death removes its complete attachment set in EventDispatcher and Control and
releases every transfer while another holder continues; the daemon retains
closing slots until relay settlement and `release_holder/2` acknowledgement,
so a replacement attach never crosses either count ceiling.

The protocol suite proves the inherited boolean replacement remains byte- and
behavior-compatible in both generations and each adapter maps it to core's
exact target, a
pipelined attach and acquire cannot bind one connection to different sessions,
`control_owner_lost` vectors cover both optional-cursor shapes with the
required message, `fatal:listener_lost` reaches existing clients and
`fatal:connections_lost` does not claim a record, and the synchronous cut
admits pre-cut work while refusing every post-cut request.

Replay evidence proves snapshot-then-contiguous at-least-once delivery with no
gap across enabled, disabled and mid-stream-dropped resident windows; bounded
reclamation, slow-client detach, idle eviction and reconnect leave other
attachments progressing; all count and byte ceilings refuse independently
with process RSS recorded; and progress is coalesced or dropped without a
journal delay.

Index evidence proves startup reads at most the 4 MiB index image and never
enumerates `sessions/`, including with more than 4,096 valid legacy files and
arbitrarily many malformed names; oversize, corrupt, duplicate and interrupted
images fail or recover as specified; a missing legacy-root index requires the
offline import; foreground rollback ignores a valid index; paging carries only
the four fields and exact cursor; full-index exact-ID activation succeeds with
`index_full`; and command-ID recovery repairs an omitted row without creating
a second session. The transport cases also cover simultaneous starts, Store
loss, generation negotiation, peer authorization, socket-path bounds and ADR
0023 framing refusals.

### Alternatives

TCP on loopback was rejected for the local daemon: it has no peer-credential
check and invites remote exposure by misconfiguration; WebSocket and HTTP
remain later transports under vision §18.8. An unbounded per-attachment queue
was rejected because it lets one client grow coordinator-adjacent memory
without bound. Keeping the M4 one-attachment-per-process rule was rejected
because a daemon's clients are processes by definition. Keeping one
attachment per holder was also rejected: an embedded holder may need several,
and a boolean replacement cannot identify one of them. A daemon-owned proxy
fan-out was rejected because it would duplicate core cursor and queue
ownership and need a second replay boundary to preserve the
subscribe/snapshot race. Serving generation 1 on the daemon was rejected: its
wire has no lease field, so it could only ever be served as one exclusive
connection per session, which the foreground server already provides, and it
would add a second fencing path with no wire epoch. Promising exactly-once
replay was rejected on 2026-09-14 because the founding contract is
at-least-once with client deduplication, and a stronger daemon promise would
create an expectation no other surface honors. Removing `session.list` was
rejected on the same day because an observer without filesystem access to
the root would have no way to discover sessions; the bounded page contract
above is the cost of keeping it. A bounded wrapper around `File.ls/1` was
rejected because the complete name list has already been materialized before
the wrapper can stop. A daemon-maintained index was selected instead of a
native directory iterator because OTP exposes no portable streaming iterator
on the supported platforms and the index changes neither Store ports nor
journal bytes.

<a id="technical-adr-0032-compatibility"></a>
### Compatibility and Rollback Mechanics

Concept: [Consequences and rollback](0032-daemon-attachment-residency-and-replay.md#concept-adr-0032-consequences).

Generation 2 is additive over generation 1's method set and both are
experimental with the exact-generation rule; no mixed-generation stream
promise exists. The daemon serves generation 2 only; the existing foreground
server still serves generation 1 with one attachment in its process. The
residency limits are server-enforced ceilings advertised at initialize under
the existing `limits` member. Removing the daemon leaves the foreground server
unchanged; existing embedded callers retain their behavior, and the core
supports independent same-session and same-holder attachments. The new index
is a bounded daemon discoverability file only: no journal record, Store port,
session event or snapshot depends on it. Foreground rollback ignores it, while
an M5 daemon validates and reuses it. A legacy root is upgraded explicitly by
the marker-protected offline import; there is no reverse migration.

Acceptance binds this complete pair at the exact candidate the maintainer
names in the governance record. Its evidence and compatibility claims remain
unproved until the tests the M5 plan maps to outcomes 2 and 4 exist and pass.
