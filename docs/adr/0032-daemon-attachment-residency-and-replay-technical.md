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
are the one exception**, and they are reused with one addition rather than
unchanged: every existing-session mutation in generation 2 carries
`writer_epoch`. That is the addition, and it is the reason generation 2 needs
a schema digest of its own.

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
hold as many connections as the residency limits admit.

**An attachment never outlives the process that attached it, and M5 is what
makes that true.** The mechanism is a monitor, not a detach call. Today the
dispatcher monitors the attaching process only while its snapshot scan is in
flight and **demonitors it the moment the scan finishes**
(`event_dispatcher.ex:455`), after which nothing watches that process at all
and the installed attachment records neither its pid nor a monitor
(`:764-803`);
`disconnect/2` marks an attachment disconnected and empties its queue but
leaves the entry in place (`:879-886`); and the one path that actually removes
an entry is same-session **supersession** (`:812-823`) — which M5's
concurrent-attachment change removes, because coexisting attachments are the
point.

**And there is a third place the change has to reach, which two reviews of
this pair missed: `Control` is single-attachment too.** The dispatcher is not
the only component holding attachment state. `Control`'s session entry has one
`attachment` field, `finish_attach/5` **overwrites** it on every successful
attach (`control.ex:1273-1283`), the command path validates against that one
field (`:343`, `current_attachment?/3` at `:1649-1657`, answering
`{:error, :stale_attachment}` for anything else), and `attachment_repetition/4`
keeps its repetition state for that same single attachment (`:1312-1314`).

So with only the dispatcher changed, two coexisting attachments would still
break the session at `Control`: an observer attaching after a controller
overwrites the controller's slot, and the controller's **next command** fails
— the daemon's central case, failing on the component nobody had looked at.

**Core change 1 therefore includes `Control`'s attachment and repetition
state, keyed by a stable holder identity.** That identity is the **holder
pid** — the connection process the dispatcher already monitors for the release
half of this change — so the two components key on the same thing and a
`DOWN` drops the entry in both. `Control` keeps one attachment *per holder*
per session rather than one per session, validates a command against the
holder's own attachment, and keeps repetition state per holder. Nothing about
the single-attachment-per-connection rule changes: one holder still has one
attachment, which is why the key is the holder and not the attachment id.

Its witness is the case that fails today: a controller attaches, an observer
attaches to the same session, and **both remain usable** — the controller's
next command is admitted and the observer keeps receiving.

So that change has three parts and this pair states all of them: supersession
stops removing attachments **unconditionally**, **the dispatcher keeps its
monitor after install and
removes the attachment on that process's `DOWN`**, and **`Control` scopes its
attachment and repetition state by holder**. Without the second half M5
would leave core with no release path at all, and every attachment ever made
would live until the runtime stopped.

**The `DOWN` removal must release the attachment's transfers, and saying so is
not optional.** The supersession block is the **sole** caller of
`release_transfers/2` — the call is at `event_dispatcher.ex:817`, inside the
block at `:812-818`, and the function is defined at `:1105` with no other call
site in the module. Removing the block without moving that call would leave
accepted **ADR 0028** unsatisfied, its technical companion requiring that
"detaching releases every transfer the attachment opened"
(`0028-…-technical.md:28-30`). So the dispatcher's `DOWN` handler calls
`release_transfers/2` for the attachment it drops, and the conditional
replacement path below calls it for the attachment it supersedes. ADR 0028 is
thereby satisfied on both of the two paths that end an attachment, where today
it is satisfied on one; its witness is a case in
`apps/loopex/test/concurrent_attachments_test.exs` asserting that an
attachment with an open transfer, released by its process exiting, leaves no
transfer behind.

**And supersession becomes conditional rather than disappearing, because
today it *is* the implementation of `replace`.** That took checking rather
than assuming, and the answer is not what ADR 0032 said. ADR 0023 puts an
optional `replace` boolean on `session.attach`
(`0023-…-technical.md:165`) and requires that a second attach refuse "unless
it names explicit replacement, which detaches the first at its last completely
emitted cursor" (`:359`). **Core never sees that flag.** The app server reads
it (`mapping.ex:162`, `:458`) and uses it for one thing only — whether a
connection already holding an attachment may open a second
(`attachable/3`, `:466-470`) — and then builds core's options without it
(`attach_options/1`, `:450-456`); `Control.validate_attach_options/1` would
refuse it anyway, its `Keyword.validate/2` defaults naming only
`after_event_sequence`, `request_id`, `client_id` and `attachment_key`
(`control.ex:1293-1310`). What actually replaces the attachment is core's
**unconditional same-session** block, which reads no flag and supersedes
*every* attachment of that session.

