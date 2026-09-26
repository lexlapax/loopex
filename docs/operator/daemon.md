# The Daemon

<a id="concept"></a>
## Concept

Technical depth: [Grammar, wire, limits, stop bound and exit statuses](#technical-depth).

`loopex daemon` keeps one state root's sessions alive between commands. Where an
offline `loopex run` composes a runtime for itself and stops it when the command
ends, a daemon composes one runtime, listens on a Unix-domain socket inside the
state root, and lets separate client processes create, drive, observe, take over
and list its sessions. Every client is a peer: the `loopex` command's live forms,
the Node client in `clients/node`, or any program that speaks the generation-2
session protocol over that socket. None of them owns a loop or durable session
truth; the daemon's runtime does, and the journal is the record.

The daemon is the host. It alone chooses the workspace, the provider launch, the
host policy and the credential, when it starts; a client can never name any of
them. What a client gets instead is a lease: one controller at a time may change
a session, under a writer epoch the daemon granted, while any number of
observers watch.

What you can do:

- run one daemon per state root in the foreground, under a terminal or a
  service manager;
- import a state root that offline commands have already written;
- start sessions, follow them, and take control of one whose controller died;
- list sessions and read the daemon's status as JSON;
- stop it in an orderly way and read its exit status.

Constraints:

- One daemon per state root. While it runs, offline commands against that root
  refuse, and the daemon refuses to start while an offline command holds it.
- Darwin and Linux only. The socket is created with mode `0600`, and every
  connection must come from the daemon's own operating-system user.
- The daemon is experimental like every other Loopex surface. The offline
  commands on [Coding sessions](coding-sessions.md#concept) keep working
  unchanged against a root no daemon holds.

A first run through a daemon is part of [getting started](getting-started.md#operator-start-daemon).

<a id="operator-daemon-running"></a>
## Running a Daemon

Build the command as [Coding sessions](coding-sessions.md#operator-sessions-running)
describes, then start one daemon per state root. Start it through the
`bin/loopex` launcher so that Ctrl-C in its terminal becomes an orderly stop.

```text
export LOOPEX_PROVIDER_API_KEY=...        # read once, then removed
loopex daemon --state-root ~/.loopex --workspace ~/code/my-project \
              --provider-launch ~/src/loopex/_build/prod/loopex_provider.launch \
              --policy allow-all
```

`--provider-launch` names the non-secret launch file the command build writes
under `_build/prod`. Each input has one source: a present flag wins over its
environment variable (`LOOPEX_HOME`, `LOOPEX_WORKSPACE`, `LOOPEX_PROVIDER_LAUNCH`,
`LOOPEX_POLICY`), an empty flag never falls back, and none of them has a
default. The credential comes only from `LOOPEX_PROVIDER_API_KEY`; the daemon
reads it once into private custody and deletes it from its own environment.
`--cleanup-grace-ms` sets the cleanup period for the sessions it starts, and
`--socket` chooses a socket path inside `ROOT/daemon/`.

Every missing or invalid input is refused with its own exit status before the
daemon takes a lock, a Store marker or a socket, so a refused start leaves
nothing behind. If the workspace has an `AGENTS.md` at its root, the daemon asks
whether to admit it before it starts listening, and that decision applies to the
sessions it runs; see
[project resources are your decision](coding-sessions.md#operator-sessions-project-trust).

When it is ready the daemon writes exactly one line to standard output and
nothing else there:

```text
{"record":"daemon_ready","root":"/home/me/.loopex","socket":"/home/me/.loopex/daemon/daemon.sock","incarnation":"…","version":"0.2.0"}
```

Logs go to standard error at `info` level, so a running daemon's standard error
carries only warnings, failures and its stop lines. A second daemon on the same
root loses at the placement lock and exits `placement_active` (76) without
touching the first.

<a id="operator-daemon-migration"></a>
## Importing an Existing Root

A state root that offline commands have written — including one written by the
`0.1.0` release — has a session directory but no daemon index, and the daemon
refuses to start on it with `session_index_upgrade_required` (85). Import it once,
while nothing else holds the root:

```text
loopex daemon prepare-index --state-root ~/.loopex
```

The import takes the same placement lock and Store marker a daemon would, reads
every recorded session strictly, and publishes the daemon's index as the union
of any existing index and those sessions. Unlike `loopex sessions`, which skips
an entry it cannot read, the import refuses the whole root when any entry is
damaged (`session_index_corrupt`, 84) and leaves any earlier index exactly as it
was. It reports the number of sessions recorded on standard error and exits `0`.
A `SIGTERM` during the import stops it with `prepare_index_interrupted` (110)
after releasing the root. Running it again is harmless.

Offline commands do not update the daemon's index. A session an offline
`loopex run` creates after the import is not listed by `sessions --daemon` until
you stop the daemon and run `prepare-index` again.

<a id="operator-daemon-driving"></a>
## Driving a Session

```text
loopex run --daemon ~/.loopex/daemon/daemon.sock "add a changelog entry"
loopex resume --daemon ~/.loopex/daemon/daemon.sock s_…
```

`run --daemon` creates a session, prints `loopex: session <id>` on standard
error, takes control of it, attaches, sends the prompt, and streams the run to
its end exactly as the offline command does. It accepts `--steer` or
`--follow-up` alongside the prompt. It takes no `--policy`, `--state-root`,
`--workspace`, `--skill` or other host flag: those are refused as unrecognised,
because the daemon owns them.

`resume --daemon` reaches an existing session. If this daemon already runs it,
the command attaches and follows; if the session is dormant in this daemon's
lifetime, the command resumes it first. If the session's coordinator has died,
the command says so (`session_unavailable`); restart the daemon and run
`resume --daemon` again.

<a id="operator-daemon-listing"></a>
## Listing and Status

```text
loopex sessions --daemon ~/.loopex/daemon/daemon.sock [--limit 20] [--after s_…]
loopex sessions --daemon ~/.loopex/daemon/daemon.sock --status
```

Both print exactly one compact JSON object and a newline, keys in a fixed order,
so a script can read them. A listing looks like:

```text
{"sessions":[{"session_id":"s_…","placement_identity":"…","residency":"active","controlled":false}],"next_after_session_id":null,"index_full":false}
```

`residency` is `active` for a session this daemon has activated since it
started and `dormant` otherwise; `controlled` says whether a client holds its
lease. Pass `next_after_session_id` back as `--after` for the next page.

The status object carries, in order: `placement_identity`,
`daemon_incarnation`, `socket_path`, `connections`, `connection_limit`,
`attachments`, `attachment_limit`, `active_sessions`, `activation_limit`,
`activations_used`, `index_entries`, `index_limit`, `index_full` and
`uptime_ms`. Compare `activations_used` with `activation_limit` and
`index_entries` with `index_limit` to see how close the daemon is to the
[limits](#operator-daemon-limits). When the index is full, either command also
writes a warning to standard error; the printed object is still true.

<a id="operator-daemon-attaching"></a>
## Observing and Taking Over

```text
loopex attach s_… --daemon ~/.loopex/daemon/daemon.sock            # observe
loopex attach s_… --daemon … --take-over [--prompt "one more thing"]
```

An observer follows the session's durable events from the beginning, or
strictly after `--after <sequence>`, and never sends anything. `--take-over`
waits for the current controller to release or for its lease to lapse — it
never forces a live holder off — then takes control and, with `--prompt`, sends
one prompt. Attaching to a session this daemon has not activated is refused as
dormant in either role; `resume --daemon` is the command that activates.

A controller keeps its lease by renewing it every ten seconds against a
thirty-second term. If a renewal is refused, the command says so and keeps
following as an observer. When it ends it releases the lease if its connection
is still writable; a killed client sends nothing, and its lease lapses at the end
of its term, which is when a waiting `--take-over` gets control.

<a id="operator-daemon-recovery"></a>
## When the Connection Drops

A live command that loses its connection reconnects every quarter of a second
for up to thirty-five seconds from the first loss. It picks up after the last
event it showed, takes control again with a fresh epoch where it was
controlling, and re-sends a command whose answer was lost with the same command
identity, so the daemon applies it once. An answer the daemon itself cannot
settle (`admission_unknown`) ends the command non-zero, naming the unresolved
command. A lost `sessions --daemon` query is asked again within ten seconds.
When the daemon itself is stopping, the command is told and ends; it does not
reconnect.

<a id="operator-daemon-signals"></a>
## Signals and Stopping

A signal detaches a live command; it never stops the daemon's work. `SIGTERM`,
`SIGHUP`, `SIGQUIT` and a terminal Ctrl-C through the launcher make `run`,
`resume` and `attach --take-over` release their lease (waiting at most five
seconds), print `loopex: detached; the session continues in the daemon`, and
exit `0`; an observer closes and exits `0`; `sessions --daemon` exits `130`.
`SIGKILL` sends nothing, and the lease lapses at the end of its term.

The daemon handles `SIGTERM` as an orderly stop; started through `bin/loopex`,
a Ctrl-C, `SIGHUP` or `SIGQUIT` to the launcher is forwarded as `SIGTERM`. It
refuses new work, lets admitted work reach the runtime, drains its sessions,
tells every client `daemon.stopping` with `operator_stop`, stops its components
with the Store last, releases the root, and exits `0`. If a component is lost
while it stops — the Store, or the runtime's own processes — the stop ends with
that component's exit status instead, never `0`.

Let it finish. The worst case is the [stop bound](#operator-daemon-stop-bound);
a service manager whose stop timeout is shorter forces the stop, after which the
next daemon recovers the root.

During an orderly stop the daemon writes, on standard error:

- a `daemon_stop` JSON record once the runtime's quiesce succeeds. It records
  the drain, not the stop's outcome: `drain_id`; `budget_ms`, the cancellation
  budget derived from the sessions' committed cleanup periods;
  `fence_budget_ms`, the fixed 130,000 ms outer bound on fencing; the
  `settled`, `unsettled` and `absent` session counts; and for each session whose
  drain outcome is unknown, its stage and session ID, plus `owner_epoch` and
  `journal_version` when a head was read (a `no_head` session has none);
- `loopex daemon fatal: <class>` when a failure latches a class. A teardown that
  fails after quiesce attempts both lines.

Both lines are attempted and never awaited, from separate writers, so their
order is not guaranteed and either can be missing: a blocked standard error
never delays the stop, and a halt can cut a line short. The exit status is
authoritative.

<a id="technical-depth"></a>
## Technical depth

Concept: [The daemon](#concept).
Developer companion: [The daemon for developers](../developer/daemon-technical.md#technical-depth).

### Grammar

```text
loopex daemon [--state-root DIR] [--workspace DIR] [--provider-launch PATH]
              [--policy NAME] [--cleanup-grace-ms MS] [--socket PATH]
loopex daemon prepare-index [--state-root DIR]
loopex run --daemon SOCKET [--steer TEXT | --follow-up TEXT] PROMPT
loopex resume --daemon SOCKET SESSION
loopex sessions --daemon SOCKET [--limit 1..256] [--after SESSION]
loopex sessions --daemon SOCKET --status
loopex attach SESSION --daemon SOCKET [--observe | --take-over [--prompt TEXT]]
              [--after SEQUENCE]
```

Every value flag takes one nonempty value in `--flag value` or `--flag=value`
form and may appear once; `--` ends options. A live-form refusal opens no
socket. `--status` cannot be combined with `--limit` or `--after`, `--prompt`
requires `--take-over`, and `--observe` and `--take-over` exclude each other.
State-root and socket bytes must be valid UTF-8, checked before any effect. The
socket defaults to `ROOT/daemon/daemon.sock` and must stay under that directory
and within the platform's `sun_path` bound (103 bytes on Darwin, 107 on Linux).
Policies are `allow-all` and `shell-allowlist`.

### Wire

The socket speaks generation `loopex.experimental/2`: one compact JSON object per
LF, the generation-1 framing, initialize handshake, admission, snapshot, event,
progress and artifact-transfer records, plus `session.list`, `daemon.status`,
`session.acquire_control`, `session.release_control`, a `writer_epoch` on every
change to an existing session, and the `daemon.stopping` and `daemon.notice`
records. A client offering only generation 1 is refused at initialize. The
[protocol reference](../developer/app-server-protocol-technical.md#technical-depth)
specifies both generations.

<a id="operator-daemon-limits"></a>
### Limits

| Limit | Value |
| --- | --- |
| Accepted connections | 512, including ones still initializing and closing |
| Initialize deadline | 30 s from accept |
| Attachments | 64 per session, 512 per daemon |
| Output buffered per connection | 4 MiB; a slow client is detached at its last emitted cursor |
| Aggregate buffered output | 512 MiB; other clients' buffers are reclaimed, unattached first, before a new write is refused, and a reclaimed attached client is told `detached` at its last cursor before its connection closes |
| Transient progress queued per connection | 32 records and 512 KiB, written only behind durable output |
| Idle observer eviction | 10 minutes; a lease holder is exempt while it holds its lease |
| Lease term / renewal | 30 s / every 10 s |
| Activations per daemon lifetime | 64; restart the daemon to activate more |
| Index entries per root | 4,096; `session.list` page 256 |

The daemon keeps no resident window of encoded events: every delivery is encoded
from the runtime's stream.

<a id="operator-daemon-stop-bound"></a>
### Stop bound

An orderly stop is bounded by, in milliseconds:

```text
5_000 + admission_wait_ms + 5_000 + 5_000 + 70_000 + budget_ms(root)
      + 10_000 + 330_000 + 130_000 + teardown_ms + 30_000 + 5_000
```

— the transport cut, the admission wait, the lease-operation freeze and quiescing
relay barriers, the runtime's quiesce admission, the root's cancellation budget,
the status census, coordinator termination and fencing, the teardown, the Store
stop and the placement release. `admission_wait_ms` is 5 s and `teardown_ms` is
30 s. For comparison, an orderly stop of a daemon holding 512 initialized,
attached connections measured 119 ms on a development machine.

The transport cut is one 5 s deadline for refusing new work, closing the
listener and closing clients that never initialized; whatever misses it ends the
stop as `relay_lost`, `connections_lost` or `listener_lost`, decided at the
deadline and latched within a further 1 s. A cut counts only if it completes by
the deadline, so the bound holds. A relay that misses a later barrier ends the
stop as `relay_lost`, except that registry work unfinished at the lease-operation
freeze ends it as `connections_lost`; a component lost while the runtime's
quiesce runs, or before success is reported, ends it with that component's
class. A controller connection still closing after its session's lease owner was
lost is killed at the transport-cut deadline; that client sees end of file and
the stop continues.

While the daemon serves, each step of a lease operation has its own 5 s budget.
A step the registry overruns ends the daemon as `connections_lost`, and one the
relay overruns as `relay_lost`. A session's lease owner that overruns its step is
replaced, and that session's controller is closed with `control_owner_lost`. A
controller connection that does not close within 5 s of being told its lease
owner was lost is killed: that client sees end of file and the daemon keeps
serving. Each step's 5 s starts when that step begins, so a slow relay that
answers each step in time never ends the daemon. Once the stop begins no step has
a budget of its own: the stop's deadlines decide, and a report that a relay
request went unanswered is then ignored rather than ending the stop as
`relay_lost`.

Losing the runtime's Control or EventDispatcher, even one its supervisor
restarts, is `runtime_lost`, except that Control lost while quiesce is running
and the runtime itself still lives is `drain_failed`: the drain can no longer
report which sessions it stopped. Every component the teardown stops shares the
one `teardown_ms` deadline, and the Store then has its own 30 s; a component
still running at its deadline is killed, its exit is awaited for up to a further
5 s, and the stop ends with that component's class. A placement release that
fails or does not finish in 5 s is `placement_lock_failed`, never `0`. A fatal
class ends the process within 35 s of the first fatal.

### Exit statuses

| Status | Class | Meaning |
| --- | --- | --- |
| 0 | — | Orderly stop, or a successful import |
| 1 | — | Command-line refusal; the usage text goes to standard error |
| 65–75 | `state_root_required`, `state_root_unusable`, `workspace_required`, `workspace_unusable`, `provider_launch_required`, `provider_launch_invalid`, `policy_required`, `policy_unknown`, `provider_credential_required`, `project_skills_unusable`, `cleanup_grace_invalid` | A missing or invalid start input, before any effect |
| 76–78 | `placement_active`, `placement_unverifiable`, `placement_lock_failed` | The root's placement lock |
| 79–82 | `store_writer_active`, `store_writer_unverifiable`, `store_writer_acquisition_failed`, `store_log_too_large` | The root's Store marker and log |
| 83–86 | `session_index_too_large`, `session_index_corrupt`, `session_index_upgrade_required`, `session_index_write_failed` | The daemon index; 85 means run `prepare-index` |
| 87–89 | `socket_path_too_long`, `socket_permission_unverified`, `invalid_socket_path` | The socket |
| 90–95 | `signal_install_failed`, `credential_plane_start_failed`, `composition_start_failed`, `daemon_services_start_failed`, `listener_start_failed`, `readiness_write_failed` | Startup components |
| 96–109 | `store_capacity_exceeded`, `store_lost`, `transfers_lost`, `workspace_lease_lost`, `executor_lost`, `registry_lost`, `custody_lost`, `capability_lost`, `runtime_lost`, `relay_lost`, `connections_lost`, `listener_lost`, `drain_failed`, `owner_lost` | A running component failed and the daemon fail-stopped |
| 110 | `prepare_index_interrupted` | The import was stopped |
| 111 | `session_index_lost` | The running daemon's session index failed and the daemon fail-stopped |

Each class occupies its own status, in the order listed. A refused start writes
`loopex daemon refused to start: <class>` to standard error.

## Related

- [Getting started](getting-started.md) — a first daemon run after a first offline session.
- [Coding sessions](coding-sessions.md#concept) — the offline commands.
- [How a run works](how-a-run-works.md#concept-run-daemon) — what changes for one run when a daemon holds the root.
- [The daemon for developers](../developer/daemon.md#concept) — its processes, orders and evidence.
- [App server operations](app-server.md#concept) — the generation-1 foreground server.
- [ADR 0031](../adr/0031-daemon-grade-store-selection-and-migration.md#concept),
  [ADR 0032](../adr/0032-daemon-attachment-residency-and-replay.md#concept),
  [ADR 0033](../adr/0033-collaboration-controller-lease-and-takeover.md#concept)
  and [ADR 0034](../adr/0034-provider-credential-handoff-over-bootstrap-channel.md#concept).
- [Operator documentation index](README.md).
