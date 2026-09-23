# The Daemon

<a id="concept"></a>
## Concept

Technical depth: [Grammar, records, limits and exit classes](#technical-depth).

`loopex daemon` keeps one state root's sessions alive between commands. Where
`loopex run` composes a runtime for itself and stops it when the command ends,
a daemon composes one runtime, listens on a Unix-domain socket inside the state
root, and lets separate client processes create, drive, observe, take over and
list its sessions. Every client is a peer: the reference CLI, the Node client in
`clients/node`, or any program that speaks the generation-2 session protocol
over that socket. None of them owns a loop or durable session truth; the daemon's
runtime does, and the journal is the record.

The daemon is the host. It alone chooses the workspace, the provider launch, the
host policy and the credential, when it starts. A client can never name any of
them, so a connection cannot replace host authority. What a client gets instead
is a lease: one controller at a time may mutate a session, under a writer epoch
the daemon granted, while any number of observers watch.

This is a working source-tree surface, experimental like every other Loopex
surface. See [Coding sessions](coding-sessions.md#concept) for the offline
commands, which keep working unchanged against a root no daemon holds.

<a id="operator-daemon-running"></a>
## Running a Daemon

Build the command as [Coding sessions](coding-sessions.md#operator-sessions-running)
describes, then start one daemon per state root:

```text
export LOOPEX_PROVIDER_API_KEY=...        # read once, then removed
loopex daemon --state-root ~/.loopex --workspace ~/code/my-project \
              --provider-launch _build/prod/loopex_provider.launch \
              --policy allow-all
```

Each input has one source: a present flag wins over its environment variable
(`LOOPEX_HOME`, `LOOPEX_WORKSPACE`, `LOOPEX_PROVIDER_LAUNCH`, `LOOPEX_POLICY`),
an empty flag never falls back, and there is no default for any of them. The
credential comes only from `LOOPEX_PROVIDER_API_KEY`; the daemon reads it once
into private custody and deletes it from its own environment. Every missing or
invalid input is refused with its own exit status before the daemon takes a
lock, a Store marker or a socket, so a refused start leaves nothing behind.

When it is ready the daemon writes exactly one line to standard output and
nothing else there:

```text
{"record":"daemon_ready","root":"/home/me/.loopex","socket":"/home/me/.loopex/daemon/daemon.sock","incarnation":"…","version":"0.2.0"}
```

Logs go to standard error. A second daemon on the same root loses at the
placement lock and exits `placement_active` (76) without touching the first.

<a id="operator-daemon-migration"></a>
## Moving a Released Root to the Daemon

A root that `0.1.0` or earlier commands wrote has a session directory but no
daemon index, and the daemon refuses to start on it
(`session_index_upgrade_required`, 85). Import it once, while nothing else holds
the root:

```text
loopex daemon prepare-index --state-root ~/.loopex
```

The import takes the same placement lock and Store marker a daemon would, reads
every recorded session strictly, and publishes the daemon's index. Unlike
`loopex sessions`, which skips an entry it cannot read, the import refuses the
whole root when any entry is damaged (`session_index_corrupt`, 84) and leaves
any earlier index exactly as it was. It prints the number of sessions recorded
on standard error and exits `0`. A `SIGTERM` during the import stops it with
`prepare_index_interrupted` (110) after releasing the root. Running it again is
harmless.

<a id="operator-daemon-driving"></a>
## Driving a Session

```text
loopex run --daemon ~/.loopex/daemon/daemon.sock "add a changelog entry"
loopex resume --daemon ~/.loopex/daemon/daemon.sock s_…
```

`run --daemon` creates a session, takes control of it, attaches, sends the
prompt, and streams the run to its end exactly as the offline command does,
including `--steer` or `--follow-up`. It takes no `--policy`, `--state-root`,
`--workspace`, `--skill` or other host flag: they are refused as unrecognised,
because the daemon owns them.

`resume --daemon` reaches an existing session. If this daemon already runs it,
the command attaches and follows; if the session is dormant in this daemon's
lifetime, it resumes it first. If the session's coordinator has died, the
command says so (`session_unavailable`); restart the daemon and run
`resume --daemon` again.

<a id="operator-daemon-listing"></a>
## Listing and Status

```text
loopex sessions --daemon ~/.loopex/daemon/daemon.sock [--limit 20] [--after s_…]
loopex sessions --daemon ~/.loopex/daemon/daemon.sock --status
```

Both print exactly one compact JSON object and a newline, keys in a fixed order,
so a script can read them:

```text
{"sessions":[{"session_id":"s_…","placement_identity":"…","residency":"active","controlled":false}],"next_after_session_id":null,"index_full":false}
```

`residency` is `active` for a session this daemon has activated since it
started and `dormant` otherwise. Pass `next_after_session_id` back as `--after`
for the next page. When the daemon's index is full a warning goes to standard
error; the page itself is still true.

<a id="operator-daemon-attaching"></a>
## Observing and Taking Over

```text
loopex attach s_… --daemon ~/.loopex/daemon/daemon.sock            # observe
loopex attach s_… --daemon … --take-over [--prompt "one more thing"]
```

An observer follows the session's durable events from the beginning, or
strictly after `--after <sequence>`, and never sends anything. `--take-over`
waits for the current controller to release or for its lease to lapse — it never
forces a live holder off — then takes control and, with `--prompt`, sends one
command. Attaching to a session this daemon has not activated is refused as
dormant in either role; `resume --daemon` is the command that activates.

A controller keeps its lease by renewing it every ten seconds against a
thirty-second term. If a renewal is refused the command says so and keeps
following as an observer. When it ends it releases the lease whenever its
connection is still writable; a killed client sends nothing, and its lease lapses
at the end of its term.

<a id="operator-daemon-recovery"></a>
## When the Connection Drops

A live command that loses its connection reconnects every quarter of a second
for up to thirty-five seconds from the first loss. It picks up at the last event
it showed, takes control again with a fresh epoch where it was controlling, and
re-sends a command whose answer was lost with the same command identity, so the
daemon applies it once. An answer the daemon itself cannot settle
(`admission_unknown`) ends the command non-zero naming the command that is
unresolved. A lost `sessions --daemon` query is asked once more within ten
seconds. When the daemon itself is stopping, the command is told and ends; it
does not reconnect.

<a id="operator-daemon-signals"></a>
## Signals

A signal detaches a live command; it never stops the daemon's work. `SIGTERM`,
`SIGHUP`, `SIGQUIT` and a terminal `Ctrl-C` through the launcher make `run`,
`resume` and `attach --take-over` release their lease (waiting at most five
seconds) and exit `0` while the session continues in the daemon; an observer
closes and exits `0`; `sessions --daemon` exits `130`. `SIGKILL` sends nothing.

The daemon handles `SIGTERM` as an orderly stop: it refuses new work, lets
admitted work reach core, drains its sessions through core, tells every client
`daemon.stopping` with `operator_stop`, stops its components with the Store last,
releases the root, and exits `0`. Allow it to finish; a service manager timeout
shorter than the bound below forces a stop, after which the next daemon recovers
the root.

<a id="technical-depth"></a>
## Technical depth

Concept: [The daemon](#concept).

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
form and may appear once; `--` ends options. A live-form refusal opens no socket.
State-root and socket bytes must be valid UTF-8, checked before any effect. The
socket defaults to `ROOT/daemon/daemon.sock` and must stay under that directory
and within the platform's `sun_path` bound (103 bytes on Darwin, 107 on Linux).
Policies are `allow-all` and `shell-allowlist`.

### Wire

The socket speaks generation `loopex.experimental/2`: one compact JSON object per
LF, the generation-1 framing, initialize handshake, admission, snapshot, event
and progress records, plus `session.list`, `daemon.status`,
`session.acquire_control`, `session.release_control`, a `writer_epoch` on every
mutation of an existing session, and the `daemon.stopping` and `daemon.notice`
records. A client offering only generation 1 is refused at initialize.

### Limits

| Limit | Value |
| --- | --- |
| Accepted connections | 512, including ones still initializing and closing |
| Initialize deadline | 30 s from accept |
| Attachments | 64 per session, 512 per daemon |
| Output buffered per connection | 4 MiB, a slow client detached at its last emitted cursor |
| Aggregate buffered output | 512 MiB; other clients' buffers are reclaimed, unattached first, before a new write is refused |
| Transient progress queued per connection | 32 records and 512 KiB, written only behind durable output |
| Idle observer eviction | 10 minutes; a lease holder is exempt while it holds its lease |
| Lease term / renewal | 30 s / every 10 s |
| Activations per daemon lifetime | 64; restart the daemon to activate more |
| Index entries per root | 4,096; `session.list` page 256 |

M5 keeps no resident window of encoded events: every delivery is encoded from
the runtime's stream.

### Stop bound

An orderly stop is bounded by, in milliseconds:

```text
5_000 + admission_wait_ms + 5_000 + 5_000 + 70_000 + budget_ms(root)
      + 10_000 + 330_000 + 130_000 + teardown_ms + 30_000 + 5_000
```

— the transport cut, the admission wait, the lease-operation freeze and quiescing
relay barriers, core's quiesce admission, the root's cancellation budget, status
census, coordinator termination and fencing, the teardown, the Store stop and
the placement release. `admission_wait_ms` defaults to 5 s and `teardown_ms` is
provisionally 30 s until the closure run records its measured value. A relay that
misses a barrier ends the stop as `relay_lost`; a fatal class ends within 35 s of
the first fatal.

### Exit statuses

| Status | Class | Meaning |
| --- | --- | --- |
| 0 | — | Orderly stop, or a successful import |
| 1 | — | Command-line refusal |
| 65–75 | `state_root_required` … `cleanup_grace_invalid` | A missing or invalid start input, before any effect |
| 76–78 | `placement_active`, `placement_unverifiable`, `placement_lock_failed` | The root's placement lock |
| 79–82 | `store_writer_active`, `store_writer_unverifiable`, `store_writer_acquisition_failed`, `store_log_too_large` | The root's Store marker and log |
| 83–86 | `session_index_too_large`, `session_index_corrupt`, `session_index_upgrade_required`, `session_index_write_failed` | The daemon index; 85 means run `prepare-index` |
| 87–89 | `socket_path_too_long`, `socket_permission_unverified`, `invalid_socket_path` | The socket |
| 90–95 | `signal_install_failed` … `readiness_write_failed` | Startup components |
| 96–109 | `store_capacity_exceeded` … `owner_lost` | A running component failed and the daemon fail-stopped |
| 110 | `prepare_index_interrupted` | The import was stopped |

## Related

- [Coding sessions](coding-sessions.md#concept) — the offline commands.
- [App server operations](app-server.md#concept) — the generation-1 stdio server.
- [ADR 0032](../adr/0032-daemon-attachment-residency-and-replay.md#concept),
  [ADR 0033](../adr/0033-collaboration-controller-lease-and-takeover.md#concept)
  and [ADR 0034](../adr/0034-provider-credential-handoff-over-bootstrap-channel.md#concept).
- [Operator documentation](README.md).