So the change is stated as what it is: **the same-session supersession becomes
conditional on `replace`, and narrows its scope to the attaching process's own
prior attachment** for that session. Core's attach options gain `replace`, the
app server passes the flag it already parses, and the block fires only when it
is set.

**That scope needs an identity the installed attachment does not carry today,
and core change 1 adds it.** `install_attachment/3` builds the attachment map
from the scan's result — `id`, `incarnation_id`, `session_id`, cursors, queue,
capacity, status, metadata, transfers (`event_dispatcher.ex:764-803`) — and
**no attacher pid**; the supersession that follows splits `state.attachments`
on `session_id` alone (`:812-818`); and the monitor the dispatcher held during
the scan is **demonitored the moment the scan finishes** (`:455`). There is
therefore nothing on an installed attachment that says which process attached
it, so "the attaching process's own prior attachment" is not a set anything
could compute.

Core change 1 therefore **retains the attacher's pid and its monitor reference
on the installed attachment**. That is not a third half: the change already
has to keep the monitor rather than dropping it at `:455`, because the `DOWN`
release is the whole of the second half — and a `DOWN` carries the monitor
reference and the pid, which is exactly what the handler needs to find the
attachment to drop. Holding both on the attachment makes the `DOWN` lookup a
map lookup rather than a scan, and makes the replacement scope a filter on a
field that exists. One addition, two uses.

**A pid on an attachment crosses no boundary the vision fences.** The rule is
about durable and public or executor contracts; the dispatcher's
`state.attachments` is neither — it is runtime-local process state, exactly as
the `caller_monitor` it already holds on a pending scan is
(`event_dispatcher.ex:186-192`). Nothing about the attachment's pid is
journaled, sent on the wire, put in a snapshot or handed to an executor, and
the snapshot and `attached` records a client receives are unchanged.

- **Generation 1 is behaviour-identical**, which is what ADR 0023 requires and
  what this milestone promises for the foreground server: that host maps one
  connection to one attachment, so its supersession only ever fired behind a
  `replace: true` the app server had already admitted, and narrowing the scope
  to the attaching process changes nothing where there is one attacher.
- **Generation 2 needs both halves of the change.** Without the condition, a
  daemon's second connection would detach the first — the thing concurrent
  attachment exists to stop. Without the narrowed scope, a `replace: true`
  from one connection would detach *every other connection's* attachment to
  that session, which is worse.
- **ADR 0023 stays unamended.** Its `replace` field is unchanged, its rule
  that a second attachment refuses unless replacement is named is unchanged,
  and what the foreground server does is unchanged. What changes is on which
  side of the boundary the flag is honoured: the app server keeps its
  connection-level check and now also passes the flag through, and core stops
  superseding without being told to. No wire field moves, so no digest input
  moves either.
- **"The named prior incarnation" is corrected.** An earlier revision of this
  pair said explicit replacement "invalidates only the named prior
  incarnation at its last emitted cursor". There is no name on the wire —
  `replace` is a boolean — so what it invalidates is the attaching process's
  own prior attachment for that session, at its last completely emitted
  cursor, with `release_transfers/2` called for it.

For the daemon this needs no API: it attaches from its **per-connection
process**, so a connection that closes — because the client went away, because
the daemon is stopping, or because the daemon gave up on a request that never
answered — ends that process, and the `DOWN` releases the attachment. That is
what makes a connection a sufficient handle on an attachment, and it is why a
daemon needs no attachment count from core to release what it reserved.

An explicit `detach/1` on **core's** public API was the alternative and is
rejected:
it would add a call every caller must remember on every exit path, including
the paths where the caller is already gone, which is exactly the case a
monitor handles for free. That rejection is about the core API and about a
*caller* detaching itself. It is not a rule against the daemon ending an
attachment — the daemon does that four ways, listed with `control_owner_lost`
below, and every one of them is a record written to that connection and then
the close of that connection, which is the same monitor-driven release read
from the other side: the connection process ends, and its `DOWN` releases the
attachment with no call at all.

