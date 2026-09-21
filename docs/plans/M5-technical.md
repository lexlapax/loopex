<a id="technical-depth"></a>
## Technical depth

Concept: [Durable service purpose and outcomes](M5.md#concept).

<a id="technical-plan-prerequisites"></a>
### Prerequisites and Acceptance Points

Concept: [Scope](M5.md#concept-plan-scope).

Concept: [Non-goals](M5.md#concept-plan-non-goals).

M5 waits on four decisions. Each is accepted before the implementation that
depends on it, not before unrelated work, and none may be outstanding at
closure.

**Acceptance binds a design and its evidence obligations, not the evidence
itself**, which is the only reading that is not circular. Each of these ADRs
lists tests that exist once the milestone implements it; requiring those
tests *before* acceptance would mean no decision could ever be accepted,
since implementation waits on acceptance. So acceptance means the maintainer
has read the design and the obligations it commits to, and those obligations —
renamed in all five proposals in this planning set, including deferred ADR
0035, to **implementation and milestone-closure
evidence** — are discharged at Outcome closure, where the exact-diff tests and
the security review belong. The repository status check reads the links in this section, so a
decision named only in prose declares nothing.

| Decision | Acceptance point | What its acceptance settles |
| --- | --- | --- |
| [ADR 0031](../adr/0031-daemon-grade-store-selection-and-migration.md#concept) | Before the daemon opens a state root, so before workstream 2 lands | The existing local adapter as the daemon's store for `0.2.0`, with the 256 MiB log capacity, 4 MiB frame ceiling, full retention, `store_capacity_exceeded` refusal, the capacity-as-store-loss consequence, the shared crash-reclaimable host placement lock preserving ADR 0008 across early Store-marker release, explicit stale-writer recovery and the operator root-retirement procedure documented; a daemon-grade adapter and its Store/journal-format migration left open for a separate decision, while ADR 0032 owns the daemon-index compatibility import |
| [ADR 0032](../adr/0032-daemon-attachment-residency-and-replay.md#concept) | Before the socket is bound or any of those core changes lands, so before workstreams 1 and 3 | The Unix-domain-socket transport reusing ADR 0023's framing, initialize handshake, admission, snapshot/event/progress records and existing input limits unchanged; generation 2 adds `writer_epoch` to its request records and adds its enumerated methods, records, errors and daemon/residency limits; inherited connection-local boolean replacement mapped to core's exact target, durable existence established by core's read-only query rather than by attaching or resuming, refusal of a generation-1-only client, owner-only peer access, the bounded socket path, placement-lock-then-marker startup, race-free multi-attachment holders with at-least-once contiguous delivery, the resident window, daemon-owned output buffers, detachment at the last emitted cursor, idle-observer eviction with controller-lease exemption, and a versioned bounded daemon index with explicit legacy import and bounded pages |
| [ADR 0033](../adr/0033-collaboration-controller-lease-and-takeover.md#concept) | Before any admission check is written, so before workstream 4 | One daemon-owned controller lease per session held in daemon memory with a fresh opaque writer epoch per grant, admission that binds holder connection, held state, unexpired term and epoch together, explicit takeover, cross-process abort through the core's own cancellation, and no authority from content, metadata or order |
| [ADR 0034](../adr/0034-provider-credential-handoff-over-bootstrap-channel.md#concept) | Before the adapter's credential resolution changes, so before workstream 5's credential item | The credential as an opaque token bound at composition beside the registry handle and **resolved per invocation**, routed by a host-owned registry that holds routing only, resolved from a host-owned custody process only inside a sender whose exact supervised argument is token-free. Managed setup registers an inert guardian with Core, obtains its authorization acknowledgement, then starts and adopts an inert sender and obtains its adoption-complete acknowledgement before initialize. Each supervised start requires the exact start-proxy result and exact child acknowledgement in either order, followed by proxy `DOWN`, before the next gate. The sender parks until exact provider readiness, then installs mandatory runtime-bound trace exclusion and a linked, sender-monitoring sink before it receives the token or channel context. Managed mode allocates one absolute invocation deadline before either supervised start, never resets it and, after registration, adoption and initialize, applies it to provider launch/readiness, sender release, exclusion, token routing, custody resolution and the credential-frame write. Every accepted completion and next release rechecks `now < deadline`; a queued completion consumed at or after the instant loses, and the timer only prompts that check. Direct mode has no Core gate and carries its request's same pre-launch absolute instant through inherited-session clearing, sink installation, routing, custody and frame write. Either expiry is `:timeout`, while lost custody, registry or capability is `:unavailable` with no reconstruction. No credential environment read occurs anywhere in the adapter's library tree, with `provider_bridge` reading none at all. ADR 0034 narrowly supersedes ADR 0019's environment-as-sender-source, ready-sender-resolution, raw-spawn and sole-guardian-ownership clauses for managed calls: managed guardian and token-free sender are direct temporary `owner_workers` children, while Direct mode retains the raw linked-and-monitored sender. It retains ADR 0019's provider child/Port/OS-guard/private-channel topology, launch-time enumeration and scrubbing, failure teardown and forensic disclaimer; the re-pointed credential-plane proofs and the security review are milestone-closure obligations |

ADR 0031 decides one thing, the `0.2.0` local-adapter selection and its
documented limits. It prescribes no successor engine, experiment or
Store/journal-format migration; those are named as open questions there and
settled by their own decision. ADR 0032 separately owns the daemon-index
compatibility import.

M4 owns interactions, transfers, the foreground server and observability. An
inherited defect is reproduced at the exact base and repaired at its owner; a
daemon workaround cannot conceal one.

<a id="technical-plan-ownership"></a>
### Ownership, Decision Owners, and Rejoin Barriers

Concept: [Scope](M5.md#concept-plan-scope).

| Component | Owns | Cannot own |
| --- | --- | --- |
| `loopex` | Durable session truth, the race-free attach barrier and cursor, independent concurrent attachments to one session **and their release — `Control` and the dispatcher each hold a holder-to-attachment-set keyed by attachment identity and own the monitor or explicit release notification they consume; one holder `DOWN` drops that holder's full set and its transfers; `replace_attachment_id` names the exact target and enters the request binding; and a narrow internal attach-for-holder call lets a relay task perform the attach while the connection pid remains the stable holder**, the read-only session-existence query, **`Loopex.Trace.exclude_self/2`, which installs both the match-specification exclusion ADR 0030 names and the process-level exclusion its callees need before any token is delivered, and the `Loopex.Trace.Entry` clause that redacts a keyword list's values under their own keys**, **the bounded, single-use `quiesce/1` that settles every active coordinator or returns `{:error, :runtime_unavailable}` — executing in one private monitored phase-owner process, not in `Control` or by changing its caller's flags, because `Control` is on every coordinator's commit path — whose first Control call installs a terminal create/resume/attach/ordinary-route gate and projects each entry's status, coordinator pid and owner; whose drain-specific coordinator call closes ordinary command admission before proposing the abort; whose drained abort pauses where cleanup would have begun and presents its commit once rather than retrying an ambiguous answer; whose later census is read-only under the same gate; and whose one-shot fence-mode `SessionCoordinator` becomes the sole serial writer for one abort-status recovery followed by one `advance_owner` and, if its result is ambiguous, one exact fence re-presentation after the ordinary coordinator is gone; no Store handle leaves core**, **`create_session_detailed/3` and `resume_session_detailed/3`, the two runtime-side functions carrying `disposition` and `control_entry` beside the unchanged create and resume**, the per-attachment event-count dispatcher queues, cancellation and recovery | A lease, a transport, a byte limit, residency policy or any daemon fact |
| `loopex_protocol` | The existing `LoopexProtocol.Session` generation-1 compatibility facade and the daemon-only `LoopexProtocol.Session.V2` contract, each with its own zero-arity metadata, negotiation, validators, schema and vectors | Daemon behaviour or lease semantics |
| `loopex_store_local` | The local adapter's unchanged durable format, private port shape and marker cleanup, its 256 MiB log and 4 MiB frame ceilings, its `store_capacity_exceeded` and `store_log_too_large` refusals, plus the missing retained-create read projection through existing `runtime_command/2`; that projection adds no durable byte, callback arity or result-union member — so the daemon owns the Store *process* and stops it last in an orderly shutdown, while host placement exclusion remains outside the adapter | Any daemon fact, lease, index or residency state |
| `loopex_daemon` | Placement-lock-then-marker process and socket lifetime, existence validation by calling core's query rather than by attaching or resuming, the peer-credential check, generation-2 negotiation, per-connection socket output buffers, the resident window and aggregate byte ceiling, attachment residency and eviction, the in-memory controller lease and writer-epoch check, the versioned durable daemon index with its file-size and recorded-entry bounds, offline legacy import and bounded pages, the one-way activation ceiling, and diagnostics | Store or coordinator internals, a second loop, policy selection, host identity, a journal record or a durable session method |
| `loopex_composition` | The edge-assembly sequence; the `LoopexComposition.Placement` crash-reclaimable host lock extracted from `LoopexCli.Placement` without changing its path, record or recovery protocol so the CLI and daemon use one mechanism; `LoopexComposition.ProjectResources`, extracted from `LoopexCli.ProjectResources` with its exact root-`AGENTS.md` discovery, containment, operator-presentation and fail-closed decision semantics so the foreground CLI and daemon use one host utility; and the one new public `LoopexComposition.start_edges/2` function that validates the existing host option set, runs in the caller's process, calls the caller's optional `interrupt` checkpoint before each edge, and returns `{:ok, edges}` or `{:error, reason, partial_edges}` with exactly the started keys and optional transfers absent rather than `nil` — used by `RuntimeOwner` and by the daemon's owner | Daemon lifetime, ownership of what it assembles, or any knowledge of a daemon |
| `loopex_app_server` | The foreground stdio server unchanged, sharing the protocol mapping the daemon reuses, and its use of `with_runtime/2`, which M5 does not change | Daemon lifetime or residency |
| `loopex_cli` | `loopex daemon` with its readiness line, signal handling and exit classes; `loopex attach` with its roles, takeover presentation and cursor reconnect; the live `run`, `resume` and `sessions` forms beside offline forms whose released grammar, session-driving semantics and output remain stable; migration from its private project-resource helper to the identical composition-owned utility; and Outcome 6's governed host-side credential custody and registry composition | Normative lease or session semantics, or any other change to released offline command behavior |
| `loopex_llm_reqllm` | The credential handoff, its sender, the token it accepts, the launcher's unchanged ADR 0019 scrubbing enumeration, the `req_llm` version floor, the re-pointed credential-plane proofs and the provider suite's concurrency | Any host credential policy, any new credential scope, where a host keeps the bytes behind a reference, or anything outside the adapter |
| `clients/node` | Socket connection, observer following and takeover presentation for the independent client | Normative semantics |

**Rejoin order.** Prerequisite decisions first. Then the new application with
its dependency-budget change, and the narrow core attachment change — the
first half of workstream 1, which the daemon's attach path needs before it can
be proved, and which is why workstream 1 is numbered first in the concept
pair. Then placement-lock-then-marker daemon lifetime and the socket over the local adapter,
workstreams 2 and 3, which may run together once the application exists. Then
the collaboration lease, workstream 4, on that base. Then the daemon-side
residency, replay and backpressure that sit above the core change, the second
half of workstream 1. Then the two-process workflow with the reference CLI and
the independent Node client. Then the documentation and the source-archive
proof, workstream 6, at the end because it describes what the others built.
Then independent review of the closure candidate.

Prove lifetime, refusal of a second daemon at the placement lock, shutdown on store
loss, capacity refusal, reopening under the foreground server after an orderly
stop, independent simultaneous core attachments, snapshot-then-contiguous
delivery, stale-epoch refusal, takeover and cross-process abort before the
client workflow rejoins.

Workstream 5, the credential handoff and the provider dependency, is
independent of the daemon's *semantics* and may land at any point after
ADR 0034 is accepted. It is not, however, file-disjoint from the daemon work,
and an earlier draft's claim that it shares no file with the other
workstreams would have set the rejoin up to fail. It owns `apps/loopex_llm_reqllm`
outright, but four surfaces are shared with the daemon workstreams and belong
to the integrator, who resolves them rather than either writer:

| Shared surface | Why both reach it |
| --- | --- |
| Host composition — `apps/loopex_composition`, `apps/loopex_app_server/lib/loopex_app_server/host.ex`, `apps/loopex_cli` | The credential item makes every host compose a routing registry and custody process, bind the token in model options, bind the mandatory tracing capability after runtime start, and delete the operator's variable; the daemon *is* a new host composed the same way, and `host.ex:221` is where the variable is read today |
| The integration scripts — `scripts/check-release.sh`, the M5-delivered `scripts/source-archive-manifest.sh`, and their fixtures | Workstream 5 replaces the shared real-provider application lanes with an eight-row fresh-BEAM manifest; the daemon workstreams add the daemon's real-provider, Node, long-bound, Linux cross-UID and fresh-archive manifest cases |
| Provider and credential documentation under `docs/operator/` and `docs/developer/` | Workstream 5 adds the operator credential sentence and the host-composition note; workstream 6 rewrites the same pages for the daemon |
| Closure evidence — `docs/evidence/M5-closure-runs.md` and `docs/evidence/README.md` | One page records every workstream run's identity, result, retained-output reference and digest, plus the corresponding references and digests for the security review and demonstration; complete outputs and reports remain outside the repository |

So workstream 5 takes its own worktree like every other writer, and the
integrator sequences those four surfaces. What is true without qualification
is narrower and worth stating on its own: workstream 5 touches no daemon
application code, and no daemon workstream touches the adapter's library
tree.

Parallel writers take one worktree each over these non-overlapping paths, and
one integrator owns rejoin, conflicts and post-rejoin verification, as the
[milestone guide](../developer/milestones-technical.md#technical-milestones-develop)
sets out.

**Semantics the rejoin must preserve.** Use the existing command identity for
every mutating method; request identities never enter journals.
`session.create` has no existing session or epoch to authorize: it creates an
uncontrolled session and grants nothing. Attach and acquire are independent
and their order is not fixed, as ADR 0033 settles it: the constraint is on the
first mutation, which is admitted only when the sending connection holds the
lease, its epoch matches and that connection holds a live attachment for the
pinned session. The single exception is `session.resume` on a verified dormant
session, which the holder may send before attaching. "Verified" means verified
by core's read-only existence query, not by having attached or resumed already:
acquire validates existence with that query and refuses an unknown ID with
nothing created. The lease record lives
in the daemon's memory, keyed by session, for as long as that session has a
lease or an acquisition; one owner process per session serializes its lease
transitions with its admission handoff, and that owner's failure is **scoped
to its session**. A granted holder is sent `control_owner_lost` and closed with
its attachment. Every other acquire or release claimed by owner loss, and every
pending or queued mutation claimed before promotion, receives the same code as
a correlated refusal and keeps its connection; a promoted mutation remains
relay-owned to its real result. A free or retiring owner with no claimed
operation has nobody to notify. Every observer stays. Successor start waits for
mirror pop, classification acknowledgement and terminal holder-close or
correlated-refusal settlement, while its first grant waits for predecessor
retirement completion and tickets before minting a fresh epoch. What keeps a successor's call from overtaking an older one is the
**admission relay**, a fixed daemon process that holds a ticket for the ten
core-call kinds that affect the drain, records the ticket and starts its
monitored task before acknowledging, and blocks the replacement's first grant
until that session's mutation ticket settles. ADR 0033 fixes both rules. For
every existing-session mutation the daemon checks the requesting connection
identity, the current epoch, the held state and the unexpired term together
before forwarding to core; an epoch alone is not authority, and every epoch is
minted fresh at grant so no earlier value can match. Attach reuses the
runtime's cursor transaction; core keeps attachments independent and keeps its
event-count queues, while the daemon buffers encoded output, evicts above its
own bounds and never reads coordinator state. Cross-process abort forwards the
existing durable `session.abort` command; no daemon-side cancellation path
exists.

<a id="technical-plan-evidence"></a>
### Evidence Obligations and Mapping

Concept: [Outcomes](M5.md#concept-plan-outcomes).

Concept: [Verification stages](M5.md#concept-plan-verification).

| Outcome | Witness | What must be proved, beyond ordinary unit tests |
| --- | --- | --- |
| 1 | `apps/loopex_daemon/test/session_lifetime_test.exs`, `apps/loopex_store_local/test/writer_lock_holder_test.exs` | A real daemon operating-system process per state root. The complete readiness output is compared byte for byte with compact JSON whose only fields are the ordered strings `record`, `root`, `socket`, `incarnation` and `version`, followed by exactly one LF and no other `stdout` byte. Short root and socket paths containing a quote, backslash, space, tab and newline prove ordinary JSON escaping and prove that an embedded newline creates no second record. The startup ordering and its readiness line: the bounded write is launched only after the placement lock and Store marker are held and the socket is bound, permission-checked and listening under a parked listener. The lifecycle sentinel serializes handled `SIGTERM`, helper result or deadline, the owner's exact component-fatal notice and its post-success clock-and-liveness-checked release authorization; only release authorization lets the sentinel send exact `begin_accept`. Forced orders prove stop, component fatal or readiness failure consumed first leaves the gate parked even when the completed line is already visible, while release first opens it and a later signal or component exit takes the running path. A client connecting before release is served only after that exact gate event. Killing the parked listener after its startup acknowledgement and ordering the owner's fatal notice before release authorization selects `listener_start_failed`, leaves the gate parked and creates no client or wire state, including when readiness success is already visible; the paired order in which the sentinel's exact send wins selects running `listener_lost`. Forcing the first accept operation to fail immediately after the exact `begin_accept` release selects `listener_lost` with no client; forcing a later accept failure while one initialized client remains attempts `fatal:listener_lost` to that client, and neither path selects startup-only `listener_start_failed`. Each of a held placement lock, a held Store marker, a failed socket permission check and an exceeded index bound releases no gate and exits non-zero with its own class. A forced `File.mkdir_p!/1` `File.Error` is caught by the total startup classifier and selects `placement_lock_failed`, never `owner_lost`. Killing the command process after owner `init/1` returns but before its exact `:go` proves the unlinked owner exits by `owner_start_gate_ms: 5_000` with no placement handle, Store pid, socket or child acquired; the startup-only gate clock never enters `T_orderly`. Post-exclusive-create WriterLock failures are forced separately: no Store pid is returned, a complete residual follows verified stale recovery, a partial residual refuses as unverifiable, and the daemon maps the originating failure to `store_writer_acquisition_failed` without touching the socket. The pre-handler root-resource prompt is held while each of launcher `INT`, `TERM`, `HUP` and `QUIT`, plus direct child `SIGTERM`, proves the default-termination cut: exact status `0`, no readiness, wire record, `daemon.stopping` record or lifecycle/fatal diagnostic, and no placement lock, Store, socket or component. After handler installation, direct `SIGHUP` proves abrupt status `129` with recoverable residuals and no orderly record, direct `SIGQUIT` proves a no-op while the daemon remains live and leaves the handler installed; orderly shutdown on a subsequent direct `SIGTERM` sent to the daemon, and on `SIGINT` sent to the launcher that forwards it as `SIGTERM`: the relay **admission cut** taken through one ref-tagged exchange, asynchronous in process mechanics and synchronous only in sequencing, that closes admissions and answers at once, followed by the registry's acknowledged `transport_closing(cut_ref)` gate, the listener's kill and exact reap, and EOF close plus reap of the complete marked provisional/uninitialized set, all within the one transport-cut deadline; a peer accepted in the interval between relay cut and registry gate may reserve a provisional slot but never initializes, while no reservation or promotion passes the registry gate. Then follows the owner's **bounded admission wait** in which only the frozen pre-cut origin rows may promote or settle — proved by distinct surface witnesses: a ticketed mutation admitted in the instant *before* the relay cut settles before the drain begins; `session.prompt`, `session.create`, `session.attach` and `artifact.read_chunk` presented on an already initialized connection after that cut each refuse `daemon_stopping` with nothing admitted and no journal record; and an accepted but uninitialized peer receives EOF without a protocol record; a pre-cut `artifact.read_chunk` whose waiting worker claims its permit and receives `go` before the cut is held across the admission-wait bound, remains `executing` through quiesce, then ends exactly once as `connection_lost` at the later connection/worker barrier and changes neither Control nor durable bytes; its paired worker held before the claim loses `shutdown_cancelled` at the deadline and is proved never to dispatch, while the same claimed read released inside the bound completes normally; killing its bounded request worker and, separately, closing its peer while a dispatcher read is held clears the exact connection-incarnation permit, kills remaining request workers and returns permit and attachment counts to baseline; a paused lease owner forced on both sides of pending-ticket promotion proves connection loss before promotion starts no task while promotion first keeps the accepted slot closing to the real result; 512 occupied incarnations with 32 active origins each hold the 513th peer out, never exceed 16,384 origins or tasks under reconnect churn, and a healthy maximum-population seal completes within the selected teardown bound while a suspended relay selects the fatal deadline path. Every relay barrier — `cut`, `freeze_lease_ops`, `quiescing`, `seal_after_quiesce` and `tearing_down` — separately proves exact-ref acknowledgement, stale and wrong-reference rejection, exact malformed response, suspension, and another owned component's `EXIT` while the barrier is pending; an exact acknowledgement consumed just before its deadline advances once, while one consumed at or after it is cleanup-only. Cut, freeze or quiescing failure enters bounded fail-stop without core quiesce; seal or tearing-down failure reports no operator-stop success. At an expired barrier the first fatal class is latched and the 35-second watchdog started before untrappable relay kill, with no out-of-phase reap wait and later `EXIT` cleanup-only; activation-cut cases forcing both serialized mailbox orders: create and resume handled first finish their Store and entry-or-dormant decision, with any `:acquiring` entry reported `unsettled` and fenced and a post-commit owner-start failure proved to have no writer, while the early quiescing barrier handled first refuses the call before Store access with no entry or durable record; a prompt held after Control routing but before `SessionCoordinator.command/3` is released only after the coordinator's drain call returned `rejected_no_active_run`, then refuses and writes no prompt admission; and one asserting the acknowledgement returns while a prompt commit is still in flight, which a cut that waited for settlement would have failed into `relay_lost`; then core's `quiesce/1` running its three parts — every active session's abort durably admitted and paused **before any** cancellation begins, asserted from journal order across two sessions, then all paused cancellations released together only when every admission is committed or definitively `rejected_no_active_run`, with a failed or ambiguous admission case asserting that **none** are released and the stop proceeds to termination and fencing — and maximum-population clock witnesses: a suspended initial Control gate returns `runtime_unavailable` inside its first 5 seconds with no worker; 64 admission workers held through the 65-second work cutoff are killed and reaped by 70 seconds with no cleanup released; 64 cleanups share one release instant and advance at the earlier of all-terminal or their one root-derived deadline; 64 status calls hit their 5-second work cutoff and return to worker baseline by 10 seconds; 64 coordinators under a suspended supervisor cause direct coordinator and blocked termination-worker kills at 325 seconds with every exact exit consumed by 330 seconds before fencing; and 64 fence paths begin cancellation at the 125-second work cutoff with every pid and operation absent by the 130-second outer deadline — each admitted abort being the command a client's own `session.abort` writes, under the deterministic `drain_abort` command ID derived from that session ID and its pre-admission owner epoch, with journal version retained only in the Store binding, and one fence procedure for every writer-started key in the frozen census after every enumerated coordinator is dead — settled ones included — while a never-started key is omitted from the projection and result and starts no worker — with a committed fence preserving the earlier settled or unsettled classification, a stale refusal reported conservatively as `unsettled` with `:superseded`, a bounded head-read failure carrying `{:unknown, :no_head}`, and an unresolved proposed fence carrying `{:unknown, :fence, head}`; the answer's **three** lists — settled, unsettled and absent — and its per-session `fences` map are asserted together — with **the case that would have failed before**: a settled session's straggler commit, held inside the Store and released during the Store stop while it is still alive, asserted refused `:stale_owner_epoch` and absent from the journal, and both the root-specific `budget_ms` and fixed `fence_budget_ms: 130_000` reported on the daemon's stop line beside its `drain_id` — no shutdown-specific field on the record, the cause reaching the operator through `daemon.stopping` and `stderr` instead — driving each session's in-flight work to settle under that session's own grace within a drain budget derived from `cancellation_bounds/1`, and after all released cleanups become terminal or the shared deadline is reached, directly killing every coordinator still alive after the concurrently issued `DynamicSupervisor.terminate_child/2` calls, awaiting every `DOWN`, and only then fencing every writer-started session and omitting every key outside the writer-domain projection, in that order, before it answers — including a suspended-supervisor witness proving the direct coordinator kills complete, fence mode starts outside that supervisor, and resuming it releases no queued late start, and **both halves asserted**, with `settled` read on the surface that decides it — the coordinator's `{:session_status, owner}` reply, asserting the aborted run is in neither `active_run_id` nor `pending_work_ids`: a dispatched tool effect that settles carries its ordinary terminal fact in the journal, and a session whose cancellation finished but whose terminal is not yet committed at the budget is asserted **`unsettled`** rather than settled, and one held past the budget leaves its coordinator dead at the instant it is reported with **no terminal claimed for that work** — no `cancelled`, no `outcome_unknown` — its ambiguous mutation left as `commit_unknown` and resolved to exactly one outcome when that session is next activated; a `Control` restart during the bounded census is forced under a live retained runtime root with Control and EventDispatcher monitor messages consumed in both orders: direct Control loss and EventDispatcher-first followed by the nonblocking retained-pid checks each name fatal `drain_failed`, claim no census or fence result and take crash-equivalent teardown; a runtime-root exit is forced with root and child signals consumed in both orders and always names `runtime_lost`; an isolated EventDispatcher loss while retained root and captured Control remain exact and live also names `runtime_lost`; the detailed create/resume API is forced with exact `Control` loss before processing and after child start but before reply, returning only outer `{:error, :runtime_unavailable}` to the daemon with no fabricated disposition, control entry or public method reply and forcing fatal `runtime_lost`; outside an orderly stop, killing the exact monitored `Control` child and, separately, the exact monitored `EventDispatcher` child each makes the owner name `runtime_lost`, fail-stop, close controller and observer connections, discard no marker, and permit a clean successor, with the case asserting no stale lease or attachment reservation survives; while the unlinked quiesce helper is held, killing only EventDispatcher with the captured Control proved exact and live and, separately, killing the Store proves the responsive owner latches `runtime_lost` or `store_lost`, terminates the helper, emits no `operator_stop` success and never exits zero; a Store exit injected while the listener's stop-helper wait is active is consumed by that same all-owned-exit loop, latches `store_lost`, sends the exact fatal latch to the sentinel before continuing and suppresses the not-yet-sent `operator_stop` notification; one case completes teardown and exits non-zero, while a paired case kills the owner immediately after the sentinel receives that latch and proves the retained status is `store_lost`, never `owner_lost`, and the absolute 35-second watchdog still bounds halt; the connection registry's deferred bounded `close_all` attempting one best-effort `daemon.stopping` naming `operator_stop` per open connection, consuming its existing monitor `DOWN`s and killing survivors at the shared deadline — asserted received where the transport accepts it and an EOF alone accepted where it does not — the socket pathname **left in place** — no exit path unlinks, and the next verified placement-lock and marker holder proves its owner and socket kind before removing it and binding, asserted by a following daemon starting cleanly on that root — the Store stopped after every composed edge and completed its release attempt, then the placement helper returned exact `:ok` and normal `DOWN`, and exit `0` — with direct probes observing both exclusion paths absent and the foreground server opening the same root immediately afterwards, which together prove the healthy attempts released them, and, for an active session whose abort and fence both commit, the journal differing from abrupt death by exactly those two records, both replayed by the released reader; separate refused-abort, superseded-fence and unknown-fence cases assert no record the Store did not commit. **Store loss is a separate fail-stop, not that sequence**: the Store's own `terminate/2` attempts marker release before the daemon can act, while ignored removal or parent-sync failure may leave a residual and the host placement lock remains held. The healthy witness separately observes marker absence; a residual follows verified live/dead/unverifiable recovery rather than being called released. The daemon observes the death, refuses service, closes every connection with `store_lost` (or `store_capacity_exceeded` where that was the reason), leaves the socket pathname in place and exits non-zero with that class on `stderr`, attempting no Store stop because there is none to attempt — proved by same-VM and separate-VM contenders refusing `placement_active` before Store or socket access while the predecessor Control lives, followed after its halt by one successor reclaiming the stale placement lock and starting. An active session progresses with zero attachments. A healthy orderly stop observes the writer marker and placement path absent after their bounded best-effort attempts and records nothing false; callback completion alone proves only that an attempt finished, so an ignored removal or sync failure may still leave a residual for verified recovery even when orderly shutdown exits `0`; an abrupt kill followed by restart activates nothing, then activates each session the root records when a client reaches for it, under the same placement identity and with no duplicate effect. The restart proves both exclusion paths explicitly: placement acquisition first refuses a live owner, refuses an unverifiable owner and recovers a dead one; only then the daemon opens with `recover_stale_writer: true`, a marker whose holder is proved dead is reclaimed, a marker whose holder is alive refuses with `store_writer_active`, and a marker whose holder cannot be decided refuses with `store_writer_unverifiable` — all three before the socket path is read, unlinked or bound. Simultaneous daemon starts on one root resolve at the placement lock with exactly one listener and the loser never opening the Store or touching the socket; an independent raw Store writer remains refused at the writer marker. A root driven to the 256 MiB log capacity refuses the append with `store_capacity_exceeded`, the store terminates, the caller sees `commit_unknown`, and the daemon closes the listener and every connection and exits naming the capacity with nothing committed lost; a root whose log is already past that bound is refused at open with `store_log_too_large` rather than opened and truncated. `session.list` returns pages of at most 256 entries in session-ID order with an exact continuation cursor from the daemon index, carrying only session identity, recorded placement identity, `residency` and `controlled`. A session committed to the Store whose daemon-index row was never written — injected at that exact cut — is absent from the listing, still reachable by ID, and present in every listing after the activation that records it. A detached long-running command and a pending admission each cross the idle deadline with every client gone and run to completion, proving idle eviction releases attachments, windows and buffers but never a coordinator; the already-activated session remains `active` for that daemon lifetime rather than becoming dormant. The activation ceiling refuses the 65th activation of a daemon lifetime with `activation_ceiling_reached` and the restart remedy, and the count starts again after a restart because it counts per lifetime; a fresh `session.create` raises the count by one, and at the ceiling a create is refused with that same reason, so creation is proved to spend an activation rather than being exempt from the bound; attach consults the activation set rather than the listing index, proved at the 4,096-entry ceiling where a session activated but deliberately unrecorded still attaches; killing an activated session's coordinator leaves the daemon serving: the listing still reports `residency: active`, which remains true because this daemon did activate that session, attach still succeeds, and the CLI's bounded `session.inspect` returns generation 2's exact correlated `session_unavailable` before any session-driving mutation; repeating inspect against that daemon repeats the refusal without a mutation, while restarting the daemon and retrying `loopex resume --daemon` takes the dormant resume branch, starts one coordinator, reattaches, inspects and drives the same durable session successfully; a bounded daemon index whose encoded size, literal header/version, canonical identity encoding, digest or 4,096-entry ceiling is invalid refuses at start without scanning `sessions/`; an exact 726-byte maximal row opens and a 727-byte row refuses as corrupt. Every live index update writes the complete canonical image exclusively to the one fixed mode-`0600` sibling `session-index-v1.next`, retains its opened device/inode identity, syncs and closes it (with close failure treated as pre-rename), renames it over `session-index-v1`, and syncs `daemon/`; a crash before rename leaves the old index plus at most that one temporary, while a crash after the directory sync leaves the new image. Startup and `prepare-index`, only after acquiring the placement lock and then the Store marker, remove that exact temporary only after `lstat` proves a daemon-owned non-symlink regular file; any other shape refuses `session_index_corrupt`, and repeated crashes cannot accumulate names. A write, file-sync, close or rename failure before successful replacement closes the descriptor where still open and removes `.next` only when its owner/type/device/inode still match that attempt, then syncs the directory; successful cleanup proves the prior image is still named and permits an in-process retry. Unverifiable identity or failed removal poisons publication until restart. A directory-sync failure **after** rename instead leaves the complete next image named and adopted in memory, reports `index_write_failed`, poisons later publication without touching either path and admits that a crash may reveal either the prior or next complete snapshot; it never claims rollback. `prepare-index` follows the same split and exits `session_index_write_failed`. Forced pre-rename write, file-sync, close and rename failures prove cleanup then successful retry; a substituted temp identity proves poison and no later write until locked restart cleanup or `session_index_corrupt`; a distinct post-rename directory-sync failure proves the new valid image is live in-process, no rollback or later publication occurs, and abrupt restart accepts one of the two complete valid snapshots. A fresh root creates a mode-`0700` non-symlink `daemon/` directory and persists the exact canonical mode-`0600` empty index before bind, and restart consumes it. A legacy root with session-directory entries and no index refuses `session_index_upgrade_required`, and the explicit offline import is proved to acquire placement then Store, create the canonical bounded index before ordinary startup, stop Store to attempt marker release, and run the same bounded exact-handle placement helper last; exact `:ok` plus normal helper `DOWN` completes only the attempt, while the healthy witness observes both paths absent and immediately reopens, and a residual follows the same verified recovery rules; a failed import before rename removes only a newly created empty daemon directory while a pre-existing directory and index remain byte-for-byte unchanged; a post-rename directory-sync failure leaves the new complete image named, makes no rollback claim and admits either complete snapshot after a crash; the daemon-owned strict importer holds the owner/non-symlink legacy-directory identity across one `File.ls/1`, excludes only released temporary names, and requires every other regular non-symlink entry to pass an identity-stable read capped at 1 MiB plus one byte, uncompressed safe decode, exact-key and filename identity checks, bounded NUL-free UTF-8 runtime and command IDs, the 4,096-command limit and cached-result identity; corrupt-term, oversized-entry and invalid UTF-8 runtime-ID witnesses each refuse `session_index_corrupt`, publish no partial union and leave the pre-existing index byte-for-byte unchanged rather than silently omitting the row; at that bound a session reached by ID is activated and not recorded and the listing carries `index_full`; a session committed to the Store whose daemon-index row was never written is recovered both by its ID — validated through core's read-only existence query, with the case asserting the validation itself created no attachment and no durable record — and, by a client that never saw the ID, through ADR 0032's full command-identity sequence run to the end — replay `session.create` with the original `command_id`, core returns the historical result and so the session ID **without starting a coordinator**, the existence query answers `{:ok, :present}` without publishing, control is acquired, and `session.resume` with a fresh resume command ID under the granted writer epoch validates this daemon's placement and activates the session, after which the daemon repairs the compatibility directory entry and daemon-index row — with the case asserting exactly one session in the root, the returned ID equal to the committed one, the replay itself starting no coordinator, the compatibility directory entry and daemon-index row present afterwards, the session listed, a live coordinator existing after the resume with the activation count risen by one, and a later prompt landing on that session and producing its events rather than on a second session or on nothing; an unknown ID answers negative from that query with nothing created, nothing attached and no lease granted; an index write that fails during activation sends that client `daemon.notice` with `index_write_failed`, while a compatibility-directory write failure emits a bounded operator warning; either leaves the session usable and reachable by ID; a pre-rename index failure leaves it absent from `session.list` and, when cleanup proved the fixed temporary gone, a later ID-bearing command retries publication, while a post-rename directory-sync failure leaves the complete next row visible in this daemon but poisons every later publication because crash durability is unknown; a poisoned publisher touches no later temp and waits for restart; bare existence or command-history lookup never publishes; a recorded session the daemon's composition cannot serve refuses at activation by name while every other session in the root activates. After an orderly stop the foreground server and the reference CLI reopen the same root and resume a daemon-created session under the same placement identity with identical replay. No durable method reaches the socket |
| 2 | `apps/loopex_daemon/test/socket_transport_test.exs`, `apps/loopex_protocol/test/public_schema_conformance_test.exs`, `apps/loopex_cli/test/daemon_commands_test.exs` | A raw-byte client over the socket negotiates generation 2 and receives generation 2's **own** exact schema digest, written out as a literal in the conformance module beside generation 1's and different from it by construction: `LoopexProtocol.Session.V2.schema_digest/0` is taken over the generation, the ordered methods, the ordered record families, the ordered error codes and the limits, and generation 2 changes **all five**, so a generation 2 that negotiated generation 1's digest would be reporting a contract it does not serve. Generation 1's **method inventory, record families, error codes and limits** are proved unchanged in the same module — the four inputs it keeps —, so the generation-2 work is proved additive rather than asserted to be — and **all three assertions that pin generation 1's changed schema digest move, and the case asserts those moves rather than the old equality**: the `3a17…08f4` **schema digest** at `public_schema_conformance_test.exs:290-291` and `:351`, plus `session_schema_test.exs:116`, because `@generation` is one of the five inputs `schema_digest/0` hashes (`session.ex:192-199`). The **two file digests at `:297-298` do not move**, because the manifests they pin already carry `loopex.experimental/1` and contain no occurrence of the retired name. The generation assertion at `:282` changes with the code it checks. The case asserts the new schema digest against a freshly computed value and asserts the other four inputs are byte-identical to what generation 1 served in `0.1.0`, which is what separates a rename from drift. **And it adds the assertion whose absence let a released discrepancy survive**: `LoopexProtocol.Session.generation()` equals generation 1's manifest `/generation` and `LoopexProtocol.Session.V2.generation()` equals generation 2's, so generation 2's new manifest and pin cannot drift from its code the way generation 1's did. A `0.1.0` client's generations list is refused `unsupported_generation` with nothing created, and the repository's Node client is proved against the new string. A generation-1-only initialize is refused with nothing created. Generation 2's record families include `daemon.stopping` — required `reason` and `message`, with no `retry_after_ms` — and `daemon.notice`, the second carrying `index_write_failed` for an activation whose daemon-index write failed, with literal vectors for each `daemon.stopping` reason a **client can actually receive** — `operator_stop`, `store_lost`, `store_capacity_exceeded`, and one `fatal:<class>` per linked component a client can actually be told about (`runtime_lost`, `transfers_lost`, `workspace_lease_lost`, `executor_lost`, `registry_lost`, `custody_lost`, `capability_lost`, `relay_lost`, `listener_lost`, `drain_failed`) — ten where artifact transfers are enabled and nine where they are not, and **not `connections_lost`**: listener loss leaves the registry and accepted connections alive to write and close, while registry loss removes the set and buffer-control interface, so only the latter cannot reach a client, plus one correlated `control_owner_lost` lease-operation vector — required `request_id` and `message`, no session state or cursor, and the connection kept open — covering the shared shape used by a claimed acquire, release or unpromoted mutation — and two uncorrelated vectors for granted-holder loss — required `message` and `session_id` in both, no `request_id`, optional `event_cursor` present only for an attached controller, and the connection closed — and four for ADR 0023's `detached` — overflow, aggregate pressure, idle eviction and core succession invalidation — each carrying `session_id` and the last completely emitted `event_cursor`, each written best-effort and followed by close; the first three close **that connection alone**, while succession closes every notified connection for that session after transfer and charge cleanup, and none ends the daemon, and vectors for `control_not_held`, `control_pending`, `control_capacity_reached`, exact `session_unavailable` — required `request_id` and `message`, no session state or cursor, connection kept open — and `daemon_stopping`, the correlated refusal a command meets after the admission cut — and explicitly none for the startup-phase classes, which carry no vector because no socket exists when they occur and no client can be holding one, and its presence in the digest is what a generation 2 omitting it would fail on. Its delivery bound is proved both ways: a reading client receives the record before the close, and a client that has stopped reading until its 4 MiB output buffer is full receives nothing and is closed anyway, with the daemon making exactly one attempt and never blocking on it. Identical durable identities for the same command corpus through facade, foreground server and socket. Owner-only peer access proved in both layers: the socket's `0700` daemon-owned subdirectory and `0600` socket mode read back after bind, a permissive subdirectory or socket mode refused at start, a subdirectory the daemon does not own refused, a path component below the root that it did not create refused — and a state root at the ordinary `0755` the foreground server creates it with accepted, not refused, because the daemon owns the subdirectory and never re-permissions the root — and an unreadable, short, undecodable or valid-but-mismatched peer credential closing the accepted connection before initialize — all in the fast check, which needs no second user — with two `@tag :cross_uid` cases the release check runs as `mix test --only cross_uid` on Linux. The foreign-user case first proves the verified filesystem modes deny connection in the kernel, then deliberately relaxes the directory and socket modes after readiness so a second foreign connection reaches `accept` and is rejected by decoded `SO_PEERCRED` before initialize; the paired daemon-uid case succeeds. Cleanup restores both modes, and the script asserts exactly two executed tests so neither a zero nor a lone survivor can pass. The accept-time initialize deadline is forced at the child-start/listener-owned cut, on both sides of controlling-process transfer with both transfer results, after listener death between reservation and child start, after listener death following a failed transfer but before close acknowledgement, across registry promotion, and with an initialize completion queued before but consumed after the instant; every late branch closes the exact socket owner, reaps the child and row, returns one slot, and advances no initialization, while each paired just-before branch advances once and timer order changes nothing. Frame, fragment, malformed-input and over-long socket path refusals have distinct stable reasons; the Darwin floor run binds at 103 and refuses 104 while the Linux lanes bind at 107 and refuse 108. A client disconnect recorded as transport loss with no cancellation and no interaction change. The generation-2 vectors are literal bytes with literal verdicts, held beside generation 1's in `apps/loopex_protocol/test/public_schema_conformance_test.exs`, never values generated from the implementation they check. The table-driven CLI case enumerates every accepted and refused live flag, incompatible pair, duplicate, missing value and numeric endpoint; accepted rows assert the exact request sequence, while every parser refusal proves zero socket dials and zero facade calls, and paired offline rows prove the released grammar, session-driving semantics and output stable while Outcome 6's governed host-composition credential custody changes |
| 3 | `apps/loopex_daemon/test/collaboration_test.exs` | One lease per session in daemon memory with observers attached. For the eight existing-session core mutations, connection identity, epoch, held state, unexpired term and a live attachment for the pinned session are checked together before core admission or any durable write, including a known current epoch sent by an observer — the mutation gate's **five conditions** exercised by **six cases** — ADR 0033 maps them one to one — each asserted separately in the daemon's own state and all six asserted to produce the **same** wire answer, `control_not_held` with nothing beyond the envelope, so no refusal is an epoch oracle. The daemon is also proved to consume `writer_epoch` only at that gate and strip it before core command normalization: a command accepted under one tenure whose reply is lost is re-presented after reacquisition with the same method, durable command ID and canonical semantic input plus the fresh epoch, returns the original idempotent admission and adds no durable bytes, while the stale-epoch form refuses before core. Release checks the first four conditions and deliberately has no attachment condition. The one explicit fifth-gate exception is proved beside them: a holder resumes a verified dormant session before attach, while a prompt in the same state refuses `control_not_held`. A holder's own `session.acquire_control` asserted to **renew**: same epoch, moved deadline, `renewed: true` — the branch a rule that refused every held lease would have swallowed. `session.release_control` asserted to carry `writer_epoch`, to refuse `control_not_held` from a non-holder, and to refuse ADR 0023's `invalid_request` — not `control_not_held` — when the field is absent, since a malformed request never reaches the gate; a dormant acquire followed by `session.attach` refusing `session_dormant` then releases successfully without an attachment, and another connection acquires immediately. Live-owner takeover only after release or expiry, and post-owner-loss replacement only after the exact dead-owner pop, owner-loss classification acknowledgement, terminal holder-close or correlated-refusal settlement, and retained predecessor-ticket settlement, with a fresh epoch minted before the successor's first command. A killed controller fenced and its late commands refused. The three ways a controller stops holding, proved separately because the transport cannot tell two of them apart: an explicit `session.release_control` linearizes release at the relay's `result` CAS and reports success only after mirror-clear settlement, while an EOF from a politely closed client and a killed client both wait for expiry, with a takeover refused before the deadline and granted after. A lease owner killed before and after a mutation is promoted takes neither the daemon nor any other session down: a pending or queued origin starts no core task and receives exactly the holder close or non-holder correlated refusal selected by mirror classification; a promoted relay task remains retained to its real core result; observers stay attached and keep receiving; successor start waits for the classification and notification barrier, its first grant waits for both populations to settle, and the previous holder's delayed command is refused on both the holder and the epoch check. Mirror publication is then forced at three cuts — owner death before sending the daemon request, after that request reaches the daemon but before registry commit, and after commit but before reply — plus an ordinary-serving acknowledgement queued ahead of its timer and consumed after the five-second absolute deadline; the last case must atomically latch `connections_lost`, start the fail-stop watchdog, send untrappable `:kill` to the exact registry, await no out-of-phase reap and claim no success. Exact dead-owner mirror pop is forced present, absent, duplicate and racing a successor, proving the linked daemon owner orders any sent install before EXIT, atomically removes only the dead pid/incarnation before successor install, leaves no stale row and preserves the successor mirror against an old exact clear or pop. The relay retains an `owner_lost` winner until it joins the exact owner `DOWN` and mirror-pop classification, with those two facts delivered in both orders. Acquire and release are each killed before and after `pending -> executing`, including after acknowledgement of a pending permit carrying the immutable exact-owner binding but before that owner claims it; the relay must select `owner_lost` from retained data without guessing or leaking the row. A lease-authorized mutation is killed as `pending_ticket`, queued and promoted. An unpromoted mutation starts no core task, while a promoted relay task stays retained to its real core result. For every claimed origin on the returned granted holder, the correlated reply is suppressed and only the uncorrelated close is emitted; any claimed non-holder acquire or release, or claimed pending or queued mutation, receives only the correlated refusal and stays open; a promoted mutation receives its real result. Renewal's direct-result branch is forced both ways: a result sent directly to the relay before EXIT wins `result`, while exact-owner DOWN first wins `owner_lost`. Release uses one daemon-coordinated settlement: witnesses kill the owner before its proposal, after proposal before the relay result CAS, after result before mirror clear, and after clear before reply, proving an owner-loss winner preserves the mirror for classification while a result winner clears it before one correlated success and makes the later pop absent. A separate disconnect after proposal but before result CAS retains `settling(connection_lost, release_ref)`, restores the owner to `held` with its original deadline through the exact cancellation handshake before terminalization, emits no success, leaves no stuck `release_pending` and permits takeover only after ordinary expiry. Disconnects after result wins before mirror clear and after clear before the success attempt prove result-first settlement still clears the mirror, terminalizes the permit and frees the lease when its reply is lost. A live owner paused through `owner_restore_deadline` and an owner restoration acknowledgement queued before but consumed at or after that instant both force exact-owner kill and begin the no-reply cancellation supersede. The supersede acknowledgement, the restored-owner cancellation settlement and the result settlement are each forced just before and at or after `release_settlement_deadline`: a matching first case terminalizes, while an at-or-after acknowledgement is cleanup-only after `relay_lost`, leaving no stuck `release_pending` or settling permit. A missing or malformed relay settlement also selects `relay_lost`. Each cut yields one terminal disposition, drains the predecessor set and emits exactly its selected reply or close. A crossing witness pauses a serving classification before acknowledgement and orders stop consumption and classification completion both ways: classification-first may emit its selected form before the cut; stop-first rebinds the row to the transport-cut instant, makes the private timer and queued acknowledgement cleanup-only, and emits only the later `daemon.stopping`/EOF path. A stop-overlap case kills the maximum live-owner population after the admission cut, delivers each owner `DOWN` and mirror-pop result in both orders, and proves the facts join the already scheduled stop barrier and its one deadline: no per-owner clock starts, no `control_owner_lost` form is emitted, and the measured orderly bound gains no owner-count term. Holder-changing acquisition is forced under both an existing owner and a fresh child at provisional install, on both sides of the recorded actor's `executing -> result` CAS, and on both sides of exact provisional resolution: connection loss first resolves cancelled, discards the existing-owner proposal or kills and reaps the fresh `start_op_ref` child and exposes no epoch, while result first resolves granted and only its acknowledgement exposes the epoch; a later EOF follows ordinary expiry even if the reply is lost. The existing-owner case also consumes the grant report and install acknowledgement before forcing owner DOWN on both sides of the daemon's later result CAS: `owner_lost` first resolves cancelled, awaits exact clear, sends one correlated refusal and leaves the connection open with no epoch, while result first resolves granted and the later owner-loss path closes the exact promoted holder once. The registry refuses provisional install for an incarnation already closing. A pre-cut acquire and release claim immediately before the deadline while relay freeze is forced before and after the daemon timer. The idempotent `freeze_lease_ops` operation atomically compare-and-sets every executing lease permit to terminal `shutdown_admitted` before destructive cleanup and returns the same fixed tagged union on every call: barrier-owned `shutdown_admitted`, `settling_acquire`, `settling_release` and `settling_owner_loss`. Result, connection loss or owner loss selected first appears in its exact settling variant; freeze selected first makes a later actor result cleanup-only. A settling owner-loss row may have no daemon operation record or the exact accepted acquire or release record whose result lost, and the cleanup tombstones or resolves that record rather than inventing one. For a barrier-owned existing-owner operation the daemon kills and reaps the exact descriptor actor, exact-pops its pid/incarnation mirror, joins the relay's owner `DOWN` and settles every claimable lease permit and pending or queued mutation origin without ordinary output; a promoted ticketed mutation stays on its real-result path. For a fresh acquire, whose actor is the daemon owner, retained `start_op_ref` state must be `not_materialized` or name the exact child to kill and reap, and any installed provisional mirror is cancelled and cleared. Forced acquisition result and connection loss, release result, restored and unresolved connection loss, and owner loss each finish their exact no-output relay and mirror cleanup by `freeze_deadline`. Each existing-owner acquire/release result and restored release orders the recorded actor-owner `DOWN` on both sides of descriptor settlement. Each fresh-acquire result instead orders the resulting child lease-owner `DOWN` named by retained start and operation state, while fresh-acquire connection loss has already reaped that child and leaves the daemon actor alive. The selected disposition stays fixed, settlement completes first, and the same deadline covers the later reap, exact pop and classification. A missing required operation or start record, a wrong tag, a missed relay acknowledgement or unfinished terminal join selects `relay_lost`; a missed registry acknowledgement or unfinished exact mirror selects `connections_lost`; neither path begins core quiesce. Every provisional, pending or stale operation mirror is absent and every nonterminal or claimable lease or pending/queued mutation origin is terminal before quiesce; an exact granted or restored holder mirror may remain for the drain. No actor-map scan or post-cut client output occurs. The relay's own two rules, each with a case that would pass without it: a client pipelining two mutations on one connection without waiting has them **admitted in wire-arrival order, one at a time**, the connection itself sending sequence-numbered owner enqueues before its independently scheduled workers can invert, the second held in its lease owner until the first ticket resolves; a forced scheduler inversion releases the later worker first and still observes the earlier ticket first; an earlier mutation followed by `session.release_control` likewise settles before release, with the in-flight admission set asserted to hold at most one entry throughout and a takeover asserted to be granted after exactly one resolution rather than after a queue drains — and the relay asserted never to answer `ticket_outstanding`, the invariant's own refusal, under that same pipelining; killing a queued mutation worker before its ticket cancels the exact owner row and starts no core call, while killing it after ticket acknowledgement retains the ticket and returns the real result without an early generic failure; and the ordering inside the ticket callback asserted on the surface that shows it: before the acknowledgement is emitted, the relay's own state is read in-VM and asserted to hold the ticket row, recorded task pid and monitor, with executor start ordered before reply; at delivery the row and monitor remain until any already-queued result or `DOWN` is consumed, without asserting the fast task is still alive. This includes `session.attach` through the internal attach-for-holder call with the connection pid as holder. A relay that replied before spawning passes the ticket assertion and fails the recorded-start assertion, which is the difference the case exists to make. A daemon restart leaving every session uncontrolled with every earlier epoch refused. A controller abort cancelling work dispatched under an earlier process with a truthful cleanup outcome. The expiry linearization: a mutation blocked inside core across the deadline settles under its own lease while the eligible takeover waits and is granted only after it resolves; the holder's next mutation refused at the deadline; the acquiring request refusing with `control_pending` when its own deadline elapses first; and the holder disconnecting while a mutation is in flight — in every case exactly one of settle or refuse, never both. No control from content, metadata, answers or attachment order. Forward and backward wall-clock jumps changing neither live admission nor takeover timing |
| 4 | `apps/loopex/test/concurrent_attachments_test.exs`, `apps/loopex/test/session_existence_query_test.exs`, **`apps/loopex/test/runtime_quiesce_test.exs`**, **`apps/loopex/test/cancellation_test.exs`**, **`apps/loopex/test/trace_session_test.exs`**, **`apps/loopex/test/session_detailed_results_test.exs`**, `apps/loopex_daemon/test/replay_residency_test.exs` | Core's read-only `session_existence/2` returns exactly `{:ok, result}` where `result` is one of `present`, `absent`, `invalid_id` and `store_unavailable`, or the distinct outer `{:error, :runtime_unavailable}`, from a fresh process against a real root, with one case per result and failure. `store_unavailable` is injected through the controllable fault store the suite already has, `Loopex.M1RuntimeTestStore`, whose `fail_reads/2` hook makes its reads refuse, and through an out-of-set adapter reply that the real Store facade normalizes to unavailable — not by making the root unreadable, which cannot produce that answer on the real adapter: `Loopex.Store.Local` answers `ownership_head` from `state.store`, in memory, so a root that has become unreadable on disk still answers. It is proved to create no attachment, no incarnation, no durable record and no Store write: the root's journal and session directory are byte-identical before and after a run of queries, including for unknown and malformed IDs. Control acquisition proceeds only on `{:ok, :present}`; the other three domain results fail closed with no attachment, no lease and no activation, and name three distinct reasons, so an unavailable store is never reported as an unknown session. A killed or replaced `Control` selects only the outer runtime error; the daemon latches `runtime_lost`, sends no existence refusal and fail-stops. Several core attachments to one session remain independent when one detaches or backpressures, including several attachment IDs under one holder. Targeted replacement removes only the named attachment owned by that holder; an unknown or foreign target refuses, the selector is part of the request binding, and one holder `DOWN` clears both core maps and all of that holder's transfers. A paused-dispatcher churn case proves the daemon does not release a reservation until core acknowledges cleanup and that neither installed map ever exceeds its per-session or per-daemon ceiling. A replacement refused at the 512 ceiling preserves the installed attachment's daemon charge and releases only the borrowed replacement reservation. A non-prepared succession initiated by an embedded holder while two daemon holders and one embedded holder are attached maps each pending daemon attach to correlated `attachment_conflict`, sends each installed daemon holder `detached` at its last emitted cursor, keeps both daemon connections open, releases each transfer and daemon charge exactly once even when holder `DOWN` races, leaves no stale core attachment state, and preserves a controller holder's lease, epoch and deadline while its next mutation remains refused until it reattaches. A snapshot anchored at the committed sequence, then contiguous at-least-once buffered and live delivery across the window boundary with no gap. Core is the only replay owner: every delivery case runs a second time with the daemon's resident window disabled and a third with it dropped mid-stream, all three byte for byte identical, so the window is proved to establish no snapshot and no cursor. Aggregate reclamation follows the fixed order ADR 0032 sets — zero-attachment windows by ascending last delivery, then active-session windows by encoded bytes owed, then unattached connections by descending output-buffer bytes and connection-incarnation tie-break, then live-attachment detachment — including the cases where zero-attachment windows alone consume the ceiling and where only initialized but unattached clients hold bytes. The latter presents a pending admission that would make `charged_aggregate + pending_admission_bytes` exceed 512 MiB, leaves those bytes uncharged, reclaims until that sum fits or closes clients without admitting the candidate and without inventing a detach cursor; a suspended initialized peer proves reclamation performs only one non-blocking write/flush attempt, never waits for peer progress, and returns the aggregate to at most 512 MiB after close. A slow observer detached at its last emitted cursor while the controller and the other attachments continue. Per-session and per-daemon limits refusing independently. Idle-observer eviction and reconnect with no missing durable event, any duplicate deduplicated by session ID, sequence and event ID; a quiet controller remains attached while its lease is held and becomes eligible for the same idle eviction only after release or expiry. Retained encoded bytes at or below the 4 MiB output buffer, 16 MiB window and 512 MiB aggregate ceilings, enforced in the daemon-owned stages, exercising 512 attachments and maximum-sized output records separately, with observed process RSS recorded beside the ceilings. Progress coalesced or dropped with counted drops and no journal delay |
| 5 | `apps/loopex_daemon/test/multi_client_workflow_test.exs`, `apps/loopex_daemon/test/external_socket_workflow_test.exs`, `apps/loopex_daemon/test/external_socket_workflow_real_test.exs`, `docs/evidence/M5-closure-runs.md` | The operator workflow end to end, each step a command an operator types: `loopex daemon` refusing once per missing or invalid mandatory or refusing composition input with its own class and leaving no marker or socket behind; root project context instead proves all four released host branches before any placement effect — interactively admitted exact manifest and decision, non-interactive exact manifest with a null decision and withheld content, absent resource as null/null, and containment or replacement exclusion with startup continuing — while a valid project-skill pack coexists as the independent `resource_manifest` and invalid project-skill discovery refuses `project_skills_unusable`; then staging a legacy root, running `loopex daemon prepare-index --state-root <root>` while no host owns it, observing the bounded index and released exclusions, and starting that prepared root with the one-line JSON readiness record; `loopex run --daemon` creating and driving a session, while `--skill` and `--skill-resource` each refuse at parse time with zero socket dials and zero protocol or facade calls; `loopex resume --daemon` taking both exact branches — an already-active session through acquire, attach and bounded inspect with no resume mutation, and a dormant one through acquire, refused first attach, resume with a fresh command ID, one successful reattach and the same inspect — plus a killed-coordinator case in which attach succeeds, exact `session_unavailable` from inspect admits no mutation, and restart then resume repairs the session; two created sessions then making `loopex sessions --daemon --limit 1` print one compact JSON line with the fixed top-level and four-field entry key order and a continuation cursor, the next page under `--after` print the other row without duplication, the empty page print exactly `{"sessions":[],"next_after_session_id":null,"index_full":false}\n`, and `loopex sessions --daemon --status` print its fixed ordered compact JSON keys while sending `daemon.status` and no `session.list`, including a socket path whose quotes, backslashes, whitespace and newline are escaped inside that one record and a true `index_full` warning appearing only on `stderr`; `loopex attach` refused with `session_dormant` at the **attach** step against a session this daemon has not activated, in both roles, while `loopex resume --daemon` acquires that same dormant session, receives `session_dormant` on its first attach, resumes, reattaches once and succeeds — the two asserted together, since refusing dormancy at acquisition would break the resume path; `--take-over` on a dormant session asserted to release its lease before exiting, proved by `loopex resume --daemon` succeeding immediately afterwards rather than refusing `control_held`; a CLI holding a lease attempting an explicit release on every exit path where its transport is still writable, and the killed-client case asserted to differ — no release, the lease waiting out its term, which is what ADR 0033 already fixes; `--after` starting strictly after a sequence and its absence replaying from `0`; a live-socket correlated renewal refusal continuing as observer on the existing attachment and sending no further mutation; a failed renewal send or EOF proving the old attachment is gone, then reconnecting at the retained cursor and reattaching as observer with no mutation; a reconnecting controller that intends to continue controlling retrying acquisition with backoff until its own lease can have expired and then holding a fresh lease with a fresh epoch before any mutation, and the variant where another client took over meanwhile exiting `control_held` rather than retrying against a live holder. The client recovery matrix is exercised at its cuts: a lost list or status reply permits one side-effect-free retry under `live_query_deadline_ms`; a lost create reply replays the same command ID and creates no second session; a post-attach EOF reacquires, reattaches and inspects without using the old epoch; and the resume replacement cut commits and activates resume ID A, loses its reply, replaces the daemon, resolves A as a completed replay whose reattach is still dormant, retires A, allocates ID B, loses once before B resolves, re-presents B rather than allocating a third ID, then activates exactly one coordinator and attaches successfully. The whole cut retains the first-loss monotonic instant and completes or fails inside its original 35-second clock. Each multi-step form retains an ordered plan whose prompt, optional follow-up or steer, and takeover prompt each carry their exact method, preallocated command ID and `not_sent | sent_unconfirmed` state, plus `next_step`; every non-steer step retains fixed canonical semantic input, while steer retains its content template until replay supplies `run_id` and then fixes that input before first send. Loss before the first write leaves a `not_sent` step that is sent exactly once after recovery and proof of its prerequisite. Loss after the write attempt leaves `sent_unconfirmed`; after reacquisition the client re-presents that exact method, command ID and semantic input with only a fresh request ID and writer epoch, and the resulting accepted or refused admission is fresh when the first write never reached core or replayed when it did, without a duplicate. Exact `admission_unknown` advances no later step and exits non-zero with the method and command ID unresolved. Cut witnesses cover that result on an eventless follow-up, a lost refusal reply, prompt followed by follow-up, prompt followed by replayed `run.started` and steer using its retained `run_id`, and takeover prompt loss on both sides of the first write. A sent-unconfirmed prompt never permits its secondary command to substitute for it. Observer recovery never activates, and takeover after daemon restart releases its new lease and names resume when attach reports dormant. A complete `daemon.stopping` record is terminal and is distinguished from a bare EOF, while every streaming retry shares one non-resetting `stream_reconnect_deadline_ms`. Real client processes receive every handled signal through launcher and direct routes: live queries exit 130 without reconnect, run, resume and takeover attempt at most one five-second release while writable and exit 0 without aborting, observe closes and exits 0, and `SIGKILL` sends neither release nor abort. From a fresh extraction of the exact candidate — staged with `git archive` — the standalone `scripts/source-archive-manifest.sh` producer writes its exact pre-build NUL stream to retained storage outside the extraction before the tree is built; an operator then follows the documented prerequisites and commands, supplies workspace, provider and policy inputs, starts the daemon, and drives one session from the reference CLI as controller and the Node client as observer, kills the controller, takes over from the observer and aborts cross-process work. The documented CLI build and the provider companion build both run inside that extraction, on the archive-carried source identity rather than on `.git`, with the missing, unsubstituted-or-malformed, changed-during-build and mismatched-commit refusals each proved and the identity the build reports asserted equal to the commit the archive was staged from. The attended real-provider cases run from that extraction, against the escript it built there. The workflow drives ADR 0030's existing core spans end to end — command admission, commit, effect intent, publication, interaction, and the model, store, policy and executor port callbacks — with the same bounded identity metadata an embedded caller produces, and no event outside that closed inventory is emitted by anything M5 adds. Daemon-internal functions are proved by the daemon's own tests and logs: `Loopex.Trace` traces only processes the runtime owns, flagged with `set_on_spawn` from the runtime's supervisor, and the daemon's listener, connections and lease owners are host processes above the runtime, so no trace-session witness is claimed for them. `VERSION` in the extracted tree is exactly `0.2.0`. Every tracked file under `docs/operator/` and `docs/developer/` has been read against the candidate, including the ones M5 leaves unchanged, recorded as a checklist derived at that commit — `git ls-files -- docs/operator docs/developer`, sorted, one row per path, each row marked *updated* or *reviewed unchanged* — retained with the closure runs. The derivation is over **every tracked file** in those two trees, not only Markdown, and that is deliberate: the gate promises that every file under them was read, so a diagram, a fixture or a data file added later must appear rather than slip through a `*.md` filter that was true when it was written and silently false afterwards. It also avoids a pathspec trap, checked rather than assumed: `git ls-files 'docs/operator/**/*.md'` without `:(glob)` matches nothing at all and would have made the gate pass vacuously. The directory form returns 26 tracked files as of this revision — 18 under `docs/developer/` and 8 under `docs/operator/`, all Markdown today — and the closure checklist states the count it derived so a reviewer can see the list was not empty, with every path in the tree present, no row unmarked, and each finding named and resolved before the closure packet |
| 6 | `apps/loopex_llm_reqllm/test/credential_plane_test.exs`, `apps/loopex_llm_reqllm/test/adapter_test.exs`, `apps/loopex_llm_reqllm/test/provider_retainer_boundaries_test.exs`, `apps/loopex_llm_reqllm/test/provider_startup_boundaries_test.exs`, core's `apps/loopex/test/trace_session_test.exs` and `apps/loopex/test/provider_lifetime_test.exs`, the exact host files `apps/loopex_cli/test/credential_custody_test.exs`, `apps/loopex_app_server/test/credential_custody_test.exs` and `apps/loopex_daemon/test/credential_custody_test.exs`, and `docs/evidence/M5-closure-runs.md` | From the completion of a reference host's composition onward, the configured credential name is absent from the parent VM's environment and no function in the adapter's call path reads the environment for a credential, before, during or after a call — "during" observed from inside the call at child readiness; composition is proved to read the operator's variable once and delete it: each exact composition-owner pid is call-traced only for `System.get_env/1` with `credential_variable/0`, with return tracing disabled, and must produce exactly one name-only call between composition entry and return; the canary is then present in custody and the environment name absent, so zero or two reads fail. The two adapter-preflight failures and every invocation-private failure map to the seven closed atoms and retain no copy: `:no_token` for an absent token; `:invalid_token` for a malformed one; `:unavailable` for immediate guardian start, Core registration, guardian authorization, sender start or adoption refusal, immediate group-leader-sink installation failure, immediate exclusion or Direct-clear failure, a token with no registry row, a gone registry, a dead custody process, malformed route or custody success, any wrong-producer registry or custody reply, a term outside the closed set, or an immediate frame-write failure; each of `:missing`, `:expired` and `:oversized`; and private `:timeout` when managed mode's unchanged absolute deadline is already elapsed at initialize or provider launch/readiness, sender release, sink installation, exclusion, registry lookup, custody resolution or frame write crosses it, or when Direct mode's pre-launch absolute instant is reached during inherited-session clearing or any later step. Exact-key validation is adversarial: canary-bearing extra keys on the token, registry handle, custody reference, tracing capability and custody success map all refuse before their next boundary, and the registry accepts only `{:error, :unavailable}` or an exact valid custody reference while custody accepts only its own three refusal atoms. Managed setup consumes and never resets the absolute invocation deadline. After Core registration, exact guardian authorization, exact sender adoption and initialize, the **guardian** applies that same instant to provider launch/readiness, sender release and every later sender step, kills the sender on timeout, and the harness proves that class distinct from every refusal. Before it accepts provider-readiness, sender, registry, custody or frame completion or emits the next release, it rechecks monotonic `now < deadline`; a timer only prompts that check, so completion queued first but consumed at or after the instant is cleanup-only and cannot extend the invocation. Paired cases at provider readiness, the exact `:bootstrap_result`, every `:credential_phase_result` and every `:credential_phase_continue` consume the same completion on either side of the instant in both mailbox orders and prove that only the before-deadline case advances. Immediate refusal at any managed gate is `:unavailable`; paired sink-install witnesses return `:unavailable` immediately or guardian `:timeout` when blocked, with no token delivered and no sink or sender retained; killing the guardian while the sender is parked or sink installation is blocked kills and reaps the exact sender and sink and returns trace-exclusion state to baseline; a live `owner_workers` start that never answers is an owner-group/runtime liveness failure outside the adapter clock, and the plan makes no adapter-timeout claim for it. The three host suites separately prove that a missing, malformed or extra-key registry handle, or a missing, malformed, extra-key or unbound tracing capability, refuses composition before runtime use or child creation and reverse-cleans every already-started edge. Each binds one capability to runtime A, accepts an idempotent A bind, refuses a B bind while preserving A, and completes a later A invocation. Each also forces custody and registry crashes during canary-bearing requests and refutes the canary across the complete OTP report and owner-observed exit — initial call, last message, state, reason, metadata and emptied log — rather than inspecting state alone; a live registry with no token row instead returns invocation-time `:unavailable`, and those composition refusals do not pretend to be one of the seven invocation atoms. Two resolutions in flight at once is a success case, not a refusal: both invocations complete, each with its own sender, its own custody reply and its own frame — using the same opaque token, with each exact reply bound to its own sender and frame and credential bytes allowed to differ when custody rotates between replies. This within-runtime case proves independent per-invocation resolution and rotation binding; it does not claim distinct-credential isolation, which belongs to the two-runtime case below. Tracing is proved against `Loopex.Trace` including the process-level exclusion M5 adds to it and the `Entry` keyword-key redaction beside it — the token travelling in model `options` through `module.complete/3` (`session_coordinator.ex:3231`) reaches the coordinator **before** the sender exists, so what keeps it out of an entry is redaction rather than exclusion, and the credential bytes after the exclusion point are what the absolute no-trace claim is about; a missing, malformed or unbound tracing capability refuses **composition**, so no invocation or child exists; after a successful bind, an immediately lost capability or unreachable `Control` refuses the invocation `:unavailable` before the token is routed, while an exclusion left unanswered until the guardian deadline yields private `:timeout`, and the decisive case names `:gen_tcp` on purpose: a trace session configured with `:gen_tcp`, `Loopex.LLM.ReqLLM.ProviderBridge` and `Loopex.LLM.ReqLLM.ProviderCodec` runs a real invocation with a **one-byte canary** credential, and the tracer captures the expected token-free sender start entry, whose exact arguments are `sender_ref`, callback owner, guardian and capability — no token, registry handle, socket, nonce, request or credential — and observes only the exact non-secret gate tuples plus `{:begin_bootstrap, sender_ref, guardian_pid, sender_pid, absolute_deadline}` before exclusion. After exclusion the sender returns `{:bootstrap_result, sender_ref, sender_pid, guardian_pid, :ok}`; only that exact success permits `{:credential_context, sender_ref, guardian_pid, sender_pid, token, registry_handle, accepted_socket, invocation_nonce}`. Registry lookup, custody resolution and credential-frame write each report the exact `{:credential_phase_result, sender_ref, guardian_pid, sender_pid, phase, result}` and advance only on the exact `{:credential_phase_continue, sender_ref, guardian_pid, sender_pid, phase, absolute_deadline}`. Wrong-reference, wrong-pid, wrong-phase and changed-deadline injections, plus a stale replay, never unpark, route or write and are cleaned at the unchanged deadline. After a successful frame write the sender drops every credential-bearing logical reference and tail-calls a non-secret final wait **before** it emits the `:credential_frame` result; its exact final continuation permits only normal exit. Only the exact normal sender `DOWN` in that final state, consumed before the retained deadline and followed by the guardian's own clock check, starts the invocation helper. Raise, exit, kill or early normal `DOWN` before expiry is `:unavailable`; the same `DOWN` after confirmed expiry is `:timeout`; and expiry at the final-continuation cut starts no helper. The Trace process is deliberately backlogged before the clear; it consumes the matching `:trace.delivered/2` marker and purges the sender's pending-call keys before the exclusion acknowledgement, after which it spawns and installs the sink from the untraced sender and receives **no further raw trace message from either sender or sink pid**, including none for `:gen_tcp.send/2` or `ProviderBridge.sink_loop/1`, while a non-excluded control process performing the same call in the same session does produce one, so the post-exclusion negative cannot pass by tracing nothing; the Direct path likewise awaits every named-session delivery marker and the legacy `:erlang.trace_delivered/1` marker before spawning its sink from the cleared sender and acknowledging. Releasing those markers after 5 seconds but before the Direct request's pre-launch absolute instant succeeds; holding them through that instant returns `:timeout`. At blocked clear, custody and frame-write cuts, abnormal or killed Direct-guardian exit reaps its raw linked-and-monitored sender and sink with no late frame; normal cleanup stops and awaits both. Managed and Direct sender exit return pending-call state and monitors to baseline; the canary appears in no captured raw trace message, rendered entry or IO request outside the one permitted custody reply. Under the **default** configuration no trace entry names `ProviderBridge.route_credential/2`, `receive_custody_reply/2` or `write_credential_frame/2`, the tracer receives no raw trace message for them and no credential byte appears in any captured raw trace message, rendered entry or IO request outside the one permitted custody reply — because `modules/1` expands a namespace through the application's own module list and the adapter is not a `:loopex` module. The token can traverse core in model options before the sender exists; the existing structured redaction proof, rather than sender exclusion, keeps it out of rendered entries. The ordering claim is proved rather than asserted, and it is proved at the **process boundary** rather than inside the body: the guardian's exact initial argument is `{guardian_ref, callback_owner_pid, stop_reference}` and the sender's is `{sender_ref, callback_owner_pid, guardian_pid, tracing_capability}`; neither holds a token, registry handle, request, socket, nonce or credential. For each child the case forces exact `start_proxy_result` and child acknowledgement in both mailbox orders plus all three legal placements of proxy `DOWN` after its same-sender result, requires the callback to monitor the child from its first pid disclosure and consume the proxy's normal `DOWN` before the next gate, kills guardian and sender after either disclosure and before transfer completion to prove `:unavailable`, and proves both supervisor refusal and a caught starter exit reverse-clean an acknowledged child without overlapping a second proxy. `set_on_spawn` traces a spawned closure's entry call, so the proof observes both exact tuples, both acknowledged ownership gates, the sender parked until child readiness, and token delivery only after exclusion is established and confirmed. The tracer is asserted to receive **no raw trace message from that process carrying the token at any point**, entry included, while a non-excluded control process spawned with the same closure shape does produce one; `exclude_self/2` and its delivery barrier finish before the sender spawns its sink; the sink inherits no trace flags, both pids are verified clear before the token is sent, and a session started concurrently with exclusion yields no message from either pid in either order. Every IO request during the real credential invocation is captured and proved credential-free; a separate non-secret IO canary after token delivery is swallowed by that sink and appears in no sender/sink raw trace or host Logger output, while the credential canary remains absent from every captured raw trace message, rendered entry and IO request outside the one permitted custody reply. Process and MFA exclusion are the sole credential-byte trace control: ADR 0030 placeholders retain value-derived size and digest, so even a placeholder for a one-byte credential is a 256-guess oracle. The one-byte canary must therefore appear in no captured raw trace event or rendered entry at all. The keyed custody map remains the exact validation/dataflow shape, not a safety fallback. A further case asserts all three exact function identities and separately proves keyword-key placeholdering only for the opaque 128-bit token before the sender exists, so no tier can pass vacuously or against the wrong signatures. The exclusion mechanism itself is proved in core's own suite: a process flagged by `:set_on_spawn` inheritance calls the exclusion, a forced tracer backlog is drained through the delivery marker before acknowledgement, its subsequent traced call produces nothing while a non-excluded control call produces a message, `:calls` retains no pending start, return-bearing state is purged on process death, and all monitors and pending keys return to baseline, at both toolchain pairs. The same suite proves a live trace operation through the handle in Trace's process-owned private ETS table, shows `:sys.get_state` exposes only the private table identifier and weak metadata and that another process cannot read that table, then uses a fake trace-module handle containing a unique binary canary and inspects the complete forced-crash report and owner-observed exit. It refutes that canary everywhere and proves Trace's `format_status/1` replaced `state`, `message` and `reason` and emptied `log`, with no full handle rendered. The registry lookup is proved to carry no credential. A separate named `credential_plane_test.exs` case, `custody reply is the sole credential-bearing BEAM message`, uses deterministic phase pauses and mailbox inspection rather than call tracing. After custody accepts the resolution request, a test gate holds its reply; the harness suspends the raw Task sender while its `GenServer.call` is waiting, releases custody, and starts a short-lived isolated inspector that reads `Process.info(sender, :messages)` after enqueue and before receipt. The inspector observes the exact `{call_reply_tag, {:ok, %{credential: canary}}}` wrapper, with the exact reference-or-alias reply tag minted for that blocked call, sends its parent only a non-secret verdict, and is terminated and awaited because `Process.info/2` copied the canary into the inspector. The case enumerates every registry, custody, guardian and sender application message, refutes the canary from every other application-message payload and from registry and guardian state, and makes no `:sys.get_state` claim about the raw Task. After the frame write, `Process.info(sender, [:current_function, :current_stacktrace])` identifies the exact non-secret final-wait MFA and its tail-call stack; the case refutes the canary in the sender mailbox, process dictionary and complete forced-crash material before `:credential_frame`. Two runtimes composed in one VM, each with its own registry, custody, token and distinct credential, are proved isolated: a token minted for one answers `:unavailable` in the other, so tokens do not cross runtimes, and neither runtime's child — nor either child's diagnostics — ever observes the other's credential. This is the distinct-credential isolation witness. The within-one-runtime concurrency witness deliberately uses the same opaque token for both calls and proves only independent resolution, exact invocation-to-reply/frame binding and permitted rotation between replies. A registry killed under a composed runtime makes every later resolution through that handle answer `:unavailable`, and the adapter is proved not to retry, wait or rebuild — recomposition is the only repair. A guardian forced to crash after its initialize message leaks neither the valid token nor registry-incarnation canary through its Task/supervisor report, exception or exit reason, stack, messages, state, metadata, log or owner-observed exit. Every re-pointed case of `apps/loopex_llm_reqllm/test/credential_plane_test.exs` passes with its assertion unchanged in meaning: version refusal and bootstrap refusal before any credential, late delivery after expiry impossible, rotation between invocations, two composed runtimes with distinct live credentials in one VM, sink loss, one child's loss not poisoning another, ordinary host messages and returned reasons, every child Logger form and metadata, and the four crash-report cases. The child-environment witness inside the version-refusal and bootstrap-refusal cases — the child's recorded `entry-env` marker refuting `Adapter.credential_variable()` — holds unchanged. `provider_startup_boundaries_test.exs` counts the actual custody protocol: exact readiness produces one resolution, while killing the real pre-entry process produces zero resolutions, zero dispatches and no canary in diagnostics. The 65,536-byte ceiling case in `provider_retainer_boundaries_test.exs` is re-pointed too, because that module delivers its credential through `System.put_env` in its `setup` and again in the case body; that invocation's own custody process holds the oversized value instead. The drift-protection case in `adapter_test.exs` survives strengthened, with an exact allowlist: `[]` for `provider_bridge.ex`, the arity-zero enumeration and only that for `provider_launcher.ex` because it is ADR 0019's first-image scrubbing rather than a credential read, `provider_worker.ex`'s two non-secret crash-dump names, and `[]` everywhere else. Because the launcher's read survives, the case also asserts its *use*: the enumeration's result flows only into the Port's removal list, every name is mapped to `false`, none is compared against `credential_variable/0`, and no value reaches the sender, the frame or any caller. Its scan is widened from one `System.get_env(...)` expression to every route an environment read can be written — `System.get_env/0`, `/1` and `/2`, `System.fetch_env/1` and `fetch_env!/1`, `:os.getenv/0`, `/1` and `/2`, `:os.env/0`, and indirect application through `apply/3` or a captured function — each unpinned route refuted outright. The `req_llm` move to `~> 1.24.0` — pinned to that minor, not to `~> 1.24`, so the reviewed diff is the version actually built against — lands as its own reviewed change before the credential change, with the reviewed changelog diff across the intervening releases named in the commit, the adapter and streaming-conformance suites green, and the *existing* real-provider case at closure run against it. It adds no call path: nothing in M5 calls anything `1.24.0` makes newly reachable, and no second provider, second credential or new release-check case enters this milestone. It is explicit M5 scope, separate from ADR 0035 and not conditional on it. A security review by someone other than the implementer is recorded. The eleven modules — of the thirteen the application runs serially, the count measured by loading them rather than by globbing `test/*.exs`, which misses `test/support/provider_entry_test.exs` — are then converted to run concurrently one at a time, each kept only while its application's suite stays green, any module that stays serial keeping its reason beside it, and the measured duration is recorded beside the M4-closure baseline as evidence about the change rather than a threshold |

The reference CLI witnesses are named separately because they prove command
ownership and parser effects rather than a core invariant:

| Exact file | Exact case | Lane | What it proves |
| --- | --- | --- | --- |
| `apps/loopex_cli/test/daemon_commands_test.exs` | `daemon startup grammar resolves exact inputs before effects` | fast | The startup and `prepare-index` grammars, their distinct accepted inputs, flag-over-environment precedence, empty and invalid values, the startup-only two-policy registry, duplicate and positional refusals, zero placement, Store, socket or component work on every parser refusal, status `1` for those refusals, silent status-`0` import success with no readiness line, and handled import signals during enumeration, pre/post rename, Store stop and placement release returning status `110` with no stdout or partial image; direct calls to the shared path-input API pass `<<0xFF>>` as each command's state root and as startup's explicit socket, proving `state_root_unusable` for either invalid root, `invalid_socket_path` for the invalid explicit socket, the root classification for its unattempted derived socket, and zero path-normalization, filesystem, placement, Store, socket or component effects; startup also proves that an interactively admitted root `AGENTS.md` reaches composition as the exact `project_manifest` and `project_decision`, a non-interactive launch carries the manifest with a null decision and continues with its content withheld, an absent resource carries null/null, and an independent `.agents/skills` pack reaches `resource_manifest` in the same call; daemon startup compares the complete readiness `stdout` byte for byte against the fixed five-key compact JSON object plus one LF, using short resolved root and socket paths containing a quote, backslash, space, tab and newline and asserting no second record or extra byte; operational import failures assert the reused class/status map, including `session_index_corrupt` for a legacy/index identity conflict and for corrupt, oversized or invalid UTF-8 strict-reader rows, each before publication with the prior index byte-identical |
| `apps/loopex_composition/test/project_resources_test.exs` | `root project-resource trust is shared by both reference hosts` | fast | The cases moved from the released CLI helper retain its one-label root discovery, bounded read, workspace identity, symlink containment and replacement-race exclusions, exact manifest display and digest-bound interactive decision, non-interactive null decision, absent-resource null manifest, and fail-closed malformed-manifest behavior; focused CLI and daemon wiring cases prove both hosts call those exact shared bytes rather than keeping a divergent copy |
| `apps/loopex_cli/test/daemon_commands_test.exs` | `live command grammar separates host and request flags` | fast | Every accepted and refused live-form flag and combination, numeric endpoints, the offline/live split, exact run/follow-up/steer request sequences, both resource-selection flags refused before a dial, and zero socket dials or facade calls on every parser refusal |
| `apps/loopex_daemon/test/external_socket_workflow_real_test.exs` | `a controller and observer complete the documented daemon workflow against a real provider` | release | The already selected exact manifest case exercises `loopex daemon prepare-index` on a staged legacy root, daemon startup, `loopex run --daemon`, both the already-active and dormant branches of `loopex resume --daemon`, controller and observer `loopex attach`, and the reference CLI's one-page listing, continuation and status output over the socket, so every changed operator command has one discoverable release workflow rather than a separate unselected case |
| `apps/loopex_daemon/test/session_lifetime_test.exs` | `listener failure class follows the begin-accept cut` | fast | Killing the parked listener after its startup acknowledgement and ordering the owner's exact fatal notice before release authorization, including after readiness success is visible, selects `listener_start_failed`, leaves the gate parked and creates no client or wire state; when the sentinel sends exact `begin_accept` first, the first accept error and a later error with one initialized client both select `listener_lost`, and the later case attempts `fatal:listener_lost` to that client |
| `apps/loopex_daemon/test/session_lifetime_test.exs` | `startup dispositions share one sentinel arbiter` | fast | The lifecycle sentinel consumes both orders of stop versus completed success and deadline, and component-fatal notice versus completed success and deadline. Stop first exits `0`; fatal first retains its class; readiness failure first retains `readiness_write_failed`; each leaves the gate parked even if the line is visible and makes later candidates cleanup-only. Release authorization first makes the sentinel send exact `begin_accept`, after which the same signal runs the ordinary orderly stop and the same component loss takes the running fatal path |
| `apps/loopex_daemon/test/socket_transport_test.exs` | `registry owns a connection from its first pid` | fast | The registry is paused inside its serialized start callback after `GenServer.start_link/3` returns but before row bind and unlink; killing the listener makes the child exit, queueing the trapped child `EXIT`, child-monitor `DOWN` and listener `DOWN`. Resuming proves the registry first binds the returned pid, survives, handles those signals idempotently and reaps the exact child, provisional row, socket and slot, while every no-child row is proved to have no connection pid |

**Checks a boundary selects.** Beyond `bash scripts/check.sh`, which every
merge needs green in hosted CI, M5 selects exactly these, from the
[selection table](../developer/verification.md#concept-verification-selection):

- generation 2's schema and vectors select the independent client workflows
  (`--only node_client`, part of `bash scripts/check-release.sh`) and an
  update to `docs/developer/compatibility-surfaces.md` in the same change;
- a new or changed operator command — `loopex daemon`, `loopex attach`,
  and the live forms of `loopex run`, `loopex resume` and
  `loopex sessions` — selects its operator page in the same change and its
  workflow in the release check;
- Outcome 6 is provider and credential handling, so it selects
  `bash scripts/check-release.sh` and its real-provider cases;
- Outcome 6 also changes an operating-system process boundary with the same
  spawn, control-pipe and cleanup shape the executor's has. That row of the
  selection table named only the executor until M5 widened it, so widening it
  is M5's work and not an assumption M5 may make: both verification documents
  change in the same milestone, and the provider cases the row now names are
  `apps/loopex_llm_reqllm/test/provider_launcher_test.exs`,
  `provider_startup_boundaries_test.exs`, `provider_deadline_test.exs`,
  `provider_retainer_boundaries_test.exs` and `credential_plane_test.exs`.
  Those are the cases that run under `bash scripts/fixtures/pinned-load.sh`
  on a Linux host:
  the test VM and eight busy-loop hogs pinned to four cores with
  `taskset -c 0-3`, one process writing 8 MiB with `dd oflag=dsync` in a loop,
  thirty runs, any run past its 60 s deadline counted as a hang, and no
  failure and no hang admitted;
- the Store and recovery keep the local adapter's durable bytes, marker cleanup,
  private port callback, arity and result union; the one adapter change is the
  retained-create read projection through existing `runtime_command/2`, so the focused adapter
  tests, fault injection and old-reader cases cover it;
- `.tool-versions` and the toolchain floor are unchanged, so nothing selects
  the floor row for that reason.

**Closure runs.** At the candidate: hosted CI's green fast check on that
commit is the current-pair Linux evidence; `bash scripts/check.sh` runs once
under the floor pair **on Darwin**, `env -u MIX_BUILD_PATH
MIX_BUILD_ROOT="/absolute/retained-work/M5-otp27-build" mise exec
erlang@27.3.4 elixir@1.18.5-otp-27 -- bash scripts/check.sh`; and
`bash scripts/check-release.sh` runs once on the current pair **on Linux**.
This platform split is required: the Darwin floor run executes
`LOCAL_PEERCRED` decode/fail-closed and the 103/104-byte path boundary, while
Linux CI and release execute `SO_PEERCRED`, the 107/108-byte boundary and the
real second-user witness. The evidence page records the platform beside each
result. The release run needs a second unprivileged user and runs with the
provider credential and the pinned Node version in
`scripts/fixtures/m4/client-toolchain.txt`.

**Each credential-consuming real-provider workflow runs in its own fresh BEAM.**
Reference composition consumes and deletes `LOOPEX_PROVIDER_API_KEY`; a second
production composition in the same VM must refuse rather than find or restore
it. The release shell retains the exported variable and lets each child BEAM
inherit it once. No test, helper or application re-seeds the variable inside a
VM. `scripts/check-release.sh` therefore replaces the application-wide
real-provider pass with an explicit manifest of these independently launched
cases:

| Application and file | Exact case |
| --- | --- |
| `loopex_cli/test/foundation_workflow_real_test.exs` | `public pinned Git import and a real provider complete the admitted skill tool and artifact workflow` |
| `loopex_cli/test/coding_task_test.exs` | `one real provider task streams edits a real repository across several turns and the operator sees the committed result` |
| `loopex_cli/test/coding_task_test.exs` | `one real provider call surfaces the provider's own response identifier and reported usage that the deterministic adapter cannot produce` |
| `loopex_app_server/test/external_workflow_real_test.exs` | `an extracted source archive follows the operator guide to serve the shipped host and complete the chain against a real provider` |
| `loopex_llm_reqllm/test/provider_test.exs` | `one real model call completes through the model boundary` |
| `loopex_reference_client/test/end_to_end_recovery_test.exs` | `one real-provider trace forces a credential-free tool survives an untrappable runtime-tree kill after receipt before fact reconciles one effect without redispatch preserves its fact and completes a second real call` |
| `loopex_reference_client/test/real_model_session_test.exs` | `one real non-streaming model call receives the committed canonical request bytes and digest and completes inside a session` |
| `loopex_daemon/test/external_socket_workflow_real_test.exs` | `a controller and observer complete the documented daemon workflow against a real provider` |

The manifest stores the application, file and exact case name. The script
requires the literal `test "<name>"` definition to occur once, resolves its
current source line, and invokes `mix test <file>:<line> --only real_provider`
in a new operating-system process. Every invocation streams to its own named
log, prints its elapsed time, and must report exactly one executed test; the
script also asserts that all eight manifest rows ran exactly once. Node-only,
long-bound, cross-UID and fresh-source non-provider steps remain separately
selected and run through `env -u LOOPEX_PROVIDER_API_KEY`; only the eight
manifest subprocesses inherit the release shell's credential. The script's
wrapper self-check plants a synthetic value, proves the manifest wrapper sees
the name and the non-provider wrapper does not, and logs only present/absent —
never the value — before any provider call.

Each reference host's fast custody suite also composes its production path
twice in one VM: the first consumes and deletes the variable and the second
refuses `provider_credential_required` without starting another runtime or
child. That witness makes fresh release VMs a consequence of the host contract
rather than a test-runner convenience.

That release check is where Outcome 2's cross-UID witness lives, and it needs
a selector it does not have today. Before M5, `scripts/check-release.sh` runs
each `release_apps` lane as `mix test --only real_provider --only node_client
--include long_bound`. M5 removes that combined lane: the manifest above owns
real-provider cases, `node_client_apps="loopex_app_server loopex_protocol
loopex_daemon"` runs `--only node_client`, and
`long_bound_apps="loopex loopex_executor_local loopex_daemon"` runs
`--only long_bound`. None of those selectors covers a cross-UID case. M5 adds
one — the cases are tagged `@tag :cross_uid` — and the
script runs, on the Linux lane only, for `loopex_daemon`:

```text
(cd apps/loopex_daemon && mix test --only cross_uid)
```

Two cases carry that tag and both must execute: a connection from a foreign
uid refused before initialize, and one from the daemon's own uid accepted.

They are excluded from an ordinary run at the source, on the precedent both
existing helpers set: `apps/loopex_daemon/test/test_helper.exs` ends

```elixir
ExUnit.start(exclude: [:cross_uid, :real_provider, :node_client, :long_bound])
```

— all four, because this application carries cases of all four kinds: the two
`cross_uid` cases here, the real-provider workflow, the Node client, and the
long-duration bound proofs the fast check excludes. That is the same shape as
`apps/loopex_executor_local/test/test_helper.exs`, which excludes
`:real_provider` and `:long_bound`, and `apps/loopex_app_server/test/test_helper.exs`,
which excludes `:node_client` and `:real_provider` so an ordinary `mix test`
needs neither Node nor a credential. The fast check therefore never runs these two, and they run only
when the release check asks for them by name.

**The suite judge's rule is not enough here, so the script asserts the exact
count.** `scripts/suite-summary.sh` fails a lane that executed no test — "a
run that executed nothing is not a pass", as the script's own comment puts it
— but one executed test would satisfy that while the second silently excluded
itself, which is exactly the failure mode a cross-UID case has. So the release
script asserts this lane reported **exactly two executed tests**, and anything
else, including one and including zero, is red. A missing second user is a red
check, not a skipped case.

**And the script has to make a Darwin run visibly incomplete, because today
nothing does.** `scripts/check-release.sh` has no platform branch — `uname`
appears only in its opening banner — and it pipes each lane's suite summary to
`/dev/null`, discarding the very line that would carry an executed count. So
M5 changes the script in two ways:

- it reads `scripts/suite-summary.sh`'s result line instead of discarding it,
  which is what lets any lane assert a count at all — and it reads that line
  **without assuming one toolchain's shape**, because the summary format
  differs between the two supported pairs and a parser fixed to one of them
  would silently read zero on the other, which is exactly the false negative
  an executed-count assertion exists to prevent; and
- it branches on platform for this one lane. On Linux it runs
  `mix test --only cross_uid` and asserts **exactly two** executed. On any
  other platform it runs nothing for that lane, prints
  `cross_uid: not run (<uname -s>)`, and the run's final line is
  `PASS (closure-incomplete: cross_uid not run)` rather than a plain `PASS`.

A Darwin release run is then still useful — it proves everything else — but it
cannot be mistaken for the run closure needs. **Closure requires the evidence
page to cite a Linux run whose final line is a plain `PASS`**, and a
`closure-incomplete` line is not that.

`loopex_daemon` joins the real-provider manifest, `node_client_apps` and
`long_bound_apps` in the changes that add those exact cases. Its cross-UID lane
is the separate Linux-only invocation above. Every selected lane asserts its
own exact or nonzero count, so combining selectors cannot hide an omitted
class. Each run's revision, platform,
toolchain, result and measured duration is recorded on
`docs/evidence/M5-closure-runs.md`, indexed in `docs/evidence/README.md`,
together with the Outcome 6 security review's result, retained-report
reference and digest and the attended demonstration's provider and model
identities. Complete logs and reports stay with the maintainer.

**Documentation the milestone must update.** New: `docs/operator/daemon.md`
and the developer pair `docs/developer/daemon.md` and
`docs/developer/daemon-technical.md`. Materially updated:
`docs/operator/app-server.md`, `docs/operator/coding-sessions.md`,
`docs/operator/runtime.md`, `docs/operator/observability.md`,
`docs/operator/tools-and-policy.md`, the operator pair
`docs/operator/how-a-run-works.md` and
`docs/operator/how-a-run-works-technical.md`, the developer pairs
`docs/developer/app-server-protocol.md` and its companion,
`docs/developer/observability.md` and its companion,
`docs/developer/architecture.md` and its companion,
`docs/developer/runtime-and-embedding.md`,
`docs/developer/agent-loop-and-tools.md`,
`docs/developer/compatibility-surfaces.md`,
`docs/developer/agent-context-map.md`, the verification pair
`docs/developer/verification.md` and
`docs/developer/verification-technical.md`, whose
operating-system-process-boundary row and its case list M5 widens from the
executor to the provider child, the indexes
`docs/operator/README.md`, `docs/developer/README.md`, `docs/README.md` and
`README.md`, `DEVELOPMENT.md`, and `CHANGELOG.md`. `DEVELOPMENT.md` must replace
its old combined release-check selector description with the implemented
fresh-BEAM provider manifest and separate Node, long-bound and cross-UID lanes.
Because the derived two-tree checklist does not include this root file, the
tested scaffold predeclares a separate `DEVELOPMENT.md` review row and closure
cannot fill it as reviewed until its commands and lane counts match the
  implementation. Outcome 6 adds the operator's credential
sentence and the developer note on host composition to the pages that describe
provider configuration.

**Three page-level obligations are named here rather than left to the writer**,
because all three are facts an operator cannot derive from the software and a
reviewer can check against this sentence at closure.

- **`docs/operator/daemon.md` must state the graceful-stop contract as a
  per-root bound, not as one useful configuration-independent operational
  timeout.** The accepted cleanup-grace
  domain reaches far beyond a useful service-manager timeout and a root may
  contain sessions composed under different graces. At closure the page
  explains that the daemon derives and reports its drain budget from the
  root's committed cancellation bounds, records the selected fixed admission
  wait and teardown costs with their maximum-population conditions, and
  recommends an unlimited service-manager stop
  timeout unless the operator intentionally chooses forced cutoff. It states
  the complete successful bound
  `5_000 + admission_wait_ms + 5_000 + 5_000 + 70_000 + budget_ms(root) +
  10_000 + 330_000 + 130_000 + teardown_ms + 30_000 + 5_000`, naming each
  term and its units. It states the distinct **35 s from first fatal latch**
  fail-stop watchdog as an alternative tail after the prefix already spent,
  and distinguishes the Store's usual millisecond release attempt from its
  safety ceiling and from the final placement-release deadline. A finite external
  timeout shorter than that root's reported stop bound is a forced shutdown:
  work that would have settled may not, and the placement lock and writer
  marker may be left for the next daemon's verified recovery. Nothing is written until the
  implementation exists; this row makes closure unable to forget the contract.
- **`docs/operator/coding-sessions.md` keeps every released offline command
  syntax row but corrects its numeric-validation account and links to the new
  daemon page.** `--context-token-budget` is refused before composition unless
  it is a positive unsigned-64 value. The released
  `--cleanup-grace-ms` parser checks only that the value is a positive whole
  number; core enforces the unsigned-64 ceiling when composition reaches the
  runtime, after earlier edges may have started and then been reverse-cleaned.
  The page must not claim both flags fail before runtime work. Its daemon-page
  link sends readers to the separate live grammars without adding a live-only
  flag to an offline syntax row.
- **`docs/developer/app-server-protocol.md`, its companion,
  `docs/developer/compatibility-surfaces.md`, `docs/developer/agent-context-map.md`
  and `docs/operator/app-server.md` must carry the renamed generation string**
  and the one-line migration it implies.

All three are covered by the docs gate, which derives its checklist from
`git ls-files -- docs/operator docs/developer` over **every** tracked file
rather than a Markdown filter, so none of those files can be marked
reviewed-unchanged by accident.

Every other tracked file under `docs/operator/` and
`docs/developer/` is read at the candidate and left unchanged only
deliberately, and the derived checklist in Outcome 5's evidence row is what
makes that auditable rather than asserted.


**Every core change has a core witness, named here to file, case and lane —
six changes, six rows**, matching the surfaces table below one for one.
Session discovery is daemon-owned under the final index decision, so there is
no core listing change or core listing witness.

A downstream witness is not a substitute, and three properties say why:
quiesce's `absent` branch needs a
`Control` entry whose coordinator has already died (`control.ex:821-823`),
`exclude_self/2`'s two fail-closed paths need the tracer mid-restart and `Control` mid-restart, and
`Control` pruning an excluded sender needs that sender's `DOWN`. All three are
core-internal states a daemon cannot construct through the socket.

Core change 3 also reroutes `Loopex.Runtime.trace/2` and the matching trace
stop through `Control`. Start receives the current excluded-pid/MFA snapshot
without calling back into `Control`. Trace creates a private ETS table owned by
the Trace process and stores every full handle returned by
`:trace.session_create/3` only in that table. Its existing internal
`trace_module` option becomes the sole dispatch seam for Trace's named-session
create, function/process selection, delivery, information and destroy calls;
production selects `:trace`, while the test module returns an identifiable
canary-bearing handle and records that the later calls receive that exact
handle. Only Trace accesses the table; the
GenServer callback state carries the private table identifier, normalized
configuration and weak session identities, never a full handle. Consequently
`:sys.get_state/1` can copy the callback state without copying a handle, and a
caller holding the table identifier cannot read the private table. Trace sends
Control only the weak `{name, id}` element split from the newly stored handle,
never a name-selected result from `:trace.session_info(:all)`. Its defensive
`format_status/1` replaces `state`, `message` and `reason` with fixed redacted
atoms and replaces `log` with `[]`, so status and crash formatting cannot
render either table contents or a handle. The witness uses a fake trace-module
handle carrying a unique binary canary, forces Trace to crash, and refutes that
canary across the complete OTP report and owner-observed exit while asserting
the four exact formatted replacements. Control retains normalized
configuration and selected MFAs and monitors the exact Trace pid. Explicit
stop destroys the table-held handle and removes the retained selection only
after Trace acknowledges destruction. That Trace pid's
`DOWN` instead marks the predecessor lost while retaining its weak identity,
normalized configuration and selected MFAs until a replacement resolves the
predecessor and acknowledges the restored snapshot; only `Control` restart
loses that retained state. A replacement first announces its pid/incarnation and stays idle; Control handles
both orders of predecessor `DOWN` and replacement hello, queueing the hello or
proving the old exact pid dead and demonitor-flushing it before it supplies the
retained snapshot. The replacement then verifies each exact weak predecessor
is absent before creating a session and acknowledging. On the production path
the Trace-owned private table disappeared with its owner and released the
predecessor's sole strong handle, so the weak identity is already absent and no
destroy is attempted. A defensive destroy branch exists only for a present
identity; its witness is an explicit fault-injection fixture that retains one
forbidden extra strong handle outside `Control`, a state the production
ownership graph cannot create. A racing
`false` or `:badarg` is accepted only after a fresh all-session query proves
that exact identity absent. Control
promotes one current Trace monitor and publishes start/status only after that
acknowledgement. The internal acknowledgement does not change the experimental
embedded API: `Loopex.Runtime.trace/2` still returns its existing
`{:ok, session_description}` shape, and trace stop and status keep their
existing shapes. This is the mechanism behind the concurrent
start/exclusion witness, not an assumption about the current direct call from
`Runtime.trace/2` to `Trace.start_session/3`. The same change makes pending-call
state total: `:calls` retains no start time because that level requests no
return event; return-bearing levels monitor every pid with retained calls and
purge all of its keys on `DOWN`; managed exclusion waits for the named-session
delivery marker, purges that sender's remaining keys and only then acknowledges
`Control`. Session destruction demonitor-flushes every retained monitor.

| Core change | Core witness | Cases | Lane |
| --- | --- | --- | --- |
| Concurrent attachment (core change 1) | `apps/loopex/test/concurrent_attachments_test.exs` (**new**) | `several attachments under one holder coexist without replacement`; `attachments under different holders coexist`; `one detaching leaves every other attachment delivering`; `holder DOWN and succession release core attachment state` — holder DOWN removes that holder's full attachment set from Control and the dispatcher and releases every transfer; a non-prepared active-session succession through Control.invalidate_attachments/3 removes every session attachment without holder DOWN, releases every transfer before the exact cleanup acknowledgement, notifies each stable holder, and clears core live, pending, repetition and monitor state; `the internal attach-for-holder call installs the supplied stable holder rather than its transient caller`; `a command executed by a relay task is admitted when its stable holder owns any live attachment for the pinned session`; `replace_attachment_id replaces only the named attachment owned by that holder and releases its transfers`; `an unknown, foreign or different-session replacement target is refused`; `an exact live replacement target is reserved once: exact repetition coalesces and a distinct concurrent request refuses without a second borrow`; `the replacement selector is part of repetition binding`; `Control allocates one attachment and incarnation identity at reservation and that exact pair appears in Control pending/live state, dispatcher staged/live state, the returned or repeated handle and cleanup acknowledgement`; `a Control generation change between dispatcher staging and validation discards an ordinary pending attach with both live maps equal`; `replacement refusal at the 512 ceiling preserves core state` — the old attachment and transfers remain live and pending state clears; `post-publication holder death is order-independent` — both Control mailbox orders are forced for ordinary and replacement attaches: publish-ack then DOWN finalizes before ordinary cleanup, while DOWN then publish-ack returns holder_unavailable only after idempotent dispatcher cleanup; both leave equal live sets, zero pending rows and no retained core charge, and neither restores a replacement target; `a post-publication interruption reconciles by transaction identity before returning a result`; `the state-changing half is one deferred infinity Control call whose handle_call returns noreply, whose dispatcher acknowledgements go directly to Control, and whose only terminal reply comes from Control while post_commit remains responsive`; `caller death drops only the reply route and the transaction reaches cleanup`; `one linked preparation worker exists per pending attach, worker death refuses only that transaction, and 512 pending attaches create no 513th worker`; `EventDispatcher death cleans every attachment transaction phase` — death before stage, after stage, after authorization and after publish acknowledgement was sent but before Control consumed it returns attachment_superseded to a live retained embedded caller within the fixed bound, clears predecessor live, pending, waiter, repetition, monitor and borrowed core state, treats late predecessor messages as cleanup-only, never restores a removed target, makes old handles stale and permits a fresh attach after recovery; `replacement registration seeds Control's retained acknowledged event sequence, so an unacknowledged outbox row stays fenced until resolution`; `a replacement stays mailbox-responsive while a linked registration worker talks to Control, accepts and max-merges an acknowledgement while Control is in post_commit, then opens admission only after dispatcher-ready and Control-ready states agree`; `dispatcher death kills its registration worker and no predecessor worker survives restart`; `one backpressuring attachment does not stall another`; `each attachment carries its own cursor and incarnation` | fast |
| Read-only existence and create-history query surface (core change 2) | `apps/loopex/test/session_existence_query_test.exs`, `apps/loopex/test/create_history_query_test.exs`, the shared Store conformance cases for `Loopex.Store.Local` and `Loopex.M1RuntimeTestStore` | existence: `{:ok, :present | :absent | :invalid_id | :store_unavailable}`, each with a byte-identical root, plus a malformed adapter answer proved to normalize to `{:ok, :store_unavailable}` through the Store facade, and exact-Control loss returning only `{:error, :runtime_unavailable}`; create history: `{:ok, {:historical, session_id} | :absent | :conflict | :store_unavailable | :unexpected}` with exact command/options binding, no coordinator and no write, plus the same distinct outer runtime failure; both Store implementations project an exact retained create as `{:completed, %{result: session_id}}`, reject changed options and a cross-kind command ID as `runtime_command_conflict`, and leave durable bytes unchanged | fast |
| **`quiesce/1` and the coordinator change it needs** (core change 4) | **`apps/loopex/test/runtime_quiesce_test.exs`** (new) for the drain, and **`apps/loopex/test/cancellation_test.exs`** (existing; the file that already drives an abort against a receipt arriving mid-reduction) for the coordinator half | `admits every abort before any cleanup begins`; `a coordinator commit during the abort admission is served by Control and its session settles`; `an unlinked quiesce helper crash becomes drain_failed without taking the owner down`; `one abnormal per-session worker affects only that session while siblings finish`; `a phase-owner crash returns runtime_unavailable and leaves no worker or fence-mode coordinator at cuts before the head read, inside the first fence transaction, and before and inside exact re-presentation`; `a suspended ordinary session supervisor cannot block fence start and its later resume creates no delayed coordinator or Store call`; `killing the daemon outer helper ends the monitored phase owner and every linked worker before fail-stop`; `a drained abort commit is presented once and never re-presented on commit_unknown`; `a fresh create executes nine store calls, ten with the retry`; `attach executes one store call over an empty session and two over eight events`; `resume Store-call count includes abort and fence queries` — a twelve-record session containing one committed event executes fifteen Store calls when both current/predecessor abort IDs and both current/predecessor fence IDs are absent — the ordinary eleven plus four status queries — and thirteen when the current abort and fence candidates are terminal; `the reserve-completion callback commits three times on a refused fact and twice on a committed one`; `an abort admission whose reply path settles an open model attempt commits twice and stops`; `quiesce admits no abort into an acquiring entry, and terminates and fences it instead`; `a fence executes three store calls at worst, and an ambiguous abort followed by a fence executes four`; `releases cancellation concurrently once every admission resolves`; `a suspended initial Control gate returns runtime_unavailable inside five seconds and starts no per-session worker`; `sixty-four admission calls are issued together, held through the 65-second work cutoff, killed and reaped by the 70-second outer deadline, release no cleanup, and recover a late deterministic abort rather than treating it as absent`; `sixty-four cleanups receive one release transition and one shared cancellation deadline, with an all-early population advancing when all are terminal and a mixed population advancing once at the deadline`; `an empty active set drains with a zero budget`; `reports a Control entry whose coordinator has died as absent`; `omits an unavailable entry that never entered the writer domain and starts no worker; reports an unavailable writer-domain entry as absent and fences it`; `reports an acquiring entry as unsettled and fences it`; `an acquiring entry whose owner_ready cast is in flight is terminated and reported unsettled`; `settled is read from the coordinator's status, not from the cancellation finishing`; `a cancellation that finished with its terminal commit held is unsettled, not settled`; `fences an unsettled session and refuses its paused transaction as stale`; `fences an absent session too`; `fences a settled session too, and refuses its straggler commit released during the store phase`; `the first census freezes its exact writer-domain projection through fencing`; `uses the monotonic writer-domain set, not unavailable status, so a terminated coordinator is fenced and a never-started entry is omitted`; `an awaiting_owner_barrier owner-group DOWN consumed between censuses answers its waiters runtime_unavailable, retains the same key, starts no ordinary owner and is fenced`; `the first Control call gates create, resume, attach and ordinary routes`; `create and resume forced in both Control mailbox orders either finish their Store and entry-or-dormant decision before the gate or refuse before Store access after it`; `a prompt held after Control routing but before SessionCoordinator.command refuses when the drain call wins its mailbox`; `two concurrent quiesce calls produce one owner and one runtime_unavailable refusal with no second per-session work`; `a fence refused stale_owner_epoch is superseded with no second attempt`; `a fence refused stale_journal_version is superseded too, not an error`; `a live fence owner answering commit_unknown re-presents once with its exact retained binding and a second unknown remains fences[id] == {:unknown, :fence, head}`; `a tx_id_conflict on first fence presentation returns `{:unknown, :fence, head}` with no alternate ID or retry; a tx_id_conflict during exact live re-presentation is an invariant violation and never reports the fence committed`; `a fence id and incarnation recomputed from session id and owner epoch reproduce that live operation's exact transaction; replayed `owner_advanced` reconstruction derives the expected prior head from the stamped journal version, rebuilds `Store.advance_owner/6` and its canonical digest, and compares every durable field because the record carries epochs, incarnation and transaction ID but no digest`; `restart reconstructs fence recovery without retained drain bytes` — a fresh process checks the current-epoch ID and, only on absence or an exactly attributable different-command collision, the predecessor ID, with reconstructed committed, collision/no-fence, terminal non-commit, stale-journal, stale-epoch, both-absent, unattributable-commit and unavailable branches before ordinary successor admission; unattributable or unavailable stays unavailable; `a client command pre-bound to the derived abort ID with a different binding returns `idempotency_conflict`, releases no cleanup, remains unsettled and proceeds to termination/fencing; a session whose abort admission is ambiguous has no cleanup released`; `committed, terminal non-commit, absent in both CAS orders, and unavailable exhaust the abort-unknown outcomes`; `a crash between abort unknown and fencing is recovered before successor admission`; `an admission task shut down mid-call still leaves the coordinator admitting the abort and pausing at the split`; `the status census is bounded by one deadline, not one per session` — sixty-four enumerated sessions whose coordinators never answer are cut at five seconds, killed and reaped to worker baseline by ten seconds, and reported `unsettled` rather than taking sixty-four deadlines; `suspended-supervisor termination reaches baseline before fencing` — sixty-four coordinators start termination together, at 325 seconds directly kill every still-live coordinator and blocked termination worker, consume every exact coordinator DOWN and worker exit by 330 seconds, reach worker baseline before fencing, and after supervisor resume produce no queued start, result or Store call; `sixty-four fence paths begin cancellation at the 125-second work cutoff, have every exact pid and operation absent by the 130-second outer deadline, and permit one ordinary sibling to finish`; `sixty-four writer-domain entries succeed, sixty-five refuse runtime_unavailable before any worker starts, while more than sixty-four no-writer dormant entries are omitted and start no worker`; `a start_child refusal reports no_activation, leaves the session outside the writer-domain set and spawns no fence worker`; `a child start followed by later attach/readiness failure reports activated and remains fence-eligible, with sixty-four such entries filling the activation ceiling and the sixty-fifth refused before start`; `the enumeration carries no Store handle`; `after ordinary coordinator DOWN, a one-shot fence-mode SessionCoordinator is the sole serial owner for abort status recovery, advance_owner and exact fence re-presentation, then exits`, asserted with the helper holding no Store handle; and, in `cancellation_test.exs`, the coordinator half: `a drained abort commits without beginning cleanup`; `a client abort still begins cleanup on its commit reply path` — the pair that proves the split changed the drain and nothing else | fast |
| **`create_session_detailed/3` and `resume_session_detailed/3`** (core change 5) | **`apps/loopex/test/session_detailed_results_test.exs`** (new) | `a create that starts an owner answers disposition activated`; `a completed create replay answers no_activation and starts no coordinator`; `a fresh resume answers activated`; `an open resume-command replay answers activated and charges because it starts an owner`; `a completed resume replay answers no_activation`; `control_entry is observed independently as active, acquiring or dormant`; `exact Control loss before processing returns outer runtime_unavailable with no metadata`; `exact Control loss after child start but before reply also returns only runtime_unavailable, fabricates no disposition or control_entry, and leaves successor recovery rather than a continuing daemon to determine durable truth`; `only a domain result from a live Control authorizes reservation conversion or release and initial directory/index publication, while no_activation under all three control_entry values publishes nothing`; `create_session/3's own return is byte-identical to the released shape` — the case that makes the addition provably additive rather than a facade change; `resume_session/3's own return is byte-identical too` | fast |
| **`Loopex.Trace.exclude_self/2`, `Control`'s excluded-pid/MFA state and `Entry`'s keyword-key redaction** (core change 3) | **`apps/loopex/test/trace_session_test.exs`** (existing; extended), plus **`apps/loopex_llm_reqllm/test/credential_plane_test.exs`** for the adapter-side application-message census | `the named MFAs produce no raw message under an explicitly named module, before any process flag is set`; `an excluded process drains its pre-clear trace signals through :trace.delivered before acknowledgement and produces no post-ack trace message`; `level :calls retains no pending start while return-bearing levels monitor each represented pid`; `managed exclusion purges the sender's pending-call keys at the delivery marker`; `managed and Direct sender DOWN return pending-call state and monitors to baseline`; `destroying a trace session removes that session's process flags and pending-call monitors`; `Trace keeps full handles only in private ETS` — its callback state exposes only the table identifier, normalized configuration and weak identity; Control retains the exact weak element, with exactly one current Trace monitor and no start/status publication before replacement acknowledgement; `a live trace operation succeeds through that private table, :sys.get_state copies no full handle and a foreign process cannot read the private table`; `a fake trace-module handle carries a unique binary canary; Trace format_status replaces state, message and reason and empties log, and the complete forced-crash report plus owner-observed exit contain neither canary nor full handle`; `the rerouted Runtime.trace/2, trace_stop/1 and trace_status/1 preserve their existing public result shapes`; `tracer restart resolves its predecessor before activation` — both mailbox orders of predecessor DOWN and replacement hello keep the replacement idle until Control resolves the exact predecessor; the ordinary predecessor identity becomes absent when its private table releases the sole strong handle, the present-and-destroyed branch uses a separate forbidden-extra-handle fixture, a racing false or badarg is normalized only after an all-session absence query, no shared-name lookup occurs, and the new session reapplies retained pid and MFA exclusions; `the last sender DOWN restores each live session's own selected MFA pattern while a session that never selected the MFA remains clear`; `a new session skips every already-excluded pid`; `fails closed while the capability or Control is immediately unavailable`; `an unanswered exclusion remains pending for the guardian deadline`; `a Control restart stops Trace, whose process-owned private table is the sole full-handle owner, and downstream sender owners together, after which a fresh sender excludes anew`; `the excluded set and ref-counted MFA union return to baseline after the last sender exits`; `a keyword list's value is redacted under its own key`; `the same value under a key naming nothing is rendered, so the case cannot pass vacuously`; adapter case `custody reply is the sole credential-bearing BEAM message` holds custody after it accepts the request, suspends the raw Task sender inside its waiting `GenServer.call`, and uses a short-lived isolated inspector over `Process.info(sender, :messages)` to observe the exact `{call_reply_tag, {:ok, %{credential: canary}}}` wrapper after enqueue and before receipt; the inspector returns only a non-secret verdict and is terminated and awaited, every other application-message payload plus registry and guardian state is canary-free, and after the frame write the sender's exact `current_function` and stack identify the non-secret tail-called final wait while its mailbox, dictionary and complete forced-crash material remain canary-free before `:credential_frame`, without any raw-Task state or call-trace-absence claim | fast |
| **Managed provider lifetime** (core change 6) | **`apps/loopex/test/provider_lifetime_test.exs`** (new), plus **`apps/loopex_llm_reqllm/test/credential_plane_test.exs`** | `managed scope starts an inert guardian and an inert sender sequentially as direct temporary owner_workers children, with at most one linked start proxy alive`; `start proxies transfer one exact child at a time` — each reports the exact start_proxy_result tuple for guardian or sender, reference, proxy pid and either the exact child pid or unavailable; the callback accepts only that matching result plus the exact child acknowledgement, monitors the child from first pid disclosure and consumes proxy normal DOWN before continuing, so no second proxy overlaps; `the three legal start orders are child acknowledgement then result then proxy DOWN, result then child acknowledgement then proxy DOWN, and result then proxy DOWN then child acknowledgement; same-sender ordering forbids proxy DOWN before its result`; `a starter refusal and a caught starter exit follow that same unavailable result and reverse-clean an acknowledged child`; `the guardian initial argument is exactly guardian_ref, callback-owner pid and stop_reference`; `the sender initial argument is exactly sender_ref, callback-owner pid, guardian pid and tracing capability`; `suspending owner_workers before guardian materialization, ending the scope and resuming produces only an inert late guardian and every count returns to baseline`; `pausing guardian start acknowledgement before Core registration and killing the callback produces no registration or provider action`; `Core registration returns the exact retainer and cleanup grace, the guardian installs that monitor and acknowledges authorization before sender start`; `every private gate uses the exact tagged guardian-started, authorize-guardian, guardian-authorized, sender-started, authorize-sender, sender-adopt, sender-adopted-by-guardian and sender-adopted tuple with the expected reference and pid`; `late sender materialization stays inert after Core stop` — holding sender materialization after registration while Core sends its exact stop request yields the stop acknowledgement and guardian DOWN; resuming owner_workers creates only an inert late sender that sees callback or guardian loss and exits, with every population at baseline; `sender start, guardian adoption and sender adoption-complete acknowledgement are separate cuts, and initialize cannot race either`; `pre-transfer child death returns unavailable without a monitor gap` — guardian or sender death after first pid disclosure and before transfer completion reaches the callback child monitor as unavailable; the callback demonitor-flushes only after the retainer owns the guardian monitor or the guardian owns the sender monitor; `immediate refusal at any gate returns unavailable, reverse-cleans partial children and never raw-spawns`; `a non-answering start remains owner-group liveness rather than adapter timeout`; `normal callback completion after both transfers leaves the guardian retained and the sender governed by the guardian, not callback DOWN`; `the adopted sender parks until exact provider readiness, so pre-ready refusal or guardian death performs no exclusion, sink, route, custody or frame work`; `provider continuations retain identity phase and deadline` — release, bootstrap result, credential context, every phase result and every continuation use the exact sender_ref/guardian-pid/sender-pid binding; continuations also carry the exact phase and unchanged deadline, and wrong-ref, wrong-pid, wrong-phase, changed-deadline and stale-replay injections never unpark, route or write; `managed setup consumes and never resets the absolute invocation deadline, release after 5 seconds but before that instant succeeds, and expiry after initialize returns timeout`; `guardian accepts completions only before the absolute deadline` — before accepting provider readiness, bootstrap or phase results, and before emitting credential context or a continuation, the guardian rechecks monotonic now before deadline; paired mailbox orders prove a completion consumed before the instant advances once, one consumed at or after it is cleanup-only timeout even when queued first, and the timer only prompts the check; `after begin_bootstrap the sender keeps trap_exit false, completes exclusion before starting a sink that is linked for abnormal exit and monitors the sender for normal exit, and both pids are clear before token delivery`; `normal sender success and abnormal or kill exit each return the sink population to baseline`; `abnormal guardian death while the sender is parked or post-readiness sink installation is blocked ends sender and sink, restores Control and Trace baselines, and delivers no token, handle, channel context, frame or raw trace canary`; `normal guardian cleanup explicitly stops and awaits the sender`; `only the adapter-minted direct/no-runtime mode retains the existing raw-spawn fallback`; `killing Control while a sender is paused after custody reply delivers guardian and sender DOWN before the replacement tracer appears`; `a fresh sender succeeds after restart`; `ordinary completion leaves no guardian, sender, start proxy, receiver, generic phase-send helper, sink, Port, carrier, guard or provider BEAM behind, and every member's population returns to baseline`; `credential_plane_test.exs: credential frame result is emitted only from a non-secret final wait` holds the raw sender after the frame write, uses `Process.info(sender, [:current_function, :current_stacktrace])` to identify the exact tail-called final-wait MFA, refutes the canary from its mailbox, process dictionary and complete forced-crash material, and only then permits the exact `:credential_frame` result; `credential_plane_test.exs: only final-state normal sender DOWN starts invocation` proves the final continuation permits only normal exit and only that exact normal `DOWN` before the retained deadline starts the generic invocation helper; `credential_plane_test.exs: sender DOWN and final-deadline cuts never start invocation` forces raise, exit, kill and early normal exit before expiry to `:unavailable`, consumes the same `DOWN` after the guardian clock reaches the instant as `:timeout`, and expires the final continuation with no helper | fast |

The paused-transaction case in `runtime_quiesce_test.exs` pauses the
transaction through core's own controllable store, not the shipped adapter:
`apps/loopex` depends on nothing but the protocol and telemetry
(`apps/loopex/mix.exs:34-36`), the dependency direction forbids a test-only
edge to a store implementation, and `Loopex.M1RuntimeTestStore` already holds
a transaction pending outside its process for exactly this order
(`hold_next_record_before_linearization/3`,
`apps/loopex/test/support/m1_runtime_helper.exs:40-46`) and refuses a stale
`advance_owner` with `:stale_owner_epoch` (`:598-599`). It stays a core test
because what it proves is core's fence; the shipped adapter's own
`:before_linearization` probe (`local.ex:252`) is the same seam for the
adapter's suite, not for this one.

**The downstream witnesses stay**, and their job is different: the daemon's
lifetime suite proves the drain happens in the stop sequence a real operator
triggers, and the adapter's credential suite proves a real invocation is not
traceable. Neither can reach the branches above, and neither is asked to.

**Every bound the implementation derives from a call count carries a witness
that executes the path and asserts the count.** This is a rule of this plan
rather than a remark about one case, and it exists because two independent
readings of the create path produced two wrong numbers before a traced run
produced the right one: six by reading, then nine — ten with the retry — by
executing. A count read off the source is a hypothesis; only a run is
evidence, and a bound built on a miscount is a bound the stop silently
exceeds.

**The plan itself now states no such bound.** The maintainer withdrew the
derived stop arithmetic on 2026-09-20, and what the drain costs is measured at
implementation. The rule survives for the implementation, which does state
bounds: each one is asserted by a case that **counts adapter calls while the
path runs**, by tracing the adapter module —
`:erlang.trace_pattern({Loopex.Store.Local, :_, :_}, true, [:global])` where
the adapter is reachable, and the suite's controllable store's own call log
where it is not (`Loopex.M1RuntimeTestStore`, which core's tree can reach and
`Loopex.Store.Local` is not) — and asserts an exact number, not a bound. The
executed counts this plan already holds are the ones named in the `quiesce/1`
row of the evidence table above: a fresh create's nine Store calls, ten with
the retry; an attach's one over an empty session and two over eight events; a
resume's fifteen over a twelve-record session containing one committed event
on the path where both plausible abort IDs and both plausible fence IDs are
absent — the original eleven plus two abort-status and two fence-status queries
— and thirteen when the current abort and fence IDs are terminal; a shutdown
fence's three at worst.

Those are **core** witnesses, because those paths are core's: the daemon
contributes no Store call of its own to any of them. A case that asserted "at
most N" would pass on a path that had grown shorter *or* been restructured
into something the count no longer describes; asserting the exact number is
what makes a later change to the path fail here rather than at an operator's
`TimeoutStopSec`.

**Test honesty.** Future test bodies are written with their implementation; a
missing witness is never a pass. **Every witness named in this plan pair names
three things: the exact file, the case
name, and the lane it runs in** — `fast` for `bash scripts/check.sh`,
`release` for `bash scripts/check-release.sh`, and `attended` for the two
release cases that need a person. A witness described only by what it asserts
is a witness nobody can find at closure.

**The rule is the plan's, not the ADRs', and an earlier revision extended it
to both and then named an enforcement point that cannot enforce it.** ADR
0031, 0032 and 0033 describe their evidence in prose, as accepted ADRs in this
repository do, and rewriting three proposed ADRs into three-column tables buys
nothing a reader needs: the decisions are what those files are for. So the
obligation sits where the tables already are — **this pair's core-witness
table carries the file, case and lane for every witness the ADRs describe**,
and a witness an ADR names with no row there is a gap this pair closes, not a
defect in that ADR. It is that table specifically, and not the Outcome rows:
those name a witness **file** per outcome and then describe what it must
prove in prose, which is the right shape for an outcome and the wrong one for
finding a case by name. That is the smaller of the two changes and it is the one taken.

And the enforcement point is **review**, stated plainly. The earlier revision
pointed at the derived documentation checklist in Outcome 5's evidence row,
which lists every tracked file under `docs/operator/` and `docs/developer/`
and reads none of them for test identities — it could not check this and was
never going to. An independent reviewer reading the candidate against these
tables is what checks it, as it is for every other claim in this pair. Real-provider cases live in their own files
under the `real_provider` tag. A daemon that proxies several socket
connections to one replaceable core attachment cannot satisfy Outcome 4,
because independent concurrent attachments, lifetime with zero attachments,
fencing after a real kill and cross-process abort are each required
separately. Build the first integrated workflow early — one daemon process,
two independent socket clients, one creating and driving a session and one
attaching while the daemon still owns it, with the second client's correlated
snapshot carrying a top-level `event_cursor` equal to
`snapshot.event_sequence` at or beyond the committed tail — then add the
boundary and failure cases as the implementation reaches them.

<a id="technical-plan-compatibility"></a>
### Compatibility

Concept: [Rollout and compatibility](M5.md#concept-plan-rollout).

The `v0.2.0` source tag identifies a numbered release, not a compatibility
freeze; all surfaces remain experimental. The socket reuses ADR 0023's
framing, handshake, limits, and its admission, snapshot, event and progress
records unchanged. Its **request** records are reused with one addition, not
unchanged: every existing-session mutation in generation 2 carries
`writer_epoch`. The exception is stated because a **reader of the DTO tables**
would otherwise take "records reused unchanged" literally and build a request
without that field. It is **not** stated because the digest would catch it:
`schema_digest/0` hashes the generation, the ordered method *names*, the
ordered record-family *names*, the ordered error-code *names* and the limits
(`session.ex:192-199`, with the family list at `:53-61`) — no request field
appears in it, so an added field changes no digest. An earlier revision said
the digest was the place a reader checks it, which was false in the one
direction that matters: the digest would have let this through. Generation 2 is additive
over generation 1's method set under the exact-generation rule: a generation-1
client sees no daemon method and no lease field, the daemon refuses a
generation-1-only initialize, and the foreground server keeps serving
generation 1 unchanged. No mixed-generation stream is promised. The private
journal, its adapter and its format are unchanged; public events, snapshots,
artifact formats and the executor protocol are unchanged.

**The embedded API's *shape* is unchanged, but three transient behaviours
change**, which an earlier revision folded into "the embedded API is unchanged"
and thereby denied. `Loopex.attach/3` (`loopex.ex:134`) keeps its arity and
result and gains only one optional attach option,
`replace_attachment_id`. Today the dispatcher supersedes unconditionally: it
splits `state.attachments` on `session_id` alone
(`runtime/event_dispatcher.ex:812-818`), and no replacement selector exists in
core. After core change 1, a second attach without a selector leaves both
attachments live, including when the same holder owns them. A replacement
names one attachment identity, is admitted only when the same stable holder
owns that attachment for the same session, and removes only that target. A
boolean replacement flag is insufficient because one holder may own several
attachments and there is no implicit ordering that can select one.

That targeted attach-time rule does not remove the existing succession cut.
`Control.invalidate_attachments/3` still runs on every non-prepared owner
succession, while `carried_attachment/2` preserves the prepared case. Core
change 1 turns the present fire-and-forget cast into an acknowledged
transaction: Control clears the old command routes and retains the exact
attachment identities and stable holders; EventDispatcher removes every
matching live or pending row, kills its preparation and read workers, releases
every transfer opened by each removed attachment as ADR 0028 requires, and
acknowledges those identities. Only then does Control notify each live holder
and clear its retained repetition and monitor state. A pending embedded attach
caller receives `attachment_superseded`; a generation-2 attach transaction
maps that core result to the existing correlated `attachment_conflict` wire
error, adding no error code or schema-digest input. An installed embedded
handle becomes stale.

For a generation-2 holder, the connection registry owns the final side of that
transaction. It retains the attachment charge until the exact core cleanup
acknowledgement and holder notification join, releases the charge idempotently
by attachment identity even if holder `DOWN` races, attempts one uncorrelated
`detached` record carrying the session ID and last completely emitted cursor,
and leaves that connection open. This is the fourth generation-2 `detached`
occasion. A controller's lease, epoch and deadline remain unchanged; the
attachment gate refuses its next mutation until that same connection
reattaches. Unlike the three single-attachment eviction occasions, a
succession may notify every connection attached to that session; no unrelated
session is affected.

Source `VERSION` is distinct from protocol generation, provider build and
schema digest.


**The generation strings are renamed, and generation 1's is one of them.**
M5 serves `loopex.experimental/2` on the socket — the name ADR 0032 already
fixes — and **renames the released generation-1 string
`loopex.session.v1-experimental` to `loopex.experimental/1`**. That is a
break in an experimental surface, taken deliberately under the 0.x policy the
vision states: "Experimental APIs may break in a minor release with explicit
migration notes" (`vision-technical.md` § 24.2), and `0.2.0` is a minor
release.

The reason is collision rather than tidiness. The vision reserves "public
protocol v1" for the *stable* protocol, which cannot freeze until the daemon,
the ACP mapping and extension namespaces exist. An experimental line numbered
`v1` and then `/2` would be two numbering schemes racing toward the same name,
and the first stable release would have to explain why its `v1` is not the
`v1` that shipped in 0.1.0. `loopex.experimental/N` numbers the experimental
line on its own and leaves the stable name unclaimed.

**No accepted decision binds the literal, so this is a plan decision and not
an amendment.** That was checked rather than assumed: the string
`loopex.session.v1-experimental` appears in **no** accepted ADR and nowhere in
the vision pair — ADR 0023 fixes that client and server "agree on one
experimental protocol generation, exact" and that "source version and protocol
generation are independent" (`0023-…md:116-118`) without ever writing the
name, and ADR 0024 does not mention generations at all. The only ADR that
carries a generation string is ADR 0032, which is Proposed with this
milestone and states the rename itself — so **ADR 0032's acceptance is what
authorizes the change to a released generation name**, and it is the right
place for it: that ADR fixes generation 2 and its negotiation, and the rename
is the other half of the same naming decision. ADR 0023 stays accepted and
unedited, and nothing supersedes it: it never named the string, so nothing it
says stops being true.

**Now is the cheapest moment**, which is the other half of the decision.
Workstream 3 keeps `LoopexProtocol.Session` as the generation-1 compatibility
facade and adds `LoopexProtocol.Session.V2` as the daemon's explicit generation-2
contract, with both digests pinned side by side; the generation-1 string is a
module attribute in exactly that work.
Renaming later would mean a second pass over the same module, the same
vectors, the same clients and the same documents.

**The rejected option is recorded:** keep `loopex.session.v1-experimental`
beside `loopex.experimental/2`. It was rejected because the two shapes would
then coexist for as long as generation 1 is served — which is the whole of
0.2.x and beyond — so every client, document and vector would carry both
conventions, and the collision above would still be waiting at the freeze.

**What that costs, exactly.** Generation 1's **contract** is unchanged: the
same methods, the same record families, the same error codes, the same limits.
What changes is its **name** — and the name is one field in the canonical map
`LoopexProtocol.Session.schema_digest/0` hashes (`session.ex:192-199`), so
generation 1's **schema digest** changes with it. All three assertions that pin
that digest move: `public_schema_conformance_test.exs:291` and `:351`, and
`session_schema_test.exs:116`.

**The two manifests do not move, and the reason is the strongest argument for
this decision.** `apps/loopex_protocol/priv/schema/loopex-experimental-1.json`
and `apps/loopex_protocol/priv/vectors/loopex-experimental-1.json` — the files
an independent client fetches and verifies, pinned by file digest at
`public_schema_conformance_test.exs:297-298` — contain **no occurrence of
`loopex.session.v1-experimental`**. They already declare
`"generation": "loopex.experimental/1"`, and the schema manifest also declares
`server_records.initialized.selected_generation` as `loopex.experimental/1`.

So the released surface is **already inconsistent with itself**: `session.ex:32`
serves `loopex.session.v1-experimental`, the conformance module pins that
string at `:282`, and the digest-pinned manifests those same clients read say
`loopex.experimental/1`. Nothing catches it, because the conformance test pins
each manifest by its **file digest** and never compares the generation-1
manifest's `/generation` with `LoopexProtocol.Session.generation()`; M5 adds
the corresponding `LoopexProtocol.Session.V2.generation()` assertion for the
generation-2 manifest.

That reframes the rename. It is not a break introduced for tidiness; it is the
change that makes the **code agree with the artifacts already published beside
it**, and it closes a live discrepancy in a released surface rather than
opening one. The manifests are the thing being conformed to, not files to
edit.

The plan says all of this wherever it used to say the generation-1 pins were
untouched, because a reader who trusts that sentence would read a failing
build as drift. The three schema-digest assertions move; the two independently
computed manifest file-digest pins do not.

Outcome 6 changes one experimental public helper behavior. The
`complete_prompt/3` arity and result union remain, but an environment-only
options list now refuses; a caller composes ephemeral custody and a routing
registry and passes their token and handle. The `Loopex.Model` callbacks, the
private provider codec's version and frame kinds, and the build manifest are unchanged.
ADR 0019's provider child, Port, OS guard, private channel, launch-time
enumeration and scrubbing, failure teardown and forensic disclaimer remain;
ADR 0034 narrowly changes the credential source and resolution point and puts
managed guardian/sender processes under `owner_workers`. Its one compatibility effect is on host
composition: an embedder that relied on the adapter reading the environment
for it passes a credential token with the call instead, over a registry and custody it composes, and gets the
adapter's ordinary refusal to dispatch rather than a silent fallback if it
does not.

<a id="technical-plan-migration"></a>
### Migration and Rollback

Concept: [Rollout and compatibility](M5.md#concept-plan-rollout).

No journal migration exists in M5. The daemon reads and writes the same local
log the M4 foreground server and the CLI write, under the same placement
identity. That makes daemon-to-foreground rollback direct. The first move of a
populated M4 or `0.1.0` root with no daemon index into M5 requires the one-time
`loopex daemon prepare-index` import; ordinary daemon startup refuses it until
that succeeds. The import's daemon-owned strict reader validates every
non-temporary legacy entry and refuses the whole import before publication
rather than inheriting the released listing projection's skip-invalid behavior.
Once a valid index exists, later switches need only stop the
current surface before starting the other. On a healthy orderly daemon stop, prove
writer-marker absence and immediate foreground-server and CLI reopen rather
than inferring release from `terminate/2`; then resume a daemon-created session
with identical replay. A separate injected removal/sync failure proves the
complete residual follows verified stale-writer recovery.

A root that reaches the local log's 256 MiB capacity is retired, not migrated.
The daemon has already exited by then, because the capacity refusal terminates
the store; the operator moves the root aside and starts a fresh root. A root already past
that bound refuses at open with `store_log_too_large`, which is the message
the operator page must explain, because it is what an operator meets when a
root grew past the ceiling under an earlier process. A session in a
retired root is reached only by reopening that root.


**M5 owes two migration notes, and the first is one string.** A `0.1.0` client
sends `loopex.session.v1-experimental` in its `initialize` generations list.
Against a `0.2.0` server that list has no common generation, so the server
refuses with `unsupported_generation` — the refusal ADR 0023 already defines
for exactly this — and the client's remedy is to **reconnect** and send
`loopex.experimental/1` on the new connection. Reconnecting is part of the
remedy rather than a detail: ADR 0023 gives a refused connection no second
negotiation attempt and leaves it uninitialized
(`0023-…-technical.md:357-358`), so a client that retried `initialize` on the
same socket would be refused again for a different reason. Nothing else about that client changes: same framing, same methods,
same limits, same records. **The repository's own Node client is updated in
the same change**, so the independent-client evidence is written against the
new string rather than against a shim.

There is no compatibility mode and none is offered: accepting both strings for
one generation would put two names on one contract, which is the thing this
rename exists to stop, and it would have to be removed later anyway.

**The second note is for embedded callers, and it is one behaviour.** A
caller that relied on `Loopex.attach/3` superseding an earlier attachment to a
session retains that earlier handle and passes its attachment identity as
`replace_attachment_id`. The same stable holder must own the target, and an
unknown, foreign or different-session target is refused. Omitting the selector
creates another live attachment where the old implementation removed one, so
callers that depended on implicit replacement must change. Callers that
attach once per session need no change. Rollback is symmetric: a root carries
no attachment state, so reverting core change 1 restores the old transient
behaviour for the next runtime.

**Rollback is unaffected by the rename**, because a generation string is
negotiated and never persisted. A root written by a `0.2.0` daemon carries no
generation name anywhere, so removing the daemon restores the `0.1.0`
foreground server on the same root exactly as it would without this decision;
what a `0.1.0` *client* then talks to is a `0.1.0` server, which speaks the old
string again.

**Seventeen files carry the string today; the rename edits thirteen**, named
here so workstream 3 can be checked against a list rather than a grep:
`apps/loopex_app_server/lib/loopex_app_server.ex` and its three tests
(`app_server_test.exs`, `initialization_test.exs`, `stdio_probe_test.exs`);
`apps/loopex_protocol/lib/loopex_protocol/session.ex:32` with
`public_schema_conformance_test.exs` and `session_schema_test.exs` — **and
not the two `priv` manifests**, which already carry the new name and are what
the code is being made to agree with;
`clients/node/loopex-client.mjs`; and the documents
`docs/developer/agent-context-map.md`,
`docs/developer/app-server-protocol.md` and its technical companion,
`docs/developer/compatibility-surfaces.md`, and `docs/operator/app-server.md`.
The documents are closure obligations under the docs gate, which reads every
tracked file in `docs/operator` and `docs/developer`, so none can be missed.

**Four carriers are deliberately *not* rewritten, which is why seventeen and
thirteen are both right.** `CHANGELOG.md` carries the string in the entry that
records what `0.1.0` shipped, and that
entry stays true: `0.1.0` did serve `loopex.session.v1-experimental`. The
rename is recorded as a **new** `0.2.0` entry instead, so the changelog is
touched without that occurrence moving. The other three are **inside this
planning set**, each carrying the retired name only in the passage that
explains why it is being retired:
`docs/adr/0032-daemon-attachment-residency-and-replay-technical.md`,
`docs/plans/M5.md` and this file. They are changed by this milestone's own
planning work rather than by workstream 3's search-and-replace, and they are
counted here so a reviewer running the grep finds seventeen and reads it as
agreement rather than as drift. Earlier revisions said fourteen, then
fifteen, each time counting the carriers they had happened to look at.

Rollback to `0.1.0` is stopping the daemon. Removing it restores the M4
foreground server and the CLI on the same root with no durable dependency on
residency or lease state. The daemon's bounded index is a separate advisory
file: released foreground surfaces ignore it, and rollback may leave it in
place or remove it while the daemon is stopped without changing journal or
session truth. A daemon-owned root is an ordinary local root once the daemon is
gone and the next opener either observes the placement lock and writer marker
absent or applies their verified stale-owner recovery; a root whose placement
lock or marker remains after a dead daemon is released only by that lock's
existing liveness-probe discipline and its live/unverifiable refusals. M5 does
not change either on-disk record or recovery rule. Outcome 6's rollback is reverting the adapter change; nothing
durable records which mechanism delivered a credential to a process that has
since exited. No in-place downgrade, installed-data migration or
service-manager claim exists.

<a id="technical-plan-packaging"></a>
### Packaging

Concept: [Rollout and compatibility](M5.md#concept-plan-rollout).

Add exactly one application: `loopex_daemon`, the eleventh, with role
`:client`, depending inward on core, protocol and composition and reusing the
foreground server's protocol mapping. The application inventory and the role
rules in `apps/loopex/lib/mix/tasks/loopex.deps_budget.ex` and its cases in
`apps/loopex/test/deps_budget_test.exs` change in the same reviewed change
that adds the application, and `mix loopex.deps_budget` proves the direction.
M5 adds no new dependency package; it updates the existing `req_llm`
constraint to `~> 1.24.0`. No transport library, socket abstraction layer
or service-manager integration enters any application. The socket lives in a
`0700` daemon-owned `daemon/` subdirectory of the state root, which the daemon
creates and whose mode it verifies; the state root's own mode is read and never
changed, so a root the foreground server created `0755` is served unchanged and
the no-migration claim holds. The socket is the
runtime's own, on OTP's `:socket` API for the local address family. The
classic `inet` backend is not sufficient here and the choice is not a
preference: the peer-credential read ADR 0032 requires is a socket option, and
the classic backend exposes neither the named option nor the raw one, while
`:socket` exposes `getopt_native/3`. Either `:socket` directly or `gen_tcp`
over the socket backend with its handle reachable satisfies this; no library
is added either way.

Supply `loopex daemon`, `loopex attach`, live forms of `loopex run`,
`loopex resume` and `loopex sessions` in the reference CLI, on the contracts
below, and extend the client in
`clients/node` to connect over the socket, to follow as an observer and to
take over. It stays a plain client with no build
step, package manifest or dependency, as the maintainer decided for M4 on
2026-09-15. The Node version stays pinned in
`scripts/fixtures/m4/client-toolchain.txt` and `scripts/check-release.sh`
continues to verify it before any client runs; the release check's application
list gains `loopex_daemon` in the same change that adds its release cases.

**The archive must be able to build itself.** Today it cannot, and this is
work M5 owes rather than a property it can assert. Both build paths demand a
`.git` directory: `apps/loopex_cli/mix.exs` matches `{source, 0} = System.cmd
("git", ["rev-parse", "HEAD"], ...)` at line 34 and again at line 80, with
`git status --porcelain=v1 --untracked-files=all` at line 83, and
`Mix.Tasks.Loopex.Provider.Build`'s `clean_source!` does the same at
`loopex.provider.build.ex:120-125`. A `git archive` extraction has no `.git`,
so every one of those matches fails and the documented CLI build cannot run
from the extraction the closure candidate must build from.

M5 therefore adds an archive-carried source identity that both paths accept,
and one shared resolver they both call:

- a tracked `SOURCE_IDENTITY` file with exactly these bytes, including the
  single ASCII spaces and final LF:

  ```text
  commit $Format:%H$
  committer-date $Format:%cI$
  ```

  `.gitattributes` contains the exact attribute entry
  `SOURCE_IDENTITY export-subst`. In an archive the first value must be one
  lowercase 40-character hexadecimal object name and the second must be the
  strict ISO-8601 committer date emitted by Git's `%cI`, including its numeric
  offset: the calendar-valid ASCII shape
  `YYYY-MM-DDTHH:MM:SS+HH:MM` or `YYYY-MM-DDTHH:MM:SS-HH:MM`, with every
  letter standing for exactly one decimal digit. The parser accepts those two fields once, in that order, with no
  unknown field, duplicate, blank line, alternate separator, or trailing byte
  after the final LF. Closure compares the complete expanded file with the
  final-LF-terminated output of
  `git show -s --format='commit %H%ncommitter-date %cI' <candidate>`.
  What `export-subst` does,
  stated because the refusals below depend on it: `git archive` rewrites
  `$Format:…$` placeholders **inside a file's contents** as it exports, so the
  extracted copy carries the exact commit while the copy in a checkout keeps
  the unsubstituted literal — which is why an unsubstituted value is a
  reliable "this was not exported" signal rather than a formatting accident.
  It substitutes only into files marked `export-subst`, and only the
  placeholders `git log --format` defines, so the mechanism cannot be extended
  to carry a path list — which is why the inventory lives outside the
  archive;
- a resolver that prefers git when `.git` is present — the existing behaviour,
  unchanged, including the clean-tree requirement — and otherwise reads
  `SOURCE_IDENTITY`;
- three refusals in the archive case, each with its own stable reason and none
  of them a fallback to building anyway: the file is **missing**; the file is
  **unsubstituted or malformed**, which is what a hand-copied checkout file or
  a hand-written one looks like, since anything but one lowercase 40-character
  hexadecimal commit id and a commit date is refused; or the extracted tree
  **changed during the build**, which is the property `git status` buys in a
  checkout and which the resolver has to buy some other way here, because an
  extraction has no git index to ask what is tracked;
- the provider build manifest embeds the resolved commit id together with the
  `sha256` digest of the canonical pre-build extraction manifest defined
  below. That digest is the term **source digest** everywhere in this pair, so
  an identity naming a commit whose tree is not what was built is detectable
  rather than merely trusted.

**The unchanged-tree check needs an inventory, and the inventory cannot ride
inside the archive.** An earlier revision said the resolver hashes "the
extracted tracked source paths" — but *tracked* is a fact held in `.git`, and
`git archive` leaves none. A later one put a tracked `SOURCE_INVENTORY` in the
archive, "generated at the moment the archive is staged", which cannot happen
either: `git archive` exports the **committed** bytes of tracked files, and
`export-subst` substitutes a fixed set of `$Format:…$` placeholders into a
file's contents — there is no placeholder that expands to a path list, so a
tracked file cannot learn what the tree contains at staging time. Both designs
asked the extraction to carry an answer only the repository has.

So the inventory stays **outside** the archive, with the party that has the
repository:

- **the closure evidence records the candidate's source-path inventory**: the
  output bytes of `git ls-files -z` at that commit are retained outside the
  repository. The frozen `docs/evidence/M5-closure-runs.md` scaffold records
  their source SHA, entry count, stable retained-output reference and SHA-256
  digest beside the archive's own digest and commit. The closure runner is in
  the checkout when it stages the archive, so this costs one command it is
  already positioned to run;
- **before the build, the extraction's regular-file and symbolic-link path
  set**, excluding only `_build/` and `deps/`, is emitted NUL-delimited and
  compared exactly with the recorded `git ls-files -z` inventory. Directories
  are excluded from this comparison because Git does not track them;
- **the extracted-build witness separately compares a canonical manifest**,
  taken over the extraction before the build and again after, and requires the
  two to be identical. M5 adds `scripts/source-archive-manifest.sh` as the one
  repository-owned producer. It accepts exactly one extraction-root argument,
  walks with `lstat` without following symbolic links, collects the complete
  result before writing, writes only manifest bytes to standard output, writes
  diagnostics to standard error, and exits nonzero on an unsupported entry or
  incomplete walk. Its only exclusions are the exact top-level `_build` and
  `deps` paths and their descendants; a nested path with either basename is
  included. The manifest is one record per path, **NUL-separated**
  so no filename containing a newline or a quote can forge a boundary, holding
  the **path**, its **kind and canonical source mode**, and
  either the **SHA-256 of its contents** or, for a link, its **target**. A
  digest over contents alone would miss a file made executable, a regular
  file replaced by a link to one, or a path that appeared and another that
  vanished; the path set, the kind and the mode are what close those, and the
  before/after pair is what catches a build that writes into its own source
  tree. Its byte grammar is fixed: records sort by raw path bytes; each record
  is `kind NUL mode NUL path NUL value NUL`, where `kind` is `f`, `l` or `d`.
  For `f`, `mode` is `755` when any extracted execute bit is set and `644`
  otherwise; for `l` and `d`, it is the fixed value `0`. This retains the one
  executable distinction Git records while making the stream independent of
  extraction umask and platform-specific link or directory modes. `path` is relative to the
  extraction root, and `value` is the lowercase SHA-256 hex digest for a
  regular file, the raw link target for a symbolic link, or empty for a
  directory. POSIX paths and link targets cannot contain NUL, so the stream is
  unambiguous. **Source digest** is the lowercase SHA-256 hex digest of this
  complete pre-build byte stream. The exact path-set comparison above is what
  ties the extraction to the commit; the richer manifest proves the build did
  not change kind, mode, content, link target or directory structure;
- exactly **one** exclusion rule, named rather than implied: the two build-output roots
  `_build/` and `deps/`, which the build is supposed to create. Nothing else
  is excluded, and the list of exclusions is part of the retained evidence, so
  a later exclusion cannot quietly widen what "unchanged" means. Every
  invocation redirects standard output to a retained path outside the
  extraction, so the output file cannot enter the walk or make the manifest
  self-referential.

The extracted tree therefore needs to carry only `SOURCE_IDENTITY`, which
`export-subst` genuinely can fill, and the inventory is evidence rather than a
build input — which is also the more honest arrangement, an inventory shipped
inside the thing it describes being checkable only against itself.

Its witness is the one neither earlier design could have: a file is
created **inside the extraction and outside the excluded roots** during the
build, and the comparison against the recorded inventory is asserted to
**refuse** with the changed-tree reason — where the same build without it
succeeds. A missing or empty recorded inventory is itself a closure refusal,
on the same rule as an unsubstituted identity, so a check that compared
against nothing cannot read as a pass.

The **mismatch** case is proved where the external truth exists: the release
check stages the archive with `git archive` from a known commit, retains the
archive's SHA-256 and that commit, and asserts that the identity the
extraction's build reports is exactly that commit. Then, inside the
extraction, the documented CLI build runs and the real-provider workflow runs
against it, which is the proof that the archive is buildable rather than
merely extractable.

`VERSION` and the application versions move to `0.2.0` in an ordinary
reviewed commit before closure, as the
[milestone guide](../developer/milestones-technical.md#technical-milestones-release)
sets out; every application reads it at compile time.

**How a run is retained immutably, since a tag does not exist yet when the
runs happen.** The tested implementation commit itself moves the register and
both supplied marked status blocks from `In progress` to `In review`. Its
`Proved` rows mean the implementation is complete and each row names the proof
obligation; the `Pending` scaffold values are the result or identity of the
later closure run or review taken of that exact commit. The tested
implementation SHA already contains an indexed,
unfilled `docs/evidence/M5-closure-runs.md` scaffold whose results remain
`Pending`. Every closure-matrix run's complete output is retained outside the
repository under a stable reference and SHA-256 digest. The administrative
closure commit has the tested SHA as its sole parent, changes only `In review`
to `Closed`, and fills that
existing page with the tested SHA, each run's identity, platform, toolchain,
result, duration, retained-output reference and digest, plus the independent
review's result, reference and digest, and every M5-specific value predeclared
as `Pending`: the source inventory identity, documentation checklist including
the separate `DEVELOPMENT.md` row, Outcome 6 security review, attended-demo
provider/model identities, archive manifest identity, and graceful-stop
observation with its conditions. The archive-manifest fields carry the tested
manifest's source SHA, entry count, exact-byte retained-output reference and
SHA-256 digest. It adds no heading, label, row or prose. It
touches exactly the five paths and
allowed regions the milestone guide confines and carries no run of its own.

The source
archive is staged from the exact committed candidate with `git archive` and
extracted outside the checkout. Before the build, the fresh-source lane runs
`bash "$tree/scripts/source-archive-manifest.sh" "$tree" >"$retained_manifest"`
with `retained_manifest` outside `tree`; those exact bytes are the tested
manifest retained above. The extraction is then compiled and used to run the two-process
workflow from the extraction following the operator guide; its SHA-256, source
commit and tree are retained with the closure runs. The release itself is one
annotated `v0.2.0` tag created on the maintainer's separate decision, and the
commit it names is the **administrative closure SHA** — the one carrying the
closure record, and therefore the tree a reader who fetches the tag gets.
Before the tag is created, four proofs run on the administrative SHA, in this
order. First, the confinement proof requires its sole parent to be the tested
SHA, requires the complete zero-context patch to reach exactly
[the five confined paths and each path's allowed region](../developer/milestones-technical.md#technical-milestones-confinement),
compares the five paths' `git ls-tree` entries and raw diff to require ordinary
  blobs with unchanged modes, maps every changed byte to that table and requires
  the root README to be the sole path outside `docs/`. Reconstruction of
  `docs/plans/README.md` replaces both its exact M5 register row and its
  `current-status` marked block with the administrative bytes; reconstruction
  of the root `README.md` replaces only its `readme-status` marked block. Each
  reconstructed file must equal its administrative file byte for byte. Any
  object-type or mode change fails confinement even when every changed byte lies
  in an allowed region. Second,
`bash scripts/check.sh --docs`, including its `mix loopex.status` step,
validates the resulting documentation structure and reconstructed status
summary. Third, the final
semantic documentation gate inventories every file under
`docs/operator/` and `docs/developer/`, records why each is relevant or not,
and checks every relevant page against the implementation, plan, accepted
ADRs and its peers, then separately rechecks the predeclared `DEVELOPMENT.md`
row against the implemented release script. Fourth, a fresh `git archive`
extraction of the administrative SHA runs its own copy of
`scripts/source-archive-manifest.sh`, with output again retained outside the
extraction. A NUL-aware consumer rejects a malformed stream, an unknown kind,
or a duplicate path; removes the `docs` directory record and its descendants
plus the exact root paths `README.md` and `SOURCE_IDENTITY`; and compares every
remaining complete `(kind, mode, path, value)` tuple with the retained tested
manifest. The README is validated by complete-patch confinement,
marked-block reconstruction and the documentation/status gate; exactly one
source-identity file appears in each
archive and each value is validated against its own commit and source identity.
Nothing else re-runs — no suite, no release
check and no provider credential. The complete release-proof outputs and both
manifests remain outside the repository. Only after they pass is the immutable
annotated `v0.2.0` tag created on the administrative SHA; its annotation names
both SHAs and records every proof's result, retained-output reference and
SHA-256 digest, both manifest references and digests, the comparison-output
reference and digest, and both validated
`SOURCE_IDENTITY` values. The evidence page is not amended, there is no third
commit, and no proof named by the annotation postdates the tag. The tag's
commit must be reachable from `main` and carry `VERSION` exactly `0.2.0`.
Publish no package, binary, installer or service unit.

<a id="technical-plan-cli"></a>
### The Daemon's Operator Contracts

Concept: [Scope](M5.md#concept-plan-scope).

A daemon is not finished when it starts. These are the contracts M5 owes an
operator for running one, and each names the operator page that documents it.
The reference CLI is where they land; the Node client implements only the
attach side.

#### `loopex sessions`: the released form is preserved, the live form is new

`loopex sessions [--state-root DIR]` is a released command, documented in
`docs/operator/coding-sessions.md`, and it reads the state root's session
directory with no runtime and no daemon. M5 does not change it: an operator
whose daemon is stopped, or who never ran one, keeps exactly the behaviour
`0.1.0` gave them, and no flag they type today acquires a new meaning.

The live listing is a **separate form**, `loopex sessions --daemon <socket>`,
which connects and issues `session.list`. It is additive and explicit —
without `--daemon` nothing reaches a socket — and it presents:

- one page per request, with `--limit` (1 to 256, default 256) and
  `--after <session-id>`, printing the continuation cursor when the daemon
  returns one, so paging is the operator's step and never a silent loop;
- the four fields the index carries — session identity, recorded placement
  identity, `residency`, `controlled` — and nothing it does not have;
- `index_full` as a visible warning on `stderr` when the daemon sets it: *the
  daemon's index is full, so this listing may omit sessions this root
  contains*. A warning rather than a failure, because the page it accompanies
  is still true as far as it goes;
- `--status`, which issues `daemon.status` and prints placement identity,
  daemon incarnation, socket path, connection, attachment, activation and
  index counts against their limits, and uptime.

Both live-query forms write one compact UTF-8 JSON object followed by one LF;
they write no headings or locale-dependent text. Keys appear in the order fixed
here so the reference output is byte-testable. A list page is
`sessions`, `next_after_session_id`, `index_full`; `sessions` is an array whose
entry keys are `session_id`, `placement_identity`, `residency`, `controlled` in
that order. The CLI normalizes the wire's absent continuation to JSON `null` and
its absent `index_full` to `false`, so the empty page is exactly
`{"sessions":[],"next_after_session_id":null,"index_full":false}\n`.
Status keys are `placement_identity`, `daemon_incarnation`, `socket_path`,
`connections`, `connection_limit`, `attachments`, `attachment_limit`,
`active_sessions`, `activation_limit`, `activations_used`, `index_entries`,
`index_limit`, `index_full`, `uptime_ms`, in that order and with the wire types
unchanged, including the decimal-string `uptime_ms`. Strings use ordinary JSON
escaping, so whitespace, quotes, backslashes and newlines in a socket path stay
inside one record. `index_full: true` additionally produces the bounded warning
on `stderr`; warnings never enter the JSON.

Exit status: `0` for a page printed, including an empty one; non-zero with the
reason on `stderr` when the socket cannot be reached, the peer check refuses,
or the daemon refuses the arguments.

#### `loopex daemon`: starting, readiness, stopping

**Command grammar.** The complete startup form is:

```text
loopex daemon [--state-root <directory>] [--workspace <directory>]
              [--provider-launch <configuration-path>] [--policy <name>]
              [--cleanup-grace-ms <milliseconds>] [--socket <path>]
```

The startup form takes no positional argument. Every flag takes one nonempty value,
may appear exactly once, and accepts both `--flag value` and
`--flag=value`. A bare `--` ends option parsing, after which any word is a
refused positional argument. An unknown flag, duplicate flag, missing or empty
value, or any positional argument is a parser refusal before placement, Store,
socket or component work. There is no credential, root-project-resource or
project-skill flag: those inputs have the sources below.

The explicit offline-import form is separate:

```text
loopex daemon prepare-index [--state-root <directory>]
```

It accepts exactly the same state-root flag and `LOOPEX_HOME` precedence and
validation as startup, and no other flag or positional argument. It does not
require or read workspace, provider-launch, policy, credential, cleanup-grace,
root-project-resource, project-skill or socket inputs because it composes none
of those edges. The `prepare-index` word must be the first argument after
`daemon`; it may appear
exactly once and cannot appear after `--`. Its `--state-root` flag takes one
nonempty value, appears at most once, accepts both value forms, and follows the
same empty-flag, empty-environment and no-fallback rules below. Unknown,
duplicate, missing-value, empty-value, `--`-followed-by-word and extra-positional
forms refuse before placement or Store acquisition. The command then acquires
only those two exclusions in the order and with the cleanup contract specified
for offline import below. After parser and path-byte validation, and before
either exclusion, it installs its handled-`SIGTERM` route and starts the
ref-tagged import owner behind a monitor-and-`:go` gate.

**Path-byte validation precedes every effect.** Startup and `prepare-index`
share one boundary helper that applies `String.valid?/1` to the selected state
root before `Path.expand/1`, path normalization, filesystem inspection or
creation, placement acquisition, Store access, socket derivation or any other
component work. Invalid state-root bytes return `state_root_unusable` from
either command. Startup applies the same check to an explicit `--socket`
binary before normalizing or inspecting it; invalid bytes return
`invalid_socket_path`. The default socket is derived only after the root has
passed, so invalid root bytes always retain the root classification and never
become a socket error. The command parser and the directly callable path-input
API both use this helper; tests call the API with invalid binaries rather than
depending on what an OS argument vector can carry, and assert zero filesystem,
placement, Store, socket or component effects.

**Composition inputs.** A daemon is a host, so it takes the same input kinds
the app-server host takes today, but each input follows the exact flag,
environment, default or discovery source below. Where both a flag and
environment variable are listed, a present flag wins. The parser refuses an
empty flag value without consulting the environment; with no flag, a nonempty
environment value is used and an empty value is missing. An invalid flag value
never falls back to the environment. A required or refusing input that is
missing or unusable has the typed class and exact status below. Root project
context is the stated exception: its host utility reports an exclusion or
invalid manifest, withholds the content and continues.

| Input | Flag / environment | Default | Missing or invalid |
| --- | --- | --- | --- |
| State root | `--state-root` / `LOOPEX_HOME` | none | `state_root_required`, or `state_root_unusable` when its bytes are not valid UTF-8 or it cannot be created or read |
| Workspace | `--workspace` / `LOOPEX_WORKSPACE` | none | `workspace_required`, `workspace_unusable` |
| Provider launch | `--provider-launch` / `LOOPEX_PROVIDER_LAUNCH` | none | `provider_launch_required`, `provider_launch_invalid` |
| Policy | `--policy` / `LOOPEX_POLICY` | **none, deliberately** — authority is the operator's to name. The daemon command's host-owned registry is exactly `allow-all` and `shell-allowlist`, the two policies the released reference CLI already owns; the app-server-only `ask` value is not admitted here | `policy_required`; `policy_unknown` for any other value, including `ask` |
| Provider credential | `LOOPEX_PROVIDER_API_KEY` only | none; absent and empty are the same missing input | `provider_credential_required`, checked at start so an unattended launch refuses in a second rather than at the first dispatch. The daemon reads it once, deletes it from its environment and holds it in custody under ADR 0034 |
| Cleanup grace | `--cleanup-grace-ms` | the composition default | `cleanup_grace_invalid`, and the admitted domain is **an integer from 1 to `18_446_744_073_709_551_615`**, exactly core's own (`@max_cleanup_grace_ms`, `apps/loopex/lib/loopex/executor.ex:75`, and `grace_ms >= 1` at `:456`). Zero is refused, which the local executor's own validation would admit (`apps/loopex_executor_local/lib/executor.ex:897`, `>= 0`): a daemon composed with zero would carry a grace core cannot derive bounds from. A very large value is **accepted, not refused** — the daemon never passes it to a `receive … after` unsliced, for the reason the wait rule below gives |
| Root project resource | the selected workspace's root `AGENTS.md`, discovered through `LoopexComposition.ProjectResources`, the released CLI helper moved byte-for-byte in behavior into the shared host layer | `project_manifest: nil, project_decision: nil` when absent; with a valid manifest an interactive terminal sees the exact resolved path, size and digests and may supply the existing digest-bound decision, while a non-interactive launch carries that manifest with a null decision | no startup refusal. Containment or replacement exclusion is reported on bounded `stderr` and carried as absent; a malformed, oversized or unapproved manifest remains supplied with no matching decision where one exists, so core withholds the class and journals its existing declined receipt when a session runs |
| Project-skill packs | discovered from the selected workspace through `LoopexComposition.ResourcePacks`, as the app-server host does, and supplied independently as `resource_manifest` | an empty manifest when no `.agents/skills` exists | `project_skills_unusable` when workspace identity, discovery or manifest validation fails |
| Socket path | `--socket` | `<root>/daemon/daemon.sock` | `socket_path_too_long`; `socket_permission_unverified` when the directory or bound socket cannot be verified, or an existing selected path is not a same-user Unix-domain socket under no-follow metadata; `invalid_socket_path` when an explicit path's bytes are not valid UTF-8 or it is outside the root's `daemon/` directory |

Every refusing condition in the table is handled **before** the placement lock
is acquired where that is possible, so the common operator mistake costs
nothing and leaves nothing behind; the ones that can only fail later are
covered by the reverse-cleanup rule. Root project-resource discovery and the
interactive decision also finish before placement, but their fail-closed result
is an input to composition rather than a startup refusal. The daemon passes the
root manifest and decision as `project_manifest` and `project_decision`, and
the separate project-skill pack as `resource_manifest`; neither can overwrite
the other.

The extracted host utility has one typed boundary rather than the CLI's current
rendered strings:
`LoopexComposition.Placement.acquire/1` returns `{:ok, owner_handle}` or exactly
`{:error, {:placement_active, os_pid}}`,
`{:error, {:placement_unverifiable, reason}}`, or
`{:error, {:placement_lock_failed, reason}}`; `release/1` is idempotent `:ok`
and uses the acquisition-specific owner handle, but ignores both exact-handle
path-removal results. Callers therefore treat it as a best-effort attempt,
not proof that the lock path is absent. The daemon, failed-start cleanup and
`prepare-index` run it in an unlinked monitored helper under the fixed absolute
`placement_release_ms: 5_000` deadline. Exact `:ok` followed by normal helper
`DOWN` completes the phase; malformed result, abnormal death or timeout is
`placement_lock_failed`, with timeout hard-halting and leaving the exact-handle
residual for verified stale-owner recovery. `LoopexCli.Placement` migrates
to that module and renders the same operator messages it renders today. The
daemon maps the three tuple heads to the three startup classes of the same
names, keeping diagnostic detail on `stderr` without making prose part of a
control contract.

Extraction converts the present rendered branches rather than parsing their
strings: a readable owner proved live becomes `{:placement_active, os_pid}`;
an unreadable or otherwise undecidable owner or liveness result becomes
`{:placement_unverifiable, reason}`; and guard, create, write, link, race and
other acquisition failures become `{:placement_lock_failed, reason}`. Only
the CLI edge renders those typed results.

A `--socket` override is constrained exactly as the default is — its parent
directory must be owned by the daemon's user and mode `0700`, no component
below the state root may be a symbolic link the daemon did not create, and the
socket is created `0600` and verified after bind — **and it must resolve
inside the selected root's `daemon/` directory**. A path outside it is refused
at startup with `invalid_socket_path`, before the placement lock is acquired.

That last constraint is not tidiness. Socket ownership in this design is
derived from the host placement lock after the Store marker is acquired, and
both are per state root: two daemons on two different roots hold different
locks and markers and have no exclusion between
them at all. An override that let them name one path would put two daemons
with equal claim on one file, which no rule in this plan can adjudicate.
Inside one root there is exactly one placement holder with an opened Store, so there is exactly one
daemon entitled to bind, and exactly one entitled to remove a pathname a
predecessor left. An override therefore moves where the rule applies, never
which root it applies within.

**Readiness.** Exactly one line on `stdout`, and nothing else on that stream.
It is **one JSON object on one line**, not a space-separated phrase, because a
state root or socket path may contain a space or a newline and a phrase would
then be ambiguous to the process manager parsing it:

```json
{"record":"daemon_ready","root":"…","socket":"…","incarnation":"…","version":"0.2.0"}
```

Those are the only five fields, all strings, in that exact order. The encoder
writes compact UTF-8 JSON with no insignificant whitespace, applies ordinary
JSON escaping to every string, and appends exactly one LF byte. Nothing precedes
or follows that record on `stdout`. `root` and `socket` are the exact resolved
path strings, `incarnation` is this daemon lifetime's identifier, and `version`
is the literal `0.2.0`. A byte witness starts a daemon under short root and
socket names that contain a quote, backslash, space, tab and newline, compares
the complete output to the literal escaped object plus LF, and proves that the
embedded newline creates no second output record.

The write is launched **only after** all of: the placement lock is held, the
Store is open and its writer marker held, the `0700` subdirectory and `0600`
listening socket exist with their ownership and mode read back and verified,
and the listener owns that socket and has acknowledged its parked startup gate. A
monitored, disposable writer helper performs the one `stdout` request under the
command process's fixed absolute `startup_output_deadline_ms: 5_000`. That
command process is the lifecycle sentinel and the sole startup-disposition
arbiter. It serializes signal-handler stop, helper result or death, its absolute
deadline, the owner's component-fatal notice and the owner's post-success
release authorization. Exact helper success merely asks the owner to consume
queued exits and recheck the deadline and every required component; only the
resulting exact authorization consumed before another disposition lets the
sentinel send `begin_accept`.

The helper, signal handler and owner are different senders, so the plan does
not infer physical order from their mailboxes. It instead fixes the sentinel's
observable first disposition. Stop, component fatal, completed IO refusal,
helper death or deadline first leaves the gate parked; later candidates are
cleanup-only, and the line may already have reached `stdout` because a completed
IO write cannot be recalled. Release authorization first lets the sentinel open
the gate; a later stop or component exit takes its running path. Deadline
hard-halts as `readiness_write_failed`, because a queued IO request cannot be
recalled safely.
Thus the line proves that every startup prerequisite had been established when
the bounded write was launched, while successful write disposition plus the
exact gate release is what permits the first accept. A client that connected
while the listener was parked remains in the kernel backlog until that release,
or is closed without creating daemon state. Every diagnostic, warning and
failure goes to `stderr`, so `stdout` carries at most the one machine-readable
readiness line.

**Stopping.** After handler installation, sent **to the escript**, `SIGTERM`
begins the orderly shutdown below and is the only signal that does. After that
same cut, sent **to the launcher**,
`apps/loopex_cli/bin/loopex`, **any of `INT`, `TERM`, `HUP` or `QUIT`** does,
because the launcher traps all four and forwards `kill -TERM` to its child.
The daemon itself installs no `SIGINT` handler and cannot: the
emulator reserves that signal and `:os.set_signal/2` refuses the name, as the
signal section below sets out with the full route-by-signal table.
There is no `daemon.stop` method on the wire: stopping is an operator act
against the process, and a client-issued stop would let one connection end
every other client's session residency, which is authority the socket does not
carry and this milestone does not grant.

Before handler installation, while the shared host utility may be waiting at
the root-project-resource prompt, direct `SIGTERM` and each of those four
launcher routes use the BEAM emulator's default `SIGTERM` handler. The released
launcher waits for and returns the child's real status, so all five prompt-cut
cases report `0`. This is abrupt BEAM shutdown before daemon resource ownership
begins, not the orderly sequence. No daemon resource has been acquired, and
there is no readiness line, wire record, `daemon.stopping` record or
lifecycle/fatal diagnostic.
Root-resource presentation and prompt bytes already written to `stderr` may be
visible, as may the BEAM runtime's own `SIGTERM` shutdown notice; neither is a
daemon lifecycle or fatal diagnostic.

**Exit status.** `0` when an operator-requested stop completes, whether it
reverse-cleans an interrupted startup before readiness or runs the full orderly
shutdown after readiness, whatever the sessions were doing. This contract
starts at handler installation; a prompt-cut default `SIGTERM` also has status
`0` but does not run the orderly sequence. A successful `prepare-index` also
exits `0`, writes nothing to
`stdout`, and never emits a readiness record; its ordinary progress and warnings
go only to `stderr`. A handled import stop exits
`prepare_index_interrupted` status `110` after bounded cleanup, also with no
`stdout`, readiness or wire record. An offline-command parser refusal uses the
reference CLI's existing status `1`, prints its bounded reason or usage on
`stderr`, and performs no placement or Store work. An operational
offline-import refusal reuses the
applicable state-root, placement, Store or index class and unique integer below,
prints no readiness or wire record, and attempts one bounded diagnostic on
`stderr`. Every fatal exit uses its class's unique integer from the complete
map below; status is authoritative, and a disposable unawaited helper attempts
one reason line on `stderr`. The line may be absent when stderr is blocked. The
classes are the nonzero-class map's, in full, and this list is derived from it
rather than summarising it:

- **during startup**, before the sentinel's exact `begin_accept` send: the
  readiness line may already be visible when a stop, component fatal or
  readiness disposition wins, but no accepted client or wire state exists:
  `placement_active`,
  `placement_unverifiable`, `placement_lock_failed`, `store_writer_active`,
  `store_writer_unverifiable`, `store_writer_acquisition_failed`,
  `store_log_too_large`, `socket_path_too_long`,
  `invalid_socket_path`, `socket_permission_unverified`,
  `session_index_too_large`, `session_index_corrupt`,
  `session_index_upgrade_required`, `session_index_write_failed`,
  `signal_install_failed`, `credential_plane_start_failed`,
  `composition_start_failed`, `daemon_services_start_failed`,
  `listener_start_failed`, `readiness_write_failed`, and the explicit
  composition-input classes `state_root_required`, `state_root_unusable`,
  `workspace_required`, `workspace_unusable`, `provider_launch_required`,
  `provider_launch_invalid`, `policy_required`, `policy_unknown`,
  `provider_credential_required`, `project_skills_unusable` and
  `cleanup_grace_invalid`;
- **during offline import**, which has no readiness or wire surface:
  `state_root_required`, `state_root_unusable`, `placement_active`,
  `placement_unverifiable`, `placement_lock_failed`, `store_writer_active`,
  `store_writer_unverifiable`, `store_writer_acquisition_failed`,
  `store_log_too_large`, `store_lost`, `session_index_too_large`,
  `session_index_corrupt` — including a conflicting canonical and legacy
  placement identity or any non-temporary legacy row rejected by the strict
  reader — and `session_index_write_failed`, `signal_install_failed` and
  `prepare_index_interrupted`;
- **while running**, one per linked component in the fixed set: `store_lost`,
  `store_capacity_exceeded`, `runtime_lost`, `transfers_lost`,
  `workspace_lease_lost`, `executor_lost`, `registry_lost`, `custody_lost`,
  `capability_lost`, `relay_lost`, `connections_lost` and `listener_lost`;
  `drain_failed` names an orderly stop whose core census became unavailable
  and therefore continued as crash-equivalent teardown. A lease owner's death is **not** in this
  list: it is
  session-scoped, closes that session's controller with `control_owner_lost`,
  and the daemon keeps running;
- **from the command-process monitor**, `owner_lost`: the unlinked daemon owner
  died before sending a matching fatal latch. A prior latch keeps its first
  class and status; owner death requires no signal.

#### How a session is created and driven over the socket

`loopex attach` alone cannot start work, because a session has to exist and be
resumed before anything can be sent to it. The complete live client grammar is:

```text
loopex run --daemon <socket>
           [--steer <text> | --follow-up <text>] <prompt>
loopex resume --daemon <socket> <session-id>
loopex sessions --daemon <socket>
                [--limit <1..256>] [--after <session-id>]
loopex sessions --daemon <socket> --status
loopex attach <session-id> --daemon <socket>
              [--observe | --take-over [--prompt <text>]]
              [--after <event-sequence>]
```

`--daemon` takes one nonempty socket path and may appear exactly once. It
selects the live grammar before command-specific flag admission; a parse
refusal opens no socket and invokes no runtime or daemon method. The live
forms never reinterpret a released composition flag as client data:

| Form | Accepted flags | Refused released flags | Ownership and combinations |
| --- | --- | --- | --- |
| `run --daemon` | `--daemon`; optional `--steer` or `--follow-up` | `--skill`, `--skill-resource`, `--policy`, `--state-root`, `--workspace`, `--cleanup-grace-ms`, `--context-token-budget` | Steer and follow-up are request choices. Generation 2 exposes neither the immutable workspace binding and pre-admission manifest data needed to construct ADR 0023's exact project-skills decision nor a channel that hands that decision to the reference client, so the CLI cannot admit or activate resources and refuses both resource-selection flags before dialing. Generation 2 keeps the resource methods for host-integrated clients that receive the exact decision out of band. The daemon owns policy, root, workspace and runtime configuration. The existing steer/follow-up mutual exclusion applies unchanged |
| `resume --daemon` | `--daemon` | `--policy`, `--state-root`, `--workspace`, `--cleanup-grace-ms`, `--context-token-budget` | The daemon owns composition and checks the resumed session's binding. The live form does not ask the client to repeat or assert host configuration; in particular it does not require the offline form's `--policy` |
| `sessions --daemon` | `--daemon`; `--limit`; `--after`; `--status` | `--state-root` | `--limit` and `--after` select one listing page. `--status` is a different query and is refused with either paging flag. The socket identifies the root |
| `attach --daemon` | `--daemon`; `--observe`; `--take-over`; `--prompt`; `--after` | none; `attach` is new in M5 | Neither role flag means observe. Supplying both roles refuses. `--prompt` requires `--take-over`; observe may not send. A bare `--take-over` acquires, attaches and streams without sending a command; M5 never reads an attach prompt from standard input. `--after` is an unsigned 64-bit event sequence. Repeated non-repeatable flags refuse |

Every flag that takes a value keeps the released parser's `--flag value` and
`--flag=value` forms and refuses a missing or empty value. `--` ends option
parsing. The offline `run`, `resume` and `sessions` forms keep their released
grammars and do not accept any live-only flag. A table-driven CLI test
enumerates every cell above, both steer/follow-up orders, every incompatible
pair, duplicate and missing-value cases, the numeric endpoints, a bare
`--take-over` with a never-answering standard input that must not be read, and
the offline/live split. Its accepted cases assert the exact protocol request
sequence and values; its refused cases assert that no socket dial or facade
call occurred.

The daemon forms of the two released driving commands behave as follows:

- **`loopex run --daemon <socket> "<prompt>"`** — creates a session and sends
  its first prompt. It takes **no `--policy`**, and an earlier draft that
  showed one was wrong on the plan's own rule: policy is the host's, named
  when the daemon starts, and a connection that could name it would be a
  client replacing host authority. A `--policy` flag on a `--daemon` form is
  refused as an unrecognised option for that command. Its sequence is
  `session.create`, `session.acquire_control`, **`session.attach`**, then the
  prompt under the granted writer epoch. The reference live CLI sends no
  `resources.catalog`, `resources.read`, `session.admit_resources` or
  `session.activate_skill` request. ADRs 0023 and 0025 distinguish the
  seven-field project-skills decision from launch-time project-resource trust;
  generation 2 exposes neither the immutable workspace binding and
  pre-admission manifest data needed to construct that exact decision nor a
  decision-handoff channel for the reference client. Generation 2 retains
  those methods for a host-integrated client that receives the exact decision
  out of band. Attach comes
  *before* the prompt because
  ADR 0033 admits an existing-session mutation only from a connection that
  holds a live attachment for the pinned session, and grants exactly one exception —
  `session.resume` on a verified dormant session — which a prompt is not. The
  optional inputs keep their released ordering. With `--follow-up`, the
  client waits for the prompt admission result, submits
  `session.follow_up` with a fresh command ID and the current writer epoch
  **before** it begins streaming, then streams. With `--steer`, it begins
  streaming after prompt admission, waits for the first durable
  `run.started` record, submits exactly one `session.steer` carrying that
  record's `run_id`, a fresh command ID and the current writer epoch, and
  continues the same stream; a terminal stream with no `run.started` sends no
  steer. The parser refuses both options together. The
  offline `loopex run` keeps its released grammar, session-driving semantics
  and output and continues to compose its own runtime; Outcome 6 separately
  changes that host composition's credential source and lifetime. `--daemon`
  is what redirects it.
- **`loopex resume --daemon <socket> <session-id>`** — reaches an existing
  session. It acquires control and attempts `session.attach`. When attach
  succeeds, the session is already active, but the one-way activation set does
  not prove its temporary coordinator is alive. The client therefore issues one
  bounded `session.inspect` before streaming and sends no mutation. A normal
  status begins the stream; generation 2's exact `session_unavailable` refusal
  makes the client attempt release while the transport is writable, exit
  non-zero and print the restart-then-resume remedy. It never parses `message`.
  When attach refuses
  `session_dormant`, that result agrees with the daemon's activation set and
  verifies ADR 0033's exception: the client sends `session.resume` with a
  **fresh resume command ID** and the granted epoch, retries attach exactly
  once, performs the same inspect and then streams. Thus an active session
  follows acquire → attach → inspect, while a dormant session follows acquire →
  refused attach → resume → attach → inspect; only the resume branch activates.
  Across transport recovery, an unresolved resume keeps that same ID. The one
  exception follows a daemon replacement: if the retained ID resolves as a
  completed replay but reattach still reports `session_dormant`, that completed
  ID cannot activate the new lifetime. The client retires it, allocates a fresh
  resume command ID, and retries without resetting the original 35-second
  recovery clock. It never allocates a replacement while an earlier resume is
  unresolved.
  If core's temporary coordinator died, this daemon's one-way activation set
  still makes the first attach succeed, but inspect returns the discriminable
  refusal without admitting a command. The exact remedy is to restart the
  daemon, then retry `loopex resume --daemon`, which takes the new lifetime's
  dormant branch and starts a coordinator.
- **`loopex attach <session-id> --daemon <socket>`** — joins a session that is
  already activated. It does **not** resume, so it does not activate.

**`loopex attach` is observe-or-one-shot-control, and that is a deliberate
restriction.** Its forms are:

| Form | What it does |
| --- | --- |
| `--observe` (default when neither role flag is given) | Attaches without acquiring, streams events, sends nothing. Refused by the daemon, not the client, if it ever tries |
| `--take-over` | Acquires when no lease is held or after a live owner's release or expiry, waiting while an in-flight admission settles as ADR 0033's linearization requires and never forcing a live holder off. Following lease-owner loss it waits for exact dead-owner pop, classification acknowledgement and terminal holder-close or correlated-refusal settlement before successor start, then for every predecessor ticket and retirement completion before the fresh-owner grant. It then attaches. Against a session this daemon has not activated the attach refuses `session_dormant`, and the client **releases the lease explicitly** before exiting non-zero with `loopex resume --daemon` as the remedy. On every other exit path where the transport remains writable it also releases explicitly; a killed client or broken socket sends nothing and the lease expires |
| `--take-over --prompt "<text>"` | The same — acquire, then attach — plus **one** command under the granted epoch, sent only after the connection holds a live attachment for the pinned session, then streams to a terminal outcome. An omitted `--prompt` sends no command; M5 does not inspect standard input for one |

There is no interactive multi-turn controller in M5. A controller that could
accept turn after turn from a terminal would need a full interactive contract
— input framing, mid-run steering, interrupt handling, what a partial line
means — and none of that is in this milestone's scope. One-shot control is
what the two-process demonstration actually needs, and the restriction is
stated here so it is a decision rather than an omission. A live
`loopex run --daemon` drives its initial request and at most one optional
follow-up or steer. A live `loopex resume --daemon` repairs, attaches or resumes
as needed and streams without admitting a user command. Later one-shot control
uses explicit `loopex attach --take-over --prompt`.

**Initial cursor.** `--after <sequence>` starts the stream strictly after that
event sequence. Without it the cursor is `0` and the client receives the
session's full replay, which is the honest default: a client that did not say
where it left off has not established a position, and silently starting at the
live tail would hide everything before it.

**Lease renewal, and what a failed renewal does.** A controller CLI renews
every ten seconds against a thirty-second term, as ADR 0033's proposed terms
fix. A live-socket correlated renewal refusal is not retried silently: the
client stops sending mutations immediately, reports the loss on `stderr`, and
continues **as an observer on that same attachment** until the process ends or
the operator re-runs with `--take-over`. If the renewal cannot be sent or EOF
arrives, that connection pid and attachment are already gone. The client takes
the ordinary transport-loss path, reconnects at its retained cursor and
reattaches as an observer; it does not claim to keep the dead attachment. A
controller whose UX is to continue controlling instead takes the separate
re-acquisition path below and receives a fresh epoch before another mutation.
Neither failure branch races the old deadline or sends another mutation.


**Core's create and resume results tell the daemon whether this invocation
started a coordinator, and that is core's fifth M5 change.** The daemon has two
duties that pull against each other: charge any call that starts a coordinator
against the activation ceiling, including an open resume command replay; and
repair a directory entry for a completed create replay without activating
anything. Today it cannot do either
reliably, because every path answers the same way. Two branches reply
`{:ok, session_id}` directly — the session is already active (`control.ex:903-904`),
or the command was seen before so no owner is started (`:906-907`). The third
starts one — the `true ->` arm at `:909`, calling `start_owner` at `:910` —
and replies **`{:noreply, next}`**, the `{:ok, session_id}` arriving later
through `owner_ready_reply/4` (`:532`). Three
paths, one indistinguishable value.

Core already computes what is missing, and uses it: `create_command_absent?/2`
binds `fresh?` at `control.ex:895`, and the `cond` at `:902-919` reads it to
decide whether to `start_owner`. What is discarded is the distinction in what
the caller finally receives — the same `{:ok, session_id}` however it got
there — so the fifth change is to stop discarding it there. **Core's runtime-side create and resume results — the
Elixir function the daemon calls, not the released public protocol result —
carries two plain fields beside the session ID:**

| Field | Values | What the daemon does with it |
| --- | --- | --- |
| `disposition` | `:activated` \| `:no_activation` | `:activated` converts the reserved activation slot and permits directory/index publication only after that successful create or resume proves this daemon's placement. `:no_activation` releases the slot and publishes nothing, except the separate idempotent retry for a row whose placement this daemon already proved. Command-history status is deliberately not used: an open historical resume starts one, while a completed replay does not |
| `control_entry` | `:active` \| `:acquiring` \| `:dormant` | Observation only. None of the three authorizes publication. In particular, `:acquiring` can belong to another invocation, and `:dormant` can be a historical create whose placement this daemon has not proved |

**`control_entry` is three values over four statuses plus no-entry, and an
earlier revision argued one of them away.** `Control` holds `:active`,
`:acquiring`, `:unavailable` and `:awaiting_owner_barrier`, and a session may
have no entry at all
(`control.ex:569`, `:620`, `:818`, `:835`, `:862`, `:1030`, `:1150`, `:1189`).
The
mapping is `:active` → **`:active`**; `:acquiring` → **`:acquiring`**;
`:unavailable`, `:awaiting_owner_barrier` and no-entry → **`:dormant`**,
there being no ready, routable coordinator in any of the three — the barrier status
meaning the coordinator has already died.

The field carries `:acquiring` because a completed replay can observe another
call starting that session. Reservation accounting does not infer from it:
`disposition` records whether **this** invocation called `start_owner` or
`start_resume_owner`. That distinction also covers the branch an earlier
revision missed: replaying an **open** resume command is historical by command
identity but calls `start_resume_owner` and therefore returns `:activated`.

**It is `control_entry`, not `residency`, and the rename is the point.**
`residency` is a **daemon** fact on the wire — what `session.list` reports
about a session in *this daemon's* lifetime — while this field says what
`Loopex.Runtime.Control` holds for that session at the instant of the call.
The two coincide today and would not always: a session `Control` still lists
as active may have no live coordinator, which is precisely the `absent` case
`quiesce/1` reports. Giving both the same name would have invited a daemon to
forward one as the other. `residency` stays daemon-only; `control_entry` is
core's.

**The same two fields belong on the runtime-side `resume` result.** Resume has
three relevant branches: `{:completed, …}` returns without an owner, while
both `{:open, open}` and `:absent` call `start_resume_owner`
(`control.ex:306-328`, `:506-510`). Core already knows the difference and
already exposes replay information in one mode: `completed_resume_reply/2`
answers `{:ok, {:replayed, session_id}}` for the **prepared** mode
(`control.ex:526`) and a bare `{:ok, session_id}` for the plain one (`:527`),
and `owner_ready_reply/4` does the same for a started owner (`:529-532`).
Rather than make the daemon use a mode it does not otherwise want, the plain
resume result carries the same `disposition` and `control_entry` the create result
does. That is one shape for both, not two.

**The two fields arrive on new functions, not on the existing ones**, and that
is the half an earlier revision left unsaid. `Loopex.Runtime.create_session/3`
and `resume_session/3` are specified `{:ok, binary()} | {:error, term()}`
(`runtime.ex:156`, `:169`), and the embedded facade forwards exactly that:
`Loopex.create_session/3` returns what `Runtime.create_session/3` returns
(`loopex.ex:87-95`) and `Loopex.resume_session/3` likewise (spec at
`:110`, clause at `:111-117`).
Widening those returns would change what a released embedded caller receives
from a call it already makes — a compatibility break taken for a daemon's
bookkeeping.

So core change 5 adds **two daemon-facing functions beside them**,
`Loopex.Runtime.create_session_detailed/3` and
`resume_session_detailed/3`, answering
`{:ok, %{session_id: binary(), disposition: :activated | :no_activation,
control_entry: :active | :acquiring | :dormant}} | {:error, term(),
%{disposition: :activated | :no_activation,
control_entry: :active | :acquiring | :dormant}} | {:error,
:runtime_unavailable}`. The metadata-bearing error is a domain reply produced
by the exact live `Control`; failure to resolve that `Control`, or loss of that
incarnation before its reply, is the outer two-tuple and carries no invented
metadata. `:activated` means the
serialized callback successfully started a coordinator child even if later
readiness or attachment work made the enclosing call return an error. The existing pair
keeps its exact spec and its exact return, implemented as a projection of the
detailed one, so `loopex.ex:87-95` and `:110-117` forward what they forward today and
no embedded caller sees anything move. The daemon calls the detailed pair,
which is the only caller that needs them.

**The public protocol result is unchanged too.** Generation 1 and generation 2
return what they return today; this is an in-VM API detail between core and
any host, and no wire schema, digest or vector moves. A host that ignores the
detailed functions behaves exactly as it does now.

**Core change 2 keeps domain results separate from loss of core.** Its exact
existence API is:

```elixir
Loopex.Runtime.session_existence(runtime, session_id) ::
  {:ok, :present | :absent | :invalid_id | :store_unavailable}
  | {:error, :runtime_unavailable}
```

An invalid ID returns its domain answer before a Store call. For a valid ID the
function resolves one exact `Control` incarnation and maps only Store answers
inside `{:ok, result}`. Failure to resolve or call that `Control` is the outer
runtime error, which the daemon treats as fatal `runtime_lost`; it is never
mapped to `store_unavailable` or sent as an existence refusal.

**What happens at the ceiling requires a read before the activating call.** A
fresh create cannot be refused after `create_session_detailed/3` tells the
daemon it was fresh: core starts the coordinator inside that call's `true`
branch (`control.ex:909-918`). Core change 2 therefore includes a narrow
read-only `Loopex.Runtime.lookup_create_result/3` beside the session-existence
query. It takes the create `command_id` and the exact canonical session options
bound by the command and has this exact result:

```elixir
{:ok, {:historical, session_id} | :absent | :conflict
      | :store_unavailable | :unexpected}
| {:error, :runtime_unavailable}
```

The five values inside `{:ok, result}` are its complete domain. Failure to
resolve or call the exact `Control` is the same outer runtime error and the
same daemon-fatal `runtime_lost`. The query reads the existing runtime-command
history, starts no coordinator and writes no byte.

The read uses the existing Store callback rather than widening the port.
`Control` rebuilds `session_genesis/2`, passes it through
`Store.create_session/3`, and queries `Store.runtime_command/2` with that
transaction's canonical bytes and digest under `command_kind: :create`.
`Loopex.Store.Local.State.runtime_command/2` gains the missing projection for
the retained create shape `%{binding:, resolution:, session_id:}`: an exact
binding returns `{:completed, %{result: session_id}}`; changed options or a
cross-kind command ID return `{:error, :runtime_command_conflict}`. The callback
arity and existing result union do not change, and neither `transact/2` nor an
owner start occurs. The in-memory conformance store implements the same
projection, so the core witness cannot pass only on the local adapter.

At the activation ceiling the daemon calls that discriminator before any
create. `{:ok, {:historical, session_id}}` returns the prior result without charging
an activation, but does not publish a placement row: the create-history result
does not carry placement, so directory/index repair waits for a later successful
resume under the daemon's configured placement. `{:ok, :absent}` refuses
`activation_ceiling_reached`; `{:ok, :conflict}` returns the existing
correlated admission refusal with reason `runtime_command_conflict`;
`{:ok, :store_unavailable}` returns the correlated `store_unavailable` error;
and `{:ok, :unexpected}` collapses to the correlated `internal_failure` error
without serializing the term. The outer runtime error selects fatal
`runtime_lost`. Ceiling-path witnesses force all five inner results plus the
outer failure and assert these exact wire dispositions, no coordinator and no
write. Below the ceiling the detailed create path remains the authority for
the activated/no_activation disposition and for reservation conversion. This keeps
command-ID recovery available without permitting a sixty-fifth coordinator.

Guessing the disposition from side effects — comparing activation counts
before and after, or watching for a coordinator to appear — was the rejected
alternative: it is a race by construction, since another connection may create
a session between the two observations.

**A dormant session refuses `attach` in either role.** `loopex attach` against
a session this daemon has not activated is refused with `session_dormant`,
naming the remedy: `loopex resume --daemon`. Attaching does not activate. Activation is a
controller's act — acquire, then resume with a fresh command ID — because it
starts a coordinator and counts against the activation ceiling, and letting a
read-only observer trigger it would let a watcher consume a resource a
controller needs and start durable recovery nobody asked for.

**The refusal sits at attach, not at acquisition, and that placement took
correcting.** An earlier draft refused inside `session.acquire_control` — "no
lease taken" — which reads well and is wrong twice over. ADR 0033's own
concept says a known dormant session is driven by *acquiring by ID, resuming
with the granted epoch and attaching*, and ADR 0032's recovery sequence
acquires a dormant session at step 7 before resuming at step 8. Refusing
acquisition for dormancy would break the one path that is supposed to bring a
dormant session back. And acquisition could not tell the two intentions apart
anyway: `session.acquire_control` carries `session_id` and `request_id` and
nothing about what the caller means to do next, so distinguishing "acquiring
to resume" from "acquiring to attach" would need a new field — a new input to
the generation-2 schema digest, added to make a client-side convenience
expressible.

So the daemon's **attach** handler is where it belongs — and it consults the
right structure, which is not the listing index. Two daemon-owned structures
answer two different questions, and conflating them would make the index
ceiling bound reachability:

| Structure | Question it answers | Bounded? |
| --- | --- | --- |
| The **activation set** | Has this daemon activated this session ID in this lifetime? | By the 64-activation ceiling it already counts — it *is* that counter's backing set |
| The **listing index** | What sessions does this root record, for `session.list`? | By the 4,096 recorded-entry ceiling |

Attach consults the **activation set**. That matters because at the index
ceiling a session reached by ID is activated and deliberately *not* recorded:
consulting the index would refuse `session_dormant` for a session that is
demonstrably active, and the recorded-entry bound — which this plan says is
never a bound on reachability — would become exactly that. The activation set
has no such gap, because a session cannot be activated without entering it.
`loopex resume --daemon` uses that exact set: its first attach succeeds for an
active session, while `session_dormant` selects the fresh-resume-then-reattach
branch.


**Every ceiling consumed by a core call is reserved before that call**, and
the activation ceiling is the one where getting it wrong is most visible. The
rule is general: `attachments_per_session` (64) and `attachments_per_daemon`
(512) are consumed by `session.attach`, which creates the attachment inside
core, so the daemon reserves an attachment slot before calling and releases it
on any refusal — two concurrent attaches at 511 would otherwise both see 511
and both succeed. For replacement, the connection registry is the one daemon
reservation owner. It reserves an injective borrow of the exact
`{holder, attachment_id, incarnation}` after the relay has recorded the request
origin and before that origin can promote. Exact repetition becomes a waiter on
the first primary; a distinct request for the same target receives
`attachment_conflict` with no second relay task, borrow or core transaction.
Core independently reserves the exact target for embedded callers. The index's
4,096 rows need no concurrent reservation because one daemon process serializes
index publication. A lease operation needs no registry-owned reservation
before a core call, but the daemon owner atomically reserves one of the 512
lease-owner process slots as `starting` or `starting_waiting_pop` before it
starts or transfers an owner and keeps that slot charged through the exact linked `EXIT`; a transferred
`starting_waiting_pop` reservation permits no child until exact mirror pop,
owner-loss classification acknowledgement and terminal holder-close or
correlated-refusal settlement, as ADR 0033 requires.

**The activation ceiling is enforced by reservation, because counting after
the call is a race.** Core starts a coordinator *inside* the call that would tell the
daemon it did — `start_owner` for a fresh create (`control.ex:909-918`),
`start_resume_owner` for a resume that is not a replay (`control.ex:318`,
`:321`) — so a daemon that counts when the call returns has already let it
happen. Two consequences, both real: at 63 activations two concurrent calls
each see 63, both proceed, and both coordinators start; and at 64 a dormant
resume that the daemon has not yet counted starts a sixty-fifth.

So the daemon takes an **atomic slot reservation before any
activation-capable call**, and the invariant it maintains is

> **|activation set| + |reservations| ≤ 64.**

A call that cannot reserve is refused `activation_ceiling_reached` **before
core is called at all**, which is the only place a refusal can be both
truthful and early. Every reservation is bound to the request's exact
`origin_id = {connection_incarnation, request_slot, request_sequence}` in the
connection registry. A reservation cannot outlive a terminal
origin without an exact, idempotent rollback acknowledgement.

The call direction is fixed to avoid an owner↔relay deadlock. A connection or
lease owner asks the connection registry to allocate and bind a reservation;
the relay never synchronously calls the registry. For direct create, the
registry then calls the relay itself before answering the connection. For
resume, the lease owner calls the relay with the reservation reference returned
by the registry. Result and rollback notifications from the relay are
asynchronous and idempotent by that reference. The daemon owner calls the relay for cut,
freeze and seal, so no reverse synchronous edge exists.

**A duplicate create does not take a second reservation; one serialized owner
chooses the primary and installs it before another create can pass.** The
connection registry keeps
`create_binding[(command_id, canonical_session_options_digest)] =
{primary_ticket_id: origin_id, reservation_ref}`. On the first request it
records that binding and reservation, then synchronously asks the relay to
install and promote that exact origin. The relay records the primary ticket and
starts its monitored core task before acknowledging. Only then does the daemon
registry answer the connection, so a duplicate cannot overtake the primary.

An exact re-presentation receives `duplicate(primary_ticket_id)` from the
connection registry. Before answering that connection, the registry synchronously has
the relay install `waiting(primary_ticket_id)`; no second task starts. The
waiter retains its own origin and reply route and receives the primary's real
result. The same `command_id` with a different digest receives the stable
idempotency-conflict classification with no task or reservation. A different
command identity reserves independently. Primary connection death after
promotion retains the task and reservation; waiter death clears only that
waiter.

Cut, dead-incarnation or relay refusal after reservation but before promotion
returns an exact terminal acknowledgement to the connection registry. It releases
the reservation and binding and terminalizes every waiter; no waiter is ever
promoted to primary. Forced cuts cover both owner-reserved/relay-not-installed
and relay-pending/not-promoted. After promotion, only the real detailed result
converts or releases the reservation and settles all live waiters.

**Reservation identity follows the exact origin plus command identity and the
inputs that command binds.** A create uses
`(origin_id, command_id, canonical_session_options_digest)` until its session
ID is known; a resume uses `(origin_id, command_id, session_id)`. The latter
pair matters because two different resume commands for one dormant session are
two calls, while one replayed command is one. The create's canonical digest is
retained with the reservation and compared before joining a waiter; after the
call answers, the returned session ID is recorded on that same reservation.

It is **converted or released idempotently by `reservation_ref`**: converting
records the session ID in the activation set and drops the reservation;
releasing drops it. Repeating either for the same reference is a no-op, so a
retry, a crash-recovered handler or a duplicated reply cannot double-count or
double-free. A dormant resume first has its pending origin recorded, then its
lease owner obtains this exact reservation, then promotes that origin. Worker
or lease-owner death, cut/deadline, or relay refusal before promotion
terminalizes the origin and asynchronously releases that exact reservation.
After promotion only the real detailed result converts or releases it.

**A session already in the activation set takes no reservation at all**, which
an earlier revision also got wrong: it refused a resume at the ceiling for a
session this daemon had *already* activated, although that resume adds no
activation — the coordinator exists, the slot was spent when it started, and
core's own command idempotency handles the rest. So the rule is checked in
that order: if the session ID is already counted, the call proceeds with no
reservation and no ceiling test; only a call that may add an activation
reserves. That is also what keeps a controller from being locked out of a
session it is already driving merely because the daemon is full.

**Every domain branch of both results resolves the reservation, and runtime
loss ends the daemon that owns it. The table is complete rather than
illustrative**, because a branch nobody listed is a slot leaked until the
daemon restarts:

| Result of the call | Slot |
| --- | --- |
| Create or resume, `disposition: :activated` | **Converted** — this invocation started a coordinator, including an `{:open, open}` resume replay |
| Create or resume, `disposition: :no_activation` | Released — this invocation started no coordinator. `control_entry` may be `:active`, `:acquiring` or `:dormant` because it is an observation of shared Control state, not evidence about which invocation created it |
| Completed resume replay | `:no_activation`, released (`control.ex:311-312`) |
| Open resume-command replay | `:activated`, converted: both the `{:open, open}` and `:absent` branches call `start_resume_owner` (`control.ex:306-328`, `:506-510`) |
| Create or resume returns `{:error, reason, %{disposition: :activated}}` after its coordinator child started | **Converted**. The outer refusal does not erase a lifetime activation or the entry's `writer_started?` fence obligation |
| Create or resume returns `{:error, reason, %{disposition: :no_activation}}`; or attach refuses before its pending-row reservation | Released. Invalid identity, placement conflict, Store refusal, `start_child` failure and the attach preflight all belong here because none started a coordinator for this invocation |
| Create or resume returns outer `{:error, :runtime_unavailable}` because the exact `Control` cannot be resolved or dies before replying | The daemon latches fatal `runtime_lost`, sends no fabricated domain result, and retains no requirement to convert or release the ephemeral reservation because this daemon lifetime ends. Its relay task and reservation die in fail-stop; a successor derives truth from core and Store rather than metadata the failed call never supplied |
| A **resume** whose connection is lost while the call is in flight | **Held, then resolved by the relay**, which holds the call's real answer whether or not the process that asked is still there; where the daemon must re-establish it later, the client's replay under its original `command_id` carries the same `disposition`/`control_entry`. The existence query cannot answer this — it says `present` either way |
| A **create** whose connection is lost while the call is in flight | **Held, then resolved by the relay** the same way; a later replay under the same `command_id` returns the historical result and starts no coordinator (`control.ex:901-907`), carrying the same two fields. Same reservation key, so no second slot |
| An **attach whose connection ends before the relay task answers** | **Held until core decides both installation and holder cleanup during ordinary service.** The connection registered its pid and incarnation with the relay before sending any attach ticket. The registry's retirement request can race ahead of the holder's ticket, so the relay answers it only after consuming its own monitor `DOWN` and settling every ticket ordered before that signal. Before publication the transaction discards. If publication committed, Control consumes either publish-ack then `DOWN` and performs ordinary cleanup, or `DOWN` then publish-ack and finalizes directly to released/no-live-route after idempotent dispatcher cleanup; neither order restores a removed replacement target. During orderly shutdown, successful `seal_after_quiesce` kills the relay task and removes an unresolved ticket, while the nondurable core transaction and capacity charge remain until holder `DOWN` or runtime teardown; admissions are closed, so the charge cannot be reused. The daemon decrements installed attachment counts only after both core owners' cleanup acknowledgements, so it never admits a 513th attachment while one is still installed |

**The daemon never calls `Runtime.prepare_resume_session/3`**, which is why
the prepared-capability row an earlier revision carried is gone. That function
exists (`runtime.ex:186-192`) and answers `{:ok, {:prepared, …}}` for a caller
that wants to hold an activation open — and a daemon that used it would have
an **unticketed** entry into core, an activation begun outside the relay's
account and therefore outside the admission cut, which is a hole no
reservation row could have covered. The daemon uses
`resume_session_detailed/3` and nothing else, so there is no "held until the
activation resolves" branch to describe.

**Those rows used to say "crashing or timing out", and the timing-out half was
false.** An earlier revision rested it on a default: `Loopex.Runtime`'s
`control_call/3` and `dispatcher_call/3` do default to a **five-second** reply
timeout (`runtime.ex:470`, `:478`) — but **`create_session/3` and
`resume_session/3` both pass `:infinity` explicitly**
(`runtime.ex:156-163`, `:169-177`), so neither inherits it and neither can
time out. There is no deadline on those calls to give the daemon "no answer".
What actually ends the wait is the **per-connection process dying** while the
call is still running in core, which is why the rows now name that.

**`Runtime.attach/3` keeps a bounded read-only preflight and makes its
state-changing half one deferred Control call.** Its signature takes a runtime,
a session ID and options and no timeout (`runtime.ex:198-210`). The preflight
`control_call(runtime, {:begin_attach, …})` keeps the existing five-second
default (`runtime.ex:200`, `:470`). `safe_call/3` maps timeout or exit to
`{:error, :runtime_unavailable}` (`:529-535`). That leg reads the session entry,
validates options and detects repetition but mutates nothing
(`control.ex:1235-1251`), so a refusal leaves no identity, scan, attachment or
capacity charge.

M5 replaces the current state-changing dispatcher call followed by Control
install with **one** `Control` call at `:infinity`. In its `handle_call`, Control
revalidates the preflight, reserves the pending row, allocates the exact
attachment and incarnation IDs, retains the caller's `from` value plus caller
and stable-holder monitors, and returns `{:noreply, state}`. It never holds its
mailbox in a dispatcher call. Instead it drives stage, authorization,
publication, cleanup and finalization through exact-incarnation messages;
dispatcher acknowledgements return directly to Control. The dispatcher runs a
bounded snapshot preparation in a linked, monitored, non-trapping worker and
remains responsive to acknowledgement and cleanup messages. At most one such
worker exists per pending attach, so the existing 512 daemon charge bounds that
process group. Worker death refuses that transaction; dispatcher death kills
its workers and invokes the generation-cut disposition below.

Only Control sends `GenServer.reply/2`, after both owners agree on the terminal
transaction state. Caller death drops that reply route but does not cancel the
state driver. The stable holder remains a separate pid, monitored independently
by Control and EventDispatcher. Control's pending-row reservation, rather than
the read-only preflight, linearizes against `begin_quiesce`: gate first means
`runtime_unavailable` with no dispatcher row or borrowed charge; reservation
first grandfathers only that exact transaction/incarnation through a terminal
result. During ordinary service the relay keeps its ticket and capacity charge
until its task receives that result. During orderly shutdown the successful
post-quiesce seal removes an unresolved ticket after killing the task, while the
transaction and charge remain cleanup-owned. Quiesce does not await the
transaction because it changes no durable truth; holder cleanup or runtime
teardown removes any transient installation and charge afterwards, with no
capacity reuse after the cut.

The daemon's rule follows the split rather than the call: **it adds no timeout
to a core call that has already changed something**, because a timeout it
could not act on truthfully would be worse than the wait, and it leaves the
first leg's existing five seconds alone because that leg changes nothing.
`create_session/3` and `resume_session/3` have no such split — they are
`:infinity` from the first line — so the two of them and attach's second leg
are what the reservation rows are written against.

**Who resolves a reservation when the asking process is gone: the relay.** A
relay task performs every ticketed core call and returns core's answer whether
or not the connection still exists. For a create or resume domain result it
hands `disposition` and `control_entry` to the daemon's serial owner. An outer
`runtime_unavailable` instead latches fatal `runtime_lost` and ends that owner
without a public method reply. For attach it hands back the attachment result while core continues to treat the connection
pid as holder. The connection's death can therefore close the client route
without losing the result needed to convert or release a slot.

**A call whose answer the daemon holds no route to may still have started a
coordinator
or an attachment**, so releasing the reservation would let the ceiling be
exceeded and converting it would spend a slot that may not exist. What
resolves it differs by call, and an earlier revision used one resolution for
all three — core's existence query — which cannot discriminate for two of
them.

**Create and resume: the relay retains the original detailed answer.** A
connection death does not turn accounting into a replay inference: the
ticketed core task continues and the relay consumes its actual
`:activated | :no_activation` result before it releases or converts the
reservation. A completed replay later returns `:no_activation`, truthfully
describing that replay rather than the original call. If relay or daemon state
is lost, the daemon fail-stops and the per-lifetime activation count starts
again; no old reservation must be reconstructed. Create-history lookup remains
the separate discovery-repair path for a client that never received its
session ID.

**Attach: the transient caller and stable holder are deliberately different.**
The relay task calls core's internal attach-for-holder operation with the
connection pid. Core records and monitors that stable holder in both Control
and the dispatcher, while the task remains only the caller carrying the
result back to the relay. Core permits several attachments under one holder
for embedded callers, but each daemon connection remains a single attachment
slot. Its first attach tentatively pins the connection to the session; a
second refuses unless the existing wire boolean is `replace: true`, in which
case the daemon maps the connection's sole live handle to core's exact
`replace_attachment_id`. The connection's `DOWN` releases its installed
attachment and transfers. A replacement is net-zero for the daemon attachment
ceiling only because the daemon serially borrows that exact live target before
the relay call; the borrow is injective across pending replacements. A first
attach reserves one slot until the relay and core have accounted for the result.

If the connection dies during the infinite second leg, the task continues to
the real core result. Core either installs nothing, or installs against a
holder already known dead and then completes the holder cleanup. The daemon
keeps the reservation counted throughout and releases installed counts only
after that cleanup acknowledgement. This is the witnessable mechanism that
makes connection loss safe at 511 installed attachments; simply releasing on
transport `DOWN` would be a check/use race against an attach still completing.

`loopex attach --take-over` against a dormant session therefore acquires
successfully and is refused at attach, holding a lease it no longer wants.
That is exactly why the general rule matters: **a CLI that holds a lease
attempts an explicit release while its transport is still writable**, by
sending `session.release_control`, because ADR 0033 binds early release to
that call alone and treats every transport loss — including a clean client
exit — as a wait for expiry. The qualification is not a hedge but the honest
scope of the promise: a client whose socket has already failed, or which is
killed, sends nothing, and there is no exit path on which a dead process can
write a frame. On this path the socket is live, so the client releases, exits
non-zero, and names `loopex resume --daemon` as the remedy. Without that
attempt it would strand the operator: the command the refusal recommends
begins by acquiring the same lease, and would refuse `control_held` for the
rest of the term.

**Cursor, reconnection and re-acquisition.** A streaming client remembers the
last event cursor it emitted and deduplicates by session ID, event sequence and
event ID; delivery is contiguous and at least once, so a duplicate at the seam
is expected and a gap is a defect. It also retains a non-secret phase record:
command form, durable create/resume identities, session ID once known, role and
cursor; plus the exact ordered mutation plan for that form. Each planned
prompt, optional follow-up or steer, or takeover prompt retains its method,
preallocated command ID and
`not_sent | sent_unconfirmed` state, and the record retains `next_step`. Every
non-steer step retains its fixed canonical semantic input when planned. A steer
retains its immutable content template until the exact replayed `run.started`
supplies `run_id`, then fixes and retains its canonical semantic input
immediately before its first send. The client changes a step to
`sent_unconfirmed` before that first socket-write attempt, so a failed write is
treated conservatively as possibly delivered. After reacquisition it
re-presents a sent-unconfirmed step with the same method, command ID and
canonical semantic input, a fresh connection-local request ID and the fresh
writer epoch. The epoch authorizes the retry but is not part of the durable
command input. A fresh or replayed accepted or refused admission resolves the
step without duplicating the mutation. Exact `admission_unknown` does not: the
client advances no `next_step`, sends no later mutation, reports the retained
method and command ID unresolved and exits non-zero. The client advances
`next_step` only after a resolved admission or the exact durable prerequisite
that makes the following step valid. It never retains a writer epoch as
reusable authority.

Two fixed client clocks make recovery bounded. A list, status or liveness query
uses `live_query_deadline_ms: 10_000` from its first send and permits at most one
new connection and one retry. A streaming command uses
`stream_reconnect_deadline_ms: 35_000` from its first unexpected transport loss,
with a fixed 250 ms delay between dial or acquisition attempts; no successful
step or later EOF restarts that instant. The 35 seconds contain the complete
30-second lease term plus a five-second local tail. Every dial, negotiation,
request and backoff rechecks the same monotonic instant. A complete
`daemon.stopping` record followed by close is terminal and is never treated as
an EOF to repair: `operator_stop` exits `0`, while a fatal reason exits non-zero.
A bare EOF has no trustworthy reason and follows the table below.

| Command and loss phase | Bounded recovery |
| --- | --- |
| `sessions --daemon` list or status before its complete result | Reconnect once and issue the same side-effect-free query with a fresh connection request ID inside `live_query_deadline_ms`. A second loss, refusal or deadline exits non-zero. There is no event cursor. |
| `run --daemon` before the create result | Replay `session.create` with the **same** command ID and canonical creation inputs. A live result supplies the same session ID. A historical result starts no coordinator, so the client acquires control, attempts attach, and, if dormant, allocates one resume command ID, resumes, reattaches and inspects before it can send the prompt. No second session is created. |
| `run --daemon` or `resume --daemon` after a session ID is known, with `next_step` absent or `not_sent` | Reacquire for a fresh epoch, attach, and inspect. If the daemon lifetime changed and attach says dormant, these two command forms may resume. An unresolved resume ID is retained across every retry. When that ID instead resolves successfully as a completed replay and reattach still reports `session_dormant` after daemon replacement, retire the resolved ID, allocate one fresh resume ID for the new activation attempt and continue under the same original 35-second recovery clock. A later loss before that fresh attempt resolves reuses its ID; no step, replay, reattach or later EOF resets the clock, and no new ID is allocated while one is unresolved. A post-attach EOF repeats this phase and sends no mutation under the old epoch. When a retained next step exists and its prerequisite is already proved, send that exact command ID and input once under the fresh epoch; resume has no user mutation to send. |
| An observer attachment | Reconnect and attach at the retained cursor without acquiring or resuming. `session_dormant` exits non-zero and names `resume`; observing never activates. |
| Core succession invalidates an installed attachment | A received `detached` record is attachment loss, never evidence that the session is dormant. The connection remains open. An observer reattaches at the retained last-emitted cursor without activating; a controller retains its lease, epoch and deadline, reattaches and inspects before continuing, and no mutation passes the attachment gate before that reattach. Neither role sends `session.resume`, releases, reacquires or waits for expiry solely because succession invalidated the old handle. A separate transport loss follows the ordinary EOF recovery rows. |
| A controller whose current planned step is `sent_unconfirmed` | Reconnect, reacquire and attach at the retained cursor, using dormant recovery only for `run` or `resume`, then re-present the exact method, durable command ID and retained canonical semantic input under a fresh request ID and the fresh writer epoch. The resulting accepted or refused admission is fresh if the first write never reached core and is the idempotent replay if it did, including when that command emits no public event. Acceptance advances to the retained next step once its exact prerequisite holds; refusal ends the plan. Exact `admission_unknown`, failure to obtain the reply or expiry of the fixed deadline advance nothing, send no later mutation and exit non-zero with that method and command ID unresolved. |
| `run --daemon` between prompt and optional follow-up or steer | A retained `not_sent` follow-up is sent once after the prompt's accepted admission is proved. A retained steer waits for the exact replayed `run.started`, records its `run_id`, fixes and retains the canonical steer input and sends once. If the prompt is `sent_unconfirmed`, the client never substitutes the secondary command for it; it first re-presents the prompt by the preceding row and advances only from its resolved admission. |
| `attach --take-over` before its optional prompt | Reacquire and attach at the retained cursor, but never resume, then send the exact retained `not_sent` prompt once. After a daemon restart, acquire succeeds and attach says dormant; the client attempts one bounded release while writable, exits non-zero and names `resume`. |
| `attach --take-over` after its optional prompt reached `sent_unconfirmed` | Reacquire and attach without resuming, then re-present the exact prompt command and semantic input with a fresh request ID and writer epoch. A fresh or replayed accepted or refused admission decides without a duplicate; exact `admission_unknown` takes the unresolved non-zero exit above. A dormant result takes the same bounded release-and-exit path. |

The resume-replacement cut is an explicit client witness. Resume ID A commits
and activates a coordinator, its reply is lost, and that daemon is replaced.
The client re-presents A; core returns the completed historical result, which
starts no coordinator in the successor, and the following attach returns
`session_dormant`. The client then retires resolved A and allocates ID B. A
second loss before B's result causes B, not a third ID, to be re-presented; B
activates exactly one coordinator and the next attach and inspect succeed. The
test holds the first-loss monotonic instant fixed and proves the whole cut,
including both daemon replacements, replay, acquisition waits and final
attach, either completes or fails when that same 35-second instant expires.

A reconnecting controller can meet `control_held` while its own earlier tenure
is still live. It retries only until the earlier of the known old lease deadline
or 30 seconds after the first loss; at or after that instant, another
`control_held` means another client controls the session and ends recovery.
Every successful recovery gets a fresh epoch before any mutation. No observer
acquires, and no command sends a mutation under the old tenure.

**Signals detach live clients; they do not abort daemon-owned work.** Through
the launcher, `INT`, `TERM`, `HUP` and `QUIT` arrive at the live escript as
`SIGTERM`; a directly executed live-client escript uses
`LoopexCli.Interrupt` and handles `SIGTERM`, `SIGHUP` and `SIGQUIT`
(`interrupt.ex:60`). Direct `SIGINT` remains the emulator's reserved break
behavior and has no graceful contract. The released offline commands keep that
same existing `LoopexCli.Interrupt` behavior; this table applies only when
`--daemon` is present.

| Live form | Handled signal action | Durable effect and exit |
| --- | --- | --- |
| `sessions --daemon`, including `--status` | Cancel the query, close the socket and suppress reconnect | No mutation; exit `130` |
| `run --daemon` or `resume --daemon` | Mark operator detach, make one `session.release_control` attempt if a lease is held and the socket is writable, wait at most `live_detach_release_ms: 5_000`, then close | No `session.abort`; admitted work remains daemon-owned; exit `0` |
| `attach --observe` | Close the socket | No lease and no mutation; exit `0` |
| `attach --take-over`, with or without `--prompt` | Make the same one bounded release attempt when writable, then close | No signal-driven `session.abort`; an admitted prompt continues under daemon ownership; exit `0` |
| Any live form under `SIGKILL` | No handler runs | No release or abort is sent; the socket closes, any held lease expires, and the OS status is preserved |

The release attempt is best effort: refusal, deadline or a failed socket cannot
delay detach, and the lease then follows ordinary expiry. Exit `0` means the
operator detached the client, not that an in-flight session command completed.
All other refusals, an unrepaired bare EOF and a recovery deadline exit non-zero
with the stable reason on `stderr`.

#### Where these are documented

| Contract | Operator page |
| --- | --- |
| `loopex sessions`, `loopex run` and `loopex resume` offline grammar, session-driving semantics and output | `docs/operator/coding-sessions.md`, whose syntax rows stay unchanged while its numeric-validation account is corrected, Outcome 6's host-composition credential change is stated, and its daemon-page cross-link is added |
| `loopex run --daemon`, `loopex resume --daemon`, the create-and-drive sequence, the pre-dial `--skill` and `--skill-resource` refusals where no exact project-skills decision is handed to the reference client, bounded post-attach inspection, exact `admission_unknown` as an unresolved non-zero exit, phase-specific reconnect clock, the resolved-replay/dormant-reattach rule that retires one resume ID and allocates the next under the same clock, and the restart-then-resume remedy after a temporary coordinator dies | `docs/operator/daemon.md`, driving and recovery sections |
| `loopex sessions --daemon`, `--limit`, `--after`, `--status`, exact compact JSON output, one-query retry and `index_full` | `docs/operator/daemon.md`, listing and recovery sections |
| `loopex daemon` composition inputs — including pre-effect UTF-8 validation of state-root and explicit socket bytes, interactive and non-interactive root `AGENTS.md` handling, its fail-closed no-refusal rule, the separate project-skill manifest and the absence of flags for either — the pre-handler prompt's status `0` from the BEAM default handler, the post-handler orderly and direct signal routes, readiness record and exit classes | `docs/operator/daemon.md`, running section |
| `loopex daemon prepare-index`, its state-root-only grammar and pre-effect UTF-8 validation, pre-exclusion signal installation, status-`110` interruption path, exclusion order, strict legacy reader and whole-import refusal, success and residual outcomes | `docs/operator/daemon.md`, migration section |
| `loopex attach` roles, one-shot control, `--after`, renewal loss, `session_dormant` at attach, the attempted release while the transport is writable, reconnect and re-acquisition with its fixed clock and backoff, its `control_held` ending, and every handled-signal detach outcome | `docs/operator/daemon.md`, attaching, recovery and signals sections |

<a id="technical-plan-lifecycle"></a>
### Daemon Lifecycle and Orderly Shutdown

Concept: [Scope](M5.md#concept-plan-scope).

Outcome 1 requires that an orderly stop and an abrupt death both leave only
what the journal proves. That is a claim about a sequence, so the sequence is
written out rather than left implied by the words "foreground process".

**Startup, in order.** The order is written against the seam that actually
exists — one composition function that assembles every edge and ends with the
runtime — rather than against a staged one the plan would have to invent:

1. **Validate path bytes, then resolve the static composition inputs, root and
   socket path.** The shared boundary helper calls `String.valid?/1` on the
   selected root and any explicit socket before path normalization or any
   filesystem, placement, Store, socket or component work. Invalid root bytes
   are `state_root_unusable`; invalid explicit socket bytes are
   `invalid_socket_path`; and a default socket is derived only after a valid
   root, so it cannot reclassify a root error. Resolution then includes
   the `--socket` constraint below, the root `AGENTS.md` manifest and the
   independent project-skill pack. A path outside the root's `daemon/`
   directory is refused here with `invalid_socket_path`; unusable skill-pack
   discovery is `project_skills_unusable`. Root project-resource containment or
   replacement exclusion instead produces the shared host utility's
   fail-closed absent or withheld result. The utility shows an interactive
   operator the exact resolved root-resource manifest and takes the existing
   digest-bound decision, or records the non-interactive null decision. Nothing
   is acquired, so the default signal action during an operator prompt strands
   no host exclusion or component.
2. **Install the signal handlers**, for the reason the signal section gives:
   before this, the default handler would stop the VM outright and strand
   whatever the next steps take.
3. **Acquire the host placement lock** through
   `LoopexComposition.Placement.acquire/1`. A live or unverifiable owner, or a
   lock operation failure, ends startup with its typed placement class before
   the Store or socket is touched. A stale owner is reclaimed only under the
   utility's existing OS-incarnation guard. Immediately after acquisition,
   `File.stat/1` reads the acquisition-specific regular-file owner handle that
   this start created and retains its uid as `daemon_uid`; an error return or
   an owner handle that is no longer the acquired regular file selects
   `placement_lock_failed` before any later component starts.
4. **Start the credential routing registry, the custody process and the
   tracing capability**, in that order. All three are
   the daemon's own, as ADR 0034's host, and all three must exist before the
   model configuration that carries the registry handle, the token and the
   capability reference is built. The capability is listed here rather than
   left to the process table: it is one of the daemon's fixed links, ADR 0034 now makes
   it mandatory wherever a token is configured, and a startup sequence that
   named two of the three would have left the third's position to inference.
   It is handed the runtime reference as soon as step 5 returns one.
5. **Call the composition function**, which opens the Store and acquires the
   writer marker with `recover_stale_writer: true` and the three holder
   outcomes ADR 0032 fixes, then assembles the artifact transfers owner where
   enabled, the workspace lease, the executor and the runtime, and returns
   every pid it linked. A daemon that does not hold the marker fails here and
   never reads, unlinks or binds the socket path.
6. **Use the retained owner UID to create or verify the owner-only `0700`,
   non-symlink `daemon/` directory, then load the daemon's versioned index.**
   The `daemon/` directory must have `daemon_uid`; this comparison does not
   depend on an OTP effective-uid API. The index
   read consumes at most its fixed encoded-file ceiling, validating its
   version, digest, unique sorted rows and
   4,096-entry ceiling, and never enumerating `sessions/`. A root with session
   directories but no index refuses `session_index_upgrade_required`; the
   operator runs the explicit offline import while no daemon or foreground
   writer holds the root. A new root with neither index nor session directory
   gets a persisted canonical mode-`0600` empty index before startup proceeds.
   Reverse cleanup removes the directory only when this invocation created it
   and it remains empty.
7. **Start the admission relay, then the connection registry.** They are the
   fixed daemon processes started after the runtime and before the listener.
   The relay needs the runtime step 5 returned, and it must exist
   before any connection can be accepted, because every ticketed core mutation
   goes through it. The connection registry must exist before the listener
   accepts, because the provisional slot is reserved **at** `accept` and the
   registry must atomically install the permanent connection monitor at
   promotion. The listener holds a separate temporary connection monitor from
   process start through the promotion acknowledgement; accepting before the
   registry exists would accept connections nothing can promote or own. An earlier
   revision gave the relay a row in the process table and no step here, and
   the revision after it added the connection registry with neither, which
   left the two processes the admission cut and the connection ceiling depend
   on with no place in the order.
8. **In the already verified `0700` subdirectory, inspect the selected path
   without following it, remove only a proved stale socket, and bind the
   `0600` socket**, then read back and verify ownership and mode. After both
   exclusions are held, `File.lstat/1` may return `:enoent`, which proceeds
   directly to bind. A present path is removed only when its owner uid equals
   the retained `daemon_uid`, its `type` is `:other`, and
   `Bitwise.band(mode, 0o170000) == 0o140000` proves `S_IFSOCK`; `:other`
   alone is not proof because Elixir reports several special file kinds that
   way. A regular file, symbolic link, other kind, owner mismatch, metadata
   failure or removal failure is preserved and refuses
   `socket_permission_unverified`; no bind, listener or readiness work
   follows. The bound socket is read back and must have that same uid. A
   predecessor's proved socket is cleaned up here rather than by itself.
9. **Start the listener parked, then let the lifecycle sentinel arbitrate
   readiness, startup stop and startup failure before it releases the accept
   loop.** The listener owns the already bound listening socket, monitors the
   owner and acknowledges an unforgeable `startup_ref`, but performs no
   `accept` until it receives the exact `{:begin_accept, startup_ref}` **from
   the sentinel**. The owner sends the sentinel the exact
   `{:begin_readiness, owner_ref, startup_ref, listener_pid, line}`. The sentinel
   starts and monitors the whole-line `stdout` helper, records the absolute
   five-second output deadline and becomes the sole writer of the startup
   disposition. During this phase it serializes matching `SIGTERM`, helper
   result, helper `DOWN`, deadline checks, the owner's exact startup-fatal
   notice and the owner's exact release authorization. The timer only prompts a
   clock check; every candidate result is rejected at or after the absolute
   instant.

   From submission until the sentinel returns a disposition, the owner remains
   in its owned-exit loop and immediately reports a consumed component fatal.
   Exact output success before the deadline does not release the listener. The
   sentinel sends exact
   `{:readiness_output_succeeded, owner_ref, startup_ref, sentinel_pid}` to the
   owner, which consumes already queued
   component exits, rechecks the clock and every required component, and sends
   exactly one of
   `{:readiness_release_authorized, owner_ref, startup_ref, owner_pid,
   listener_pid}` or
   `{:readiness_startup_fatal, owner_ref, startup_ref, owner_pid,
   listener_pid, class, status}`. The same
   owner sends both messages, so an owner-observed component fatal and its later
   authorization have mailbox order at the sentinel. The owner waits for the
   sentinel's exact winning disposition and does not independently start
   cleanup or declare the daemon running.

   The first valid disposition the sentinel consumes wins. A helper refusal,
   helper death or expired deadline selects `readiness_write_failed`. Every
   nonzero readiness disposition is also the sentinel's retained first-fatal
   class and status and arms its watchdog. Deadline expiry hard-halts with that
   status because a queued IO request cannot safely be recalled; a completed
   refusal or helper death tells the owner to reverse-clean. A startup-fatal
   notice selects that exact component class and status. A
   `SIGTERM` selects `:operator_stop`, status `0`. Except for the deadline
   hard-halt, the winner is returned as exactly one of
   `{:readiness_disposition, owner_ref, startup_ref, :operator_stop}`,
   `{:readiness_disposition, owner_ref, startup_ref, {:fatal, class, status}}`
   or `{:readiness_disposition, owner_ref, startup_ref, :running}`. A stop or
   fatal leaves the gate parked,
   tells the owner to reverse-clean the exact partial inventory, and
   makes every later helper result, deadline, signal, fatal notice or release
   authorization cleanup-only. The sentinel kills and reaps any retained helper
   during bounded cleanup without claiming it recalled an IO request already
   queued at the IO server. The complete line may already be visible because
   the helper, signal handler and owner are different senders, but no server
   connection or wire state is created.

   Only a valid release authorization consumed before the deadline and before
   another disposition lets the sentinel send exact
   `{:begin_accept, startup_ref}`. That send is the classification cut; the
   sentinel records `running` before it returns the exact `:running`
   disposition to the owner, and
   forwards a later `SIGTERM` to the owner for the ordinary orderly-stop path.
   A linked listener `EXIT` the owner consumes before sending authorization is
   reported as startup class `listener_start_failed`. The same exit consumed
   after the sentinel's exact send is running class `listener_lost`; a fatal
   notice already ordered after authorization cannot move the cut backwards.
   This rule uses messages and the sentinel's observable send rather than an
   unobservable kernel-time order. A client may complete kernel `connect` while
   the listener is parked, but it remains in the backlog and creates no server
   connection process or daemon state. Stale placement, marker and pathname
   recovery handles either crash-equivalent residue.

No lease owner exists at this point, and none is started here: one is started
at the **first lease operation for a session** — an `acquire_control`, whether
or not that session is active. The parked listener guarantees no socket has
been accepted and no request can reach that operation before successful
readiness output.
An earlier revision said "when a session is activated", which is the rule this
pair corrected elsewhere and forgot here: dormant recovery acquires before it
resumes.

An operator `SIGTERM` the sentinel forwards and the owner consumes at a startup
checkpoint is the one non-failure terminal result: it records
`:operator_stop`, starts nothing further, performs
the same bounded reverse cleanup for the exact partial inventory, emits no
readiness or wire record and no fatal diagnostic, then exits `0` if that cleanup
completes. At the final readiness loop, the more exact rule above permits an
already completed line but still opens no gate when the stop wins. A cleanup
failure retains its own typed non-zero class. Every startup
failure otherwise exits non-zero with that step's reason class after reverse
cleanup and touches nothing after it.

Each step returns a tagged result to one total startup classifier. The exact
interrupt result `{:stop, :operator_stop}` remains that distinguished status-0
branch even when it returns from `start_edges/2`; no other stop reason acquires
that meaning. Typed input,
placement, Store, index and path failures retain their closed public class.
Every other result is normalized by step: signal installation,
credential-plane children, composition edges, daemon relay/registry services,
listener/socket operations, or readiness output. Raw terms never cross to
   `stderr`, and a returned error, raised error, throw or exit is caught into
   the same step family together with the exact partial pid inventory already
   acquired. In particular, `File.mkdir_p!/1` raising `File.Error` during
   placement and `File.stat/1` returning an error for the acquired owner handle
   both select `placement_lock_failed`, rather than escaping as `owner_lost` or
   leaving `daemon_uid` unset.


**Startup is interruptible, the lifecycle sentinel routes every stop, and the
owner is monitored rather than linked —
both because a synchronous sequence inside one process is not, by itself,
process-safe.** The steps above run in the owner, and while they run the owner
is not reading its mailbox: a stop the lifecycle sentinel forwards becomes a
message that waits, and a linked component's `{:EXIT, …}` waits beside it.
Left alone, that means a daemon can take the marker and bind the socket after a
stop or component exit is already queued. The interrupt rules prevent another
acquisition after such a message is consumed. When the owner asks to enter the
readiness phase, that request and every signal-handler message are serialized by
the sentinel: a stop already consumed there refuses the phase, and a later stop
joins the readiness arbitration above. The separate parked accept gate, rather
than visibility of the line alone, prevents a raced fatal event from admitting
work.

Four rules, each narrow:

- **The owner is started unlinked and monitored by the lifecycle sentinel.**
  The escript command process is that sentinel. It calls
  **`GenServer.start/3`, not `start_link/3`**, and monitors the owner
  immediately. An earlier revision had it both link *and* monitor, which
  defeats the monitor: an abnormal exit travels the link first and kills the
  command process, so the `DOWN` that was supposed to produce `owner_lost` is
  never handled by anybody. Unlinked, the command process survives every way
  the owner can die and gives the operating system an exact exit status. It
  never performs synchronous IO: its diagnostic helpers are disposable, and
  the exit status remains authoritative if output is blocked. The inventory
  row says unlinked-and-monitored, and now the design does too.
- **Startup does not run in `init/1`, because a monitor taken after
  `GenServer.start/3` returns cannot see a death inside it.** That call
  returns only once `init/1` has answered (it waits for the started process's
  acknowledgement), so an owner that took the marker, bound the socket and
  then died *in `init/1`* would leave the command process with no owner to
  monitor and a `{:error, reason}` that says nothing about what was acquired
  before the failure. Every acquisition would sit inside the one window the
  monitor cannot cover.

  So `init/1` acquires **nothing**. It sets `trap_exit`, builds the state from
  the already-validated inputs, and returns
  `{:ok, state, {:continue, :start}}`; the nine steps run in
  `handle_continue(:start, state)`. That is enough to make `GenServer.start/3`
  return before the first step, and the ordering is then explicit rather than
  incidental:

  | # | Who | What |
  | --- | --- | --- |
  | 1 | Command process | `GenServer.start(Owner, args)` |
  | 2 | Owner | `init/1` returns `{:ok, state, {:continue, :start}}`, having acquired nothing |
  | 3 | Command process | creates an unforgeable `owner_ref`, calls `Process.monitor(owner)`, and records the exact owner pid/ref pair |
  | 4 | Command process | sends the owner `{:go, owner_ref, command_pid}` |
  | 5 | Owner | `handle_continue/2` **waits for that exact message** before step 1 of the startup sequence, then runs the nine steps |

  **Step 5's wait is what makes the monitor provably installed**, and it is
  why the continue does not simply begin. Without it the ordering would rest
  on the command process winning a race it has no reason to win: the owner is
  runnable the instant `init/1` returns, and a scheduler is free to run its
  continue before the caller's next line. The `:go` message turns a hope about
  scheduling into a happens-before: the owner cannot pass step 5 until a
  message exists, and the message does not exist until the monitor does. The
  wait has the fixed startup-only bound `owner_start_gate_ms: 5_000`. The owner
  computes `owner_start_deadline = monotonic_now + owner_start_gate_ms`
  immediately before `init/1` returns and carries it into `handle_continue/2`,
  so scheduler delay cannot restart the clock. This clock is spent before any
  resource acquisition and is not a term in `T_orderly`. A
  `:go` that never arrives — a command process that died between steps 2 and
  4 — ends the owner through the reverse cleanup with nothing acquired, which
  is correct, because there is nobody left to report a daemon to.

  The alternative was to keep the sequence in `init/1` and have the owner
  monitor the *command process* instead. It is rejected: it inverts the
  reporting direction, gives the operating system no exit status when the
  owner is the thing that dies, and still leaves the `{:error, reason}` return
  as the only account of an acquisition that already happened.
- **The sentinel forwards startup stops to the owner until readiness begins,
  and the owner drains and checks before every acquisition it performs itself.**
  The signal handler always targets the sentinel. Before readiness the sentinel
  records the stop pending and forwards the exact ref-bound stop to the owner;
  after the owner submits
  `begin_readiness`, the sentinel retains stop authority until it either leaves
  the gate parked or sends `begin_accept`. Because both the stop and the
  readiness request are consumed by that one process, a stop accepted first
  cannot be overtaken by the phase transition. After release the sentinel again
  forwards later stops to the owner.

  The checkpoint runs before taking the placement lock; before each of the
  registry, custody and capability starts; before calling the composition
  function that takes the marker; before creating or opening the daemon
  directory and index and again before a fresh empty-index write; before each
  of the relay and connection-registry starts; before no-follow inspection and
  any removal of a proved stale socket, and again before binding the new socket;
  before starting the parked listener;
  and before submitting the readiness request. At each checkpoint the owner
  reads every already forwarded stop message or `{:EXIT, …}` and checks that every
  component it has already started is alive. Any stop or failed liveness check
  aborts startup into reverse cleanup before the named acquisition. The
  composition function supplies the corresponding checkpoint between its own
  edges below.
- **The composition function checks between its own edges, because the owner
  cannot.** Its chain is one synchronous `with` (`loopex_composition.ex:166-178`):
  the owner is inside that call for the whole of it and can read nothing
  between the Store and the runtime. An earlier revision claimed a mailbox
  check "before each edge the function returns to it", which is not a thing
  the owner can do. So the function takes an **interrupt checkpoint** as an
  option and calls it **before starting each edge**. The public seam is exact:

  ```elixir
  @type edges :: %{
          required(:store) => pid(),
          required(:workspace_lease) => pid(),
          required(:executor) => pid(),
          required(:runtime) => Loopex.Runtime.t(),
          required(:runtime_supervisor) => pid(),
          optional(:transfers) => pid()
        }
  @type partial_edges :: %{
          optional(:store) => pid(),
          optional(:transfers) => pid(),
          optional(:workspace_lease) => pid(),
          optional(:executor) => pid(),
          optional(:runtime) => Loopex.Runtime.t(),
          optional(:runtime_supervisor) => pid()
        }

  @spec start_edges(keyword(), keyword()) ::
          {:ok, edges()}
          | {:error, term(), partial_edges()}

  LoopexComposition.start_edges(options,
    interrupt: (-> :continue | {:stop, term()}))
  ```

  The first argument is the same option set and validation contract as
  `start/1`; the second accepts only optional `:interrupt`, defaulting to a
  function that returns `:continue`. A non-list argument, unknown lifecycle
  option or non-function interrupt refuses `:invalid_composition_options` with
  an empty partial map. The zero-arity function is evaluated in the caller's
  own process before Store, optional transfers, workspace lease, executor and
  runtime start. Where it answers `{:stop, reason}` the composition starts
  nothing further; any other return refuses
  `{:invalid_composition_interrupt_result, value}`.

  **And on any early exit it returns what it has already started**, which the
  interrupt makes necessary and an edge failure needed anyway. Both the
  interrupt checkpoint and each edge starter execute under one narrow catcher:
  `error`, `throw` and `exit` become
  `{:composition_interrupt_exception, next_edge, kind}` or
  `{:composition_edge_exception, edge, kind}` respectively, where `kind` is
  exactly `:error`, `:throw` or `:exit`. The caught value and stack never enter
  the returned reason or a diagnostic. Each caught path returns
  `{:error, tagged_reason, partial_edges}` rather than escaping the owner:

  The partial map's type permits exactly the six success-map keys and contains
  only the successfully started edges, never a placeholder or `nil`;
  `:transfers` is absent when disabled or not yet started. `:runtime` and
  `:runtime_supervisor` enter atomically after runtime start, the latter taken
  from the returned runtime. Early validation and pre-edge failures therefore
  return `%{}`. Without that map, an interrupted or failed composition would leave the owner
  linked to edges it cannot name, and reverse cleanup would unwind less than
  exists. `RuntimeOwner.start/1` and `with_runtime/2` call this named seam from
  their spawned owner process, discard the edge map only after registering it
  for their existing reverse cleanup, and preserve their released return
  shapes. The daemon owner calls the same seam directly and retains the map.

The monitor and checkpoint need no supervisor. The drain is a receive with a
zero timeout and a liveness check, the interrupt is a function the caller
already has, and the command process is the lifecycle sentinel that waits for
the daemon to end and gives the operating system an exit status. Startup and
sentinel output use short-lived unlinked helpers that hold no daemon state and
never own cleanup. The orderly quiesce caller and the other transient helpers
are separately bounded in the process inventory below.

**One cost of matching the seam is stated rather than hidden.** Index validation
is step 6, after the composition function has already taken the workspace lease
and started the executor, so an invalid, oversized or legacy-without-index root
is refused *after* those were taken and released rather than before. Nothing
durable is at risk — the reverse cleanup below releases them in order — and the
alternative was a second staged public composition function only to reorder a
bounded refusal. The offline legacy import is deliberately outside daemon
startup and runs only while the root is otherwise stopped; it may enumerate the
legacy directory because its command is explicit and its cost is visible to the
operator.

**The explicit import has an interruptible lifecycle of its own.** After parser
and path-byte validation, but before either exclusion, the command process
installs the same `SIGTERM` mechanism and becomes the import lifecycle
sentinel. It starts an unlinked import owner behind the same monitor-before-
`:go` ordering used by daemon startup. The owner traps exits and alone owns
the placement handle and Store pid. It starts one monitored scan worker for the
materialized `File.ls/1` and all strict per-entry reads; that worker receives
no Store handle, opens no index output and publishes nothing.

The signal handler sends the sentinel an exact ref-tagged import stop, and the
sentinel forwards it to the owner while retaining
`prepare_index_interrupted` status `110`. The owner kills and reaps a live
scan worker, stops Store under the same fixed 30-second phase, and runs the same
five-second placement-release helper. The sentinel's one absolute
`prepare_index_interrupt_ms: 40_000` watchdog covers worker reap and both
cleanup phases; expiry hard-halts with status `110`, leaving only the marker
or placement residuals their verified recovery rules already admit.

The sentinel arbitrates the exact successful-import report and a stop with the
same first-consumed rule as daemon readiness. If it consumes success first, the
import is complete, a later stop is cleanup-only and the command exits `0`.
If it consumes stop first, interruption retains status `110` even if success
was already queued. Cleanup runs once in either order.

The owner drains a queued stop before placement acquisition, before Store open,
before scan-worker start, after the scan result and before index publication,
immediately after rename, after directory sync, before Store stop and before
placement release. A signal during the intentionally unbounded scan therefore
interrupts the worker rather than waiting for enumeration to finish. Before
rename, interruption preserves the prior index; after rename, it leaves the
newly named complete synced file or the existing post-rename
directory-sync-unknown outcome and makes no rollback claim. All paths emit no
stdout, readiness or wire record.

The import uses its own strict reader and does not call
`Loopex.SessionDirectory.list_sessions/1`, whose released operator projection
intentionally drops entries it cannot decode. The importer opens the
`sessions/` directory without following a symbolic link, requires its owner UID
to equal the uid retained from the importer's acquisition-specific placement
owner handle, and retains that owner plus its non-symlink
directory type, device and inode. It materializes the names once with
`File.ls/1`, excludes only names matching the released
`String.contains?(name, ".tmp-")` rule, and rechecks the directory identity.
Every remaining name must pass the released one-component session-ID
containment rule and identify a regular non-symlink file. The reader performs
an identity-stable read of at most the released 1 MiB entry ceiling plus one
byte to detect overflow, rejects the compressed external-term tag before
`:erlang.binary_to_term(contents, [:safe])`, and accepts exactly the legacy
keys `session_id`, `runtime_id` and `commands`. The stored session ID must equal
the filename byte for byte. The runtime ID and every command ID must be valid
UTF-8, NUL-free and 1 through 256 bytes; there are at most 4,096 commands, and
every cached result equals that session ID. Any non-temporary entry that fails
containment, file kind, size, stable read, safe decode, exact keys, identity,
UTF-8 or command validation returns `session_index_corrupt` before publication.
Failure to open or list the directory, an initial owner mismatch, or an owner,
type, device or inode change at the post-list recheck returns
`state_root_unusable`. An injected metadata seam proves both owner-mismatch
orders without requiring filesystem ownership privileges. Every refusal leaves
a pre-existing index byte-for-byte unchanged, publishes no union and runs the
same bounded pre-rename exclusion cleanup.

**The daemon's top-level component is an owner process, not a supervisor.**
That is a decision this section has to make before it can describe any
shutdown, and three facts in the code force it.

- `LoopexComposition.start_edge/2` runs inside a process `RuntimeOwner`
  **spawns** — `own_started/5` and `own_bracketed/6` are `spawn_monitor` bodies
  and `initialize/1` sets `trap_exit` there — so the `start_link` to the Store
  adapter links that *owner* process, not the daemon. The daemon is only the
  caller of `start/1` or `with_runtime/2`, and `%Loopex.Runtime{}` is
  `[:supervisor, :token]`: no composition function hands back the adapter pid.
  **A daemon using the bracket has no way to observe the Store's death and no
  pid to monitor.**
- The bracket also inverts the ordering. `Runtime.stop/1` is
  `Supervisor.stop(supervisor, :normal)`, and the runtime supervisor is one of
  the owner's linked edges, so its exit arrives at the owner as
  `{:EXIT, _owned_pid, reason}` and the owner runs `cleanup/1` **immediately**
  — stopping every owned edge including the Store, and releasing the marker —
  before the daemon has told a single client or closed its listener.
- And an OTP `Supervisor` cannot serve here either, which an earlier draft of
  this section got wrong. `Loopex.Runtime.start_link/1` returns
  `{:ok, %Loopex.Runtime{}}` — a **struct**, not `{:ok, pid}` — so the runtime
  is not a startable child at all; a supervisor rejects that return. Beyond
  that, a supervisor offers no callback that can read a terminating child's
  exit reason, so `store_lost`, `store_capacity_exceeded` and a lease owner's
  session-scoped exit would be indistinguishable at exactly the moment the
  daemon must tell them apart.

So `apps/loopex_daemon` has one top-level process, `Loopex.Daemon.Owner`, a
`GenServer` that traps exits and holds the links itself — the same pattern
`RuntimeOwner` already uses, for the same reason.

**It links a fixed set of eleven processes — ten without artifact
transfers — and a bounded, dynamic population of lease owners beside them.**
Earlier drafts said four, then seven, then nine, each time having counted the
components the daemon *thinks* about rather than the processes that actually
exist. The fixed set is this:

| Start order | Linked process | Where it comes from | Optional? |
| --- | --- | --- | --- |
| 1 | The credential **routing registry** | The daemon's own, as the host ADR 0034 names | no |
| 2 | The credential **custody process** | The daemon's own, as the host ADR 0034 names | no |
| 3 | The **tracing capability** | The daemon's own, as the host ADR 0034 names; it holds the runtime reference and resolves the current `Control`, which coordinates the tracer for `exclude_self/2` | no |
| 4 | The Store adapter | `start_edge(Store.Local, …)` | no |
| 5 | The artifact transfers owner | `start_edge(Transfers, …)` | **yes** — only when transfers are enabled |
| 6 | The workspace lease | `start_edge(WorkspaceLease, …)` | no |
| 7 | The local executor | `start_edge(Local, …)` | no |
| 8 | The runtime root | `start_edge(Loopex, …)` | no |
| 9 | The **admission relay** | The daemon's own; the ten ticketed calls — eight lease-authorized Control/journal mutations plus `session.create` and `session.attach` — are routed through it, and every other post-initialize method takes a lightweight permit | no |
| 10 | The **connection registry** | The daemon's own; it owns every connection's slot, monitor and output buffer, and the slot is reserved at `accept`, so it must exist before anything accepts | no |
| 11 | The listener | Bound and permission-checked last, so nothing accepts before the rest exists | no |

The tracing capability starts with the other two host-owned processes and
before composition, for the reason all three share: model options carry their
references, and options are built before the runtime exists. It is handed the
runtime reference as soon as the composition function returns one.

**Connections have an owner, and it is not the listener.** A connection is a
process, a reserved slot, a monitor, an output buffer and — once it has
negotiated — a generation. Something has to hold all five together, and an
earlier revision left them scattered: the listener accepted, the connection
process held its own buffer, and nothing owned the set. So the daemon runs one
fixed **connection registry** beside the relay, and it owns exactly that.
The listener records `accepted_at` immediately after kernel `accept`, computes
the one absolute `initialize_deadline = accepted_at + 30_000`, and reserves a
provisional registry slot keyed initially by rollback token and listener
incarnation, then also by the fresh
connection incarnation when the child is bound — that carries both instants and the exact transfer disposition
`:listener_owned | :transferring | :connection_owned`. The listener does not
start the child. It asks the registry to do so for the exact rollback token. In
one serialized registry callback, after rechecking that row, listener
incarnation and deadline, the registry calls `GenServer.start_link/3` with the
registry, listener and unchanged deadline in the waiting child's arguments.
The child's `init/1` installs monitors on both owners and returns without IO or
another external call. Before serving, the registry sets
`Process.flag(:trap_exit, true)` and retains the exact daemon-owner pid: that
owner's `EXIT` still stops it, while an exact temporary-child `EXIT` is handled
idempotently with the child's monitor `DOWN`. Before replying or consuming a
queued listener `DOWN`, child `EXIT` or child `DOWN`, the registry installs its
own provisional child monitor, binds the returned pid and fresh connection
incarnation into the row, prepares the new state, and then unlinks the child.
The creation link owns the child up to that instant without letting its exit
kill the trapping registry; the
opposing registry/child monitors own it afterwards. A caught exit or returned
start failure leaves the row's pid `nil`, which therefore means no child exists.
Registry loss ends the child through the link or its registry monitor and is
already daemon-fatal. Only the exact successful reply exposes the child pid to
the listener. The connection already monitors the listener. The listener transfers ownership with
`:socket.setopt(socket, {:otp, :controlling_process}, connection_pid)` after
CASing `:listener_owned` to `:transferring`; it reports the exact result to the
registry, which records `:connection_owned` on success or returns to
`:listener_owned` on refusal, before promotion. Reservation, start, transfer, promotion and every initialize
continuation recheck `monotonic_now < initialize_deadline`. In one callback the
registry installs its permanent connection monitor and turns the provisional
row live before acknowledging the connection, retaining that same deadline.
The connection then removes and flushes its listener monitor, begins receiving,
and sends `promotion_complete`; only then does the listener remove and flush
its temporary connection monitor. Before promotion, listener and connection
each send an exact idempotent provisional-abort message when its monitor or
transfer fails. The registry compare-and-sets
`provisional(token, :handing_off)` to `provisional(token, :aborting)`, which
remains an occupied slot. The registry's exact listener-incarnation monitor
makes listener `DOWN` terminal close evidence wherever the listener still owns
or may own the socket. With no child, it removes the row only after the
listener closes the socket and acknowledges or that listener `DOWN` arrives.
With a child, `:listener_owned` requires the close acknowledgement or listener
`DOWN` plus child reap; `:connection_owned` kills and reaps the connection that
owns the socket; and `:transferring` marks abort pending, waits for the exact
call result and takes one branch. If the listener dies before reporting,
listener `DOWN` closes the listener-owned possibility and killing/reaping the
child closes the transferred possibility; both exact `DOWN`s are consumed
before row removal.
The forced ownership-cut witness pauses the registry inside its serialized
callback after `start_link/3` has returned but before the child is bound and
unlinked, then kills the listener. The child observes listener `DOWN` and exits,
but its trapped `EXIT`, its monitor `DOWN` and the listener `DOWN` all remain
queued. After the registry resumes it binds the returned pid before processing
those signals, handles them idempotently, survives, and reaps the exact child,
row, socket and slot. There is no process-visible state in which a returned
child exists behind a `nil` row.
The daemon owner also observes listener `EXIT` and commands
`abort_provisional_for(listener_incarnation)` before fatal teardown, covering
simultaneous listener and connection death in which neither temporary process
can report. After promotion or exact reap, a late provisional
abort is a no-op, the permanent registry monitor owns release, and listener
death cannot propagate to or close the connection. The registry owns the one
deadline timer and final initialize-complete CAS: the timer only prompts a
clock check, provisional expiry enters exact abort/reap, live uninitialized
expiry enters closing with EOF, and only exact completion consumed before the
instant cancels and flushes the timer. A completion queued before the instant
but consumed at or after it loses. Thus handoff can never reset or escape the
accept-time bound:

- **the slot**, reserved at `accept` and retained through an aborting
  provisional row until the socket close acknowledgement or exact connection
  `DOWN`. After promotion the registry's permanent
  connection `DOWN` moves it to `closing`; the relay-retirement and holder-
  cleanup acknowledgements release it. This is what makes the 512 ceiling a
  ceiling rather than a handshake rule;
- **the transport monitor**, so a connection that dies closes its socket and
  buffer and begins bounded retirement. Core separately monitors that connection pid as the stable attachment
  holder and drops the holder's complete attachment set and transfers on the
  same `DOWN`;
- **the buffer-control interface**, so backpressure and the bounded
  best-effort writes go through one place rather than each caller reaching
  into a connection's state;
- **the generation**, so a broadcast reaches only connections that negotiated
  one. **Generation-2 records — `daemon.stopping`, `daemon.notice`,
  `control_owner_lost`, `detached` — go only to connections that completed a
  generation-2 `initialize`.** An uninitialized socket has agreed no encoding,
  so it is **closed with EOF** and told nothing; writing a generation-2 record
  to it would be sending bytes under a contract the peer never accepted.

**Losing the listener does not lose the connections, and losing the registry
does.** `listener_lost` stops new connections arriving; the registry and every
accepted connection still exist under their connection-process owners, so fail-stop attempts a bounded
`daemon.stopping` carrying `fatal:listener_lost` to each initialized
generation-2 peer before closing them. Registry loss removes the only live set
and buffer-control interface. The owner therefore cannot enumerate or close
accepted connections on `connections_lost`: it directly kills the listener and
relay without awaiting either, performs the bounded executor and Store phases, and lets
`System.halt/1` close the connection processes' sockets. No record is claimed,
and clients learn by EOF at the halt. Both classes are daemon-fatal; only the
first has a wire reason.

**The admission relay is new in this revision, and it exists because of a
window nothing else closes.** Core has no writer epoch — the lease is the
daemon's, and core never sees it — so when a lease owner dies with an
admission still inside core, the daemon loses the only record that the
admission exists. A replacement owner starting from nothing could grant a
successor, whose call could then reach a coordinator *before* the dead
controller's earlier call, which is still in flight. Neither ADR 0033's fresh
epoch nor core's serial ownership prevents that reordering: the fresh epoch
stops a *later* command from the old tenure, and core orders what it receives,
not what is still on the way.

So one fixed, daemon-owned process holds what the lease owners cannot — and
three details of it are the difference between closing the window and looking
as though it does:

- **Tickets cover every core call that mutates `Control` or the journal, plus
  `session.attach` because the daemon counts attachments — ten of them.** The
  claim is that narrow on purpose, and an earlier revision's wider one —
  "every core call that mutates core state, and nothing else" — was false.
  Generation 2 inherits ADR 0023's three **artifact transfer** methods
  (`artifact.open_transfer`, `artifact.read_chunk`, `artifact.close_transfer`,
  `0023-…-technical.md:175-177`), which M5 reuses unchanged; they reach core
  through `Runtime.open_artifact_transfer/2`, `read_artifact_chunk/3` and
  `close_artifact_transfer/2` (`runtime.ex:279-288`, `:295-306`, `:312-321`)
  and they **do write** dispatcher state — the transfer map on the attachment,
  at `event_dispatcher.ex:323`, `:351` and `:386`. They carry no ticket, and
  that is correct rather than an omission: what the cut protects is quiesce's
  enumeration of `Control` and the journal it drains, and a transfer touches
  **neither** — only per-attachment state that belongs to the attachment and
  dies with it. Ticketing all thirteen was the alternative and is rejected: it
  would put a read of an artifact chunk in the way of a stop for no property
  the stop needs.

  What holds for them is the rule stated once and for every kind: **after the
  cut, every post-initialize method on an initialized open connection is
  refused `daemon_stopping`** — transfers included, and reads included, the refusal
  being about the daemon's state and not about what the request would have
  done. A transfer already in flight when the cut answers either completes on
  its own or ends in the teardown with its connection: the connection process ends,
  core change 1's monitor drops its attachment, and the transfer state goes
  with the attachment it was hanging from. Nothing about it is durable and
  nothing about it can disturb the drain.

  Of the ten, eight are the lease-authorized
  existing-session mutations ADR 0033
  lists: `session.resume`, `session.prompt`,
  `session.steer`, `session.follow_up`, `session.abort`,
  `session.respond_interaction`, `session.admit_resources` and
  `session.activate_skill` — the calls that carry `writer_epoch` and
  are admitted only from the recorded holder
  (ADR 0033's methods-and-fields section). The ninth is **`session.create`**, which
  carries no epoch and has no lease owner, because the session it makes does
  not exist yet; its ticket is taken by the **connection process** rather than
  by a lease owner, and it takes no part in the per-session grant-blocking
  rule below, there being no earlier tenure for a successor to overtake. It is
  ticketed for the two things a ticket is otherwise for: so that the admission
  cut can say it has accounted for every mutation in flight, and so that the
  relay — not the connection, which may be gone — owns the resolution of the
  activation slot an activation-capable create reserved, where one exists. A
  historical create replay reserves no activation; its task is bounded by the
  connection origin ledger. An earlier revision left creates
  outside the relay entirely, which made the cut a promise the daemon could
  not keep.

  **The tenth is `session.attach`, and it follows the same task-before-reply
  rule as every other ticketed call.** The connection asks the relay with its
  own pid as the stable holder. Inside that callback the relay creates and
  promotes the connection's origin row, starts a monitored task, and that task calls the narrow internal
  attach-for-holder operation with the connection pid before the relay
  acknowledges. The task is therefore the caller but never the installed
  holder; the connection remains the holder after the task exits, and its
  `DOWN` removes every attachment it owns. This is the purpose of the internal
  operation and the reason ordinary `Runtime.attach/3` keeps caller-is-holder
  semantics for embedded callers.

  Before it can send any admitted request, the connection synchronously
  registers its pid and fresh connection incarnation with the relay, which
  installs its own monitor. Every active local request slot then has one relay
  origin row keyed by `{connection_incarnation, request_slot,
  request_sequence}`; the monotonic sequence prevents slot-reuse ABA. On connection loss, the registry moves that accepted slot from `live` to
  `closing`, destroys that socket and output buffer, and starts one monitored
  cleanup worker keyed by `{connection_incarnation, cleanup_ref}`. The worker,
  never the registry process, calls `release_holder/2`; an inline call could
  block registry status, accept, buffer and reservation work for the duration of
  both core cleanup acknowledgements. The relay terminalizes unpromoted rows,
  kills and reaps nonterminal request workers, and retains promoted primary
  tickets. Its exact retirement acknowledgement sets `relay_retired`; the
  cleanup worker's exact result sets `holder_cleanup_acked`, and only that
  worker's exact normal monitor `DOWN` after its acknowledgement sets
  `cleanup_worker_reaped`. A stale result or `DOWN` is a no-op. Abnormal exit,
  a normal `DOWN` without the acknowledgement, or an acknowledgement whose
  normal `DOWN` does not arrive inside the bound selects fatal `runtime_lost`;
  the slot is never freed or reused while that daemon remains alive.

  The only free transition is
  `closing && relay_retired && holder_cleanup_acked && cleanup_worker_reaped -> free`.
  Therefore the
  accepted slot is freed only after no nonterminal origin, waiter, permit,
  request worker or relay task remains and both core owners have acknowledged
  holder cleanup. `release_holder/2` is an internal cleanup operation admitted
  after core's terminal quiescing gate; step 3 invokes it after quiesce and
  successful relay seal, so it cannot be refused by the create/resume/attach
  admission branch. A forced-order witness holds one cleanup call while the
  registry serves status and an unaffected slot; another closes all 512 slots
  and proves cleanup runs concurrently inside the phase bound. Worker crash,
  stale acknowledgement and a live attachment through quiesce prove no early
  reuse and normal registry retirement only after every exact acknowledgement.

  `session.attach` belongs in the ticketed set because its second leg mutates
  dispatcher and `Control` attachment state. A cut that ignored an attach in
  flight could begin its drain while core was still installing one. Its ticket
  is not a mutation ticket for takeover ordering: an attachment grants no
  authority and cannot overtake a durable mutation. Reads, artifact transfer
  calls, `session.acquire_control` and `session.release_control` use lightweight
  in-flight permits rather than mutation tickets. The lease calls change owner
  state but start no core mutation; reads/transfers touch neither `Control` nor
  the journal. The relay counts all of them until their connection task reports
  completion.

  **`session.release_control` is not among the ten**, and the
  distinction is worth one line: it carries `writer_epoch` and
  is lease-authorized, but it starts no core call, so there is nothing for a
  ticket to account for; it takes a retained lightweight permit instead.
  Acquisition does the same through existence validation and owner creation.
  **Reads are not ticketed either.** An earlier
  revision said "every core call the daemon makes", which would have included
  `Loopex.Runtime.next_event/1` — an `:infinity` dispatcher call by
  construction (`runtime.ex:236-244`) — so a quiet observer sitting on a read
  would have blocked every takeover for that session for as long as it sat
  there. A read grants nothing, orders nothing and cannot overtake a mutation.
- **Each ticket has an origin row before a cross-process descriptor, and
  promotion starts the call before acknowledgement.** The connection first
  synchronously installs `pending_ticket(origin_id, class, nil)`. A waiting
  request worker monitors that connection and acknowledges readiness; before
  the connection sends any lease descriptor or claims a lightweight permit,
  the relay binds the exact ticket origin as
  `queued(origin_id, class, worker_pid, worker_monitor, owner_incarnation)`.
  A lease-mutation row also binds the session and current owner incarnation. A
  lease owner promotes that exact row. Create promotion is called by the
  connection registry with the exact activation reservation; attach promotion
  carries its exact attachment reservation and, for replacement, its exact
  borrow. The relay writes
  `ticketed(primary_origin_id, task_pid, task_monitor, reservation_or_borrow)`
  **and spawns the monitored task that performs the core call** before it
  replies. Promotion explicitly retires and reaps the waiting request worker;
  the relay task, not that worker, continues the call. Exact duplicate create
  and replacement origins instead become `waiting(primary_ticket_id)` and
  start no task. A cast would have left the window open at
  the other end: an owner could pass its holder check, send its ticket and die
  before the message arrived, and a replacement would see no ticket for a call
  that was about to be made. Replying before the spawn would open the window
  at *this* end, and an earlier revision did exactly that: the owner would
  hold an acknowledgement meaning "admitted" for a call no process had yet
  been created to make, and a relay that died in between would lose the call
  with the ticket, leaving the client's mutation neither made nor refused. The
  promotion acknowledgement therefore means the ticket exists and a recorded, monitored
  executor was started before the reply. A fast task may already have returned
  or died with its signal queued while the relay is still in that callback; the
  row and monitor remain until the relay consumes that terminal signal. No
  witness relies on `Process.alive?/1` at reply delivery.

  Connection `DOWN` is authoritative in the relay, not in a request worker's
  mailbox. The relay kills and reaps every nonterminal queued or executing
  request worker for that incarnation and selects one winning disposition per
  origin or permit. An unpromoted ticket origin with no compensating work may
  terminalize immediately, while an acquire or release permit remains
  `settling(connection_lost, op_ref)` until ADR 0033's exact provisional-route
  cleanup or release-cancellation acknowledgement; a promoted primary task stays
  retained. It never kills the separately recorded
  lightweight actor merely because that actor appears in the permit: for
  acquire and release that pid is the daemon owner or a lease owner shared with
  other work. A later actor result is cleanup-only after
  `connection_lost`; ADR 0033's compensation removes any provisional
  acquisition route that was not yet visible or restores a release-pending
  owner to `held` at its original deadline. A worker that has not yet been
  bound uses its startup parent-monitor/ready handshake and exits on an already
  dead parent. Thus an `:infinity` call cannot hide connection `DOWN` behind its
  own receive. The closing slot cannot retire until all exact workers are
  `DOWN` and every relay row is terminal.

  Exact lease-owner `DOWN` claims every `pending_ticket` or `queued`
  lease-mutation origin bound to that owner as `owner_lost`, kills and reaps a
  queued worker and starts no core task. A promoted `ticketed` mutation remains
  relay-owned to its real result, fatal disposition or orderly seal. The relay
  retains each unpromoted winner until mirror-pop classification selects the
  returned holder's one uncorrelated close or a non-holder origin's one
  correlated refusal. The predecessor barrier waits for both the classified
  unpromoted origins and promoted tasks before a successor grant.

- **At most one unresolved mutation ticket per session**, which is the
  relay's rule and the answer to pipelining. A client may send several
  mutations on one connection without waiting, and ADR 0023 does not forbid
  it. The connection assigns a monotonically increasing sequence within its
  incarnation and sends each lease-sensitive descriptor to the owner itself;
  request workers never race independent calls into that mailbox. The
  **lease owner** is the only process that makes ticket calls for a session,
  so it is where the sequence-checked queue lives: it holds the client's next mutation
  until its current ticket resolves, replying later with
  `GenServer.reply/2`, and pipelined mutations are therefore admitted in
  arrival order, one at a time. The relay asserts the invariant rather than
  relying on it — a second ticket call for a session that already has an
  unresolved one is answered `{:error, :ticket_outstanding}`, which a correct
  daemon never produces and a case asserts is never produced. What this costs
  is stated: within one session the daemon promises **ordering, not
  parallelism**, which costs nothing real because core serializes a session's
  mutations at its coordinator anyway. What it buys is that "the session's
  in-flight admission set is empty" — the condition ADR 0033's takeover waits
  on, and the condition a lease owner retires on — is a set of at most one,
  decided by one resolution rather than by draining a queue of unknown
  depth.

  **That queue is bounded, and by a number this milestone does not invent.**
  Only the controller connection may mutate a session, so every queued
  mutation for one session came from one connection — and its pending origin
  row already exists at the relay — while ADR 0023 already
  fixes that "no more than 32 requests are in flight per connection"
  (`0023-…-technical.md:332-333`), checked at admission rather than after
  enqueue. So a lease owner holds **at most one unresolved ticket and at most
  31 mutations behind it**, and the daemon adds no second queue and no second
  bound. A client that exceeds the in-flight bound is refused by the rule that
  already exists, at the connection, before any of this. The limits table
  carries the row.

  A queued row also has one death rule. The owner monitors its waiting worker;
  if that worker dies before the owner receives the relay's promotion
  acknowledgement, the owner terminalizes the exact pending row and authorizes
  the generic failure. If the acknowledgement already
  moved the row to `ticketed`, worker death does not cancel or answer it: the
  relay retains the ticket and routes the real result to the connection. The
  owner mailbox serializes that transition with `DOWN`, so a caller is never
  told a mutation failed while the same row can still be admitted later.

  **Two of the ten are not mutation tickets and the rule does not reach
  them**, stated because a rule that silently excluded them would be read as
  covering them. `session.create` has no session to be one-per, its ticket is
  the connection process's rather than a lease owner's, and it already takes
  no part in the per-session grant-blocking rule for the reason given above;
  what bounds activation-capable creates is the activation ceiling and its
  reservation; historical create replays are bounded by the 512-by-32 origin
  ledger.
  `session.attach` is ticketed for the cut alone and its relay task uses the
  connection as the stable holder; what bounds attaches is ADR 0032's
  attachment ceiling and its reservation. Neither is a mutation of an existing session's durable
  state, and neither is in the in-flight admission set a takeover waits on.
  The eight epoch-carrying methods are what the rule covers.

  Replacement attachment coalescing has the same one-primary rule as create,
  but the connection registry owns it. After the relay installs the exact
  pending origin and before promotion or a core call, the registry atomically
  records
  `borrow[target] = {request_binding, primary_ticket_id}`. Injectivity is
  explicit: every live target has at most one borrower. The first request gets
  `primary(primary_ticket_id, borrow_ref)`; an exact repetition gets
  `waiting(primary_ticket_id)` and starts no second relay task or core call; a
  distinct request for that target gets `attachment_conflict`, a terminal
  origin and no borrow. The caller then asks the relay to promote the exact
  primary and start its one task before admission acknowledgement, or to record
  the exact waiter.

  If connection death, worker or lease-owner death, cut, or relay refusal wins
  before promotion, the relay terminalizes the primary and all waiters and
  asynchronously releases `borrow_ref`; it never transfers primary status to a
  waiter. After promotion, the real core result and holder cleanup clear the
  daemon borrow and core's independent pending/live target claim exactly once.
  Primary connection death retains the relay task and borrow until that
  disposition. The forced-order case pauses after the borrow and proves one
  daemon borrow, one Control target, one task and one core call across an exact
  repeat and a distinct conflict, then repeats with pre-promotion death and cut
  and proves zero retained borrow or waiter.

  **That call carries an explicit bound and does not inherit
  `GenServer.call/2`'s hidden default**, which is the same discipline the rest
  of this plan applies to every call that matters. The relay's whole job here
  is to write a row and answer, so the bound is sized for that and for nothing
  else — the implementation states it as an executed count and measures it —
  and a relay that cannot write a row and answer inside it is a relay the
  daemon has lost. An unanswered ticket call is therefore not a silent stall
  inside a client's mutation; it is `relay_lost`, the class that already
  exists for a relay the daemon can no longer account through.
- **The relay installs the monitor during a synchronous owner-registration
  handshake**, before that owner may answer an acquisition or admit its first
  ticket. Registration binds session, owner pid and a fresh owner incarnation;
  a replacement also names the exact predecessor pid and incarnation supplied
  by the daemon owner that observed the exit. Every ticket that owner can send
  is therefore ordered after registration.
- **Every accepted connection uses one origin-row retirement barrier.** Each
  connection registers its pid and incarnation before any request row. A
  `DOWN` moves the accepted slot to `closing` and selects `connection_lost` for
  its pending rows. Rows with no compensating work terminalize, promoted tickets
  stay retained, and provisional-acquire or release-cancellation permits remain
  settling through their exact acknowledgements. It also closes the socket/buffer and starts
  the exact monitored cleanup worker; it does not call `release_holder/2`
  inline. The registry cannot release that slot or attachment capacity until
  all of the incarnation's at most 32 rows are terminal, every request worker
  and ticket task is gone, the relay has acknowledged retirement and the
  cleanup worker has acknowledged both core owners **and its exact normal
  `DOWN` has been consumed**. This row, rather than any
  assumed ordering from connection to owner to relay, prevents a late ticket
  after slot reuse.
- **The relay monitors every lease owner**, so an owner's death is ordered
  *after* the tickets it sent. Message ordering between one sender and one
  receiver is guaranteed by the BEAM — signals from a process to a process are
  delivered in send order, and a monitor's `DOWN` is a signal from the same
  pair — so every ticket an owner sent before dying is in the relay's mailbox
  ahead of that owner's `DOWN`. The relay therefore knows, at the instant it
  learns an owner is gone, exactly which of that owner's calls it is holding.
  The daemon owner's independent `EXIT` observation is not used as this
  ordering point; it only identifies the predecessor a replacement must name.
- **A ticket settles only on a real core result**, and this is the part an
  earlier revision got backwards. The task returning core's answer — any
  answer, including a refusal — settles the ticket. The task **dying without
  one does not**: the relay does not know whether the call reached a
  coordinator, and a delivered `GenServer.call` completes whether or not its
  caller is alive, so "the task died" says nothing about the call. Treating
  that as `commit_unknown` would have admitted a successor while an older
  mutation was still on its way into core, which is the exact hole the relay
  exists to close.

  Before orderly drain reaches its explicit relay phase, a task that dies
  without a result **retains its ticket**, and the relay **exits
  `relay_lost`** — daemon-fatal, the class it already has. That is the
  honest answer: the daemon has lost track of a mutation it authorized and
  cannot say whether a successor would overtake it, and a daemon that cannot
  answer that question must not keep granting leases. It is rare by
  construction, the task's only job being one call.

  An orderly stop has one narrower disposition after its bounded admission
  wait. Immediately before core quiesce, the daemon advances the relay to
  `quiescing(drain_id)` only after its exact ref-tagged acknowledgement. A
  no-result task death then retains an
  unresolved ticket without independently changing the stop to `relay_lost`;
  it grants no successor and claims no core result. After successful quiesce,
  deferred `seal_after_quiesce(drain_id)`, the first consumer of the shared
  teardown deadline, kills every remaining exact task pid concurrently and
  consumes result/`DOWN` ordering against the remaining absolute time before
  replying. A real result sent before
  task exit wins by sender ordering; all other fixed ticket IDs are returned as
  unresolved and abandoned for shutdown, never called settled. Core's barrier,
  census, coordinator termination and fences have by then ordered durable
  mutations. The seal removes a pending attach's unresolved ticket after killing
  the caller task; that work is nondurable, and holder/runtime teardown clears
  any late transaction and charge. If the seal reaches the deadline, the owner
  atomically latches `relay_lost`, notifies the sentinel, sends untrappable
  `:kill` to the relay and enters fail-stop without awaiting its reap or
  reporting operator-stop success. A later relay `EXIT` is cleanup-only. A quiesce error is
  `drain_failed` and never gets a successful seal.
- **A connection disappearing settles nothing**, because the call it made is
  still running inside core; the ticket outlives the connection exactly as the
  call does.
- **The relay never blocks its own loop, and that is why one session's stall
  is one session's.** A grant that must wait on an outstanding ticket is
  **deferred, not waited on**: the relay answers `{:noreply, …}` and replies
  later with `GenServer.reply/2` when the last of that session's tickets
  settles. A relay that ran the wait inside its callback would stop answering
  every other session's ticket calls for as long as one session's mutation
  took, and the bound on a ticket call would then be measuring
  somebody else's core work rather than the relay's own responsiveness —
  turning an unrelated slow mutation into `relay_lost`. With deferral that
  bound measures exactly what it claims to: whether the relay is alive and
  reading its mailbox.
- **A replacement owner's first grant for a session crosses an explicit
  predecessor-retirement barrier.** The relay defers it until it has consumed
  the named predecessor's own `DOWN` and every ticket ordered before that
  signal has settled. Checking the ticket set alone is insufficient: the new
  owner's grant request can reach the relay before both the old owner's ticket
  and `DOWN`, when the set still looks empty. The witness forces exactly that
  cross-sender order and proves the grant remains pending until the old ticket
  arrives, the old `DOWN` is consumed and the ticket settles. This is scoped to
  that session. A create ticket and an attach ticket block no grant: the first
  names no session yet, and the second grants nothing that could be overtaken.
- **The admission cut is the relay's, because the relay is the only process
  that can answer for all ten.** The owner calls it once at the start of an
  orderly stop and the relay **stops admitting and answers at once** — that is
  the **cut**, and it promises nothing about work already inside core. The
  wait for that work is separate, bounded, and then **proceeds**.

  An earlier revision said here that the cut "answers only when every ticket
  it holds has settled". That was the design the bounded wait replaced, and
  leaving the sentence standing gave this file two cut semantics — one that
  waits unconditionally and one that proceeds at a bound — with every witness
  written against the second. One stands: **the cut closes, the wait
  waits, the stop proceeds.**

  What the cut buys is exact: after the cut **no new origin row or lightweight
  permit is issued**. The relay freezes the exact pre-cut origin-ID set. Only a
  pending ticket in that set may promote and start a task before the shared
  admission deadline; at that instant every unpromoted row becomes
  `shutdown_cancelled`, and no later task may start. A promoted task may enter
  `Control`, the dispatcher or the journal after the acknowledgement; the
  bounded wait accounts for every frozen origin and permit. The first core drain operation then
  installs the `Control` admission barrier. Create and resume are whole
  serialized `Control` calls: if one is already being handled, its Store work
  and entry-or-dormant decision finish before the barrier can run; every
  resulting coordinator writer has an entry, while a post-commit owner-start
  failure is dormant with no writer. If the barrier is handled first, it
  refuses before Store access. Attach uses its pending-row
  reservation as its cut, and a mutation that already obtained a coordinator
  route is ordered in that coordinator's mailbox against the drain-specific
  close. The cut is
  therefore a linear admission boundary, not a claim that every pre-cut call
  has already reached core.

That is the ordering claim ADR 0033's owner-loss section now rests on: a
successor's first call cannot be issued while an older call for the same
session is unaccounted for, so it cannot overtake one. The relay grants no
authority, holds no lease and makes no decision about who may control what; it
is a bookkeeping process on the path lease-authorized mutations already take.

Its own failure is **daemon-fatal**, class `relay_lost`, and for the plainest
reason in the fatal map: a daemon whose relay is gone has lost the record of
every in-flight admission and can no longer honour the ordering rule for any
session.

**Beside the fixed set, one lease owner per session**, which ADR 0033 requires
and the maintainer confirmed on 2026-09-20 in preference to one process
holding a record per session. That population is dynamic, and every question a
dynamic population raises is answered here rather than left to the
implementation:

| Question | Answer |
| --- | --- |
| When does one start? | On the **first lease operation for that session after successful existence validation** — an `session.acquire_control`, whether or not the session is active. Not at activation: an earlier revision said activation, which was wrong twice over, since dormant recovery acquires *before* it resumes and `loopex attach --take-over` may acquire and release a session it never activates |
| When does one retire? | When the lease is free — released or expired — **and** no acquisition is waiting **and** the relay holds no outstanding ticket for that session. It performs an acknowledged retirement handshake: relay first marks the exact pid/incarnation retiring; the owner then sends a pre-exit intent to the daemon and waits for its acknowledgement before exiting `:normal`. The daemon can consume that exact EXIT even if it arrives before relay completion. Relay then consumes its own `DOWN`, waits for all earlier tickets and sends completion. Any exit without the pre-exit intent, including `:normal`, is `control_owner_lost` |
| When does one stop unconditionally? | At daemon exit, in the stop sequence below |
| How many can exist at once? | **512 process slots** across `starting_waiting_pop`, starting, live and retiring owners, reusing ADR 0032's per-daemon attachment ceiling. A slot remains charged until the daemon owner consumes the exact owner pid's linked `EXIT`; retirement intent or acknowledgement is not enough. That callback atomically transfers a same-session freed slot to `starting_waiting_pop` but spawns no child until exact mirror pop, owner-loss classification acknowledgement and terminal holder-close or correlated-refusal settlement. An unrelated acquisition that would need a 513th slot refuses `control_capacity_reached`; renewal and release through an existing owner still succeed at the cap. The population is **independent of the activation ceiling**, which counts something else entirely |
| What does its death mean? | That **session's** collaboration state, not the daemon's — the daemon atomically pops only that exact owner's routing mirror before successor install, while the relay retains every `owner_lost` permit until it receives that pop classification. The relay claims pending acquire and release permits whose immutable intended binding names the dead owner, executing permits whose actor binding names it, and pending or queued mutation origins bound to it; an unpromoted mutation starts no core task, while a promoted mutation stays relay-owned to its real result. An origin equal to the returned granted holder suppresses its correlated reply and receives only the uncorrelated close; every other claimed lease operation receives correlated `control_owner_lost` and stays open. Free or retiring owners with no claimed operation notify nobody; relay tickets and predecessor barriers survive in every case |

The retirement acknowledgement is also the memory bound. An acquisition that
arrives before it is held behind that predecessor; one after it registers with
no predecessor. On relay completion the daemon drops the predecessor identity
and the relay drops its tombstone and empty ticket set. A churn test acquires
and releases more than 512 distinct dormant, including unindexed, session IDs
and proves every owner, predecessor and relay map returns to baseline; another
forces an unexpected normal exit while held and proves the session-scoped
failure rather than treating it as retirement. A forced cross-sender case
delivers the linked `EXIT` before relay's post-`DOWN` completion and proves the
pre-exit intent keeps ordinary retirement out of `control_owner_lost`.

The process bound has its own forced-order case. With all 512 slots occupied,
one predecessor pauses after retirement acknowledgement and before exit. A
same-session acquire starts no successor while that pid is alive; after exact
linked `EXIT`, the daemon transfers the freed slot to `starting_waiting_pop`
without `control_capacity_reached`, starts no child before exact mirror pop,
owner-loss classification acknowledgement and terminal holder-close or
correlated-refusal settlement, and only then spawns the successor. Its first
grant additionally waits for every predecessor ticket and retirement
completion. An unrelated 513th-session acquire remains refused
throughout. Thus replacement never creates a transient 513th process or two
live owners for one session, even though the relay tombstone and predecessor
identity may remain for ordering.

**Why not the activation ceiling.** An earlier revision bounded the population
at 64 by pointing at the activation ceiling. That was wrong in both
directions: a dormant session can have a lease owner without ever being
activated, and an activated session whose lease was released and whose tickets
have settled has no owner at all. The two populations are not the same set,
and tying one to the other's number would have made the bound wrong the first
time an operator took control of a dormant session.

**The registry, the custody process and the tracing capability are first, and
that is forced rather than chosen.** ADR 0034 makes the *host* own all three, and for a daemon the host
is the daemon. The runtime's model configuration carries the registry handle
and the token in `options`, so both processes must exist before the
composition function builds that configuration — which means before the
runtime starts, and the composition function starts the runtime at the end of
its own chain, so before the composition call itself.

Links 4 to 8 are the composition's actual chain, not a tidied one: the Store
first, then the artifact placement and the executor's own edges, and the
runtime last within that chain, because it depends on all of them.

**The stop order is the reverse, with one deliberate exception.** Reversed:
listener, then the **connection registry**, then **every lease owner**, then
the **relay**, then runtime,
executor, workspace lease, transfers, then the tracing capability, custody and
the registry — and then **the
Store, last of all**, out of reverse order. The lease owners go before the
relay because the relay is what holds their tickets, and stopping it first
would discard a ticket an owner could still be waiting on. After every
connection and request worker is gone, the owner/relay mailbox barrier freezes
their exact pid/incarnation set and forbids later starts or mirror installs.
That set is stopped as **one collective sweep, not one at a time**, against the teardown deadline:
up to 512 of them exist, and 512 sequential stops inside one teardown
deadline is arithmetic that does not work. The sweep — every stop sent at once, one
wait for all of the exits, a kill for whatever is left at the phase's end —
and the disposition of a lease owner killed that way are written out with
the teardown below. The
Store is moved to the end because its `terminate/2` invokes the best-effort
writer-marker release, and the live Store plus marker must outlive every
operation the owner can end;
custody and registry hold nothing durable, so stopping them before it costs
nothing and keeps the one exception to one line. The socket **pathname is
left where it is**, on this path and every other, for the reason the
socket-ownership rule below gives.

The composition function therefore returns **every pid it linked**, not only
the ones the daemon names in prose: a map carrying `store`, `runtime` (the
`%Loopex.Runtime{}` struct), `runtime_supervisor`, `transfers` (absent when
disabled), `workspace_lease` and `executor`. The registry and custody pids are
not in it: the daemon started them itself, before the call, and already holds
them. Returning the runtime supervisor
pid separately is a convenience rather than a necessity, and the plan says so
plainly: the owner needs that pid to bound its stop, composition already holds
it, so handing it over costs nothing. `%Loopex.Runtime{}`'s type is declared
`@opaque` at `runtime.ex:45`, but that is unenforced here — the repository
runs no dialyzer, and `RuntimeOwner` itself already destructures the field, at
`runtime_owner.ex:200`. An earlier draft called reading it a violation; it is
not, and the real argument is the simpler one above.

**There is no restart strategy, because there are no restarts.** Every one of
the fixed eleven — ten without transfers — is `start_link`ed in the owner's
process, directly by the owner or by the composition function it invokes, as
is each lease owner beside them, and the owner's
`handle_info({:EXIT, pid, reason}, state)` clause is the failure rule. That
clause is also the **reader** the fatal-class map needs — it matches the pid
against the set it holds, maps it to a component, classifies `reason`, and
has the class in hand before anything else happens. Nothing here is
`rest_for_one`, `one_for_all` or `max_restarts`; those words belonged to the
withdrawn design and are gone.

**One field keeps that clause from firing on the owner's own work.** An
earlier draft said "any linked exit, whatever the reason, is fatal", which is
right for an exit the owner did not cause and wrong for every exit it does:
an orderly stop terminates them all deliberately, so that rule would classify
step 1 as `listener_lost`, every lease owner's stop as a lost controller,
step 5's clean return as `runtime_lost` — a daemon that could never exit `0`, and an
idle-shutdown witness that could never pass.

So the owner carries a `stopping` field naming **the component it is
currently stopping and the exact expected-exit mode** — one pid at every step
but the teardown's lease-owner sweep, where it names that step's set of pids.
The modes are `normal_stop`, the listener's `planned_transport_kill`, and
`{:timeout_kill, class}` recorded only after that class has been latched. The
field is set immediately before each stop or owner-issued kill. The EXIT clause
reads:

- an exit from the pid named in `stopping` is **consumed** only when
  `normal_stop` receives `:normal` or `:shutdown`, when
  `planned_transport_kill` receives the listener's exact `:killed`, or when
  `{:timeout_kill, class}` receives exact `:killed` after `class` was already
  latched. The timeout case is cleanup-only and cannot permit exit `0`;
- **every other exit is classified**, including one from the pid named in
  `stopping` whose reason is none of those three, and one from a
  component not yet stopped that dies of its own accord *during* another
  component's stop. A store that fails while the listener is being stopped is
  still `store_lost`, and must be: the daemon is going down either way, but
  the operator is owed the real reason rather than `operator_stop`.

**The field and expected mode narrow *which* exits can be consumed; the reason
decides whether the expectation was met**, and an earlier revision had the pid
field deciding on its own.
That version consumed **any** exit from the named pid, which contradicts the
reason-sensitive rule four steps below and contradicts this file's own
witness: the transfers owner is made to raise inside its `terminate/2` during
a stop the owner asked for, and the case asserts `transfers_lost` rather than
`operator_stop`. Under "any exit from the named pid is consumed" that case
fails. The two rules are one rule now, stated here and applied at step 4 of
the stop driver: **reason first, and the field only says whose `:killed` was
the owner's doing.**

**The owner never calls `GenServer.stop/3` itself**, and the reason is a
result an earlier draft did not have. Every previous version of this section
put the call in the owner and tried to name the shapes it must catch. That
approach is abandoned here, because at a boundary the composition already
admits the call does not raise an *exit* at all.

**The probe.** A trapping `GenServer` whose `terminate/2` takes longer than
the timeout passed to `GenServer.stop/3`, run at both toolchain pairs. The
small values are not session cleanup grace: they model
`remaining(teardown_deadline)` near the shared stop clock's end, which is the
exact argument the adopted driver passes:

| stop timeout | `terminate/2` | what `GenServer.stop/3` did | `Process.alive?` right after | the link exit the owner then got |
| --- | --- | --- | --- | --- |
| 1 ms | 50 ms | **raised `ErlangError`, `:timeout_value`** | `true` | `:normal` |
| 1 ms | 0 ms | returned `:ok` | `false` | `:normal` |
| 5000 ms | 50 ms | returned `:ok` | `false` | `:normal` |
| 10 ms | 500 ms | exited `{:timeout, {GenServer, :stop, [pid, :normal, 10]}}` | `true` | `:normal` |

Identical on 1.18.5-otp-27 and 1.20.3-otp-29. Two things in that table end the
inline design:

- **Row 1 is an error, not an exit.** `:proc_lib.stop/3` computes
  `RemainingTimeout = Timeout - elapsed` after `sys:terminate/3` returns, and
  at a grace that small the subtraction goes negative, so its `receive … after
  RemainingTimeout` raises `error:timeout_value` (proc_lib.erl:1578-1604 at
  the floor pair, :1591-1618 at the current pair). No `catch :exit` clause
  matches an error; the owner would die mid-shutdown with no class, no status
  and the socket left behind — the same failure the last two rounds fixed
  twice, reached by a third route. Chasing shapes is what keeps failing.
- **`Process.alive?` cannot tell success from failure here.** In rows 1 and 4
  it answered `true`, and in both the component then exited `:normal` a
  moment later — it had stopped correctly. A design that kills on "alive after
  the call" turns a successful stop into a killed one; the guard an earlier
  round added on exactly that test is withdrawn with the rest.

**So the stop is driven from outside the owner, and the classification comes
only from the exit the owner observes on its own link.** For each component:

1. The owner sets `stopping` to that component, as before.
2. It `spawn_monitor`s a **helper** whose whole body is
   `GenServer.stop(pid, :normal, remaining(deadline))`, where
   `remaining(deadline) = max(0, deadline - monotonic_now())`. No component
   carries a budget of its own. The helper is monitored, never
   linked, so whatever that call raises, exits or returns dies with the helper
   and never reaches the owner. The owner uses neither its return value nor its
   death reason to classify the component. It does retain the helper pid and
   monitor reference, because the helper itself must be gone before another
   component stop begins.

   **Killing the helper would not cancel the stop it has already delivered**,
   which is the same property that makes a dead coordinator's transaction
   commit and a dead relay task's mutation reach core. That is precisely why
   classification comes from the **exit reason on the owner's own link** and
   never from what became of the helper: the helper is a way to make a call
   without risking the caller, not a handle on the call.
3. The owner then waits on the link it already holds. The wait is a lifecycle
   loop, not a selective receive for the target alone:

```elixir
defp await_component_exit(target, helper, helper_ref, deadline, state) do
  owned = state.owned

  receive do
    {:EXIT, ^target, reason} ->
      state = finish_target_exit(target, reason, state)
      reap_stop_helper(helper, helper_ref, state)

    {:EXIT, other, reason} when is_map_key(owned, other) ->
      state = classify_and_latch_owned_exit(state, other, reason)
      await_component_exit(target, helper, helper_ref, deadline, state)

    {:DOWN, ^helper_ref, :process, _helper, _reason} ->
      await_component_exit(target, nil, nil, deadline, state)
  after
    remaining(deadline) ->
      state = latch_stop_timeout_class(state, target)
      Process.exit(target, :kill)
      await_killed_target_exit(target, helper, helper_ref, state)
  end
end

defp await_killed_target_exit(target, helper, helper_ref, state) do
  owned = state.owned

  receive do
    {:EXIT, ^target, reason} ->
      state = finish_target_exit(target, reason, state)
      reap_stop_helper(helper, helper_ref, state)

    {:EXIT, other, reason} when is_map_key(owned, other) ->
      state = classify_and_latch_owned_exit(state, other, reason)
      await_killed_target_exit(target, helper, helper_ref, state)

    {:DOWN, ^helper_ref, :process, _helper, _reason} ->
      await_killed_target_exit(target, nil, nil, state)
  end
end

defp reap_stop_helper(nil, nil, state), do: state

defp reap_stop_helper(helper, helper_ref, state) do
  Process.exit(helper, :kill)
  await_stop_helper_down(helper_ref, state)
end

defp await_stop_helper_down(helper_ref, state) do
  owned = state.owned

  receive do
    {:DOWN, ^helper_ref, :process, _helper, _reason} ->
      state

    {:EXIT, other, reason} when is_map_key(owned, other) ->
      state = classify_and_latch_owned_exit(state, other, reason)
      await_stop_helper_down(helper_ref, state)
  end
end
```

   `classify_and_latch_owned_exit/3` accepts only a pid from the owner's
   retained component inventory; any other message remains in the mailbox.
   It applies the same reason-sensitive fatal map as the target exit and calls
   the one `latch_first_fatal/2` primitive before it marks that component dead
   and keeps waiting for the target. The lease-owner set uses the collective
   variant specified below.

4. **The reason decides, and a deadline is itself a classified failure.**
   `:normal` and `:shutdown` are the stop the owner asked for, so the exit is
   consumed. Before an orderly deadline kill, `latch_stop_timeout_class/2`
   records the target's existing fatal class: `listener_lost`,
   `connections_lost`, `relay_lost`, `runtime_lost`, `executor_lost`,
   `workspace_lease_lost`, `transfers_lost`, `capability_lost`, `custody_lost`,
   `registry_lost` or `store_lost`; a lease-owner sweep deadline uses
   `drain_failed`. It records that class through `latch_first_fatal/2` before
   it sends `:kill`. The later `:killed` is cleanup-only and cannot erase that
   class. On a fail-stop an earlier class is already latched, so its timeout
   kill likewise preserves the first class. **Every other reason is
   classified**, first class wins, and that is true whether the component died
   before the stop, during it, or of something unrelated at that moment.

`latch_first_fatal/2` is the only nil-to-fatal transition. It captures
`latched_at`, records the class and its unique status locally, and executes the
exact same-sender ordered send
`{:fatal_latched, owner_ref, class, status, latched_at}` to the lifecycle
sentinel before it returns. Every owned-exit classifier, barrier and stop
deadline uses that primitive; a later class is a no-op. The caller therefore
cannot kill a component, continue an orderly stop or enter fatal teardown
until the first latch signal has been sent. Erlang signal ordering makes that
message precede any later owner-exit signal to the sentinel, so owner death at
the next instruction retains the original class and its absolute watchdog
rather than selecting `owner_lost`.

This is smaller than what it replaces and it is total. There is no shape to
enumerate, because the owner reads the one thing the VM guarantees it: the
exit reason on a link it holds. The four-row catch table of the previous
revision, its `{:timeout, _}` / `{:noproc, _}` / catch-all clauses, its
`Process.alive?` guard and its "no daemon component exits with the bare atom
`:timeout`" rule are all withdrawn — they were an attempt to classify a
component's fate from what a library function did to the caller, and row 1
shows that is not derivable.

**What bounds each step.** The outer `receive` waits until that step's
**absolute deadline** — the shared teardown deadline for every non-Store stop,
the Store's own fixed phase for the Store — and the helper is given what
remains of it, so a component is bounded once rather than twice and the step
is bounded whatever the component does. Expiry is non-zero even though the
subsequent unconditional kill guarantees progress. The inner `receive` after the kill
carries no `after`, and needs none: `Process.exit(pid, :kill)` on a live
process is unconditional, and on one already dead the exit the owner is
waiting for is the one that made it dead, already queued. It is a wait for a
signal that exists, not a second bound.

**Every component exit is read while every stop wait runs.** The loop matches
the target pid (or the lease-owner target set), every other daemon-owned linked
pid, and the monitored stop helper. An exit from another component is
classified immediately and the first fatal class is latched; the owner marks
that component dead, keeps stopping the current target, and later skips the
dead component's own step. A helper `DOWN` is consumed without using its
reason. If the target exit arrives first, the target is already gone, so the
owner kills the still-live helper and consumes its exact `DOWN` before another
helper may start; the same cleanup follows the timeout-kill branch. Thus the
one-at-a-time population is literal and no stale helper `DOWN` reaches a later
stop. Client frames and unrelated messages may wait, but lifecycle signals do
not. Immediately before the first
step-3 notification the owner drains already queued lifecycle signals once
more. If a fatal class is latched, it sends that class where the connection
interface still exists, sends no `operator_stop`, and continues through the
crash-equivalent teardown. Once the step-3 notification sweep itself begins,
`operator_stop` is the already-linearized client cause and cannot be retracted;
a later teardown failure still controls `stderr` and the non-zero exit.

Two consequences the sequences below depend on, stated here once:

- **A class recorded during a stop does not abort the sequence.** The owner
  finishes stopping what remains — the components it has not reached still own
  things worth ending — and then halts with that class instead of `0`. The
  first class recorded wins and its latch signal has already armed the
  sentinel; a later one does not overwrite it, so the
  operator gets the reason the daemon went down for rather than the last thing
  that happened on the way out.
- **"Already dead" is something the owner learns, not something it knows.**
  A component is known dead when its exit has been consumed or classified. A
  component that died before the sequence began was classified then and its
  step is skipped; one that dies during the sequence is found at its own step,
  where the helper's call fails in whatever way it fails — which the owner
  never sees — and the wait reads the exit that is already queued. The owner
  never assumes a component is gone from a class recorded earlier in the same
  sequence.

One field, one place, and it is what makes the two paths distinguishable at
all. Both sequences below rely on it, and the idle-shutdown witness asserts
the consequence directly: **no fatal class is recorded during an orderly
stop**.

**Trapping exits does not make an owner crash stop the Store.** The Store
adapter traps (`local.ex:150`) and has no `handle_info({:EXIT, ...})` clause, so
an abnormal exit from its linked owner becomes an unhandled mailbox message;
it does not run `terminate/2`. An orderly explicit Store stop runs
`terminate/2` and attempts marker removal. A Store self-stop also runs that
best-effort callback, as it does today. Either completed callback may leave a
complete residual after an ignored removal or sync error. Owner or VM death leaves a stale
marker for the verified recovery rule. The independent host placement lock,
not a change to `terminate/2`, keeps a successor Control out after Store
self-loss.

The **local executor does not trap**, and the correction matters because two
claims rested on the mistake. Its `init/1` sets no `trap_exit`
(`apps/loopex_executor_local/lib/executor.ex:858-…`; the only `Process.flag(:trap_exit, true)` in that module
is at `:2603`, inside `lease_guarded_work/6`, which runs in a **guardian
process** spawned per bounded job), and the module defines **no
`terminate/2`** at all. Two consequences, re-derived:

- **Stopping the executor is fast, not slow.** With no trap and no
  `terminate/2`, that stop returns about as
  quickly as the mailbox allows. It is not the step that spends the grace; it
  is the step that *starts* the cleanup.
- **The cleanup happens elsewhere, in processes the daemon does not hold.**
  A per-job monitored worker owns the Port, watches the executor, and performs
  the bounded group termination when that authority disappears
  (`apps/loopex_executor_local/lib/executor.ex:3703-3724`). Those workers are not linked to the daemon's
  owner, so the owner cannot wait for them, and the halt that follows ends
  them.

So the residual stated at the executor's step is not confined to a *killed*
executor: **an orderly stop has it too**, because the daemon halts without any
guarantee that the workers finished. The plan does not add a wait for them —
it holds no handle on them, and inventing one would mean an executor API M5
does not have and does not propose. What bounds the exposure is that the
workers begin immediately, that the steps after the executor's stop take real
time, and that nothing durable is at stake: an unreaped process group is an
operator-visible fact, while the journal records `commit_unknown` and
reconciles at the next activation.

The rejected option is recorded with its reasons, because it was tried in an
earlier draft of this pair and looked plausible: **a `Supervisor` with
`max_restarts: 0`**. It fails three ways. With intensity zero the restart
accounting runs before the strategy clause and the supervisor terminates with
reason `:shutdown`, so the child's real reason is logged and discarded —
exactly the information the daemon exists to report. It cannot host the
runtime at all, because of the struct return above. And its own termination
would leave the listener open and no client told, so a fifth component
would have been needed to do the work steps 3 and 4 describe — which is the
owner, arrived at by a longer road.

The second rejected option is moving daemon lifetime and failure policy into
`LoopexComposition`, or widening its existing `start/1` / `with_runtime/2`
bracket so those functions monitor and classify the Store for the daemon. It
is a host convenience application the app server uses and the daemon does not
need for *lifetime*; giving that bracket daemon concerns would put them into an
application whose other caller has none. **The two hosts own lifetime
differently, deliberately**: `LoopexAppServer.Host` keeps `with_runtime/2`,
whose bracket suits a process that lives and dies with one client's stdin, and
the daemon owns its links and policies itself.

**Wiring is a separate question from lifetime, and M5 answers it.** The daemon
still needs everything `loopex_composition` assembles — the executor with its
workspace lease and coding tools, the artifact store, the resolved policy, the
runtime identity, the tool definitions. Duplicating that is not an option the
minimalism budget leaves open. So `loopex_composition` gains **one narrow
public function** that runs its existing edge-assembly sequence **in the
caller's process** and returns the started edges — the adapter pid, the
`%Loopex.Runtime{}` struct and the rest — instead of owning them. The daemon
owner calls it from inside its own trap-exit process, so every link lands on
the owner; `RuntimeOwner` calls the same function from its spawned process, so
`start/1` and `with_runtime/2` behave exactly as they do today. The Concept
file records this as a design decision; this file explains it.

There are **two** ways a daemon ends, and conflating them was a defect. A
daemon-initiated shutdown is the ordered sequence below. A **store loss is a
fail-stop**, and it cannot be that sequence, for a reason in the code rather
than in taste: `Loopex.Store.Local` answers an append error with
`{:stop, reason, commit_unknown, state}`, so it terminates *itself*. Its
`terminate/2` runs and attempts writer-marker release before anything observes the
exit. The Store is gone, while the daemon's host placement lock still excludes
another Runtime Control until this daemon VM has halted. A sequence that ends
"then stop the Store" cannot run when the Store is what died.

**Who may unlink the socket: nobody, except the next daemon that has proved it
holds both the placement lock and the Store marker.** The socket path is not
the daemon's by possession. No shutdown path needs to infer authority from the
Store's current liveness or from a prior ownership check. Such a check and a
later `File.rm` would still be two separate facts with a process death between
them; the design removes that check/use interval entirely.

So the rule is one line, and it has no precondition to get wrong:

- **No predecessor path ever unlinks.** Not the orderly stop, not any
  fail-stop, not reverse cleanup. The orderly stop closes the listener, tells
  clients, and **leaves the pathname where it is**.
- **Only the next verified placement-lock and marker holder may inspect and
  remove it**, at startup, before it binds. It uses `File.lstat/1` and removes
  only a pathname whose uid matches the retained uid of this acquisition's
  placement owner handle and whose mode bits prove `S_IFSOCK`; every other
  present or unverifiable path is preserved and refused. A stale
  `daemon.sock` is therefore an ordinary condition of startup rather than a
  failure of shutdown.

**What that costs, said plainly.** A stopped daemon leaves a socket file
behind. Nothing connects through it — no process is listening, so a client
gets `ECONNREFUSED` rather than a hang — and the next daemon removes it only
after the no-follow owner-and-socket-kind check. An
operator inspecting a stopped root sees a file that looks live and is not,
which the operator page states; that is the price of never removing a file
that might belong to somebody else.

**Three things are deleted from the predecessor path.** The `File.stat`
device and inode guard, which tried to make unlinking safe after ownership had
lapsed. The predecessor's stat-then-unlink race disappears because a
predecessor never unlinks at all. The successor still performs `lstat` and
`rm` as two syscalls in the same-uid-writable `0700` directory; placement
and marker exclusion name the only eligible remover, and `File.rm/1` does not
follow a replaced final path component, but the plan does not claim the object
is immutable between those calls. And **the read-only marker-ownership call the previous
revision added to the local adapter**: nothing else needed it, so
`loopex_store_local` gains no marker query. Its one narrow M5 change is the
retained-create projection through existing `runtime_command/2`; its marker
cleanup, durable format and port shape stay unchanged. Placement exclusion is
shared host code in `loopex_composition`, not Store behaviour.

**`--socket` is constrained to the selected root.** An override must resolve
inside that root's `daemon/` directory — the same directory the default path
sits in, under the same owner and symbolic-link rules — and a path outside it
is refused at startup with `invalid_socket_path`, before the marker is
acquired. Without that constraint two daemons on *different* roots could be
pointed at one path, and the successor rule would have one daemon removing a
path another daemon's marker governs. Inside one root the marker is the
exclusion, there is exactly one holder, and the holder is the only remover.

**How a signal reaches the owner, and when the handler is installed.** The
daemon does not inherit a usable signal disposition; it installs one, and the
order matters more than the mechanism.

`SIGINT` cannot be installed on at all: the emulator reserves it for its break
handler and `:os.set_signal/2` refuses the name outright, which
`LoopexCli.Interrupt` states as a fact about that function rather than about
the command (`interrupt.ex:13-17`). So a terminal `Ctrl-C` reaches a daemon
the only way a reserved signal can — from outside the emulator.
`apps/loopex_cli/bin/loopex` traps `INT TERM HUP QUIT` and forwards
`kill -TERM` to its child (`bin/loopex:60`), so **`SIGINT` is a launcher
concern and `SIGTERM` is the escript's**. A daemon started without that
launcher has no `SIGINT` behaviour to specify, and the plan says so rather
than implying one.

**The daemon installs on `SIGTERM` and on nothing else**, which is smaller
than the CLI's set and deliberately so. `LoopexCli.Interrupt` installs on
`SIGTERM`, `SIGHUP` and `SIGQUIT` because it owns a terminal session: a
closing terminal sends `SIGHUP` to its foreground group and `SIGQUIT` is the
other keyboard interrupt, and an ordinary command run at a prompt should end
on both. A daemon may use the terminal once for the pre-handler project-resource
decision, where default signal dispositions apply and no daemon resource is
held. After that cut it has service semantics: it is run through a launcher or
service manager, both of which stop it with `SIGTERM`. A direct `SIGHUP`
keeps the operating-system default and abruptly kills the VM. Stock OTP handles
a direct `SIGQUIT` by calling `erlang:halt/0`, but installing the daemon's
`SIGTERM` handler removes OTP's default signal handler, after which direct
`SIGQUIT` is ignored. The daemon therefore handles `SIGTERM` and documents
those two measured direct routes rather than assigning them graceful meaning.
The daemon and import handlers must nevertheless remain installed when any
other event arrives: each accepts both the bare-atom and `{signal, pid}` event
shapes and returns `{:ok, state}` for every event it does not act on. Their
final catch-all clauses make an ignored `SIGQUIT` a no-op rather than a
`FunctionClauseError` that removes the `SIGTERM` handler.

**After handler installation the contract depends on the entry point, and the
plan says so rather than giving one answer for two different processes.** It has to,
because `apps/loopex_cli/bin/loopex` traps **`INT TERM HUP QUIT`** and
forwards every one of them to its child as `kill -TERM`
(`bin/loopex:60`) — so what a signal means is decided by whether it lands
on the launcher or on the escript:

| Signal | Sent to the **launcher after handler installation** | Sent to the **escript** directly after handler installation |
| --- | --- | --- |
| `SIGINT` | Orderly stop: forwarded as `SIGTERM` | Not this plan's to specify — `:os.set_signal/2` refuses `:sigint` (`interrupt.ex:13-17`) and the emulator's break handler owns it |
| `SIGTERM` | Orderly stop: forwarded as `SIGTERM` | Orderly stop: the one signal the daemon installs a handler for |
| `SIGHUP` | Orderly stop: forwarded as `SIGTERM` | Abrupt operating-system signal death, status `129`; no orderly cleanup runs |
| `SIGQUIT` | Orderly stop: forwarded as `SIGTERM` | Ignored after daemon handler installation because the installation removes OTP's default handler; the catch-all keeps the handler installed, so a later direct `SIGTERM` remains orderly. Before removal, stock OTP handles `SIGQUIT` as status-`0` `erlang:halt/0` with no dump |

For `daemon prepare-index`, the same routes apply after its own handler is
installed: the four launcher signals arrive as handled `SIGTERM`, direct
`SIGTERM` selects `prepare_index_interrupted`, and direct `SIGINT`,
`SIGHUP` and `SIGQUIT` keep the native dispositions above. The import has no
root-resource prompt. Parser and path-byte validation occur before installation
while no resource is held; the handler and import sentinel exist before the
placement lock or Store marker can be acquired.

Before this table applies, direct `SIGTERM` and every launcher route at the
root-resource prompt take the BEAM emulator's default `SIGTERM` handler and report
status `0`; direct `SIGINT`, `SIGHUP` and `SIGQUIT` retain the emulator or
native dispositions the table names. No handler is present and no daemon
resource has yet been acquired.

So a direct `SIGHUP` kills the escript abruptly, while a `SIGHUP` sent to
the launcher is translated to the daemon's orderly `SIGTERM` route. That is
the launcher's existing behaviour, deliberately left alone. An
earlier revision of this section gave `SIGHUP` and `SIGQUIT` one meaning each
without naming a route, which contradicted the launcher for two of the four.
**Changing the launcher was the alternative and is rejected**: it forwards
all four as `TERM` for every `loopex` command, that behaviour is released, and
narrowing it for the daemon's sake would change what `loopex run` does on
`SIGHUP` in the same change.

The post-handler witnesses are **one per signal per route** — eight route
cases: the four launcher routes plus direct `SIGTERM` assert the five orderly
outcomes; direct `SIGHUP` asserts status `129`, no orderly record or drain
and the recoverable marker, socket and placement residuals; and direct
`SIGQUIT` asserts the process stays live and emits no stop record, then sends a
direct `SIGTERM` and asserts the complete orderly sequence, proving the ignored
event did not remove the handler. The direct-`SIGINT` case asserts only that the
signal reaches the emulator break-handler boundary and does not assert an
orderly daemon result or specify the handler's interactive behavior. This
replaces the `SIGTERM`-and-forwarded-`SIGINT` pair an earlier revision listed.
Five additional cases hold the interactive project-resource prompt before
handler installation, send the four launcher signals and direct `SIGTERM`, and
assert exact status `0`, no readiness, wire record, `daemon.stopping` record or
lifecycle/fatal diagnostic, and no placement lock, Store, socket or component;
they permit the already-written project-resource prompt and the BEAM runtime's
own shutdown notice.

The import adds five handled-route cases after its handler is installed: the
four launcher routes and direct `SIGTERM` each return status `110`, write no
stdout, readiness or wire record, and run the import cleanup below. Direct
`SIGINT` retains the emulator boundary, direct `SIGHUP` abruptly exits with
status `129` and no import cleanup, and direct `SIGQUIT` is ignored after
handler installation; the `SIGQUIT` case then sends direct `SIGTERM` and
asserts status `110` and the complete interrupted-import cleanup, proving the
ignored event did not remove the import handler. Neither direct `SIGINT` nor
direct `SIGHUP` claims interrupted-import cleanup.

For `SIGTERM` the daemon does what the CLI already
does, and reuses the same mechanism rather than inventing one:
`:os.set_signal(:sigterm, :handle)` (the call `interrupt.ex:782` makes per signal), a `:gen_event` handler
added to `:erl_signal_server` (`interrupt.ex:806` and `:818`), and the
**default handler removed** (`interrupt.ex:870-873`) because the runtime's
default stops the emulator immediately, which would end the process before any
of the sequence below could run.

**The installation happens before the marker is acquired**, before the socket
is bound, and before any other resource whose release depends on the daemon
still running. That order is the whole point: with the default handler still
in place, a `SIGTERM` in the window between taking the marker and installing
the handler would stop the VM with no `terminate/2` anywhere, stranding the
marker for the next daemon's stale-writer recovery and leaving the socket file
behind. Installing first costs nothing — there is nothing to shut down yet, so
a signal arriving after handler installation but before the first placement-lock
acquisition ends a daemon that holds nothing. Later startup signals take the
interrupt checkpoints and reverse cleanup, with the residual rules for the
resources already acquired.

**The handler does one thing: it sends the lifecycle sentinel exact
`{:daemon_signal, owner_ref, :sigterm}`.** It runs in `:erl_signal_server`, so it
performs no teardown, holds no state and makes no decision; a stale or wrong
reference changes nothing. The sentinel serializes that message with the
startup phase: before readiness it records the stop pending and forwards exact
`{:daemon_stop, owner_ref, :operator_stop}` to the owner for the next interrupt
checkpoint; during readiness it selects the single startup disposition
described above; after the exact `begin_accept` send it forwards that same exact
stop to the owner for the ordinary shutdown sequence. The owner still runs
cleanup from its own process; the sentinel decides only which startup
disposition won and retains the operating-system exit authority.

**The command process is the lifecycle sentinel, not just an owner-loss
backstop.** It holds the signal route, is the sole readiness arbiter and the
only process that can send the listener's startup release. A nonzero readiness
winner is already its retained first fatal class and status; an operator-stop
winner merely authorizes the owner to halt with status `0` after cleanup
completes. Owner death before that point selects `owner_lost`, so it cannot turn
a readiness failure into `owner_lost` or failed cleanup into status `0`.
Outside that arbitration, the owner's single `latch_first_fatal/2` transition
sends it the exact
`{:fatal_latched, owner_ref, class, status, latched_at}` before any component
kill, continued orderly stop or fatal teardown. The first matching latch wins and arms the absolute
`latched_at + 35_000` watchdog; a later class or owner `DOWN` cannot replace
it. If the owner dies before any matching latch, its monitor selects
`owner_lost` and status `109`; if it dies after one, the sentinel halts at once
with the retained status. In either case it starts an unlinked one-shot stderr
helper and never awaits it. Owner death needs no later signal and no
synchronous diagnostic. This makes the status, rather than an IO line, the
authoritative operating-system disposition.

**The stop is a contract, not an arithmetic.** Earlier revisions of this
section built an eight-phase table, derived each phase's seconds from a count
of sequential Store calls, and summed them into an operator bound. That
derivation was wrong four times in four reviews — once by missing a paging
call, once by missing a commit, once by taking a callback the drain never
waits behind, and once by bounding one of two commit routes — and each
correction moved a number the plan had already published. The maintainer
withdrew the approach on 2026-09-20: **the plan states what the drain
guarantees and how each guarantee is proved; the implementation measures what
it costs.**

So this section fixes the **order** of the stop and the **guarantees** at each
step. There is no useful configuration-independent operational timeout across
every accepted root: the formal bound is finite because cleanup grace is a
bounded unsigned integer and the active writer-domain set is capped, but it is
far beyond an operational service-manager value. The drain clock is derived
from each root's committed cleanup graces. The implementation reports that
root-specific `budget_ms`, names the fixed five-second transport cut, and
selects fixed `admission_wait_ms` and `teardown_ms` values from the
maximum-population witnesses below. The closure evidence records each selected
value and its toolchain, machine and workload conditions, and states every bound
derived from a call count as an executed count. The operator page uses those
inputs, points to those observations on the closure evidence page, and
recommends an unlimited service-manager timeout unless forced cutoff is
intended.

The successful expression contains these universal fixed terms:
`transport_cut_deadline_ms: 5_000`, begun before the relay cut; the selected
`admission_wait_ms`, begun only when that cut linearizes; two sequential uses of
`relay_control_timeout_ms: 5_000`; core's
`quiesce_admission_ms: 70_000`, `status_census_ms: 10_000`,
`coordinator_termination_ms: 330_000` and `fence_budget_ms: 130_000`; the Store
phase's fixed **30 s**, the adapter's own `@call_timeout`
(`apps/loopex_store_local/lib/loopex/store/local.ex:65`); and
`placement_release_ms: 5_000`. Separately, the **fail-stop** watchdog is **35 s
from first fatal latch** and is never an extra successful-stop term.

The operator page states the complete upper-bound expression rather than
leaving these clocks to prose:

```text
T_orderly(root) =
  5_000
  + admission_wait_ms
  + 5_000
  + 5_000
  + 70_000
  + budget_ms(root)
  + 10_000
  + 330_000
  + 130_000
  + teardown_ms
  + 30_000
  + 5_000
```

In order, those terms conservatively charge the complete transport-cut
allowance and then the complete measured post-linearization admission wait,
followed by lease freeze,
the quiescing relay barrier, quiesce admission, root-derived cancellation,
status census, coordinator termination, fencing, measured teardown, Store stop
and placement release. `teardown_ms` already covers the post-quiesce seal,
client close and retirement barriers, the final relay barrier and non-Store
component stops. A stop that latches a fatal class is bounded by the prefix
already spent plus the 35-second fail-stop watchdog, not by adding that watchdog
to the whole successful expression.

The transport work after the relay acknowledgement normally overlaps the
admission wait, but the two clocks do not share a start instant. Charging both
complete terms is the safe stop-receipt bound: a cut may consume almost the
whole transport allowance before `cut_linearization_time` starts the full
admission interval.

**The admission wait has one selected constant and one start instant.** Before
closure, the implementation chooses `admission_wait_ms` from a worst-case
witness with the full 16,384-origin population across 512 accepted connections,
including the slowest permitted pre-cut promotion and owner-start path. The
closure evidence and operator page record the chosen value and the conditions
under which it was measured. The relay cut linearizes once, and at that same
instant the daemon owner and relay store
`admission_deadline = cut_linearization_time + admission_wait_ms`. No promotion,
settlement, timer delivery or later phase restarts or extends it. The value is a
fixed implementation constant for the released candidate; changing it changes
the bound and requires new maximum-population evidence.

**What the cut guarantees.** The owner sends the relay a ref-tagged barrier;
the relay closes admissions and acknowledges that **state change** — one
awaited correlated acknowledgement, not a wait for work. After the acknowledgement **every
post-initialize method on an initialized open connection is refused
`daemon_stopping`**: the ten ticketed core calls, the queries, and ADR 0023's three
artifact-transfer methods alike. Every connection synchronously installs or
claims a relay origin or lightweight permit before dispatch. The relay's
closed-state CAS is the admission decision and returns the correlated refusal;
the connection only renders it. A local connection-state check may
short-circuit the same refusal, but it is never the authority. An accepted
peer that has not completed initialize has no negotiated encoding and is
closed with EOF by the following acknowledged registry transport gate. An earlier
revision gated only the ticketed methods and left reads and transfers entering
core after a cut that claimed to have closed it.

The ten core-changing calls carry tickets. Queries and transfer calls carry
lightweight permits until result or terminal connection disposition. Each row
retains its immutable operation class, connection incarnation, optional session
ID and optional intended actor binding. Before a lease permit is acknowledged,
the daemon owner supplies its session ID and the exact registered lease-owner
pid/incarnation, or its own daemon-owner pid/incarnation for a fresh-owner
acquisition. Relay creation is serialized with the exact owner monitor: owner
`DOWN` first routes the origin into retained owner-loss classification, so no
acknowledged pending lease permit is unbound. Acquire and release carry those
lightweight permits through terminal disposition; every owner/daemon message
includes `permit_id`. A permit
is `pending(nil | {request_worker_pid, request_worker_monitor}) |
executing(actor_pid, actor_incarnation, request_worker_pid,
request_worker_monitor, start_op_ref | nil) | settling(disposition, op_ref) |
terminal(disposition)`,
where the closed dispositions are `result`, `owner_lost`, `connection_lost`,
`shutdown_cancelled`, and `shutdown_admitted` and one relay CAS wins.

For a query, read or artifact transfer, the connection starts a waiting worker.
That worker first monitors the exact connection incarnation and acknowledges
readiness. The connection then asks the relay in one ref-tagged bind call to
retain the worker pid and monitor and compare-and-set its permit
`pending -> executing` with that worker pid and incarnation. Only the relay
performs that CAS, and only after exact success does the relay send `go` so the
worker may dispatch. If the connection dies
before binding, the worker's parent monitor ends it; after binding, relay
connection `DOWN` kills and reaps it even if it is blocked in an infinite call.
Immediately before an existing lease owner mutates lease state it synchronously
claims its permit `pending -> executing` only when its exact pid/incarnation
matches the immutable intended actor. For an acquisition that needs a fresh
owner, the daemon owner claims execution immediately before it asks to start the
owner, retains an exact start `op_ref`, and remains completion authority through
the entire first acquire; the child reports its grant or refusal back to that
owner, which settles the permit. Owner start and routing-mirror install remain
provisional during that first acquire. Every acquisition that changes holder —
whether proposed by an existing owner or a fresh child — uses the same three
registry actions: `install_provisional`, then exactly one of
`resolve_provisional(granted)` or `resolve_provisional(cancelled)`. The registry
installs only for the exact live connection incarnation. The daemon owner
coordinates resolution: after install acknowledgement it compare-and-sets the
recorded actor's permit from `executing` to `result`, the sole grant
linearization. If connection `DOWN` wins `connection_lost`, the daemon resolves
cancelled, tells an existing owner to discard its proposal or kills and reaps
the fresh child named by `start_op_ref`, and exposes no epoch. If `result` wins,
it resolves granted even if the connection became closing after the CAS; only
the promotion acknowledgement exposes the epoch and permits the grant reply. If
an existing actor owner dies after reporting the proposal but the relay wins
`owner_lost` before the daemon's result CAS, the daemon instead resolves
cancelled, exact-clears the provisional row, performs proposal cleanup without
addressing the dead owner, sends one correlated `control_owner_lost` refusal and
leaves the connection open; no epoch is exposed. If the daemon's result CAS wins
first, granted resolution completes and the later owner-loss path closes the
exact promoted holder once. The relay retains every winning permit in
`settling(disposition, op_ref)` until the exact promotion or clear
acknowledgement and proposal/child cleanup, so slot retirement cannot pass
an unresolved mirror. Renewal changes no holder and release removes one, so
neither uses this provisional state. Forced cases order connection death on both
sides of both CAS and resolution acknowledgement and assert these opposite
outcomes.

Release uses one daemon-owned settlement instead of sends to two recipients.
After its combined gate succeeds, the lease owner enters `release_pending`,
admits no later transition and sends only exact
`{:release_proposed, release_ref, permit_id, owner_pid, owner_incarnation,
holder_connection_incarnation}` to the linked daemon owner; it retains the
original absolute deadline and has not yet made the lease free. The daemon
records the operation and asks the relay to CAS that exact executing permit to
`result`. A `connection_lost` winner remains
`settling(connection_lost, release_ref)` without a reply while the daemon sends
the exact cancellation to the owner. A matching owner still in
`release_pending` restores `held` with the original deadline, immediately
expires it if that instant has passed, and acknowledges the daemon; the daemon
then exact-settles the cancellation with the relay, whose acknowledgement alone
terminalizes the permit. Owner death before that acknowledgement makes the
daemon send the relay an exact no-reply supersede, whose acknowledgement
terminalizes `connection_lost`, before ordinary owner-loss pop and
classification handles the dead owner and every other claimed origin; fatal
teardown supersedes both. An `owner_lost` winner preserves the granted mirror for pop
classification. A `result` winner
linearizes release but remains `settling(result, release_ref)` without a reply
while the daemon exact-clears the mirror under the operation deadline. The
daemon then sends `release_mirror_settled`; only the matching relay
acknowledgement terminalizes and renders the correlated success, after which
the owner may enter free or retirement state. An owner `EXIT` ordered after the
proposal is deferred until one of result, cancellation or owner-loss settlement
selects its exact branch, or fatal teardown. If owner `DOWN` makes
`owner_lost` win, the result CAS loses and pop returns the holder. If `result`
wins first, later owner `DOWN` is cleanup, mirror clear makes pop absent and no
uncorrelated close accompanies the correlated release result.

When the daemon records the proposal while serving, it fixes
`owner_restore_deadline = proposal_accepted_at + 5_000 ms` and
`release_settlement_deadline = proposal_accepted_at + 10_000 ms`. Neither
restarts. The initial result CAS, owner cancellation/restoration and any result
branch mirror clear must be accepted before the first instant. The exact relay
cancellation or result-settlement acknowledgement must be accepted before the
second. A missing or malformed relay answer at either exchange is `relay_lost`;
a result branch whose registry clear misses the first instant is
`connections_lost`. On a connection-loss branch, a missing, malformed or late
owner restoration acknowledgement at the first instant makes the daemon kill
that exact owner and begin the no-reply cancellation supersede before ordinary
session-scoped owner-loss pop and classification; the supersede acknowledgement
must beat the second instant or select `relay_lost`. A queued-late owner or
relay acknowledgement is cleanup-only at its respective instant. If the
orderly admission cut linearizes first, both serving timers become cleanup-only
and the exact row joins the frozen pre-cut set: it may settle only through the
fixed `admission_deadline`, and any remaining exact cleanup and terminal CAS
must finish inside the later `freeze_lease_ops` barrier's `freeze_deadline`.
Shutdown starts no operation-private extension, so neither `release_pending`
nor a settling permit can outlive its governing bound.

The request worker is not the completion carrier once a call is delivered; the
exact lease owner or daemon owner reports the terminal result.
The cut returns exact ticket and permit IDs, moves lease routing to `draining`
and acknowledges at once. Any frozen pre-cut permit may still claim execution
before the one absolute admission deadline; only an
acquisition can start an owner.

The relay and daemon owner retain that same monotonic deadline independently.
Every relay `pending -> executing` CAS, daemon owner-start or mirror acceptance,
and continuation after child start or registry acknowledgement rechecks it.
Crossing the instant wins even while the timer message is queued. The daemon
owner first enters its own deadline-checked `lease_ops_frozen` state and calls
the relay's idempotent `freeze_lease_ops(admission_deadline)`. The relay rechecks
the instant, atomically changes routing from `draining` to `lease_ops_frozen`,
terminalizes pending rows, atomically CASes every still-`executing` lease permit
to terminal `shutdown_admitted`, and retains and returns one fixed tagged cleanup
descriptor set. Barrier-owned rows use
`{:shutdown_admitted, permit_id, class, actor_pid, actor_incarnation,
start_op_ref}`;
proposed releases whose relay disposition is already selected use
`{:settling_release, permit_id, disposition, actor_pid, actor_incarnation,
release_ref}` for `result` or `connection_lost`. A holder-changing acquisition
whose disposition is selected while provisional resolution or child cleanup
remains uses `{:settling_acquire, permit_id, disposition, actor_pid,
actor_incarnation, start_op_ref, op_ref}` for `result` or `connection_lost`.
An acquire or release whose `owner_lost` disposition has won uses
`{:settling_owner_loss, permit_id, class, actor_pid, actor_incarnation,
op_ref}`. It may have no accepted daemon operation record, or may have the exact
acquire/release record whose later result CAS lost. The immutable actor binding and,
where one exists, the daemon's exact retained `release_ref` and acquisition
`op_ref` records make the set complete without a map scan or inferred winner.
If result, connection loss or owner loss wins before the atomic freeze CAS, the
row appears in its exact settling variant; if freeze wins, the late actor result
is cleanup-only. Later freeze calls return the same set. No
post-deadline claim can join it. A child
materialized across the instant is killed and reaped before grant; a late mirror
acknowledgement is cleanup-only and follows the exact-registry
kill/`connections_lost` rule.

At that deadline the relay changes `pending` rows to `shutdown_cancelled`, sends correlated
`daemon_stopping` where a socket remains, and kills and reaps those request
workers. An executing non-lease query, read or transfer remains tracked through
its result or step 3; connection `DOWN` there makes the relay kill and reap the
exact actor and terminalize it `connection_lost`. The
owner rejects and terminally records queued owner-start or mirror work as
`shutdown_admitted`, creating no child or row. For a barrier-owned
`shutdown_admitted` existing-owner
operation it consumes the returned descriptor, kills and reaps that exact
lease-owner actor, exact-pops its pid/incarnation mirror, joins the result with
the relay's exact owner `DOWN`, and terminalizes every owner-loss-claimable lease
permit and pending or queued mutation origin with no ordinary owner-loss client
output. A promoted ticketed mutation remains relay-owned to its real core result,
fatal disposition or orderly seal. The barrier has already won the target permit
before destructive cleanup begins; a late actor result is cleanup-only. Cleanup
is idempotent and the mirror must be absent before core quiesce. For a fresh
acquire, whose descriptor actor is the daemon owner, that owner survives. Its
retained exact start record keyed by `start_op_ref` must say `not_materialized`
or carry the exact child pid/incarnation; the owner tombstones the first or kills
and reaps the second, first resolving any installed provisional mirror cancelled
and requiring its absence before quiesce. Missing or mismatched start state
selects `relay_lost`. It never infers actors by scanning its
owner map. `shutdown_admitted` is the terminal disposition authorizing that
exact cleanup, not a claim that a linearized mutation rolled back.

For a settling release it requires the daemon's matching retained `release_ref`
record. A `result` row finishes or confirms mirror clear, terminalizes without
rendering after the cut and acknowledges its owner into free or retirement
state. A `connection_lost` row whose owner already restored finishes its
no-reply settlement and leaves the holder for the drain; an unresolved restore
kills and reaps that exact owner, exact-pops and classifies the mirror without
client output, sends the cancellation supersede and terminalizes the retained
disposition. A `settling_acquire` descriptor requires its exact retained
`op_ref` record: `result` finishes or confirms provisional grant without a
post-cut reply and retains the owner for drain, while `connection_lost` finishes
or confirms provisional cancellation and discards an existing-owner proposal or
kills and reaps the exact fresh child. A `settling_owner_loss` descriptor
completes its retained exact `DOWN`, pop and classification join without client
output. It may have no daemon operation record; a matching release record is
tombstoned, while a matching acquisition record finishes provisional
cancellation and proposal/start cleanup. A missing record whose accepted phase
requires one selects `relay_lost`, and unfinished mirror cleanup selects
`connections_lost`. A permit's selected disposition is immutable if its exact
lease owner dies later. That is the recorded actor owner for an existing-owner
operation and, for a fresh acquire whose `result` granted, the resulting child
lease owner named by the retained start record; it is never the daemon owner
that acted as completion authority. The owner first completes that descriptor's
release or provisional settlement, then consumes and reaps any retained or
newly arrived exact lease-owner `DOWN` and exact-pops and classifies the mirror under the same
`freeze_deadline`, with no ordinary output. A restored `connection_lost`
release completes cancellation before owner loss; an acquire or release
`result` stays `result`, and the later pop is present or absent according to
the mirror state that settlement produced. No new clock or disposition begins.
Missing or mismatched required release state, malformed relay answers or
relay cleanup past `freeze_deadline` select `relay_lost`; mirror work past it,
including a mirror left after an executing-owner kill, selects
`connections_lost`. Ordinary owner-loss client handling is
suppressed because shutdown owns those deaths and dispositions. A pending
mirror atomically latches
`connections_lost`, notifies the sentinel, sends untrappable `:kill` to the exact
registry and enters fail-stop without awaiting its reap; its later linked `EXIT`
is cleanup-only. Idle and granted lease owners remain through
quiesce. After quiesce and the step-3 connection/request-worker barrier, the
  relay and daemon owner both enter `tearing_down`, freeze the remaining owner set
  and sweep it in step 4. Thus no pre-cut start or mirror crossing the first
  barrier can be authorized, produce a grant, install a mirror or survive cleanup, and no
  owner can appear behind the second.

A read or transfer completed inside the bound returns normally; a still-pending
one becomes `shutdown_cancelled` and changes neither durable nor Control state.
One already claimed and dispatched remains `executing` until its result or the
step-3 connection/worker barrier, without extending the admission wait.
A pre-cut ticketed task may not yet have entered core when the cut answers. The
first operation inside `quiesce/1` then installs core's terminal admission
barrier. An existing `Control` entry is classified and fenced; a create, resume
or attach still before its first `Control` operation refuses there and cannot
create a late entry. A mutation that already obtained a coordinator route is
ordered against that coordinator's drain-specific admission close. The cut
never treats a started task as though it had already linearized merely because
its ticket or permit exists.

**What the abort admission guarantees.** Quiesce first atomically sets
`quiescing: drain_id` in `Control` and returns the initial entries and ordinary
coordinator pids. It then sends a drain-specific call to each active
coordinator; in that mailbox the call closes ordinary command admission before
   it proposes the existing abort command — a command ID deterministically
   derived by `SessionState.drain_abort_command_id/2` from the session ID and
   pre-admission owner epoch. The Store binding, but not the identity derivation,
   still includes the exact
   journal version, owner incarnation and canonical abort digest, and a commit that is
   **presented once** rather than re-presented on an ambiguous answer, the two halves of core
change 4's coordinator change — and it admits **only into an `:active`
entry**, `Control` writing that status at the instant an owner is ready
(`control.ex:575-591`). Only `:active` proves through Control that the
coordinator is ready and safely addressable for this admission. A non-active
entry may already have a ready coordinator while its `owner_ready` cast is in
flight, but quiesce cannot safely infer that state and therefore admits no
abort through it.

An ordinary command processed before the drain call is included in the abort;
one processed after it refuses `runtime_unavailable`. Internal commit,
cancellation, receipt and recovery messages remain allowed. Therefore a
`rejected_no_active_run` answer proves no delayed routed prompt can start later.

**The invariant is global, and it is the one the Concept promises.**
Cancellation is released **only when every admission either committed or
definitively refused `rejected_no_active_run`**. A failed, ambiguous or
unanswered admission releases **no cleanup for any session**: the census is
terminated and fenced instead. An earlier revision
released cleanup per session once that session's own admission resolved, which
makes "every abort durable before any cancellation begins" true one session at
a time and false across the daemon — the thing the split exists to prevent.

**What settlement means.** A session is `settled` exactly when the run the
drain aborted has its **terminal fact committed**, read on the coordinator's
`{:session_status, owner}` reply (`session_coordinator.ex:414-442`), where a
committed terminal means the run appears in neither `active_run_id` (`:421`)
nor `pending_work_ids` (`:425-426`). That read carries its own five-second
bound and **any answer but `{:ok, status}` means not settled** — a coordinator
that refuses, times out or is gone is not a settled session. An abort answered
`rejected_no_active_run` (`session_state.ex:1750-1761`) is `settled`: there
was nothing to cancel and nothing is owed.

**Then termination, then the fence, over one frozen entry set.** The later
enumeration reads under the terminal transition the first census already
installed. A delayed create, resume, attach or ordinary route may not insert a
key or start an ordinary coordinator after that barrier. No lifecycle
continuation may insert or delete a key or start a replacement ordinary
coordinator either. `owner_ready` may complete a pre-cut acquisition and
update its retained entry; `owner_replayed` may return the historical result
but retains a non-routable entry. A quiescing `:awaiting_owner_barrier` branch
answers its waiters `runtime_unavailable` and retains or converts the entry
instead of deleting it before the gated `do_start_owner/6`. The later
fence-mode start is the one explicit new start under the gate. Every ordinary
coordinator in the later status projection is
terminated and every `DOWN` awaited **before** any fence commits, so no fence
races a live writer. The second read observes status and coordinator changes
for exactly the first census's keys. All termination work shares the fixed
`coordinator_termination_ms: 330_000` absolute phase deadline. Only after every
termination succeeds does all fence work share a new fixed
`fence_budget_ms: 130_000` absolute phase deadline. Within the termination phase,
"concurrent" means **issued together, not served together**:
`DynamicSupervisor.terminate_child/2` is a call into the **one** session
supervisor, so terminations queue behind each other there — two children that
take half a second each cost about a second, not half of one. The plan says so
rather than implying a parallel stop the supervisor cannot give.

**What abort recovery and the fence guarantee.** Every session ID in the frozen writer-domain set gets one fence disposition.
Entries outside that set are omitted from the projection and result and start no
worker. If abort admission was ambiguous, the fence-mode
coordinator first queries that head-derived abort transaction ID. A terminal
commit is replayed before fencing; a terminal non-commit proceeds; `:absent`
is non-terminal and proceeds to the fresh compare-and-swap below, which orders
against a delayed abort; and `:unavailable` proposes no new mutation and returns
`{:unknown, :abort, head}`. After a bounded ownership-head read supplies the
inputs, it makes at most one
   `advance_owner` attempt, whose identity derives from `(session_id,
expected_owner_epoch)` so a successor can recompute it, while journal version
remains in the immutable transaction binding. Only a **committed**
fence proves the epoch moved; after that commit no prior-epoch transaction can
commit and the adapter refuses it `:stale_owner_epoch` (`state.ex:548-551`). A
stale refusal establishes no new fence fact and is classified conservatively;
an unresolved `commit_unknown` proves neither outcome until the exact binding is
re-presented. A **committed** fence
**preserves the classification the session already had**: a settled session
stays `settled`, an unsettled one stays `unsettled`. An earlier revision's
table reported every committed fence as `unsettled`, which contradicted the
settled-and-fenced case two paragraphs above it. A fence refused stale is
**not reattempted and not reconciled from the journal**: the session is
reported `unsettled` with `fence: :superseded`, which is the conservative
answer and costs no further Store call. A fence answering `commit_unknown` is
resolved by one byte-identical re-presentation of the retained `advance_owner`
transaction. A matching committed result is `:committed`; a matching stale
non-commit is `:superseded`; conflict, unavailable, malformed, another
`commit_unknown`, or any other nonmatching refusal remains
`{:unknown, :fence, head}`. A normal fence costs at most three Store calls: head
read, first transaction, exact re-presentation. An ambiguous abort adds one
preliminary status call and therefore costs at most four.

**There is no entryless activation residual at the barrier.** Create and
resume do make Store calls before `await_owner/9` writes an entry
(`control.ex:896-897`, `:959-965`, and `:1176-1212`), but those calls and the
entry decision run inside one serialized `Control.handle_call/3`. Control
cannot service `begin_quiesce/1` in the middle. If create or resume is handled
first, it either proves an exact no-activation replay with no live writer,
finishes its Store work and installs an entry before Control reads the next
message, or leaves a committed create dormant after owner-start failure with no
writer. If the barrier is handled first, the later call refuses before its
Store operation. A forced witness pauses each branch at the Store boundary and
proves those two orders. Attach spans two processes and therefore uses the
separate pending-reservation cut specified below.

**The teardown stops the lease owners as a collective sweep, not one at a time.**
Up to 512 of them exist, and stopping them in sequence inside one teardown
deadline was arithmetic nobody did: the owner spawns one stop helper **per lease owner, all
at once**, then waits in **one** loop until every one of those pids has
produced an exit on the owner's own link — the same link it already holds, so
the exits are `{:EXIT, pid, reason}` and not monitor `DOWN`s — **and** every
monitored helper has produced its exact `DOWN`. The owner retains the injective
`owner_pid -> {helper_pid, helper_ref}` map and the reverse helper-reference
map. A lease-owner exit first makes it kill that owner's still-live helper and
keep both charges until the helper `DOWN`; a helper `DOWN` first removes only
the helper charge while the owner remains awaited. At the phase deadline the
owner latches `drain_failed`, sends untrappable `:kill` to every remaining
lease owner and helper at once, and consumes every exact owner exit and helper
`DOWN` before continuing. Killing a helper at that point cannot lose a stop:
the target is killed independently by the same deadline path. The forced
witnesses cover owner-exit-first, helper-DOWN-first and deadline orders at the
maximum population, return both populations to baseline, and leave no helper
`DOWN` for the next teardown step.

**Two rules bend exactly here, and only here.** The `stopping` field names one
component elsewhere; for this step it names the **set** of lease-owner pids.
And the reason rule bends with it: for a pid in that set **every** reason is
consumed, not only the three. That is not an exception to classification but
a consequence of the fatal map — **a lease owner has no daemon exit class at
all**, its death being session-scoped, so there is nothing for a non-`:normal`
reason to be classified *as*. Its session-scoped handling is a no-op here
because step 3 has already closed every connection, so there is no controller
attachment to close and no `control_owner_lost` to send. An earlier revision
left the general rule in place over this step, which would have classified a
lease owner's crash during the sweep into a class the map does not contain. And the two selective receives elsewhere match one pid; here the
loop matches **any** pid in the set and removes it, which is the same
discipline over a set rather than a singleton. Nothing else in the sequence
sweeps, so nothing else needs either form.

The disposition of a killed lease owner is
stated: it loses nothing durable — it holds a lease
record, an epoch and an in-flight admission set, none of which outlives the
daemon — and the relay's tickets, which do matter, are held by the relay and
stopped after them. Its session's controller connection is already gone, step
3 having closed every connection, so a lease owner ended here produces no
`control_owner_lost` and there is nothing left to send one to.

**`budget_ms` is still core's to derive and report**, for the reason below:
it bounds the drain's own wait, and it is the one figure in the stop that no
part of the daemon can compute.

The budget is derived rather than chosen because the cancellation it waits on
is already bounded by core: `cli_backstop_ms` is the number core itself says a
liveness backstop must cover for a session with that grace, so a drain that
waits exactly that long waits neither less than the cancellation needs nor
longer than core can justify. Taking the maximum over the drained sessions —
not the sum — is what keeps the bound flat as sessions multiply.

**And core derives it because the daemon cannot.** Each `g_i` is the grace
that session **committed**, read from its durable state
(`session_coordinator.ex:422`); the daemon's `--cleanup-grace-ms` is the
default a *new* session is composed with (`control.ex:894`), not a fact
about sessions already in the root. A root carrying sessions created under an
earlier composition therefore holds graces the daemon has never seen. An
earlier revision had the daemon compute the budget from its own option, which
would have been wrong for exactly the roots a daemon is for. So `quiesce/1`
derives it from the durable graces and **returns** it as `budget_ms`, and the
daemon reports that figure rather than one it assumed.

**The Store phase is fixed, not `max(g, 30_000)`.** The previous revision's
`max` made an operator's grace able to *lengthen* the Store phase, which is
the one phase whose length has nothing to do with any session. Thirty seconds
is the Store's own bound on its synced call path, and releasing the marker is
that same class of work — `File.read`, `File.rm`, a parent-directory sync
(`writer_lock.ex:105-115`). **The usual release takes milliseconds**; the 30 s
is a ceiling that matters only when the filesystem is wedged, which is exactly
when killing the Store mid-release is worst. The same fixed phase applies in
the failed-start reverse cleanup, for the same reason.

**The teardown has one deadline covering every non-Store action after the
drain, and the implementation measures it rather than this plan naming a
number.** An earlier revision named the clock and never gave it a value,
which left every "what remains" reference undefined; the revision after that
named a number and derived an operator bound from it, which the maintainer
withdrew with the rest of the arithmetic. What this plan fixes is the shape:
**one deadline, `teardown_ms`, covering every non-Store action**. Its measured
selection includes a healthy seal of the hard maximum 16,384 relay tasks, the
512-connection collective close and retirement barrier, the lease-owner sweep,
runtime stop/kill and edge cleanup on both toolchain pairs. Notification writes
remain one attempt into an existing buffer and closes remain closes. The figure
the implementation settles on, with the maximum-population timing evidence, is
the one the operator page carries.

**One process under this deadline is not like the others, and an earlier
revision's justification was false for it.** That revision said "of the
processes stopped here only the transfers owner runs a `terminate/2` at all",
which forgets that **the runtime stop is inside the teardown**:
`Supervisor.stop(runtime_supervisor, :normal, remaining)` brings down a tree
whose `OwnerGroup` children trap exits, carry `shutdown: :infinity` and have a
`terminate/2` that stops their own worker supervisor with `:infinity`
(`owner_group.ex:14-19`, `:50`, `:86-90`). Nothing bounds that from inside.

So the rule is the one this file already argues for the kill path, applied
honestly here: **the runtime stop is attempted with what remains of the
teardown deadline and killed at it.** A tree killed that way is crash-equivalent in the
only sense this plan ever claims — about the journal, not about processes —
and its trapping descendants go on unwinding on their own clock afterwards,
which the daemon does not wait for and the halt at the end of the sequence
ends. `teardown_ms` is therefore a ceiling for the work the teardown
*performs*, not a promise about what the runtime's subtree has finished, and
the drain is why that is affordable: by the time step 5 runs, every
coordinator quiesce could not settle has already been fenced and terminated
inside core. The closure obligation carries the measured figure into the
operator page with that rationale.

**The teardown deadline starts when `quiesce/1` returns**, and its first consumer
is the deferred relay seal. It then covers every remaining non-Store action: the
stop records, the connection closes, the relay's final mailbox barrier, and
every stop from the lease owners through the registry. The listener was already
killed and reaped under the transport-cut deadline and is not charged twice.
Every helper under it is given `remaining(teardown_deadline)` and nothing
else — no component has a budget of its own to spend — and the collective
sweep above is what makes 512 lease owners fit inside it.

**`budget_ms` is not knowable from the daemon's flags alone**, and the
operator page says so rather than implying a constant. The composed
`--cleanup-grace-ms` bounds sessions this daemon creates; a root may carry
sessions created under earlier graces. The figure actually used is reported on
the stop line as `budget_ms`, beside the fixed `fence_budget_ms`, `drain_id` and
the three counts. It is not
on `daemon.status`, because the daemon cannot derive it before core reads the
root's active session state. The documented default is therefore an unlimited
service-manager stop timeout. An operator who chooses a finite timeout treats
the last observed budget and fixed-cost measurement only as evidence for that
root and workload, not as a universal bound. If the manager kills the daemon
sooner, the stop is forced: the journal remains crash-equivalent, work that
would have settled may not, and the marker may be left for verified recovery.

**Every wait is an absolute deadline, sliced — because the BEAM's `after` has
a domain the plan must respect.** Core admits a `cleanup_grace_ms` up to
`18_446_744_073_709_551_615` (`@max_cleanup_grace_ms`,
`apps/loopex/lib/loopex/executor.ex:75`), and the derived budgets above are
sums of such values. A `receive … after` does not accept numbers that large.
Probed at **both** toolchain pairs:

| `receive … after` | 1.18.5-otp-27 | 1.20.3-otp-29 |
| --- | --- | --- |
| `4_294_967_295` | accepted (waits) | accepted (waits) |
| `4_294_967_296` | **raises `error:timeout_value` at once** | **raises `error:timeout_value` at once** |
| `18_446_744_073_709_551_615` | **raises `error:timeout_value` at once** | **raises `error:timeout_value` at once** |

The limit is 2^32-1 milliseconds, about 49.7 days, and exceeding it is not a
long wait but an immediate error in the waiting process — which for the owner
would be a shutdown that never runs. Nothing in this repository slices a wait
today, so the rule is stated here:

- **Every wait is an absolute instant**, `System.monotonic_time(:millisecond)
  + budget`, computed once. Deadlines compose by comparison, and every
  remaining-time helper clamps subtraction with
  `max(0, deadline - now)`, so no arithmetic can produce a negative `after`
  — the other way `after` fails.
- **Every wait is taken in slices of at most `@wait_slice_ms`, 60_000** — the
  obligation falling on **`quiesce/1`'s own waits**, the cancellation being the only
  bound that is unbounded by construction and core being where it is
  enforced; every other wait is a fixed number far inside the domain. A
  minute is long enough that slicing costs nothing measurable and short
  enough to be far inside that domain. After each slice the waiter compares
  the clock with the deadline and either waits again or gives up. A budget of
  any admitted size is therefore reachable, and no `after` argument is ever
  larger than the slice.
- **The composition-input table says what a huge value does**: it is accepted,
  not refused, because core accepts it; the daemon simply never passes it to
  `after` unsliced. An operator who composes a grace of a year gets a daemon
  that waits a year, in minute slices, rather than one that exits instantly at
  the first stop.

**Daemon-initiated shutdown is a drain and then a teardown, in reverse
order.** `SIGTERM` reaches the lifecycle sentinel — sent directly, or forwarded
by the launcher from a terminal `SIGINT` — and after readiness the sentinel
forwards the exact stop to the owner, which performs these six
steps itself. They are the owner's code, not a supervisor's behaviour, which
is what lets each one carry a reason and lets the teardown use one deadline
the owner fixes.

Every owner-to-relay lifecycle transition below is **synchronous in
sequencing and asynchronous in process mechanics**. The owner sends
`{:relay_barrier, barrier_ref, action}` and advances only after the exact relay
answers `{:relay_barrier_ack, barrier_ref, action, payload}` before that
barrier's absolute instant. It waits in the same all-owned-exit receive loop
used for component stops, so Store, runtime, registry and other linked exits
remain classifiable while the relay is alive but suspended. A stale or
wrong-reference answer satisfies nothing; a malformed answer from the exact
relay, or no exact answer by the instant, latches `relay_lost`, sends
untrappable `:kill` to that exact relay, consumes its linked `EXIT` as cleanup
when it arrives, and enters fail-stop without running the next orderly step.
No timeout infers a payload or reconstructs one from the daemon owner's maps.

1. **The relay closes admissions first; then the transport stops accepting —
   an acknowledged sequenced cut, not a policy.** An earlier revision said "the daemon
   refuses new admissions from that instant" and left the instant undefined:
   stopping the listener stops *new connections*, while every existing
   connection process is still free to submit, and `session.create` did not
   even pass through the relay. Quiesce would then have been snapshotting a
   set of sessions that could still grow underneath it.

   So the cut is a ref-tagged send **and then a wait**, which an earlier
   revision folded into one step it could not possibly contain. Before sending
   it, the owner computes the one absolute
   `transport_cut_deadline = now + transport_cut_deadline_ms`; that same
   instant covers the relay acknowledgement and every later transport action
   in this step. The owner asks the **relay** — whose scope this
   extends to cover `session.create` and `session.attach` as well as every
   ticketed mutation, ten calls in all — and the relay **closes admissions and
   answers at once**: an acknowledgement of a state change, bounded by the
   remaining transport-cut time and on nothing else. The reply carries the exact
   retained ticket IDs and exact lightweight permit IDs, moves lease routing to
   `draining`, and freezes which pre-cut permits may still claim execution
   before the absolute admission deadline; only an acquisition may finish
   validation and reserve a future owner start.

   A relay suspended before the exact acknowledgement therefore reaches the
   shared instant as `relay_lost`; the owner latches the class, notifies the
   sentinel so the 35-second fail-stop watchdog is running, sends untrappable
   `:kill`, and neither the transport nor core success path begins. Its later
   linked `EXIT` is cleanup-only and is never awaited outside the expired
   transport-cut deadline. **Only after that authoritative
   acknowledgement** does the owner stop the
   transport. It first asks the connection registry to atomically enter
   `transport_closing(cut_ref)`: the acknowledged state rejects every later
   provisional reservation or promotion and marks every existing provisional
   or uninitialized row for EOF close. The owner then marks the listener
   intentional, sends untrappable `:kill`, and waits for its exact linked
   `EXIT`. Only after that exit proves no later `accept` can arrive does the
   registry close and reap the complete marked uninitialized set and
   acknowledge it empty. A peer racing between the relay cut and registry gate
   may occupy a provisional slot briefly, but can never initialize; after the
   registry acknowledgement no new slot can be created. Gate acknowledgement,
   listener reap and the final uninitialized sweep share one fixed absolute
   `transport_cut_deadline_ms: 5_000` **begun before the relay cut**, never a
   fresh five seconds; an absent listener exit selects
   `listener_lost`, while either absent registry acknowledgement selects
   `connections_lost`, and either atomically latches its first fatal class,
   notifies the sentinel and enters fail-stop. A missing registry acknowledgement
   sends untrappable `:kill` to the exact registry without awaiting its reap; a
   late registry or listener exit is cleanup-only after its class is latched. All three waits use the owner's
   all-owned-exit loop. Initialized connections
   survive for their correlated post-cut refusals and the later stop record.
   The owner then waits for the exact pre-cut relay rows for the measured
   admission bound; a post-cut request can start no owner.

   Folding the two together was the defect: a ticket settles only when its
   core call answers, a prompt's commit is bounded by the Store's 30 s and by
   core's one retry, and `SessionCoordinator.command/3` waits `:infinity` for
   it (`session_coordinator.ex:146-149`) — so a `SIGTERM` arriving during any
   ordinary prompt would have blown an acknowledgement sized for a relay and
   turned an operator stop into `relay_lost`. Refusing new work is instant; waiting
   for admitted work is not, and the two now have their own bounds.

   **At the wait's bound the stop proceeds**, and what that costs is stated. A
   still-running mutation normally leaves its session `:active`; a create or
   resume that reached owner acquisition may leave `:acquiring`. Both appear
   in the first core census and are terminated and fenced. A create, resume or
   attach task still before its first `Control` operation refuses at the early
   quiescing barrier and creates no late entry. A mutation that already obtained
   a coordinator route is ordered against that coordinator's drain-specific
   admission close; its pre-cut ticket remains accounted for. At the bound the
   daemon owner enters its own deadline-checked `lease_ops_frozen` state,
   computes a fresh absolute
   `freeze_deadline = now + relay_control_timeout_ms`, and sends the relay's
   idempotent `freeze_lease_ops(admission_deadline)` barrier with a fresh
   reference. `relay_control_timeout_ms` is fixed at **5,000 ms**. The earlier
   admission deadline remains the authority cut; the later freeze deadline
   only bounds acknowledgement and cleanup and grants no extra time to claim.
   Every permit claim, owner-start,
   mirror acceptance and post-start or post-ack continuation rechecks the same
   absolute monotonic deadline, so expiry wins even when its timer is queued.
   The relay rechecks the instant, enters `lease_ops_frozen`, changes `pending`
   lightweight rows to `shutdown_cancelled`, atomically CASes every executing
   lease row to `shutdown_admitted`, and returns the fixed tagged set of
   barrier-owned, settling-acquire, settling-release and settling-owner-loss
   descriptors; a
   timer-first path returns the same retained set on the later call. It also returns
   correlated `daemon_stopping`. Executing non-lease queries, reads and transfers
   remain tracked through result or the step-3 connection/worker barrier; the
   first barrier neither waits for nor kills them. The owner rejects queued owner-start or mirror
   work as `shutdown_admitted`. From the barrier-owned descriptors, existing-owner
   operations kill and reap the exact actor, exact-pop its mirror, join the
   relay's owner `DOWN` and terminalize every claimable lease or unpromoted
   mutation origin without ordinary owner-loss output before quiesce, while a
   promoted ticketed mutation remains on its real-result path. A fresh acquire
   leaves the daemon owner alive and uses its exact `start_op_ref` record to
   tombstone `not_materialized` or kill/reap the named child, first cancelling
   and clearing any installed provisional row.
   The owner never scans its actor map to infer the set. The atomic freeze CAS
   already selected each `shutdown_admitted` disposition before cleanup; a late
   actor result is cleanup-only. A tagged
   settling acquisition finishes its selected provisional grant or cancellation
   without a post-cut reply. A tagged settling release keeps its selected disposition: the owner finishes result
   mirror clear without a reply, finishes a restored connection-loss settlement,
   or kills an unresponsive exact owner and completes its no-reply supersede and
   pop/classification. A separately tagged owner-loss row completes the same
   retained `DOWN`/pop join, tombstoning or cancelling any accepted daemon
   release/acquisition record while permitting a true pre-operation row, all
   under the same freeze deadline. A selected disposition is immutable if the
   associated lease owner then dies. Existing-owner acquire/release and restored
   release join the recorded actor-owner `DOWN`; a fresh-acquire `result` joins
   the resulting child lease-owner `DOWN` named by retained start/operation
   state, while fresh-acquire `connection_lost` already reaps that child as
   cancellation cleanup and the daemon actor remains alive. Descriptor
   settlement finishes first, and the retained or newly arrived exact
   lease-owner `DOWN` is reaped and joined with the required mirror
   pop/classification under the same deadline and with no ordinary output. The exact
   acknowledgement, returned-set cleanup and terminal-row confirmation all complete inside
   `freeze_deadline`; otherwise the owner atomically latches `relay_lost`,
   notifies the sentinel, sends untrappable `:kill` to the exact relay and
   enters fail-stop without awaiting its reap, inferring the missing set or
   beginning core quiesce. A later relay `EXIT` is cleanup-only. A pending mirror instead atomically latches `connections_lost`, notifies the
   sentinel, sends untrappable `:kill` to the exact registry and enters fail-stop
   without awaiting its reap; its later linked `EXIT` is cleanup-only. Idle and
   granted owners remain for the drain; no
   new owner or mirror operation may begin after this first barrier.

   After the cut, no new **post-initialize method** passes relay admission and
   no new origin row or permit is created. Every initialized connection
   synchronously installs or claims its
   relay origin or lightweight permit before dispatch; the relay's closed state
   refuses that operation as **`daemon_stopping`**, and the connection only
   renders the correlated refusal. An uninitialized connection instead receives
   EOF because it has negotiated no encoding. A post-initialize method of
   **any kind** arriving on an open initialized connection therefore reaches no
   owner or core operation. Only a pending origin in the
   frozen pre-cut set may promote and start a monitored task before the shared
   admission deadline; none may start afterwards. A promoted task may still
   reach core after the cut; the early core barrier and per-coordinator
   drain call give that task a closed ordering rather than leaving an untracked
   residual. Immediately before core quiesce, the owner computes a **new**
   `now + relay_control_timeout_ms` absolute instant and sends the ref-tagged
   transition to `quiescing(drain_id)`. Reusing the timeout value does not reuse
   the earlier instant: these are two sequential phases, both counted in the
   operator bound. A missing or malformed exact acknowledgement atomically
   latches `relay_lost`, notifies the sentinel, sends untrappable `:kill` to the
   exact relay and enters fail-stop **without awaiting its reap or calling
   `quiesce/1`**. A later relay `EXIT` is cleanup-only. From a valid acknowledgement until sealing, a
   ticketed task that dies without a result remains explicitly unresolved rather
   than independently turning the ordered drain into `relay_lost`; no successor
   is granted and no core result is inferred.

   Nothing is written to initialized clients yet and none is closed: those
   connections stay open across the drain, because a client that is about to be
   told something true is better served by being told it than by an early close.
2. **The runtime is quiesced within the budget core derives.** The owner
   calls core's `quiesce/1` — which takes no deadline, core owning the drain
   clock entirely — and waits for its answer, which names the sessions that
   settled, those that did not, those that were already gone, and the budget
   core used — and, by the time it answers, every session it could not settle
   has already been fenced
   and terminated inside core. If the census cannot obtain a usable `Control`
   projection, `quiesce/1` returns `{:error, :runtime_unavailable}`. The owner
   records fatal `drain_failed`, claims no census or fence result, skips the
   orderly notification as an operator-success record, and takes the
   crash-equivalent fail-stop teardown. After a successful quiesce answer, the
   owner starts the shared `teardown_ms` clock and sends the ref-tagged deferred
   `seal_after_quiesce(drain_id)` barrier, its first consumer. The relay kills every
   remaining exact ticket-task pid concurrently, consumes each result/`DOWN`
   ordering against the remaining absolute time, and
   returns the real-result and unresolved ticket-ID sets before teardown may
   continue. A task's queued real result wins its later `DOWN`; all other
   tickets are abandoned for this shutdown without being called settled. A
   pending attach's unresolved ticket is removed by the seal after its caller
   task is killed; the work is nondurable, and later holder and runtime teardown
   clear any late transaction and charge. A seal that reaches the shared
   deadline, or an exact malformed result, makes the owner atomically latch
   `relay_lost`, notify the sentinel, send untrappable `:kill` to the relay,
   suppress operator-stop success and enter fail-stop without awaiting its reap;
   a later relay `EXIT` is cleanup-only. A failed quiesce never receives a
   successful seal. This is the drain; what it does, and
   what it cannot do, is set out below.
3. **Initialized clients are told and every remaining connection closes. The
   listener is already gone, and the socket path is left where it is.** Each
   open initialized connection gets one `daemon.stopping` naming
   `operator_stop`, bounded best-effort as ADR 0032 fixes — one write attempt
   into the existing 4 MiB output buffer — and is closed. The listener's exact
   exit in step 1 already closed the listening socket; this step never waits on
   it again.

   **This is a collective sweep too, for the same arithmetic as the lease
   owners.** Up to 512 connections exist, and the write and the close are each
   microseconds — one non-blocking `send` into a buffer the daemon already
   holds, and one `close` — so the work is trivial; what is not trivial is
   doing 512 of them in sequence and then waiting for 512 process exits one
   after another inside the teardown. So the owner writes and closes **all of
   them at once**, then waits **once** for every connection process to exit,
   killing whatever is left at the phase's end. The processes must actually
   end, not merely stop being written to: core change 1's holder monitors drop
   each connection's complete attachment set and transfers on that process's
   `DOWN`. A connection killed here loses a buffered record it had not
   finished writing, which is the case ADR 0032 already admits when it says a
   client may learn of a shutdown only by its socket closing. **Nothing unlinks the pathname**, on this path
   or any other: the next daemon to prove it holds both the placement lock and
   Store marker applies the no-follow owner-and-socket-kind check and removes
   only the proved socket before binding.

   Each live-to-closing transition starts its monitored holder-cleanup worker,
   and `release_holder/2` remains admitted as internal cleanup after the core
   gate. Once every connection, request worker and holder-cleanup worker is
   `DOWN`, the registry completes the closing-slot retirement barrier: every
   incarnation has no nonterminal origin, waiter or permit, no relay task
   remains, and every exact cleanup reference has acknowledged both core
   owners. A worker crash selects `runtime_lost`; a late or stale acknowledgement
   cannot free a slot. Only then does the owner perform a mailbox
   ref-tagged barrier with the relay, changing both the relay and daemon owner
   from `lease_ops_frozen` to `tearing_down`, and freezes the exact remaining idle or
   granted lease-owner pid/incarnation set. No owner start or routing-mirror
   install has been accepted since the admission-deadline barrier; this second
   barrier makes the population immutable for the collective sweep. It consumes
   the already-running `teardown_deadline`: no exact acknowledgement by that
   instant, or an exact malformed one, atomically latches `relay_lost`, notifies
   the sentinel, sends untrappable `:kill` to the relay and enters fail-stop
   without awaiting its reap or sweeping a guessed owner set. A later relay
   `EXIT` is cleanup-only. Registry
   loss while this barrier is pending retains the existing
   `connections_lost` classification and precedence.
4. **The connection registry stops, then every lease owner as one sweep, then
   the admission relay**, inside
   the teardown deadline. The registry goes first of the three and **not
   before step 3**: step 3's stop records and closes go through the
   buffer-control interface it owns, so stopping it earlier would leave the
   daemon unable to write the record it promises. By the time it stops, every
   connection it monitored is already gone. The registry stop and collective
   owner sweep consume exactly the frozen set, so no later owner or mirror can
   appear behind them. Every lease vanishes with those owners; the relay goes
   after them because it is what holds their admission
   ticket bookkeeping; successful `seal_after_quiesce` has already returned
   every ticket as a real result or an unresolved shutdown abandonment, so
   stopping the relay here discards no unknown row. Nothing durable is involved, and no client is left
   holding a lease, because no connection survived step 3. Their exits are
   consumed like any other the owner asks for — a lease owner stopped here
   closes no controller attachment and produces no `control_owner_lost`,
   because there is no attachment left to close.
5. **The runtime stops.** After the drain there is little left to end —
   **every** coordinator quiesce enumerated was terminated and then fenced
   inside core before `quiesce/1` returned, the settled ones included — so
   this step ends the tree rather than the
   work. The helper calls
   `Supervisor.stop(runtime_supervisor, :normal, remaining)` on the pid the
   composition function handed it, where `remaining` is what is left of the
   **shared `teardown_ms` deadline**, not a per-component grace. It does
   **not** call `Loopex.Runtime.stop/1`: that is arity one and uses the
   default `:infinity` timeout, which is exactly the bound this step exists to
   supply.

   `Supervisor.stop/3` is `GenServer.stop(supervisor, reason, timeout)`
   (supervisor.ex:1152-1154 at the floor pair, :1197-1199 at the current
   pair), so it is the same call the general rule above describes, made in the
   same place — the helper — and its outcome is read the same way, from the
   exit on the owner's link. What `:proc_lib.stop/3` does to *its* caller on
   expiry, whatever shape that takes, is the helper's business and dies with
   it. The owner's wait on the shared deadline expires, it kills the runtime supervisor with
   `Process.exit(runtime_supervisor, :kill)`, and it reads the exit that
   follows: `:normal` or `:shutdown` where the tree came down on its own;
   `:killed` where the deadline kill ended it, with `runtime_lost` already
   latched; anything else classified from its reason.

   **What "crash-equivalent" does and does not claim.** An earlier draft said
   the kill makes the tree crash-equivalent "by definition". That is true of
   the coordinators and false of part of the tree, and the difference is worth
   stating because a reader will otherwise assume more than holds.
   `Process.exit(sup, :kill)` ends the root only; `killed` then propagates over
   links, and a **trapping** descendant receives it as a message and unwinds on
   its own clock. Three of the runtime root's own children are supervisors, and
   `OwnerGroup` traps exits, carries `shutdown: :infinity`, and has a
   `terminate/2` that itself calls `Supervisor.stop(workers, :shutdown,
   :infinity)`. So:

   - coordinators, which do not trap, die at once;
   - owner groups and their trapping workers unwind on their own clock, and
     **the daemon does not wait for them**;
   - the claim that survives is about the **journal**, not about processes: no
     terminal mutation is claimed, nothing false is recorded, and the fencing
     the journal already carries settles the ambiguous transaction at the next
     activation — exactly as after a VM death. It is not the claim that every
     process is gone when the daemon exits.

   Enumerating the subtree and killing it process by process was the
   alternative and is rejected: there is no API that enumerates and kills a
   supervision subtree without racing its own teardown, and a loop that walked
   `which_children` would be reading a tree that is already dissolving.

6. **The remaining composed edges stop, then the Store last.** Reverse start
   order puts the executor, the workspace lease and the transfers owner
   between the runtime and the Store, and each is stopped in turn — the
   executor first, since stopping it is what sets its Port-owning workers
   terminating the captured process groups. Then the tracing capability,
   custody and the registry, which hold nothing durable. Then the Store, whose
   `terminate/2` invokes the best-effort writer-marker release — see the marker
   invariant in ADR 0031. Completion does not prove marker absence. The socket path is **left in place**
   by step 3 for the next placement-lock and marker holder to remove — "already gone" was a
   residue of the design that unlinked — so the last
   lifecycle act before the halt is placement disposition: after an otherwise
   clean operator stop, with the Runtime Control gone and the Store stopped, an
   unlinked monitored helper attempts release of the acquisition-specific
   placement handle under `placement_release_ms: 5_000`. Exact `:ok` plus normal
   helper `DOWN` completes the phase without proving either path absent. A
   malformed result or abnormal helper death selects `placement_lock_failed`;
   expiry selects that class and hard-halts, leaving the residual for verified
   stale-owner recovery. If an earlier fatal class was latched, no placement
   release is attempted and that handle remains until the OS process exits. The
   last act is the halt: **`0`**, or the class,
   in the case above where something failed on the way out.

   **The executor is stopped before the lease, and that order is load-bearing**
   rather than alphabetical. The executor privately monitors the lease holder
   for a job's full life and reads its `DOWN` as cancellation evidence
   (`workspace_lease.ex:1-13`). Stopping the lease first would hand the
   executor a cancellation in the middle of its own cleanup; stopping the
   executor first means the lease's death is observed by nobody, which is
   what an orderly stop wants.

   **Each composed process stop through the Store uses a helper calling
   `GenServer.stop(pid, :normal, bound)`, with the owner waiting on the
   component's own link** — the same rule as step 5. The executor, workspace
   lease, transfers owner and Store are `GenServer`s
   (`apps/loopex_executor_local/lib/executor.ex:22`, `workspace_lease.ex:15`, `transfers.ex:26`,
   `local.ex:55`), so the same call fits those four. The later placement helper
   calls the exact-handle release function instead. The bounds:

   | Process | Bound | What it is waiting for |
   | --- | --- | --- |
   | The executor | What remains of **`teardown_ms`** | Nothing, in the executor itself: it neither traps exits nor defines `terminate/2`, so this stop returns quickly. What takes the time is the Port-owning workers it sets going, which the owner does not hold and cannot wait for |
   | The workspace lease | What remains of `teardown_ms` | Nothing: it has no `terminate/2` and holds no file — the lease *is* the live process, so stopping it revokes it |
   | The transfers owner | What remains of `teardown_ms` | Closing the open transfer descriptors its `terminate/2` holds (`transfers.ex:146-149`) |
   | The tracing capability, then custody, then the registry | What remains of `teardown_ms` | Nothing durable |
   | **The Store** | A **fixed 30 s**, its own phase | Its `terminate/2`, which invokes the best-effort writer-marker release (`local.ex:167`) |
   | **Placement release helper** | A **fixed 5 s**, after the Store phase | The existing two exact-handle best-effort removals; completion does not prove absence |

   **"What remains" is one deadline, not one budget each.** The owner computes
   an absolute instant once — `System.monotonic_time(:millisecond) +
   teardown_ms` — and every non-Store stop from step 4 through this one waits
   until that instant or until its exit arrives, whichever comes first, then
   kills. So a slow lease owner spends the same clock a slow executor would;
   the worst case is `teardown_ms`, not `teardown_ms` multiplied by the number
   of components. An earlier revision gave each component its own grace, which
   made the worst-case stop a sum nobody had written down.

   **The Store's stop is separate and fixed**, and the reason it is
   its own phase is that it is the one stop whose `terminate/2` attempts release of a
   durable exclusion, and its length has nothing to do with any session's
   cancellation grace. It begins when the teardown deadline is done with, runs
   for at most 30 s, and usually finishes in milliseconds.

   **The residual is stated.** A Store whose stop has not completed within its 30 s
   first latches `store_lost`, is killed, retains host placement through the
   non-zero halt, and may leave the marker behind. That is the same stale marker ADR
   0031's recovery rule already answers: the next daemon probes the marker's
   recorded holder and reclaims it where that holder is proved dead, refuses
   `store_writer_unverifiable` where it cannot be decided, and refuses
   `store_writer_active` where it is alive.

   **The operating-system residual, stated for the ordinary path and not only
   for a killed executor.** Whether the executor stops cleanly or is killed,
   the cleanup of captured process groups happens in the per-job monitored
   workers that own the Ports and watch the executor
   (`apps/loopex_executor_local/lib/executor.ex:3703-3724`, `effect_owner/0` at `:4166-4173`) — the
   executor's own contract, written after a kill once left a descendant
   running.

   Those workers are processes **in this VM**, and the halt at the end of this
   sequence ends them. Whatever bounded termination they have not finished by
   then does not finish. So the residual is the same on both paths:
   **operating-system children may survive the daemon**, as an orphaned
   process group an operator can see and reap. The plan does not add a wait —
   the owner holds no handle on those workers, and acquiring one would mean an
   executor API M5 does not have and does not propose, while an unbounded wait
   at the end of a bounded sequence is the thing being avoided. What limits
   the exposure in practice is that the workers start at once and the steps
   after this one take real time.

   What is *not* at risk is durable truth. The effect that was in flight is
   `commit_unknown` in the journal and resolves to exactly one outcome at the
   next activation, exactly as an abrupt death leaves it; nothing false is
   recorded about it, and no terminal is claimed.

   An earlier draft ended at the runtime and the Store, naming neither the
   executor, the lease nor the transfers owner — which would have left all
   three running while the Store went out from under them. They are stopped
   here, in this order, for that reason.

   Stopping it last makes the marker outlive **every operation the owner can
   end**, which is the honest form of a claim an earlier draft overstated. On
   the ordinary path that is every operation. On the timeout path it is not:
   an orphaned owner-group worker may still be unwinding when the runtime is
   killed at the teardown deadline, and it goes on unwinding **while the Store is
   still alive**, because the Store stop has its own fixed thirty seconds.

   **What refuses its commit is the fence, not a dead Store**, and an earlier
   revision had this exactly backwards. It said such a call "reaches a stopped
   Store and fails as it would after a VM death… a refusal, never a write",
   which is false for the whole of the Store stop: the Store is not stopped yet, and
   a straggler's `session_commit` in that window would be an ordinary,
   acceptable transaction. A **committed** fence has already moved that
   session's owner epoch, so the adapter answers `:stale_owner_epoch`
   (`state.ex:548-551`) even while the Store is alive. A `:superseded` fence
   proves instead that the one predecessor transaction won the race before the
   newer head; an `{:unknown, :fence, head}` fence proves neither outcome and remains
   unsettled for later reconciliation. Quiesce attempts a fence for every
   enumerated session, settled ones included, but claims the stale-epoch
   protection only for the committed disposition.

   One dependency this step relies on is worth naming rather than assuming:
   an **explicit** Store stop runs `Loopex.Store.Local.terminate/2` and gives
   the marker back. The adapter traps its owner's exit and has no handler that
   converts that signal into a stop, while `System.halt/1` runs no termination
   callbacks; an owner crash, VM kill or power loss therefore leaves the marker.
   Recovery rather than release is what lets a verified successor open that
   path.

**What quiesce is, and why it is core's.** The Concept promises that an
orderly stop drains admitted work within the cleanup grace. A revision of this
file withdrew that promise for want of a mechanism; the maintainer restored it
on 2026-09-20 and gave it one. The mechanism is the **fourth of the six core
changes** in the inventory above:

```elixir
Loopex.Runtime.quiesce(runtime) ::
  {:ok, %{
     settled: [session_id],
     unsettled: [session_id],
     absent: [session_id],
     budget_ms: non_neg_integer(),
     fence_budget_ms: 130_000,
     drain_id: binary(),
     fences: %{session_id => :committed | :superseded
                             | {:unknown, :no_head}
                             | {:unknown, :abort, %{owner_epoch: non_neg_integer(),
                                                   journal_version: non_neg_integer()}}
                             | {:unknown, :fence, %{owner_epoch: non_neg_integer(),
                                                   journal_version: non_neg_integer()}}}
   }}
  | {:error, :runtime_unavailable}
```

**One argument, a seven-key success map, one distinct error, and no daemon
deadline crosses the boundary.** Core owns four fixed phase clocks:
`quiesce_admission_ms: 70_000`, `status_census_ms: 10_000`,
`coordinator_termination_ms: 330_000`, and `fence_budget_ms: 130_000`. An earlier
revision passed the daemon's teardown deadline in, which contradicted the rule
two paragraphs later that the teardown clock starts when `quiesce/1`
*returns*: a deadline cannot both bound the drain and begin after it. It takes
the runtime and nothing else. Core derives the budget, enforces it, and
returns the dynamic cancellation component as `budget_ms` and the one shared
fence-phase bound as `fence_budget_ms`; the daemon's own `teardown_ms` starts when the
call comes back. At entry the phase owner starts the admission clock before a
worker resolves and monitors one exact `Control` pid; both enumerations call
that pid directly. The initial lookup and `begin_quiesce` projection must finish
within the first 5,000 ms of that clock. If the pid dies, changes, or either
enumeration cannot return its bounded session projection, the function returns
`{:error, :runtime_unavailable}`; it never follows a restarted empty `Control`
or fabricates empty lists or partial fence results. A long derived budget
is valid input, which is why the operator contract has no useful
configuration-independent operational timeout even though the formal maximum
is finite.

The terminal transition is single-use. The first `begin_quiesce(drain_id)`
call that finds no drain installed sets the gate and owns all per-session work.
A concurrent or later `quiesce/1` sees `quiescing` already set and returns
`{:error, :runtime_unavailable}` before admitting an abort, terminating a
coordinator or starting a fence-mode writer. The core witness races two calls
and proves exactly one success and no work from the refusal.

Of the seven keys, four answer questions the daemon cannot ask. `absent` names
projected writer domains for which there is no ready, routable coordinator to
drain, including an `:active` entry with a dead coordinator, an `:unavailable`
entry or a writer-domain ID whose current entry disappeared. That state is
neither settled nor unsettled. The classification table below is total over
the frozen writer-domain projection; entries that never started a writer are
outside it. `budget_ms` is the cancellation budget core derives from committed
graces; `fence_budget_ms` is the fixed 130-second outer fence-phase deadline.
`drain_id` is
the label this drain reports, and `fences` is what the fence below actually
did for every session in the frozen writer-domain census — `:committed` where the epoch
moved, `:superseded` where the one transaction that could still linearize won
the race first, `{:unknown, :no_head}` where the bounded head read could not
supply an identity, `{:unknown, :abort, head}` where abort status was
unavailable and no fence was proposed, and `{:unknown, :fence, head}` where the
Store could not resolve a proposed fence. Both tagged forms carry the head the
operation was built from, because that head is the only thing a successor can
discriminate on. **Without `fences` a fence's failure is
a thing no caller can observe**, which is the defect an earlier revision
carried: it described three outcomes and returned none of them.

**Three parts, in order, and the first two are one thing split in half.**

1. **The admission barrier and abort admission: core closes new routes, then
   every live coordinator closes ordinary command admission, admits the abort,
   and stops at the cleanup split.** The first Control call sets
   `quiescing: drain_id` and returns the initial entries and coordinator pids.
   Create, resume, attach and route calls ordered after it refuse. For a command
   already routed, one drain-specific coordinator call closes ordinary command
   admission in that mailbox before proposing the abort: an ordinary command
   processed first is included in the abort; one processed later refuses, while
   internal commit and recovery messages keep settling.

   One absolute `quiesce_admission_ms: 70_000` clock starts before the exact
   Control lookup. Its first 5,000 ms cover that lookup and the one
   `begin_quiesce` projection gate; failure there returns
   `{:error, :runtime_unavailable}` because there is no trustworthy frozen set.
   Every concurrent per-session admission worker must finish before
   `admission_deadline - 5_000`, leaving at least 60,000 ms after the gate. That
   minimum work allowance derives from the maximum **drain-only admission**
   path: two sequential local-Store calls at the adapter's 30,000 ms call
   timeout, with the drained abort presented once and never retried. The
   separate reserve-completion witness can observe three commits after an
   already-returned refusal, but that callback work is not a third sequential
   admission call and does not enlarge this deadline. The final 5,000 ms are reserved to
   kill and reap every unanswered worker. The population is at most 64 and all
   calls are issued concurrently, so it is a population bound, not a time
   multiplier. An unanswered session is `unsettled`, receives no cleanup
   release, and continues to termination and fencing; a queued coordinator call
   that runs after its worker died can admit only the deterministic paused abort
   whose unknown disposition the later fence recovery already resolves.

   ADR 0023 fixes that *only* the durable `session.abort` command cancels, and
   that cancellation is "never inferred from EOF or death"
   (`0023-…-technical.md:365`, with the method table at `:169`). Quiesce
   cancels, so quiesce must admit — and the Concept promises **every** abort
   is durable before **any** cancellation begins, which a per-session
   admit-then-cancel loop cannot deliver.

   It cannot because cleanup starts on the commit reply path:
   `begin_admitted_cleanup/1` runs "from the reply path of a committed
   command" and starts cleanup the moment the reducer marks a run aborting
   (`session_coordinator.ex:4806-4815`). Admitting session A's abort therefore
   begins A's cleanup while session B's abort is still unwritten.

   So quiesce **splits admission from cleanup**, and that split is the first
   of the **two halves** of core change 4's coordinator change: under a drain,
   a coordinator admits the abort and **pauses at
   exactly the point `begin_admitted_cleanup/1` would have begun** — the
   record is committed, the queued steer and follow-up are resolved as they
   already are, and no cancellation runs.

   **The second half is that a drained abort commits without the retry**, and
   an earlier revision missed it by saying the admission path was "otherwise
   untouched" four lines above a rule that an ambiguous admission is not
   retried. Both cannot hold: an abort taking the ordinary path goes through
   `resolve_transaction/2`, which re-presents once on `commit_unknown`
   (`session_coordinator.ex:1752-1768`). Under a drain it presents **once**
   and an unknown answer is an unknown answer, which is what lets the session be fenced
   rather than waited on. Two halves, one clause, one change.

   **What is genuinely untouched is the record**: `propose_new/3` for
   `%{type: :abort}` writes the same
   `command_admitted` record with `"command_type" => "abort"` and
   `"admission" => "accepted"` (`session_state.ex:1684-1700`), and answers
   `"admission" => "rejected_no_active_run"` where nothing is running
   (`:1750-1761`), which is the right answer for an idle session and needs no
   special case. Because ordinary admission was already closed in that
   coordinator, this refusal cannot be invalidated by a delayed routed prompt.
   Nothing about what is written changes; what changes is
   whether the commit is presented a second time and whether cleanup begins on
   the reply.

2. **The cancellation: it is released, concurrently,
   only once every admission is durably decided in the admitted set.** Core
   waits for every admission. If all committed or definitively refused
   `rejected_no_active_run`, it releases the committed paused cleanups
   together. If any failed, remained ambiguous or did not answer, it releases
   none and proceeds to termination and fencing. That is what makes the Concept's
   ordering true globally rather than per session, and it is also why the two
   phases are inside core: a host that ran them would need two round trips per
   session and a way to hold a coordinator between them.

   At the single phase-owner transition that sends all cleanup releases, core
   computes `budget_ms` once from exactly the committed paused-cleanup set and
   starts `cancellation_deadline = now + budget_ms`. An empty set has budget
   `0`; a globally failed admission phase releases none and therefore also
   advances without a cancellation wait. Every released cleanup runs against
   that same absolute instant. Core advances to status classification at the
   earlier of every released cleanup reaching a terminal state or
   `cancellation_deadline`; no session, timer delivery or late message restarts
   or extends the clock.

   **Concurrently, not in sequence**, because each session's cleanup is
   bounded by its own committed grace and running them one after another would
   add those bounds together.

   **Core derives each session's `cleanup_grace_ms` itself** from the durable
   state it already holds (`session_coordinator.ex:422`, `:5366`); the daemon
   passes no per-session number and does not know them. The drain budget is
   the maximum over the committed paused-cleanup set of
   `cancellation_bounds(g_i).cli_backstop_ms`
   (`apps/loopex/lib/loopex/executor.ex:456-474`), and over an **empty** set
   of released cleanups that maximum is **`0`**: a daemon with nothing to
   cancel, or with a globally failed admission phase, proceeds rather than
   waiting out a number derived from nothing.
   Core **returns** the figure it used as `budget_ms`, because a daemon that
   cannot compute it cannot report it either.

   Inside the budget each session's cancellation runs under its own `g`,
   through `Loopex.Executor.cancel/4` (core), exactly as the coordinator
   already drives it at `session_coordinator.ex:3614` and `:5366`.

   **Whose `command_id` that abort carries, which the set did not say.**
   `propose_new/3` writes `"command_id" => command.command_id`
   (`session_state.ex:1686`), and command identity is load-bearing everywhere
   else in this plan — `create_command_absent?/2` decides freshness by it,
   replay is idempotent by it, and a resume is required to carry a *fresh*
   one. A client's abort carries the client's ID. Quiesce has no client, so
   the question has to be answered rather than inherited.

   **Core derives one restart-recoverable identity from the durable
   pre-admission head.** `SessionState.drain_abort_command_id/2` wraps its
   existing deterministic `stable_id/3` discipline
   (`session_state.ex:5049-5052`) and hashes the namespace `"drain_abort"`, the
   session ID and `owner_epoch`. `Store.ownership_head/3` exposes the epoch and
   journal version (`store.ex:299-313`), but only the epoch belongs to the
   recoverable operation identity. The
   coordinator uses the result as both the abort's `command_id` and the Store
   `tx_id` that `propose_new/3` already takes from it. The Store binds that ID
   on first presentation to the exact owner incarnation, epoch, journal
   version, canonical digest and bytes.

   **It is derived from no client's ID, but it need not be secret.** Command
   IDs grant no authority. The private namespace prevents accidental
   cross-kind collision but is not reserved from a client that deliberately
   supplies the same binary. The Store still binds the proposal to the current
   owner incarnation, epoch, journal version, canonical digest and bytes. Core
   admits live or recovered re-presentation only after validating the retained
   command-idempotency row's exact abort type, canonical drain-abort digest and
   run binding. During a live drain a different pre-bound command makes abort
   admission fail as `idempotency_conflict`, releases no cleanup and proceeds
   to termination and fencing. On restart, replay of that exact different
   binding proves collision/no-drain and recovery continues; only an
   unattributable committed status stays unavailable. Transaction status alone
   is never proof that an abort was committed. The identifier remains within
   `valid_identifier?/1`'s 256-byte bound (`control.ex:40`, `:1726`).

   **What that means for replay, said plainly: one owner epoch names one drain
   abort.** The drain presents the commit once; it does not hide an ordinary
   retry inside the call. If that presentation is ambiguous, the exact
   candidate is resolved before any fence mutation as described below. The
   terminal quiescing gate permits one drain abort per session in a daemon
   lifetime, and every later service lifetime must commit fresh owner
   succession before admission or another drain. That increments the epoch, so
   correct core never reuses the abort ID with a later journal version. If no
   record committed and the epoch is unchanged, a successor derives the
   original candidate rather than abandoning the only key that can resolve it.

   **Nothing new is journaled, and that is the decision.** The abort quiesce
   admits is the abort that exists: the same command, the same record, the
   same fields a client's `session.abort` writes today. **No `cause` field is
   added.** An earlier revision of this section added a bounded `"cause"` so a
   journal could say which aborts were shutdowns; the maintainer rejected that
   on 2026-09-20, and the reason is proportion rather than mechanism. The
   operator-shutdown cause is an operator-facing fact, and the daemon already
   reports it twice — as `operator_stop` in the `daemon.stopping` record every
   client receives, and in its bounded `stderr` line. Nothing durable needs
   it, and a field added to a durable record is a persistent-schema decision,
   which is not a thing to take in passing for a fact that is already
   reported.

   **So a drained root is exactly a root, and the plan can say why.** The
   frame the local adapter writes is built from the transaction the caller
   supplied — its records are derived from `transaction.records`
   (`state.ex:326-339`) — and replay recomputes that frame from the stored
   transaction and requires whole-term equality, `expected == frame`, refusing
   `:frame_does_not_match_transition` otherwise (`state.ex:414-426`). A drain
   that writes the records core already writes therefore produces frames the
   released reader recomputes identically, and the adapter's `@schema_version`
   stays `1` (`state.ex:7`) because nothing about the schema moved. That is
   what makes **rollback** true rather than asserted: a root a drained daemon
   leaves behind is opened by the released foreground surface, on the same
   adapter, with no migration and no recovery step.

   The rejected option is recorded with its date: proposing the schema change
   properly — a version bump and a root that only newer readers can open —
   was available and was declined, because it would buy a journal annotation
   at the price of a one-way root.

3. **Terminate every coordinator in the writer-domain projection, then fence
   every projected domain — two steps, in that order.** When the budget and
   status census are spent, core starts one absolute
   `coordinator_termination_ms: 330_000` clock. Its first 5,000 ms cover the
   second read-only Control projection; failure returns
   `{:error, :runtime_unavailable}` rather than inventing a set. Core then issues
   `DynamicSupervisor.terminate_child/2` for **every enumerated coordinator** —
   settled, unsettled and acquiring alike — together. Those calls serialize
   through the one session supervisor, and every coordinator child has
   `shutdown: 5_000`, so the admitted maximum is 64 × 5,000 ms. At
   `termination_deadline - 5_000`, after that 320,000 ms work allowance, core
   sends `Process.exit(pid, :kill)` directly to every coordinator still alive
   and kills every still-live termination worker blocked in
   `DynamicSupervisor.terminate_child/2`. The final 5,000 ms are reserved for
   every exact coordinator `DOWN` and worker exit. If either is missing at the
   outer instant, quiesce returns `{:error, :runtime_unavailable}` and never
   begins a fence; it does not wait beyond the named bound. A suspended or
   wedged supervisor therefore cannot prevent the direct kill or create a live
   writer/fence overlap. Only after every coordinator is observed dead does it
   start the separate 130,000 ms fence phase for every ID in the frozen
   writer-domain set. A no-writer dormant entry is outside the projection and
   starts no worker.

   **The order is the whole of it, and an earlier revision had the sets
   different.** That revision terminated only the *unsettled* coordinators
   while fencing every writer-eligible session, and then justified the fence's no-retry rule
   with "the coordinator is dead". For a settled session that was simply not
   true: its coordinator was still alive and still able to begin a transaction
   **between the fence's head read and its advance**, which is the one window
   the whole no-second-attempt argument assumes cannot produce a second
   writer. Terminating first makes the premise true for every session the
   fence touches, which is what the fence table's reasoning has always
   required and now actually gets.

   Terminating a settled session's coordinator costs nothing it was still
   doing, and "settled" is what makes that true: its terminal is already
   committed, which is what the word is defined to mean below. What the termination
   buys is that no enumerated session still has a **process** that could start
   a transaction, so the fence **races at most one delivered
   transaction** — the one the serial `OwnerLane` may have handed the Store
   before its coordinator died — which the fence's stale handling already
   covers. It does not race nothing, and an earlier revision said it did; what
   it races is bounded at one, which is the claim the no-second-attempt rule
   needs.

   **The drain's guarantee rests on that termination and not on how a
   coordinator handles a refusal**, which is worth saying because the
   coordinator's handling is **incomplete** and a design that leaned on it
   would be leaning on a gap. `apply_transaction/3` maps two of the three
   stale results to `{:error, :superseded_owner}` and marks the coordinator
   superseded so it performs no later run work — `:stale_owner_epoch` and
   `:stale_owner_incarnation_id`, at `session_coordinator.ex:1731-1732`. The
   third, **`:stale_journal_version`**, falls through to the general clause at
   `:1734-1735`: the caller is told the reason, and the coordinator is **not**
   marked superseded.

   **That is an observation for core, not an M5 change**, and the argument is
   the one P0-2 just supplied. A drain never meets it: every enumerated
   coordinator is dead before any fence commits, so no live coordinator can
   receive a refusal caused by the drain's epoch move, and the fence's
   correctness never passes through that clause. Outside a drain it is core's
   ordinary succession business under ADR 0006, where a stale journal version
   is a legitimate retry condition rather than proof of supersession — which
   may well be why the clause reads as it does. M5 therefore changes nothing
   here, and records the asymmetry so that a later change which *does* need a
   live coordinator to stand down on `:stale_journal_version` finds the
   question already asked rather than discovering it. An earlier revision stopped there and claimed nothing could be
   appended for that session afterwards. **That claim was false**, and the
   reason is worth stating because it is the general shape of this whole
   class of bug: a coordinator commits through a *synchronous* call —
   `OwnerLane.call/4` runs `Store.transact/2` (`store/owner_lane.ex:120-121`)
   — and a `GenServer.call` that has already been delivered runs to
   completion whether or not its caller is still alive. Probed at both
   toolchain pairs: a handler that sleeps, with its caller killed mid-call,
   **still ran and still produced its effect**. So an in-flight transaction
   can be linearized by the Store (`local.ex:250-256`) after its coordinator
   is gone, and `Control`'s `DOWN` handler does not prevent it — all that
   handler does is `EventDispatcher.release_fence/2` and leave the entry
   (`control.ex:805-826`), which fences *delivery*, not the journal.

   **An ambiguous abort is resolved before that fence, by the same temporary
   serial owner.** The ordinary coordinator returns the retained
   `{abort_tx_id, abort_head}` to `Control`; the quiesce helper receives neither
   a Store handle nor authority to resolve it. After the ordinary coordinator is
   `DOWN`, the fence-mode coordinator performs this bounded sequence:

   1. Query `transaction_status/4` under the exact deterministic abort ID.
      `{:terminal, :committed}` requires replay/reload of the one abort record
      before fencing from the resulting head. Missing history after that result
      is `runtime_unavailable`, never permission to proceed. A matching terminal
      non-commit proceeds to the head read. `:unavailable` attempts no new
      mutation and returns `{:unknown, :abort, abort_head}`.
   2. Treat `:absent` as an observation at that instant, not as a terminal
      resolution. Read the current head and attempt the fresh fence CAS below.
      If the fence commits first, the delayed abort is stale on owner epoch; if
      the abort or another prior transaction commits first, the fence is stale on
      owner epoch or journal version. Exactly one can advance the original head,
      and the stale side is conservatively `:superseded` and `unsettled`.

   Cleanup is never released after an ambiguous abort, even if the later status
   proves it committed: the ordinary coordinator that owned the run is already
   terminated. The result remains an unsettled shutdown classification while
   replay preserves the one durable admission.

   **The bounded identity set survives a daemon crash without a durable drain
   marker.** Existing-session activation replays first, reads current epoch
   `E`, and queries `drain_abort(E)` then, only on absence or exact replay that
   proves a different-binding collision/no-drain, `drain_abort(E - 1)` when a
   predecessor exists. A committed result must
   appear on reload; a terminal non-commit resolves that exact operation.
   Unavailable, malformed or head-inconsistent results leave the session
   unavailable. Both absent means neither identity that can represent the
   immediately unresolved shutdown abort is retained; it does not erase older
   history. This adds at most two status queries to existing-session activation.
   Fence recovery then
   queries `drain_fence(E)` and, only on absence or exact replay that proves a
   different-binding collision/no-fence, `drain_fence(E - 1)`, adding
   at most two more; it adds none to a fresh create, which has no predecessor
   session history. After those queries it rereads the head before ordinary
   succession. A moved head or replayed abort already makes an older candidate
   unable to commit.

   So quiesce installs a fence the **Store** enforces, using machinery that
   already exists. After terminating **each enumerated coordinator**, the
   fence-mode coordinator attempts one **`advance_owner` transaction** for that
   session (`store.ex:169-179`,
   built by `Store.advance_owner/6` at `store.ex:820-827`, linearized at
   `apps/loopex_store_local/lib/loopex/store/local/state.ex:241-254`). Once it commits, the session's
   `owner_epoch` has moved, and any older `session_commit` the Store
   linearizes afterwards is refused **`:stale_owner_epoch`** by the rule that
   already governs every commit (`state.ex:548-551`).

   **That transaction has six arguments and the plan names where each comes
   from**, because a fence built from guesses is a fence that refuses the
   wrong thing:

   | Argument | Where quiesce gets it |
   | --- | --- |
   | `session_id` | The session being fenced |
   | `mutation_domain` | The ownership domain, as every owner transaction uses |
   | `tx_id` | **Derived from durable operation identity, not from anything in memory**, by the discipline the coordinator already uses: `owner_identity/3` hashes a namespace, a succession identity and an attempt into a stable ID (`session_coordinator.ex:1346`, `:1490-1498`). Quiesce derives its own from **`("drain_fence", session_id, expected_owner_epoch)`**. Journal version remains in the transaction's immutable Store binding and canonical digest, but not in the recoverable ID |
   | `expected_owner_epoch`, `expected_journal_version` | Read **fresh** from `Store.ownership_head/3`, exactly as the coordinator reads them (`session_coordinator.ex:1337-1343`), so the fence binds the state it is actually fencing |
   | `proposed_owner_incarnation_id` | **Derived from the same session ID and expected owner epoch**, in the coordinator's `owner_identity/3` form rather than its `fresh_incarnation/2` form — see below |

   **The `tx_id` derives from durable state, and an earlier revision derived it
   from a random number held only in memory.** That revision minted one
   `drain_id` per call and hashed `(drain_id, session_id)`. It reads well and
   it breaks the one rule this fence exists under: a `commit_unknown` fence
   whose deriving process then dies leaves a preallocated ID **no successor can
   reconstruct**, because the only copy of `drain_id` was in a VM that is gone.
   The founding rule is that a preallocated ID be recoverable *from the owning
   command or operation identity* and that resolution be restart-safe
   (`vision-technical.md:710-715`), and a value in RAM is neither.

   So the drain returns the exact observed head inside the stage-tagged
   disposition `{:unknown, :fence, head}`, and the stop line renders that same
   disposition beside `drain_id`. This is operator evidence about the failed
   stop, not a restart input. A crash may happen before either value is emitted.

   **Restart recovery uses only the root and configuration and still resolves
   the exact preallocated ID.** A successor reads the current durable owner
   epoch `E`, then queries `transaction_status/4` for the deterministic
   `drain_fence(session_id, E)`. A terminal non-commit resolves a fence that
   lost without advancing the epoch. A committed result is attributed only by
   a replayed `owner_advanced` record with the fields the adapter actually
   carries: matching prior and new epochs, deterministic proposed incarnation
   and deterministic transaction ID. Its stamped journal version gives the
   expected version one lower; with the session ID from journal context and the
   prior epoch, recovery reconstructs the exact `Store.advance_owner/6`
   candidate and canonical digest and requires every replayed field to match.
   A different exact binding proves a client collision and means no fence at
   that candidate; a committed
   status without attributable replay keeps the session unavailable. A matching
   fence while the head still reports `E` is inconsistent and keeps the session unavailable.

   Only when that identity is absent or a proved collision does it query
   `drain_fence(session_id, E - 1)`, if `E` has a predecessor. A committed
   result there is the fence that advanced the head to `E` only when the
   reconstructed candidate matches every replayed field; a different
   binding is collision/no-fence. A terminal
   non-commit resolves that exact operation. Absence at both identities means
   neither candidate for the immediately unresolved stop is retained; it does
   not erase older fence history. Unavailable, exit, malformed output or any result
   inconsistent with the observed head stays fail-closed. Only after this
   exact-ID recovery does ordinary fresh-ID succession run, and no command is
   admitted until that succession commits.

   Two bounded identities are complete because Control's terminal quiescing
   gate permits one fence per session. An acquiring coordinator's already
   delivered succession may commit after its `DOWN` but before fence mode reads
   the head. After that read, however, no owner can start and every older CAS is
   bound to an older head, so only the fence or a competitor on the observed
   head can move it. Thus current and predecessor IDs remain complete even when
   the acquiring straggler and then the fence make two post-`DOWN` epoch moves.
   A later service lifetime must finish ordinary succession, which increments
   the epoch, before activation or another drain. Correct core therefore never
   presents two **fence** bindings under `drain_fence(session_id, epoch)`. The
   namespace prevents accidental collision but is not reserved from client
   command IDs; the replayed owner-advance binding makes the restart status
   attributable under ADR 0008. The live fence owner still resolves its own initial `commit_unknown`
   by one byte-identical re-presentation, where it has the full binding.

   **The incarnation is derived too, and it has to be.** The coordinator's
   `fresh_incarnation/2` hashes `make_ref()`
   (`session_coordinator.ex:1500-1509`), so two fences built from one unmoved
   epoch would carry the same `tx_id` and **different** incarnations — and the
   adapter refuses that: `resolve_known/2` compares the re-presented
   transaction's immutable binding with the retained one and answers
   `{:not_committed, :tx_id_conflict}` when they differ
   (`state.ex:137-144`). The founding rule wants the preallocated
   ID bound to the canonical mutation digest
   (`vision-technical.md:710-716`), and a random incarnation is what breaks
   that binding. So the fence's incarnation derives from the same two inputs
   the `tx_id` does, through the same `owner_identity/3` discipline, **under a
   second namespace**: `"drain_fence"` for the transaction id and
   `"drain_fence_incarnation"` for the incarnation. The two namespaces matter
   rather than being tidiness — `owner_identity/3` hashes the namespace with
   its inputs, so one namespace over identical inputs would make the
   incarnation and the transaction id the *same string*. The coordinator
   already does exactly this, deriving both from `owner_identity/3` under
   `"owner_tx"` and `"owner_incarnation"`
   (`session_coordinator.ex:1222-1224`). A
   re-presentation is then **byte-identical**.

   **Fence mode retains that exact transaction and resolves an initial
   `commit_unknown` by re-presenting it once.** Exact re-presentation invokes
   `resolve_known/2`, which compares the retained binding
   (`state.ex:137-144`). Matching committed and matching stale results are
   therefore attributable to this fence. A `:tx_id_conflict` is an invariant
   violation because the namespace is single-use at an owner epoch; it, another
   nonmatching refusal, a second `commit_unknown`, unavailable, exit or
   malformed output remains `unsettled` with
   `{:unknown, :fence, head}`. The Store-call ceiling stays three: head read,
   first transaction, one exact re-presentation.

   **`drain_id` survives as a report label and nothing more.** Core still mints
   one per call, with the generator it already uses for identifiers of its own
   (`:crypto.strong_rand_bytes(16)` rendered base16,
   `session_directory.ex:545-548`), and **returns** it so the stop line and the
   evidence page can name one drain. No fence ID derives from it, so losing it
   costs a label and no recovery.

   **A journaled drain record was the alternative and was not taken.** Writing
   the drain's identity into the journal would make recovery trivial and would
   also be a change to a durable record — a persistent-schema decision, which
   is the maintainer's and not a thing to take in passing when a derivation
   from state that is already durable answers the same question. It is recorded
   here as the option available and declined.

   **The proposed incarnation is a fence marker, not an owner**, and nothing
   inherits it. The next activation of that session builds its own candidate
   from the head it reads at that moment —
   `discover_and_advance_owner/1` reads `ownership_head/1` and then
   `build_owner_candidate/2` (`session_coordinator.ex:1186-1196`,
   `:1345-1359`) — so the fence's incarnation is simply the head that the next
   activation supersedes. Fencing therefore costs the next activation one
   ordinary epoch step and nothing else.

   That turns an unanswerable question into a decided one, and the table is
   **total over what the adapter can answer** rather than over the three
   outcomes an earlier revision imagined. A fence is an `advance_owner`, so
   the adapter's `succession_refusal/3` governs it, and that function has
   **two** stale results, not one: `:stale_owner_epoch` and
   `:stale_journal_version`, in that order
   (`apps/loopex_store_local/lib/loopex/store/local/state.ex:450-463`, reached
   from `linearize/3` at `:241-254`). The second is the case where a
   **same-epoch** commit linearized between the head read and the fence's own
   linearization — exactly the race the fence exists for — and a design that
   handled only the first would have read it as an unexplained error.

   | Outcome | What it means | `fences[session_id]` | How the session is reported |
   | --- | --- | --- | --- |
   | The fence **commits**, directly or through its one exact re-presentation | The epoch has moved; any older `session_commit` linearized afterwards is refused `:stale_owner_epoch` (`state.ex:548-551`) | `:committed` | Preserve the pre-fence `settled`, `unsettled` or `absent` classification; the fence changes future authority, not the observed terminal fact |
   | The fence is refused **`:stale_owner_epoch`** or **`:stale_journal_version`**, directly or through its exact re-presentation | A prior transaction linearized first. The fence lost the race on the epoch or version; no new attempt is permitted | `:superseded` | Conservatively `unsettled`; the fence did not commit and this operation performs no second journal read that could prove a terminal fact |
   | The first fence presentation is refused **`:tx_id_conflict`** | A client transaction already bound the deterministic identity. The live fence cannot attribute that retained binding from this refusal | `{:unknown, :fence, head}` | `unsettled`; no alternate ID and no retry. A dedicated client-prebinding witness is distinct from the invariant-violation conflict after this owner presented its own binding |
   | The fence answers **`commit_unknown`** | The Store cannot say whether it linearized | Initially `{:unknown, :fence, head}` | Re-present the retained byte-identical `advance_owner` once. Matching committed becomes `:committed`; matching stale becomes `:superseded`; `:tx_id_conflict`, another nonmatching refusal, a second `commit_unknown`, unavailable, exit or malformed output remains `{:unknown, :fence, head}` and `unsettled` |
   | The bounded ownership-head read does not return a usable head | No recomputable transaction identity exists, so no `advance_owner` is proposed | `{:unknown, :no_head}` | `unsettled`; a successor reads the head itself, and no fence transaction is outstanding |

   **Termination and the fence use a second status projection over the frozen
   writer-domain set.** The first census sets `quiescing: drain_id` and freezes
   that monotonic set. No later writer-domain ID can appear or disappear during
   abort admission, cancellation, termination or fencing, although the current
   entry for a retained ID may change status or disappear. Termination uses that
   second projection, then runs the fence procedure
   for every projected writer-domain key. Entries outside that set are omitted. Thus
   every projected session has exactly one `fences` disposition, and no key is
   invented from outside the census.

   **The fence covers every writer-eligible session in that enumeration —
   settled, unsettled and absent alike, every coordinator already terminated in
   the termination — and an earlier revision fenced only the ones that had not
   settled.** That was a hole, and the Store stop is where it opened. The stop kills
   the runtime supervisor at the teardown deadline; `OwnerGroup` traps exits and
   carries `shutdown: :infinity` (`owner_group.ex:14-19`, `:50`, `:86-90`), so
   a trapping descendant of a **settled** session's coordinator can still be
   unwinding afterwards — and the Store stop then keeps it **alive** for up to
   thirty seconds more. A straggler's `session_commit` in that window would
   land on a session the drain had already reported `settled`, after the
   census was taken and with no fence to refuse it.

   So the fence is not a remedy only for sessions that failed to settle; it
   runs for every ID in the frozen writer-domain set. A committed fence moves the
   epoch. A superseded fence proves the
   sole previously delivered transaction won first. An unknown fence remains
   explicitly `unsettled` and may resolve while the Store is still alive; the
   result never upgrades that uncertainty into a stronger claim.

   **There is no entryless activation residual at the first census.** Create
   and resume are serialized with `begin_quiesce/1` in the same Control mailbox.
   When the activation call wins, its Store work and entry-or-dormant decision
   finishes before the census: a no-activation replay and a post-commit
   owner-start failure for which no coordinator started has no writer and is
   omitted from the projection and result, while an entry whose start path was entered is frozen and
   follows termination and fencing even if later reset to unavailable. When the barrier wins,
   the call refuses `runtime_unavailable` before Store access and the daemon
   maps that result to correlated `daemon_stopping`. Forced cases pause both
   operations around the Store boundary and prove both mailbox orders. Attach
   uses its pending-row reservation instead: gate first creates no pending or
   dispatcher state; reservation first grandfathers only that transaction
   through publish/finalize or discard. Ordinary service retains its ticket and
   charge to the real result; orderly sealing may remove an unresolved ticket,
   but holder/runtime cleanup still owns the nondurable transaction and charge.

   A pre-cut mutation has one additional cut because it may already hold a
   coordinator pid. The forced witness pauses a prompt after Control routing
   but before `SessionCoordinator.command/3`, lets the drain-specific
   coordinator call close ordinary admission and return
   `rejected_no_active_run`, then releases the prompt. The prompt refuses,
   writes no admission record and cannot turn that settled answer into a live
   run. Reversing the mailbox order admits the prompt first and the abort then
   covers it. Those are the only two outcomes.

   The cost is stated: a settled session's next activation spends one ordinary
   epoch step, exactly as an unsettled one's does. Each committed fence adds one
   ordinary owner-advance record beside any admitted abort; superseded and
   unknown dispositions add no record the Store did not commit. Every record
   present is one the released reader replays without a migration, which is the
   property the rollback claim rests on.

   **A stale refusal ends the fence rather than starting a second one, and the
   reason is the serial lane.** An earlier revision rereads the head and makes
   one new attempt — which would be right if more transactions could keep
   arriving, and none can. By the time a fence is attempted the coordinator is
   **dead**, and that holds for **every** session the fence covers because
   **termination reaches every enumerated coordinator first** and waits for
   every `DOWN` — which is the change this premise needed, an earlier revision
   having terminated only the unsettled ones while fencing them all. While a
   coordinator was alive it held **at most one** Store transaction in flight
   for that session, because `OwnerLane.transact/2` is a synchronous call the
   coordinator makes from its own process and threads the returned lane through
   its state (`store/owner_lane.ex:83-99`, `session_coordinator.ex:1242`,
   `:1363`, `:1702`). So at most one transaction can linearize after the
   coordinator is gone. A stale refusal is proof that it did — and proof that
   nothing else will, there being no process left to send one. Reattempting
   would spend a third and fourth Store call to fence a session that no longer
   has anything to fence, and would make this step's bound a number nobody
   could state. A
   `commit_unknown` is the opposite case: the transaction may have linearized,
   so it is **resolved once**, never re-proposed under a new identity and
   never retried into an unbounded loop.

   So the claim the plan makes is the one the mechanism supports: when
   `quiesce/1` returns, every session whose `fences` entry is `:committed` has
   had its epoch moved, every entry outside the result provably never entered this
   runtime's writer domain, and every other session is classified from what the
   journal actually holds. What it does **not** claim is that no transaction
   anywhere can still commit — a fence that is itself `commit_unknown` is
   precisely the case where the daemon says so rather than pretending, and it
   says so in a key a caller can read.

   **The cancellation never releases a session whose admission it cannot account
   for.** A session whose abort admission **failed or is ambiguous**
   — a refusal that is not `rejected_no_active_run`, or a `commit_unknown` on
   the admission itself — has no cleanup released for it at all. It is fenced
   like an unsettled session, or, where the fence too is unknown, left fenced
   and reported `unsettled` with `{:unknown, :fence, head}`. Releasing a
   cancellation for a session whose abort may or may not be in the journal is
   the one thing a drain must not do, because it would cancel work no command
   admitted.

   **The classification quiesce returns has three lists, not two, and it is
   total over the frozen writer-domain projection.** An earlier revision wrote it as
   though every entry were `:active`, and a later one found three statuses
   where there are **four**. `Control` writes `:acquiring`, `:active`,
   `:unavailable` and **`:awaiting_owner_barrier`** (`control.ex:835`,
   `:1040`, `:1046-1053`, consumed in the owner-group `DOWN` handler at
   `:833-857`), and a projected writer-domain ID may have no current entry, so
   the drain says what it does with each:

   | What `Control` holds | Why it can be there | Which list | Fenced? |
   | --- | --- | --- | --- |
   | `:active` with a live coordinator | The ordinary case | `settled` or `unsettled`, by whether the aborted run's **terminal fact is committed** — see the surface below | **Yes, either way** — see below |
   | `:active` whose coordinator is already dead | Its `DOWN` handler releases the dispatcher fence and **leaves the entry** (`control.ex:805-826`), which is right for residency and misleading for a drain | `absent` | **Yes** — an old transaction from that dead coordinator is precisely the case the fence exists for |
   | `:unavailable` in the writer-domain projection | The status `Control` writes when an acquisition it was waiting on failed or its coordinator went down mid-acquisition (`control.ex:620`, `:818`, `:862`, `:1150`) | `absent` | `unavailable_owner/3` (`:1149-1158`) writes `%{status: :unavailable, durable: nil}` with **no coordinator key**, and one caller reaches it at `:1134` *after* terminating a coordinator started at `:1132`; that writer-domain row is fenced. A start failure before any coordinator exists never enters the projection. Status alone cannot decide membership |
   | `:acquiring` | The status while an owner is being started (`control.ex:569`, `:1030`, `:1189`) | `unsettled` | **Yes** |
   | `:awaiting_owner_barrier` | A coordinator has died with its **owner group still alive** and a caller still waiting (`control.ex:835`, `:1040`, `:1046-1053`, consumed at `:833-857`) — reachable exactly when the bounded wait proceeds with a resume in flight | `unsettled`; no abort is admitted, there being no ready coordinator to admit one | **Yes, and the quiescing gate is what keeps the fence serial.** Today the later owner-group `DOWN` deletes the entry before calling `do_start_owner/6` (`control.ex:829-857`). Core change 4 gives quiescing its own branch: answer every waiter `runtime_unavailable`, retain or convert the entry with the durable head inputs needed by fence mode, and start no ordinary owner. The dead coordinator's at-most-one already-delivered transaction may still resolve. A forced witness makes Control consume the owner-group `DOWN` after the first census but before the second; the same session key remains, no ordinary child appears, and the one-shot fence-mode `SessionCoordinator` is the sole serial writer. The helper receives no Store handle |
   | A projected writer-domain ID with no current entry | Its writer started earlier in this runtime, but lifecycle cleanup removed the current entry after the first census | `absent` | **Yes**; monotonic writer-domain membership, rather than current entry presence, carries it through the fence |
   | A no-writer entry | No coordinator ever started for it in this runtime | In no list and no `fences` key | No; it is outside the frozen projection and starts no worker |
   | **An admission that did not answer** inside its bound, its task shut down | The session's abort is neither known-committed nor known-refused **to the drain** — see below for what the coordinator does | `unsettled`, with no cleanup released | **Yes** |
   | **A fence that did not answer** inside its bound, its task shut down **after** the head was read | The fence's outcome cannot be read | `unsettled`, `{:unknown, :fence, head}` | The attempt was made; the domain stays fenced |
   | **A fence task shut down before its head read answered** | There is no head, so there is no identity a successor could recompute and nothing was proposed | `unsettled`, `{:unknown, :no_head}` | No fence was attempted. A successor reads the head itself and proceeds; nothing is outstanding at any version |

   **What `settled` means, and where it is read.** An earlier revision defined
   it as "whether its cancellation finished inside the budget" and named no
   observation point, which left the most consequential of the three lists
   with no surface at all — and made termination able to kill a coordinator
   between its cleanup and its terminal commit and still report the session
   settled, with no terminal in the journal.

   **A session with no run to abort is `settled` at once**, and it is the
   commonest drained session there is. `propose_new/3` answers an abort on an
   idle session `"admission" => "rejected_no_active_run"`
   (`session_state.ex:1750-1761`); there was nothing to cancel, nothing is
   owed, and the session is reported `settled` without waiting for a terminal
   that no run will produce. It is still terminated and fenced like every
   other enumerated session.

   **Otherwise a session is `settled` exactly when the run the drain aborted
   has its terminal fact committed**, and that is read on a surface core already
   serves: the coordinator's own `{:session_status, owner}` call
   (`session_coordinator.ex:414-442`), whose reply carries `active_run_id`
   (`:421`) and `pending_work_ids` (`:425-426`) at the coordinator's committed
   cursor. A run whose terminal is committed appears in neither. **The two
   answers that must differ are therefore the aborted run present and the
   aborted run absent**, and the owner the call requires is the one quiesce
   read from `Control`'s enumeration, which is why that enumeration carries
   it. That read carries the coordinator's own bound, not the drain's:
   `session_status/2` is `safe_call(coordinator, …, @session_status_timeout_ms)`
   at 5,000 ms (`session_coordinator.ex:164`, `:181-182`), and quiesce reads
   it at budget expiry, when a coordinator that has just cancelled may be
   inside the cleanup callback whose commits are each bounded at 30 s. Any
   answer that is not `{:ok, …}` — a `:session_unavailable` refusal or the
   timeout — is read as **not settled**, which fails closed: the session is
   `unsettled`, terminated and fenced, and nothing false is journaled. The "it
   settles" witness therefore holds the Store fast enough for the read to
   answer, and a witness beside it holds one commit past 5 s and asserts the
   session lands in `unsettled` with its terminal still committed by the
   coordinator before termination ends it.

   **The census as a whole is bounded by one absolute
   `status_census_ms: 10_000` deadline, not by 5,000 ms per session.** The
   per-coordinator bound is the coordinator's own and is not multiplied by the
   number of enumerated sessions. All at most 64 reads are **issued together**.
   The first 5,000 ms are their work cutoff, matching
   `session_status/2`; every unanswered worker is then killed and reaped inside
   the reserved final 5,000 ms. A session whose status has not answered by the
   work cutoff is `unsettled` under the same fail-closed rule that covers a
   refusal or a timeout. Nothing is lost by that: a status that did not answer
   was never going to be read as settled.

   No core change is needed for this, which is worth saying plainly after
   several rounds of adding things: the read exists, quiesce is outside
   `Control` and can make it, and a coordinator that refuses it —
   `:session_unavailable` for a superseded or not-ready owner — is not a
   settled session anyway.

   **So a cancellation that finished without its terminal committed is
   `unsettled`, never `settled`**: terminated, fenced,
   and reconciled at the next activation like any other. Termination therefore
   kills no owed write of a session it called settled, because a session is
   called settled only once the write it owed is already in the journal.

   **Quiesce admits no abort into an `:acquiring` entry, and the disposition
   is right even though an earlier revision's reason for it was not.** That
   revision said an `:acquiring` session "has no ready coordinator". It may
   have one: the coordinator sets `phase: :ready` (`session_coordinator.ex:1407`)
   and then **casts** `{:owner_ready, …}` to `Control` (`:1424`) before
   sending itself `:advance_work` (`:1425`), so a fully ready coordinator — a
   resumed one, with a recovered active run already advancing — sits behind an
   `:acquiring` entry until `Control` consumes that cast.

   The rule rests on the implication that actually holds: **`:active` ⇒
   ready**, because `Control` writes that status only in the `owner_ready`
   handler (`control.ex:575-591`). Quiesce admits only into `:active`, which
   is sound — every entry it admits into has a ready coordinator — and is what
   keeps the admission off the acquisition callback, which is far deeper
   than any ready one. What it costs is stated rather than hidden: an
   `:acquiring` entry whose cast is merely in flight is a session whose run is
   **ended crash-equivalent** by termination rather than cancelled
   through its own grace. Its journal claims no terminal, its ambiguous
   mutation is `commit_unknown`, and the next activation reconciles it —
   which is exactly the unsettled disposition, reached without the drain
   having to guess at a cast it cannot see.

   **`:acquiring` is reachable, and an earlier revision called it unreachable.**
   That revision's argument was the cut: only `session.create` and
   `session.resume` write that status, both start a coordinator inside the
   call, both are ticketed, and the cut waited for every ticket to settle — so
   none could be in flight. The argument died with the bounded wait, which
   waits for the admitted tickets and then **proceeds**, and a
   resume whose replay is paging a long history is exactly the ticket most
   likely to still be running when it does. So an `:acquiring` entry is an
   ordinary outcome of a stop that fell back on its bound, not a defect.

   It is classified `unsettled` and **fenced**, which is the safe answer and
   also the right one: the session's ownership is mid-advance, so either the
   owner transaction commits — and the fence, reading a head that has moved,
   is superseded and says so — or it does not, and the fence moves the epoch
   under a candidate that will then be refused. Both are decided outcomes.
   Quiesce admits no abort for it because only `:active` proves that the
   owner-ready transition has completed; it does not guess from an acquiring
   coordinator's internal phase.

   **Where "reports" lands, since a list in a return value is not a surface.**
   The daemon has two places to put what quiesce answers, and it uses both:
   the counts — settled, unsettled, absent — go in the **stop line on
   `stderr`** beside `budget_ms`, `fence_budget_ms` and `drain_id`, which is what an operator
   reading a stopped service's log sees; and nothing goes on the wire, because
   by the time quiesce returns the clients have not yet been told anything and
   what they are told is `operator_stop`, not a census. A session in `absent`
   is therefore distinguishable from one in `settled` exactly where the
   difference is actionable, and nowhere it would be noise.

**Quiesce's reads are not made through the facade's default timeout.** `control_call/3`
and `dispatcher_call/3` both default to `5_000` (`runtime.ex:470`, `:478`), and
a drain whose budget is derived from a session's cleanup grace will routinely
exceed that — a five-second reply timeout would abandon a drain that was
working and leave the daemon tearing down underneath it. The reads `quiesce/1`
makes into `Control` therefore carry explicit bounds rather than the default,
and the drain's own budget is data it holds rather than a reply timeout.

**`quiesce/1` runs outside `Control` without changing its arbitrary caller's
process flags.** It is a daemon-scoped, `@doc false` runtime entry point. For
the daemon, the caller is a monitored, unlinked
outer helper started by the owner; it is not the owner process itself. The owner remains in its receive loop for the whole, potentially very
large, derived drain budget so Store/executor EXITs and the exact
Control/EventDispatcher sentinel DOWNs cannot queue unseen behind a synchronous
call. Runtime-root loss during active quiesce remains `runtime_lost`. A
Control-first event checks the retained exact root pid and latches
`drain_failed` only while that root is live. An EventDispatcher-first event
checks the retained root and Control pids in that order, so root loss remains
`runtime_lost`, a Control rest-for-one restart remains `drain_failed`, and
isolated dispatcher loss remains `runtime_lost` regardless of message order. That
first component class terminates the helper and enters fail-stop; it cannot
later be overwritten by a successful quiesce message. A helper exit or
`{:error, :runtime_unavailable}` with no earlier
component class is `drain_failed`. An earlier revision said `Control` "already
holds every active session and its coordinator pid, so there is nowhere else
this could live". It could not live there. `Control` is on the commit path of
every coordinator in the runtime: a commit ends in `Control.post_commit/5`,
which is a `GenServer.call(control, …, :infinity)`
(`control.ex:182-209`, the call at `:199-203`, made at
`session_coordinator.ex:1710` and `:6431`), and scheduling asks
`Control.current_owner/3`, another `:infinity` call (`control.ex:92-98`, at
`session_coordinator.ex:1778`). A drain executing **inside** `Control`'s
process would therefore hold the mailbox that every abort it just admitted
must reach to commit: each coordinator would block in `post_commit` forever,
every admission would time out as ambiguous, and nothing would ever settle.
Not a race — a certainty, on the first session with work to drain.

So `quiesce/1` is an internal function of **`Loopex.Runtime`** whose caller starts and
monitors one private **phase owner**. The phase owner monitors the caller, sets
`trap_exit`, owns all phase/deadline state and is the only parent of the linked,
non-trapping per-session workers. It is a pure receive coordinator: every
potentially blocking child lookup, `Control`/coordinator call, supervisor stop or
temporary-coordinator wait runs in one of those workers, so the phase owner can
always consume the caller monitor and worker exits. The caller changes no process flag and
maps phase-owner `DOWN` without a result to
`{:error, :runtime_unavailable}`. If the caller dies, its monitor makes the
phase owner terminate with a non-normal reason, which ends every linked worker.
For the daemon the caller is its unlinked outer helper, which sits on no commit
path, while the daemon owner handles lifecycle signals and `Control` keeps
serving `post_commit` and `current_owner` throughout.
At entry a linked worker resolves the exact `Control` pid once through
`RuntimeSupervisor.children/1`; the phase owner installs a monitor and retains
that pid only for this call. Its next worker makes `begin_quiesce(drain_id)`, one
Control operation that must return with the lookup inside the first 5,000 ms of
the already-started `quiesce_admission_ms` clock. It atomically sets the terminal quiescing gate and
returns the monotonic writer-domain session-ID set and, for each member, its
current status, coordinator pid and owner when present. Control adds membership
immediately after
`DynamicSupervisor.start_child` succeeds, before later attach or readiness work,
and never clears it in the runtime lifetime. A status alone cannot recover the
fact: a started owner whose attach failed can be reset to `:unavailable` after it
has already entered succession.

The same serialized operation counts the writer-domain entries after
installing the gate. Above 64 it returns `{:error, :runtime_unavailable}` before
the phase owner spawns a per-session worker or fence writer. The daemon's
activation reservation is converted even when a later error follows a successful
child start, so correct daemon use keeps that set at or below 64. More than 64
never-started dormant entries are allowed but omitted from the result and start
no worker; a separate impossible 65-entry core case proves bounded refusal.
Create, resume, attach and ordinary routes ordered after the gate refuse.

At the start of termination the phase owner starts
`coordinator_termination_ms: 330_000` and asks the same captured Control pid for
a read-only projection under the existing gate within its first 5,000 ms. Its key set must equal the
frozen first set exactly. A missing or extra key makes the whole operation
`{:error, :runtime_unavailable}`. A writer-domain ID whose current entry
disappeared is projected as absent, not treated as a missing key.
`owner_replayed` between the censuses retains a
non-routable row, starts no ordinary owner and remains fence-eligible when its
writer bit is true. Ordinary status, abort, cancellation and termination work
runs concurrently in linked per-session workers; the phase owner never calls
the Store.

After every ordinary coordinator is `DOWN`, the phase owner preallocates an
`op_ref` for each eligible entry and retains it before sending
`start_fence(op_ref, phase_owner, session, absolute_deadline)` to Control. Control
first refuses an expired message; otherwise it starts a one-shot fence-mode
`SessionCoordinator` with `spawn_monitor`, outside the ordinary session
supervisor and with the Store handle kept inside core. The process links to the
phase owner, handshakes with Control and waits. Control records the exact pid in
the frozen entry and sends `{fence_started, op_ref, pid}` directly to the phase
owner; it does not send `go`. The phase owner installs its own monitor, retains
`{op_ref, pid, monitor_ref}`, and sends
`authorize_fence(op_ref, absolute_deadline)` only while the shared phase deadline
remains live. Control validates the registered operation and rechecks the
deadline before sending `{go, absolute_deadline}`. The fence process checks the
same deadline on receipt and refuses before any Store operation if it expired.

The fence phase computes two absolute instants once before any start and shares
them across every eligible entry. Its
`fence_work_deadline = t0 + 125_000` is the Store-work cutoff: four sequential Store calls
at the local adapter's fixed 30-second call timeout cover abort-status recovery
plus the maximum fence path, and five seconds cover the Control
start/authorize handshake. A separate outer deadline at `130_000` ms reserves five seconds to kill and reap every exact pid after the Store-work cutoff. The result reports that outer bound separately as `fence_budget_ms`; `budget_ms` remains the cancellation budget derived from
committed cleanup graces. The daemon stop line and operator page show both.
Sixty-four held Store paths prove cancellation begins at 125 seconds, every
exact pid and operation is absent by the 130-second outer deadline, and return
uses one shared deadline rather than sixty-four, while a sibling path completes
normally.

At `fence_work_deadline` the phase owner sends `cancel_fence(op_ref)` for every
unresolved operation, kills every exact already-authorized pid, and permits no
further Store operation to begin. A start message handled after its carried
deadline refuses without a spawn. A started but unauthorized operation makes
Control kill the exact waiting pid and acknowledge only after its own monitor
consumes `DOWN`. Authorize before cancel means the phase owner already owns the
exact pid and monitor; its kill is idempotent, it awaits `DOWN`, and Control
consumes the same terminal operation idempotently. The fence phase uses no
separate waiter worker. A Store call authorized and begun before the work cutoff
keeps its ordinary ambiguity. Control cancellation acknowledgements and every
exact `DOWN` are consumed only until `fence_deadline = t0 + 130_000`; a missing
acknowledgement or surviving pid at that outer deadline returns
`runtime_unavailable`. No new Store call starts after the work cutoff.

If the daemon owner kills the unlinked outer helper after Store, Control or
dispatcher loss, the phase owner's caller monitor fires and ends every linked
worker and temporary coordinator before fail-stop. One abnormal worker affects
only its session while siblings finish. Forced phase-owner death and deadline
cuts cover Control handling an already-delivered start after its deadline, after spawn before
the phase owner receives it, after receipt before authorization, after
authorization before `go`, before the head reply, inside the first transaction,
and before and inside exact re-presentation. Each leaves no temporary writer or
later Store call; sibling work finishes.

**The enumeration exports no drain context or Store handle.** `%Loopex.Runtime{}`
is `defstruct [:supervisor, :token]` (`runtime.ex:46`) and the Store handle
remains in Control's state (`control.ex:218`). Both projections return only
session ID, status, coordinator pid, owner and `writer_started?`. The fence-mode
coordinator is the sole serial writer for abort-unknown recovery followed, where
permitted, by one `advance_owner` and one byte-identical re-presentation on
`commit_unknown`, then exits. Start and handshake are short mailbox operations;
waiting occurs outside Control, so `post_commit` remains available. A suspended
ordinary session supervisor cannot delay a fence start or release a queued one
later.

**That enumeration does not exist today, and adding it is part of core
change 4.** `Control` answers `{:session_status, token, session_id}` for **one**
session (`control.ex:473-481`) and has no call that projects `state.sessions`
at all. So quiesce's read is a new `Control` call — a plain-data projection of
every entry's session ID, status, coordinator pid and owner, taken in one
`handle_call` and returning immediately, which is what keeps it from blocking
the process it reads. It is named in the concept pair's core-change list and
in the ownership table beside `quiesce/1` itself. The one-shot fence-mode owner
and its short start call are the other half of that change, because a change
nobody listed is a change nobody reviews.

Neither read blocks `Control` for longer than a map projection, so a
coordinator committing in the middle of the admission is served as usual. That is
the witness: **a commit made by a coordinator during the abort admission completes** — its
`post_commit` answered while the drain is running — **and its session
settles**. Under the design this replaces, that case hangs. A second witness
restarts `Control` after the first successful read and before the second; even
though the replacement can answer an empty census, the captured pid's death
makes `quiesce/1` return `{:error, :runtime_unavailable}` with no partial result.

**Why core rather than the daemon.** The daemon cannot do this without
reaching into coordinator internals, which the dependency direction forbids,
or running a cancellation loop of its own, which is precisely the second loop
this milestone forbids — and it certainly cannot admit a durable command on
its own authority. Core owns coordinator lifetime, cancellation and admission,
so core is where a bounded settle belongs. It returns **plain data** — session
  IDs, three lists, `budget_ms`, `drain_id` and the per-session `fences` map,
  or the one stable error — so nothing about a coordinator crosses the boundary.

**What it does not promise.** A session whose cancellation cannot finish
inside the derived budget is reported **unsettled**, and its coordinator is
fenced and terminated at the deadline. Because the budget is derived from the
same formula the cancellation uses, this is the case where an effect exceeds
even its own backstop — not the case where the daemon was impatient. An
earlier revision used the raw cleanup grace as the drain deadline, which
guaranteed the mismatch: `cancellation_bounds/1` derives an observation bound
of `max(10_000, grace_ms + 2_000)` from that same grace
(`apps/loopex/lib/loopex/executor.ex:458`), and `cli_backstop_ms` is larger
still.

**The owner remains responsive while the helper drains.** It keeps reading
linked component EXITs, Control/dispatcher sentinel DOWNs, the helper result
and signals throughout the derived budget. A component failure latches its
real class, stops the helper and enters fail-stop immediately, so Store or
dispatcher loss can never be overwritten by a later orderly result. A second
`SIGTERM` during the drain is idempotent: the sequence is already running, and
the owner discards it rather than restarting anything.

**A session waiting on an interaction cannot settle, and that is correct.**
An answer to a durable interaction is a session command under ADR 0024, and
step 1 has already refused admissions, so no answer can arrive during the
drain. Such a session is reported **unsettled**, its interaction stays durable
and unanswered, and the next daemon can answer it — which is exactly what a
durable interaction is for. Quiesce does not answer, expire or abandon one.

So the outcome has two halves and both are said: **work that settled within
the grace has its ordinary terminal facts in the journal** — including
`cancelled` where a cancellation produced one, which is a true statement about
work that was actually cancelled — and **work that did not settle is left
unclaimed**, its ambiguous mutation `commit_unknown`, reconciled to exactly
one outcome at the next activation. The negative an earlier revision asserted
without qualification — that no terminal is ever claimed — is now the precise
one: no terminal is claimed for work that did not settle.

The rejected option is recorded: the smaller design with no drain at all —
refuse, tell, close, tear down — which this file carried for one revision. The
maintainer rejected it on 2026-09-20. It was smaller, and it was also a
daemon that told an operator nothing about whether its work had finished.

One ordering consequence follows from the drain and reverses an earlier
revision of this file: clients are told **after** it, not before. A client
that waits a few seconds and then learns the true reason is better served than
one told early about work whose fate was not yet decided, and the connections
stay open across the drain so that the record can still be written.

**And "told" is an attempt, not a guarantee.** The write is one attempt into
the existing 4 MiB output buffer, on a transport the client may already have
dropped; ADR 0032 admits an EOF alone as a complete ending for exactly this
reason. Listener loss after the completed controlling-process handoff does not
remove accepted connections or the registry's write interface, so it still
makes this attempt; connection-registry loss
cannot. A client
learns the reason from the record where the write succeeds and from the close
where it does not — that is the whole promise, and no part of this plan
depends on a stronger one.

**Cancellation is not the daemon's to run**, and that rule survives the drain
rather than being softened by it. The abort quiesce admits is admitted **by
core, on the operator's signal, through core's own path** — not by the daemon
issuing a mutation over the socket, which stays forbidden and is why there is
no `daemon.stop` method on the wire. An earlier revision rejected
"host-authorized durable aborts" as the daemon issuing mutations on nobody's
authority; that was right about the daemon and wrong as a reason to cancel
with no record at all, which is what it left behind. An unbounded natural
drain was rejected with it and stays rejected: it would make `SIGTERM`
unbounded, which is not a stop.

**The drain is core's, not the daemon's**, and that is the same rule seen from
the other side. The daemon asks for a bounded settle and waits for the answer;
every decision inside it — which abort to admit, which effect to cancel,
under what bound, what to record — is core's, running the paths it already
has. The daemon neither admits a command nor interprets a cancellation, and a
session that cannot settle in time is fenced by core rather than left running
behind a report.

**Store loss, a fail-stop path.** The owner holds the Store's link and its
pid, so the adapter's termination arrives as `{:EXIT, store_pid, reason}` at
the owner's own clause, carrying the store's real reason. That clause is the
fatal-class map's reader: it matches the pid, classifies `reason` as
`store_capacity_exceeded` where that was the store's own refusal and
`store_lost` otherwise, and has the class in hand before it does anything
else. No link the owner does not already hold, no monitor to remember, and no
information lost on the way.

**The steps below are the fail-stop path for every fatal class, not only the
two store ones.** Store loss is the instance worth reading first because it is
the one where the thing the daemon would otherwise stop is already gone. The
linked-component set is closed: the Store has `store_lost` and
`store_capacity_exceeded`; the others have `transfers_lost` where enabled,
`workspace_lease_lost`, `executor_lost`, `registry_lost`, `custody_lost`,
`capability_lost`, `runtime_lost`, `relay_lost`, `connections_lost` and
`listener_lost`. `drain_failed` reaches the same path either when `quiesce/1`
or its helper cannot produce a trustworthy census without an earlier component
class, or when captured Control loss or replacement invalidates the active
quiesce census. In every case the
owner has a class in hand, runs no orderly sequence, and does not return to
serving. A step whose component is already gone is a no-op. Under
`listener_lost` new accepts have already stopped, but the registry and accepted
connections remain for the bounded stop record; under `connections_lost` no
such delivery can be claimed.

Before the first teardown action, the owner sends the lifecycle sentinel the
exact fatal-latch tuple. The sentinel atomically retains the first class and its
unique status, starts the unawaited diagnostic helper, and owns the absolute
35-second watchdog. The owner may finish earlier; it cannot extend that instant.

1. **Cut service without a synchronous call.** At the instant it latches the
   first fatal class, the owner computes an executor deadline of
   `latched_at + 5_000`, marks the exact listener and relay pids as intentional
   fatal teardown, and
   sends each surviving pid an untrappable `:kill`. A suspended listener cannot
   accept again and a suspended relay cannot admit or dispatch after that
   signal; the owner consumes their exact linked `EXIT`s if they arrive but does
   not wait for either. A component already dead is skipped.
2. For every fatal class **except `connections_lost`**, send the connection
   registry one idempotent **ordinary message**, never a call and never an
   awaited acknowledgement, asking it to attempt one `daemon.stopping` per
   connection and close: `store_lost`, or `store_capacity_exceeded` when the
   Store's own reason was the capacity refusal, and `fatal:<class>` for every
   other deliverable fatal class. A responsive registry performs the bounded
   best-effort writes. A suspended registry cannot extend the exit bound; its
   connections receive EOF at `System.halt/1`. On `connections_lost` there is
   no inventory or buffer-control interface to message, so the owner skips this
   step. In all cases the killed listener and relay have already ended new
   accepts and admissions.
3. **Stop the executor** — on every class but `executor_lost`, where it is
   the component that already died — under the same discipline as every other
   stop: a monitored helper calling
   `GenServer.stop(pid, :normal, remaining(deadline))`, the owner waiting on
   its own link until the earlier of the executor deadline and the global
   watchdog, killing on expiry. The listener/relay kills and registry message
   add no awaited phase. This is not tidiness: the executor is
   the one linked process whose work reaches outside the VM, and stopping it
   is what tells its Port-owning workers to terminate the captured process
   groups. Halting without stopping it would never start that cleanup at
   all. The residual is the one stated there and is
   the same here: if the stop times out and the executor is killed, the halt
   that follows also ends the Port-owning worker that would have terminated
   the captured process group, so operating-system children may survive the
   daemon. The journal does not: the effect is `commit_unknown` and reconciles
   at the next activation.
4. **Stop the Store — on every class except the two store classes.** Where the
   Store terminated itself, `store_lost` or `store_capacity_exceeded`, it is
   already gone and its `terminate/2` has attempted marker release; there is nothing
   to stop. The independent placement lock remains until the owner halts the
   daemon VM in step 6, after which stale-owner recovery can prove the recorded
   OS holder dead. On every other fatal class, the Store is **still alive**, and
   because `System.halt/1` runs no `terminate/2`, halting past it would leave
   the marker file behind on a daemon that shut down deliberately. So the
   owner stops it here. `store_stop_started_at` is captured when this phase
   begins, and
   `min(store_stop_started_at + 30_000, latched_at + 35_000)` is the absolute
   deadline. The adapter's own phase is still independent of every cleanup
   grace and is at most 30 seconds; the global watchdog wins if earlier. A
   healthy filesystem completes the attempt in milliseconds. This precedence is what turns
   the arithmetic sum into a wall-clock guarantee.

   **If that stop times out and the Store is killed, the marker survives; a
   completed stop may also leave a complete marker after an ignored removal or
   sync error.** Those are the residuals on this path and the plan states them
   rather than implying otherwise. They are bounded in consequence, not open-ended: the next
   daemon meets exactly the stale marker ADR 0031's recovery rule already
   covers, and reclaims it where the marker's own recorded holder is probed
   and found dead, refuses with `store_writer_unverifiable` where it cannot be
   decided, and refuses with `store_writer_active` where it is alive. A
   surviving marker is a case with a defined answer, not a corruption.
5. **The socket path is left alone**, exactly as the orderly path leaves it.
   No daemon unlinks a path on its way out, whatever class it is exiting with;
   the next verified placement-lock and marker holder removes it only after the
   no-follow owner-and-socket-kind check and before binding. **The runtime root, the lease owners, the registry, the
   custody process and the transfers owner are not stopped on this path**, and
   that is deliberate rather than an omission. A fail-stop is not a drain, and
   none of them owns anything that outlives the VM: the executor does, which
   is why step 3 of this path exists, and
   the Store holds the marker, which is why step 4 of it does, while the transfers
   owner's open descriptors are closed by the operating system when the VM
   goes. Stopping the lease owners would buy less here than on the ordered
   path, where the point was to stop the executor before it — on
   `executor_lost` there is no executor left to read the lease holder's `DOWN`
   at all.
6. **Halt with the unique non-zero status for that class.** The diagnostic
   helper started at the latch is never joined; a blocked or broken stderr may
   omit the line and cannot delay the halt.

   **A fail-stop has an operator bound too, and it is much smaller than an
   orderly stop's.** Only two of its steps can wait: the executor stop until
   `latched_at + 5_000`, and the Store stop until the earlier of its own
   30-second deadline and the global instant. Nothing else waits on anything — there is no drain, no admission,
   no fence, no coordinator to terminate and no runtime tree to bring down.
   The lifecycle sentinel therefore calls `System.halt(status)` no later than
   **35 seconds after the first fatal latch**, independent of phase-transition
   overhead or IO. On the two store classes the owner normally
   finishes within 5 seconds, the Store being already gone while the placement
   lock remains until the halt. Nothing restarts anything: the owner `start_link`s its fixed
   set and restarts none, so an exit it did not cause is fatal by its own clause —
   which is why this path exists at all rather than being a restart.

Nothing durable is at risk in that ordering: whatever was ambiguous is
`commit_unknown` in the journal and is reconciled at the next activation, and
whatever was not committed was never promised.

**How the daemon actually ends, on either path.** On a completed operator stop,
including bounded startup reverse cleanup before readiness, the owner's last
act is `System.halt(0)`. On a fatal path, the owner halts with
the latched integer status when it finishes first; the lifecycle sentinel uses
the same retained status if owner `DOWN` or the 35-second watchdog wins. That
matters to state because BEAM exit semantics alone would not do it: a `:normal`
exit from the owner is ignored by every linked process that does not trap, so
"the owner exits" is not by itself a shutdown.

**And `halt` runs no callbacks**, which is the whole reason the sequences
above stop things explicitly rather than trusting the exit. `:erlang.halt/1`
terminates the VM immediately: no `terminate/2` anywhere, no `Application`
stop callbacks. The alternative, `:init.stop/0`, does run them — and is
rejected here precisely for that, because it would walk the application tree
and wait on whatever the orphaned owner-group subtree is doing, which is the
unbounded wait the grace exists to avoid. The daemon takes a bounded stop it
performs itself, then a halt that cannot hang.

**One consequence this had to fix.** No callback cleanup happens at the halt.
On the ordered path that is fine — the Store was already stopped in step 6,
its `terminate/2` attempted marker release, and the bounded placement helper
attempted exact-handle release. Healthy evidence proves the paths absent; either
best-effort call may instead leave a complete residual. On a Store-loss path the
Store has already attempted marker release, while the halt makes the deliberately
retained placement lock recoverable. On the other **fatal** paths an
earlier draft left a real hole: for the classes where the Store is still alive (`runtime_lost`,
`transfers_lost`, `workspace_lease_lost`, `executor_lost`, `registry_lost`,
`custody_lost`, `capability_lost`, `relay_lost`, `connections_lost`,
`listener_lost`, and `drain_failed`), nothing
stopped the Store, so the halt
left the marker file behind on a daemon that had shut down deliberately. The
fail-stop path above therefore stops the Store on every fatal class
**except** the two store classes, where it is already gone.

**An abrupt death** — `SIGKILL`, direct `SIGHUP`, power loss — runs neither path, and is safe
for the reasons the durability rules already give: nothing the journal does
not hold was ever promised, the placement lock and any marker left behind are
reclaimed by their verified stale-owner recovery, and the socket file is a
stale path the next placement-lock and marker holder removes only after the
no-follow owner-and-socket-kind check.

**The nonzero-class and status map.** Exit status is the authoritative
operator result: `0` means an operator-requested termination or successful
offline import. At the pre-handler root-resource prompt it is BEAM's default
termination, with no daemon-owned resource acquired and no daemon cleanup path
run; after handler installation it means the documented reverse-clean orderly
sequence completed. A handled import interruption is deliberately nonzero.
Every nonzero class has
one unique integer from 65 through 110. A one-shot helper attempts the class on
`stderr`, but the sentinel never awaits that helper, so a blocked diagnostic
cannot change or delay the status. Running-component failures enter the owner's
one classifier through `{:EXIT, pid, reason}`; startup steps enter through their
tagged return. Input validation performed before the owner exists enters the
same map directly in the command process. Offline import maps its post-parser
state-root, placement, Store, index and interruption results here through its
own owner and sentinel. The classifier preserves the typed
input, placement, Store, index and socket-path classes named below. Every other
signal-install result becomes `signal_install_failed`; registry, custody or
capability start result becomes `credential_plane_start_failed`; arbitrary
`start_edges/2` failure becomes `composition_start_failed`; relay or connection
registry start result becomes `daemon_services_start_failed`; socket create,
bind, listen or listener-start result, or a linked parked-listener `EXIT` whose
fatal notice the sentinel consumes before release authorization, becomes
`listener_start_failed`;
and readiness-output failure becomes `readiness_write_failed`. Lower-level
terms remain only in bounded redacted diagnostics and never become a class.

| Class | Status | When | Wire reason |
| --- | ---: | --- | --- |
| `state_root_required` | 65 | Startup or offline-import input: no state root was supplied | — no socket exists |
| `state_root_unusable` | 66 | Startup or offline-import input: the state-root bytes are not valid UTF-8, or the root cannot be created, resolved or read | — |
| `workspace_required` | 67 | Startup input: no workspace was supplied | — |
| `workspace_unusable` | 68 | Startup input: the workspace or its identity cannot be read | — |
| `provider_launch_required` | 69 | Startup input: no provider launch was supplied | — |
| `provider_launch_invalid` | 70 | Startup input: the launch configuration is unreadable or invalid | — |
| `policy_required` | 71 | Startup input: no host policy was named | — |
| `policy_unknown` | 72 | Startup input: the named host policy is unknown | — |
| `provider_credential_required` | 73 | Startup input: no provider credential was supplied | — |
| `project_skills_unusable` | 74 | Startup input: workspace project-skill-pack discovery or validation failed; an empty `.agents/skills` set remains valid | — |
| `cleanup_grace_invalid` | 75 | Startup input: cleanup grace is outside core's admitted domain | — |
| `placement_active` | 76 | Startup or offline import: the host placement lock is held by a proved-live daemon | — |
| `placement_unverifiable` | 77 | Startup or offline import: the placement holder cannot be decided | — |
| `placement_lock_failed` | 78 | Startup, offline import or final cleanup: placement identity/create/write/link/close failed without a proved predecessor classification, the acquired regular-file owner handle could not be read and verified for `daemon_uid`, or the bounded exact-handle release helper failed or expired with no earlier class | — |
| `store_writer_active` | 79 | Startup or offline import: the marker is held by a live holder | — |
| `store_writer_unverifiable` | 80 | Startup or offline import: the marker's holder cannot be decided | — |
| `store_writer_acquisition_failed` | 81 | Startup or offline import: marker identity/recovery/create/write/sync/close failed for a reason other than a proved live or unverifiable predecessor; an error after exclusive create may leave a complete stale or undecodable partial marker | — |
| `store_log_too_large` | 82 | Startup or offline import: the log is already past the capacity bound | — |
| `session_index_too_large` | 83 | Startup or offline import: the encoded index or row count exceeds its bound | — |
| `session_index_corrupt` | 84 | Startup or offline import: the index version, digest, ordering, uniqueness or row shape is invalid; canonical and legacy rows disagree on placement identity; or a non-temporary legacy entry fails strict containment, file-kind, size, stable-read, safe-decode, exact-key, identity, UTF-8 or command validation | — |
| `session_index_upgrade_required` | 85 | Startup: a legacy root has session entries but no daemon index | — |
| `session_index_write_failed` | 86 | Startup or offline import: the fixed index temporary could not be cleaned or durably replaced | — |
| `socket_path_too_long` | 87 | Startup: the path exceeds the derived `sun_path` bound | — |
| `socket_permission_unverified` | 88 | Startup: subdirectory or bound-socket ownership/mode could not be verified, or a pre-bind selected path was not proved by no-follow owner, type and mode checks to be a same-user Unix-domain socket and safely removed | — |
| `invalid_socket_path` | 89 | Startup: a `--socket` override has invalid UTF-8 bytes or is outside the selected root's `daemon/` directory | — |
| `signal_install_failed` | 90 | Startup or offline import: the required `SIGTERM` handler could not be installed | — |
| `credential_plane_start_failed` | 91 | Startup: credential registry, custody or tracing-capability start failed | — |
| `composition_start_failed` | 92 | Startup: `start_edges/2` returned a non-allowlisted edge failure after returning its exact partial map | — |
| `daemon_services_start_failed` | 93 | Startup: admission relay or connection-registry start failed | — |
| `listener_start_failed` | 94 | Startup: socket create, bind, listen, parked-listener start/ack failed, or the owner ordered the linked parked-listener `EXIT` into the lifecycle sentinel before release authorization and the sentinel's exact `begin_accept` send | — |
| `readiness_write_failed` | 95 | Startup: the readiness request refused, its helper died, or its absolute deadline elapsed before the sentinel consumed release authorization | — |
| `store_capacity_exceeded` | 96 | The Store exited on its own capacity refusal | `store_capacity_exceeded` |
| `store_lost` | 97 | A running daemon's Store, or the Store held by offline import, exited for any other reason | `store_lost` when initialized daemon clients exist; no wire surface during import |
| `transfers_lost` | 98 | The artifact transfers owner exited | `fatal:transfers_lost` |
| `workspace_lease_lost` | 99 | The workspace lease exited | `fatal:workspace_lease_lost` |
| `executor_lost` | 100 | The local executor exited | `fatal:executor_lost` |
| `registry_lost` | 101 | The credential routing registry exited | `fatal:registry_lost` |
| `custody_lost` | 102 | The credential custody process exited | `fatal:custody_lost` |
| `capability_lost` | 103 | The tracing capability exited | `fatal:capability_lost` |
| `runtime_lost` | 104 | The runtime root exited; outside active quiesce the exact monitored `Control` or `EventDispatcher` child exited or changed identity; during active quiesce a child event's nonblocking retained-pid check found the root dead, or captured EventDispatcher exited or changed identity while root and captured Control remained exact and live; or a holder-cleanup worker exited abnormally, exited normally without its exact acknowledgement, or acknowledged without the exact normal `DOWN` by its bound | `fatal:runtime_lost` |
| `relay_lost` | 105 | The admission relay exited, or an exact relay control exchange was missing, late, malformed or inconsistent, so admission tickets or retained settlement state cannot be proved complete | `fatal:relay_lost` |
| `connections_lost` | 106 | The connection registry exited, or an exact registry control exchange was missing, late, malformed or inconsistent, so connection slots, monitors, buffer control or the required routing mirror cannot be proved complete | — the record would have gone through the interface that is gone |
| `listener_lost` | 107 | After exact `begin_accept`, the first or any later accept-loop operation failed, the listener exited unexpectedly, or the owner did not observe its exact linked `EXIT` and reap by the orderly transport-cut deadline, while the connection registry and any accepted initialized connections remain | `fatal:listener_lost` |
| `drain_failed` | 108 | `quiesce/1` returned `{:error, :runtime_unavailable}`; during active quiesce captured Control exited or changed identity while the retained exact root remained live, including when an EventDispatcher-first monitor event's nonblocking checks found that root live and captured Control absent or dead; or the monitored outer quiesce helper exited or disappeared without its exact result and no earlier component class was latched, so no census or fence result can be claimed | `fatal:drain_failed`, best effort before crash-equivalent teardown |
| `owner_lost` | 109 | The monitored daemon owner died before sending a fatal latch | — no live owner can write a record |
| `prepare_index_interrupted` | 110 | Offline import: a handled operator stop won after signal-handler installation; the scan is reaped and Store and placement cleanup are bounded, while a post-rename complete image is retained | — no socket exists |

The mapping is injective and closed: status `0` has no nonzero class; every
composition input, startup step, linked running component, drain failure and
owner loss, plus handled import interruption, has exactly one row; no atom is
ever passed to `System.halt/1`.

**A lease owner's exit is the one that is not in this table**, and its absence
is the rule rather than an omission. The owner's clause maps that pid to the
session it belonged to and handles it per session. After any signal-ordered
mirror operation, the daemon atomically pops only that dead pid/incarnation's
routing row but does not yet notify or close a returned holder. The relay
atomically claims every pending acquire or release permit whose immutable
intended actor names that exact dead owner, every executing permit whose actor
binding names it, and every `pending_ticket` or queued lease-authorized mutation
bound to it as `owner_lost`. It kills and reaps a queued mutation worker, starts
no core task for an unpromoted mutation, and retains every winner without
rendering. A promoted mutation instead remains relay-owned to its real core
result, fatal disposition or orderly seal. Under a fresh five-second
relay-control instant, the daemon sends exact
`{:owner_lost_classified, classification_ref, owner_pid, owner_incarnation,
holder_connection_incarnation_or_none}` after mirror pop. The relay retains
whichever of that classification and its exact owner `DOWN` arrives first and
joins only matching facts; an early classification is not rejected. For every
claimed origin on the returned holder it selects `holder_close` and suppresses
the correlated reply. For every other claimed lease operation it selects the
correlated request-shaped refusal and keeps that connection open. Only after
each claimed origin reaches its selected terminal disposition does it answer
exact
`{:owner_lost_classified_ack, classification_ref, owner_pid,
owner_incarnation}`. Only after that acknowledgement does the daemon write the
uncorrelated holder-loss form and close the returned holder. A renewal changes
no mirror, and a renewal result sent directly to the relay before owner `EXIT`
wins `result` by signal order. Release instead uses the daemon-coordinated
result-CAS-and-clear settlement defined above: an `owner_lost` winner preserves the
holder mirror for classification, while a `result` winner clears it before its
one correlated success and makes a later pop absent. No successor starts until
the pop, classification acknowledgement and terminal holder-close or
correlated-refusal settlement complete; its first grant additionally waits for
every predecessor ticket and retirement completion. For a
holder-changing proposal reported first to the daemon, the relay's independent
owner-`DOWN` handling may instead win `owner_lost` before the daemon's result
CAS; that path resolves the provisional mirror cancelled, awaits its clear,
answers the correlated refusal once and leaves the connection open. A daemon
result CAS that wins first resolves granted, after which the owner-loss path
closes the exact promoted holder. An executing fresh acquire owned by the
still-live daemon owner is not claimed merely because its provisional child
dies. Those correlated-refusal connections stay open. If the owner was free or
retiring and no lease operation was claimed, there is nobody to notify. Every
observer stays attached, every predecessor barrier and mutation ticket survives
until settlement, and every other session keeps serving. The next
`session.acquire_control` starts a fresh owner with a fresh epoch, on
ADR 0033's ordinary takeover mechanics. The reason is stated there and it is
proportionality: one session's collaboration state is not grounds to end every
other session's, and the daemon-wide rows above are all components whose loss
leaves *nothing* working. `supervision_fault` is therefore gone from the class
set; a lease owner produces no daemon exit class at all.

That fresh five-second classification exchange is serving-state only and is
outside `T_orderly`. When the daemon owner consumes a stop and begins the
admission cut, it atomically marks every locally pending classification
stop-owned before sending the ref-tagged cut. Cut acceptance in the relay
atomically absorbs every matching in-progress classification into the earlier
`transport_cut_deadline_ms` instant; its old private timer and any queued
classification acknowledgement become prompt/cleanup-only. A classification
whose acknowledgement the daemon owner consumed and whose selected output it
completed before consuming the stop remains an ordinary pre-cut result.
Otherwise, ordinary owner-loss notification stops: no fresh per-owner deadline
starts and no `control_owner_lost` form is emitted. The daemon and relay retain
every dead-owner and mirror-pop fact, batch them into the current or next
already scheduled cut, freeze, quiescing or teardown barrier, and resolve them
under that phase's existing absolute deadline. Permit dispositions become the
stop-owned `shutdown_cancelled`, `shutdown_admitted` or retained real result
that the barrier already defines; the later `daemon.stopping`/EOF path owns
client notification. Simultaneous owner deaths therefore consume one shared
stop clock instead of serial five-second clocks.

The connection registry makes that target discoverable after owner-local lease
state is gone. It carries a routing mirror, not authority, and the lease owner
never calls it directly. Mirror publication uses an asynchronous exact-operation
protocol so the daemon owner stays responsive. The lease owner sends
`{mirror, op_ref, owner_pid/incarnation, action, exact_row, from}`, enters one
`mirror_pending` state and admits no later transition. The daemon owner records
that operation, registry incarnation and absolute deadline before sending
`apply_mirror` to the registry. The registry applies the exact-incarnation
install or clear and acks the daemon owner; only after validating that ack does
the daemon remove pending state and reply to the lease owner. Exact owner
incarnation and epoch keep an old clear from erasing a successor; stale acks are
cleanup-only. The effective absolute deadline is `accepted_at + 5_000 ms` or,
once draining, the earlier shared admission deadline; no event restarts that
clock. Every apply acknowledgement and continuation rechecks that instant. An
ack queued ahead of its timer but consumed after the instant is cleanup-only:
the daemon atomically latches `connections_lost`, notifies the sentinel, sends
untrappable `:kill` to the exact registry and enters fail-stop without awaiting
its reap or claiming mirror success. Its later linked `EXIT` is cleanup-only.
The timer only prompts the check.

A timeout does not kill a helper and pretend a delivered call vanished. There is
no helper or synchronous registry call. On deadline or registry loss, the daemon
atomically latches `connections_lost`, notifies the sentinel, sends untrappable
`:kill` to the exact registry incarnation and enters fail-stop without awaiting
its reap. Its later linked `EXIT` is cleanup-only; the dead daemon lifetime can
expose no queued apply as a live route. An
owner's mirror request precedes its later linked `EXIT` in signal order, so the
daemon defers that owner disposition until the operation acks or fatal teardown
wins. It then sends `pop_owner_mirror` through the same asynchronous deadline
protocol. The registry atomically removes only a row matching the dead owner
pid/incarnation and returns its exact holder route or absent. The daemon retains
that result, runs the exact `owner_lost_classified` exchange above and closes a
returned controller only after the matching classification acknowledgement; an
absent result still completes that exchange with `none`. Successor start and
install wait for the pop, classification acknowledgement and terminal holder
close or correlated-refusal settlement. A stale or duplicate pop is idempotent
and cannot erase a successor. The teardown freeze
likewise waits until every pending mirror is terminal or the registry is reaped.
Forced cuts suspend the registry while independent Store loss and `SIGTERM` are
consumed; kill it during install; queue an ordinary-serving ack ahead of its
timer but consume it after the five-second instant; order owner exit before
request, after request before ack and after ack; deliver a stale late ack; force
present, absent and duplicate exact pops; force relay `DOWN` and pop result in
both orders; cross a pending serving classification with the admission cut in
both orders; and race an old clear or pop with a successor. They prove one
classification/outcome, no blocked daemon-owner loop, no stale row and no
post-freeze install.

The linked-component rows are named rather than numbered, because a number is a fact about the
start order and this table is a fact about which pid died; the two drifted
apart in an earlier revision and the numbers are gone for that reason. There
is one row per linked process **except the Store's, which has two** — the
capacity refusal being distinguished from every other reason, as the table
above says — and the transfers row exists only in a daemon
that has one. `drain_failed` is not a linked-process death and is therefore the
one running-phase row outside that count.

**`registry_lost`, `custody_lost` and `capability_lost` are fail-stop like
every other row, and that follows from ADR 0034 rather than adding to it.**
That ADR makes a dead registry answer `:unavailable` for every later
resolution *until the host recomposes*, and makes a sender that cannot
confirm its trace exclusion refuse rather than resolve; in a daemon,
recomposing is restarting the process. A daemon that
kept running would serve a runtime whose every model invocation refuses for a
reason no client can fix, which is exactly the shape the fail-stop rule
exists for.

**`owner_lost` is the sentinel's row.** The command process's monitor selects it
only when the unlinked owner dies before sending a matching fatal latch. No
linked component produces it, owner death needs no signal, and a prior latch
keeps its first class and status.

The wire column matters because ADR 0032's `daemon.stopping` `reason` admits
`operator_stop`, `store_lost`, `store_capacity_exceeded` and `fatal:<class>`,
so every class above that a running daemon can reach has a reason a client can
receive — *if* there is still a socket and the write succeeds. The startup
classes have none, deliberately: no socket exists when they occur, so no
client is holding one. `connections_lost` cannot be delivered because the
process and interface that own the recipients are gone. `listener_lost` can
be delivered because the registry and accepted connections remain.
`owner_lost` has no live owner to write a record, so those clients learn by
EOF.

**The daemon's own log is bounded, best-effort and redacted by the rules that
already exist.** Everything the daemon attempts on `stderr` — refusals,
warnings, the fatal reason — is a bounded non-secret line under ADR 0029's discipline, and
carries no credential, no token, no model content, no tool argument or result,
and no artifact bytes, exactly as ADR 0030's metadata rule already forbids for
a trace or a telemetry span. Nothing here is a new logging plane: the daemon
has no diagnostic surface of its own beyond these lines and the records it
already sends on the wire, and the fatal-class map above is the whole
vocabulary of what a **fatal** exit may say. The unique status remains the
authoritative fatal result if stderr is blocked. Routine refusals and warnings
use at most one unlinked monitored helper. While it is alive the owner queues
no second line and retains only one boolean, `routine_diagnostic_dropped`; any
additional attempt sets that bit. After an exact successful helper result and
`DOWN`, the next eligible line includes
`prior_routine_diagnostic_dropped:true` and clears the bit only if that line
also succeeds. Helper failure keeps the bit set. A blocked IO device therefore
costs one helper and one bit, never a queue, and never blocks admission,
shutdown or the fatal watchdog. An **orderly** stop attempts
exactly one line and no class: a census naming `drain_id`, `budget_ms`,
`fence_budget_ms`, the three
  counts quiesce returned and, for every session it left
  `{:unknown, :abort, head}` or `{:unknown, :fence, head}`, the stage and that
  session's id with the `owner_epoch` and `journal_version` core read
— the values a successor compares against, and the only part of the census
that is recovery data rather than a count. After successful quiesce, the owner
starts an unlinked, monitored census helper and includes it in the existing
shared `teardown_ms` pending set. The helper may complete at any point while
teardown proceeds; it is killed at the shared deadline and is never awaited
after the Store phase. Thus a healthy stderr receives exactly one census line,
while a blocked or broken stderr may receive none and cannot delay connection
teardown, marker release or exit `0`. A quiesce-helper crash is instead
`drain_failed`: the sentinel attempts the bounded fatal line, the daemon claims
no census and exits with status `108`.

**Reverse cleanup.** Startup happens inside the owner, so a failure at any
step unwinds what that step and its predecessors did, in reverse — and
"predecessors" means **every process the startup started**, not the three an
earlier revision named. If startup reached them, cleanup first stops and awaits
the listener, then the connection registry, then the admission relay. A bound
socket is **closed, and its path left in place** — reverse cleanup unlinks
nothing, for the same reason no shutdown path does — a `daemon/` subdirectory
this start created is removed **when it is empty**, by the matrix below — no
lease owner can exist yet, since the parked listener has accepted no socket and
therefore no client request has reached a lease operation. A kernel-backlog
connection is closed when the listening socket closes and has no daemon pid or
registry state to unwind — and **every pid the composition
function returned is stopped in reverse start order** — runtime, executor,
workspace lease, transfers where it exists — then the tracing capability,
  custody and credential registry, and, **where acquisition returned a Store
  pid**, the Store last, so its `terminate/2` invokes the best-effort marker
  release. A
  `WriterLock.acquire/3` error after exclusive marker creation returns no Store
  pid or lock handle; cleanup cannot stop or release what it was never given.
  Once every started component is confirmed gone, cleanup uses the same
  unlinked monitored placement-release helper and fixed five-second deadline to
  attempt the acquisition-specific handle's release. If cleanup cannot prove
  the components gone, or that helper expires, the non-zero halt leaves the lock
  for stale-owner recovery. An already-latched startup class remains the exit
  class; a placement failure with no earlier class is `placement_lock_failed`.

Each of those stops is the same call and the same discipline as a shutdown
stop: a monitored helper running `GenServer.stop(pid, :normal, …)`, the owner
waiting on its own link against **one shared teardown deadline** and killing
on expiry, and — where a Store pid exists — **the same fixed 30 s phase** the orderly
path gives it, for the same reason: this is the stop that attempts marker release,
and a failed start that killed the Store mid-release would leave exactly the
stale marker it is trying not to leave. Startup introduces no second teardown
mechanism; it reuses the one the shutdown sequence defines, against the pid
map it already holds.

The owner does this in its own start path rather than leaving it to a crash,
because a crashing owner would take the links down without attempting release of a marker
whose Store pid it received or removing the directory it made. A daemon that
refuses after successful Store acquisition **runs the marker-release callback on
the ordinary path** unless that stop times out. Healthy evidence proves actual
absence; callback completion alone does not. A refusal from inside marker
acquisition has no such pid and follows the separate residual below.

**There are three ways to reach the two marker residual shapes, all inherited
from the unchanged adapter.** First, a returned Store pid that does not stop
within its fixed 30-second phase is killed and leaves its complete marker for
verified stale-writer recovery. Second, a completed `terminate/2` may still
leave the complete marker because `WriterLock.release/1` ignores removal and
parent-sync errors. Third, `WriterLock.write_marker/2` can exclusively create
the marker and then
fail its write, file sync, close or parent-directory sync before `Local.init/1`
returns a Store pid or lock handle (`writer_lock.ex:200-225`,
`local.ex:152-168`). A complete residual is again recoverable after its recorded
holder is dead. An empty or partial residual is undecodable and automatic
recovery correctly refuses `store_writer_unverifiable`; the operator runbook
requires inspection and explicit removal only after proving no holder is live.
The daemon normalizes the acquisition error to
`store_writer_acquisition_failed`, retains placement through cleanup, touches
no socket and claims neither release nor corruption of session truth.

**What a failed start leaves on disk is one matrix, because three passages
gave three answers.** One said a bound socket is closed with its path left in
place while the `daemon/` subdirectory is removed — which cannot both happen,
a directory holding a socket file not being empty. Two witnesses then asserted
"no socket file exists afterwards" while the no-unlink witness asserted the
opposite for the same failure. The rule is the bind:

| Where the start failed | Socket pathname | `daemon/` subdirectory | Store writer marker |
| --- | --- | --- | --- |
| **Before exclusive marker creation** — path resolution, signal install, registry, custody, capability, or an acquisition error before create | None | Not yet created by this start | None created by this attempt |
| **Inside marker acquisition after exclusive create, before a Store pid is returned** | None | Not yet created by this start | May remain complete and stale-recoverable, or empty/partial and therefore `store_writer_unverifiable`; no reverse-cleanup pid exists |
| **After a Store pid is returned but before a successful bind** — later composition, index, relay/registry, subdirectory/socket validation, or an unsuccessful bind/listen | None created by this attempt; any unsafe pre-existing selected path is preserved | Removed **only if this start created it and it is empty**; a pre-existing or non-empty directory is left as found | Completed Store `terminate/2` invokes best-effort release. The healthy witness proves absence; an expired stop or ignored removal/sync error may leave the complete marker for stale recovery |
| **After a successful bind** — permission read-back, parked-listener start, readiness write, or any component dying during those | Left in place, closed but not unlinked | Left in place because it holds that pathname | The same best-effort completed-stop attempt, healthy absence witness and complete-residual recovery |

Both halves follow from one rule already stated and one plain fact: **no
predecessor path ever unlinks**, so a bound socket's pathname survives a
failed start exactly as it survives a stop; and a directory holding a file
cannot be removed, so the subdirectory removal is conditional on there being
nothing in it. A daemon that refuses to start may therefore leave a socket
pathname and may leave one of the marker residuals above. The next verified
placement-lock and marker holder removes only a stale path proved by the
no-follow owner-and-socket-kind check before binding;
marker recovery remains the adapter's separate, liveness-checked operation.

**Witnesses.** Most run a real daemon operating-system process; a few read
state no surface exposes and run **in-VM**, in the same VM as the daemon or
the runtime they are about. Each is labelled.

**A note on how these are written, added after a review found three that
could not be checked.** Every witness here names the **surface** it reads, the
**two answers** that must differ on it, and — where the surface is new — the
**change that creates it**. A case asserting "core holds N" without saying
where N is read is not a case anybody can write; nor is one whose difference
depends on a code path that does not exist. **Five** inspection surfaces are new
work across the plan's six core changes. Core change 6 changes managed process
lifetime and is read through existing supervisor-child lists and process
monitors, so it adds no sixth product surface. Each new surface is named where
it is used:

| Surface | Created by | Read by |
| --- | --- | --- |
| The dispatcher's release on holder `DOWN`; `Control.invalidate_attachments/3` and `carried_attachment/2` at succession; the per-holder attachment set and monitor state that both owners keep; the transfers released with each attachment; the acknowledged succession-invalidation transaction and holder notification; and `Control`'s repetition state | Core change 1 | The concurrent-attachment cases, the ADR 0028 transfer case, the scoped-replacement case, the attach connection-loss case, the active-resume succession case without holder `DOWN`, and the non-holder command case that resolves by `attachment_id` |
| The existence query's four domain results plus its outer runtime failure, and the create-history query's five domain results plus the same outer failure | Core change 2 | `session_existence_query_test.exs` and `create_history_query_test.exs`, one case per result and failure, including a malformed adapter answer normalized through the real Store facade, exact `Control` loss, and Outcome 4's row |
| `Control`'s excluded-pid/MFA set and exact Trace monitor/weak session identity; Trace's process-owned private ETS handle table, handle-free callback state and defensive `format_status/1`; plus `Entry`'s redaction of a keyword pair under its own key | Core change 3 | The trace-exclusion, private-table access, complete forced-crash, tracer-replacement and differing render-pair cases |
| `quiesce/1`'s three lists, `budget_ms`, `fence_budget_ms`, `drain_id` and the per-session `fences` map | Core change 4 | The drain cases, the fence cases and the stop line |
| `disposition` and `control_entry`, on `create_session_detailed/3` and `resume_session_detailed/3` | Core change 5 | The create and resume connection-loss cases; exact-Control loss before processing and after child start but before reply, both of which return outer `runtime_unavailable` with no fabricated metadata; and the case asserting `create_session/3`'s own return is byte-identical to today's |
Everything read outside those five exists today — the journal, a supervisor's
children, a pid's liveness, a socket's EOF, or the daemon's own `stderr`.

- **Idle shutdown.** A daemon with sessions activated and no work in flight
  receives `SIGTERM`, writes nothing further to `stdout`, closes every
  connection with the stop reason, leaves the socket pathname for the next
  marker holder, proves the marker path absent after the Store's best-effort
  release attempt, and exits `0`; the foreground server then opens the same root
  immediately. Those observations, rather than callback completion, prove
  healthy release. The case also asserts the
  negative that the `stopping` field exists for: **no fatal class is recorded
  at any point during the stop**, and `stderr` carries **nothing but the one
  census line** — `drain_id`, `budget_ms`, `fence_budget_ms`, three counts and no unknown-fence
  heads, an idle daemon having none — **with no fatal
  class in it**. Stopping every linked process deliberately produces an exit
  from each, and every one of them must be consumed rather than classified.
  (Real process.)
- **A real failure during an orderly stop is still classified, and the
  sequence still finishes.** The Store is made to fail while the listener is
  being stopped. The case asserts three things, because the second and third
  are what an earlier draft would have failed: the daemon exits with
  `store_lost` rather than `operator_stop`, since the Store is not the
  component named in `stopping` and the operator is owed the reason it
  actually went down for; **the sequence runs to its end**, reaching the
  Store's own step — where the helper's stop meets `noproc` without reaching
  the owner, while the owner consumes the already-queued Store exit — then
  leaving the socket pathname; and the class reaches `stderr` with a non-zero exit
  rather than the owner dying of `noproc` with no status, no message and a
  socket file left behind. A second daemon opens the same root immediately
  afterwards, which is what proves the path completed.
- **The fence is a Store fence, proved against a transaction in flight.**
  This is the case a terminated coordinator alone would fail. A session's
  terminal transaction is **paused inside the Store, before linearization**,
  using core's controllable store, `Loopex.M1RuntimeTestStore`, whose
  `hold_next_record_before_linearization/3` keeps the caller pending outside
  the store process for exactly this order
  (`apps/loopex/test/support/m1_runtime_helper.exs:40-46`); the shipped
  adapter's `checkpoint(state.fault_probe, transition, :before_linearization)`
  at `local.ex:252` is the same seam, but core's tree cannot reach that
  module. With it paused, the coordinator is killed, so the caller of
  that transaction is dead while the transaction itself is still pending.
  Quiesce then runs its deadline path: it terminates the coordinator, waits
  for the `DOWN`, and commits the `advance_owner` fence for that session. The
  paused transaction is released. The case asserts it is **refused
  `:stale_owner_epoch`**, that `fences[session_id]` is **`:committed`**, that
  the journal contains no terminal for it, and
  that the daemon's `unsettled` report was therefore true when it was read.

  A variant releases the paused transaction **before** the fence commits and
  asserts the other half: it commits, it is observed, the session's
  durable state includes it, and the fence that then loses the race is
  reported **`:superseded`** rather than as an error. Both outcomes are
  decided; neither is a race the plan has to argue about.

  A third variant is the one the result-totality repair added: the paused
  transaction is released so that it commits **under the same epoch** the
  fence read, so the fence meets **`:stale_journal_version`** rather than
  `:stale_owner_epoch`. The case asserts the same `:superseded` disposition
  and that the drain does not treat it as an unexplained failure — the
  assertion a design handling only the epoch refusal would fail.

  A fourth proves restart recovery without a hidden carrier: the fence answers
  `commit_unknown`, and the daemon is killed immediately before the drain result
  or stop line can be emitted. A fresh process receives only the root and normal
  configuration. From current epoch `E` it queries the current fence ID and, on
  absence only, the predecessor ID. Forced branches cover a committed
  predecessor fence, current-ID `:stale_journal_version`, current-ID
  `:stale_owner_epoch`, both IDs absent, current-ID committed while the head is
  still `E` as an inconsistent fail-closed result, and Store unavailability.
  Only a resolved exact ID or both-absent result reaches ordinary fresh owner
  succession; no command is admitted before that succession commits. The test
  supplies no recorded drain head, fence transaction bytes or stop-line value
  to the replacement process, and correct core never writes a conflicting
  binding under the single-use fence namespace.

  The abort unknown has its own four live-drain outcomes under the deterministic
  `drain_abort` identity: terminal committed reloads exactly one abort before
  the fence; terminal non-commit proceeds to the fence; `:absent` races the
  fence CAS in both orders and makes exactly one side stale; and unavailable
  returns `{:unknown, :abort, head}` and proposes no fence. Fresh-process cases
  then kill the daemon after abort `commit_unknown` and before fencing or stop
  output. They force a same-epoch stale-journal terminal, a predecessor-epoch
  committed abort after a fence advanced the head, both current and predecessor
  IDs absent, unavailable and malformed status, and an attempted second abort
  binding at the same epoch after journal movement. The last refuses as a
  conflict and proves the terminal gate plus mandatory owner succession are
  load-bearing. Exact-ID discovery and ordinary fresh succession both complete
  before any command admission.
- **The drain is globally durable-first, not per session.** Two sessions are
  active, each with a cancellable effect. The case asserts that **both**
  aborts are committed to the journal **before either** cleanup begins —
  read from the journal's order, not from timing — which a per-session
  admit-then-cancel loop would fail, since `begin_admitted_cleanup/1` starts
  cleanup on the commit reply path. A second assertion covers the empty case:
  a daemon with no active session drains with a budget of `0` and does not
  wait.
- **An `:active` entry whose coordinator is already dead is reported, not
  drained.** A session's coordinator is killed and the daemon is stopped
  before `Control`'s entry is replaced. The case asserts the session appears
  in quiesce's **`absent`** list rather than in `settled` or `unsettled`, that
  no abort was admitted for it, and that it was **fenced** all the same — the
  `advance_owner` commits — because a dead coordinator's in-flight
  transaction is exactly what the fence is for.
- **A component that fails while it is being stopped.** The transfers owner
  is made to raise in its own `terminate/2` during an orderly stop, so its
  stop returns that reason rather than `:normal` and the two-clause catch
  would have killed the owner. The case asserts the sequence completes — the
  Store still stopped — and that the exit class is
  `transfers_lost` rather than `operator_stop`, because the component died of
  its own reason and not because the owner asked.
- **In-flight shutdown, both halves of it.** Two cases, because the drain has
  two outcomes and proving one would hide the other. Both assert the durable
  admission first: a `command_admitted` record with
  `"command_type" => "abort"` appears for the active session **before** any
  cancellation, because ADR 0023 admits no cancellation that was not
  commanded — and both assert it is **the record a client's own
  `session.abort` writes**, field for field, with no shutdown-specific field
  on it. Both also assert its `command_id` equals the deterministic
  `drain_abort` ID derived from that session ID and its pre-admission owner
  epoch, with journal version retained only in the immutable Store binding,
  and that two sessions drained by the same stop
  derive different IDs. The operator learns the cause from `daemon.stopping` and from
  `stderr`, not from the journal.

  *It settles.* A daemon with a dispatched tool effect that **can** be
  cancelled inside its session's own grace receives `SIGTERM`. The case
  asserts the effect settles during `quiesce/1`, that its session is in the
  returned `settled` list, that the journal carries its ordinary terminal fact
  — `cancelled`, which is now a true statement about work that was truly
  cancelled — and that the `daemon.stopping` record is written **after** the
  drain rather than before it.

  **And it asserts what `settled` was read from**, which is the half an
  earlier revision left unstated: the coordinator's
  `{:session_status, owner}` reply, with the aborted run in neither
  `active_run_id` nor `pending_work_ids` at the moment the drain classified
  it. A **third** case is the one that separates the definition from the
  timing: a session whose cancellation completes but whose **terminal commit
  is held** past the budget is asserted **`unsettled`**, terminated and
  fenced, with the journal carrying no terminal for that run — where the old
  definition, "whether its cancellation finished", would have called it
  settled and left termination free to kill the write it still owed.

  *It does not.* A daemon with an effect held past the drain budget and an
  unresolved mutation receives `SIGTERM`. The case asserts the session is in
  the `unsettled` list; that its coordinator is **gone before `quiesce/1`
  returned**, read **in-VM** as that coordinator's pid being dead at the
  instant the daemon reports it — `Process.alive?` on a pid the case holds,
  not a wire field; and then the negative
  that matters: **no terminal is claimed for the work that did not settle** —
  no `cancelled`, no `outcome_unknown` for it. The ambiguous mutation stays
  `commit_unknown`, each client is sent the stop reason on a transport that
  accepts it and sees the close either way, and the exit is still `0`.
  Activating that session again afterwards resolves the transaction to exactly
  one outcome through the existing reconciliation.

  The journal after this path is **not** byte-identical to an abrupt death at
  the same instant, and the case asserts the difference rather than the old
  equality: for each active writer-eligible session it holds exactly **two** more records — the
  admitted abort, and the `advance_owner` that fences it. An earlier revision
  said one, from the revision in which only unsettled sessions were fenced.
  What remains identical is what the abrupt-death case actually needs:
  the unresolved transaction and the outcome reconciliation produces.

  **A settled session's straggler is the case this fence exists for**, and it
  has its own assertion here: a transaction for a session the drain reported
  `settled` is held inside the Store and released during the **Store stop**, while
  the Store is still alive and the runtime has already been killed. It is
  asserted refused `:stale_owner_epoch` and absent from the journal. Before
  every writer-eligible session was fenced, that commit would have landed after the
  census that called its session settled.

  **And the rollback assertion sits here**, because this is the path that
  writes the extra records: after the drain, the **released foreground
  surface** opens that same root on the same adapter, replays it, and resumes
  the session — no migration, no recovery step, no version refusal. That is
  the proof that a drained root is still an ordinary root, and it is asserted
  rather than argued.
- **Store-loss fail-stop.** The Store is made to terminate under a live
  listener. The case asserts the daemon observed it, closed the listener and
  every connection with `store_lost`, left the socket pathname in place, and exited non-zero
  with that class on `stderr` — and that it did **not** attempt the ordered
  sequence, because there is no Store left to stop. Its `terminate/2` attempts
  marker release. A healthy branch proves absence; an injected unlink or sync
  failure leaves a complete residual for the same stale-writer recovery. A contender in a separate VM and a second acquisition in the same
  VM, each started before the predecessor halts while its Runtime Control is
  still alive, refuse `placement_active` before opening the Store or touching
  the socket; after the halt, the placement lock is stale, the next daemon
  recovers it and starts.
  The capacity variant
  reports `store_capacity_exceeded` instead, and the case asserts the executor
  was stopped before the halt, and that its stop *returned* rather than timing
  out into a kill. It does **not** assert that no operating-system child is
  left behind: that is the residual this plan states, since the cleanup runs
  in workers the daemon cannot wait for.
  Two bound witnesses repeat Store loss with the relay suspended and with the
  connection registry suspended. The first proves the direct relay kill admits
  and dispatches nothing after the fatal cut; the second receives no stop
  record but reaches EOF. Neither owner performs a synchronous call to the held
  process, and both VMs halt within the Store-loss path's one 5-second clock.
- **One class per linked component of the fixed set.** Each is
  killed in turn, in its own case, and the daemon is asserted to exit with
  that component's class, to send that component's `fatal:<class>` on the wire
  where a socket still exists, and — for the classes where the Store is
  still alive — on the healthy release branch **to prove marker absence** by the
  next daemon opening that root without recovery; paired removal/sync failures
  leave a complete residual and prove only verified stale-writer recovery; ten non-Store components in a daemon with
  transfers enabled and nine without — `runtime_lost`, `transfers_lost`,
  `workspace_lease_lost`, `executor_lost`, `registry_lost`, `custody_lost`,
  `capability_lost`, `relay_lost`, `connections_lost`, `listener_lost`,
  beside the two store
  classes — with `connections_lost`, the one that can reach **no** client,
  asserted to send nothing, leave an accepted socket open through the executor
  and Store phases, close it by EOF at `System.halt/1` within the 35-second
  fail-stop bound, and still exit with its class; `listener_lost`
  is injected after a completed controlling-process handoff and instead uses
  the surviving registry and accepted socket for one bounded attempt before
  close. The case proves the connection remains alive after the listener dies;
  two companion handoff cases force the connection to die after ownership
  transfer but before registry promotion and force the listener to die in the
  same window, proving in each case that abort first retains an occupied
  `aborting` row and releases the socket and slot only after close
  acknowledgement or the exact connection `DOWN`. A suspended post-transfer
  connection keeps that slot charged and prevents a 513th process or socket
  until it is reaped. A paired-death cut kills listener and
  connection before either abort can be observed; the daemon owner's listener
  `EXIT` path calls `abort_provisional_for(listener_incarnation)` and proves no
  slot leaks. A fourth cut completes registry promotion, including its permanent
  monitor, before listener death and proves the connection survives and the
  listener's temporary monitor is gone. The set is closed for the
  fixed set, so one of those dying without a class is a failing case rather
  than a silent `:shutdown`. A lease owner is deliberately not in this case:
  its own witness is below, and it asserts the daemon **keeps running**. A
  separate `drain_failed` case forces `quiesce/1` to return
  `{:error, :runtime_unavailable}`, asserts no census or fence result is
  claimed, one best-effort `fatal:drain_failed` is attempted, and the same
  crash-equivalent teardown reaches the Store release attempt and then either
  proves healthy absence or exercises the complete-residual recovery branch.
- **No daemon ever unlinks, and a successor's socket survives.** Three cases,
  one per exit path, each asserting the **absence** of an unlink rather than
  its correctness. After an **orderly stop**, the pathname is still on disk
  and `connect` to it fails as refused rather than hanging; the next daemon
  proves its kind and owner, removes it, binds and serves. After a
  **store-loss fail-stop**, the same.
  After a **failed start at or after the bind** — the marker acquired and the
  socket bound, then the permission read-back refused — the same again, with
  no live marker holder. Its healthy branch proves marker absence; the injected
  release-failure branch uses verified residual recovery. The index-bound failure is **not** this case and is asserted
  the other way in the reverse-cleanup witness, because it happens before the
  bind and there is no pathname to leave.

  The race the old design had is then run directly on the orderly path: the
  first daemon completes runtime teardown, its deliberate Store stop and the
  exact placement-release helper result plus normal `DOWN`; direct probes prove
  both exclusion paths absent, but the daemon is held immediately before its
  final halt. A second daemon acquires the placement lock and marker, proves
  the stale path's kind and owner, removes it, binds and
  prints readiness; the first daemon then finishes. The case asserts the
  second daemon's socket is **still bound and still serving a client** — which
  a predecessor that unlinked under any precondition would have broken. The
  separate Store-loss witness does not reuse this cut: its self-stop attempts
  marker release immediately, while the placement lock remains held until the
  predecessor halts; a contender before that halt is refused at placement and
  never opens the Store or touches the socket.
- **Unsafe selected paths are preserved.** After both exclusions are held,
  separate starts place a regular file, a symbolic link and a special
  non-socket `:other` entry at the selected path; an injected metadata case
  reports a foreign uid, and separate seams make `lstat` and removal fail.
  Each returns `socket_permission_unverified`, preserves the exact path and
  target bytes, starts no bind or later component, emits no readiness, and
  reverse-cleans the Store and placement attempts. The positive stale-path case
  first asserts `File.lstat/1` returns `:other` with
  `mode &&& 0o170000 == 0o140000` and the uid retained from this start's
  placement owner handle, then proves only that path is removed and replaced
  by the serving socket. A replacement between `lstat` and `File.rm/1` is
  also forced and proves removal never follows the final component. These cases prevent a
  regular file or final-component symlink from being deleted while keeping
  ordinary restart possible.
- **Invalid path bytes stop before path handling.** Direct calls to the shared
  path-input API pass `<<0xFF>>` first as the selected root for startup and
  `prepare-index`, and then as startup's explicit socket with a valid root.
  The first two return `state_root_unusable`; the third returns
  `invalid_socket_path`. A startup using a default socket under the invalid
  root also returns the root error because no socket path is derived. Every
  case asserts that path normalization and filesystem calls were not reached
  and that no placement lock, Store access, socket operation or component
  start occurred.
- **A `--socket` path outside the root is refused.** A path in a directory
  that is otherwise perfectly valid — right owner, right mode — but outside
  the selected root's `daemon/` directory exits `invalid_socket_path` with no
  marker taken, no socket bound and nothing left behind.
- **Signals, one case per signal per route and phase, and the route is what
  decides after handler installation.** Four post-handler cases send `INT`,
  `TERM`, `HUP` and `QUIT` **to the launcher**,
  `apps/loopex_cli/bin/loopex`, and each asserts the **orderly sequence** —
  because the launcher traps all four and forwards `kill -TERM`
  (`bin/loopex:60`), so through the shipped path all four mean stop. Four
  more send the same signals **to the escript process itself**: `TERM` asserts
  the orderly sequence; `HUP` asserts abrupt signal death with status `129`,
  no `daemon.stopping` record or drain, and marker, socket and placement
  residuals accepted only through verified recovery; `QUIT` asserts the
  process stays live with no stop record after handler installation, then a
  direct `TERM` runs the complete orderly sequence. That final step proves the
  ignored event did not remove the handler. Those outcomes make "the daemon
  installs on `SIGTERM` and nothing else" a checked claim rather than a
  preference. The direct-`SIGINT` case asserts only
  that the signal reaches the emulator break-handler boundary:
  `:os.set_signal/2` refuses `:sigint` (`interrupt.ex:13-17`), so the case makes
  no orderly-result claim and does not specify the handler's interactive
  behavior. Every case names which process it signals, which is the whole
  point of the pair. Five pre-handler cases hold the interactive root-resource
  prompt, send those four signals to the launcher and direct `TERM` to the
  child, and assert exact status `0`, no readiness, wire record,
  `daemon.stopping` record or lifecycle/fatal diagnostic, and no placement
  lock, Store, socket or component, while permitting the already-written
  project-resource prompt and the BEAM runtime's own shutdown notice. A
  fourteenth case asserts the install order at the exact
  post-handler, pre-placement-acquisition cut: a `SIGTERM` there ends a daemon
  that holds no placement lock or marker and has bound no socket, proved by a
  following daemon starting with nothing to recover.
- **`owner_lost`, by the monitor and not by a later signal.** The owner is
  killed while the daemon is otherwise healthy and **nothing else happens**:
  no signal is sent. The case asserts exact status `109` within a bounded time
  of the kill, which is the command process's monitor doing it; on healthy
  stderr it also sees the bare `owner_lost` class. A second case suspends the
  registered stderr IO process, kills the owner and proves status `109` without
  requiring a line. A third first latches another fatal class and then kills the
  owner, proving the first class's status wins rather than being replaced by
  `owner_lost`.

  **Two more cases straddle the marker, and they are what the `{:continue,
  :start}` ordering exists for.** The owner is killed **before** it acquires
  the marker and again **after** it has acquired it but before the socket is
  bound. Both assert the same two answers on the same two surfaces: the
  process exits with status `109` (and, where stderr is healthy, `owner_lost`), and a following daemon
  starts on that root — with nothing to recover in the first case, and with
  the stale marker its verified recovery reclaims in the second. A design that
  ran the sequence inside `init/1` fails the first of them outright, because
  `GenServer.start/3` has not returned yet and no monitor exists to fire. A
  third asserts the happens-before directly: the command process is made to
  delay its `:go`, and the case asserts the marker is **not** taken until the
  message is sent, which is what proves the monitor precedes the first
  irreversible acquisition rather than merely usually preceding it.
- **Startup is interruptible, including inside the composition call.** A
  `SIGTERM` is delivered mid-startup at the step before the marker is taken,
  again at the step before the socket is bound, and again **between two edges
  inside the composition function** — which the interrupt checkpoint is what
  makes observable. That third case asserts the function returns
  `{:error, reason, started}` naming every edge it had started, and that
  reverse cleanup stops exactly those. Each case asserts **no readiness line is printed**, that no marker is
  held, that what is left on disk matches the startup-failure matrix for where
  it stopped — no pathname for the two pre-bind cases — and that a following
  daemon starts cleanly with nothing to recover. All three signal cuts assert
  status `0`, no readiness or wire record and no fatal diagnostic after the
  exact partial inventory has been reverse-cleaned; any injected cleanup
  failure instead asserts its own non-zero class. A third kills the Store immediately
  after the composition call returns and asserts the start aborts into reverse
  cleanup rather than binding a socket and announcing readiness on top of a
  dead component. Three further cuts fail after the admission relay, after the
  connection registry, and after the listener has started. Each samples the
  exact startup pid inventory, observes listener, connection registry and relay
  stop in that reverse order before runtime and the composition edges, and
  proves every process reaches `DOWN` under the one shared teardown deadline.
  The listener cut also proves the bound socket is closed while its pathname is
  left for the next verified placement-lock and marker holder.
  The final startup cut drives the lifecycle sentinel's single arbitration.
  Completed readiness success and `SIGTERM` are consumed in both orders: stop
  first keeps the gate parked, creates no connection or wire record and exits
  `0` after bounded reverse cleanup even when the line is already visible;
  release authorization first makes the sentinel send exact `begin_accept` and
  the later signal run the full orderly sequence. Readiness refusal and expiry
  are each forced on both sides of stop too. The same matrix forces the owner's
  component-fatal notice on both sides of helper success and deadline. Fatal
  first retains its component class, readiness failure first retains
  `readiness_write_failed`, and every later candidate is cleanup-only without
  opening the gate. A separate same-sender case proves an owner fatal notice
  sent before release authorization reaches the sentinel first.
  Six startup-class families are then forced at their earliest and latest
  partial-state cuts: signal-handler installation; registry/custody/capability
  start; a table forcing each of `error`, `throw` and `exit` from both the
  interrupt checkpoint and an edge starter after the Store has started, each
  returning its tagged class and exact partial map; relay or
  connection-registry start; socket create/bind/listen or listener
  start; and readiness output after the listener has parked but before its
  first accept is released. In the readiness case a raw client completes
  `connect` into the kernel backlog before the forced write failure; it then
  observes close, while the case proves no server connection pid, registry row,
  relay origin, lease owner, attachment, core call or journal byte existed.
  Each case asserts the exact
  normalized class on `stderr`, no raw lower-level term, no readiness record,
  reverse cleanup of precisely the acquired pid inventory, the bounded
  placement-release attempt only after Store and Control are gone, and the residue matrix's opposite
  pathname answers before versus after successful bind. The index group also
  forces `session_index_write_failed` from an unremovable fixed temporary and
  proves the offline command stops Store before attempting placement release.
- **Blocked output never forges readiness or governs an exit.** With the
  registered stdout IO process suspended after the listener parks, a raw client
  completes `connect` into the kernel backlog. At the absolute five-second
  output deadline the daemon hard-halts with exact status `95`, emits no late
  readiness record, creates no connection or core state, and a successor
  reclaims the dead placement/marker and stale socket path before serving.
  Separately, suspended stderr is given a burst of routine index and directory
  warnings: at most one routine helper exists, the owner retains only the
  dropped bit, and unaffected requests continue. After stderr resumes, the
  next successful eligible line carries
  `prior_routine_diagnostic_dropped:true`. Re-suspending it and killing the
  runtime yields exact `runtime_lost` status `104` by the 35-second watchdog
  without requiring a line; an orderly stop under the same blockage still
  stops the Store, exits `0`, and permits a successor to open the root.
- **A lease owner's death is session-scoped, and the relay is what makes it
  safe.** A session is activated, a controller acquires it and an observer
  attaches; that session's lease owner is killed **while one of its admissions
  is still inside core**. The case asserts the **daemon keeps running** — every
  other session still serves, and the process does not exit — that the
  controller's attachment closes with `control_owner_lost` while the observer
  stays attached and keeps receiving events, and that a following
  `session.acquire_control` returns an epoch **different** from the dead
  owner's.

  It also asserts the ordering the relay exists for: the replacement owner's
  grant **does not complete** while the old admission's ticket is
  outstanding, and the successor's first call reaches core only after that
  ticket settles. A variant lets the old admission finish first and asserts
  the grant proceeds without an observable wait, so the case cannot pass by
  blocking unconditionally. A late command from the dead controller's tenure
  is refused on the epoch check, as it would be for any released lease.
- **The relay's own death is daemon-fatal.** Killing it exits `relay_lost`
  with that `fatal:<class>` on the wire, like every other fixed component.
- **A relay task that dies without a result before orderly quiescing keeps its
  ticket and takes the daemon down.** The task performing a ticketed mutation is killed while the
  call is in flight. The case asserts the ticket is **still outstanding**,
  that no replacement owner is granted the session in the meantime, and that
  the daemon exits `relay_lost` — **not** that the mutation is treated as
  settled. It is the case that separates this design from the one that
  admitted a successor over a call it had lost track of.
- **Orderly quiescing seals unresolved tickets without inventing results.**
  After the relay has acknowledged `quiescing(drain_id)`, the case injects a
  hold in the relay task itself; the seal kills it and returns its exact ticket
  unresolved while operator stop succeeds rather than changing to
  `relay_lost`. In the paired fatal case the relay is proved to consume that
  task's no-result `DOWN` before it processes the quiescing transition. An attach held
  through quiesce is reaped by deferred `seal_after_quiesce`, after which holder
  `DOWN` and runtime teardown clear its transaction and charge. A fourth cut
  queues a real result before the task's `DOWN` and proves that result wins
  terminal disposition rather than being abandoned. The seal reports the exact
  real-result and unresolved ticket-ID sets and leaves no ticket row before the
  relay is stopped. A healthy maximum population of 16,384 promoted primary
  tasks is killed, reaped and terminalizes its waiters within the selected
  teardown bound. The paired maximum-population seal with the relay suspended
  reaches the shared deadline, where the owner atomically latches `relay_lost`,
  starts the fail-stop watchdog, sends untrappable `:kill`, awaits no
  out-of-phase reap and emits no operator-stop success. Repeated connection
  churn cannot add a seventeenth thousandth origin because dead incarnations
  remain charged closing slots until their rows retire.
- **Connection retirement never blocks the registry and never frees early.**
  One holder-cleanup worker is held inside `release_holder/2` while the registry
  continues to answer status and serve an unaffected slot. A 512-connection
  close starts the exact monitored workers together and obtains every
  acknowledgement inside the one phase bound rather than 512 serial waits.
  Worker crash selects `runtime_lost`; a late or stale acknowledgement cannot
  free or reuse its slot. A live attachment crosses quiesce, then step 3 invokes
  the cleanup-only operation through core's terminal gate, receives both owner
  acknowledgements and lets the registry retire normally.
- **Connection death reaps workers at every ownership cut.** A worker is killed
  before its readiness acknowledgement, after readiness but before permit claim
  or lease descriptor, while queued behind another mutation, and while blocked
  in an executing infinite read. The startup parent monitor covers only the
  first cut; relay connection `DOWN` kills and reaps every bound queued or
  executing worker in the others before closing-slot retirement. Each origin or
  permit reaches exactly `connection_lost` or pending-row cancellation, with no
  surviving worker, late dispatch or leaked charge.
- **A read never holds a takeover.** An observer sits on
  `Loopex.Runtime.next_event/1`, which blocks indefinitely by construction,
  while a controller dies and a new client takes over. The case asserts the
  takeover is **granted** — the read is not ticketed — and that the observer's
  own read still completes when an event arrives.
- **A ticket exists before its call does.** A lease owner is killed in the
  window between its holder check and its core call, injected at the
  acknowledgement boundary. Because the ticket is recorded by a synchronous
  call, the case asserts the relay holds a ticket for a mutation whose core
  call was never made, and that a replacement grant waits on it rather than
  proceeding into a gap.
- **Owners exist for dormant sessions, and the population is not the
  activation count.** These are **in-VM cases**, not socket cases, and the
  plan says so rather than implying a surface: the daemon's live-owner
  population and its activation count are internal, no wire method reports
  either, and **no DTO field is added to make them observable**. The cases run
  against the daemon's own processes in the same VM. A dormant session is
  acquired for recovery without being resumed: the case asserts an owner
  process exists for it, that the activation count the daemon holds is
  unchanged, and that after `session.release_control` — with no acquisition
  waiting and no ticket outstanding — the owner process **is gone**. A second
  case runs the `--take-over` sequence against a dormant session, which
  acquires, is refused at attach, releases and exits, and asserts the owner
  process is gone afterwards and no activation was spent.
- **The concurrent-owner cap is the attachment ceiling, not a new number** —
  again in-VM for the count, and on the wire for the refusal. A daemon driven
  to 512 concurrent lease owners refuses the next lease operation with
  `control_capacity_reached`, which **is** a wire code; the case asserts that
  refusal on the socket, and asserts in-VM that no five-hundred-and-thirteenth
  owner process was started and that releasing one lease lets the next
  acquisition through. At that same population, a retiring predecessor pauses
  after its retirement acknowledgement but before exit. A same-session acquire
  starts no successor until the daemon owner consumes exact predecessor `EXIT`,
  then atomically takes the freed slot as `starting_waiting_pop` without
  `control_capacity_reached`, remains unspawned until exact mirror pop, owner-loss classification
  acknowledgement and terminal holder-close or correlated-refusal settlement,
  and only then starts; its first grant additionally waits for every predecessor
  ticket and retirement completion; an unrelated 513th-session
  acquire remains refused. The live-process count never reaches 513 and two
  owners for one session are never alive together.
- **The credential processes are fatal like every other component.** The
  registry, the custody process and the tracing capability are each killed in
  their own case; the daemon exits `registry_lost`, `custody_lost` and
  `capability_lost` respectively, sends that
  `fatal:<class>` on the wire, and on the healthy branch proves marker absence
  by immediate reopen; a paired removal/sync failure proves the complete
  residual follows stale-writer recovery.
- **The stop timeout is exercised, not assumed.** A session is made to hold
  the runtime's teardown past the shared teardown deadline. The case asserts the
  owner **survives** rather than dying of whatever the stop did to the helper,
  latches `runtime_lost`, kills and reaps the runtime supervisor, still reaches
  the Store stop — the step a stop called inline would skip — and exits with
  exact status `104`, never `0`.
- **A Store stop that consumes its whole phase is fatal and leaves an explicit
  residual.** The Store's stop is suspended past its own 30-second deadline.
  The owner latches `store_lost`, kills the Store, retains the placement lock
  until its non-zero halt, and makes no claim that the marker was released or
  that a foreground opener can enter immediately. The successor then exercises
  ADR 0031's stale-marker rule: reclaim only when the recorded holder is proved
  dead, refuse when it is live or unverifiable. This is distinct from the
  healthy-Store orderly witness that exits `0` and reopens immediately.
- **Zero and one millisecond remaining on the teardown clock exercise the
  probe's real call path.** One case reaches the exact deadline and proves
  `remaining(deadline) == 0` takes the immediate timeout branch without a
  negative `after`, owner death or `owner_lost 109`. A second case is
  controlled so a component stop receives exactly
  `remaining(deadline) == 1`; its `terminate/2` is held for 50 ms. The helper
  raises `ErlangError`/`:timeout_value`, but the owner survives, reaches the
  absolute deadline, pre-latches that component's fatal class, kills and reaps
  it, continues to the Store phase and exits with the class's non-zero status.
  A paired zero-delay termination exits `:normal` before the deadline and
  permits orderly status `0`. This proves helper outcome never classifies the
  component and a deadline kill never becomes a false success.
- **Target exit before helper `DOWN` leaves no helper behind.** The target's
  `terminate/2` is held while the monitored stop helper is suspended; releasing
  the target queues its linked `EXIT` while the helper cannot finish. The owner
  consumes that target exit, kills and reaps the exact helper, and only then
  starts the next component's helper. The paired timeout-kill order does the
  same. Both cases assert one helper at a time, a return to baseline, and no
  stale helper `DOWN` in the next stop.
- **Cleanup grace 1 ms exercises the drain clock, not component teardown.** A
  daemon composed with `cleanup_grace_ms: 1` — the smallest admitted value,
  since `0` is refused with `cleanup_grace_invalid` — has active in-flight work
  so core derives and reports the actual root-specific drain bound. The case
  asserts component stops still receive the independent remaining teardown
  clock, the healthy Store receives its fixed 30-second phase, marker absence is
  observed, and the next daemon opens the root without stale recovery. It
  cannot pass by feeding the one-millisecond session value to
  `GenServer.stop/3`.

  Two more cases sit beside it. One composes `cleanup_grace_ms: 0` and asserts
  the daemon refuses at startup with `cleanup_grace_invalid`, holding no
  marker and binding no socket. One composes a grace **larger than 2^32-1
  milliseconds** — admitted, because core admits up to
  `18_446_744_073_709_551_615` — and asserts the daemon starts, stops, observes
  marker absence and reopens without recovery: the value reaches no `receive … after`
  unsliced, which is what the wait rule promises and what a direct `after`
  would have turned into an immediate `:timeout_value` exit.

  **That case requires an active session with work in flight, and without one
  it proves nothing.** The huge grace only ever reaches a wait through
  `budget_ms`, which is the maximum over the **drained** sessions of
  `cancellation_bounds(g_i).cli_backstop_ms` and is therefore **`0`** on a
  daemon with nothing active — the very value that cannot exercise slicing.
  So the case activates a session, leaves a dispatched effect in flight, and
  asserts the derived `budget_ms` actually exceeds 2^32-1 before asserting the
  stop completes.

  **And the slicing obligation is `quiesce/1`'s, not the daemon owner's.**
  The cancellation is the one part whose bound is unbounded by construction, and it is
  enforced inside core; every other wait is a fixed number far below the
  domain. The wait rule therefore binds core's own waits in the drain, and the
  daemon's owner inherits it as a
  rule it cannot violate rather than one it must remember. All of them run
  at both toolchain pairs, because both timeout results were observed at
  both.
- **A replayed create returns identity; placement-proved activation repairs.**
  Two cases on the create disposition. A session whose directory entry was
  never written is recovered by replaying `session.create` with the original
  `command_id`: the case asserts core answers `disposition: :no_activation`
  with `control_entry: :dormant`, that **no activation is charged**, that no
  coordinator starts, and that neither directory nor index is written from
  that answer or a bare `present`. The client then acquires, resumes with a
  fresh command under this daemon's placement, and only that successful
  activation repairs both publications. A daemon composed for the wrong
  placement gets `present` and then a resume mismatch and records nothing. A genuinely fresh create asserts
  `disposition: :activated`, one activation charged, and a live coordinator. A
  third asserts the pair for a session that is already active —
  `:no_activation` with `control_entry: :active` — and that the daemon repairs
  nothing. A fourth observes `:no_activation` with `control_entry: :acquiring`
  from a concurrent activation and likewise publishes nothing. Only the
  invocation returning `disposition: :activated` authorizes initial publication;
  the separate retry path is limited to placement this daemon already proved.
- **At the ceiling, history remains available and a fresh create is refused.**
  A daemon at its 64th activation presents an exact historical create and a
  genuinely fresh one. The read-only discriminator returns the committed
  session ID for the first, performs no directory/index publication, charges
  no activation and starts no coordinator. Because the activation ceiling
  prevents the placement-proving resume, that historical session remains
  dormant and unindexed until a later daemon lifetime can resume it. The
  discriminator returns `:absent` for the second,
  which is refused `activation_ceiling_reached` before the activating call.
  Separate cases cover option conflict, Store unavailability and an
  unrecognised core result without starting a coordinator.
- **The ceiling holds under concurrency, which counting afterwards would not.**
  A daemon at **63** activations receives two activation-capable calls at
  once — one create and one resume, on two connections. The case asserts
  **exactly one** succeeds, the other is refused `activation_ceiling_reached`,
  and that core started **one** coordinator, not two: the refusal happens
  before the second call is made, so there is no second coordinator to
  discover afterwards.

  **It is deterministic, not a race the case hopes to lose.** Both calls are
  held at the connection registry — the one process that takes reservations
  — and released in a fixed order, so the case asserts *which* one is refused
  rather than that one of them is. A witness that ran two calls and accepted
  either outcome would pass against a daemon that reserved after the call.
- **A duplicate create coalesces rather than reserving twice.** A create is
  held in flight and the identical `command_id` is re-presented on a second
  and third connection. The case asserts **one** reservation and one core task
  existed throughout, while each duplicate held a distinct sequenced
  `waiting(primary_ticket_id)` origin. Killing the second connection clears only
  its waiter and closing slot; the third receives the primary's result. Killing
  the primary connection keeps its task, reservation and closing slot through
  the real result. Repeated dead-waiter churn returns every relay and registry
  map to baseline, and the activation count rises by **one**.
  Two forced cuts repeat the case after the connection registry has recorded
  the create binding but before relay install, and after the relay has recorded
  the pending primary but before promotion. A duplicate arrives in each window.
  Cut and primary connection `DOWN` each leave one reservation and no task while
  the primary remains admissible, or exact terminal rollback with zero
  reservation, binding and waiters; neither promotes a waiter. Reply routes are
  checked against each exact origin.
- **A dormant resume at the ceiling is refused before the call.** A daemon at
  **64** receives `session.resume` for a dormant session. The case asserts the
  refusal, and asserts core was **not called** — proved by that session having
  no coordinator and no new journal record — which a post-call count would
  have failed by starting a sixty-fifth.
  A companion below the ceiling pauses after the connection registry binds the
  resume reservation but before relay promotion. Connection/worker death,
  lease-owner death and the admission deadline each terminalize the exact origin
  and asynchronously release that reservation; none starts a core task. Once
  promoted, only the detailed result converts or releases the same reference.
- **Two concurrent attaches at the attachment ceiling.** A daemon at 511
  attachments receives two `session.attach` calls at once. On the wire the
  case asserts exactly one result and one refusal — two answers that plainly
  differ. The count is **in-VM**: core exposes no attachment count, so the
  case reads **the dispatcher's `attachments` map** (`event_dispatcher.ex:154`,
  `:823`) in the same VM and asserts **512**, not 513. Saying "proved by core holding 512" without saying where
  that number is read would have been the same unobservable claim this round
  removed elsewhere.
- **One live replacement target can be borrowed only once.** At charge 512 the
  first replacement pauses after the connection registry records
  `borrow[target] = {request_binding, primary_ticket_id}` and before relay
  promotion. An exact repeat becomes a waiter on that primary; a distinct
  request for that target receives `attachment_conflict`, creates no second
  task, borrow or core transaction and leaves charge 512. The case asserts one
  daemon borrow, one Control pending target, one relay task and one core call.
  Primary pre-promotion connection death and admission cut terminalize the
  primary and waiter and release the borrow without promoting the waiter.
  Replacements of two
  different live targets may proceed together while the capacity equation
  remains true. Holder `DOWN` and each terminal path release every borrow once.
- **Every branch releases or converts its reservation, and the connection-loss
  cases are written so the two outcomes can differ.** One case per row: a
  fresh create, a replayed create against an active and a dormant session, a
  fresh resume, a replayed resume, a refusal, and then the three
  connection-loss rows, each constructed so that a resolution which could not
  discriminate would fail. Two more sit beside them: a resume for a session
  **already in the activation set** at the ceiling, asserted to **succeed**
  with no reservation taken, since it adds no activation; and two different
  resume commands for one dormant session, asserted to hold two reservations
  under their two `(command_id, session_id)` keys rather than colliding on one:

  *Resume, connection lost in flight, two sub-cases.* One where the original resume **did**
  activate the session and one where it **did not** — the same session ID, the
  same query answer `present` in both. The case asserts the daemon converts in
  the first and releases in the second, which it can only do from the replayed
  result's `disposition` and `control_entry`. A resolution by existence query
  would give the same answer to both and is thereby excluded.

  *Create, connection lost in flight.* The replay is asserted **in-VM** to start no
  coordinator — no new pid under core's session supervisor — and to charge no
  second slot, and the slot count afterwards distinguishes a fresh
  original from a replayed one.

  *Attach, connection lost in flight.* Two surfaces, and they differ in the two cases. On the
  wire, the client's connection is asserted **closed** — an EOF a test can
  observe — where a connection whose attach answered stays open. In-VM, the
  dispatcher's `attachments` map (`event_dispatcher.ex:154`, `:823`), read
  in-VM, is asserted to lose that entry **after the connection process
  exits**, and the daemon's reservation count to be back where it
  started. The code path that produces that drop is core change 1's monitor,
  which the inventory names as new work; a core witness in
  `apps/loopex/test/concurrent_attachments_test.exs` proves the monitor
  itself, and this case proves the daemon rides it. Nothing reads an
  attachment count from core's *public* surface, because none exists there.

  Each case asserts the daemon's remaining slot count **in-VM**, reading the
  reservation state directly rather than through any wire method — no DTO
  field exposes it, and none is added — so a branch that leaked a reservation
  shows up as a daemon that refuses early rather than as a silent drift.
- **Marker acquisition can fail before cleanup owns a Store.** Adapter-level
  fault injection forces marker write, file-sync, close and parent-directory-
  sync errors after exclusive create and asserts `Local.start_link/1` returns
  no Store pid. A complete residual marker is recovered only after its recorded
  holder is dead; an empty or partial residual refuses
  `store_writer_unverifiable` and remains byte-for-byte until the documented
  operator action. The daemon case maps both to
  `store_writer_acquisition_failed`, prints no readiness line, creates no
  socket, keeps placement through cleanup and never claims a marker release.
  The paired pre-create identity/open failures leave no marker, so the negative
  cannot pass by observing only an acquisition that never created one.
- **Reverse cleanup, on both sides of the bind.** On the healthy cleanup path, a startup made to fail
  **before** the bind — at the index bound, after the marker is acquired —
  proves marker absence, **no socket pathname** and byte-for-byte preservation
  of the pre-existing `daemon/` directory and oversized index. A startup made
  to fail **at or after** the bind — at the socket
  permission read-back — proves marker absence, **the socket pathname in
  place** and the subdirectory with it. Both are proved by a second daemon
  opening immediately on the same root without recovery, and the two
  assertions about the pathname are opposite, which is the point: an earlier
  revision asserted the same answer for both and contradicted the no-unlink
  rule for one of them. Paired injected marker-unlink/parent-sync and
  placement-removal failures leave complete residuals; only after the old
  OS incarnation is dead does the successor's verified recovery proceed. A
  suspended placement helper reaches `placement_release_ms`, leaves the safe
  residual and cannot extend process exit.
- **Offline import interruption is nonzero and never partial.** Five forced cuts
  deliver handled `SIGTERM` while the scan worker is inside legacy
  enumeration, before rename, after rename, during Store stop and during
  placement release. Each returns status `110`, no stdout, readiness or wire
  record. Enumeration interruption kills and reaps the exact worker. The
  pre-rename cut preserves the prior index byte for byte; the post-rename cut
  leaves the complete newly named image and makes no rollback claim. Store and
  placement cuts finish within the 40-second watchdog or leave only their
  documented complete residuals, and a subsequent verified reopen accepts the
  corresponding complete index. The sixth cut queues the exact success report
  against a late stop in both mailbox orders: success consumed first exits `0`
  and treats stop as cleanup-only; stop consumed first retains status `110`.
- **Readiness ordering.** A client that completes `connect` while the listener
  is parked is not accepted and creates no daemon state. After successful
  readiness output, the exact startup release serves it; on forced output
  failure it observes close and no accept, initialize, origin, lease,
  attachment, core call or journal mutation occurred. No readiness line is
  printed when the marker is held elsewhere, the socket permission check
  fails, or the index bound is exceeded, and each exits non-zero with its own
  class. The sentinel-arbitration cases force both orders for stop versus helper
  success and deadline, and component fatal versus helper success and deadline.
  A stop or exact owner fatal notice consumed first keeps the gate parked and
  creates no connection or core state, while the readiness line may already
  have reached stdout. Exact output success still waits for the owner's clock
  and component-liveness recheck; only its exact authorization consumed first
  lets the sentinel send `begin_accept`, after which a later signal takes
  orderly stop and a later component `EXIT` immediately enters fail-stop. The
  cases assert the sentinel's exact disposition rather than infer physical
  component lifetime from cross-sender mailbox order.

<a id="technical-plan-boundaries"></a>
### Ownership and Failure at Every Boundary

Concept: [Scope](M5.md#concept-plan-scope).

Most of what went wrong in this plan's reviews was not missing prose. It was a
boundary where two documents each assumed the other side handled a failure, or
where the daemon was given a job the code on the other side does not let it
do. This table is the answer to both: one row per boundary M5 touches, and
every cell resting on a code line that exists today or on a component this
plan names as new. It is the thing to check a change against.

**First, the process inventory, at one stated granularity.** Earlier revisions
called this table exhaustive while listing twenty-one rows that mixed exact
processes with per-thing families and omitted the runtime's own children —
three different resolutions in one table, which is why it kept being wrong. It
is now **grouped ownership**: every **fixed daemon process** appears exactly,
because the daemon's topology is a closed set this plan fixes; everything
owned by core, the adapter or the executor appears as a **group with its
owner**, because their counts are those components' business and naming them
individually would make this table a copy that rots.

The escript command process is the **lifecycle sentinel** outside the owner's
linked component set. It creates and monitors the owner, retains the
unforgeable `owner_ref`, receives every handled `SIGTERM`, owns readiness
publication and its single startup-disposition arbitration, owns the
first-fatal watchdog, and is the only process allowed to replace an owner
`DOWN` with `owner_lost`. It alone sends the parked listener's exact
`begin_accept`; it performs no synchronous IO and holds no product resource.

The offline import uses a disjoint three-process lifecycle and creates no daemon
component: its command process is the import sentinel; its unlinked monitored
owner holds placement and Store; and at most one monitored scan worker performs
the unbounded read-only enumeration. The owner kills and reaps the worker on
interruption, stops Store and attempts placement release, while the sentinel's
40-second absolute watchdog preserves status `110`.

**The daemon's fixed processes — twelve rows with transfers, eleven without:
the owner and every process it links.** The table has one more row than the
link set because the owner holds the links rather than being one of them.
Artifact transfers are the optional row. The **connection registry** is fixed,
linked and daemon-fatal, so it appears here rather than in the dynamic table.

| Process | Started by | Linked to | Stopped by | Its death |
| --- | --- | --- | --- | --- |
| **Daemon owner** | The `loopex daemon` lifecycle sentinel, `GenServer.start/3` — **unlinked**, monitored immediately, with `init/1` acquiring nothing and the startup sequence running in `handle_continue(:start, …)` behind the exact `{:go, owner_ref, command_pid}` sent after the monitor | Nothing; the lifecycle sentinel holds a monitor | Itself on orderly or completed fatal teardown; the sentinel on owner `DOWN` or fatal-watchdog expiry | Owner `DOWN` before a latch is `owner_lost` status 109; after a latch, its first class/status wins |
| Credential routing **registry** (ADR 0034) | Daemon owner, first | Daemon owner | Orderly step 6 | `registry_lost`, daemon-fatal |
| Credential **custody process** (ADR 0034), one for the one composed model configuration | Daemon owner, second | Daemon owner | Orderly step 6 | `custody_lost`, daemon-fatal |
| **Tracing capability** (ADR 0034) | Daemon owner, third, before composition | Daemon owner | Orderly step 6 | `capability_lost`, daemon-fatal: a sender that cannot confirm its trace exclusion refuses rather than resolves, so every model invocation would fail for a reason no client can fix |
| **Store adapter** (ADR 0031) | The composition function, in the owner's process | Daemon owner | Orderly step 6, **last**, in its own fixed 30 s phase | `store_lost`, or `store_capacity_exceeded` on its own capacity refusal |
| **Artifact transfers owner** | The composition function | Daemon owner | Orderly step 6 | `transfers_lost`. **Absent** where transfers are disabled |
| **Workspace lease** | The composition function | Daemon owner | Orderly step 6 | `workspace_lease_lost` |
| **Local executor** | The composition function | Daemon owner | Orderly step 6, before the lease | `executor_lost` |
| **Runtime root** (a supervisor; its children are core's, below) | The composition function | Daemon owner | Orderly step 5 | `runtime_lost` |
| **Admission relay** | Daemon owner, after the runtime | Daemon owner | Orderly step 4, after successful `seal_after_quiesce` has classified and removed every ticket and after the lease-owner sweep | `relay_lost`, daemon-fatal |
| **Connection registry** | Daemon owner, beside the relay and before the listener | Daemon owner | Orderly step 4, first — after step 3's records and closes, which go through the buffer-control interface it owns | `connections_lost`, daemon-fatal: it owns every connection's monitor, the buffer-control interface and the bounded lease-holder routing mirror. Without it the daemon can neither release a slot, route owner loss nor stop writing to a gone peer. **No client can be told this class**, because the write goes through the interface that is gone |
| **Listener** | Daemon owner, after the connection registry; it starts parked on `startup_ref` and performs no accept until the exact readiness-write success and required-component liveness recheck have won and the lifecycle sentinel sends the exact release | Daemon owner | Step 1, after the relay cut: untrappable kill and exact linked `EXIT` within the shared transport-cut deadline, leaving the pathname | An owner-observed linked `EXIT` ordered into the sentinel before release authorization is startup class `listener_start_failed`, with no accepted client; after the sentinel's exact `begin_accept` send, an unexpected exit is daemon-fatal `listener_lost`, and the connection registry remains alive long enough to attempt `fatal:listener_lost` to initialized clients |

**The daemon's dynamic processes, each with its bound:**

| Group | Started by | Bound | Its death |
| --- | --- | --- | --- |
| **Lease owners**, one per session under lease or acquisition | Daemon owner, on the first lease operation after existence validation | At most 512 process slots across `starting_waiting_pop`, starting, live and retiring owners. A slot remains occupied until the daemon owner consumes the exact pid's linked `EXIT`; a same-session successor then reserves the freed slot without spawning until exact mirror pop, owner-loss classification acknowledgement and terminal holder-close or correlated-refusal settlement, while an unrelated 513th session remains refused; its first grant additionally waits for every predecessor ticket and retirement completion | **Session-scoped**: the relay claims pending acquire and release permits whose immutable intended binding names the dead owner, executing permits whose actor binding names it, and pending or queued mutation origins bound to it, then waits for exact mirror-pop classification; an unpromoted mutation starts no core task, while a promoted mutation stays relay-owned to its real result. The returned granted holder gets only the uncorrelated `control_owner_lost` close, while every other claimed lease operation gets only a correlated refusal and stays open. A free or retiring owner with no claimed operation notifies nobody; observers stay, successor start waits the full routing-and-notification barrier, and first grant waits predecessor tickets and retirement completion. Retirement intent does not release the process slot |
| **Connections**, one per accepted client | Immediately after kernel `accept`, the listener records `accepted_at`, computes `initialize_deadline = accepted_at + 30_000` and reserves a provisional registry slot carrying both. The registry traps exits before serving, retains the exact daemon-owner pid, and starts the waiting connection with `GenServer.start_link/3` inside one serialized callback; an exact temporary-child `EXIT` is handled idempotently with its monitor `DOWN`. Before replying or consuming queued signals it monitors and binds the returned pid, prepares the updated row and unlinks it. The child monitors registry and listener from `init/1`, which performs no IO or external call. Thus a `nil` row means no child exists. Through handoff the listener temporarily monitors the connection and the connection monitors the listener. The provisional row retains `:listener_owned | :transferring | :connection_owned`; an abort in the middle waits for the exact transfer result and then requires listener close evidence or connection reap according to that result. Registry promotion retains the permanent connection monitor and deadline before acknowledgement; the connection then drops the listener monitor and acknowledges promotion so the listener can drop its temporary monitor. The registry owns the timer and initialize-complete CAS. The registry's acknowledged `transport_closing` gate refuses every later reservation or promotion | **512 occupied accepted slots** across provisional (`handing_off` or `aborting`), live and closing; a closed socket may retain a slot while request or holder cleanup remains | Every handoff and initialize continuation checks `now < initialize_deadline`; the timer only prompts. Expiry aborts and reaps a provisional row or closes a promoted uninitialized connection with EOF; queued-late completion loses. With no child, exact close acknowledgement or exact listener `DOWN` completes socket cleanup. A listener-owned abort requires that same listener close evidence plus child `DOWN`; a connection-owned abort requires exact connection `DOWN`; a transferring abort waits for the exact disposition, while listener death plus child reap closes either possible owner. Before promotion both sides send exact idempotent aborts on transfer failure, and daemon-owner listener loss aborts every provisional row for that listener incarnation. At the transport cut, every provisional or uninitialized row is marked for EOF close; after listener EXIT the registry reaps that fixed complete set before acknowledging. Abort changes `handing_off` to occupied `aborting`; the row and slot remain until the exact evidence for its no-child, listener-owned, connection-owned, transferring, or listener-death branch is complete. Promotion or exact reap makes a late abort a no-op. Afterwards `DOWN` moves live to closing, closes socket/buffer and starts a cleanup worker. The slot becomes free only when the relay has retired every origin, permit, worker and task, the cleanup worker has acknowledged both core owners, and the registry has consumed that worker's exact normal `DOWN` |
| **Request workers**, one per dispatched request including lease operations, reads and transfers | Each first monitors its connection incarnation and acknowledges readiness. The connection then binds it and its monitor to the relay origin or lightweight permit before sending a descriptor or `go`. The connection separately monitors it. Mutation workers wait and never race independent calls into the lease owner | At most ADR 0023's **32 in-flight per occupied connection** | Before relay binding, parent `DOWN` ends the worker. Afterwards relay connection `DOWN` kills and reaps every nonterminal queued or executing worker, including one blocked in an infinite call, and selects one winning disposition. An origin with no compensating work may terminalize immediately; provisional acquire cleanup and release cancellation remain `settling(connection_lost, op_ref)` through their exact acknowledgement, while promotion retires the waiting worker and retains its relay task. Only exact settlement terminalizes the origin or permit, so no capacity charge leaks |
| **Holder-cleanup workers**, one per closing live connection | Connection registry, monitored and keyed by `{connection_incarnation, cleanup_ref}` | At most 512, one per closing accepted slot | Exact acknowledgement sets `holder_cleanup_acked`; only the exact later normal `DOWN` sets `cleanup_worker_reaped`. Stale messages are ignored. Abnormal exit, normal exit without acknowledgement, or acknowledgement without normal `DOWN` by the bound is fatal `runtime_lost`, and the slot is never reused. Step 3 kills and reaps survivors at its deadline before fail-stop |
| **Daemon quiesce caller** | Daemon owner, unlinked and monitored, only after the admission wait | Exactly one per orderly stop; it owns the one `Loopex.Runtime.quiesce/1` call and its parameterized absolute drain/fence deadlines | An earlier component loss terminates and reaps it while preserving that component's fatal class. Exact quiesce error, helper exit without the matching result, or helper result loss with no earlier component class becomes `drain_failed`; it never turns into orderly success |
| **Stop helpers**, one per stop | Daemon owner, `spawn_monitor` | One at a time outside the teardown's lease-owner sweep; a target exit first makes the owner kill and reap that helper before starting another. The collective sweep starts at most 512, retains each charge through exact `DOWN`, and after an owner exit kills that owner's remaining helper; its deadline kills every remaining owner and helper together before awaiting all exact exits and `DOWN`s | Its reason never classifies the component. Exact `DOWN` only releases the helper population charge |
| **Placement-release helper** | Daemon owner after Store stop, or the failed-start/offline command owner after its Store stop; unlinked and monitored with the exact acquisition handle | At most one, under `placement_release_ms: 5_000` | Exact `:ok` plus normal `DOWN` completes only the attempt. Malformed result or abnormal death selects `placement_lock_failed`; deadline hard-halts without awaiting it, and verified stale-owner recovery handles any complete residual |
| **Output helpers** | Lifecycle sentinel for readiness and fatal diagnostics; daemon owner for routine diagnostics and the orderly census | At most one readiness helper, one first-fatal helper, one routine-diagnostic helper and one orderly-census helper. Readiness has an absolute 5-second deadline; fatal and routine output are unawaited; census output shares `teardown_ms`. A busy routine helper causes later lines to coalesce into the single `routine_diagnostic_dropped` bit | The helpers own no resource or disposition. The sentinel serializes readiness refusal, early death or deadline with startup stop, owner-reported component fatal and release authorization; only its winning release sends `begin_accept`. Deadline hard-halts as `readiness_write_failed` because a queued stdout request cannot be recalled safely. A raced component fatal or stop may coexist with a line already written but never opens the gate when it wins. Fatal output death is ignored. Routine output failure retains the dropped bit. Census output death or deadline omits only the best-effort line. None can delay the fatal status or orderly exit |
| **Relay tasks**, one per promoted primary ticket — the eight lease-authorized mutations, `session.create` and `session.attach`; **not** lightweight calls, duplicate-create waiters or replacement waiters | The relay, after recording the exact sequenced origin and capacity reservation/borrow and before acknowledging promotion | At most **16,384**: 512 occupied accepted slots times 32 active origin rows, with waiters starting no second task | Before orderly `quiescing`, a no-result death keeps its ticket and the relay exits `relay_lost`. During orderly quiescing it remains unresolved; after successful core quiesce, deferred `seal_after_quiesce` kills and reaps every survivor, lets a real result sent before `DOWN` win, terminalizes its waiters, returns every other exact ID as unresolved, and removes all origin rows before teardown |

**Core's processes, as groups with their owner.** The runtime root supervises
seven children under `:rest_for_one` (`runtime/supervisor.ex:64-90`, strategy
at `:92`), in this order: the tool
registry, `Control`, a worker task supervisor, an owner-group dynamic
supervisor, a session dynamic supervisor, the event dispatcher and the tracer.
The order is load-bearing under that strategy: a restart of the *n*th child
restarts every child after it, so `Control`'s restart takes the five beneath
it including every session coordinator, and the tracer's takes nothing.
The daemon links the **root** and, after composition, resolves and monitors the
exact `Control` and `EventDispatcher` incarnations for that runtime generation.
A `DOWN` or child-identity change for either while serving is `runtime_lost`,
even if the root survives; those two processes hold the core half of the
daemon's session and attachment accounting, so accepting an empty replacement
would leave leases, reservations and sockets claiming state core no longer
holds. Their `DOWN`s are expected only after the owner begins its deliberate
runtime stop. During active `quiesce/1` and before that teardown, root loss
remains `runtime_lost`. On a captured-Control event the owner first checks the
retained exact root pid: a dead root selects `runtime_lost`, while a live root
with lost or replaced Control selects `drain_failed`, because no census from
that drain remains valid. On a captured-EventDispatcher event the owner checks
the retained root and Control pids in that order: a dead root selects
`runtime_lost`; a live root with absent or dead Control selects `drain_failed`;
both exact pids still live selects `runtime_lost` for isolated dispatcher
failure. These are nonblocking pid-liveness checks and make no call into the
root, Control or a supervisor, so a Control-triggered `:rest_for_one` restart
and a root exit each have the same result in either monitor-message order. The first resulting
fatal class remains latched and later monitor messages are cleanup-only. A
dispatcher sentinel transitively catches rest-for-one restarts from the worker,
owner-group or session-supervisor positions; the Control sentinel catches a
registry or Control restart.

| Group | Owner | Count | What its loss means to the daemon |
| --- | --- | --- | --- |
| **Ordinary session coordinators** | Core's session supervisor, `restart: :temporary`, each with `shutdown: 5_000` | One per active/acquiring entry; at most 64 in daemon use | Core's exact `:session_unavailable` result on the next session operation; the reference live-resume client makes that operation a bounded post-attach `session.inspect`, which generation 2 maps before any driving mutation. **No death signal reaches the daemon and none is owed.** `quiesce/1` closes the internal start gate, issues every supervisor termination together, then directly kills survivors at the 325,000 ms work cutoff and requires every exact `DOWN` by the 330,000 ms outer instant before fencing |
| **Quiesce phase owner** | `Loopex.Runtime.quiesce/1` starts it privately with a monitor; it monitors the public caller and traps exits from its workers | One transient process per quiesce call | It owns the frozen census, fixed 70,000/10,000/330,000/130,000 ms phase deadlines, root-derived cancellation deadline and worker results. Its death makes the public call `{:error, :runtime_unavailable}`. Caller death makes it terminate its worker tree, so killing the daemon's unlinked outer helper leaves no inner work behind |
| **Quiesce workers** | The private phase owner; linked and non-trapping, used phase by phase for per-session admission, status and termination; the fence phase is tracked directly by the phase owner | One per projected writer-domain entry in the active phase. The internal entry point rejects more than 64 projected entries before spawning one; never-started dormant entries are omitted and get no worker | One abnormal worker exit is trapped and becomes only that session's conservative result while siblings finish. The admission, status and termination clocks each reserve a 5,000 ms kill/reap tail and start no later phase until their exact workers or coordinators are gone. Phase-owner or outer-helper death ends the whole linked set; an already-delivered core/Store call keeps its ordinary ambiguity, but no worker starts a later phase |
| **Fence-mode session coordinators** | The phase owner preallocates `op_ref` and a shared absolute deadline; Control uses `spawn_monitor` outside the ordinary session supervisor, captures its Store handle inside core, and registers the exact waiting pid after it links to the phase owner. Control reports the pid directly; the phase owner installs its own monitor and authorizes only before the deadline. Control and the fence process each recheck that carried deadline before `go` or Store work | One per projected writer-domain entry; at most 64, then each exits. Entries outside that set get no process | Sole serial writer for that session's abort-unknown resolution followed, where permitted, by one `advance_owner` and its exact re-presentation on `commit_unknown`. Phase-owner death ends it. A start may materialize after the shared deadline, but it remains waiting and unauthorized and is killed and reaped by the operation handshake; a waiting pid is killed and reaped, and an already-authorized pid is known and killed through the phase owner's monitor. A Store call begun before the cut keeps ordinary ambiguity, but after cleanup reaps the pid no later call can start. A suspended ordinary session supervisor cannot delay an untracked start, and no ordinary coordinator can start under the gate |
| **Attachment preparation workers** | The current EventDispatcher starts one linked, monitored, non-trapping worker after Control reserves an attachment transaction | One per pending attachment; core's pending-row ceiling and the daemon charge bound both cap the group at 512 | One worker's abnormal exit refuses only its transaction. A non-prepared session succession cancels matching workers, releases every installed attachment transfer and acknowledges the exact removed identities to Control before Control notifies holders and daemon attachment charges are released. The registry then clears only each connection-local attachment and keeps the initialized connection and any controller lease, epoch and deadline live for reattachment. Dispatcher death ends the entire group; Control's generation cut selects `attachment_superseded` for live embedded callers, while the daemon sentinel independently fail-stops as `runtime_lost` and clears relay charges during teardown |
| **Owner groups and their workers** | Core, beneath a coordinator | Per coordinator. For each managed provider attempt, the existing provider-call guard and permit-gated provider worker task are direct `owner_workers` children; M5 adds the adapter guardian and credential sender as two more direct children while that bridge runs. The guard's raw callback and the adapter's raw helpers remain beneath their named direct owners | Core's; a trapping owner group unwinds on its own clock and the daemon does not wait. Synchronous owner-group teardown awaits every direct child before a replacement tracer starts |
| **Event dispatcher and registration worker** | The runtime root owns one dispatcher; an initializing dispatcher owns one linked, monitored, non-trapping registration worker until its Control handshake finishes | **One dispatcher per runtime** plus at most one transient registration worker, holding the per-attachment queues — not one dispatcher per attachment, which an earlier revision of this table said | The owner monitors the dispatcher's exact incarnation; its loss or replacement while serving is fatal `runtime_lost` before an empty dispatcher can be treated as continuity. During active quiesce an EventDispatcher-first monitor event performs nonblocking retained-pid checks: dead root selects `runtime_lost`, live root with absent/dead Control selects `drain_failed`, and both exact pids live retains `runtime_lost` for isolated dispatcher loss. Dispatcher death kills the registration worker, and exact-incarnation checks reject late worker messages |
| **`Control`** | The runtime root | One per runtime | Holds the trace exclusion set and the session entries; the owner monitors its exact incarnation. Its loss or replacement while serving is fatal `runtime_lost`; during an active orderly drain a live retained root makes the same loss `drain_failed`, including when the carried EventDispatcher `DOWN` is consumed first and its retained-pid checks find that root live and this Control absent or dead. A dead root retains `runtime_lost` in either child/root message order. It is the root's **second** child, so under `:rest_for_one` its restart carries the workers, owner groups, sessions, dispatcher and tracer with it |
| **Tracer** | The runtime root, **last** child | One per runtime | Restarts alone, changing pid, which is why nothing holds a tracer pid |

**The adapter's and executor's processes, likewise:**

| Group | Owner | Count | Its death |
| --- | --- | --- | --- |
| **Provider bridge process tree** (ADRs 0019 and 0034) | For a runtime-managed call, the guardian and credential sender are the two adapter-bridge members that become direct temporary children of core's existing per-owner `owner_workers` supervisor, beside core's existing provider-call guard and permit-gated provider worker task named above. The callback uses at most one linked start proxy at a time. Each proxy sends exactly `{:start_proxy_result, kind, ref, proxy_pid, {:ok, child_pid}}` or the same tuple ending in `{:error, :unavailable}`; a caught starter exit is the latter. The callback requires that matching result and the child acknowledgement, installs a child monitor as soon as either matching message first discloses the pid, and consumes the proxy normal `DOWN` before it proceeds or starts the other proxy. The only legal cross-sender orders put proxy `DOWN` after its result. Child `DOWN` before ownership transfer is `:unavailable`; the callback demonitor-flushes only after the retainer owns guardian lifetime or the guardian owns sender lifetime. It starts the guardian with exactly `{guardian_ref, callback_owner_pid, stop_reference}`, registers it with Core, and waits for the guardian's authorization acknowledgement after retainer-monitor installation. It then starts the sender with exactly `{sender_ref, callback_owner_pid, guardian_pid, tracing_capability}` and waits for guardian adoption plus the sender's adoption-complete acknowledgement before initialize. The sender parks until exact provider readiness supplies `{:begin_bootstrap, sender_ref, guardian_pid, sender_pid, absolute_deadline}`; it validates the binding and deadline, completes exclusion and its delivery barrier, starts and installs the sink from an untraced process, and returns `{:bootstrap_result, sender_ref, sender_pid, guardian_pid, :ok}`. Only that exact acknowledgement permits `{:credential_context, sender_ref, guardian_pid, sender_pid, token, registry_handle, accepted_socket, invocation_nonce}`; the sender revalidates every binding field and the retained deadline before routing. Registry lookup, custody resolution and credential-frame write are separately parked phases. Each reports `{:credential_phase_result, sender_ref, guardian_pid, sender_pid, phase, result}` and advances only on `{:credential_phase_continue, sender_ref, guardian_pid, sender_pid, phase, absolute_deadline}` with the exact retained binding. After a successful frame write the sender drops every credential-bearing logical reference, tail-calls a non-secret final wait, and the final continuation permits only normal exit; only the exact normal sender `DOWN` plus the guardian's own deadline check permits the generic invocation helper. The sink links for abnormal termination and monitors the exact sender for normal exit. Only after both pids are verified clear may token delivery or registry/custody work begin. The guardian starts and owns the socket receiver and generic phase-send helpers; the credential sender starts and owns its group-leader sink. The registered guardian calls `Port.open/2` and owns the Port; that Port's direct OS image is ADR 0019's carrier, the carrier starts the independent OS guard, and the guard starts and owns the provider BEAM. For the explicit Direct/no-runtime API the bridge branch is adapter-owned and unmanaged: its raw guardian starts the sender linked and monitored, carries the request's pre-launch absolute deadline through every step, and explicitly stops and awaits sender and sink on normal cleanup | One bounded bridge tree per invocation: one guardian, one credential sender, at most one transient start proxy in managed mode and none in Direct, at most one socket receiver, at most one generic phase-send helper live at a time and one group-leader sink, plus one Port/carrier/guard/provider-BEAM set; the two outer core tasks are counted in the owner-workers row | Any branch failure maps to the existing generic model refusal. Owner-group teardown awaits both managed children; their links and monitors end raw helpers and sink. Guardian death ends a parked sender or one blocked in sink installation. Normal sender exit ends the sink through its sender monitor; abnormal or kill exit propagates through the link. Every transient proxy returns to baseline. Direct guardian loss kills the non-trapping raw sender through its link, sender loss ends its sink, and normal cleanup stops and awaits both. No daemon class |
| **Per-job Port worker, carrier and guard** (ADR 0022) | The local executor | One set per job | The job's outcome, reconciled through `commit_unknown`. **These are the processes the daemon cannot wait for at a halt** |

| Boundary | Owner | What fails | Who observes it, and how | What the client sees | Durable / not durable |
| --- | --- | --- | --- | --- | --- |
| **Host placement lock ↔ daemon** | The daemon owner holds an acquisition-specific handle from `LoopexComposition.Placement` for the root; the CLI uses the same mechanism | A live or unverifiable owner, lock operation failure, predecessor crash, or blocked release | Typed `placement_active`, `placement_unverifiable` and `placement_lock_failed` acquisition results refuse before Store/socket access. Clean teardown attempts exact-handle release only after Control and Store are gone, in an unlinked monitored helper under `placement_release_ms: 5_000`; completion does not prove absence. Fatal halt or release timeout leaves the lock and the next host reclaims only after the recorded OS incarnation is dead | Nothing — startup has no socket; a running client learns a later fatal cause by the ordinary stop record or EOF | **Not session truth:** host exclusion only. The lock record and recovery format are unchanged from the released CLI mechanism |
| **Store ↔ daemon** | `loopex_store_local` owns the marker and the log; the **daemon owner process** holds the Store's link and pid | Append error, including the capacity refusal | The Store stops **itself** (`local.ex:251-270` answers `{:stop, reason, commit_unknown, state}`) and its existing `terminate/2` invokes best-effort marker release. The owner's `{:EXIT, store_pid, reason}` clause receives it **with the Store's real reason**, which distinguishes `store_capacity_exceeded` from `store_lost`; the independent placement lock remains until the final VM halt. Healthy evidence proves marker absence; an ignored removal/sync failure leaves a complete residual for verified recovery | `daemon.stopping` with `store_lost` or `store_capacity_exceeded`, one bounded attempt, then the socket closes | **Durable:** whatever committed. **Not:** the failed append; the in-flight transaction is `commit_unknown` and reconciles later |
| **Store ↔ daemon (startup)** | The adapter | Marker held or unverifiable; acquisition write/sync/close/recovery failure; log too large | `WriterLock.acquire` refuses a live or unverifiable predecessor directly; every other acquisition failure maps to `store_writer_acquisition_failed`; `Log.open` refuses `store_log_too_large` (`log.ex:80-84`). If exclusive create preceded the acquisition failure, no Store pid or lock handle exists for reverse cleanup: a complete marker follows stale recovery, while a partial marker refuses as unverifiable and requires the documented operator procedure | Nothing — no socket exists yet | **Not session truth:** no journal record was written. A failed acquisition may leave only the physical marker residual; later startup never silently deletes an unverifiable one |
| **Core ↔ daemon: existence and create-history queries** | `loopex` answers; the daemon asks | Store unavailable, malformed ID, malformed adapter answer, or loss of the exact `Control` incarnation | `session_existence/2` returns `{:ok, :present | :absent | :invalid_id | :store_unavailable}`; `lookup_create_result/3` returns its five create-history domain answers inside `{:ok, result}`. The Store facade normalizes malformed adapter output to `:unavailable`. Either runtime API returns the separate `{:error, :runtime_unavailable}` when exact `Control` resolution or call fails | Existence uses its named correlated refusal. At the create ceiling, `:historical` returns the prior result without publication, `:absent` returns `activation_ceiling_reached`, `:conflict` returns the existing admission refusal reason `runtime_command_conflict`, `:store_unavailable` returns the correlated error of that name, and `:unexpected` returns correlated `internal_failure` without serializing the term. Runtime failure is daemon-fatal `runtime_lost` and emits no domain refusal | **Not durable:** both queries write nothing, proved by a byte-identical root |
| **Core ↔ daemon: attach** | `loopex` owns the cursor barrier, snapshot and queues | Barrier race, stale handle, queue overflow, **an attachment whose stable holder is gone**, or non-prepared session succession | The relay task invokes core's new attach-for-holder operation with the connection pid; `Control` and the dispatcher independently monitor that stable holder and release its full attachment set and transfers on `DOWN`, while the connection registry's monitored cleanup worker calls `release_holder/2` only after the relay's core-terminal gate, giving explicit idempotent cleanup and acknowledgement without blocking the registry. The slot remains `closing` until relay retirement, holder-cleanup acknowledgement and that cleanup worker's exact normal `DOWN`; abnormal exit or either missing terminal signal is daemon-fatal `runtime_lost` and the slot is never reused. A holder tombstone carried by the attach transaction resolves publication racing `DOWN`: publish-ack first may finalize before ordinary cleanup; `DOWN` first finishes published state directly to released after dispatcher cleanup, never restoring a replacement target. Separately, `Control.invalidate_attachments/3` turns non-prepared succession into an acknowledged all-session cleanup: EventDispatcher releases each transfer and returns the exact removed identities, Control notifies each stable holder, and the registry retains then idempotently releases every charge. The daemon reads no coordinator state to repair either race | Snapshot then contiguous at-least-once events, or detachment at the last emitted cursor with a stable reason; succession sends that same uncorrelated `detached` record to every live generation-2 holder for the session and closes those connections; a dead provisional holder receives no answer, while core records private `holder_unavailable` for its retained ticket | **Durable:** the events. **Not:** the attachment, the window, the buffer |
| **Core ↔ daemon: resume** | `loopex` | Placement mismatch, unknown session, already-resolved command | Core's existing resume path and command idempotency (`control.ex:306-328` selects the runtime-command branches and `:506-532` owns start/reply; completed replay is `:311-312` with the returned shape at `:526-527`) | Core's refusal, forwarded unchanged | **Durable:** the resume command and its result |
| **Core ↔ daemon: commands** | `loopex` admits; the daemon forwards | **Coordinator death** | Core's `DynamicSupervisor` (`restart: :temporary`, `session_coordinator.ex:134-142`); `Control` consumes the `DOWN`, releases the fence and leaves the entry (`control.ex:821`). No signal reaches the daemon, and none is owed: the daemon supervises the runtime, not the coordinators beneath it. The live resume client therefore detects the state with one bounded post-attach `session.inspect` | Generation 2 maps only core's exact `:session_unavailable` result to the correlated `session_unavailable` error before any driving mutation. The connection remains open for a bounded release attempt; restart then resume takes the dormant branch. `residency` still reads `active`, which means only that this daemon activated the session | **Durable:** whatever committed before. **Not:** any claim about liveness |
| **Lease owner ↔ connections** | `loopex_daemon` | A session's lease owner dies; its pending lease-state operations must be classified, while the relay's ticket for any promoted mutation it authorized survives | The linked daemon owner is the sole writer of exact lease-mirror installs and clears. The 512 lease-owner process slots cover `starting_waiting_pop`, starting, live and retiring rows; a materialized pid remains charged until the daemon owner consumes its exact linked `EXIT`, while the pidless `starting_waiting_pop` row owns the atomically transferred same-session slot until exact mirror pop, owner-loss classification acknowledgement and terminal holder-close or correlated-refusal settlement permit spawn. An unrelated 513th session remains refused. Every holder-changing acquire keeps a provisional connection-registry mirror while the daemon owner resolves the recorded actor's permit CAS: connection loss first resolves cancelled and discards an existing-owner proposal or reaps a fresh operation child without exposing an epoch; for an existing actor owner that dies after its grant report, relay `owner_lost` before the daemon's result CAS resolves cancelled, exact-clears the mirror, sends one correlated refusal and leaves the connection open; result first resolves granted, whose acknowledgement alone exposes the epoch, and a later connection EOF follows ordinary lease expiry while a later actor-owner loss closes the exact promoted holder. Signals from a lease owner are ordered before its later `EXIT`, so the daemon consumes any sent grant report and finishes the resulting granted-or-cancelled registry resolution before its session-scoped exit clause decides whether an exact holder was visible. On exact owner `DOWN` the relay claims every pending acquire or release whose immutable intended binding names that owner, every executing permit whose actor binding names it, and every pending or queued mutation bound to it, while a promoted mutation remains relay-owned to its real result. It retains each `owner_lost` winner until it joins that `DOWN` with the daemon's exact mirror-pop classification; a returned holder suppresses the correlated reply and receives only the uncorrelated close, while every other claimed acquire, release or unpromoted mutation receives only the correlated refusal and stays open. Renewal may settle directly at the relay. Release enters `release_pending` with the original deadline and sends only a proposal to the daemon; the daemon owns the result CAS, exact mirror clear and settlement acknowledgement, so an owner-loss winner preserves the holder mirror and a result winner clears it before the one correlated success. A connection-loss winner remains settling until the daemon's exact cancellation makes the owner restore `held` at that original deadline and the relay acknowledges terminalization. While serving, owner restoration and mirror clear share a first fixed five-second instant and exact relay settlement has a second fixed ten-second instant from proposal acceptance. Exact owner death or a missing, malformed or late restoration acknowledgement invokes the no-reply supersede before ordinary pop/classification; that supersede must settle by the second instant, while a missing relay settlement is `relay_lost`. No success is rendered. At the admission cut both serving clocks become cleanup-only and the exact row joins the existing admission/freeze barriers. The freeze atomically moves executing lease permits to `shutdown_admitted` and returns the complete tagged union of barrier-owned, settling-acquire, settling-release and settling-owner-loss rows, including owner loss from any phase. Exact retained operation and start records drive child reap, provisional resolution, release settlement and later owner-`DOWN` joins; the selected disposition never changes, all no-output relay and mirror cleanup shares the freeze deadline, and core quiesce begins only with no nonterminal or claimable **lease-operation** row and no provisional, pending or stale mirror left. Executing non-lease query, read and transfer permits remain tracked through result or the later connection/worker barrier. An exact granted or restored holder mirror remains for the drain. Ordinary owner-loss output is suppressed and no per-operation extension begins | While serving, a granted holder receives the uncorrelated `control_owner_lost` form and its attachment closes; every other claimed acquire, release or unpromoted mutation receives the correlated form and its connection stays open. Exactly one form is emitted for an origin. Free/retiring has no notification. During orderly stop, `daemon.stopping`/EOF owns notification. Observers stay; successor start waits the complete pop, classification and terminal-notification barrier, and the next owner mints a fresh epoch only after every predecessor ticket and retirement completion | **Not durable:** the lease, the epoch, the in-flight set. The journal is untouched, and a mutation already inside core settles or refuses exactly once under core's serial ownership |
| **Lease owner ↔ connections (expiry)** | `loopex_daemon` | A holder stops renewing, or a mutation is unresolved at the deadline | The lease owner's own monotonic deadline; the in-flight set decides when a takeover is granted | The holder's next mutation refuses; a takeover is eligible at the deadline and granted when the in-flight set empties | **Not durable:** the lease. The mutation that was in flight settles or refuses exactly once |
| **Listener ↔ connections** | `loopex_daemon` | Foreign peer, malformed frame, over-long path, backpressure, initialize-deadline expiry, listener or connection death during handoff, listener death after promotion | Filesystem permission verified after bind, then the per-platform peer-credential read (`LOCAL_PEERCRED` / `SO_PEERCRED`), then ADR 0023's framing refusals. The registry monitors the listener incarnation, traps exits while retaining the exact daemon-owner pid, and creates each waiting connection linked inside the registry callback that atomically installs its child monitor and row before unlinking and replying; an exact temporary-child `EXIT` is handled idempotently as cleanup with its monitor `DOWN`, and the child monitors registry and listener from its inert `init/1`. During handoff the listener temporarily monitors the connection and the connection monitors the listener; the provisional row retains the exact listener-owned/transferring/connection-owned disposition so abort or deadline expiry closes and reaps the actual owner; registry promotion retains its permanent monitor and deadline before acknowledgement, then the connection drops the listener monitor and tells the listener to drop its temporary monitor. The registry's exact CAS accepts initialize only before that instant. Backpressure is enforced at the 4 MiB output buffer | Closed before initialize for a peer refusal or deadline expiry; a stable framing reason otherwise; detachment at the last emitted cursor under attachment backpressure. Before promotion, the listener and connection each send an exact idempotent abort for their provisional row; if both die, the daemon owner's listener-EXIT path aborts every remaining row for that listener incarnation. The aborting row stays occupied until its branch has exact evidence: close acknowledgement or listener `DOWN` with no child; that listener close evidence plus child `DOWN` for listener-owned; connection `DOWN` for connection-owned; or the exact transfer result followed by its selected branch, with listener `DOWN` plus child `DOWN` resolving an unreported transfer. Promotion or exact reap makes a late abort a no-op. After promotion listener death leaves the connection alive for the bounded fatal record and close | **Not durable:** connections, buffers, windows |
| **Registry ↔ sender ↔ custody ↔ provider child** | The **host** owns registry, custody and tracing capability. For managed calls core's `owner_workers` directly owns guardian and credential sender; the guardian owns the socket receiver and generic phase-send helpers, the credential sender owns its linked-and-monitoring group-leader sink, the registered guardian owns the Port it opens, that Port's direct OS image is the carrier, the carrier starts the independent OS guard, and the guard starts and owns the provider BEAM. Direct calls use the explicit unmanaged adapter lifetime: raw guardian and sender are linked and monitored, and the guardian carries the request's pre-launch absolute instant. The token is bound at composition and resolved per invocation | Composition handle invalidity; immediate guardian start, Core registration, guardian authorization, sender start or adoption refusal; provider readiness, sink-install or Direct-clear failure; no registry row; registry/custody death, refusal, malformed reply or silence; immediate or blocked private-frame write; or exclusion that cannot be confirmed | A missing or malformed registry handle, or a missing, malformed or unbound tracing capability, refuses composition before runtime use or child creation and reverse-cleans started edges. Adapter preflight produces `:no_token` or `:invalid_token`; an invocation-private refusal produces `:missing`, `:expired`, `:oversized` or `:unavailable`, including `:unavailable` from a live registry with no token row. The managed absolute invocation deadline exists before either supervised start and is never reset. After guardian registration, sender adoption and initialize, the guardian applies that instant to provider launch/readiness, sender release and every later step, kills the sender on expiry and produces `:timeout`. Before accepting any provider-readiness, sender, registry, custody or frame completion or emitting the next release, it rechecks monotonic `now < deadline`; the timer only prompts the check, so a queued completion consumed at or after the instant is cleanup-only; a non-answering managed start remains an owner-group/runtime liveness failure. Direct has no Core registration or adoption gate: its raw guardian carries the request's pre-launch absolute instant through inherited-session clearing, sink installation, routing, custody and frame write, kills and reaps sender and sink on expiry, and also produces `:timeout` | The adapter's existing generic `Loopex.Model` refusal only; no private atom enters ADR 0029's terminal, a public event or an operator diagnostic | **Not durable:** nothing about credentials is journaled, and no span or record carries model `options`. Exactly one credential-bearing BEAM message crosses from custody to sender, followed by one credential-bearing private socket frame to the child. A later core command outcome follows its existing durability semantics; the credential-resolution class itself is transient |
| **CLI ↔ socket** | `loopex_cli` | Socket unreachable, refusal, transport loss, renewal failure, a complete `daemon.stopping` record or a handled client signal | The client retains its command form, durable create and resume identities, session ID, role and last emitted cursor, plus an exact ordered mutation plan. Every prompt, optional follow-up or steer, and takeover prompt has its method, preallocated command ID and `not_sent | sent_unconfirmed` state, and the record carries `next_step`. Non-steer input is fixed when planned; steer retains its content template until replay supplies `run_id`, then fixes its canonical semantic input before first send. It never retains a writer epoch. List, status and liveness use one 10-second query clock and at most one reconnect/retry. Streaming uses one non-resetting 35-second recovery clock with 250 ms retry delay: a lost create reply replays the same command ID; run and resume may reacquire, attach, inspect and resume after restart; an unresolved resume retains its ID, while a resolved historical replay followed by dormant reattach after daemon replacement retires that completed ID and allocates a fresh activation attempt under the same clock; observers and takeover never activate. A `not_sent` next step is sent exactly once after recovery and proof of its prerequisite. After reacquisition a `sent_unconfirmed` step is re-presented with the same method, durable command ID and canonical semantic input, a fresh request ID and fresh writer epoch; a fresh or replayed accepted or refused admission resolves the step without a duplicate mutation, while exact `admission_unknown` advances nothing, sends no later mutation and exits non-zero with the retained method and command ID unresolved. `control_held` retries only until the prior lease can have expired. A complete stop record is terminal; bare EOF follows the phase matrix. Handled live-client signals suppress reconnect and never send `session.abort`, with one bounded release attempt only when a lease is held and the socket remains writable | Exact compact JSON for list and status; contiguous at-least-once streaming from the retained cursor with seam duplicates removed; terminal stop reason, bounded refusal or non-zero unresolved outcome on `stderr`; signal exits fixed by the live-form table | **Durable:** nothing the client holds. The cursor and recovery phase are client-side positions; durable command identity makes create replay safe |
| **Daemon ↔ OS: signals** | The operator | Before handler installation, direct child `SIGTERM` or launcher `INT`, `TERM`, `HUP` or `QUIT` at the root-resource prompt reaches BEAM's default handler. After installation, `SIGTERM` reaches the daemon handler; terminal `SIGINT` reaches it only as the `SIGTERM` the launcher forwards, since `:os.set_signal/2` refuses `:sigint`; direct `SIGHUP` is operating-system signal death with status `129`, and direct `SIGQUIT` is ignored after the daemon installation removes OTP's default handler | Before installation no installed daemon handler routes the signal to the existing lifecycle sentinel: the command exits `0` through BEAM's default termination with no daemon-owned resource acquired and no cleanup path run. After installation the lifecycle sentinel records and forwards pre-readiness stops, arbitrates stops during readiness, and forwards post-release stops. Its catch-all returns `{:ok, state}` for every unhandled bare or tuple event, so an ignored `SIGQUIT` cannot remove the handler. The owner first completes the relay admission cut, the registry's `transport_closing` gate, the listener's untrappable kill and exact linked `EXIT`, and the provisional/uninitialized sweep under the one transport-cut deadline, leaving the socket pathname for the next verified placement-lock and marker holder. It then runs the bounded admission wait and core drain, tells initialized clients and closes every remaining connection, and stops the connection registry, lease owners, relay, runtime, edges, and Store in that order, with Store last in its own fixed 30 s phase — each process stop driven by a monitored helper while the owner waits on its own link until the shared teardown deadline and kills on expiry. It then runs the exact-handle placement attempt in its separate five-second helper. Classification uses the observed exit plus the exact `stopping` mode: `:normal` or `:shutdown` is consumed for `normal_stop`; the listener's exact owner-issued `:killed` is consumed for `planned_transport_kill`; and a timeout-issued `:killed` is cleanup-only after that target's fatal class was latched, so it can never independently permit exit `0`. Every other exit is classified | Before installation no client or readiness surface exists. After handled `SIGTERM`, an initialized client sees `daemon.stopping` with `operator_stop`, then close. Direct `SIGHUP` provides only abrupt EOF; direct `SIGQUIT` leaves the connection and process live, and a following direct `SIGTERM` still performs the orderly sequence | **Durable:** before installation, nothing changed; afterwards, whatever committed. **Not:** work ended crash-equivalently — a claim about the journal, not about every process being gone |
| **Offline import ↔ OS: signals** | The operator | After parser and path-byte validation the import installs the same direct-`SIGTERM` handler before placement or Store acquisition; launcher `INT`, `TERM`, `HUP` and `QUIT` arrive as that `SIGTERM` | The import sentinel retains status `110` and tells its monitored owner to stop. The owner kills and reaps the scan worker, preserves the prior image before rename or the complete image after rename, stops Store under 30 seconds and attempts placement release under five seconds. A 40-second sentinel watchdog hard-halts with the same status and existing residual rules | No stdout, readiness or wire record; bounded stderr diagnostic only | **Durable:** never a partial image. The old complete index remains before rename; the new complete index may remain after rename. Exclusion residuals use their existing verified recovery |
| **Daemon ↔ OS: kill** | The operator | `SIGKILL`, power loss | Nothing runs — no handler, no `terminate/2` | The socket closes with no record at all | **Durable:** the journal. The marker is left for the next daemon's verified stale-writer recovery |
| **Daemon ↔ OS: socket file** | `loopex_daemon` | A stale `daemon.sock` left by any exit path, or an unsafe object at the selected path | Only a daemon that has acquired and verified both the host placement lock and Store marker may inspect it. A no-follow `File.lstat/1` must prove the uid retained from this acquisition's placement owner handle, `:other` and `S_IFSOCK` mode bits before removal; absent proceeds, while wrong kind/owner or metadata/removal failure preserves the path and returns `socket_permission_unverified`. No daemon removes one on its way out, so no predecessor can delete a successor's socket | The loser of two simultaneous starts exits without touching the socket; a client meeting a stale socket is refused rather than hung; an unsafe path prevents readiness | **Not durable:** the socket file is a path, never state |
| **Daemon ↔ OS: Store marker** | `loopex_store_local` | Best-effort release attempted by `terminate/2`, retained when no callback completes or its removal/sync fails, or left before a Store pid exists when acquisition fails after exclusive create | Every completed Store `terminate/2`, deliberate or self-initiated, invokes the unchanged adapter's release but ignores its removal and parent-sync results. Healthy evidence proves absence and immediate reopen. Daemon-owner loss, `SIGKILL`, power loss, a timed-out Store stop or ignored release failure can leave a complete marker for verified stale recovery. A failed acquisition may leave a complete marker with the same disposition or a partial marker that refuses as unverifiable and requires operator inspection. The separate placement lock prevents a new Control after Store self-loss and remains held through failed-start cleanup | No client exists on acquisition failure; a running client sees only the later `daemon.stopping` reason. The marker is never a client contract | **Not durable in the journal sense:** physical-writer exclusion only. No case authorizes silent deletion of an unverifiable marker |

Three rows deserve their reading stated, because they are where earlier drafts
went wrong. The **coordinator death** row is the one that forced `residency`
to mean a daemon fact: there is no observer column entry available, so any
design that needed one was unimplementable. The **Store ↔ daemon** row is the
one that forced the fail-stop split — the Store is already gone and has already
attempted marker release by the time anything can act, so an ordered shutdown ending "stop the Store" had
nothing to stop — and it is also the row that has now been written wrong
twice. The first draft filled its observer column with a link and a monitor
the daemon could not hold, because `LoopexComposition` takes the link in a
process it spawns and returns no adapter pid. The second put a `Supervisor`
there, which cannot report a child's exit reason at all and cannot host the
runtime's struct return. Both failures were the same mistake: naming an
observer without checking that something could observe.

So the standard this table holds itself to is now explicit. **Every observer
cell names either a process the daemon itself links, with the clause that
receives the exit, or a mechanism inside core with a line number.** A cell
that can name neither is a boundary the plan has not finished.

<a id="technical-plan-minimalism"></a>
### Proportional Minimalism Budget

Concept: [Scope](M5.md#concept-plan-scope).

The smallest sufficient system wins, and each addition below names what it
unifies and why direct code is insufficient. One application, because a
daemon is a host and a host is an application. One daemon owner process, one new public composition function — which unifies
the two callers that need the edges assembled, `RuntimeOwner` and the daemon's
owner, and which direct code cannot replace because the alternative is a
second copy of the whole wiring layer. One socket listener, **one narrow core
concurrent-attachment change with three parts** — supersession stops removing
an attachment *unconditionally*, becoming conditional on ADR 0023's existing
`replace` flag and scoped to the attaching process's own prior attachment, and
the dispatcher monitors the attaching process, keeps that monitor and the
attacher pid **on the installed attachment**, and removes
on its `DOWN`, releasing that attachment's transfers, and `Control` holds
its own attachment and repetition state **per holder** rather than
keeping one slot per session — owned by the holder pid, released by its
`DOWN`, and resolved at the command path by the `attachment_id` the handle
carries, because that path discards its caller (`control.ex:336`) and under a
daemon the caller is a relay task rather than the holder — because the first half
alone would leave core with no release
path at all, supersession being the only one there is today, and would leave
the only caller of `release_transfers/2` with no replacement, which accepted
ADR 0028 forbids. **One
trace-exclusion call,
`Loopex.Trace.exclude_self(capability, functions: [mfa])`** — which unifies
nothing and is not asked for by this milestone's features at all: it exists
because accepted ADR 0030 already requires that a key-bearing call be excluded
before delivery, and the implementation did not do it. Direct code cannot
supply it, because exclusion has to happen inside the tracer that owns the
session. It is **one** core change with two inputs rather than two changes:
the caller passes its own key-bearing identities and core installs both the
match-specification clear ADR 0030 names and the process flag its callees
need. What *was* dropped is **sink-time redaction**, which is too late — the
raw call having already reached the tracer — and the module-wide exclusion of
a codec, which cost every other frame's tracing. The match-specification list
is not dropped; it is half the call, and the process flag is the other half,
because a list of `{module, function, arity}` identities cannot cover what an
excluded function *calls*: a traced `:gen_tcp.send/2` shows the credential
frame however this adapter's own functions are patterned. **Two plain fields on two new runtime-side functions beside create and resume** — which unify
nothing and add no wire surface: they exist because core computes `fresh?` at
`control.ex:895` and then throws it away four lines later, leaving every
caller unable to tell a fresh create from a replay. They are new functions
rather than widened returns because widening `create_session/3` would change
what `Loopex.create_session/3` forwards to a released embedded caller
(`loopex.ex:87-95`), which is a compatibility break bought for a daemon's
bookkeeping. Direct code cannot supply
them, because the only alternative is inferring the answer from side effects,
which is a race. **One bounded, single-use `quiesce/1`, one terminal Control gate with an initial projection and later read-only census, and one drain-specific coordinator gate** — the Control gate closes create/resume/attach/ordinary routes; the coordinator gate orders already-routed commands before or after the abort; the admit-and-pause split and non-retrying drained commit remain one drain-only clause; and the plain-data projections carry `Control`'s session entries, which is the smallest thing that can answer "what is there
to drain" and which `Control` cannot answer today at all, its only session
read taking one id. It unifies nothing today and says so:
its only caller is the daemon's orderly stop, and the app-server host does not
drain by hand, because `LoopexComposition.with_runtime/2` brackets a runtime
that lives and dies with one client's stdin and has nothing to drain
(`host.ex:76-79`). It earns its place another way: an outcome of this
milestone promises a bounded drain, and there is no other place the mechanism
can live. Core owns coordinator lifetime and cancellation; a daemon-side drain
would read coordinator internals, which the dependency direction forbids, or
run its own cancellation loop, which is the second loop this milestone
forbids. It adds no bound and no durable command — it drives the cancellation
sequence and the bounds core already has — and it returns plain data. One
read-only core existence query — which
unifies the three daemon paths that must know whether an ID exists before
doing anything with it (acquire, activation of a session the index does not
hold, and the crash-cut recovery), and which direct code cannot supply,
because the only alternatives are reading Store internals, which the
dependency direction forbids, or calling `attach` or `resume` for their
answer, which takes an attaching or durable side effect to ask a question —
one in-memory lease record and one
admission check, one resident window and eviction policy, one per-connection
output buffer, one session index with bounded pages, two new top-level CLI
commands (`daemon` and `attach`), the `daemon prepare-index` subcommand, three
daemon-backed forms of released commands (`run`, `resume` and `sessions`), and
the Node client's socket mode. Outcome 6 adds exactly one indirection, the
credential token and the host-owned routing registry it is resolved through,
because the value that travels in adapter configuration is copied between
processes and may be printed by a crash report: an opaque token is the
smallest thing that can travel there while disclosing neither the credential
nor the host's arrangement of it, and a registry row is what a host adds for a
second credential instead of widening the value. It unifies the three
reference hosts that hold a credential today — the CLI, the app-server host
and the daemon — and any embedder that holds one elsewhere. Beside it, each
reference host gains one custody process for the one value it already reads
and one registry row for it. Nothing else: the change otherwise moves where
one value is resolved and deletes the credential environment read from the
call path.

Nothing else. No lease, transport, byte limit or residency policy in core; no
second loop, event dispatcher, cancellation path or protocol codec; no
transport registry, plugin socket layer, generic service framework, store
adapter, control store or durable daemon record; no daemon-side session state
beyond the lease, the index and the residency facts it holds in memory.
Implement lifetime, transport and collaboration once, against the local
adapter.

**The numbers M5 commits to.** The table distinguishes inherited or ADR-owned
bounds from explicit plan-owned operational bounds. Each plan-owned number
names the existing code constraint or composed mechanism that justifies it.

| Ceiling | Value | Source |
| --- | --- | --- |
| Log capacity per state root | 256 MiB; an append past it refused as `store_capacity_exceeded`, which terminates the store and closes the daemon, a log already past it refused at open as `store_log_too_large` | ADR 0031 |
| Frame ceiling on any single store record | 4 MiB | ADR 0031 |
| Retention and replay | Full history, no compaction, full replay at open | ADR 0031 |
| Occupied accepted connection slots per daemon | 512 across provisional (`handing_off` or `aborting`), live and closing, the attachment number reused; the slot is taken at `accept`, so the 513th socket is accepted and **closed with no frame read and no record written**. A dead incarnation remains closing until every request origin and holder cleanup is terminal | ADR 0032 |
| Relay request origins and tasks | At most 16,384 active origins, derived as 512 occupied accepted slots × ADR 0023's 32 in-flight requests; every relay task owns one promoted primary origin, while duplicate-create and replacement waiters add no task | ADRs 0023, 0032 and 0033 |
| Time an accepted connection may take to complete `initialize` | 30 s from kernel accept, advertised under its own limits key `initialize_deadline_ms`; one absolute deadline is retained through provisional handoff and promotion, after which the connection is closed with no record; without it the connection ceiling would bound nothing | ADR 0032, its value derived from ADR 0033's lease term rather than chosen, and carried as a separate key so neither contract moves the other |
| Attachments per session | 64 | ADR 0032 |
| Attachments per daemon | 512 | ADR 0032, its attachment-lifecycle list, with the limit key in its limits table |
| Core event-count queue per attachment | 1,024 events | ADR 0032 |
| Daemon socket output buffer per connection | 4 MiB encoded | ADR 0032 |
| Resident window per session | 4,096 events and 16 MiB encoded | ADR 0032 |
| Aggregate retained encoded events per daemon | 512 MiB | ADR 0032, its queue-ownership and attachment-lifecycle sections |
| Lease-owner process slots | 512 across `starting_waiting_pop`, starting, live and retiring owner rows, the attachment number reused rather than a second limit; a materialized slot remains charged until the daemon owner consumes exact linked process `EXIT`, a transferred `starting_waiting_pop` slot has no child until exact mirror pop, owner-loss classification acknowledgement and terminal holder-close or correlated-refusal settlement, its first grant additionally waits for every predecessor ticket and retirement completion, and an unrelated 513th session is refused `control_capacity_reached` | ADRs 0032 and 0033 |
| Idle time before an observer attachment, or a connection no longer holding a controller lease, is evicted and its window and buffer released | 10 minutes; a current lease holder is exempt and eviction never stops a coordinator | ADR 0032 |
| Sessions activated per daemon lifetime | 64; the 65th activation refused, the remedy being to restart the daemon. It is per lifetime rather than concurrent because nothing deactivates a coordinator, which is recorded as a limitation | ADR 0032 |
| Recorded session index entries per root | 4,096; an index image with more rows is refused at daemon start without enumerating the legacy directory. `prepare-index` alone examines legacy population and refuses a union over the ceiling. The ceiling is on recorded entries and never on reachability: a session successfully resumed by ID beyond it is activated and not recorded, and the listing carries `index_full` | ADR 0032 |
| `session.list` page | at most 256 entries, `limit` in 1 to 256 | ADR 0032 |
| Socket path bound, over `<root>/daemon/daemon.sock` | the platform's usable `sun_path`, one byte less than the structure because of the terminator: at most 103 bytes on Darwin and 107 on Linux, derived and tested per platform rather than assumed, refused at start as `socket_path_too_long` | ADR 0032 |
| Protocol frame ceiling on the wire | unchanged from ADR 0023 | ADR 0032 |
| Live list, status or liveness query recovery | `live_query_deadline_ms: 10_000` from first send, with at most one new connection and one retry | This plan |
| Streaming client recovery | `stream_reconnect_deadline_ms: 35_000` from first unexpected transport loss, with a fixed 250 ms retry delay; no successful step, resolved replay, replacement resume ID or later EOF resets it, so every resume identity and daemon-replacement cycle shares that one absolute instant | This plan, composed from ADR 0033's 30-second lease term and a five-second local tail |
| Live-client handled-signal release | `live_detach_release_ms: 5_000`, one best-effort release attempt when a lease is held and the socket is writable; no signal-driven abort | This plan |
| Cleanup grace | an integer of 1 or more, refusing `0` with `cleanup_grace_invalid`, because core's `cancellation_bounds/1` admits `grace_ms >= 1` (`apps/loopex/lib/loopex/executor.ex:456`) | This plan, against core's existing validation |
| Owner startup gate | `owner_start_gate_ms: 5_000`, begun immediately before `Owner.init/1` returns and covering only the unlinked owner's wait for the command process's exact `:go`; expiry ends the owner with nothing acquired | This plan; startup-only and excluded from `T_orderly` |
| Transport cut | `transport_cut_deadline_ms: 5_000`, one absolute instant covering relay cut, registry gate, listener reap and the uninitialized-peer sweep | This plan |
| Relay-control barriers | `relay_control_timeout_ms: 5_000`; orderly stop uses it exactly twice, as fresh sequential instants for lease freeze and entry to quiescing. Serving-state owner-loss classification may use one fresh instant before the admission cut and is outside `T_orderly`; the cut absorbs any still-running classification into the transport-cut instant and makes its old timer cleanup-only, while stopping starts no per-owner instant | This plan and ADR 0033 |
| Release settlement while serving | `owner_restore_deadline` at 5,000 ms and `release_settlement_deadline` at 10,000 ms from one proposal acceptance; the first bounds result selection, owner restoration and mirror clear, and the second bounds exact relay terminalization. An orderly admission cut makes both timers cleanup-only and transfers the exact row to the fixed admission/freeze barriers | This plan and ADR 0033 |
| Quiesce admission | `quiesce_admission_ms: 70_000`: a 5,000 ms exact-Control gate, at least 60,000 ms for the two-call drain-only Store path, and a reserved 5,000 ms worker kill/reap tail, shared across at most 64 concurrent sessions | This plan, against the local Store's 30,000 ms call timeout |
| Status census | `status_census_ms: 10_000`: 5,000 ms concurrent work plus a 5,000 ms kill/reap tail across at most 64 sessions | This plan, against `SessionCoordinator.session_status/2`'s 5,000 ms bound |
| Coordinator termination | `coordinator_termination_ms: 330_000`: 5,000 ms for the second Control projection, at most 64 serialized child shutdowns × 5,000 ms, then a 5,000 ms direct-kill/reap tail | This plan, against the session child specification and one session supervisor |
| Fence phase | `fence_budget_ms: 130_000`: a 125,000 ms shared work cutoff plus a 5,000 ms kill/reap tail | This plan |
| Store stop | a fixed 30 s, the Store's own `@call_timeout` (`apps/loopex_store_local/lib/loopex/store/local.ex:65`), independent of any grace; the usual release attempt takes milliseconds | This plan, against the Store's existing bound |
| Placement release | `placement_release_ms: 5_000`, an outer deadline on one unlinked monitored exact-handle release helper; timeout hard-halts and leaves a safe residual for stale-owner recovery | This plan, against ADR 0031's best-effort host lock |
| Offline-import interruption | `prepare_index_interrupt_ms: 40_000`, one absolute sentinel watchdog covering scan-worker kill/reap, the Store's 30-second phase and the five-second placement-release phase, with a five-second scheduling and halt margin | This plan, composed from the two existing cleanup phases |
| Maximum fail-stop exit | **35 s** — 5 s for the executor stop and the Store's own fixed 30 s, the only two steps of that path that wait; 5 s on the two store classes, where the Store is already gone | This plan, as the sum of its parts |
| Wait slice | 60_000 ms, so no `receive … after` argument approaches the BEAM's 2^32-1 limit, probed at both pairs | This plan; the limit is the VM's |
| Queued mutations per session in its lease owner | at most 31, behind the one unresolved ticket: only the controller connection mutates a session, and ADR 0023 bounds a connection to 32 requests in flight, checked at admission | ADR 0023, reused; this plan adds no second queue bound |
| Lease term | 30 seconds | ADR 0033 |
| Lease renewal interval for the reference clients | 10 seconds | ADR 0033 |
| Takeover grace beyond expiry | none; takeover is eligible at expiry and granted once the session's in-flight admission set is empty | ADR 0033 |
| Writer epoch | opaque, at most 64 bytes, at least 128 bits of fresh randomness, minted per grant | ADR 0033 |
| Credential size | 1 to 65,536 bytes | ADR 0019, unchanged by ADR 0034 |
| Credential frame **payload** cap | 69,632 bytes, the wire frame being eight bytes longer for its header | ADR 0034, which is where the frame's shape is written; no ADR 0019 file states it |
| `req_llm` version pin | `~> 1.24.0` | Maintainer decision 4B of 2026-09-20, a **plan** decision. A dependency pin is not a contract number: it binds what this milestone builds against and is changed by an ordinary reviewed dependency change, not by an ADR amendment |

**Four rows say 512 and they are four different bounds**, which is worth one
sentence because "one number, one ADR" would otherwise read as one limit: 512
*attachments* per daemon, 512 *MiB* of retained encoded
events across every buffer and window, at most 512
lease-owner *process slots*, and at most 512 occupied accepted *connection slots*
across provisional, live and closing — the last
two deliberately reusing the attachment number rather than introducing limits
that could drift from it. The connection bound is not implied by the
attachment bound and is stated separately for that reason: a client may
connect, initialize, list and acquire without ever attaching.

Count and byte ceilings apply together: an event that would exceed either
triggers the stated detachment, eviction or refusal before the ceiling is
crossed. These are retained-payload ceilings, not an exact BEAM RSS promise;
measure and report actual process RSS under the maximum attachment count and
at payload pressure separately.

**Verification cost.** The
[verification guide](../developer/verification.md#concept-verification-speed)
sets the target that checking work takes a small share of development time
while every real guarantee keeps a check that would fail if it were broken. M5
adds one application's suite to the fast check and must not lengthen the
critical path: `loopex_llm_reqllm` was that path at M4 closure, and Outcome 6
is what unpins it. New daemon tests that wait on a real-time bound inject that
bound where it is armed and assert the production default once, as M4's speed
work established; a test whose claim is the real duration is tagged
`long_bound` and moves to the release check. Raw line count is a review
signal; behaviour and the measured limits above govern.
