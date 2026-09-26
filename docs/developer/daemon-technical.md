# The Daemon — Technical Depth

<a id="technical-depth"></a>
## Technical depth

Concept: [The daemon](daemon.md#concept).

This companion names the processes, the orders they follow, the fixed clocks,
where each bound lives and which tests hold each claim. The operator-facing
grammar, limits table, stop-bound formula and exit statuses are stated once in
the [operator page](../operator/daemon.md#technical-depth) and are not repeated
here.

<a id="technical-daemon-processes"></a>
## Processes

Concept: [A host, not a surface over a host](daemon.md#concept-daemon-host-role).

| Process | Module | Owns |
| --- | --- | --- |
| Command sentinel | `LoopexDaemon.Sentinel`, `LoopexDaemon.StartupArbiter` | Signal routing, readiness arbitration, opening the parked listener, the exit status |
| Service owner | `LoopexDaemon.Service` | Every resource of one lifetime, acquired in order and released in reverse, the Store last |
| Collaboration owner | `LoopexDaemon.Owner` | Starts and links the relay and registry, binds their incarnation, creates one `LeaseOwner` per controlled session, orders relay barriers |
| Admission relay | `LoopexDaemon.AdmissionRelay` | One ticket per post-initialize request from origin to disposition; lease-operation permits; barrier phases; retirement queries |
| Connection registry | `LoopexDaemon.ConnectionRegistry` | The 512-slot inventory from accept to reaped owner, attachment and lease mirrors, encoded output accounting, succession reserve, progress routing, idle and aggregate eviction |
| Lease owner | `LoopexDaemon.LeaseOwner` | One session's controller lease, writer epoch, renewal, release and takeover eligibility |
| Listener | `LoopexDaemon.Listener`, `LoopexDaemon.ListenerSocket` | The bound socket; accepts only after the startup gate; charges each accept to the registry before peer verification |
| Connection | `LoopexDaemon.SocketConnection` with `ConnectionProtocol`, `Request`, `RequestLedger`, `OutputBuffer` | One client: framing, initialize, request admission, correlated replies, bounded output |
| Request worker | `LoopexDaemon.RequestWorker` | One admitted request's blocking facade call, away from the connection process |
| Attachment pump | `LoopexDaemon.AttachmentPump` | Pulls one attachment's next durable event only when the connection has room |
| Session index | `LoopexDaemon.SessionIndex` with `.Codec`, `.Storage` | The bounded durable discoverability image |

No daemon process is registered by name; every reference is explicit and
bound to the lifetime's incarnation. The daemon reaches sessions through
`Loopex.Runtime`, including host entries hidden from generated documentation —
`create_session_detailed/3`, `resume_session_detailed/3`, `attach_for_holder/4`,
`command_for_daemon/2`, `release_holder/2`, and `quiesce/1` — and never through a
coordinator or the Store directly.

<a id="technical-daemon-leases"></a>
## Leases and Writer Epochs

Concept: [Controller authority lives outside the journal](daemon.md#concept-daemon-authority).

`LoopexDaemon.LeaseOwner` serializes controller authority for one session. It
grants at most one connection at a time, and each grant carries a fresh 128-bit
opaque writer epoch. The lease term is 30 s on the daemon's monotonic clock; the
holder renews by sending `session.acquire_control` again (the command does so
every ten seconds), and an accepted mutation also renews it. Every mutation of
an existing session must carry the current epoch. A client asking while the
lease is held receives `control_held` or `control_pending` and asks again; the
lease passes only on release or lapse. At most 512 sessions have a lease owner
at once; beyond that an acquisition answers `control_capacity_reached`. A lease
owner that
overruns a step is replaced and its controller closed with
`control_owner_lost`. Holder-changing grants, expiry, and release are proposals
the collaboration owner acknowledges before any epoch becomes visible. The
lease is never written to the journal, so a restarted daemon begins with none.

<a id="technical-daemon-startup"></a>
## Startup Order

Concept: [One order in, the reverse order out](daemon.md#concept-daemon-lifecycle).

`Service` acquires nothing in `init/1`. It waits up to `owner_start_gate_ms`
(5 s) for the sentinel's exact `{:go, owner_ref, sentinel}`, then runs each step
behind a checkpoint that honours an already queued `SIGTERM` or linked exit and
proves every started component alive:

| Step | Failure class |
| --- | --- |
| Placement lock | `placement_active`, `placement_unverifiable`, `placement_lock_failed` |
| Credential plane (custody and registry) | `credential_plane_start_failed` |
| Composition edges through `LoopexComposition.start_edges/2` | `composition_start_failed`, or the Store marker classes |
| Session index open | `session_index_*` |
| Collaboration owner | `daemon_services_start_failed` |
| Socket bind and permission read-back | `socket_*` |
| Parked listener | `listener_start_failed` |

A raised, thrown or exited step is classified by the step it interrupted, never
by the raw term. The owner then submits the readiness line; the sentinel writes
it, and only after the owner rechecks every component does the sentinel open
the listener.

<a id="technical-daemon-stop"></a>
## Orderly Stop

Concept: [One order in, the reverse order out](daemon.md#concept-daemon-lifecycle).

| Phase | Clock | On a missed acknowledgement |
| --- | --- | --- |
| Admission cut and transport gate; the listener killed and its exact exit awaited; uninitialized connections reaped | one absolute `transport_cut_deadline_ms` 5 s, begun before the relay cut | `relay_lost` for the relay acknowledgement, `connections_lost` for the registry gate or sweep, `listener_lost` for the listener's exit; the collaboration owner decides at the deadline and the service waits `@verdict_margin_ms` 1 s more only for a failure verdict, treating none as `relay_lost`; a success counts only by the deadline. The owner asks the registry by message, never blocking, so an earlier component exit keeps its class, and a relay or registry that missed the deadline is killed at that instant |
| Admitted requests reach core | `admission_wait_ms` 5 s | continues |
| `freeze_lease_ops`: no new lease operation; executing rows finish | `relay_control_timeout_ms` 5 s | `connections_lost` when registry mirror work is unfinished; otherwise `relay_lost`. No holder close remains here: one in progress at the cut is killed at the transport-cut deadline |
| `quiescing` | a fresh 5 s | `relay_lost` |
| `Loopex.Runtime.quiesce/1`, in an unlinked helper while the owner keeps consuming component exits | core's own clocks | `drain_failed` when the runtime is unavailable; a component lost meanwhile ends the stop with its own class |
| `seal_after_quiesce`, one `daemon.stopping` per connection, `tearing_down` | one shared `teardown_ms` 30 s | `relay_lost` |
| Collaboration, runtime and edges stop in reverse; Store last | what remains of the shared `teardown_ms`; the Store its own 30 s; a component killed at its deadline is awaited for up to a further 5 s | the component's class (`runtime_lost` for the runtime, `store_lost` for the Store) |
| Placement release | 5 s | — |

While serving, each lease-operation step — a registry apply, pop or clear; a relay selection, settlement or owner-loss classification; a lease owner's resolution; a holder's close — has its own 5 s instant from when its request is sent. A late registry step is `connections_lost` and kills the registry; a late relay step is `relay_lost`; a late lease owner is killed and superseded, its session going through the ordinary owner-loss path; a late holder is killed and its monitored `DOWN` completes the close. Consuming the admission cut cancels every step instant; a holder close already sent is re-bound to the transport-cut deadline, and a relay-unanswered report is cleanup-only from then on.

A fail-stop sends `daemon.stopping` naming `fatal:<class>` — or the bare
`store_lost` or `store_capacity_exceeded` for the Store — within 5 s and ends
within 35 s of the first fatal. The owner monitors the runtime's exact Control
and EventDispatcher, so losing either — even one the runtime's supervisor
restarts — is `runtime_lost`; and before an orderly stop reports success it
checks for any owned component lost while the stop ran, so a stop never exits
zero after one. `teardown_ms` was measured at 119 ms for 512
initialized, attached connections on the development machine; the closure
evidence records the measurement on each supported toolchain.

<a id="technical-daemon-connection"></a>
## One Connection's Life

Concept: [Nothing admitted is forgotten](daemon.md#concept-daemon-accounting).

1. The listener accepts and charges a registry slot before anything else.
2. `PeerCredential` decodes `SO_PEERCRED` on Linux or `LOCAL_PEERCRED` on
   Darwin and closes the socket unless the uid is the daemon's; an unreadable,
   short or undecodable credential fails closed.
3. The registry records socket ownership and transfers the socket to the
   connection process; until then the child is inert.
4. `initialize` must arrive within 30 s and must offer `loopex.experimental/2`.
5. Each request is admitted by a relay ticket, run by a worker, and answered
   exactly once through the ledger.
6. On close the slot moves to retiring and is freed only when the relay reports
   the connection retired, cleanup is acknowledged and the cleanup worker is
   reaped.

<a id="technical-daemon-output"></a>
## Output and Progress

Concept: [Durable first, transient behind it](daemon.md#concept-daemon-delivery).

Output is complete encoded frames only. The per-connection allowance is 4 MiB,
of which `SuccessionCapacity` reserves the exact bytes of one maximal
`detached` notice and one maximal correlated reply, derived from every legal
reply shape. Past the ordinary allowance a client is detached at its last
completely emitted cursor. The aggregate allowance is 512 MiB; before refusing
a write the registry reclaims other connections, unattached first and then
attached, largest buffer first; a reclaimed attached connection writes `detached` at
its last emitted cursor, best effort, and closes.

Core delivers progress to `{:session, pid}` sinks as
`{:loopex_progress, session_id, item}`. `Service` forwards it to the registry,
which routes it to every connection attached to that session. Each connection
keeps at most 32 progress records and 512 KiB, written only when no durable
output is waiting; excess progress is dropped.

An attached connection idle for `idle_eviction_ms` (10 minutes) is evicted with
`detached`; a connection holding a live lease is exempt while it holds it. The
daemon keeps no resident window of encoded events: every delivery is encoded
from the runtime's stream.

<a id="technical-daemon-succession"></a>
## Succession

When core invalidates an attachment because its session changed owner, the
connection receives `loopex_attachment_invalidated`, writes `detached` through
the reserved slot, clears its local attachment and keeps its lease, epoch and
deadline. The connection stays open.

<a id="technical-daemon-credential"></a>
## Credential

Concept: [The credential is read once](daemon.md#concept-daemon-credential).

`loopex daemon` reads `LOOPEX_PROVIDER_API_KEY` at command entry, before it
parses its arguments, and deletes it from the environment
(`LoopexCli.Daemon.credential/1`); the offline commands read it through
`LoopexComposition.CredentialHost` instead.
`Service` deletes the value from its own options once custody holds it, and the
git and `ps` children the host starts run with the variable removed. Custody
and the registry answer unknown calls with `{:error, :unavailable}` and ignore
unknown messages, so no crash report carries the value. A second composition
in the same VM returns `provider_credential_required` without starting anything.

<a id="technical-daemon-index"></a>
## The Session Index

Concept: [Discovery is not existence](daemon.md#concept-daemon-discovery).

`LoopexDaemon.SessionIndex` is one unregistered process that holds the root's
index rows in memory and replaces the complete durable image on each
publication, through `SessionIndex.Codec` and `SessionIndex.Storage`. It holds
at most 4,096 rows, keyed by raw session identity, and `session.list` pages
through them at most 256 at a time; a full index still answers truthfully and
reports `index_full`. A fresh root gets a persisted empty image. A root with a
session directory but no image is refused at start as
`session_index_upgrade_required` until `loopex daemon prepare-index`
(`LoopexDaemon.PrepareIndex`) imports every recorded session strictly, refusing
the whole root if any entry is damaged. A row that cannot be written leaves the
session as it is and sends `daemon.notice` with `index_write_failed` to the
client that caused it.

<a id="technical-daemon-evidence"></a>
## Evidence

| Claim | Tests |
| --- | --- |
| Startup order, checkpoints, reverse cleanup | `service_lifecycle_test.exs`, `startup_arbiter_test.exs`, `readiness_test.exs` |
| Relay tickets, barriers, retirement | `admission_relay_test.exs`, `owner_test.exs`, `collaboration_test.exs` |
| Slots, retirement barrier, eviction, reclamation, succession | `connection_registry_test.exs`, `succession_capacity_test.exs`, `wire_records_test.exs`, `output_buffer_test.exs` |
| Leases and takeover | `lease_owner_test.exs`, `lease_lifecycle_test.exs` |
| Non-blocking components: per-step clocks, lease-owner replacement, the monitored holder close, held requests, the stop rule | `owner_test.exs`, `lease_owner_test.exs`, `socket_transport_test.exs` |
| No blocking call between components through `:gen.call/4` while serving or stopping (T14); an orderly stop exits 0 with a lease owner's relay request unanswered past a step between the cut and the freeze (T21's owner and Service halves) | `service_lifecycle_test.exs` |
| Socket, peer credential, framing and methods | `listener_test.exs`, `listener_socket_test.exs`, `peer_credential_test.exs`, `connection_protocol_test.exs`, `request_test.exs`, `request_ledger_test.exs`, `socket_transport_test.exs` |
| Index and import | `session_index*_test.exs`, `prepare_index_test.exs` |
| Credential custody | `credential_custody_test.exs` here and in the app server and CLI |
| Progress and workflow | `external_socket_workflow_test.exs` |
| Cross-process CLI workflow | `apps/loopex_cli/test/multi_client_workflow_test.exs` |

Release-only lanes, excluded by the daemon's `test_helper.exs`:

| Tag | Case | Run by |
| --- | --- | --- |
| `real_provider` | `external_socket_workflow_real_test.exs` | the release manifest, its own process |
| `node_client` | `external_socket_workflow_test.exs` Node cases | `--only node_client` |
| `long_bound` | `maximum_population_test.exs` | `--only long_bound` |
| `cross_uid` | `cross_uid_test.exs`, two cases | Linux only, exactly two executed |

## Related

- [The daemon](daemon.md#concept).
- [Operator guide, technical depth](../operator/daemon.md#technical-depth).
- [Developer documentation](README.md).