The core EventDispatcher and Control retain multiple live attachment IDs and
incarnations for one session. A new distinct attachment does not implicitly
detach another session attachment or cancel its pending read. Repetition of
the same attachment request returns its live attachment; explicit replacement
— `replace: true` — invalidates the attaching process's own prior attachment
for that session at its last completely emitted cursor, and releases its
transfers.
Snapshot barriers, queued durable delivery, stale-handle checks and detach
remain core operations. The daemon neither copies the snapshot into a second
fan-out owner nor reads coordinator state to repair an attachment race.

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
- `active_sessions` is `|activation set|` alone — sessions with a coordinator
  now, which is a different question and is why the two fields both exist;
- `attachments` counts installed attachments plus reserved attachment slots,
  for the same reason `activations_used` does;
- `connections` counts accepted connections, reservation-free by nature.

So `activations_used` may exceed `active_sessions` for as long as a call is in
flight, and settles to it. Reporting the set alone would advertise headroom
the very next call would refuse.

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
| | `retry_after_ms` | `u64` | present **only** for `operator_stop` |
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
| `control_not_held` | `session.release_control` from a non-holder, **and every lease-authorized existing-session mutation whose combined admission gate fails** — any of the **five** conditions ADR 0033 lists: wrong connection, wrong epoch, a lease that is not `held`, a deadline already passed, or an attachment without controller capability. A request missing `writer_epoch` altogether is `invalid_request` instead, being malformed before the gate | **Nothing**, deliberately: the five conditions are indistinguishable on the wire, because saying which one failed would make the refusal an epoch and lease oracle. ADR 0033 fixes the gate; this is the one answer it has |
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

**A connection is pinned to one session, and both paths pin it.** The first
`session.attach` or `session.acquire_control` a connection completes fixes
which session that connection is about; every later call on it naming a
different session is refused with the existing invalid-argument reason, and
the daemon's per-connection state is keyed by that one session rather than by
whatever the last frame said. Without the rule a connection could hold a lease
on one session and an attachment on another, and `control_owner_lost` — whose
close ends *the connection* — would take down an attachment belonging to a
session that had nothing to do with the lost owner.

**`control_owner_lost` therefore carries `event_cursor` exactly when there was
an attachment to carry one for.** A connection that acquired and never
attached has no emitted cursor, and inventing one would be a lie about what it
received; the field is **absent** in that case and present otherwise, which
is an optional-field rule the DTO tables already have vocabulary for. Both
shapes are generation-2 vectors — one with the cursor, one without — because a
client parsing the record has to know that absence is legal.

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
about a connection hangs from. The `initialize`-time refusal below still
exists for the case a slot was free at accept and the handshake is what fails.

