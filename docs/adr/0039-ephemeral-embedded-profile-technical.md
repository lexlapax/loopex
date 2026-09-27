<a id="technical-depth"></a>
## Technical depth

Concept: [Ephemeral embedded profile](0039-ephemeral-embedded-profile.md#concept).

<a id="technical-adr-0039-decision"></a>
### Profile Composition

Concept: [Context and decision](0039-ephemeral-embedded-profile.md#concept-adr-0039-decision).

The kernel's ports are unchanged; the profile chooses what fills each one:

| Port | Durable profile | Ephemeral profile |
| --- | --- | --- |
| `Loopex.Store` (six callbacks) | `Loopex.Store.Local` | `Loopex.Store.Memory`: a supervised process over `Loopex.Store.Local.State`, the conformance test wrapper `LoopexStoreLocalTest.Memory` promoted with its optional fault probe (active only when supplied, as `Loopex.Store.Local`'s is), so every conformance case proves it |
| `Loopex.ArtifactStore` | `Loopex.Store.Local.Artifacts` | None; the runtime's existing `artifact_store: nil` behaviour (overflow truncated with the executor's notice, transfers unsupported) |
| `Loopex.Model` (`complete/3`) | `Loopex.LLM.ReqLLM` through the companion bridge | `Loopex.LLM.ReqLLM.InProcess` for every provider the profile serves |
| `Loopex.Executor` | `Loopex.Executor.Local`, ledger under the state root | `Loopex.Executor.Local`, ledger under the profile's temporary root |
| `Loopex.Policy` | A named host policy | A policy module supplied by the host; the reference CLI maps `allow-all`, `shell-allowlist` and `refuse-all` to its own modules |

**The in-process adapter:**
- **Placement:** it lives in `apps/loopex_llm_reqllm`, the one edge application
  that carries ReqLLM.
- **Scope:** the ephemeral profile only. The durable composition always uses
  the companion adapter, which keeps refusing any in-VM fallback, as ADR 0034
  fixed.

**Providers and their credential variables:**

| Prefix | ReqLLM module required at call time | Credential variable |
| --- | --- | --- |
| `ollama:` | `ReqLLM.Providers.Ollama` | None |
| `openai:` | `ReqLLM.Providers.OpenAI` | `OPENAI_API_KEY` |
| `anthropic:` | `ReqLLM.Providers.Anthropic` | `ANTHROPIC_API_KEY` |
| `openrouter:` | `ReqLLM.Providers.OpenRouter` | `OPENROUTER_API_KEY` |

**Credential/tool scheduling gate.** The composition application owns one
VM-wide `LoopexComposition.Ephemeral.CredentialToolGate` before its ephemeral
session-owner DynamicSupervisor under a one-for-all supervisor. It grants
monitored, serialized leases in one of two mutually exclusive modes: any number
of session-lifetime `:tools` holders, or any number of per-call
`:credential_call` holders. Composition passes the gate as an explicit opaque
capability to the adapter and executor; they never discover it through a global
lookup. It is host-edge admission state and stores no session truth, policy,
request or credential. Every gate `init/1` creates a fresh private generation
and writes exact `{:unclean, generation}` to `:persistent_term`; absence means
a first healthy VM start, while any prior value makes that incarnation start
poisoned. A replacement overwrites the old generation before serving a message,
so a clean-stop proof from an earlier gate cannot erase its marker. Before every ephemeral owner start, including a session
with no tool lease, the entrypoint atomically reserves owner admission at the
gate. The reservation is bound to and monitored against the starting process.
The new temporary owner must synchronously exchange it for a registration bound
to its own PID before it creates a root or acquires a lease; a refused child
start, explicit cancellation or starting-process `DOWN` releases only an
unexchanged reservation. Owner `DOWN` removes a registration only when no
lease, preflight, subtree, executor or local-call obligation hangs beneath it.
Otherwise the gate retains those records as orphan obligations, tells every
registered local lifecycle root to unwind, kills registered callers and
poisons both modes; a parent death never discards its child census.

The adapter and executor do not import composition. Each owns a private gate-
client behaviour at its inward edge; one composition module implements both and
passes `{client_module, opaque_handle}` through private constructors. The handle
contains no function and reaches no public or durable plane. The edge invokes
only its own behaviour dynamically, preserving the existing inward dependency
direction.

After closed public validation, workspace and skill resolution, provider
admission and the pre-start Req, SSL and Tidewave guards, but before ReqLLM
hygiene, gate lookup or owner admission, `start_session/1`, and `run/2` through
that session-creation path, ensure `:loopex_composition` is started through one
unlinked, monitored `ApplicationBootstrapGuard`. That guard monitors the
requester and owns one linked, monitored, non-trapping worker that alone calls
`Application.ensure_all_started/1`; neither receives session inputs. Both use
one absolute 5,000 ms decision bound followed by a 1,000 ms finish/reap bound.
The worker reports provisionally through the guard and exits only after the
requester's correlated `finish`. Only an in-time exact success, exact normal
worker `DOWN`, the guard's reap acknowledgement and exact normal guard `DOWN`
proceed. Requester death or either deadline makes the guard kill and reap its
worker; the guard exits normally only after exact worker `DOWN`, and every
earlier exit is non-normal, so unexpected guard death kills the linked worker.
An error, malformed or late result, abnormal exit, timeout or missing proof returns fixed
`composition_application_start_failed` before any root, credential read or
session. An application-controller request may finish after the bounded refusal,
and a killed guard or worker may outlive the caller until scheduled. Neither has
session inputs or authority, so a later creation call may use a new guard and
re-evaluate the application; OTP serializes concurrent starts and the operation
is idempotent.
The composition application omits ReqLLM, Req and Finch from its
automatic application set, so bootstrap cannot bypass the hygiene decision.
The packaged CLI escript sets its Mix `:escript` `app` option to `nil`, so the
generated wrapper loads code and configuration but starts no Loopex application
before `LoopexCli.main/1`. Main performs only literal command classification
before startup. A literal `ask` or `-p` completes its closed CLI grammar, prompt
bounds and profile selection first; every invalid form refuses without starting
a Loopex application. A valid ephemeral form invokes this public creation
entrypoint directly. A valid durable form first calls the private ask-specific
application helper before credential discard or durable dispatch. It calls
`Application.ensure_all_started(:loopex_cli)`; success continues, while every
returned error, malformed value, raise, throw or exit is discarded and enters
ask's fixed `application_start_failed` status-1 renderer. Every other argv uses
the private legacy-start helper. That helper calls the same OTP function and exactly
reproduces Mix's former two branches: success continues; `{app, reason}` writes
iodata consisting, in order, of the literal "ERROR! Could not start application ",
`Atom.to_string(app)`, the literal ": ", `Application.format_error(reason)`
and one LF to standard error, then halts status 1.
Thus a stalled composition callback
is inside the valid-ephemeral bound, invalid ask input starts nothing, and
released commands retain the M6 CLI graph's dependency-start order and M1–M5
behavior; ReqLLM, Req and Finch remain the separately declared load-only
exception.
Handle-consuming `ask/3`, `answer/3`, `last_result/1`, `history/1` and
`stop_session/1` never bootstrap. They perform only their lifecycle-first check;
application, gate or owner loss makes the existing handle closed or unavailable
and never starts a replacement tree.

**Gate message discipline.** "Synchronously" means that the protected action
waits for an acknowledgement, not that an owner uses an unbounded
`GenServer.call/3`. Every gate operation is an asynchronous capability message
carrying a fresh request reference, the requester PID, an absolute monotonic
expiry, the operation and its bounded payload. The only accepted reply carries
that exact reference and the operation's closed result. The requester monitors
the gate, ignores stale or mismatched replies and sends an idempotent cancel
with the same reference on timeout. Messages from that requester preserve
reserve-before-cancel order; the gate also rejects an expired request and keeps
the canceled reference until its expiry, so a suspended gate cannot later
create a live reservation, owner registration or lease from an abandoned
request. Repeating a reference returns the recorded result and never performs a
second transition.

Each admission, acquisition, exchange, registration, caller-creation,
caller-token verification, lease-validation, proof-submission, proof-query and
release round trip ends at the earlier of 1,000 ms and its enclosing startup,
model-call, tool-call or cleanup deadline. The requester never passes that
duration to an OTP timer; it compares the absolute deadline and receives in
bounded slices. Session and cleanup owners keep pending gate requests in their
ordinary receive loop, so stop, creator `DOWN` and dependency `DOWN` remain
answerable. A setup actor that waits outside an owner is still start-blocked and
has read no credential or started no OS effect. A missing, late, malformed or
gate-`DOWN` reply never authorizes progress. Reservation and owner-exchange
failures use the M6 composition reasons; a credential-call failure uses the
fixed model failure; a tool-dispatch lease check refuses before an OS child;
and a lost registration or cleanup proof takes the unproved/poison path. The
start-blocked credential caller applies the same rule to its token check and
exits without reading the environment on any failure. Clean-stop census uses
its stated 1,000 ms callback bound. Late replies cannot change a result already
selected by an owner.

Each opaque handle also carries a private one-way `:atomics` poison latch owned
by the gate tree. A session-bound participant that cannot prove a registration,
release or gate-scope helper `DOWN` atomically changes it from zero to one before
reporting the failure. Through the owner's prepared acknowledgement, the
synchronous entrypoint is the sole detector and poison committer for owner-start helper proof: the guard
reports evidence to it, and it detects a dead, silent or malformed guard through
its own monitor and deadline. Gate-scope helpers are exactly an owner-start guard or worker, a
pre-root credential preflight actor, a ReqLLM-hygiene worker, or a
gate-registered provider-call cleanup owner, lifecycle root or caller whose
missing end could retain authority. The session `FacadeClient`, cleanup phase workers
and root-removal worker are excluded: their missing ends retain the retryable
session-subtree or root-removal obligation without poisoning by themselves.

Poison may originate in the session owner itself, including after an unproved
final gate acknowledgement or owner-held preflight proof. That owner first
commits the atomic latch and creates one poison reference. It atomically enters
the applicable startup-rollback or session-cleanup state and closes new facade
admission. Before the owner can acknowledge post-exchange preparation, it has
already recorded the one cleanup grace and no preflight, root or dependency
phase is yet authorized. It therefore creates the ordinary
`now + cleanup_grace_ms + 5_000` deadline or joins the existing deadline without
extension. It computes the
selection-notification deadline as 1,000 ms after the later of the active
cleanup deadline and that origin instant, using saturating arithmetic, and
sends the exact correlated `poison_watch` control to the gate. It does not wait
for the acknowledgement: its message order places that watch before either
later control, and the live owner remains the independent deadline fallback.
It completes every still-independent cleanup phase under that recorded cleanup
deadline, atomically stores the full reached-phase result, freezes its recipient
values and sends `poison_delivery_started` with one aggregate delivery deadline
1,000 ms ahead. Only that second control starts delivery. A live gate already
monitors the owner and records the controls when they arrive; owner `DOWN` or
either applicable deadline makes it terminate the shared tree. Owner `DOWN`
after the latch but before result selection leaves only the named bare-
unavailable owner-loss result. A suspended gate cannot grant when it resumes
because each transition rechecks the already-set latch, while the live owner
kills the tree at the applicable deadline.

A session-bound detector records one poison reference, sends it only to its
registered owner without a preliminary gate message or result-delivery
deadline and waits at most 1,000 ms for exact custody. Accepting custody in the
owner's serial loop atomically commits poison and enters the existing
`stopping`/session-failure state when cleanup has not begun: new facade
admission closes, earlier operations keep their admission rules and later stops
join the attempt. It records a fresh `now + cleanup_grace_ms + 5_000` cleanup
deadline. If stop or creator loss already started cleanup, custody joins its
existing deadline without extension. Before doing cleanup work, the owner
computes a distinct selection-notification deadline exactly 1,000 ms after that
cleanup deadline, using saturating arithmetic, and sends the exact correlated
`poison_watch` control to the gate. Only its exact acknowledgement received
within the detector's custody wait permits the owner to acknowledge custody;
that acknowledgement names the owner, poison reference and selection deadline.
The detector then sends its correlated retirement notice and exits normally;
the owner must observe that exact detector `DOWN`. Cleanup may continue beyond
that initial custody interval. At its cleanup deadline the owner performs the
final zero-wait receives, samples proof state and atomically stores the complete
reached-phase result. Missing gate or owner custody, detector `DOWN` before
retirement, owner `DOWN`, a mismatched message or absence of exact
`poison_delivery_started` by the later selection deadline makes the detector,
owner or gate kill the tree. During the post-cleanup margin the owner freezes an immutable
capability-bound set of every live recipient and that recipient's already
selected bounded value, then sends `poison_delivery_started` with one aggregate
absolute delivery deadline 1,000 ms ahead. Values may differ: an ask may retain
its terminal value while a concurrent stop receives `cleanup_unproved`. The
owner sends all entries without serial waits and collects acknowledgements only
until that deadline. Each receiver acknowledges before returning and performs
one zero-wait matching receive if reporter `DOWN` wins. The owner logs any no-
waiter or unacknowledged retained-root path. The detector has already retired;
the owner sends exact `poison_handoff_complete` to the gate immediately before
tree termination and then kills the shared tree. Missing or mismatched delivery start or completion, reporter
`DOWN` or aggregate expiry makes the gate kill the tree; there is no per-
recipient interval. While live, the gate applies the
same protocol as reporter for an admitted hygiene cohort, whose recipient
values are all `req_llm_start_failed`. Every admitted external requester also
monitors the exact gate. If gate `DOWN` wins, that requester—not a replacement
gate—selects the fixed failure, ignores every later reply and returns by the
same 7,000 ms outer deadline; no owner, root, credential read or effect exists.

The synchronous `start_session/1` entrypoint is a separate direct-return case,
not a wrapper or a process in the shared tree. It preserves the host creator
identity and caller-held refusal and is the sole detector and poison committer
for owner-start helper proof through the owner's prepared acknowledgement. The guard may report missing
worker proof but cannot commit poison or transfer result custody; a silent,
malformed or dead guard is detected through the entrypoint's monitor and
deadline. The entrypoint commits poison, directs and bounds the existing shared-
tree termination/reap branch and then returns. This case has no pre-owner
custody message, private result handoff or `poison_handoff_complete`. After
exchange and the owner's prepared acknowledgement, every detector uses the
registered-owner protocol; with no live
registered owner, the detector terminates the tree immediately. The gate checks the
latch before and after blocking work and immediately before every authority-
bearing transition. Once set, it refuses reservation, owner exchange, root-
token issue, lease acquisition or release, PID/tag registration, caller
creation or token verification, process-group proof submission and final
session disposition. It admits exactly three non-authorizing control
transitions: correlated `poison_watch` records owner PID, poison reference and
selection deadline; `poison_delivery_started` records the one delivery
deadline without recipient values; and `poison_handoff_complete` orders
immediate tree termination. The hygiene reporter may create the same states
internally. Identical replay returns the recorded acknowledgement without
extending a deadline or repeating an effect. Stale, mismatching, reordered or
conflicting messages are refused and cannot postpone fallback. Each deadline
gets one zero-wait receive for an already queued exact message before tree
termination. These transitions cannot clear poison, release an obligation or
authorize work. The gate does not autonomously exit before the
applicable selection or delivery deadline while the exact reporting owner
remains live. This
ordering preserves a reached `gate_release` result and an admitted hygiene
cohort's fixed failure without reopening admission; sessions killed as other
children of the shared tree retain only the named bare-unavailable limitation.
No gate acknowledgement is needed for the atomic poison commit, an unresponsive
gate cannot later admit queued work, and a replacement reads the retained
unclean marker and starts poisoned. Clean-stop proof requires the latch still
zero; no path resets it before VM restart.

A ReqLLM-hygiene request uses the same fresh-reference, requester, absolute-
expiry, cancel and replay discipline, with its stated 7,000 ms enclosing bound
instead of the ordinary 1,000 ms gate round trip. The gate first acknowledges
that the request started or joined the one current hygiene decision. Expiry or
cancel before that admission performs no read, configuration or start; a late
dequeue records the fixed `req_llm_start_failed` result and cannot begin a
decision. Once admitted, requester death or a joiner's local timeout does not
cancel the shared decision, but that requester receives no late reply and a
later request re-evaluates the completed state. A suspended gate can therefore
neither leave the caller waiting outside a deadline nor apply a queued start
after refusal.

Owner creation uses the same bounded discipline. After reservation, the
entrypoint starts and monitors, without linking to, one responsive temporary
guard, then starts and monitors one non-trapping worker. Before that link forms,
the guard sets `trap_exit: true`; it monitors the creator and worker and
correlates both worker `EXIT` and `DOWN`. The worker links to the guard, reports its PID to both parties and
remains start-blocked until the entrypoint grants the guard permission to relay
the start. The worker alone may call `DynamicSupervisor.start_child/2`; the
guard remains responsive, records any returned owner, and keeps custody of the
handoff. The owner's `init/1` creates only its creator and guard monitors and
returns `{:ok, start_blocked_state}` immediately, without `handle_continue/2`
or a receive inside `init/1`, so `start_child/2` can return its PID. Its normal
post-`init/1` receive loop accepts only the correlated private exchange, commit,
cancellation and monitored-lifetime messages until commit; it creates no root,
lease, application or session and accepts no public request. Creator
`DOWN` for any reason makes the guard kill the worker and any returned owner,
consume the worker's correlated `EXIT`, await both exact `DOWN` messages, cancel
the reservation and exit. Unexpected guard death kills the
linked worker and makes a start-blocked owner exit. The entrypoint's
monitor-only relationship prevents an explicit guard kill from killing the
host caller.

A worker `EXIT` or `DOWN` before the guard records an exact child-start return,
or guard `DOWN` before commit acknowledgement, means the start result is
unknown; it never proves that no request was queued. The entrypoint routes loss
before the call, while blocked or after owner return-before-relay through the
same shared-supervisor kill, poison, cancellation and reap branch as timeout.

If the guard has not relayed a result by the 1,000 ms startup deadline, the
entrypoint kills the shared owner DynamicSupervisor, worker and guard, cancels
the reservation and waits one further 1,000 ms for all three exact `DOWN`
messages. This unknown-start branch always poisons both modes and requires VM
restart. All three messages yield the fixed `ephemeral_owner_start_failed`
refusal with no known residual helper, but a child whose PID never reached the
guard may remain start-blocked until scheduled; its expired token and dead
supervisor prevent root creation or effect dispatch. A missing known `DOWN`
yields the same refusal,
retains the unclean marker, poisons the gate for both modes and logs which
monitor is missing; the already-sent untrappable kill may complete after
return. Killing the shared supervisor makes every scheduled active owner enter
its monitor-driven fail-closed path. An owner produced by a queued start
receives an expired token and exits from its start block, so this
unconfirmed-reap path creates no session root, reads no credential, dispatches
no effect and returns no handle. After a successful exchange, the entrypoint prepares commit
through the guard while the owner remains root-blocked. A second
guard-retirement handshake lets the owner authorize and demonitor that exact
guard; the guard acknowledges before exiting. The entrypoint requires worker
and guard exact `DOWN` within the remaining startup bound and otherwise takes
the same poison/no-root branch. Only after both are gone does it ask the exact
gate incarnation for a one-use release token bound to reservation, owner and
creator. The gate sends that token to the entrypoint, whose only release message
forwards it to the owner; issuance by the gate is the release boundary. The
owner validates and consumes the exact token once. Signal order from the gate
means its `DOWN` before token issue is a no-root refusal. Gate loss after issue
is an ordinary post-release failure: the owner may already have received the
forwarded token, so startup rollback or the named unmarked-owner limitation
applies. Stored gate identity and `Process.alive?/1` never authorize release.

Every admitted session owner keeps lifetime monitors on the exact gate,
application-supervisor and owner-DynamicSupervisor PIDs supplied in its start
handoff; it never rediscovers a replacement by name. Any matching `EXIT` or
`DOWN`, or a gate incarnation mismatch, closes that owner to new API work,
runs its bounded session-failure cleanup and ends it unmarked. Waiting callers
receive the M6 admission-state result; without one, a retained root is reported
only to the host logger. A suspended owner may process neither monitor nor its
already-sent kill before the startup refusal returns, but it can perform no new
gate-authorized work and completes cleanup or exit when scheduled. The poisoned
gate and required VM restart are the fail-closed boundary; the design does not
claim synchronous death of every process before the unconfirmed-reap refusal.

After token release, the owner remains responsive while one linked and
monitored lifetime `SessionRoot` owns an initially empty zero-restart
`:one_for_all` supervisor. One 5,000 ms absolute startup deadline covers its
ready handshake and fixed store, lease, executor, runtime-trace-capability,
runtime and post-runtime trace-bind phases. Each process-start phase is
owner-granted before its blocking start, and every returned PID is
owner-monitored before the next. `SessionRoot` starts
`Loopex.Trace.Capability`, obtains and validates its handle and passes it into
the model options before it starts a start-blocked `RuntimeHolder`. That holder
is registered before it calls the runtime's unbounded readiness path and
remains that runtime supervisor's OTP parent. After the runtime handle returns,
one separately granted call must bind the capability to that exact runtime and
return exact `:ok` before startup prepares or commits. A returned capability
start/handle/validation failure or bind refusal retains its fixed phase cause;
a missing post-grant start or bind result is unknown. A grant without an exact
returned result is otherwise unknown:
the first grant permits only side-effect-free root-candidate preparation. If no
exact candidate report arrives, the owner kills the actor under the startup
deadline. Exact actor `DOWN` proves no root exists, keeps the fixed temporary-
root failure and permits the ordinary final gate disposition; missing `DOWN`
prevents that exchange, returns the same no-root phase failure and poisons both
modes. Once a candidate is recorded, a lost mkdir return retains
that possible path with unknown ownership and never deletes it. After an exact
claim, known parent `DOWN` cannot prove an unreported dependency child absent,
so the owned temporary root is retained with `:session_subtree` unproved. If
executor start may have begun, tool-lease release also needs the existing
process-group proof. Only the owner's commit of the fully prepared startup lets
session creation begin.

A live owner rolling any returned startup failure back submits the same final
gate disposition as ordinary stop, but only after every known actor and subtree
is `DOWN` and any executor process-group proof is accepted. Exact acknowledgement
releases the owner record and lease and is required before root removal or a
proved failure return. A refused, malformed, late or missing acknowledgement is
permanently unproved `:gate_release`, poisons both modes and retains any possible
root. If no root or possible path ever existed, there is no truthful cleanup
root to report; composition returns `credential_tool_gate_unavailable`, logs no
path and leaves admission poisoned. That no-root result applies only when the
final exchange was reached. A pre-root probe, candidate actor or other actor
whose exact `DOWN` is unavailable prevents the exchange, returns its fixed
phase error and also poisons admission; it does not claim an unattempted gate
release.

If the owner dies after its reservation exchange but before the handle return,
the entrypoint returns bare `session_unavailable` and never becomes a cleanup
owner. Before root-token issue, the gate closes any orphaned preflight, lease or
owner record and no root exists; an unproved close poisons both modes. After
token issue, the registered subtree collapses through its owner monitor, but a
root may remain unnamed. No replacement owner retries a phase or invents a
cleanup map.

The first stop the owner accepts changes one serialized lifecycle state to
`stopping`. Later stops join its single cleanup result. Every non-stop request
the owner dequeues after that transition is answered immediately with
`session_unavailable`; only requests serialized before it use their ordinary or
admission-specific completion rules. Successful cleanup then marks the opaque
handle closed before the owner exits.

The application callback's `prep_stop/1` is the only path that may authorize
erasure, and `stop/1` is the only path that commits it. Callback state retains
the application supervisor PID. `prep_stop/1` never calls a supervisor child-
enumeration API or the gate synchronously. It starts one unlinked, monitored,
non-trapping resolver worker bound to the application-supervisor PID, a fresh
reference and one absolute 1,000 ms deadline. That worker resolves and verifies
the current gate and owner-DynamicSupervisor children, asks the exact gate to
atomically seal owner, lease and ReqLLM-hygiene admission under the same
reference and expiry, sends one provisional result and waits for `finish`. On a
structurally valid, in-time result the callback sends exact
`{callback_pid, ref, :finish}` and accepts the proof only after the worker's
exact normal `DOWN` within the same absolute deadline; otherwise it sends an untrappable kill, performs
one zero-wait receive at the deadline and returns no proof. The worker can
neither erase a marker nor start an owner, and a late request or result is
refused by the reference and expiry. A gate sealed by a worker whose result is
lost stays fail-closed while OTP stops the tree, with both markers retained.
The gate returns an empty-census proof bound to the nonce, application-
supervisor PID, owner-DynamicSupervisor PID, exact gate PID and exact persistent
marker generation only when it already
has no reservation, registered owner, lease, poisoned obligation, admitted
hygiene cohort, hygiene worker or outstanding controller-mutation obligation;
the hygiene marker is not `:starting`; and the verified owner
DynamicSupervisor already has no children. Requests queued but not admitted are
refused after the seal. It never waits for an active session or hygiene
decision; a non-empty census returns no proof and lets OTP continue stopping the
tree with both persistent markers intact. The gate does not erase either
marker.

`prep_stop/1` puts only that exact proof into the state passed to `stop/1`.
After OTP has ended the application supervisor, `stop/1` verifies that the
proof names the same supervisor and child incarnations. With the application
tree and every possible marker writer gone, it compare-and-erases only exact
`{:unclean, proof_generation}` as the final clean-stop commit; a missing,
malformed or different value returns without erasure. It never erases the
separate ReqLLM hygiene marker. A
timeout, missing or replaced child, gate death before its
reply, callback failure, non-empty or contradictory census, absent proof, or
failure before that commit leaves the scheduling marker and the hygiene marker
unchanged. Once the commit occurs, the
application tree and every admission path are already gone, so loss of a later
acknowledgement cannot make live state look clean. The gate's own `terminate/2`,
ordinary supervisor shutdown and child termination never erase it. If the gate or its supervisor dies, the
one-for-all subtree stops every ephemeral owner, but the scheduling marker remains. A
replacement gate is poisoned and refuses both modes until the VM restarts,
where `:persistent_term` is empty. Every handle for a session stopped by that
failure reports `session_unavailable`. This fail-closed marker is admission state,
not session truth; trusted host code can erase it and is outside the guarantee.

An active-tool owner records one 5,000 ms session-start deadline, acquires
before its presence-only environment preflight, registers that linked,
monitored sensitive probe beneath its lease before granting a fresh-reference
check, and accepts only `:clear` or a fixed-name presence result sent before the
same process's exact normal `DOWN`. Timeout, malformed result, abnormal `DOWN`
or either half missing is `credential_preflight_failed`; a missing exact `DOWN`
retains the obligation and poisons both modes. The owner registers its private
subtree root before an executor starts, and releases only after every registered
probe and that root are `DOWN` **and** the owner has proved every executor process
group empty. The proof actually comes from the registered `Executor.Local` over
a private gate handshake bound to its PID, instance reference and proof
capability after it
freezes dispatch and drains its at-most-one still-unproved group; the owner
cannot synthesize it. The gate retains an accepted proof nonce and its complete
binding after the worker, executor and session subtree end and after lease
release. It stays queryable until the monitored session owner acknowledges its
final cleanup disposition or dies, so a subtree-only retry does not call a dead
executor or repeat a proved drain. The gate accepts that disposition only after
every registered probe, call, caller, subtree and tag is gone, atomically drops
the owner registration, lease, inactive-executor capability and retained proof,
then sends an exact correlated acknowledgement. A missing, late, refused or
malformed acknowledgement is permanently unproved gate release, flips the
one-way poison latch and precedes any root-removal attempt. No executor is the
only vacuous case. This adds no public
executor-protocol field or durable record. An executor for `:tools :none` has no
mode lease. The owner allocates a fresh instance reference before the executor
phase grant and supplies it with the private gate client and owner registration
in the child options. `Executor.Local.init/1` uses its own PID to register as its
first effect, before ledger preparation, state construction, definition exposure
or dispatch. The exact gate reply binds an inactive-executor proof capability to
that owner registration, PID and instance. Refusal stops init; a missing,
malformed or gate-loss reply poisons admission before init stops because the
registration may have committed. The capability admits no definition or
dispatch and exists only to prove its private group set stayed empty. Every
registered executor must submit and have its gate-bound nonce validated while
it is alive; only then may subtree shutdown produce its `DOWN`. No-executor
rollback is the sole vacuous case. Owner death before registration is
releasable because no tool exists. Owner or executor death after registration,
an unproved process group or loss of
the process-group proof poisons both lease modes for the remainder of
the VM; subtree `DOWN` alone is insufficient. Each ephemeral owner also
receives an instance-bound local-call capability. It grants no lease and no
credential access; it only lets a cleanup owner register itself and its
credential-free Ollama call resources beneath that still-live owner. Such a
call may therefore run while the same session holds a tools lease. An
unproved local call poisons later ephemeral admission just like any other
unproved registered provider-call root. A
hosted call's cleanup owner obtains and holds a credential-call lease before it
creates the lifecycle root or caller. After exact pool setup, the owner asks the
gate to create the generic caller. In one serialized turn the gate spawns the
request-free process start-blocked, records and monitors its PID under the
lease, and returns a one-use start token. The caller also monitors the spawning
gate and exits without reading a credential if that gate dies before the token
arrives. The cleanup owner monitors the returned PID and only then supplies the
call inputs. The caller verifies the token, lease and PID-bound registration
immediately before the credential read. The cleanup owner registers the
lifecycle root and every pool-subtree PID as they appear. Gate failure during
caller creation therefore yields either no caller or a blocked caller that
self-terminates; it can never yield an unregistered credential reader. Normal
release requires all registered PIDs `DOWN` and a 5,000 ms
quarantine from caller `DOWN`. That interval matches the isolated transport
witness but does not observe or prove that a checked-out socket or TLS
controller ended; a slower drain is the named residual exposure. Cleanup-owner
death makes the gate tell the registered lifecycle root to unwind, kill a live
caller, await every registered PID and apply
the same quarantine rather than releasing directly. Before every tool dispatch,
an executor carrying this gate capability registers and repeats the same
sensitive result-before-normal-`DOWN` check under the earlier of 1,000 ms and
the job's effective deadline. Any non-clear or unproved result is the existing
fixed `effect_start_authority_unavailable` pre-effect refusal; a missing probe
`DOWN` also freezes dispatch and poisons both modes. The executor scrubs all
three provider variables from any OS-child environment.
Durable and directly constructed executors without the capability keep their
existing environment behavior.

The gate controls only ephemeral-composition scheduling. A durable composition,
a directly constructed executor and same-VM host code can ignore it, change the
environment after a check, inspect same-user processes or run a concurrent
tool. The profile therefore claims no structural secrecy from those
participants; a host needing that boundary isolates the ephemeral profile in
its own VM, while the durable profile keeps its provider in the companion.

**The call** (ReqLLM 1.24.0). The adapter calls the non-streaming
`ReqLLM.generate_text/3` with the model built inline as
`ReqLLM.model(%{provider:, id:, base_url:})`, and on every call:
- `api_key:` the value of the provider's variable, read by the calling process
  immediately before the call after validating a byte length of 1 to 65,536;
  absent, empty or larger values refuse before the ReqLLM call; none for Ollama,
  whose provider performs no key lookup or authentication
  (`providers/ollama.ex:118`);
- `total_timeout: :infinity`, so ReqLLM's timeout budget calls `Req.request/1`
  directly in the calling process (`timeout_budget.ex:48`) rather than in a
  task on the shared `ReqLLM.TaskSupervisor` (`:101-103`);
- `base_url:` always passed, as the host's `:base_url` or else the built-in
  module's `default_base_url/0`; ReqLLM fills an absent one from `:req_llm`'s
  per-provider application configuration or the model catalog
  (`provider/options.ex:1147-1171`), and an explicit option wins
  (`Keyword.put_new_lazy`). A credential-bearing provider accepts only an
  `https` URL; only credential-free Ollama may use `http`;
- `receive_timeout: :infinity`; the cleanup owner, not a dependency timer,
  maps the request's committed absolute system-millisecond deadline to native
  monotonic time with one frozen `native_offset =
  System.time_offset(:native)` and the companion's shared exact formula
  `System.convert_time_unit(deadline_ms, :millisecond, :native) -
  native_offset`. Positive native remainders round upward to
  milliseconds; zero or negative means expired. Every wait and the request's
  `pool_timeout` is capped at 1,000 ms, so no unsigned-64-bit value reaches a
  relative timer. The caller reports exactly
  `{caller_pid, ref, result, finished_at_native}` with its native monotonic
  completion timestamp;
  at expiry one zero-wait receive admits only an already-queued matching result
  stamped no later than the same deadline, otherwise the owner kills the caller
  and refuses every result;
- `max_retries: 0`, retained as defense in depth: every chat path attaches
  ReqLLM's retry step after `Req.new/1` (`providers/anthropic.ex:388`,
  `providers/openai.ex:703`, `providers/ollama.ex:134`,
  `provider/defaults.ex:640`), which overwrites Req's `retry:` option and can
  recursively rerun a request (`deps/req/lib/req/steps.ex:1807-1818`); the
  owner-side dispatch grant below is the authoritative at-most-once fence;
- `req_http_options:` containing the `Loopex.LLM.ReqLLM.OneShotHTTP1` adapter,
  `redirect: false`,
  `finch: [name: Req.Finch, pool_tag: tag, pool_timeout: bounded_timeout]`,
  where `bounded_timeout` is the owner-computed value from 1 through 1,000 ms,
  and bounded
  credential-free Loopex call context in the exact shape
  `finch_private: %{loopex_one_shot: {owner_pid, tag, route_fingerprint}}`,
  where the fingerprint binds the provider, planned surface, POST method,
  normalized explicit base URL, exact final path and nil query before credential
  resolution. All four chat paths
  pass these options to `Req.new/1`
  (`providers/anthropic.ex:199-235`, `providers/openai.ex:435-484`,
  `provider/defaults.ex:255-284` for Ollama and OpenRouter). Anthropic and
  OpenAI try to add their receive-timeout-derived `pool_timeout` to the named
  Finch options, but `merge_finch_options/2` preserves the explicit nested
  value (`provider/defaults.ex:649-667`); Ollama and OpenRouter also receive the
  same exact nested list unchanged;
- no `:cache` option, so ReqLLM's response cache is disabled
  (`cache.ex:125-128`).

Before resolving a hosted credential, the caller uses one exact credential-free
option list for planning: `max_tokens`, `tools`, `total_timeout: :infinity`,
`receive_timeout: :infinity`, `max_retries: 0`, `base_url` and the complete
`req_http_options` above, in that order. Ollama generation uses that same list.
A hosted generation prepends only `api_key: resolved_value` after the final
guard and gate-token verification.
`ReqLLM.plan(model_spec, :chat, planning_options)` receives the credential-free
list and never the key (`deps/req_llm/lib/req_llm.ex:420-423`); the literal
`:chat` matches the `generate_text/3` path, and neither option list contains an
operation or `cache` member.

**The call-owned pool.** Before the caller starts, the cleanup owner creates
`tag = make_ref()` and `pool = Finch.Pool.new(base_url, tag: tag)`. A reference
is a valid tag and is part of the `{scheme, host, port, tag}` pool identity
(`deps/finch/lib/finch/pool.ex:28-48`, `:80-114`, `:136-143`), so concurrent
calls to one origin do not share a pool and no per-call atom is created.

The owner itself `spawn_monitor`s one request-free **pool-lifecycle root** and
records that PID, monitor and gate registration before sending it permission to
initialize. The root traps ordinary exits and is the parent of every process it
starts; it never exits until each registered descendant is `DOWN`. It performs
every synchronous or fallible pool operation while the owner stays in its
receive loop. This owner-created, start-blocked root removes the interval in
which a helper could create an unregistered supervisor. The root monitors the
cleanup owner; owner `DOWN`, or the gate's explicit unwind message after that
`DOWN`, starts the same idempotent graceful teardown from every setup phase.

The root first requires both the duplicate worker-registry lookup
`Registry.lookup(Req.Finch, Finch.Pool.to_name(pool))` and the unique
pool-supervisor-registry lookup
`Registry.lookup(Finch.Pool.Manager.supervisor_registry_name(Req.Finch),
Finch.Pool.to_name(pool))` to be `[]`, then builds
the public `Finch.Pool.child_spec/1`, starts a fresh anonymous
`DynamicSupervisor`, and starts the user-managed pool child beneath it. That API
exists for independently managed pool lifetimes (`pool.ex:145-190`) and returns
the pool-supervisor child specification (`pool/manager.ex:187-198`). The root
synchronously registers the anonymous supervisor and each later returned PID
with the owner and receives its acknowledgement before continuing. It then requires
`Supervisor.which_children(pool_supervisor)` to be exactly
`[{1, owned_worker_pid, :worker, [Finch.HTTP1.Pool]}]`, the full duplicate-key
worker-registry lookup to equal exactly
`[{owned_worker_pid, Finch.HTTP1.Pool}]`, and the unique supervisor-registry
lookup to equal exactly one entry whose PID is the recorded pool supervisor and
whose value is `{Finch.HTTP1.Pool, 1, expected_pool_config}`.

The complete setup must produce that exact result before the earlier of 1,000
ms and the call deadline. Only then does the owner start the caller. A stop
remains answerable during registry access,
`Finch.Pool.child_spec/1`, root start, `DynamicSupervisor.start_child/2` and
inspection. Before dispatch, cancellation or setup expiry tells the lifecycle
root to unwind and awaits it; the root stops and awaits every descendant before
it exits. The owner never sends it an untrappable kill. If a dependency call
does not return so the root cannot prove its unwind, the path remains
`cleanup_unproved`, returns no provider result or successful stop
acknowledgement, retains the credential lease and poisons both lease modes rather
than treating the root's death as proof. The owner also awaits every PID already reported and
requires both Loopex-created registry entries gone before returning a fixed
pre-dispatch refusal or stop acknowledgement. A child-start failure, partial
start, missing worker or unexpected result follows the same path.

For normal teardown the same lifecycle root performs the bounded graceful
anonymous-supervisor stop while the owner remains responsive. The owner
requires the lifecycle root, pool supervisor and worker `DOWN`, plus disappearance of
both Loopex-created registry entries. It never adopts or stops a foreign
registry entry. A foreign same-tag entry in either registry before or after
owned startup makes the exact-list check fail; the call tears down its own root and refuses. Host code
that inserts one after the final dispatch check is trusted same-VM interference,
but it cannot reroute the direct PID call.

The pool's fixed options are `protocols: [:http1]`, `size: 1`, `count: 1` and
`start_pool_metrics?: false`. The only permitted plain HTTP pool is
credential-free Ollama. An HTTPS pool also sets exactly
`conn_opts: [transport_opts: [reuse_sessions: false, session_tickets: :disabled,
keep_secrets: false]]`; an HTTP pool omits `conn_opts`. Finch passes the outer
`conn_opts` to Mint, whose HTTP/1 connector reads SSL options only from the
nested `transport_opts`
(`deps/finch/lib/finch/http1/conn.ex:8-17,48-53`;
`deps/mint/lib/mint/http1.ex:167-177`).
Mint merges explicit transport options over its defaults
(`deps/mint/lib/mint/core/transport/ssl.ex:449-456`), and defaults TLS 1.2
session reuse to true (`:561-573`), so the explicit values are part of the
credential-lifetime contract: no TLS 1.2 session is registered for reuse, no
TLS 1.3 resumption ticket is retained, and no key-log secret is kept. The
two-toolchain source trace and TLS witnesses pin those OTP behaviours.

`Req.Finch`, started by Req's application (`deps/req/lib/req/application.ex:7-14`),
supplies only the duplicate worker registry and unique pool-supervisor registry
in which the user-managed pool registers. The normal
Finch route looks up a request's full `{scheme, host, port, tag}` identity and,
when it is absent, automatically starts a replacement under the named Finch
(`deps/finch/lib/finch/pool/manager.ex:94-139`; selected from
`deps/finch/lib/finch.ex:1011-1019`). This adapter never uses that route. Neither
the default `Req.Finch` pool nor `ReqLLM.Finch` carries the call. The tagged pool
is stopped after the call and its connection cannot be reused or retained by a
pool. A checked-out socket and its OTP TLS controller can still drain
asynchronously under the cleanup rule below.

**The one-shot Req adapter.** Req invokes a module adapter only after request
steps have produced the final request (`deps/req/lib/req/request.ex:1035-1067`).
`OneShotHTTP1.run/1` validates the final normalized origin, the exact
`Req.Finch` name and tag, the permitted `pool_timeout`, and the absence of
`connect_options`, proxy, Unix-socket, plug, alternate `into` or other routing
substitution. It also requires compression disabled and no final
`accept-encoding` header except `identity`. It requires the exact
`finch_private` shape, removes that Req-only option before building transport
data so Finch telemetry never receives the private owner context or PID, and
asks the owner synchronously to claim dispatch from the expected caller. The
first claim sends one inspection command to the already registered
pool-lifecycle root while the owner remains responsive; it starts no second
helper. The owner grants only when that root confirms the recorded PID is
alive, the recorded pool supervisor still reports exactly
`[{1, recorded_pid, :worker, [Finch.HTTP1.Pool]}]`, the full-tag worker registry
is still exactly `[{recorded_pid, Finch.HTTP1.Pool}]`, and the unique
supervisor registry is still exactly one entry for the recorded pool supervisor
and expected pool configuration. The grant returns that PID
and atomically marks dispatch. An inspection timeout, lifecycle-root loss or
mismatch refuses without a network write and starts or joins the same
cooperative root teardown. If the root is stuck in a dependency call, cleanup
remains unproved; the owner does not return a fixed refusal while that root is
live. It never selects through
`Finch.find_pool/2`, whose duplicate-registry strategy may choose a random
entry (`pool/manager.ex:116-128`). Granting marks the call
`dispatched_or_unknown` before any socket write.

The adapter then builds a `%Finch.Request{}` directly from the final Req method,
URL, headers and already encoded non-streaming body with
`Finch.build(method, url, headers, body, [pool_tag: tag])`, and calls
`Finch.HTTP1.Pool.request/6` on that exact PID, literal name argument
`Req.Finch`, and exactly
`[pool_timeout: bounded_timeout, receive_timeout: :infinity,
request_timeout: :infinity]`. Final validation refuses `:pool_strategy`, a
different timeout or any other Finch build/request option. This avoids the
locked HTTP/1 pool's otherwise implicit 15,000 ms receive timeout
(`deps/finch/lib/finch/http1/pool.ex:42-45`). That exported
`Finch.Pool` callback performs the synchronous caller checkout
(`deps/finch/lib/finch/http1/pool.ex:42-74`). It does not consult a registry or
pool manager. If the worker dies or its supervisor restarts it after the grant,
the call to the old PID fails; no replacement can receive the request. The
adapter never calls `Req.Finch.run/1`, `Finch.request/3`, `Finch.stream/5` or
`Finch.stream_while/5`, because each would perform the auto-starting lookup.

For that direct call, the adapter implements the small response accumulator and
error normalization that the locked `Req.Finch` adapter would otherwise supply
(`deps/req/lib/req/finch.ex:286-302`, `:338-360`). It sets
`accept-encoding: identity`, rejects a content-encoding header before retaining
body data, and accumulates at most 8,388,608 response-body bytes. When another
  chunk would cross the limit, its Finch callback returns
  `{:halt, accumulator_with_private_overflow_sentinel}`, which closes an HTTP/1
  connection while preserving the sentinel
  (`deps/finch/lib/finch.ex:723-730`). The adapter restores the
original Req `into` and private context only to the returned Req request, so a
ReqLLM retry or redirect reaches the same owner fence. It replaces an overflow
with the fixed `:loopex_response_too_large` transport sentinel and an encoded
response with `:loopex_response_encoding_unsupported`; the caller maps their
private diagnostic names `model_response_too_large` and
`model_response_encoding_unsupported` to the public
`{:dispatched_or_unknown, "model_call_failed"}` form. The caller never accumulates or
decompresses an unbounded response. Every later adapter invocation is refused
before network activity. The non-secret tag and exact pool-worker PID are
visible to Finch telemetry; the private owner PID is not. Host code that
deliberately tampers with the same VM's processes or request between validation
and dispatch remains trusted host code. After the direct pool call returns or
raises, the adapter asks the owner to stop the tagged pool and waits for proved
owned-subtree teardown before it returns or reraises. That is the early
transport-completion path, not the only cleanup trigger: once the anonymous
root exists, every later pool-child failure or partial start, terminal caller
reply, refusal, spawn failure or exit starts or joins the same teardown. The
owner's first atomic claim marks dispatch and returns the exact recorded worker
PID; every later claim is refused by the fence without performing a pool lookup
or failing incidentally during dispatch. An
untrappable caller kill skips the adapter path, so the owner retains the
fallback described below.

**Why HTTP/1 only.** Both ways of reaching HTTP/2 through the locked Finch
fail this adapter's contract. Its multiplexed HTTP/2 pool can send again below
Req's retry control when a connection turns read-only mid-upload
(`finch/http2/pool.ex:562`, `finch.ex:824-830`). HTTP/2 negotiated by ALPN on
its HTTP/1 pool sends the whole body in one `Mint.HTTP.request/5` call
(`finch/http1/conn.ex:118-124`), which Mint refuses above the 65,535-byte
initial window (`mint/http2.ex:1496-1507`); ReqLLM guards the same case on its
streaming path (`req_llm/streaming/finch_client.ex:333-359`). HTTP/2 is future
work for a transport that removes both limits.

The kernel's own deadline bounds the call. The inline model never reaches
ReqLLM's catalog lookup or its unverified-model warning, which only the string
lookup path emits (`req_llm.ex:735-750`).

**Guards.** Composition checks the host-global guards. The cleanup owner checks
them again before it casts or starts the pool, the caller checks them before
`ReqLLM.generate_text/3`, and the one-shot adapter validates the final request
at the dispatch boundary:
- The fixed model-prefix mapping chooses the existing provider atom and expected
  module (`:ollama`, `:openai`, `:anthropic` or `:openrouter`) without consulting
  ReqLLM state. The pre-start global guards and guarded ReqLLM hygiene decision
  run next. Only after that decision initializes or verifies the application does
  `ReqLLM.provider(provider_atom)` have to return `{:ok, expected_module}` with
  the exact module in the table above (`req_llm.ex:260-266`). The default address
  is then read directly from that verified module. ReqLLM's registry lets a later
  registration replace a provider (`providers.ex`), and generation resolves the
  module at call time, so the cleanup owner and caller repeat the registry check.
- `System.get_env("SSLKEYLOGFILE")` is unset. Finch falls back to it when no
  `:ssl_key_log_file` is given and opens it while casting pool options
  (`deps/finch/lib/finch.ex:550-558`). When Loopex must start ReqLLM and Req,
  this guard runs before that application start. With host-started dependencies,
  the guard prevents Loopex's call-owned pool from opening or appending to the
  destination but cannot undo a file open that happened earlier. The fixed
  `keep_secrets: false` means the locked OTP returns no key-log material.
- `Application.get_env(:req, :default_options, [])` is `[]`. `Req.new/1` merges
  it into every request, plugins included (`deps/req/lib/req.ex:475-479`,
  `:1359-1361`), so any value could add an `Authorization` header, a response
  cache, a plugin, another pool, `into:` or a transport.
- The base URL is a non-empty valid UTF-8 absolute URL of at most 65,536 bytes,
  parsed by one private byte parser rather than by provider code. Its exact
  grammar is `<scheme>://<host>[:<port>][<path>]`; any other authority syntax
  refuses. The literal lowercase scheme is `https` for a credential-bearing
  provider, or `http` or `https` for Ollama. A host is either canonical dotted
  IPv4—four decimal octets from 0 through 255, with no leading zero except
  `0`—or an ASCII DNS name of at most 253 bytes: one or more dot-separated
  1-to-63-byte labels, each beginning and ending with an ASCII letter or digit
  and containing only those bytes or `-`. DNS bytes normalize to lowercase; a
  trailing dot, empty label, bracketed IPv6, Unicode, percent escape and user
  information refuse. An optional port is canonical decimal with no leading
  zero, from 1 through 65,535; explicit `:80` on `http` and `:443` on `https`
  normalize away, and omission has that same effective port. The path is empty
  or slash-prefixed non-empty segments made only of RFC 3986 unreserved ASCII
  bytes; query, fragment, percent escapes, backslashes, repeated interior
  separators and literal `.` or `..` segments refuse. All trailing slashes,
  including a lone root slash, are removed before the same canonical string is
  passed to the inline model, pool and ReqLLM. A library URI parse may only
  verify that canonical result; it does not admit or normalize input.
  The exact POST route appended to that prefix is `/chat/completions` for
  Ollama and OpenRouter, `/v1/messages` for Anthropic, and either
  `/chat/completions` or `/responses` for the OpenAI surface. Before reading a
  key the caller derives the Anthropic/OpenAI surface with credential-free
  `ReqLLM.plan(model_spec, :chat, planning_options)` on the exact planning list
  above; Ollama and OpenRouter use
  their fixed rows because RequestPlan does not admit them. The owner retains
  the resulting fingerprint and requires the adapter's final Req method, URI,
  effective port, path, nil query and, where present, ReqLLM plan metadata to
  match it at the atomic dispatch claim. The pool is fully started before
  ReqLLM runs; the final request must also use the one-shot adapter, exact fixed
  Finch name and reference tag, and none of the routing substitutions the
  adapter refuses.
A failed guard at composition refuses `{:composition, :provider_module_replaced}`,
`{:composition, :ssl_key_log_enabled}` or
`{:composition, :req_default_options_unsupported}`, and an invalid address
refuses `{:composition, :provider_base_url_unsupported}`. The caller repeats
those checks before entering `ReqLLM.generate_text/3`, where a refusal is
`{:error, {:not_dispatched, "model_call_failed"}}`. A mismatch found by the
one-shot adapter is still refused before network activity, but is reported
conservatively as `dispatched_or_unknown` because the ReqLLM call has begun.
The prefix maps through the fixed table, never through `String.to_atom/1`. A
host mutation after a check is same-VM trusted-code interference; the final
adapter still closes the request-routing path it can validate.

**No streaming.** The adapter delivers the model's reply whole and reports no
progress deltas. Deltas are transient progress, never session truth, and the
streaming conformance suite already admits an adapter that declares
`streamed: false` with no deltas. Locked `generate_text/3` discards the outer
`Req.Response` headers when it returns the decoded `%ReqLLM.Response{}`. The
one-shot Req adapter therefore records only Anthropic's `request-id` or
OpenAI's `x-request-id`, as applicable, in the same sensitive caller's process
dictionary under the per-call tag; Ollama and OpenRouter record no header. The
caller deletes the key before generation and in an `after` clause on every exit.

On an exact successful response struct, metadata contains `usage` (or `%{}`),
`finish_reason`, that zero-or-one-element header list, and `error` only when the
response error is non-nil. The shared completion rule rejects that error and
`:error`, `:incomplete` or `:cancelled`; the shared tool-call validator reads
each buffered `%ReqLLM.ToolCall{}` that locked ReqLLM exposes; requires
`ToolCall.builtin?/1` and `provider_native?/1` both false; rejects atom- or
string-keyed error metadata still visible there; requires a non-empty binary id
and name and exact type `"function"`; decodes its binary argument JSON with
repair disabled; and accepts only a map. A visible provider-executed builtin or
provider-native call is not a replayable application call, fails the whole
ordered list and never becomes a local core tool request. Invalid binary JSON,
`null`, arrays and incomplete JSON that reach this seam do the same. ReqLLM's buffered builders run
before the seam: depending on the provider path they can generate a replacement for a missing id,
normalize missing, nil, empty or unsupported arguments to literal `"{}"`, force
type `"function"`, omit a malformed call, and remove earlier error metadata
(`provider/defaults/response_builder.ex:164-206`, `tool_call.ex:93-103`,
`provider/defaults.ex:1556-1571`,
`providers/openai/responses_api.ex:2415-2427`). Those erased distinctions are
not reconstructible here. The builtin flag remains visible on
`ToolCall.new_builtin/3`; an existing `%ToolCall{}` can retain provider-native
metadata (`tool_call.ex:106-178`,
`providers/openai/responses_api.ex:2322-2337`). The mapper accepts a visible
literal `"{}"` as an empty object and an omitted call executes nothing; only a
visible application call passes tool resolution, schema validation and policy. Text is
`ReqLLM.Response.text(response) || ""`; and the shared reply builder receives
delta count zero. Any other return, malformed response, rejected completion or
dependency-visible malformed tool call is the fixed started-call failure.
Before the mapped reply leaves the sensitive
caller, a recursive check of every provider-controlled binary in that
reply—including assistant text, tool-call fields and
`provider_response_id`—rejects an exact occurrence of the resolved credential
and substitutes the fixed `dispatched_or_unknown` failure. This does not claim
to recognize a transformed or encoded derivative a malicious provider invents.

**Error classes:**
- A refusal met before `ReqLLM.generate_text/3` is called is returned, never
  raised, as `{:not_dispatched, "model_call_failed"}`. That covers model build,
  a missing credential, a failed guard, context, tools and options, and an
  elapsed deadline.
- The locked process-local provider-lifetime registration and activation
  interval is the conservative exception. If core interrupts it, the callback
  emits no adapter result; the coordinator uses its existing provider-call
  failure or cleanup-unproved path. It is not retried even though the adapter
  authorized no network dispatch. Exact `:unmanaged` from
  `ProviderLifetime.starter/0` refuses before a candidate exists. Exact
  `:unmanaged` or `{:error, :provider_resource_refused}` from
  `ProviderLifetime.register/2`, with proved candidate `DOWN`, remains the
  pre-call `not_dispatched` form.
- Every return or raise from that call, `{:error, _}` and a non-2xx status
  included, is `{:dispatched_or_unknown, "model_call_failed"}`, as the companion
  classifies a started call
  (`apps/loopex_llm_reqllm/lib/loopex/llm/req_llm.ex:416-453`, citing ADR 0018),
  because the request may already have reached the server.

<a id="technical-adr-0039-tree"></a>
#### The Per-Call Process

Concept: [Context and decision](0039-ephemeral-embedded-profile.md#concept-adr-0039-decision).

Each call has an explicitly owned provider lifetime:
1. **The owner candidate and registered cleanup owner.** In the callback process,
   `complete/3` first calls `ProviderLifetime.starter/0`
   (`provider_lifetime.ex:35-45`). Exact `:unmanaged`
   returns fixed `not_dispatched` without creating a proxy or child, reading a
   credential, starting a pool or poisoning admission. Only
   `{:managed, starter}` proceeds. The callback retains a fresh one-use
   activation token. The opaque starter is passed to one **unlinked**, monitored
   start proxy with a private reference and absolute start deadline equal to the
   earlier of the model-call deadline and 1,000 ms from start. The proxy monitors
   the callback, reports ready and invokes
   `ProviderLifetime.start_child(starter, child)` only
   after the callback's exact grant, the same transferable-starter pattern the
   locked companion uses (`provider_bridge.ex:69-79`, `:216-227`). The child
   closure captures only callback and
   proxy PIDs, the reference and deadline—never the activation token, a model
   request, option, credential, result or the starter—and creates an
   authority-free owner candidate. The candidate marks itself sensitive,
   monitors callback and proxy,
   checks the start deadline, reports its PID directly to the callback and
   remains inert. The proxy provisionally reports the exact start return and
   waits for correlated `finish`.

   The callback accepts only matching proxy and candidate reports in either
   order, installs the candidate monitor and sends `finish`. On success the proxy
   sends the candidate exact `proxy_retiring` before it exits normally.
   Same-sender ordering lets the candidate accept normal proxy `DOWN` only after
   that notice; any earlier, abnormal or mismatching proxy `DOWN` ends it without
   work. The callback also requires exact normal proxy `DOWN`, then sends
   `registration_pending` with the exact private `stop_reference` that the later
   core registration will use. The candidate validates and stores it before
   acknowledging. That acknowledgement cancels the short start expiry but grants
   no request, credential, gate, root, pool, caller or dispatch authority.

   The callback alone then enters the locked, process-local
   `ProviderLifetime.register/2` registrar. It cannot add a local timeout. Core
   first asks the provider worker to retain the candidate and only afterwards
   asks the provider guard to register it (`session_coordinator.ex:4172-4195`).
   Forced cleanup can discover a live callback's pending-resource slot or a
   registration already queued at that guard (`session_coordinator.ex:4776-4849`),
   but normal stop kills the callback before inspecting the guard's registered
   resource (`session_coordinator.ex:4917-4919`, `:6046-6049`). Therefore the
   worker-retained/guard-unregistered interval cannot provide a strict candidate-
   `DOWN`-before-model-settlement guarantee without changing core.

   On callback `DOWN` before `begin`, the candidate permanently disables
   activation, performs one zero-wait receive for an already queued matching core
   stop, acknowledges and exits if that message is present, and otherwise exits
   without waiting. If guard registration committed, locked core observes the
   missing registered stop acknowledgement as `provider_cleanup_unproved`
   (`session_coordinator.ex:4621-4667`). If it did not commit, core may report its
   pre-registration model result with no registered provider-resource obligation
   before the authority-free candidate takes its
   first scheduled protocol step and exits. That result proves no call input or
   provider-call authority was released; it does not prove candidate `DOWN`. The
   candidate selects no fixed `not_dispatched` result, and no registration
   fallback timer exists. It remains a child of the session worker supervisor,
   so the complete session-subtree proof still reaps it before public session
   cleanup can be proved.

   Only exact `{:managed, retainer_pid, cleanup_grace_ms}` returned from
   `ProviderLifetime.register/2` converts the candidate into the cleanup owner and
   lets the callback send `activation_prepare` with the one-use token and that
   exact tuple. The owner validates the tuple, monitors the retainer, records the
   token and acknowledges preparation while remaining inert. The callback must
   then send distinct `begin` with that token; only its first exact receipt
   authorizes gate, root, pool, caller, credential or dispatch work, and the owner
   acknowledges before consuming call inputs. Callback `DOWN` before `begin`
   follows the zero-wait rule above; after `begin`, the registered owner enters
   its ordinary cleanup protocol. A missing, late or malformed preparation or
   `begin` acknowledgement emits no adapter result and remains under the same
   core interruption and cleanup semantics.

   The registered cleanup owner traps exits, never calls ReqLLM and never blocks,
   so it answers a stop at any moment. Its durable working state holds only the
   call identity, dispatch state, fixed pool identity and process or monitor
   references. After the caller has mapped and exact-credential-checked its
   response, the owner transiently holds that bounded mapped reply or one fixed
   failure class while it ends and awaits the caller and forwards the value to
   `complete/3`; it never holds the credential, raw ReqLLM response or raw
   failure reason. It is marked sensitive and matches exits only by shape, never
   retaining or reporting an exit reason.

   An exact returned start error followed by exact normal proxy `DOWN` and no
   candidate report creates no candidate and returns fixed `not_dispatched`. A
   missing, late, malformed or mismatching report, abnormal or missing proxy
   `DOWN`, or
   start expiry makes the start unknown. The callback commits the shared poison
   latch first, withholds activation, kills each known proxy or candidate and
   waits at most 1,000 ms for known `DOWN` values before returning fixed
   `not_dispatched`. Killing the proxy cannot retract a request already queued in
   `Task.Supervisor.start_child/3`; an undisclosed candidate may appear later,
   but it sees dead proxy or callback, or the expired deadline, and exits without
   authority. Callback `DOWN` while the proxy is blocked likewise leaves only
   that request-free, self-fencing path; when the proxy next runs, its callback
   monitor makes it retire. Late messages are ignored and never activate the
   candidate. Returned `:unmanaged` or `{:error, :provider_resource_refused}` from
   `register/2` plus exact candidate
   `DOWN` is clean `not_dispatched`; a missing candidate `DOWN` first poisons
   admission. On `{:error, :provider_guard_unavailable}`, a registrar raise or a
   malformed return, the callback kills and awaits the known candidate under the
   same 1,000 ms proof and poison-on-missing-`DOWN` rule, then exits with the
   fixed private reason `:provider_lifetime_registration_failed`. That exit stays
   outside the adapter's returned-error mapping; locked core catches and discards
   it as `{:error, :provider_call_failed}` (`session_coordinator.ex:4149-4152`),
   preserving the coordinator-owned conservative classification. Any fault
   after exact managed registration instead uses core's registered-resource
   stop, acknowledgement and `DOWN` proof and never substitutes fixed
   `not_dispatched` for unproved cleanup.

   After this start proof, only exact `:unmanaged` or
   `{:error, :provider_resource_refused}` takes the adapter-owned refusal branch:
   it sends the just-started candidate an untrappable `:kill` and waits for its exact monitor
   `DOWN` for at most 1,000 ms. A registration refusal has not disclosed a
   cleanup grace and the start-blocked candidate has no resource or gate grant,
   so this private reap bound is not cooperative cleanup. Exact `DOWN` returns
   fixed `not_dispatched`. A missing `DOWN` returns the same fixed result, logs only
   PID/monitor shape, poisons both ephemeral modes until VM restart and admits
   that the authority-free candidate may remain start-blocked until scheduled. No
   pool, caller, credential read or dispatch begins before registration succeeds.
   The guard-unavailable, raised and malformed forms use that fixed private exit,
   never a returned adapter `not_dispatched` value.
2. **The pool-lifecycle root.** The owner creates and monitors this request-free
   process directly, registers it with the gate under the hosted credential
   lease or the enclosing owner's local-call capability, and only then lets it
   start.
   It performs every synchronous pool setup, both the setup and dispatch-time
   inspections, and every graceful teardown operation described above. It
   owns the anonymous supervisor, traps ordinary
   exits, and exits only after every registered descendant is `DOWN`. The owner
   stays in its receive loop and cancels setup cooperatively; an unresponsive
   root leaves cleanup unproved rather than being killed and mistaken for
   descendant cleanup.
3. **The caller.** The two provider classes use distinct admission paths after
   exact pool setup. For a hosted call, the owner asks the gate to create a
   generic request-free caller under the held credential-call lease. In one
   serialized gate turn, the gate spawns it start-blocked, installs its monitor,
   records its PID under that lease and returns the PID plus a one-use start
   token; no credential-capable caller is ever alive outside the gate census.
   For Ollama, the cleanup owner has already registered itself under the
   enclosing owner's local-call capability. It directly `spawn_monitor`s the
   generic caller start-blocked; that caller monitors both the cleanup owner and
   gate and can do no work until the owner registers its PID under the same
   local-call record and receives a one-use local start token. Owner or gate
   loss before that acknowledgement makes it exit. The owner sends call inputs
   only after the applicable acknowledgement. The caller's first action sets
   `Process.flag(:sensitive, true)` and `Logger.put_process_level(self(), :none)`
   (Elixir's API; OTP's `logger` exports no per-process level setter), then
   waits start-blocked. It verifies the one-use token and its PID-bound hosted
   lease or local-call registration. It then excludes itself from Loopex trace
   sessions through the runtime's trace capability
   (`Loopex.Trace.exclude_self/2`, `trace.ex:56`) with the adapter-owned exact
   one-MFA inventory
   `[{Loopex.LLM.ReqLLM.InProcess.Caller, :run, 1}]` and requires exact `:ok`.
   The `run/1` argument is credential-free, and no other adapter function
   receives or returns the resolved bytes. An unavailable or malformed
   exclusion result reads no credential, accepts no connection and returns
   fixed `not_dispatched` through owned teardown. The caller then checks the
   guards. Only the
   hosted path then reads and validates its credential variable against the
   1-to-65,536-byte bound; Ollama reads no credential and has no credential
   quarantine. The caller calls
   `ReqLLM.generate_text/3` inside a `try` that
   catches every raise, throw and exit, maps and credential-checks the response,
   sends the owner either the reply or a fixed error class, and then blocks
   until released. A forced teardown may end it with an untrappable kill.
4. **The tagged pool subtree.** Under the lifecycle root, an anonymous
   call-owned `DynamicSupervisor` contains only the user-managed Finch pool
   supervisor and its one lazy HTTP/1 worker. The lifecycle root synchronously
   registers each PID with the owner before proceeding, and the owner records
   and monitors the exact lifecycle-root, anonymous-supervisor, pool-supervisor
   and HTTP/1 worker PIDs before starting the caller through the applicable
   hosted or local admission path. The shared `Req.Finch`
   registry is infrastructure, not part of this subtree and not a request
   owner.

The caller is the only process that can return a provider result to Loopex:
the reply reaches the coordinator only through the owner, and only from the
caller.

**Cleanup.** Teardown is idempotent and owner-gated. Once the lifecycle root
exists, every later pool-child failure or partial start, terminal caller reply,
refusal, spawn failure or exit starts or joins it; no result or fixed error
returns merely because the pool or one-shot adapter was never reached. On the
transport path, after the Req adapter's direct worker call and checkout return,
it asks the owner to have the lifecycle root start teardown early and waits.
The owner requires the lifecycle root, anonymous supervisor, pool supervisor
and worker `DOWN` messages, plus disappearance of both tagged registry entries,
before releasing that adapter. The
caller then maps the response, sends the owner its reply and blocks. On a
pre-adapter failure it sends only the fixed reply and blocks, and the owner
performs the same proof. In either case the owner releases or kills the caller,
waits for its `DOWN`, and only then sends the fixed reply to the waiting
`complete/3` callback. The registered owner does **not** exit at that point: it
remains responsive while `complete/3` returns the model result to core. Core
then sends the coordinator's resource-stop message; because cleanup is already
proved, the owner sends the exact stop acknowledgement and exits only after
that handshake. This reply-before-stop two-stage order satisfies the
coordinator's requirement that the registered resource remain alive through
resource cleanup (`session_coordinator.ex:4397-4435`, `:4508-4513`). On the coordinator's
resource stop message
(`session_coordinator.ex:4627-4634`) or a deadline, it first makes every result
inadmissible, kills the caller and waits for `DOWN`, then starts or continues
the graceful lifecycle-root stop and proves the applicable root, owned-child and registry conditions
before acknowledging `{:loopex_provider_resource_stopped, stop, self()}`
(`:4641`), then exits. It never kills the lifecycle root or pool supervisor,
because that could bypass child termination. A missing `DOWN`, timed-out
graceful stop or remaining tagged registry entry withholds the reply or acknowledgement, and the coordinator's existing
unproved-cleanup path applies (`:4646-4652`).

**What the acknowledgement covers, and what it does not.**
- **The request runs in the caller.** The pool checks its single connection out
  to the caller, which performs the request's socket I/O
  (`finch/http1/pool.ex:42-74`). Killing the caller stops further I/O. The
  owner then stops the pool only after caller `DOWN`, closing the race in which
  a still-running caller could invoke its recorded worker. The adapter never
  performs a lookup that can materialize a replacement. Bytes
  already handed to the operating system or a TLS sender may still leave; the
  call was already `dispatched_or_unknown`, so this creates no retry.
- **One network dispatch.** HTTP/1 has no lower-level read-only redispatch, and
  the owner's atomic claim permits only the first invocation of the Req
  adapter to call the recorded worker. `max_retries: 0` and `redirect: false` remain secondary
  controls. A transport failure before any bytes were sent can therefore be
  conservatively classified unknown, but it cannot cause a second send.
- **Owned teardown and transport drain are different frontiers.** NimblePool
  sends check-in asynchronously (`deps/nimble_pool/lib/nimble_pool.ex:461-471`),
  and its termination callback closes only idle resources (`:732-741`). A root
  stop can therefore race a check-in or the pool's caller-`DOWN` cancellation.
  If the pool handles that cancellation first, it removes and closes the worker
  (`:669-675`, `:770-794`; `deps/finch/lib/finch/http1/pool.ex:287-293`); if root
  shutdown wins, the checked-out socket and its OTP TLS controller still close
  from caller ownership asynchronously. The acknowledgement proves the caller,
  owned root and pool gone and both tagged registry entries removed. It does not prove
  that checked-out transport has already finished. The release witness bounds
  server-observed EOF and TLS-controller drain after caller `DOWN`. No guarantee
  depends on a `Connection: close` header or peer behaviour, and the fixed TLS
  options prohibit reusable session state and key-log secrets.
- **Credential exposure is named.** During a call the request's bytes, key
  included, pass through the caller, TLS state for an `https` address and
  Finch telemetry metadata (`finch/http1/pool.ex:47-49`), which any handler the
  host installs can copy. After owned cleanup there is no tagged pool, reusable
  TLS state or result path. A checked-out socket and its OTP TLS controller may
  still drain. Under isolated release conditions the witness requires both gone
  within 5,000 ms of caller `DOWN`; runtime cleanup does not wait for or prove
  that threshold. They, the host environment and a host-made copy are outside
  the owned-lifetime proof and have the host-VM exposure the vision amendment
  accepts.

Nothing any of this holds can reach the session: the result path ended with
the caller, and the call is already `dispatched_or_unknown`. Those copies, and
whatever a host's handler copies, are the exposure the vision amendment
names.

**What the witness pins.** On both toolchain pairs, an isolated VM first warms
only shared Req and SSL infrastructure, then records every client process and
port created while one tagged call is stalled. Normal completion, stop and
deadline must leave the caller, lifecycle root, anonymous supervisor, pool
supervisor and exact recorded worker dead and
both tagged pool registry entries absent before a provider result or successful cleanup
acknowledgement. Separately, under the isolated release witness the server must
observe EOF and every call-created TLS controller must drain within 5,000 ms of
caller `DOWN`; the witness records that interval rather than treating it as
part of the acknowledgement or a runtime proof.
A seam that fails pool-child startup after the root
exists, including after an owned child or either registry entry appears, must leave
every owned child and the root dead and every Loopex-created entry absent before
the refusal returns. When the credential or a guard changes after pool
creation, ReqLLM request preparation fails before the one-shot adapter, the
final route is refused before delegation, or caller spawn is made to fail, the
same applicable process and registry proof holds and no connection is accepted.
The witness records dependency and TLS lifecycles but does not
assert a fixed process count or universal heap inspection. Separate TLS
1.2-only and TLS 1.3-only servers prove two sequential calls do not resume a
session. Two concurrent same-origin calls prove distinct tags and that cleaning
one does not disturb the other.

**Host hygiene.** `ReqLLM.Application.start/2` reads `:load_dotenv` (default
`true`) and loads `.env` from the working directory (`application.ex:25-31`).
`loopex_llm_reqllm` declares `req_llm` and its direct exact `req` and `finch`
dependencies with `runtime: false`. They remain compile-time and code
dependencies but none enters the edge application's automatic start list, so
every build carries the three modules without starting their applications
before Loopex's guards. The companion and a host OTP release list all three as
`:load`, as the developer guide states. The companion worker already starts
ReqLLM and its dependencies itself after its settings
(`provider_worker.ex:43`, `:78-79`).

**The start step,** run by every ephemeral composition. Before it can call
`Application.ensure_all_started(:req_llm)`, it requires `SSLKEYLOGFILE` unset
and `:req` default options empty, and composition refuses
`{:composition, :req_llm_tidewave_enabled}` while `TIDEWAVE_REPL` is exactly
`"true"`. ReqLLM otherwise adds a Bandit/Tidewave listener during application
start (`application.ex:43`, `:152-162`). If Req and `Req.Finch` are not already
running, that ordering prevents their initial pool-option cast from opening an
environment-selected key-log file. If the host already started them, Loopex
does not claim that no file was opened earlier; model calls never use that
default pool, and the per-call guard prevents the tagged pool from opening or
appending to the destination. Application configuration outlives any Loopex
application's restart:

After the three pre-start guards above, the step evaluates the following rows in
numbered order and takes the first match. This order is the public error
precedence for combined states.

| Order | ReqLLM | `:req_llm` `:load_dotenv` | Loopex marker or host declaration | Result |
| --- | --- | --- | --- | --- |
| 1 | Any state | any | the marker key is present with a value other than exact `:started` | Refuse `{:composition, :req_llm_start_failed}` before mutation; malformed hygiene state never authorizes start or reuse |
| 2 | Not running | any | host passed `req_llm: :host_started` | Refuse `{:composition, :req_llm_host_declaration_invalid}`; a declaration that the application is already running never authorizes Loopex to start it |
| 3 | Not running | not `false` | marker exactly `:started` | Refuse `{:composition, :req_llm_dotenv_enabled}`; never overwrite a post-Loopex host mutation |
| 4 | Not running | `false` | marker exactly `:started` | Under the gate's serialized hygiene decision and after all pre-start guards pass, change the marker to `:starting`, restart with the persisted setting, then restore `:started` only after a returned success and the worker's exact normal `DOWN`; a returned error restores the prior `:started` marker only after the same proof, while an uncertain stop leaves `:starting` |
| 5 | Not running | any | no marker and no host declaration | This is the only first Loopex-owned start: write `:starting`, then direct the worker to persist `load_dotenv: false` and call `Application.ensure_all_started(:req_llm)`; replace it with exact `:started` only after a returned success and the worker's exact normal `DOWN`; a returned error removes `:starting` only after the same proof, while an uncertain stop leaves it |
| 6 | Running | not `false` | exact marker, host declaration or neither | Refuse `{:composition, :req_llm_dotenv_enabled}` |
| 7 | Running | `false` | the marker is exactly `:started`, or the host passed `req_llm: :host_started` | Proceed |
| 8 | Running | `false` | neither | Refuse `{:composition, :req_llm_already_started}` |

If an authorized start in row 4 or 5 returns an error and its worker then ends
normally as proved below, the result is `{:composition,
:req_llm_start_failed}` and the prior marker state is restored as the table
says. The Tidewave guard already won before either start attempt. A returned
result is provisional until that worker proof completes.

- **Concurrency and bound.** The credential/tool gate serializes the complete
  read/configure/start/mark decision; M6 does not use `:global.trans/3`, whose
  acquisition can wait forever. Before any application-controller interaction,
  the gate records one absolute decision deadline 5,000 ms ahead, sets
  `trap_exit: true`, starts one linked and monitored non-trapping hygiene worker
  and stays responsive. The gate owns table evaluation and every marker write;
  the worker performs all potentially blocking application-controller reads,
  `Application.put_env/4` and `Application.ensure_all_started/1`. It first sends
  the exact running/config snapshot and waits start-blocked for the gate's
  correlated row directive. For row 4 or 5 the gate writes `:starting` before
  directing the first mutating configuration request. The worker uses the one
  deadline throughout; the gate selects failure when that deadline wins even if
  an individual controller call has its own later timeout. It sends its exact
  provisional result with PID, reference and completion timestamp, then waits
  for a correlated `finish`. A zero-wait receive at the decision deadline
  accepts only a matching result completed no later than that instant. The gate
  then sets the reap deadline to the earlier of 1,000 ms after its choice and
  6,000 ms after the decision began. It sends `finish` for an accepted
  provisional result or an untrappable kill for a missing, malformed, late or
  otherwise unproved result, remains responsive and waits in bounded receives
  for the exact worker `DOWN`, correlating both `EXIT` and `DOWN`, then performs
  one zero-wait receive at the reap deadline. Only an in-time valid result
  followed by exact normal `DOWN` permits the gate to write exact `:started` for
  success or restore the
  prior marker state for a returned failure, then answer the joined cohort.
  Concurrent requests join that decision under the same 7,000 ms outer bound
  and re-evaluate afterward; a proved returned failure answers the current
  cohort without a second start. Two first
  compositions therefore cannot observe the running application between
  successful start and the completed marker, and only one calls the application
  controller. Requester death does not cancel an admitted decision. On deadline,
  a read or configuration timeout, malformed result, abnormal worker loss or
  failure to observe the exact normal worker `DOWN` after an in-time
  snapshot or result, the decision is unproved. Exact gate `DOWN` is separate:
  each admitted external requester selects the fixed failure under its monitor,
  and no dead gate is assigned the handoff. After the reap interval, the
  surviving gate atomically poisons both ephemeral modes, fixes
  `req_llm_start_failed` for every requester in the admitted cohort, completes
  the aggregate poison-result handoff by the absolute 7,000 ms outer deadline
  and only then terminates the shared tree; every later composition refuses
  until VM restart. Before a row-4/5 mutation
  directive, this branch preserves the exact prior hygiene marker—absent or
  `:started`—and never invents `:starting`; after that directive it leaves exact
  `:starting` because a configuration or application-controller mutation may
  have continued. No owner reservation, temporary root, credential read or
  effect exists then. A missing matching `DOWN` is logged without extending the
  outer bound or permitting marker rollback. A read failure whose worker is proved normally `DOWN`
  returns the same fixed start failure without changing the marker or poisoning
  the gate. A missing worker `DOWN` is logged but does not extend the public
  bound or permit marker rollback. A failed
  first start that returned normally leaves no marker, and a later undeclared
  host start is refused. Same-VM host code that races or ignores this
  Loopex-only gate is trusted host interference.
- **Persistence.** `persistent: true` keeps the values across any later load of
  the application (`Application.put_env/4`), so a host that stops and restarts
  ReqLLM restarts it with `.env` loading off. A host that turns loading back on
  changes the value the next composition reads, and is refused.
- **A host declaration is trusted as given.** With `req_llm: :host_started`,
  composition reads the current `:load_dotenv`, not the value in force when the
  host started ReqLLM; a false declaration is the host's.
- **Nothing else changes.** Loopex leaves `:llm_db` configuration and
  `warn_unverified_models` alone, never restores the ReqLLM value, because
  ReqLLM reads it at its start, and never
  stops ReqLLM, because another component may use it.

<a id="technical-adr-0039-relation-0019"></a>
### Shared-State and Diagnostic Facts

Concept: [What changes relative to ADR 0019](0039-ephemeral-embedded-profile.md#concept-adr-0039-relation-0019).

These facts are for ReqLLM 1.24.0, verified in `deps/req_llm`.

**What starting ReqLLM does.** Starting `:req_llm` starts `ReqLLM.Supervisor`,
with its Finch pool `ReqLLM.Finch`, `ReqLLM.TaskSupervisor` and a token cache.
It also initializes a provider registry in `persistent_term` and a named ETS
table. All of these are VM-global and named, so one ReqLLM serves every user in
the VM. Req's application also keeps the `Req.Finch` worker and pool-supervisor
registries and default infrastructure alive. M6 uses those registries to route to the tagged user-managed
pool, but uses neither shared default pool for a model call.

**Paths that can carry the request, and a hosted provider's credential, into
the host:**
- the host environment, for as long and as broadly as the host keeps it;
- a log line written by the sensitive caller is suppressed by its process
  level, but a call-owned pool or OTP TLS process may emit through the host's
  logger;
- a crash report from the caller, tagged pool or an OTP TLS process handling
  the connection;
- a telemetry handler the host installs: Finch's events carry the request,
  headers and body included (`finch/http1/pool.ex:47-49`), and ReqLLM's carry
  payloads when configured to; handlers run in the caller but may send data
  anywhere;
- an `erl_crash.dump`, which omits the sensitive caller's stack, messages and
  dictionary but not all dependency-process state.

The caller and tagged pool are gone before a provider result or successful
cleanup acknowledgement. `Req.Finch`'s remaining registries and supervision
infrastructure holds no request, connection or credential. This is not a proof
that arbitrary host memory has been erased or that checked-out transport has
already closed: a host handler can keep what it copied, and the call's socket
and OTP TLS controller can drain asynchronously. The isolated release witness
requires both gone within 5,000 ms of caller `DOWN`; runtime cleanup does not
wait for or prove that threshold.

The companion suppresses all of these by running ReqLLM in its own BEAM. The
ephemeral profile does not; the `ask` command sets the primary logger level to
`:none` and disables crash dumps for its own VM, and a library host owns the
rest.

<a id="technical-adr-0039-vision"></a>
### The Vision Amendment

Concept: [The vision amendment](0039-ephemeral-embedded-profile.md#concept-adr-0039-vision).

Acceptance of this decision changes the paired vision files and AGENTS.md in
the same change. Each place gets the same scoped exception, worded for its
context:
- **`docs/vision-technical.md` §12.7** gains, after the list of planes from
  which known credential material is excluded, an exception: ADR 0039's
  ephemeral profile runs its provider library in the host VM. The host
  environment then has the host's lifetime and audience. During a call, the
  resolved credential also exists in the sensitive caller and tagged pool's
  provider HTTP/TLS state, so their crash reports, a crash dump and
  host-installed telemetry handlers can observe it. Before a provider result
  or successful cleanup acknowledgement, Loopex proves the caller and tagged
  pool gone. A checked-out socket and its OTP TLS controller may then retain
  request material while they drain asynchronously, with no route to the
  session; their crash reports and host-installed telemetry remain observable
  during that drain. A handler's copy has the lifetime the host gives it. Under
  isolated release conditions the socket and controller must be gone within
  5,000 ms of caller `DOWN`; runtime cleanup does not wait for or prove that
  threshold. Within ephemeral-composition participants, the VM-wide gate
  excludes an active-tool session from the owned credential-call path and its
  fixed quarantine. Tool release requires the registered session subtree gone
  and the executor's process groups proved empty; credential-call release
  requires every registered process gone and the quarantine elapsed. An
  unproved release or gate loss poisons both modes until VM restart, and a gate
  crash ends active ephemeral sessions. Durable compositions, direct executors,
  trusted host code and transport that outlives the quarantine do not
  participate in that guarantee. TLS resumption, tickets and secret retention are disabled. Every
  credential-bearing endpoint is HTTPS-only, so the exception admits no
  plaintext network exposure.
  Reference-only runtime state, just-in-time resolution, the exact-value reply
  gate and every other listed Loopex-plane exclusion still hold. A host needing
  structural exclusion uses a profile that isolates the provider in its own OS
  process.
- **`docs/vision.md` §12** gains the matching Concept sentence: in ADR 0039's
  ephemeral profile the session is explicitly non-durable: its committed
  history lasts only for the declared runtime lifetime, it exposes no recovery
  or migration surface, and the durable-session survival guarantee continues
  to govern every profile represented as durable. This is the first accepted
  use of technical §12.2's in-memory posture for simple embedding. In that
  profile, the host environment has the host's lifetime and audience,
  and the sensitive caller and tagged pool's provider HTTP/TLS state can hold
  the credential during a call. Loopex removes its caller and tagged pool before
  a provider result or successful cleanup acknowledgement; a checked-out socket
  and its OTP TLS controller can retain request material while they finish
  asynchronously. The isolated release witness requires both gone within 5,000
  ms of caller `DOWN` without making that a runtime acknowledgement condition.
  Within ephemeral-composition participants, a VM-wide gate excludes active
  tools from that owned call and quarantine; an unproved release or gate loss
  poisons both gate modes until VM restart, and a gate crash ends active
  ephemeral sessions. Durable compositions, direct executors, trusted host code
  and transport that outlives the quarantine remain outside that scheduling
  guarantee.
  Host-made diagnostic copies remain the host's.
  Credential-bearing endpoints remain HTTPS-only; the separate-process profile
  keeps structural isolation.
- **`docs/vision.md` §16**, after "Observability uses references and redaction
  rather than capturing secrets or unrestricted payloads", gains: "In ADR
  0039's ephemeral profile, the in-VM provider path, including its sensitive
  caller and provider HTTP/TLS state, is visible to host crash reporting and
  telemetry during the call; a checked-out socket or TLS controller remains
  similarly observable while it drains after owned cleanup, and a host copy can
  outlive them. The isolated release witness requires that drain to end within
  5,000 ms of caller `DOWN`, without making it a runtime cleanup condition.
  The ephemeral scheduling gate excludes the profile's active tools only from
  the owned call and fixed quarantine. Its fail-closed poison and active-session
  termination do not cover a durable composition, a direct executor, trusted
  host code or a transport that drains longer than the quarantine.
  Loopex's own observability still never captures it."
- **`docs/vision-technical.md` §6.1**, in the credential custody row, the host
  column reads "Owns encryption, resolution and rotation; for ADR 0039's
  ephemeral profile, may resolve by supplying the value through a variable it
  names, read at the model boundary"; and §12.7's "narrowest possible lifetime
  and audience" gains "; in ADR 0039's ephemeral profile, a value the host
  supplies through its environment has that environment's lifetime and
  audience, which the host owns". The durable profile's custody rule is
  unchanged. The same row points to §12.7 for the owned-cleanup frontier, the
  5,000 ms isolated release-witness threshold and the ephemeral scheduling
  gate's participant, proof, poison and crash boundaries.
- **`docs/vision-technical.md` §6.2**, after the diagnostics plane's
  definition, gains: "Crash detail from the in-VM provider path that ADR 0039's
  ephemeral profile runs—including its sensitive caller, provider HTTP/TLS
  state and a socket or TLS controller draining after owned cleanup—is the
  host's diagnostics with the host's retention, outside Loopex's diagnostics
  plane. Any copy made by a host-installed telemetry or logger handler has the
  same ownership. Section 12.7's owned-cleanup frontier and 5,000 ms isolated
  release-witness threshold bound the transport drain. The ephemeral scheduling
  gate changes only admission among its participants; it neither reclassifies
  host diagnostics nor covers a nonparticipant or transport beyond its fixed
  quarantine."
- **`docs/vision-technical.md` §23**, the bullet "Known credential material
  never appears in prohibited planes" gains "; ADR 0039's ephemeral profile's
  in-VM provider-path crash detail, asynchronously draining socket and TLS
  controller, and host-retained diagnostics are the §12.7 exception; its caller
  rejects the exact resolved value before a provider reply enters a Loopex
  plane, every credential-bearing endpoint is HTTPS-only, and the isolated
  release witness requires the transport drain to end within 5,000 ms of caller
  `DOWN` without making that a runtime cleanup condition. Verification also
  proves the gate's same-mode concurrency and opposite-mode exclusion, the
  subtree, process-group, registered-process and quarantine release conditions,
  both-mode poison after an unproved release or gate loss, active-session
  termination on gate failure and the named nonparticipants".
- **`AGENTS.md`**, Product Non-Negotiables, "Credentials and context", after
  "beyond an approved scoped ephemeral hand secret", gains: "; in ADR 0039's
  ephemeral profile, a credential may also reach the sensitive caller and
  tagged pool's provider HTTP/TLS state during the call, and a checked-out
  socket or TLS controller may retain request material while it drains after
  owned cleanup. Those states and host diagnostics are host-observable. The
  host environment and host-made copies have host-owned lifetimes and remain
  outside Loopex's planes; every credential-bearing endpoint remains HTTPS-only,
  and the isolated release witness requires the transport drain to end within
  5,000 ms of caller `DOWN` without making that a runtime cleanup condition.
  Within ephemeral-composition participants, a VM-wide gate excludes active
  tools from the owned credential-call path and fixed quarantine; an unproved
  release or gate loss poisons both modes until VM restart, and a gate failure
  ends active ephemeral sessions. Durable compositions, direct executors,
  trusted host code and transport that outlives quarantine do not participate
  in that guarantee". Editing
  AGENTS.md is the maintainer's to approve with acceptance.

<a id="technical-adr-0039-proofs"></a>
### Adapters and Proofs

Concept: [Observable consequences](0039-ephemeral-embedded-profile.md#concept-adr-0039-consequences).

| Obligation | Witness |
| --- | --- |
| The memory store is a store | The store conformance suite's `:memory` kind is bound to `Loopex.Store.Memory` itself and passes unchanged |
| The in-process adapter is a model | Mapping, option and error tests run against a scripted ReqLLM transport. The model streaming conformance suite runs against it with `streamed: false` and no deltas. Real-provider lanes call a local Ollama model and one hosted provider |
| The committed deadline remains authoritative | Pure vectors freeze one native offset and cover positive and negative offsets, separated clock samples, the unsigned-64-bit maximum, one positive native tick rounded up to 1 ms, zero and negative remainder, and the 1,000 ms cap; no full durable duration or native remainder reaches an OTP or Finch timer. Caller-result vectors require the exact native completion timestamp, admit an already-queued in-time result in the expiry zero-wait race, reject a late timestamp and make every later result inadmissible |
| The guards and dispatch fence hold | At the sensitive caller, an absent, empty or greater-than-65,536-byte selected hosted credential; at composition, an active hosted preset or any supported hosted-provider variable present beside active Ollama tools; and at their stated boundaries, a replaced provider module, a set `SSLKEYLOGFILE`, a non-empty `:req` `:default_options` (including an `auth:` default and a plugin), `TIDEWAVE_REPL="true"` before a Loopex-owned ReqLLM start, an unsupported or userinfo-bearing base URL, plain HTTP for any credential-bearing provider, and each final-request routing substitution refuse. Composition never reads the selected hosted credential value; the caller's value refusals accept no connection and take owned teardown. In a fresh VM the fixed provider table and pre-start global guards require no registry; SSL and Tidewave checks run before ReqLLM or Req starts; the hygiene decision initializes the registry; and only then do exact module verification, default-address lookup and address normalization run. Thus the default Ollama composition succeeds while a replaced module still wins over an address fault. The named key-log file is not created and no Tidewave listener opens. With host-started dependencies, a set key-log variable causes refusal and the call-owned pool neither opens nor appends to the file, without claiming what the host did earlier. ReqLLM application or catalog base URLs and its Finch settings cannot change the explicit origin or tagged pool. Anthropic and OpenAI route planning calls literal `ReqLLM.plan(model_spec, :chat, planning_options)` with the exact credential-free generation-option list; `generate_text/3` follows that chat path and adds only the hosted credential. Each prepared request names `OneShotHTTP1`, `Req.Finch`, the exact reference tag, optional bounded `pool_timeout`, exact credential-free private context, `max_retries` 0 and `redirect` false, with no pool configuration mixed into the named `finch` request option. Finch telemetry receives neither private owner context nor owner PID; the non-secret routing tag and exact recorded worker PID remain visible. A returned Req request regains the private context only so a retry reaches the owner fence. The user-managed pool has the exact HTTP options and, for HTTPS only, the exact three TLS retention options. Forced retry, 429, 529, redirect and closed-transport cases get at most one dispatch grant, accepted connection and request-start marker; a second adapter invocation is refused by the grant before pool lookup or network activity, and no response is cached. The internal collector accepts exactly 8,388,608 response-body bytes, halts fixed-length and chunked bodies at the next byte with `model_response_too_large`, and refuses a content-encoded response without decompressing it |
| Credentials stay out of Loopex's planes | With each provider variable set to a canary, ordinary replies, a provider error and a caller crash whose exception embeds the request leave the exact canary in no committed record, event, progress item, diagnostic or trace entry, runtime, coordinator or owner state or mailbox, owner crash report or Loopex log. A hostile successful provider reply that echoes the exact value in any mapped provider-controlled field, including assistant text, tool-call fields and `provider_response_id` is discarded and becomes the fixed `dispatched_or_unknown` failure. A runtime trace session names the exact `InProcess.Caller.run/1` inventory and dependency call sites: it observes the credential-free pre-exclusion call and a non-excluded control canary, while no raw trace message or entry from the sensitive caller after exact exclusion carries the credential canary; an exclusion refusal reads no credential. A hosted composition accepts only `:tools` `:none`. With Ollama and either active preset, a raw sensitive monitored preflight finds all supported hosted-provider variables unset or refuses before a root; a canary present in each variable and a forced preflight crash leave no value in its fixed return, `DOWN`, log or crash report. The preflight is awaited before composition continues, so no executor job or tool process exists beside a known provider credential. The child-environment scrub is tested only as defense in depth and is not treated as same-user isolation. The witness does not claim arbitrary heap erasure or absence from host-owned telemetry copies |
| The ephemeral scheduling gate holds | Capability-bound acquisitions prove concurrent `:tools` leases and concurrent `:credential_call` leases, while either mode refuses the other. Every ephemeral session reserves admission, completes the bounded owner start and exchanges the reservation for that still-root-blocked PID before acquiring a lease. The exact gate then issues the one-use root-start token; gate death before issue creates no root, while every token/death/message-order race after issue follows startup rollback or the named unmarked-owner limitation. An active-tool owner acquires before its sensitive preflight or root and registers `SessionRoot` before executor start; release requires the complete subtree `DOWN` and an executor/instance/lease-bound empty-process-group proof the owner cannot synthesize. A hosted call registers its cleanup owner, acquires before its root, pool or caller, and uses the gate-created, start-blocked caller whose PID-bound lease token is verified before credential read; release requires all registered PIDs `DOWN`, both tagged entries absent and the fixed 5,000 ms quarantine without claiming transport `DOWN`. Credential-free Ollama acquires no credential lease: its cleanup owner, root, children and directly spawned start-blocked caller register beneath the enclosing owner's local-call capability, the caller verifies its local token, and release requires the same PID and registry proof with no quarantine. Real Ollama calls run while that session's tools lease remains held. Owner or gate loss is raced before and after every local and hosted registration. Every registered executor, including `:tools :none`, submits and validates its proof nonce while alive; premature owner or executor `DOWN` retains `:process_groups` and poisons both modes, while no-executor rollback is the sole vacuous case. Any unproved tool group or registered call poisons later admission. Latch-fault witnesses cover every named gate-scope helper and the excluded retryable workers. Owner-originated poison latches authority and finishes independent cleanup before delivery. Helper-origin poison is injected before cleanup, beside concurrent admission/stop/creator loss and at the deadline race. Custody atomically enters or joins stopping, records cleanup and a distinct selection-notification margin, and requires the detector's exact retirement and `DOWN`; owner loss or absent delivery start exercises gate takeover. Exact delivery start follows the stored reached-phase result and freezes recipient-specific values, including different concurrent ask and stop results, and begins one aggregate 1,000 ms handoff. A live hygiene gate reports to its cohort, exact gate `DOWN` makes external requesters select the fixed failure, and the synchronous owner-start entrypoint retains its caller-held refusal and creator identity without a wrapper. Tree termination follows handoff or deadline and cannot reopen admission. A gate or supervisor crash stops every active session and leaves the persistent poison across application restart. Startup-rollback witnesses prove the exact final disposition is acknowledged only after its actor, subtree and applicable process groups end; an unproved acknowledgement retains a possible root with `gate_release`, or returns the no-root gate failure when no path could exist, and poisons both modes. Paired clean-stop witnesses prove only `prep_stop/1` closes admissions and produces the exact empty census consumed by `stop/1`. Its unlinked monitored resolver is suspended in child enumeration, gate request, provisional result, `finish` and worker `DOWN`; every timeout, stale or malformed branch produces no proof and retains both markers. A gate crash after proof starts a replacement with a fresh persistent generation, so the stale proof cannot compare-and-erase its marker. A live reservation, owner, local-call record, lease, obligation, child, contradictory census or failed handshake preserves poison. Durable compositions, direct executors, trusted host code and transport beyond quarantine are exercised as named nonparticipants; durable/direct executor child environments retain M5 behavior |
| The post-poison protocol is closed | Faults prove the gate refuses every authority-bearing transition after the latch and accepts exactly correlated `poison_watch`, `poison_delivery_started` and `poison_handoff_complete`. Identical replay, stale reference, wrong PID or deadline, reordering, conflict and deadline-edge zero-wait cases neither extend time nor grant or release authority. Owner-origin installs watch before delivery-start without awaiting the gate and uses the live owner as deadline fallback; a pre-root ambient-credential preflight missing exact `DOWN` records the fixed 10,000 ms rollback deadline before watch. Helper-origin sends no preliminary gate message: exact gate watch acknowledgement precedes owner custody, then detector retirement and exact `DOWN` precede delivery-start; completion targets only the gate after the detector has retired. Every deadline race stores the complete reached-phase result before the aggregate delivery interval starts |
| Its cleanup owns the call | On both toolchain pairs, local HTTP, TLS 1.2-only and TLS 1.3-only servers deliberately keep their side of a completed connection open. The owner-candidate start witness proves exact `:unmanaged` starter acquisition creates no proxy or candidate, while the managed path passes the opaque starter only to an unlinked proxy and permutes ready/grant, proxy result, candidate report, `finish`, `proxy_retiring`, proxy `DOWN`, `registration_pending`, activation preparation and `begin`; it faults every missing, late, duplicated, replayed, malformed, mismatching and abnormal form. It covers wrong stop reference and retainer tuple, callback death before disclosure, after disclosure, during registration, after managed return and on both sides of `begin`, plus core stop before and after managed return. Suspending the locked owner `Task.Supervisor`, expiring and killing the proxy, then resuming it may materialize an undisclosed request-free candidate; that candidate receives no `begin` and exits on its first scheduled dead-proxy, dead-callback or expired-deadline step without a gate request, root, caller, credential read or dispatch. The worker-retained/guard-unregistered witness lets model settlement precede candidate `DOWN` and proves the result has no registered provider-resource obligation. If a matching core stop was already queued, the candidate acknowledges it and exits; if registration committed but callback `DOWN` arrives first, candidate exit without an acknowledgement yields locked core `provider_cleanup_unproved`. No branch uses a registration fallback timer or invents adapter `not_dispatched`. An exact returned start refusal plus normal proxy `DOWN` remains clean `not_dispatched`. Normal completion, stop and deadline after exact managed registration, each before headers, mid-body and after the body, prove caller, cleanup owner, lifecycle root, anonymous supervisor, pool supervisor and exact recorded worker `DOWN` and both tagged registry entries absent before a provider result or successful cleanup acknowledgement. Separately, under isolated release conditions the server observes EOF and every call-created TLS controller drains within 5,000 ms of caller `DOWN`; runtime cleanup does not wait for or prove that threshold. Every exact `:unmanaged`, `{:error, :provider_resource_refused}` and `{:error, :provider_guard_unavailable}` form, plus raised and malformed lifetime registration, starts no pool, caller or credential read. Exact `:unmanaged` or `{:error, :provider_resource_refused}` returned from registration with candidate `DOWN` returns fixed `not_dispatched`; if that still-start-blocked candidate's `DOWN` is missing, fixed `not_dispatched` is permitted only after the poison latch closes every future grant. Guard-unavailable, raised and malformed registration forms retain the locked core-owned conservative result. Once lifetime registration succeeds, a missing owner or child `DOWN` instead withholds success and cleanup acknowledgement and takes the unproved path. A failed or partial pool-child start after root creation removes every owned child, the root and every Loopex-created registry entry before refusal. Setup and dispatch-time inspection run in the registered lifecycle root with no helper process; a stuck inspection withholds dispatch and fixed refusal, and cannot return success unless cooperative teardown proves that root and its descendants gone. Credential or guard loss after pool creation, request-preparation failure, final-route refusal before the direct worker call and caller-spawn failure produce the applicable process and registry proof with no accepted connection. A request body larger than 64 KiB succeeds over HTTP and TLS; the separate response-boundary witnesses are stated above. A close during upload produces at most one accepted connection and request-start marker and a `dispatched_or_unknown` result. Sequential TLS calls never resume a session. Two concurrent same-origin calls have distinct tags; stopping one leaves the other to complete, and each removes only its own pool. An isolated-VM lifecycle census records every call-created client process and port without fixing a count or claiming arbitrary heap erasure. Seams that withhold a registered caller, lifecycle root, anonymous supervisor, pool supervisor or exact worker termination, or leave either tagged registry entry take the unproved path and return no success; transport drain beyond 5,000 ms fails the release lane but is not a runtime acknowledgement condition |
| Hygiene holds | Direct embedded and built-escript ephemeral calls exercise already-started, exact success/error, malformed/late result, abnormal/missing `DOWN`, timeout, late controller completion and concurrent-first-call branches of the bounded `loopex_composition` bootstrap, and prove its gate tree is live before lookup. The built escript records `app: nil`, reaches `main/1` before a Loopex application starts and keeps a stalled first composition callback inside the 5,000 ms decision plus 1,000 ms reap bound. Its CLI-parsed ephemeral branches start no `:loopex_cli` application first; durable `ask` starts the same CLI graph but discards every startup term into fixed `application_start_failed`, while every released command runs the former exact `ensure_all_started(:loopex_cli)` operation before existing main logic with retained output, status and startup-failure semantics. Combined faults pin workspace, skill, provider and pre-start guard refusal before bootstrap, and bootstrap refusal before ReqLLM hygiene. The generated composition and `loopex_llm_reqllm.app` application lists omit `req_llm`, `req` and `finch` under the `runtime: false` declarations, while the escript embeds their modules and companion and fixture host releases list all three as `:load` and boot with them stopped. A `.env` in the working directory is not loaded. With `TIDEWAVE_REPL="true"`, composition refuses before starting the composition application or ReqLLM and no listener opens. Every start-table row is exercised through the responsive gate and its one linked, monitored worker; no `:global.trans/3` participates. Suspended application reads and configuration, in-time success and returned error, the 5,000 ms decision plus 1,000 ms reap bounds, the zero-wait deadline race, provisional result, `finish`, exact normal `DOWN` before marker commit or restoration, abnormal and missing `DOWN`, malformed and late result, gate loss, joined concurrent cohort and requester death all take their fixed branches. A mutation is never directed before `:starting`; every uncertainty after that directive retains it and poisons both modes, while a proved pre-mutation read failure leaves no marker. Two concurrent first compositions start once; a failed first start followed by a later undeclared host start refuses; a later composition proceeds after success across an explicitly clean `loopex_composition` stop/restart, while a crash restart remains poisoned until VM restart; a host restart of ReqLLM loads no `.env`; a host turning loading back on is refused. `:llm_db` configuration and `warn_unverified_models` stay unchanged; after the last session, ReqLLM and Req infrastructure remain running while their default pools and state contain no per-call request or credential |
| The composition bootstrap has one bounded owner | The bootstrap guard is faulted with requester death while the application-controller call blocks and after provisional result; guard death before and after forwarding; and withheld, malformed or reordered worker result, `finish`, worker `DOWN`, guard reap acknowledgement and guard `DOWN`. Success occurs only in the order exact normal worker `DOWN`, correlated guard acknowledgement, exact normal guard `DOWN`. Both deadlines kill or prove guard and worker; a late controller completion has no result path and a later creation call repeats the complete precedence chain. Existing-handle calls never bootstrap. The built escript refuses every malformed ask form before a Loopex/project application start; valid ephemeral forms use the bounded creation path, valid durable forms use the fixed ask startup diagnostic, and released-command forms reproduce the former Mix success and formatted-error/status-1 cases through the legacy helper |
| Escript base startup is distinguished | Mix starts its embedded Elixir base before `main/1`; every no-start claim here means no Loopex project application. Invalid ask forms leave every Loopex `.app` stopped. A valid ephemeral form leaves `:loopex_cli` stopped until the bounded composition path starts its dependency graph. Durable and legacy forms start the exact M6 CLI graph with ReqLLM, Req and Finch still load-only; durable ask uses its fixed-diagnostic helper, while legacy commands use the exact-Mix-compatible helper |
| The companion's valid path is preserved | Every companion suite passes after the shared mapping is extracted. Valid application-call request and reply vectors stay byte-identical, while a malformed binary argument payload that reaches the buffered `ToolCall` seam now takes fixed post-dispatch failure instead of becoming executable `%{}`; visible provider-executed and provider-native markers likewise fail instead of becoming local requests; fixtures prove no local tool dispatch. Vectors separately pin the locked dependency's earlier normalization: replacement ids for missing provider ids and literal `{}` for the provider paths that erase missing, nil, empty or unsupported arguments, omitted malformed calls, forced function type and stripped error metadata are not claimed as mapper refusals. The M6 timer-safety fix makes ReqLLM's internal total, stream-idle and receive waits infinite so the unchanged coordinator's sliced committed deadline remains authoritative across the newly exposed unsigned-64-bit durable bound; protocol and durable formats do not change. The durable profile refuses an `ollama:` model |
| The profile is ephemeral and says so | After proved cleanup and successful recursive removal, including the owner-exit path, no file remains under the profile's temporary root. An unproved cleanup or failed root removal returned to a caller keeps and names the root; an owner-exit path with no waiting caller emits it only to the host logger. Standalone `ask` suppresses that logger, so the named post-timeout background-drain limitation can leave the retained root unnamed. The result carries `profile: :ephemeral`, and `ask`'s JSON carries `"profile"` |
| The embedded API is bounded and coherent | The M6 ephemeral API witness proves the prompt refusals and exact 32,768-byte limit; every completed result and non-completed terminal observation; both timeout and post-admission `session_unavailable` no-ending snapshots with the same bounded text, tool and shadowed-skill projection; nullable definition ids for unresolved tools; the defensive 64 KiB answer projection and 256-entry tool-result projection with their truncation flags; the closed pending-interaction shape and full post-`Interaction.view/1` validation, including minimum, maximum and out-of-domain `turn` and `expires_at` values; every answer-then-defer transition through ADR 0024's ceiling; the one-shot `interaction_requires_session` result; timeout continuation and the later `last_result/1` transition; and `history/1`'s 256-entry, defensive 64 KiB-per-text limits, ordering and truncation flags. Concurrent stop never publishes a stale question and replies to a still-waiting ask or answer with a terminal observation or the `session_unavailable` no-ending snapshot, without adding an attachment reader. Stop, retryable and permanent failed-stop states, and caught session-path failures prove every cleanup obligation, every precedence case and the kept-root contract; a pending interaction followed by an unproved stop is retained exactly in `cleanup_unproved.ending`. A timeout followed by background-drain failure proves that no second snapshot is published, later calls are bare-unavailable, cleanup ends the poll and owned resources when proved, and an unproved root is only host-logged and can be unnamed under standalone `ask`. Adversarial terminal and wall-clock numeric values prove the projector never exposes an out-of-domain public member. A forced unmarked owner/gate crash proves the separately named bare-unavailable, no-cleanup-proof limitation |
| The `ask` machine contract is closed | The M6 command witnesses prove the grammar, profile-specific default model, profile selection, exact JSON member and per-outcome detail sets, run-local text and tool provenance and order, literal shadowed source ids, nullable unresolved tool ids, decimal values beyond `2^53`, every Loopex-owned exit status, the durable `cleanup: null` and resumable-state meaning, and zero standard-output bytes on pre-run refusal and on an unmarked owner/gate failure with no public cleanup proof, before observation or after a terminal observation. Ephemeral JSON is derived only from the public observation or no-ending snapshot plus the mandatory stop return; timeout and caught post-admission session loss render the two fixed `no_ending` reasons, while a bare-unavailable stop takes status 1 and emits no object. An ordinary provisional result must be followed by exact worker `DOWN` through the 1,000 ms kill-and-reap protocol before stop or rendering; withheld `DOWN` hard-halts status 1 with no output or cleanup claim. A real stalled call proves that the main process receives the first signal, calls stop while a monitored worker remains in `ask/3`, drains its one reply and renders once. A pre-handle signal is latched, forwarded and reaped but retains the platform child status without a Loopex cleanup or output promise; second-signal and backstop cases remain named hard kills |
| The interrupt admission race is closed | Exact ask-mode installation precedes worker start, is bounded and returns the exact `:erl_signal_server` manager PID; install refusal, duplicate claim, replacement or manager loss stops the new session, emits no result and exits 1. A provisional worker result stays protected through exact `DOWN` and mandatory stop. One synchronous correlated finish call on that manager serializes with signal callbacks and returns ordinary or interrupted before it disarms; fault witnesses race a first signal before, during and after stop and prove only one branch renders. A missing or malformed finish reply, handler loss or manager loss emits no result and exits 1. First-notice witnesses suspend the monitored worker before owner registration, after registration but before grant, and after grant. The pre-registration branch permits successful stop plus bare `session_closed` or unavailable, emits no object and invents no `no_ending`; every branch performs one stop and at most one render before exit 130, proves worker `DOWN` within its reap bound or takes the hard halt. Direct `SIGTERM`, `SIGHUP` and `SIGQUIT`, plus launcher-forwarded terminal `SIGINT`, share one handler path. It accepts only its fresh manager PID/reference notice, ignores forged, stale, old-manager and replayed notices, disarms its backstop on exact finish or main `DOWN`, and hard-halts only on a later handled signal or backstop expiry while stopping. Launcher fixtures close the pre-child lost-signal window without asserting status 130 |
| Temporary-root ownership is conservative | Exact claim-return witnesses distinguish an owned root from a lost `mkdir` result. Every ordinary startup or stop failure names `root_ownership: :owned`. A grant followed by loss before an exact `mkdir` return names `root_ownership: :unknown` and never removes or retries that possible path. If the actor or subtree cannot be proved down, only `:session_subtree` is pending and the final exchange is not reached; if those proofs succeed but the reached gate acknowledgement fails, only `:gate_release` is pending; only a successful acknowledgement reaches the permanently unproved `:root_removal` branch. Loss during side-effect-free candidate preparation with exact actor `DOWN` proves no filesystem mutation and reaches the ordinary no-root final disposition; missing actor `DOWN` prevents that exchange and poisons admission. The JSON and fixed diagnostic projections preserve the ownership label |
| Base URLs have one canonical grammar | Vectors cover omitted, explicit default and explicit non-default ports; lowercase schemes; canonical IPv4; lowercase and uppercase-input ASCII DNS; normalized origin and path; and provider defaults. They reject uppercase schemes, IPv6, Unicode or percent-encoded hosts, userinfo, empty or malformed authorities, non-canonical numeric ports, ports 0 and 65,536, query, fragment, dot segments and every path spelling outside the stated grammar before a root or credential read |
| No default authority | Composition without `:policy` refuses with `host_policy_required` |
| Skills are truthfully named | A `.agents/skills/<name>` directory in the workspace is `project:<name>`; a directory outside is `user:<name>` with its content digest; any other workspace directory refuses; a shared name admits the project skill and reports the user skill as shadowed; the same holds under `ask --state-root`. `ask` passes the helper's explicit manifest, even when empty, through the released `resource_manifest` option and never discovers project context. A direct host can reproduce the path by passing the helper's `result.manifest` through one released composition bracket, which retains it once, then issuing ADR 0025's admission and canonical ordered activation commands; the raw durable constructors have no `skill_directories` option and submit no session command |
| Rollback holds as stated | A durable root with a pending interaction written by the candidate recovers and is answered under `v0.2.0`, and the reverse; a `loopex.grep` call not yet dispatched, resumed under `v0.2.0`, is committed as `unknown_tool` and the run continues; a `loopex.grep` call already dispatched is never run under `v0.2.0`, and its work either has a matching receipt admitted or stays pending; a completed `loopex.grep` call in history replays under `v0.2.0`; a root with an admitted user skill, written by the candidate, resumes under `v0.2.0`'s offline `loopex resume` with the retained snapshot reloaded by digest, and under `v0.2.0`'s daemon with the session resumed and all of that session's skill context withheld, project skills included |
| The vision amendment is recorded | The acceptance change applies all seven scoped texts together: `docs/vision.md` §12 and §16, `docs/vision-technical.md` §6.1, §6.2, §12.7 and §23, and AGENTS.md's credential non-negotiable. Their semantic review and the retained security review confirm the same ADR 0039-only exception, owned-cleanup frontier, asynchronous transport exposure, 5,000 ms release-witness threshold, gate participant and release boundaries, both-mode poison, active-session termination and named nonparticipants; `bash scripts/check.sh --docs` passes |
| Core is unchanged | `git diff v0.2.0 -- apps/loopex/lib ':(exclude)apps/loopex/lib/mix'` is empty, the only additions under `apps/loopex/lib/mix/tasks/` are the two closure tasks, and `mix loopex.deps_budget` passes unchanged |

<a id="technical-adr-0039-compatibility"></a>
### Compatibility Mechanics

Concept: [Compatibility and rollback](0039-ephemeral-embedded-profile.md#concept-adr-0039-compatibility).

**New surfaces**, all experimental under the 0.x policy:
- `LoopexComposition.Ephemeral`;
- `LoopexComposition.ResourcePacks.read_directories/2`;
- the `ask` command and its `-p` alias;
- the `provider:model` grammar.

**Additive options.** The durable `LoopexComposition.start/1`, `with_runtime/2`
and `start_edges/2` entrypoints gain `:model`, `:bounds`, `:sampling` and
`:active_tools`, whose defaults reproduce M5. Named directories use the public
helper and released `resource_manifest` plus ADR 0025 session commands. Their
released outer option behavior remains unchanged: non-list input keeps its bare
error, unknown keyword keys remain ignored and the first repeated key wins.

**Durable policy revision.** The default durable `policy_identity` revision
(`loopex_composition.ex:259-261`) becomes the fixed string `"0.2.0"` instead of
`Loopex.version()`. The revision is persisted with each interaction
(`session_state.ex:1509`) and recovery requires exact equality
(`session_coordinator.ex:6593`), so deriving it from the release version would
leave a pending interaction suspended across an upgrade or a rollback. The
revision changes only when the reference policies' behaviour changes, and that
change is its own compatibility decision.

**Rollback exceptions.**
- **A call to an M6-only tool.** Core resolves a tool name against the active
  set only at dispatch (`session_coordinator.ex:5609`), at the post-policy
  continuation (`:6401`) and when resuming a pending policy evaluation
  (`:6602`). For a call not yet dispatched, `0.2` answers an unknown name with
  `{:error, {:unknown_tool, name}}` (`:6845-6847`) and commits it as a failed
  tool call (`:6625-6626`). A call already dispatched follows core's
  dispatched-effect recovery unchanged: `0.2` queries the executor, admits a
  matching receipt, and otherwise leaves the work pending for reconciliation;
  `0.2`'s executor defines no such tool, so it never runs it again.
- **An admitted user skill.** Its admission is journaled as a reference,
  digest, decision and selections (`session_state.ex:4898-4909`), and its
  snapshot is retained under the state root by digest and reloaded through
  core validation (`resource_packs.ex:333-380`), as for a project pack. Its
  `source_id` `user:<name>` and nil Git provenance are both accepted by `0.2`'s
  core validation (`resource_pack.ex:203-216`, `:343-348`). `0.2`'s offline
  `loopex resume` reads the session's admitted digest and reloads that
  snapshot before resuming (`loopex_cli.ex:944-1003`). `0.2`'s daemon instead
  composes the manifest it discovers in the workspace at start
  (`daemon.ex:239-242`), which never contains a user pack, so its snapshot never
  matches the session's one admitted digest: core reports `binding_changed`
  (`runtime/resource_snapshot.ex:112-121`), stages no resource entries
  (`:136-140`, `runtime/resource_context.ex:38-47`), and withholds all of that
  session's skill context while the session itself resumes. A user skill has
  nil Git provenance, so it gets no separate provenance record (the nil-commit
  branch of `retain_provenance/2`, `resource_packs.ex:1584` onward); its
  retained manifest carries its identity and bytes, which is all `load/2`
  needs.

**Unchanged:** the store format, the public protocol generations 1 and 2, the
executor protocol, the daemon, the companion's valid application-call request
and reply behavior and core's library. The companion deliberately changes two
private mechanics: dependency-visible tool-call admission fails a malformed
binary argument rather than producing `%{}` and rejects visible
provider-executed or provider-native classifications rather than flattening
them; and ReqLLM-relative waits become infinite so the coordinator remains the
deadline authority. Provider defects ReqLLM already normalized or omitted
retain the locked dependency's behavior described above.

**Removal.** Removing the profile deletes these and touches no durable byte:
- the in-process adapter, the memory store and the ephemeral composition;
- the ReqLLM start step, restoring automatic start;
- the `ask` command;
- the directory-reading function.
The vision amendment would then describe no shipped profile, and a later change
would retire it.