**The refusal is ADR 0023's, not a new one.** A connection accepted beyond the
ceiling is answered, at its `initialize`, with a correlated
**`capacity_exceeded`** — which generation 1 already carries, so generation
2's ordered error list gains nothing for it — and then closed. It is answered
at `initialize` rather than refused at `accept` because a peer that is never
answered cannot tell a full daemon from a wedged one, and because ADR 0023
already fixes what a refused `initialize` means: the connection remains
uninitialized and gets no second negotiation attempt
(`0023-…-technical.md:357-358`). The peer-credential and filesystem checks
still run first; a foreign peer is closed before any of this. Its witness is a
boundary pair: the 512th connection initializes and is served, the 513th is
refused `capacity_exceeded` and closed, and closing one of the 512 lets the
next through.

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
| `reason` | One of `operator_stop`, `store_lost`, `store_capacity_exceeded`, or `fatal:<class>` for the remaining classes the plan's fatal-class map names, one per linked component: `fatal:runtime_lost`, `fatal:transfers_lost`, `fatal:workspace_lease_lost`, `fatal:executor_lost`, `fatal:registry_lost`, `fatal:custody_lost`, `fatal:capability_lost`, `fatal:relay_lost`, `fatal:listener_lost` — nine in a daemon with artifact transfers and eight without, one per linked component of the fixed set. A lease owner's death is not among them: it closes one session's controller connection with `control_owner_lost` and ends no daemon. The startup classes carry no reason, because no socket exists when they occur, and neither does `owner_lost`, where the process that would write it is the one that is gone |
| `message` | A bounded non-secret sentence for an operator to read |
| `retry_after_ms` | Present only for `operator_stop`, where a restart is expected; absent for every fatal reason, because the daemon does not know when the cause will be fixed |

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
| **Error codes** | Adds every refusal generation 2 can return and generation 1 cannot: `control_held`, `control_not_held`, `control_pending`, `control_capacity_reached`, `control_owner_lost`, `session_dormant`, `daemon_stopping`, the four existence-query refusals the daemon maps to the wire (`session_unknown`, `session_id_invalid`, `store_unavailable`, `existence_indeterminate`), and the activation and residency refusals (`activation_ceiling_reached`, `composition_mismatch`). **Not** `session_index_too_large`, which is a startup exit class and can reach no client, and **not** `capacity_exceeded`, which generation 1 already carries and generation 2 reuses for the connection ceiling |
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
connection, epoch, `held` state, unexpired deadline or controller-capable
attachment. One code for all of them, carrying nothing beyond the envelope:
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
| `code` | `control_owner_lost` |
| `session_id` | the session whose lease owner died |
| `event_cursor` | the last completely emitted durable cursor for that attachment, exactly as `detached` carries it |

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
| The controller's lease owner died | `error`, `control_owner_lost`, with `session_id` and `event_cursor` | close that connection |
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

**`event_cursor` is the same quantity in all four**: the **last completely
emitted durable cursor** for that attachment — the highest event sequence the
daemon finished writing to that socket, never one it had only encoded or
buffered. That is the position the client reconnects at, and delivery from it
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

**`daemon_stopping`, the refusal after the admission cut.** An orderly stop
begins with a synchronous, acknowledged cut: the daemon's owner calls the
admission relay, the relay closes admissions and answers only once every
ticket it holds has **settled** — not merely been recorded, a recorded ticket
being a call still running — and nothing enters core through
the daemon after that answer. A connection that is still open — and every
connection is, because the cut precedes the closes — may still send a frame.
**Every** method is refused after it, whatever it would have done — the eight
lease-authorized mutations, `session.create`, `session.attach`, the queries,
and ADR 0023's three artifact-transfer methods alike — because the refusal is
about the daemon's state rather than about the request's effect. It is
answered with a **correlated** `daemon_stopping` carrying that request's
`request_id` and nothing else: no `event_cursor`, no session state, and it
closes nothing on its own. The connection is closed a moment later by step 3
of the stop sequence, which is where a client is told the reason it is going
away; `daemon_stopping` answers the one request that arrived in between.

The instant it names is the relay's acknowledgement, not the signal: a command
whose relay ticket was recorded **before** the acknowledgement has settled by
the time it returns, and one that arrives after it is refused. Those are
the two witnesses, and they must give different answers on the same surface —
the connection's own reply stream.

**`session_index_too_large` is not a wire code**, and an earlier revision
listed it as one. It is a **startup** refusal: the daemon exits non-zero with
that class before any socket exists, so no client can be holding a connection
to be told. It is removed from the generation-2 error inventory and stays in
the daemon's exit classes, where it belongs.

**A failed directory write is a notification, not an error.** Generation 2
adds a **second notification record family**, `daemon.notice`, beside
`daemon.stopping`:

| Field | Value |
| --- | --- |
| `code` | one of a closed set, today `index_write_failed` |
| `session_id` | the session the notice is about |
| `message` | a bounded non-secret sentence for an operator |

The activation it follows **succeeded**: the session is usable and reachable
by ID, and only its directory entry and index row are missing, to be written
by the retry the plan already describes. Reporting that as an `error` would
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

`session.list` reads a daemon-owned index, never the session directory or the
store on the request path. What the index *is* follows from what it is built
from. `Loopex.SessionDirectory` holds plain files beside the log and states
that neither is Store durable truth; a host records an entry after
`create_session/3` commits, and that write can fail on its own — the reference
CLI reports exactly that failure to the operator. So there is a real crash cut
between a committed session and its directory entry, and a daemon rebuilt from
the directory can be missing a session the Store holds.

The index therefore claims only what it can keep true, and each field is one
the daemon itself owns or reads once:

- `session_id` and the recorded placement identity, read from the directory
  entry at daemon start, or written when the daemon first activates a session
  the directory does not hold;
- `residency`, a daemon fact meaning *this daemon activated this session in
  this lifetime*, set to `active` at activation and never set back, because
  activation is one-way. It is not a claim about a live coordinator;
- `controlled`, a daemon fact, updated on every lease grant, release and
  expiry by the same lease owner ADR 0033 gives those transitions — **and on
  that owner's death**, which is a fourth way a lease stops being held and
  which an earlier revision left out. The daemon's owner process, which
  observes the exit, clears `controlled` for that session as it closes the
  controller attachment; a listing that still said `controlled: true` would be
  naming a holder that no longer exists.

**`residency` says what the daemon knows, not what core is doing.** Its two
values mean exactly:

- `active` — **this daemon activated this session during this lifetime**;
- `dormant` — it has not.

That is a daemon-owned fact, recorded by the daemon at the moment it acted,
and it is **true by construction**: nothing else has to hold for it to stay
accurate, and no other process has to tell the daemon anything.

An earlier draft defined `active` as "the daemon holds a live coordinator",
which is a claim about core's state that the daemon has no way to keep
current, and then paid for it with a rule that took the whole daemon down when
a coordinator died. Both are withdrawn. The reason the first was untenable is
in the code: a coordinator is a `restart: :temporary` child of core's
`DynamicSupervisor`, and when one goes down `Loopex.Runtime.Control` consumes
the `DOWN`, releases the dispatcher fence and returns without altering the
session entry. No notification leaves core, and none is owed — that is core
minding its own supervision.

**So a dead coordinator is surfaced by core's own refusal, not by the index.**
A client that sends the next command for that session gets core's existing
refusal, and the daemon forwards it unchanged, adding nothing and interpreting
nothing. The client learns at the moment it matters, from the component that
knows, and the listing never claimed otherwise: `residency: active` said this
daemon activated the session, which remains true. The activation ceiling still
counts activations per daemon lifetime, for the same reason — it counts what
the daemon did.

Two alternatives were rejected, and both would be **a further core change**
beyond the five this milestone makes. A lifecycle notification from core to the daemon
would be a new core-to-host signal, with its own delivery and ordering
questions, added for a listing field. A monitorable coordinator handle handed
out to the daemon would export core's supervision topology across the boundary
and invite the daemon to reason about it. M5's core changes stay at five, and
neither of these is among them.

ADR 0033's lease-owner rule is untouched by this and stays — and it is a
**session-scoped** rule, not a fatal one; this sentence said "fatal" from the
revision before that decision was taken. The
difference is ownership: a lease owner is a **daemon** process holding
daemon-only state that nothing can reconstruct, so losing it is the daemon's
failure to handle; a coordinator is core's, supervised by core, and its loss
is core's to report.

Lineage, lifecycle state and last committed sequence are deliberately absent.
A daemon index cannot keep them current without reading the Store on the
request path or subscribing to every session it is not holding, and a field
that is silently stale is worse than an absent one; a client that needs them
attaches, and the snapshot carries them at a committed sequence.

**The recovery procedure for the crash cut**, in four parts, needing no new
durable record and no Store read by the daemon:

1. **Durable existence is learned from core, through a query that asks only
   that.** The daemon never reads Store internals and never enumerates the log
   to decide whether a session exists. It calls core's read-only
   session-existence query on the ID — no attach, no resume, no side effect,
   a plain-data answer — and treats core's answer as the proof.

   An earlier draft had the daemon learn existence from `attach` or `resume`
   themselves. The maintainer rejected that on 2026-09-20 and admitted the
   query instead. Asking a question by performing the operation is not a
   question: `attach` establishes a cursor barrier and an attachment
   incarnation, `resume` is a durable mutation under ADR 0008's placement
   rules, and a daemon that had to run one of them to discover that a session
   does not exist would be taking a side effect to learn a fact — worst of all
   at `acquire_control`, which must validate existence *before* granting a
   lease and must be safe to call on an ID that turns out to be unknown.

   **The query's result set is closed, and only one member is a yes.** "A
   plain-data answer" is not a contract on its own — a caller has to know what
   it may receive and what each result obliges it to do, especially a caller
   about to grant authority on the strength of it. The query answers exactly
   one of:

   | Result | Means | What the daemon does |
   | --- | --- | --- |
   | `present` | The root holds this session durably | Proceed: acquire may be granted, activation may follow |
   | `absent` | The root does not hold it, and core is certain of that | Refuse, naming the session as unknown |
   | `invalid_id` | The argument is not a well-formed session identifier | Refuse as an invalid argument, before anything is looked up |
   | `store_unavailable` | Core could not read the root to decide | Refuse, naming the store as unavailable — **not** as an unknown session, because those are different facts and an operator acts on them differently |
   | `unexpected` | Anything else, including a result shape the daemon does not recognise | Refuse, the same way as `store_unavailable`, because an answer that cannot be interpreted is not a yes |

   **Control acquisition proceeds only on `present`.** Every other result
   fails closed and identically in what it leaves behind: no attachment, no
   lease, no activation, no index row, nothing created. What differs is only
   what the client is told, and the client is always told which — a refusal
   that said "unknown session" when the store was unreadable would send an
   operator looking for a session that exists.

   Nothing about the index is consulted to decide existence, which is why an
   index that is incomplete is not a correctness problem, and the daemon still
   reads no Store internals.

   Each of the five results is a witness: `present` granting, `absent`,
   `invalid_id`, `store_unavailable` injected through the suite's controllable
   fault store rather than by making the root unreadable — `Loopex.Store.Local`
   answers `ownership_head` from memory, so an unreadable root does not produce
   that result —
   and `unexpected` injected by a stub that answers outside the set. All five
   assert the same absence afterwards — no attachment, no lease, no activation
   — and assert that the four refusals name distinct reasons.
2. **A client that never saw the session ID recovers by command identity, and
   the sequence is written out here rather than left as a gesture.** At the
   cut where the Store committed the creation and the process died before the
   reply, the client holds no session ID at all — only the `command_id` it
   chose for its own `session.create`. Every step below uses something the
   client already has or something already durable:

   | Step | Who acts | What happens |
   | --- | --- | --- |
   | 1 | Client | Reconnects to the daemon and re-presents `session.create` with **the same `command_id`** it used before. It knows no session ID, so it cannot ask for one |
   | 2 | Daemon | Forwards it as an ordinary create. It does not consult the index, which by construction may not hold this session |
   | 3 | Core | Recognises the command identity as already resolved and returns the **historical result** — the same session ID it committed before — rather than creating a second session. This is the command idempotency the resume path already relies on, not a new mechanism |
   | 4 | Client | Now holds the session ID for the first time. **No coordinator is running for it** — see below |
   | 5 | Daemon | Validates durable existence with the read-only existence query on that ID, which answers `present` because the Store committed it in the first place |
   | 6 | Daemon | Repairs what is missing: writes the directory entry and adds the index row, so every later `session.list` shows the session. If that write fails, step 3 of this procedure applies |
   | 7 | Client | Acquires control, receiving the writer epoch |
   | 8 | Client | Sends `session.resume` with a **fresh resume `command_id`** and that writer epoch. This is the step that activates the session: it is a new command, not a replay, because the create's identity is spent |
   | 9 | Daemon | Activates the session — a live coordinator now exists — and counts it against the activation ceiling |
   | 10 | Client | Attaches and drives |

   **Step 8 is the one an earlier draft left out, and without it the recovery
   ends with nothing running.** Replaying a completed create does not start a
   coordinator: `Loopex.Runtime.Control.create_session/4` resolves the
   transaction, sees the command was already resolved, and replies `{:ok,
   session_id}` on the `not fresh?` branch *without* calling `start_owner`.
   That is correct — a replay must not create a second owner — but it means
   steps 1 to 4 return an identity and nothing more. The session is durable
   and idle. `session.resume`, with its own fresh command identity and under
   the lease acquired at step 7, is what brings it back, and the sequence is
   only a recovery once it reaches there.

   Steps 5 and 6 turn the recovery into a repair: the session is not merely
   reachable once, it stops being missing. A client that *does* still hold the
   session ID skips steps 1 to 4 and enters at step 5.

   **Its witness.** One case injects the exact cut — Store commit of the
   create followed by process death before the directory write and before the
   reply — then, from a client that never received the session ID, replays
   `session.create` with the original `command_id` and runs the sequence to
   the end. It asserts: exactly one session exists in the root; the returned
   ID equals the committed one; the replay itself started no coordinator; the
   existence query answers `present`; the directory entry and index row are
   present afterwards and the session appears in `session.list`; the resume
   under the granted epoch activates it, so a **live coordinator exists** and
   the activation count has risen by one; and a prompt sent afterwards lands
   on that session and produces its events, rather than on a second session or
   on nothing at all.
3. **Recording can fail, and says so.** If writing the directory entry fails
   during activation, the failure is reported to the client that triggered it,
   as an explicit warning that this session will not appear in `session.list`
   — the reference CLI already reports exactly that failure today. The
   activation itself succeeds, the session is fully usable, and the daemon
   **retries while it still holds the ID**, which is the only time it can:

   - immediately after activation, once;
   - on each later command for that session, since the daemon has the ID in
     hand at that moment anyway and the retry costs one file write it already
     knows how to make;
   - and when any later client reaches the session by ID, or replays its
     create command, since both paths put the ID back in the daemon's hands.

   The retry stops as soon as it succeeds. Two earlier answers were wrong and
   both are withdrawn. "At the next activation of that session" cannot happen:
   activation is one-way, so within a lifetime there is no second one. "At the
   next daemon start" cannot happen either, and for a sharper reason — a
   restarted daemon builds its index *from the directory*, so a session the
   directory does not hold is a session the new daemon has never heard of. It
   has no ID to retry with. Only a live daemon that still holds the ID can
   repair the gap, which is why the retry is bound to the moments it does.

   Until it succeeds, the session is reachable by ID and absent from
   `session.list`, which is exactly what the client was told.
4. **A full index still activates.** If the index already holds 4,096 entries
   and a client reaches an unrecorded session by ID, the session is activated
   and is **not** recorded. Reachability never depends on the ceiling. What
   changes is the listing's honesty: `session.list` then carries `index_full`,
   so an operator is told the listing is incomplete rather than reading a
   silent omission as an absence.

`session.list` is documented as *the sessions this root records*, not *the
sessions this root contains*, and the operator documentation states all four
parts, because an operator who lost a terminal mid-creation is exactly who
meets them.

A page is consistent with the index at the moment it is read, and no
consistency is promised across pages. What that can actually produce is
narrower than an earlier draft claimed, because the index is append-only
within a daemon's lifetime and keyed by unique session ID: rows are added,
never removed and never renumbered, and ordering is by session ID bytes. So a
session recorded between two page reads may be **missed** — if its ID sorts
before the cursor the client has already passed — and that is the only
anomaly paging can show. A row cannot vanish between pages and cannot be
returned twice, because nothing deletes a row and no two rows share an ID. A
client that needs a complete view pages again from the start; deduplication is
unnecessary here, though a client that deduplicates by session ID loses
nothing. A `limit` outside 1 to 256 or an `after_session_id` that is not
a well-formed session ID refuses with the existing invalid-argument reason; an
`after_session_id` naming an unknown session is admitted and pages from its
byte position.

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
plan should not pretend otherwise. It holds one index row against the
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
none of M5's six core changes (concurrent attachment, the read-only existence
query, the trace exclusion, `quiesce/1`, the `disposition` and
`control_entry` fields on the detailed create and resume functions, and the
bounded session listing) stops a coordinator,
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
- **Index bound.** The index holds at most 4,096 **recorded** entries. A root
  whose session directory holds more refuses at daemon start with a stable
  reason naming the bound and pointing at root retirement, in the same posture
  as `store_log_too_large`: refuse rather than serve a truncated view of what
  the root records. The ceiling is on recorded entries only, and it never
  makes a session unreachable — see the crash cut below.

  **Enforcing it needs a bounded read, and core does not have one.** The
  listing the daemon builds its index from is core's:
  `Loopex.list_sessions/1` (`loopex.ex:452-453`) calls
  `SessionDirectory.list_sessions/1` (`session_directory.ex:230-253`), which
  does `File.ls` and then reads **every** entry before sorting and returning.
  A root holding a hundred thousand entries is therefore read in full before
  the daemon can refuse at the four-thousand-and-ninety-seventh — a refusal
  whose point is to avoid exactly that cost. So this milestone adds one
  further narrow read to core and counts it: **`Loopex.list_sessions/2`
  taking a bound and stopping after the bound-plus-first valid entry**,
  answering what it read and whether it stopped early. It is read-only and
  additive — the arity-one form keeps its exact meaning and its callers — and
  it is the smallest thing that lets the bound be enforced rather than
  discovered.
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
- 64 attachments per session and 512 per daemon, refused at attach with a
  stable reason when exhausted;
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

Tests prove: two core attachments to one session keep independent live handles,
snapshots and cursors with no implicit replacement; an explicit `replace: true`
invalidates only the attaching process's own prior attachment for that session,
releasing its transfers, while every other connection's attachment to it
continues; an attachment released by its process exiting leaves no transfer
behind, which is accepted ADR 0028's requirement on the path that replaces the
only caller `release_transfers/2` has today; snapshot-then-contiguous at-least-once
delivery with no gap across the window boundary; the same delivery cases run
again with the resident window disabled, byte for byte identical, and with the
window dropped mid-stream, proving the cache establishes nothing; deterministic
reclamation in the fixed order above, including the case where zero-attachment
windows alone consume the aggregate ceiling and are released before any
attachment is detached; a slow observer detached at
its last emitted cursor — its `detached` record written best-effort and its
connection closed — while the controller and other attachments on their own
connections continue;
the per-session and per-daemon limits refusing independently; idle eviction, its close, and reconnect on a
fresh connection with no missing durable event and any duplicate deduplicated
by session ID, sequence and event ID; the three encoded-byte ceilings at maximum
attachment count and payload pressure enforced in the daemon-owned stages,
with process RSS observed and reported separately; a generation-1-only
initialize refused with `unsupported_generation` and nothing created;
simultaneous daemon starts on one root leaving exactly one listener with the
loser never touching the socket; Store-child failure closing the listener and
every connection before exit; `session.list` pages of at most 256 entries in
session-ID order with an exact continuation cursor, carrying only the four
fields above; a session committed to the Store whose directory entry was never
written — injected at exactly that cut — absent from the listing, still
reachable by ID, and present in every listing after the activation that
records it; a restarted daemon activating nothing until a client reaches for a
session; a detached long-running command and a pending admission each crossing
the idle deadline with every client gone and running to completion, so
dormancy is proved to release attachments and never a coordinator; the
activation ceiling refusing the 65th activation of a daemon lifetime with its
stable reason and restart remedy; a root whose directory holds more than the
recorded-entry bound refusing at start with its stable reason; at that bound a
session reached by ID activated, not recorded, and the listing carrying
`index_full`; a client that never saw a session ID recovering it through the
create command's durable `command_id`; a directory write failing at activation
reported to that client, the session still usable, and the record written by
the retry the next time the live daemon holds that ID — right after
activation, on a later command for the session, or when a client reaches it by
ID; a
recorded session the current composition cannot serve refused at activation by
name while every other session in the root activates; progress coalescing under
pressure with counted drops and no journal delay; peer-credential refusal; a
socket path beyond the bound refused at start; frame, fragment and
malformed-input refusals identical to the foreground server's.

### Alternatives

TCP on loopback was rejected for the local daemon: it has no peer-credential
check and invites remote exposure by misconfiguration; WebSocket and HTTP
remain later transports under vision §18.8. An unbounded per-attachment queue
was rejected because it lets one client grow coordinator-adjacent memory
without bound. Keeping the M4 one-attachment-per-process rule was rejected
because a daemon's clients are processes by definition. A daemon-owned proxy
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
above is the cost of keeping it.

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
supports independent same-session attachments. No durable record depends on
residency state or on the session index.

Acceptance binds this complete pair at the exact candidate the maintainer
names in the governance record. Its evidence and compatibility claims remain
unproved until the tests the M5 plan maps to outcomes 2 and 4 exist and pass.
