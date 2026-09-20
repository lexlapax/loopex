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
renamed in every one of the five to **implementation and milestone-closure
evidence** — are discharged at Outcome closure, where the exact-diff tests and
the security review belong. The repository status check reads the links in this section, so a
decision named only in prose declares nothing.

| Decision | Acceptance point | What its acceptance settles |
| --- | --- | --- |
| [ADR 0031](../adr/0031-daemon-grade-store-selection-and-migration.md#concept) | Before the daemon opens a state root, so before workstream 2 lands | The existing local adapter as the daemon's store for `0.2.0`, with the 256 MiB log capacity, 4 MiB frame ceiling, full retention, `store_capacity_exceeded` refusal, the capacity-as-store-loss consequence, explicit stale-writer recovery and the operator root-retirement procedure documented; a daemon-grade adapter and any migration left open for a separate decision |
| [ADR 0032](../adr/0032-daemon-attachment-residency-and-replay.md#concept) | Before the socket is bound or any of those core changes lands, so before workstreams 1 and 3 | The Unix-domain-socket transport reusing ADR 0023 unchanged, generation 2's methods, durable existence established by core's read-only query rather than by attaching or resuming, refusal of a generation-1-only client, owner-only peer access, the bounded socket path, marker-first startup, race-free attach with at-least-once contiguous delivery, the resident window, daemon-owned output buffers, detachment at the last emitted cursor, idle eviction and bounded session pages, and every residency number below |
| [ADR 0033](../adr/0033-collaboration-controller-lease-and-takeover.md#concept) | Before any admission check is written, so before workstream 4 | One daemon-owned controller lease per session held in daemon memory with a fresh opaque writer epoch per grant, admission that binds holder connection, held state, unexpired term and epoch together, explicit takeover, cross-process abort through the core's own cancellation, and no authority from content, metadata or order |
| [ADR 0034](../adr/0034-provider-credential-handoff-over-bootstrap-channel.md#concept) | Before the adapter's credential resolution changes, so before workstream 5's credential item | The credential as an opaque token bound at composition beside the registry handle and **resolved per invocation**, routed by a host-owned registry that holds routing only, resolved from a host-owned custody process only inside the sender that writes the credential frame, after the child proves nonce, codec version and build manifest digest and before the invocation frame; custody and registry ownership, rotation, the guardian-enforced deadline, `:unavailable` on lost custody or registry with no reconstruction, and every failure outcome; no credential environment read anywhere in the adapter's library tree, with `provider_bridge` reading none at all and the launcher's ADR 0019 scrubbing enumeration kept exactly where it is, which is what leaves ADR 0019 unamended; the re-pointed credential-plane proofs and the security review as acceptance points |

ADR 0031 decides one thing, the `0.2.0` local-adapter selection and its
documented limits. It prescribes no successor engine, experiment or migration;
those are named as open questions there and settled by their own decision.

M4 owns interactions, transfers, the foreground server and observability. An
inherited defect is reproduced at the exact base and repaired at its owner; a
daemon workaround cannot conceal one.

<a id="technical-plan-ownership"></a>
### Ownership, Decision Owners, and Rejoin Barriers

Concept: [Scope](M5.md#concept-plan-scope).

| Component | Owns | Cannot own |
| --- | --- | --- |
| `loopex` | Durable session truth, the race-free attach barrier and cursor, independent concurrent attachments to one session **and their release — the dispatcher monitors the attaching process and drops its attachment on `DOWN`, which is what replaces the supersession this change removes**, the read-only session-existence query, **`Loopex.Trace.exclude_self/2`, which installs both the match-specification exclusion ADR 0030 names and the process-level exclusion its callees need, before any message is delivered, and the `Loopex.Trace.Entry` clause that redacts a keyword list's values under their own keys**, **the bounded `quiesce/1` that settles every active coordinator or names what it could not, together with the one coordinator change it needs in two halves — a drained abort pauses where cleanup would have begun, and its commit is presented once rather than retried on an ambiguous answer**, **`create_session_detailed/3` and `resume_session_detailed/3`, the two runtime-side functions carrying `disposition` and `control_entry` beside the unchanged create and resume**, the per-attachment event-count dispatcher queues, cancellation and recovery | A lease, a transport, a byte limit, residency policy or any daemon fact |
| `loopex_protocol` | Generation-2 records, validators, schema and vectors | Daemon behaviour or lease semantics |
| `loopex_store_local` | The unchanged local adapter, its 256 MiB log and 4 MiB frame ceilings, its `store_capacity_exceeded` and `store_log_too_large` refusals and its writer marker, which it takes at start and releases in its own `terminate/2` — so the daemon owns the Store *process* and stops it last in an orderly shutdown, and a store loss releases the marker before the daemon can act | Any daemon fact, lease, index or residency state |
| `loopex_daemon` | Marker-first process and socket lifetime, existence validation by calling core's query rather than by attaching or resuming, the peer-credential check, generation-2 negotiation, per-connection socket output buffers, the resident window and aggregate byte ceiling, attachment residency and eviction, the in-memory controller lease and writer-epoch check, the session index with its recorded-entry bound and its bounded pages, attachment residency and the one-way activation ceiling, and diagnostics | Store or coordinator internals, a second loop, policy selection, host identity, a durable record or a durable method |
| `loopex_composition` | The edge-assembly sequence, and the one new public function that runs it in the caller's process, calls the caller's `interrupt` checkpoint before each edge, and returns the edges — or, on an interrupt or a failure, returns the ones it has already started so the caller can unwind them — used by `RuntimeOwner` and by the daemon's owner | Daemon lifetime, ownership of what it assembles, or any knowledge of a daemon |
| `loopex_app_server` | The foreground stdio server unchanged, sharing the protocol mapping the daemon reuses, and its use of `with_runtime/2`, which M5 does not change | Daemon lifetime or residency |
| `loopex_cli` | `loopex daemon` with its readiness line, signal handling and exit classes, `loopex attach` with its roles, takeover presentation and cursor reconnect, the live `loopex sessions --daemon` form beside the unchanged offline one, and the host-side credential custody and registry it composes | Normative lease or session semantics, and any change to the released offline `loopex sessions` |
| `loopex_llm_reqllm` | The credential handoff, its sender, the token it accepts, the launcher's unchanged ADR 0019 scrubbing enumeration, the `req_llm` version floor, the re-pointed credential-plane proofs and the provider suite's concurrency | Any host credential policy, any new credential scope, where a host keeps the bytes behind a reference, or anything outside the adapter |
| `clients/node` | Socket connection, observer following and takeover presentation for the independent client | Normative semantics |

**Rejoin order.** Prerequisite decisions first. Then the new application with
its dependency-budget change, and the narrow core attachment change — the
first half of workstream 1, which the daemon's attach path needs before it can
be proved, and which is why workstream 1 is numbered first in the concept
pair. Then marker-first daemon lifetime and the socket over the local adapter,
workstreams 2 and 3, which may run together once the application exists. Then
the collaboration lease, workstream 4, on that base. Then the daemon-side
residency, replay and backpressure that sit above the core change, the second
half of workstream 1. Then the two-process workflow with the reference CLI and
the independent Node client. Then the documentation and the source-archive
proof, workstream 6, at the end because it describes what the others built.
Then independent review of the closure candidate.

Prove lifetime, refusal of a second daemon at the marker, shutdown on store
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
| Host composition — `apps/loopex_composition`, `apps/loopex_app_server/lib/loopex_app_server/host.ex`, `apps/loopex_cli` | The credential item makes every host compose a routing registry, a custody process and the token bound in its model options, and delete the operator's variable; the daemon *is* a new host composed the same way, and `host.ex:221` is where the variable is read today |
| The integration scripts — `scripts/check-release.sh` and its fixtures | Workstream 5 selects the real-provider lane; the daemon workstreams add `loopex_daemon` to `release_apps` and the Linux cross-uid case |
| Provider and credential documentation under `docs/operator/` and `docs/developer/` | Workstream 5 adds the operator credential sentence and the host-composition note; workstream 6 rewrites the same pages for the daemon |
| Closure evidence — `docs/evidence/M5-closure-runs.md` and `docs/evidence/README.md` | Every workstream's runs, the security review and the demonstration are retained on one page |

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
lease, its epoch matches and that connection holds a controller-capable
attachment. The single exception is `session.resume` on a verified dormant
session, which the holder may send before attaching. "Verified" means verified
by core's read-only existence query, not by having attached or resumed already:
acquire validates existence with that query and refuses an unknown ID with
nothing created. The lease record lives
in the daemon's memory, keyed by session, for as long as that session has a
lease or an acquisition; one owner process per session serializes its lease
transitions with its admission handoff, and that owner's failure is **scoped
to its session**: the controller's connection is sent `control_owner_lost`
and closed with its attachment,
every observer stays, and the next acquisition starts a fresh owner with a
fresh epoch. What keeps a successor's call from overtaking an older one is the
**admission relay**, a fixed daemon process that holds a ticket for every core
call and blocks the replacement's first grant until that session's tickets
settle. ADR 0033 fixes both rules. For
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
| 1 | `apps/loopex_daemon/test/session_lifetime_test.exs` | A real daemon operating-system process per state root. The startup ordering and its readiness line: the line appears on `stdout` only after the marker is held and the socket is bound, permission-checked and accepting, a client connecting the instant it appears is served, and each of a held marker elsewhere, a failed socket permission check and an exceeded index bound prints no readiness line and exits non-zero with its own class. Orderly shutdown on `SIGTERM` sent to the daemon, and on `SIGINT` sent to the launcher that forwards it as `SIGTERM`: the listener stopped accepting and the **admission cut** taken as **phase 1a**, one synchronous call in which the relay closes admissions and answers at once, followed by **phase 1b**, the owner's bounded wait for the tickets already inside core — proved by **two witnesses that must differ on one surface, the connection's own reply stream**: a ticketed mutation admitted in the instant *before* 1a is asserted to have settled before the drain begins, and a `session.prompt` sent on a still-open connection *after* it is asserted to be refused `daemon_stopping` with nothing admitted and no journal record — with `session.create`, `session.attach` and `artifact.read_chunk` sent after the cut refused the same way, the first two being the cases that would fail if either bypassed the relay and the third proving the refusal covers an unticketed method too; a case that holds a resume's replay past 1b's bound and asserts the stop **proceeds**, with that session reported `unsettled` from an `:acquiring` `Control` entry and fenced; and one asserting the 1a acknowledgement returns while a prompt commit is still in flight, which a five-second cut that waited for settlement would have failed into `relay_lost`; then core's `quiesce/1` running stop phases 2 to 5 — every active session's abort durably admitted and paused **before any** cancellation begins, asserted from journal order across two sessions, then every cancellation released together — each abort being the command a client's own `session.abort` writes, under a `command_id` core mints fresh per session per drain and asserted to be one no client sent, and **every enumerated session** fenced by a committed `advance_owner` — settled ones included — so no transaction for any of them can commit afterwards, each refused `:stale_owner_epoch`, and the answer's **three** lists — settled, unsettled and absent, with a `:unavailable` `Control` entry asserted to land in `absent` and be fenced — plus its per-session `fences` map, asserted `:committed` for the settled session as well as for the unsettled one — and `:not_needed` only for an entry that never had a coordinator — with **the case that would have failed before**: a settled session's straggler commit, held inside the Store and released during phase 7 while the Store is still alive, asserted refused `:stale_owner_epoch` and absent from the journal, and the `budget_ms` core derived reported on the daemon's stop line beside its `drain_id` — no shutdown-specific field on the record, the cause reaching the operator through `daemon.stopping` and `stderr` instead — driving each session's in-flight work to settle under that session's own grace within a drain budget derived from `cancellation_bounds/1`, and at the deadline terminating **every** enumerated coordinator and only then fencing every one of those sessions, in that order, before it answers — **both halves asserted**, with `settled` read on the surface that decides it — the coordinator's `{:session_status, owner}` reply, asserting the aborted run is in neither `active_run_id` nor `pending_work_ids`: a dispatched tool effect that settles carries its ordinary terminal fact in the journal, and a session whose cancellation finished but whose terminal is not yet committed at the budget is asserted **`unsettled`** rather than settled, and one held past the budget leaves its coordinator dead at the instant it is reported with **no terminal claimed for that work** — no `cancelled`, no `outcome_unknown` — its ambiguous mutation left as `commit_unknown` and resolved to exactly one outcome when that session is next activated, one bounded best-effort `daemon.stopping` naming `operator_stop` attempted per open connection — asserted received where the transport accepts it and an EOF alone accepted where it does not — the socket pathname **left in place** — no exit path unlinks, and the next daemon removes it before binding, asserted by a following daemon starting cleanly on that root — the Store stopped last, and exit `0` — with the foreground server opening the same root immediately afterwards, which is what proves the marker was released, and the journal differing from what an abrupt death at the same instant would have left by exactly the admitted-abort record and the fence record per enumerated session, both of which the released reader replays without a migration, with the unresolved transaction and its own fence identical. **Store loss is a separate fail-stop, not that sequence**: the Store terminates itself and releases the marker before the daemon can act, so the daemon observes the death, refuses service, closes every connection with `store_lost` (or `store_capacity_exceeded` where that was the reason), leaves the socket pathname in place and exits non-zero with that class on `stderr`, attempting no Store stop because there is none to attempt — proved by a second daemon starting on that root with no stale marker to recover. An active session progresses with zero attachments. An orderly stop releases the writer marker and records nothing false; an abrupt kill followed by restart activates nothing, then activates each session the root records when a client reaches for it, under the same placement identity and with no duplicate effect. The restart proves the marker path explicitly: the daemon opens with `recover_stale_writer: true`, a marker whose holder is proved dead is reclaimed, a marker whose holder is alive refuses with `store_writer_active`, and a marker whose holder cannot be decided refuses with `store_writer_unverifiable` — all three before the socket path is read, unlinked or bound. Simultaneous starts on one root resolve at the writer marker with exactly one listener and the loser never touching the socket. A root driven to the 256 MiB log capacity refuses the append with `store_capacity_exceeded`, the store terminates, the caller sees `commit_unknown`, and the daemon closes the listener and every connection and exits naming the capacity with nothing committed lost; a root whose log is already past that bound is refused at open with `store_log_too_large` rather than opened and truncated. `session.list` returns pages of at most 256 entries in session-ID order with an exact continuation cursor from the daemon index, carrying only session identity, recorded placement identity, `residency` and `controlled`. A session committed to the Store whose directory entry was never written — injected at that exact cut — is absent from the listing, still reachable by ID, and present in every listing after the activation that records it. A detached long-running command and a pending admission each cross the idle deadline with every client gone and run to completion, proving dormancy releases attachments and never a coordinator. The activation ceiling refuses the 65th activation of a daemon lifetime with `activation_ceiling_reached` and the restart remedy, and the count starts again after a restart because it counts per lifetime; a fresh `session.create` raises the count by one, and at the ceiling a create is refused with that same reason, so creation is proved to spend an activation rather than being exempt from the bound; attach consults the activation set rather than the listing index, proved at the 4,096-entry ceiling where a session activated but deliberately unrecorded still attaches; killing an activated session's coordinator leaves the daemon serving: the listing still reports `residency: active`, which remains true because this daemon did activate that session, and the next command for it returns core's own refusal forwarded unchanged, with the daemon adding and interpreting nothing; a root whose directory exceeds the recorded-entry bound refuses at start; at that bound a session reached by ID is activated and not recorded and the listing carries `index_full`; a session committed to the Store whose directory entry was never written is recovered both by its ID — validated through core's read-only existence query, with the case asserting the validation itself created no attachment and no durable record — and, by a client that never saw the ID, through ADR 0032's full command-identity sequence run to the end — replay `session.create` with the original `command_id`, core returns the historical result and so the session ID **without starting a coordinator**, the existence query answers `present`, the daemon repairs the directory entry and index row, control is acquired, and `session.resume` with a fresh resume command ID under the granted writer epoch is what activates the session — with the case asserting exactly one session in the root, the returned ID equal to the committed one, the replay itself starting no coordinator, the directory entry and index row present afterwards, the session listed, a live coordinator existing after the resume with the activation count risen by one, and a later prompt landing on that session and producing its events rather than on a second session or on nothing; an unknown ID answers negative from that query with nothing created, nothing attached and no lease granted; a directory write that fails during activation is reported to that client, leaves the session usable and reachable by ID while absent from `session.list`, and is written by the retry the next time the live daemon holds that ID — right after activation, on a later command for the session, or when a client reaches it by ID; a recorded session the daemon's composition cannot serve refuses at activation by name while every other session in the root activates. After an orderly stop the foreground server and the reference CLI reopen the same root and resume a daemon-created session under the same placement identity with identical replay. No durable method reaches the socket |
| 2 | `apps/loopex_daemon/test/socket_transport_test.exs`, `apps/loopex_protocol/test/public_schema_conformance_test.exs` | A raw-byte client over the socket negotiates generation 2 and receives generation 2's **own** exact schema digest, written out as a literal in the conformance module beside generation 1's and different from it by construction: `LoopexProtocol.Session.schema_digest/0` is taken over the generation, the ordered methods, the ordered record families, the ordered error codes and the limits, and generation 2 changes **all five**, so a generation 2 that negotiated generation 1's digest would be reporting a contract it does not serve. Generation 1's **method inventory, record families, error codes and limits** are proved unchanged in the same module — the four inputs it keeps —, so the generation-2 work is proved additive rather than asserted to be — but **exactly one pinned literal moves, and the case asserts the move rather than the old equality**: the `3a17…08f4` **schema digest** at `public_schema_conformance_test.exs:291-292`, because `@generation` is one of the five inputs `schema_digest/0` hashes (`session.ex:192-199`). The **two file digests at `:297-298` do not move**, because the manifests they pin already carry `loopex.experimental/1` and contain no occurrence of the retired name. The generation assertion at `:282` changes with the code it checks. The case asserts the new schema digest against a freshly computed value and asserts the other four inputs are byte-identical to what generation 1 served in `0.1.0`, which is what separates a rename from drift. **And it adds the assertion whose absence let a released discrepancy survive**: `Session.generation()` equals each served generation's manifest `/generation`, for generation 1 and generation 2 alike, so generation 2's new manifest and pin cannot drift from its code the way generation 1's did. A `0.1.0` client's generations list is refused `unsupported_generation` with nothing created, and the repository's Node client is proved against the new string. A generation-1-only initialize is refused with nothing created. Generation 2's record families include `daemon.stopping` and `daemon.notice`, the second carrying `index_write_failed` for an activation whose directory write failed, with literal vectors for each `daemon.stopping` reason a **client can actually receive** — `operator_stop`, `store_lost`, `store_capacity_exceeded`, and one `fatal:<class>` per linked component a client can actually be told about (`runtime_lost`, `transfers_lost`, `workspace_lease_lost`, `executor_lost`, `registry_lost`, `custody_lost`, `capability_lost`, `relay_lost`) — **not `listener_lost`**, which has no vector because the listener is what would have written it, so no client ever receives that reason, plus an uncorrelated `error` vector for `control_owner_lost` and three for ADR 0023's `detached` — overflow, aggregate pressure and idle eviction — each carrying `session_id` and the last completely emitted `event_cursor`, each written best-effort and followed by the close of **that connection alone**, and none of them ending the daemon, and vectors for `control_not_held`, `control_pending`, `control_capacity_reached` and `daemon_stopping`, the correlated refusal a command meets after the admission cut — and explicitly none for the startup-phase classes, which carry no vector because no socket exists when they occur and no client can be holding one, and its presence in the digest is what a generation 2 omitting it would fail on. Its delivery bound is proved both ways: a reading client receives the record before the close, and a client that has stopped reading until its 4 MiB output buffer is full receives nothing and is closed anyway, with the daemon making exactly one attempt and never blocking on it. Identical durable identities for the same command corpus through facade, foreground server and socket. Owner-only peer access proved in both layers: the socket's `0700` daemon-owned subdirectory and `0600` socket mode read back after bind, a permissive subdirectory or socket mode refused at start, a subdirectory the daemon does not own refused, a path component below the root that it did not create refused — and a state root at the ordinary `0755` the foreground server creates it with accepted, not refused, because the daemon owns the subdirectory and never re-permissions the root — and an unreadable or undecodable peer credential closing the connection before initialize — all in the fast check, which needs no second user — with the real cross-uid refusal and the same-uid success carried by two `@tag :cross_uid` cases the release check runs as `mix test --only cross_uid` on its single run, which closure requires to be on Linux, and where the script asserts exactly two executed tests so neither a zero nor a lone survivor can pass. Frame, fragment, malformed-input and over-long socket path refusals with distinct stable reasons, the path cases binding at the derived bound and at one byte past it on each platform the release check runs. A client disconnect recorded as transport loss with no cancellation and no interaction change. The generation-2 vectors are literal bytes with literal verdicts, held beside generation 1's in `apps/loopex_protocol/test/public_schema_conformance_test.exs`, never values generated from the implementation they check |
| 3 | `apps/loopex_daemon/test/collaboration_test.exs` | One lease per session in daemon memory with observers attached. Connection identity, epoch, held state, unexpired term and controller-capable attachment checked together before core admission or any durable write, including a known current epoch sent by an observer — the gate's **five conditions** exercised by **six cases** — ADR 0033 maps them one to one — each asserted separately in the daemon's own state and all six asserted to produce the **same** wire answer, `control_not_held` with nothing beyond the envelope, so no refusal is an epoch oracle. A holder's own `session.acquire_control` asserted to **renew**: same epoch, moved deadline, `renewed: true` — the branch a rule that refused every held lease would have swallowed. `session.release_control` asserted to carry `writer_epoch`, to refuse `control_not_held` from a non-holder, and to refuse ADR 0023's `invalid_request` — not `control_not_held` — when the field is absent, since a malformed request never reaches the gate. Takeover only after release or expiry, with a fresh epoch minted before the successor's first command. A killed controller fenced and its late commands refused. The three ways a controller stops holding, proved separately because the transport cannot tell two of them apart: an explicit `session.release_control` frees the lease at once, while an EOF from a politely closed client and a killed client both wait for expiry, with a takeover refused before the deadline and granted after. A lease owner killed while a mutation is in flight taking neither the daemon nor any other session down: that session's controller connection sent `control_owner_lost` and closed with its attachment, its observers still attached on their own connections and still receiving, the relay's ticket for the in-flight mutation retained, the replacement owner's first grant held until that ticket settles, and the previous holder's delayed command refused on both the holder and the epoch check. A daemon restart leaving every session uncontrolled with every earlier epoch refused. A controller abort cancelling work dispatched under an earlier process with a truthful cleanup outcome. The expiry linearization: a mutation blocked inside core across the deadline settles under its own lease while the eligible takeover waits and is granted only after it resolves; the holder's next mutation refused at the deadline; the acquiring request refusing with `control_pending` when its own deadline elapses first; and the holder disconnecting while a mutation is in flight — in every case exactly one of settle or refuse, never both. No control from content, metadata, answers or attachment order. Forward and backward wall-clock jumps changing neither live admission nor takeover timing |
| 4 | `apps/loopex/test/concurrent_attachments_test.exs`, `apps/loopex/test/session_existence_query_test.exs`, **`apps/loopex/test/runtime_quiesce_test.exs`**, **`apps/loopex/test/cancellation_test.exs`**, **`apps/loopex/test/trace_session_test.exs`**, `apps/loopex_daemon/test/replay_residency_test.exs` | Core's read-only session-existence query answers exactly one of the closed set `present`, `absent`, `invalid_id`, `store_unavailable` and `unexpected`, from a fresh process against a real root, with one case per result. `store_unavailable` is injected through the controllable fault store the suite already has, `Loopex.M1RuntimeTestStore`, whose `fail_reads/2` hook makes its reads refuse — not by making the root unreadable, which cannot produce that answer on the real adapter: `Loopex.Store.Local` answers `ownership_head` from `state.store`, in memory, so a root that has become unreadable on disk still answers. `unexpected` is injected by a stub answering outside the set. It is proved to create no attachment, no incarnation, no durable record and no Store write: the root's journal and session directory are byte-identical before and after a run of queries, including for unknown and malformed IDs. Control acquisition proceeds only on `present`; the other four fail closed with no attachment, no lease and no activation, and name four distinct reasons, so an unreadable store is never reported as an unknown session. Several core attachments to one session remain independent when one detaches or backpressures. A snapshot anchored at the committed sequence, then contiguous at-least-once buffered and live delivery across the window boundary with no gap. Core is the only replay owner: every delivery case runs a second time with the daemon's resident window disabled and a third with it dropped mid-stream, all three byte for byte identical, so the window is proved to establish no snapshot and no cursor. Aggregate reclamation follows the fixed order ADR 0032 sets — zero-attachment windows by ascending last delivery, then the furthest-behind session's window, then detachment — including the case where zero-attachment windows alone consume the ceiling. A slow observer detached at its last emitted cursor while the controller and the other attachments continue. Per-session and per-daemon limits refusing independently. Idle eviction and reconnect with no missing durable event, any duplicate deduplicated by session ID, sequence and event ID. Retained encoded bytes at or below the 4 MiB output buffer, 16 MiB window and 512 MiB aggregate ceilings, enforced in the daemon-owned stages, exercising 512 attachments and maximum-sized output records separately, with observed process RSS recorded beside the ceilings. Progress coalesced or dropped with counted drops and no journal delay |
| 5 | `apps/loopex_daemon/test/multi_client_workflow_test.exs`, `apps/loopex_daemon/test/external_socket_workflow_test.exs`, `docs/evidence/M5-closure-runs.md` | The operator workflow end to end, each step a command an operator types: `loopex daemon` refusing once per missing or invalid composition input with its own class and leaving no marker or socket behind, then starting and printing the one-line JSON readiness record; `loopex run --daemon` creating and driving a session; `loopex resume --daemon` activating a dormant one through acquire, resume with a fresh command ID, attach; `loopex attach` refused with `session_dormant` at the **attach** step against a session this daemon has not activated, in both roles, while `loopex resume --daemon` acquires that same dormant session and succeeds — the two asserted together, since refusing dormancy at acquisition would break the resume path; `--take-over` on a dormant session asserted to release its lease before exiting, proved by `loopex resume --daemon` succeeding immediately afterwards rather than refusing `control_held`; a CLI holding a lease attempting an explicit release on every exit path where its transport is still writable, and the killed-client case asserted to differ — no release, the lease waiting out its term, which is what ADR 0033 already fixes; `--after` starting strictly after a sequence and its absence replaying from `0`; a controller whose renewal fails continuing as an observer and sending no further mutation; a reconnecting controller retrying acquisition with backoff until its own lease can have expired and then holding a fresh lease with a fresh epoch before any mutation, and the variant where another client took over meanwhile exiting `control_held` rather than retrying against a live holder. From a fresh extraction of the exact candidate — staged with `git archive`, extracted and built outside the checkout — an operator follows the documented prerequisites and commands, supplies workspace, provider and policy inputs, starts the daemon, and drives one session from the reference CLI as controller and the Node client as observer, kills the controller, takes over from the observer and aborts cross-process work. The documented CLI build and the provider companion build both run inside that extraction, on the archive-carried source identity rather than on `.git`, with the missing, unsubstituted-or-malformed, changed-during-build and mismatched-commit refusals each proved and the identity the build reports asserted equal to the commit the archive was staged from. The attended real-provider cases run from that extraction, against the escript it built there. The workflow drives ADR 0030's existing core spans end to end — command admission, commit, effect intent, publication, interaction, and the model, store, policy and executor port callbacks — with the same bounded identity metadata an embedded caller produces, and no event outside that closed inventory is emitted by anything M5 adds. Daemon-internal functions are proved by the daemon's own tests and logs: `Loopex.Trace` traces only processes the runtime owns, flagged with `set_on_spawn` from the runtime's supervisor, and the daemon's listener, connections and lease owners are host processes above the runtime, so no trace-session witness is claimed for them. `VERSION` in the extracted tree is exactly `0.2.0`. Every tracked file under `docs/operator/` and `docs/developer/` has been read against the candidate, including the ones M5 leaves unchanged, recorded as a checklist derived at that commit — `git ls-files -- docs/operator docs/developer`, sorted, one row per path, each row marked *updated* or *reviewed unchanged* — retained with the closure runs. The derivation is over **every tracked file** in those two trees, not only Markdown, and that is deliberate: the gate promises that every file under them was read, so a diagram, a fixture or a data file added later must appear rather than slip through a `*.md` filter that was true when it was written and silently false afterwards. It also avoids a pathspec trap, checked rather than assumed: `git ls-files 'docs/operator/**/*.md'` without `:(glob)` matches nothing at all and would have made the gate pass vacuously. The directory form returns 26 tracked files as of this revision — 18 under `docs/developer/` and 8 under `docs/operator/`, all Markdown today — and the closure checklist states the count it derived so a reviewer can see the list was not empty, with every path in the tree present, no row unmarked, and each finding named and resolved before the closure packet |
| 6 | `apps/loopex_llm_reqllm/test/credential_plane_test.exs`, `apps/loopex_llm_reqllm/test/adapter_test.exs`, `apps/loopex_llm_reqllm/test/provider_retainer_boundaries_test.exs`, **`apps/loopex_cli/test/`, `apps/loopex_app_server/test/`, `apps/loopex_daemon/test/`** for ADR 0034's host-owned-process cases — read-once, environment deletion and a redacted crash report, each proved at the host whose composition it is about — and `docs/evidence/M5-closure-runs.md` | From the completion of a reference host's composition onward, the configured credential name is absent from the parent VM's environment and no function in the adapter's call path reads the environment for a credential, before, during or after a call — "during" observed from inside the call at child readiness; composition is proved to read the operator's variable once and delete it. Every row of ADR 0034's failure table resolves to its closed-set atom and retains no copy: `:no_token` for an absent token, `:invalid_token` for a malformed one, `:unavailable` for a token with no registry row, a gone registry, a dead custody process and a malformed successful reply, and each of `:missing`, `:expired` and `:oversized`, a term outside the closed set reported as `:unavailable`, and a custody process blocking past the invocation deadline, where the **guardian** kills the sender and reports `:timeout`, asserted distinct from every refusal so the guardian can tell a refusal from a silence and asserted to bound the invocation whatever the custody process does. Two resolutions in flight at once is a success case, not a refusal: both invocations complete, each with its own sender, its own custody reply and its own frame — carrying the **same** credential, because one runtime composes one token, which is the point the two-runtime isolation case below carries and this one does not. Tracing is proved against `Loopex.Trace` including the process-level exclusion M5 adds to it and the `Entry` keyword-key redaction beside it — the token travelling in model `options` through `module.complete/3` (`session_coordinator.ex:3231`) reaches the coordinator **before** the sender exists, so what keeps it out of an entry is redaction rather than exclusion, and the credential bytes after the exclusion point are what the absolute no-trace claim is about; a tracing capability that is absent, malformed or bound to a dead process is asserted to **refuse** the invocation with `:unavailable` before the token is routed, the reversal of the earlier 'absent proceeds' rule, with the composition-time refusal asserted separately, and the decisive case names `:gen_tcp` on purpose: a trace session configured with `:gen_tcp`, `Loopex.LLM.ReqLLM.ProviderBridge` and `Loopex.LLM.ReqLLM.ProviderCodec` runs a real invocation with a **one-byte canary** credential, and the tracer is asserted to receive **no raw trace message from the sender process at all** — not for `:gen_tcp.send/2`, not for anything — while a non-excluded control process performing the same `:gen_tcp.send/2` in the same session does produce one, so the case cannot pass by tracing nothing; the canary appears in no message and no entry. Under the **default** configuration no trace entry names `ProviderBridge.route_credential/2`, `receive_custody_reply/2` or `write_credential_frame/2`, the tracer receives no raw trace message for them and no credential bytes or token appear anywhere — because `modules/1` expands a namespace through the application's own module list and the adapter is not a `:loopex` module. The ordering claim is proved rather than asserted: `exclude_self/2` returns before the token is routed, and a session started concurrently with it yields no message from the sender either way round. The keyed shape is proved as defence in depth, not as the mechanism: each of the three bridge functions is called with a one-byte credential and no captured entry contains that byte — which matters because size alone does not protect, since running `Entry.render/2` shows a bare or tuple-wrapped credential of 1, 40, 51 or 64 bytes rendered verbatim and only a credential-keyed value placeholdered at every size. A further case asserts the three function identities, so no tier can pass vacuously. The exclusion mechanism itself is proved in core's own suite: a process flagged by `:set_on_spawn` inheritance calls the exclusion and its subsequent traced call produces nothing while a non-excluded control call produces a message, at both toolchain pairs. The registry lookup is proved to carry no credential. Two runtimes composed in one VM, each with its own registry, custody and token, are proved isolated: a token minted for one answers `:unavailable` in the other, so tokens do not cross runtimes, and neither runtime's child — nor either child's diagnostics — ever observes the other's credential. That case subsumes the old within-one-runtime concurrency witness, which a composition-bound token makes meaningless: two invocations of one runtime necessarily carry the same token, so what has to be proved independent is two *runtimes*. A registry killed under a composed runtime makes every later resolution through that handle answer `:unavailable`, and the adapter is proved not to retry, wait or rebuild — recomposition is the only repair. Every re-pointed case of `apps/loopex_llm_reqllm/test/credential_plane_test.exs` passes with its assertion unchanged in meaning: version refusal and bootstrap refusal before any credential, late delivery after expiry impossible, rotation between invocations, two live credentials in one VM, sink loss, one child's loss not poisoning another, ordinary host messages and returned reasons, every child Logger form and metadata, and the four crash-report cases. The child-environment witness inside the version-refusal and bootstrap-refusal cases — the child's recorded `entry-env` marker refuting `Adapter.credential_variable()` — holds unchanged. The 65,536-byte ceiling case in `provider_retainer_boundaries_test.exs` is re-pointed too, because that module delivers its credential through `System.put_env` in its `setup` and again in the case body; that invocation's own custody process holds the oversized value instead. The drift-protection case in `adapter_test.exs` survives strengthened, with an exact allowlist: `[]` for `provider_bridge.ex`, the arity-zero enumeration and only that for `provider_launcher.ex` because it is ADR 0019's first-image scrubbing rather than a credential read, `provider_worker.ex`'s two non-secret crash-dump names, and `[]` everywhere else. Because the launcher's read survives, the case also asserts its *use*: the enumeration's result flows only into the Port's removal list, every name is mapped to `false`, none is compared against `credential_variable/0`, and no value reaches the sender, the frame or any caller. Its scan is widened from one `System.get_env(...)` expression to every route an environment read can be written — `System.get_env/0`, `/1` and `/2`, `System.fetch_env/1` and `fetch_env!/1`, `:os.getenv/0`, `/1` and `/2`, `:os.env/0`, and indirect application through `apply/3` or a captured function — each unpinned route refuted outright. The `req_llm` move to `~> 1.24.0` — pinned to that minor, not to `~> 1.24`, so the reviewed diff is the version actually built against — lands as its own reviewed change before the credential change, with the reviewed changelog diff across the intervening releases named in the commit, the adapter and streaming-conformance suites green, and the *existing* real-provider case at closure run against it. It adds no call path: nothing in M5 calls anything `1.24.0` makes newly reachable, and no second provider, second credential or new release-check case enters this milestone. It is explicit M5 scope, separate from ADR 0035 and not conditional on it. A security review by someone other than the implementer is recorded. The twelve modules are then converted to run concurrently one at a time, each kept only while its application's suite stays green, any module that stays serial keeping its reason beside it, and the measured duration is recorded beside the M4-closure baseline as evidence about the change rather than a threshold |

**Checks a boundary selects.** Beyond `bash scripts/check.sh`, which every
merge needs green in hosted CI, M5 selects exactly these, from the
[selection table](../developer/verification.md#concept-verification-selection):

- generation 2's schema and vectors select the independent client workflows
  (`--only node_client`, part of `bash scripts/check-release.sh`) and an
  update to `docs/developer/compatibility-surfaces.md` in the same change;
- a new or changed operator command — `loopex daemon`, `loopex attach`,
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
- the Store and recovery are touched only through the daemon's use of the
  unchanged adapter, so nothing more runs and the review confirms the
  fault-injection and old-reader cases still cover the change;
- `.tool-versions` and the toolchain floor are unchanged, so nothing selects
  the floor row for that reason.

**Closure runs.** At the candidate: hosted CI's green fast check on that
commit is the current-pair evidence; `bash scripts/check.sh` runs once under
the floor pair, `mise exec erlang@27.3.4 elixir@1.18.5-otp-27 -- bash
scripts/check.sh` with its own `MIX_BUILD_ROOT`; and
`bash scripts/check-release.sh` runs once on the current pair **on Linux**, which closure requires because the cross-UID witness needs a second unprivileged user and `SO_PEERCRED`, neither of which a Darwin lane supplies; the evidence page records the platform beside the result. It runs with the
provider credential and the pinned Node version in
`scripts/fixtures/m4/client-toolchain.txt`.

That release check is where Outcome 2's cross-UID witness lives, and it needs
a selector it does not have today. `scripts/check-release.sh` runs each
`release_apps` lane as `mix test --only real_provider --only node_client
--include long_bound`: three selectors, none of which a cross-UID case
belongs to. So M5 adds one — the cases are tagged `@tag :cross_uid` — and the
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

`loopex_daemon` joins the `release_apps` list in the change that adds its
first release case. Joining that list is separate from the cross-UID lane,
which is its own invocation described above and not a `release_apps` run:
every `release_apps` lane already runs
`--include long_bound`, so the daemon's long-duration bound tests are carried
there and the application does not also join `long_bound_apps`, which exists
for applications with no other release test. Each run's revision, platform,
toolchain, result and measured duration is retained on
`docs/evidence/M5-closure-runs.md`, indexed in `docs/evidence/README.md`,
together with the Outcome 6 security review and the attended demonstration's
provider and model identities. Complete logs stay with the maintainer.

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
`README.md`, and `CHANGELOG.md`. Outcome 6 adds the operator's credential
sentence and the developer note on host composition to the pages that describe
provider configuration.

**Two page-level obligations are named here rather than left to the writer**,
because both are facts an operator cannot derive from the software and a
reviewer can check against this sentence at closure.

- **`docs/operator/daemon.md` must state the maximum graceful stop as the sum
  of the eight phase bounds**, in the form the lifecycle section fixes:
  **`budget_ms` + 585 s**, being 5 s for closing admissions, 300 s for
  settling what was already admitted, 150 s for abort
  admission, `budget_ms` for cancellation, 5 s for coordinator termination,
  90 s for the fence, 5 s for daemon teardown and 30 s for the Store —
  together with the sentence that keeps the number from being read as a
  duration: **four** of the seven fixed terms — 1b, 2, 5 and 7 — count the
  Store's thirty-second ceiling for a wedged filesystem, **one** — phase 4 —
  is the coordinator's own shutdown value, and the remaining **two**, the five
  seconds for closing admissions and the five for the teardown, are this
  plan's own chosen numbers, which the page says rather than implying every
  term is derived — and an ordinary stop finishes in milliseconds —
  with the seven constants written out beside the one derived term, so an
  operator setting a `TimeoutStopSec` adds up numbers rather than trusting a
  total. It must say that seven of the eight are fixed and
  that the drain term alone is **not** read off the daemon's own
  `--cleanup-grace-ms`, because each session drains under the grace it
  committed and a root may carry sessions composed earlier, so the page must
  point an operator at the figure the daemon **reports in its stop line**
  rather than at one they can compute from flags. And that
  a shorter external service-manager timeout turns the stop into a **forced
  shutdown**, where work that would have settled does not and the writer
  marker may be left for the next daemon's verified recovery. It must also distinguish the **usual
  millisecond** Store release from that 30-second **safety ceiling**, so the
  number is read as a bound on the worst case rather than as the cost of every
  stop. Nothing is written until the implementation exists; this row is what
  makes closure unable to forget it.
- **`docs/developer/app-server-protocol.md`, its companion,
  `docs/developer/compatibility-surfaces.md`, `docs/developer/agent-context-map.md`
  and `docs/operator/app-server.md` must carry the renamed generation string**
  and the one-line migration it implies.

Both are covered by the docs gate, which derives its checklist from
`git ls-files -- docs/operator docs/developer` over **every** tracked file
rather than a Markdown filter, so neither page can be marked reviewed-unchanged
by accident.

Every other tracked file under `docs/operator/` and
`docs/developer/` is read at the candidate and left unchanged only
deliberately, and the derived checklist in Outcome 5's evidence row is what
makes that auditable rather than asserted.


**Every core change has a core witness, named here to file, case and lane.**
Three of the five were witnessed only downstream — in the daemon's lifetime
suite and the adapter's credential suite — and three of their properties
cannot be reached from there at all: quiesce's `absent` branch needs a
`Control` entry whose coordinator has already died (`control.ex:821-823`),
`exclude_self/2`'s two fail-closed paths need the tracer mid-restart and `Control` mid-restart, and
`Control` pruning an excluded sender needs that sender's `DOWN`. All three are
core-internal states a daemon cannot construct through the socket.

| Core change | Core witness | Cases | Lane |
| --- | --- | --- | --- |
| Concurrent attachment | `apps/loopex/test/concurrent_attachments_test.exs` (**new**) | `two attachments to one session coexist without replacement`; `one detaching leaves the other delivering`; `an attachment is released when the process that attached it exits`; `an attachment released by its process exiting leaves no open transfer`; `the installed attachment records the attacher pid and the monitor reference`; `replace true supersedes only the attaching process's own prior attachment and releases its transfers`; `replace true from a second process supersedes nothing of the first's`; `replace true leaves every other connection's attachment to that session delivering`; `the dispatcher holds no attachment for a dead attacher`; `one backpressuring does not stall the other`; `each carries its own cursor and incarnation` | fast |
| Read-only existence query | `apps/loopex/test/session_existence_query_test.exs` | one per result of the closed set | fast |
| **`quiesce/1`** | **`apps/loopex/test/runtime_quiesce_test.exs`** (new) | `admits every abort before any cleanup begins`; `a coordinator commit during phase 2 is served by Control and its session settles`; `a drain task that crashes fences its session and does not reach the caller as an exit`; `a drained abort commit is presented once and never re-presented on commit_unknown`; `a fresh create executes nine store calls, ten with the retry`; `attach executes one store call over an empty session and two over eight events`; `resume of a twelve-record session executes eleven store calls`; `a drained abort admitted behind the cleanup callback spends five store calls in phase 2`; `the cleanup callback commits at most twice on either branch`; `quiesce admits no abort into an acquiring entry, and terminates and fences it instead`; `a fence executes three store calls at worst`; `releases cancellation concurrently once every admission resolves`; `an empty active set drains with a zero budget`; `reports a Control entry whose coordinator has died as absent`; `reports an unavailable Control entry as absent and fences it`; `reports an acquiring entry as unsettled and fences it`; `an acquiring entry whose owner_ready cast is in flight is terminated and reported unsettled`; `settled is read from the coordinator's status, not from the cancellation finishing`; `a cancellation that finished with its terminal commit held is unsettled, not settled`; `fences an unsettled session and refuses its paused transaction as stale`; `fences an absent session too`; `fences a settled session too, and refuses its straggler commit released during the store phase`; `reports not_needed only for an entry that never had a coordinator`; `a fence refused stale_owner_epoch is superseded with no second attempt`; `a fence refused stale_journal_version is superseded too, not an error`; `a fence answering commit_unknown is resolved through transaction_status under the same derived tx_id and reported unsettled with fences[id] == {:unknown, head}`; `a fence id recomputed from the head alone matches the one the drain used`; `a session whose abort admission is ambiguous has no cleanup released and is fenced`; `a phase-2 task shut down mid-call still leaves the coordinator admitting the abort and pausing at the split` | fast |
| **The two-phase abort-path split** | **`apps/loopex/test/cancellation_test.exs`** (existing; the file that already drives an abort against a receipt arriving mid-reduction) | `a drained abort commits without beginning cleanup`; `a client abort still begins cleanup on its commit reply path` — the pair that proves the split changed the drain and nothing else | fast |
| **`Loopex.Trace.exclude_self/2`, `Control`'s excluded-pid set and `Entry`'s keyword-key redaction** | **`apps/loopex/test/trace_session_test.exs`** (existing; extended) | `the named MFAs produce no raw message under an explicitly named module, before any process flag is set`; `an excluded process produces no trace message`; `the exclusion survives a tracer restart`; `a new session skips an already-excluded pid`; `fails closed while the tracer is absent`; `fails closed while Control is unavailable` — the case that constructs a `Control` restart, and which therefore asserts what that costs: every child after `Control` restarts with it, so every session coordinator in that runtime is gone and the case starts a fresh session rather than reusing one;  `the excluded set returns to baseline after the sender exits`; `a keyword list's value is redacted under its own key`; `the same value under a key naming nothing is rendered, so the case cannot pass vacuously` | fast |

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

**Every bound derived from a call count carries a witness that executes the
path and asserts the count.** This is a rule of this plan rather than a remark
about one case, and it exists because two independent readings of the create
path produced two wrong numbers before a traced run produced the right one:
six by reading, then nine — ten with the retry — by executing. A count read
off the source is a hypothesis; only a run is evidence, and a bound built on a
miscount is a bound the stop silently exceeds.

So each of the three derived phase bounds has a case that **counts adapter
calls while the path runs**, by tracing the adapter module —
`:erlang.trace_pattern({Loopex.Store.Local, :_, :_}, true, [:global])` where
the adapter is reachable, and the suite's controllable store's own call log
where it is not (`Loopex.M1RuntimeTestStore`, which core's tree can reach and
`Loopex.Store.Local` is not) — and asserts an exact number, not a bound:

| Bound | What the case executes and counts | File | Case | Lane |
| --- | --- | --- | --- | --- |
| Phase 1b, ten calls | A fresh `session.create` driven to its reply, asserting **nine** adapter calls in the traced order and **ten** when the genesis commit is made to answer `commit_unknown` once | `apps/loopex/test/runtime_quiesce_test.exs` | `a fresh create executes nine store calls, ten with the retry` | fast |
| The two history-paged kinds, at **fixed** sizes, so the claim that they have no constant is itself checked | `session.attach` over an empty session asserting **1**, and over an eight-event session asserting **2**; `session.resume` of a **twelve-record, eight-event** session asserting **11**, in the traced order, including **two** `transact` calls — the staged owner attempt and the advance | `apps/loopex/test/runtime_quiesce_test.exs` | `attach executes one store call over an empty session and two over eight events`; `resume of a twelve-record session executes eleven store calls` | fast |
| Phase 2, five calls | A drained abort admitted behind **the real deepest callback**, not a synthetic one: a run is driven to `complete_cleanup/3` so that the coordinator commits the executor fact and then the run terminal in **one** callback, each commit made to answer `commit_unknown` once — four calls — and the drained abort is admitted behind it. Asserts **five**, and asserts the four belonged to **one** callback, which is what makes the unit the callback rather than the call. A second case asserts the acquisition callback is never what an admission waits behind, by driving a session that is still `:acquiring` and asserting **no abort is admitted for it**. A third pins the ceiling itself: the same cleanup callback driven down its `:unconfirmed` branch is asserted to commit **twice, not three times**, the executor fact and the unproved tool result being mutually exclusive | `apps/loopex/test/runtime_quiesce_test.exs` | `a drained abort admitted behind the cleanup callback spends five store calls in phase 2`; `quiesce admits no abort into an acquiring entry, and terminates and fences it instead`; `the cleanup callback commits at most twice on either branch` | fast |
| Phase 5, three calls | A fence run to `commit_unknown` and resolved, asserting **three** — head, advance, status | `apps/loopex/test/runtime_quiesce_test.exs` | `a fence executes three store calls at worst` | fast |

All three are **core** witnesses, because all three paths are core's: the
daemon contributes no Store call of its own to any of them. A case that
asserted "at most N" would pass on a path that had grown shorter *or* been
restructured into something the phase no longer bounds; asserting the exact
number is what makes a later change to the path fail here rather than at an
operator's `TimeoutStopSec`.

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
journal, its adapter and its format are unchanged; the embedded API, public
events, snapshots, artifact formats and the executor protocol are unchanged.
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
Workstream 3 already restructures `LoopexProtocol.Session` from one generation
in module attributes into one module serving two, with both digests pinned
side by side; the string is a module attribute in exactly that restructuring.
Renaming later would mean a second pass over the same module, the same
vectors, the same clients and the same documents.

**The rejected option is recorded:** keep `loopex.session.v1-experimental`
beside `loopex.experimental/2`. It was rejected because the two shapes would
then coexist for as long as generation 1 is served — which is the whole of
0.2.x and beyond — so every client, document and vector would carry both
conventions, and the collision above would still be waiting at the freeze.

**What that costs, exactly.** Generation 1's **contract** is unchanged: the
same methods, the same record families, the same error codes, the same limits.
What changes is its **name** — and the name is one of the five inputs
`LoopexProtocol.Session.schema_digest/0` hashes (`session.ex:192-199`), so
generation 1's **schema digest** changes with it and is re-pinned. Exactly one
pin moves.

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
each manifest by its **file digest** and never compares the manifest's
`/generation` with `Session.generation()`.

That reframes the rename. It is not a break introduced for tidiness; it is the
change that makes the **code agree with the artifacts already published beside
it**, and it closes a live discrepancy in a released surface rather than
opening one. The manifests are the thing being conformed to, not files to
edit.

The plan says all of this wherever it used to say the generation-1 pins were
untouched, because a reader who trusts that sentence would read a failing
build as drift — and equally, a reader told that three pins move would go
looking for two changes that are not there.

Outcome 6 changes no public surface. The `Loopex.Model` callbacks, the private
provider codec's version and frame kinds, the build manifest and ADR 0019's
process topology are all unchanged. Its one compatibility effect is on host
composition: an embedder that relied on the adapter reading the environment
for it passes a credential token with the call instead, over a registry and custody it composes, and gets the
adapter's ordinary refusal to dispatch rather than a silent fallback if it
does not.

<a id="technical-plan-migration"></a>
### Migration and Rollback

Concept: [Rollout and compatibility](M5.md#concept-plan-rollout).

No journal migration exists in M5. The daemon reads and writes the same local
log the M4 foreground server and the CLI write, under the same placement
identity, so a state root moves between the daemon and the foreground surfaces
by stopping one and starting the other. Prove that an orderly daemon stop
releases the writer marker and that the foreground server and the CLI then
resume a daemon-created session with identical replay.

A root that reaches the local log's 256 MiB capacity is retired, not migrated.
The daemon has already exited by then, because the capacity refusal terminates
the store; the operator moves the root aside and starts a fresh root. A root already past
that bound refuses at open with `store_log_too_large`, which is the message
the operator page must explain, because it is what an operator meets when a
root grew past the ceiling under an earlier process. A session in a
retired root is reached only by reopening that root.


**The one migration note M5 owes, and it is one string.** A `0.1.0` client
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
residency, index or lease state, because none of those is persisted. A
daemon-owned root is an ordinary local root the moment the daemon releases its
writer marker; a root whose marker is still held by a dead daemon is released
by the adapter's existing liveness-probe discipline and its
`store_writer_active` and `store_writer_unverifiable` refusals, which M5 does
not change. Outcome 6's rollback is reverting the adapter change; nothing
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
M5 adds no external dependency. No transport library, socket abstraction layer
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

Supply `loopex daemon`, `loopex attach` and a live form of `loopex sessions`
in the reference CLI, on the contracts below, and extend the client in
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

- a tracked `SOURCE_IDENTITY` file holding `$Format:%H$` and the commit date,
  with a tracked `.gitattributes` marking it `export-subst`, so `git archive`
  substitutes the exact commit into the extracted copy while the checkout's
  copy keeps the unsubstituted literal;
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
- the provider build manifest embeds the resolved commit id together with that
  source digest, so an identity naming a commit whose tree is not what was
  built is detectable rather than merely trusted.

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

- **the closure evidence records the candidate's inventory**: the output of
  `git ls-files -z` at that commit, and its SHA-256, retained on
  `docs/evidence/M5-closure-runs.md` **beside the archive's own digest and
  commit**. The closure runner is in the checkout when it stages the archive,
  so this costs one command it is already positioned to run;
- **the extracted-build witness compares against that recorded inventory**,
  not against anything inside the extraction: it takes the built tree's
  **path set**, so a file created or deleted during the build is caught even
  if every file it names is byte-identical, and its **bytes**, as a SHA-256
  over each path's contents in inventory order, and requires both to match
  what was recorded;
- exactly **one** exclusion, named rather than implied: the build-output roots
  `_build/` and `deps/`, which the build is supposed to create. Nothing else
  is excluded, and the list of exclusions is part of the retained evidence, so
  a later exclusion cannot quietly widen what "unchanged" means.

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
sets out; every application reads it at compile time. The release-ready source
archive is staged from the exact committed candidate with `git archive`,
extracted outside the checkout, compiled, and used to run the two-process
workflow from the extraction following the operator guide; its SHA-256, source
commit and tree are retained with the closure runs. The release itself is one
annotated `v0.2.0` tag on the integrated closure commit, created on the
maintainer's separate decision, after which the tag object is verified
annotated, `v0.2.0^{commit}` is the reviewed integration commit and reachable
from `main`, and `git show <that commit>:VERSION` is exactly `0.2.0`. Do not
move the tag, and publish no package, binary, installer or service unit.

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

Exit status: `0` for a page printed, including an empty one; non-zero with the
reason on `stderr` when the socket cannot be reached, the peer check refuses,
or the daemon refuses the arguments.

#### `loopex daemon`: starting, readiness, stopping

**Composition inputs.** A daemon is a host, so it takes the same inputs the
app-server host takes today, as flags with environment fallbacks, and refuses
the same way — `LoopexAppServer.Host` documents them and halts on standard
error when one is missing or unusable. The daemon's set, each with its default
and its refusal class:

| Input | Flag / environment | Default | Missing or invalid |
| --- | --- | --- | --- |
| State root | `--state-root` / `LOOPEX_HOME` | none | `state_root_required`, or `state_root_unusable` when it cannot be created or read |
| Workspace | `--workspace` / `LOOPEX_WORKSPACE` | none | `workspace_required`, `workspace_unusable` |
| Provider launch | `--provider-launch` / `LOOPEX_PROVIDER_LAUNCH` | none | `provider_launch_required`, `provider_launch_invalid` |
| Policy | `--policy` / `LOOPEX_POLICY` | **none, deliberately** — authority is the operator's to name, as the app-server host already insists | `policy_required`, `policy_unknown` |
| Provider credential | `LOOPEX_PROVIDER_API_KEY` | none | `provider_credential_required`, checked at start so an unattended launch refuses in a second rather than at the first dispatch. The daemon reads it once, deletes it from its environment and holds it in custody under ADR 0034 |
| Cleanup grace | `--cleanup-grace-ms` | the composition default | `cleanup_grace_invalid`, and the admitted domain is **an integer from 1 to `18_446_744_073_709_551_615`**, exactly core's own (`@max_cleanup_grace_ms`, `apps/loopex/lib/loopex/executor.ex:75`, and `grace_ms >= 1` at `:456`). Zero is refused, which the local executor's own validation would admit (`apps/loopex_executor_local/lib/executor.ex:897`, `>= 0`): a daemon composed with zero would carry a grace core cannot derive bounds from. A very large value is **accepted, not refused** — the daemon never passes it to a `receive … after` unsliced, for the reason the wait rule below gives |
| Project resources | as the host already takes them | as today | as today |
| Socket path | `--socket` | `<root>/daemon/daemon.sock` | `socket_path_too_long`, `socket_permission_unverified`, `invalid_socket_path` for a path outside the root's `daemon/` directory |

Every one of these is refused **before** the marker is acquired where that is
possible, so the common operator mistake costs nothing and leaves nothing
behind; the ones that can only fail later are covered by the reverse-cleanup
rule.

A `--socket` override is constrained exactly as the default is — its parent
directory must be owned by the daemon's user and mode `0700`, no component
below the state root may be a symbolic link the daemon did not create, and the
socket is created `0600` and verified after bind — **and it must resolve
inside the selected root's `daemon/` directory**. A path outside it is refused
at startup with `invalid_socket_path`, before the marker is acquired.

That last constraint is not tidiness. Socket ownership in this design is
derived from the writer marker, and a marker is per state root: two daemons on
two different roots hold two different markers and have no exclusion between
them at all. An override that let them name one path would put two daemons
with equal claim on one file, which no rule in this plan can adjudicate.
Inside one root there is exactly one marker holder, so there is exactly one
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

It is printed **only after** all of: the Store is open and its writer marker
held, the `0700` subdirectory and `0600` socket exist with their ownership and
mode read back and verified, and the listener is accepting. A process manager
that waits for that line is waiting for a daemon that can actually serve,
which is why it is printed there and not earlier; anything sooner would invite
a client to connect to a socket the daemon has not finished checking. Every
diagnostic, warning and failure goes to `stderr`, so `stdout` carries the
readiness line alone and stays machine-readable.

**Stopping.** Sent **to the escript**, `SIGTERM` begins the orderly shutdown
below and is the only signal that does. Sent **to the launcher**,
`apps/loopex_cli/bin/loopex`, **any of `INT`, `TERM`, `HUP` or `QUIT`** does,
because the launcher traps all four and forwards `kill -TERM` to its child.
The daemon itself installs no `SIGINT` handler and cannot: the
emulator reserves that signal and `:os.set_signal/2` refuses the name, as the
signal section below sets out with the full route-by-signal table.
There is no `daemon.stop` method on the wire: stopping is an operator act
against the process, and a client-issued stop would let one connection end
every other client's session residency, which is authority the socket does not
carry and this milestone does not grant.

**Exit status.** `0` when an orderly shutdown completes, whatever the sessions
were doing. Non-zero, with one reason line on `stderr`, for every fatal exit,
naming its class rather than a stack. The classes are the fatal-class map's,
in full, and this list is derived from it rather than summarising it:

- **at startup**, before any socket exists: `store_writer_active`,
  `store_writer_unverifiable`, `store_log_too_large`, `socket_path_too_long`,
  `invalid_socket_path`, `socket_permission_unverified`,
  `session_index_too_large`, and one class per missing or invalid composition
  input;
- **while running**, one per linked component in the fixed set: `store_lost`,
  `store_capacity_exceeded`, `runtime_lost`, `transfers_lost`,
  `workspace_lease_lost`, `executor_lost`, `registry_lost`, `custody_lost`,
  `capability_lost`, `relay_lost` and `listener_lost`. A lease owner's death is **not** in this
  list: it is
  session-scoped, closes that session's controller with `control_owner_lost`,
  and the daemon keeps running;
- **from the signal handler**, `owner_lost`, the one class no component
  produces: a signal arrived and the owner that would run the shutdown is not
  there to receive it.

#### How a session is created and driven over the socket

`loopex attach` alone cannot start work, because a session has to exist and be
resumed before anything can be sent to it. The daemon forms of the two
released commands are what reach the socket:

- **`loopex run --daemon <socket> "<prompt>"`** — creates a session and sends
  its first prompt. It takes **no `--policy`**, and an earlier draft that
  showed one was wrong on the plan's own rule: policy is the host's, named
  when the daemon starts, and a connection that could name it would be a
  client replacing host authority. A `--policy` flag on a `--daemon` form is
  refused as an unrecognised option for that command. Its sequence is `session.create`,
  `session.acquire_control`, **`session.attach`**, then the prompt under the
  granted writer epoch, then stream. Attach comes *before* the prompt because
  ADR 0033 admits an existing-session mutation only from a connection that
  holds a controller-capable attachment, and grants exactly one exception —
  `session.resume` on a verified dormant session — which a prompt is not. The
  offline `loopex run` is unchanged and keeps composing its own runtime;
  `--daemon` is what redirects it.
- **`loopex resume --daemon <socket> <session-id>`** — reaches an existing
  session. It performs ADR 0033's sequence exactly: acquire control, then
  `session.resume` with a **fresh resume command ID** and the granted epoch,
  then attach, then stream. That is the sequence that activates a dormant
  session, and it is the only one that does.
- **`loopex attach <session-id> --daemon <socket>`** — joins a session that is
  already activated. It does **not** resume, so it does not activate.

**`loopex attach` is observe-or-one-shot-control, and that is a deliberate
restriction.** Its forms are:

| Form | What it does |
| --- | --- |
| `--observe` (default when neither role flag is given) | Attaches without acquiring, streams events, sends nothing. Refused by the daemon, not the client, if it ever tries |
| `--take-over` | Acquires a released or expired lease, waiting while an in-flight admission settles as ADR 0033's linearization requires and never forcing a live holder off, then attaches. Against a session this daemon has not activated the attach refuses `session_dormant`, and the client **releases the lease explicitly** before exiting non-zero with `loopex resume --daemon` as the remedy. On every other exit path it also releases explicitly |
| `--take-over --prompt "<text>"`, or `--take-over` with the prompt on stdin | The same — acquire, then attach — plus **one** command under the granted epoch, sent only after the attachment exists because ADR 0033 admits a mutation only from a controller-capable attachment, then streams to a terminal outcome |

There is no interactive multi-turn controller in M5. A controller that could
accept turn after turn from a terminal would need a full interactive contract
— input framing, mid-run steering, interrupt handling, what a partial line
means — and none of that is in this milestone's scope. One-shot control is
what the two-process demonstration actually needs, and the restriction is
stated here so it is a decision rather than an omission. Multi-turn driving is
`loopex run --daemon` and `loopex resume --daemon`, which already own it.

**Initial cursor.** `--after <sequence>` starts the stream strictly after that
event sequence. Without it the cursor is `0` and the client receives the
session's full replay, which is the honest default: a client that did not say
where it left off has not established a position, and silently starting at the
live tail would hide everything before it.

**Lease renewal, and what a failed renewal does.** A controller CLI renews
every ten seconds against a thirty-second term, as ADR 0033's proposed terms
fix. A renewal that is refused or that cannot be sent is not retried silently:
the client stops sending mutations immediately, reports the loss on `stderr`,
and continues **as an observer** on the same attachment until the process
ends or the operator re-runs with `--take-over`. It does not race the
deadline, because a mutation sent after the term elapsed will be refused
anyway and a client that keeps trying only obscures when control was lost.


**Core's create and resume results tell the daemon which call it made, and that is core's
fifth M5 change.** The daemon has two duties that pull against each other:
charge a *fresh* create against the activation ceiling, because a fresh create
starts a coordinator; and repair a directory entry for a session whose create
is *replayed*, without activating anything. Today it cannot do either
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
| `disposition` | `:fresh` \| `:historical` | Charge an activation for `:fresh`; charge nothing for `:historical` |
| `control_entry` | `:active` \| `:acquiring` \| `:dormant` | Repair the directory entry and index row without activating when `:dormant`; leave both alone when `:active`, since an activated session already recorded them |

**`control_entry` is three values over three statuses plus no-entry, and an
earlier revision argued one of them away.** `Control` holds `:active`,
`:acquiring` and `:unavailable`, and a session may have no entry at all
(`control.ex:569`, `:620`, `:818`, `:862`, `:1030`, `:1150`, `:1189`). The
mapping is `:active` → **`:active`**; `:acquiring` → **`:acquiring`**;
`:unavailable` and no-entry → **`:dormant`**, there being no coordinator
either way.

That revision said `:acquiring` "is never observed by the caller of a
completed create or resume", reasoning that the status exists only while that
very call is starting an owner. The reasoning is wrong on both **replayed**
branches, which are the branches the daemon most cares about. A replayed
create takes the second arm of the `cond` at `control.ex:902-919` and replies
`{:ok, session_id}` **immediately, whatever the entry holds**; a replayed
resume replies the same way at `:311-312`. Neither starts an owner and
neither waits for one. So a client replaying a create while another connection
is concurrently resuming that same session — which sets `:acquiring` at
`:1185-1192` — reads `:acquiring`, from a call that completed without
touching it.

The field therefore carries it, and the reservation table says what to do
with it: a **replay** that sees `:acquiring` **releases** its reservation,
because some other call is doing the activating and holds its own; a **fresh**
resume can never answer `:acquiring`, having waited for its own owner.

**It is `control_entry`, not `residency`, and the rename is the point.**
`residency` is a **daemon** fact on the wire — what `session.list` reports
about a session in *this daemon's* lifetime — while this field says what
`Loopex.Runtime.Control` holds for that session at the instant of the call.
The two coincide today and would not always: a session `Control` still lists
as active may have no live coordinator, which is precisely the `absent` case
`quiesce/1` reports. Giving both the same name would have invited a daemon to
forward one as the other. `residency` stays daemon-only; `control_entry` is
core's.

**The same two fields belong on the runtime-side `resume` result**, which my
own pass over this section found and the finding did not name. `resume` has
exactly the same ambiguity: a replayed resume takes the `{:completed, …}`
branch and answers `{:ok, session_id}` (`control.ex:311-312`), a fresh one
answers the same through `start_resume_owner`, and the daemon charges an
activation for resume as it does for create — so a client retrying a resume
under its original `command_id` would be charged twice. Core already knows the
difference and already exposes it in one mode: `completed_resume_reply/2`
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
(`loopex.ex:87-95`) and `Loopex.resume_session/3` likewise (`:110-117`).
Widening those returns would change what a released embedded caller receives
from a call it already makes — a compatibility break taken for a daemon's
bookkeeping.

So core change 5 adds **two daemon-facing functions beside them**,
`Loopex.Runtime.create_session_detailed/3` and
`resume_session_detailed/3`, answering
`{:ok, %{session_id: binary(), disposition: :fresh | :historical,
control_entry: :active | :acquiring | :dormant}} | {:error, term()}`. The existing pair
keeps its exact spec and its exact return, implemented as a projection of the
detailed one, so `loopex.ex:87-95` and `:110-117` forward what they forward today and
no embedded caller sees anything move. The daemon calls the detailed pair,
which is the only caller that needs them.

**The public protocol result is unchanged too.** Generation 1 and generation 2
return what they return today; this is an in-VM API detail between core and
any host, and no wire schema, digest or vector moves. A host that ignores the
detailed functions behaves exactly as it does now.

**What happens at the ceiling, stated because the honest answer is not the
neat one.** The brief for this change asked whether a fresh create can be
refused *before* core starts the coordinator. It cannot, from the daemon: the
coordinator is started inside the same call that would tell the daemon the
create was fresh (`start_owner` in the `true` branch at `:909-918`), so by the
time the daemon could act, the coordinator exists and the daemon has no API to
stop it. So the rule at the ceiling is the blunt one: **at the activation
ceiling the daemon refuses every `session.create`, replayed or fresh**, with
`activation_ceiling_reached` and the restart remedy the ceiling already names.

That costs something and the plan says what: recovery by `command_id` is
unavailable at the ceiling until the daemon is restarted. It is the right
trade because the alternative permits a sixty-fifth coordinator — breaking the
one-way activation bound this milestone proves — to save a recovery path whose
remedy is the restart the ceiling already prescribes. Below the ceiling, which
is where recovery is actually performed, `disposition` does its work.

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
has no such gap, because a session cannot be activated without entering it. `loopex resume --daemon` is unaffected: it acquires,
resumes, and only then attaches, by which time the session is active.


**Every ceiling consumed by a core call is reserved before that call**, and
the activation ceiling is the one where getting it wrong is most visible. The
rule is general: `attachments_per_session` (64) and `attachments_per_daemon`
(512) are consumed by `session.attach`, which creates the attachment inside
core, so the daemon reserves an attachment slot before calling and releases it
on any refusal — two concurrent attaches at 511 would otherwise both see 511
and both succeed. The index's 4,096 entries and the 512 concurrent lease
owners need no reservation, because the daemon creates those itself, serially,
in its own process.

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
truthful and early. The reservation is taken in the daemon's own serial
owner, so "atomic" needs no new mechanism: it is one process deciding.

**A reservation is keyed by `(command_id, session_id)`**, and the pair matters
in both directions. An earlier revision keyed a resume's reservation by its
**session ID alone**, which collides the moment two clients send two different
resume commands for one dormant session: the second would find a reservation
already taken for a key it does not own, and either double-count or refuse a
command that should have refused for a different reason. The command
identity is what makes a reservation *this call's*. A create's session
position is empty until the call answers — no session ID exists to key on —
and is filled in when it does; a resume carries both from the start.

It is **converted or released
idempotently**: converting records the session ID in the activation set and
drops the reservation; releasing drops it. Repeating either for the same key
is a no-op, so a retry, a crash-recovered handler or a duplicated reply
cannot double-count or double-free.

**A session already in the activation set takes no reservation at all**, which
an earlier revision also got wrong: it refused a resume at the ceiling for a
session this daemon had *already* activated, although that resume adds no
activation — the coordinator exists, the slot was spent when it started, and
core's own command idempotency handles the rest. So the rule is checked in
that order: if the session ID is already counted, the call proceeds with no
reservation and no ceiling test; only a call that may add an activation
reserves. That is also what keeps a controller from being locked out of a
session it is already driving merely because the daemon is full.

**Every branch of both results resolves the reservation, and the table is
complete rather than illustrative**, because a branch nobody listed is a slot
leaked until the daemon restarts:

| Result of the call | Slot |
| --- | --- |
| Create, `disposition: :fresh` | **Converted** — a coordinator started |
| Create, `:historical` with `control_entry: :active` | Released — that session was counted when it was activated |
| Create, `:historical` with `control_entry: :dormant` | Released — a replay starts nothing. `:dormant` here covers both a `Control` entry that is `:unavailable` and no entry at all: neither is a live coordinator, and neither was charged |
| Create or resume, `:historical` with `control_entry: :acquiring` | Released — another call is activating that session **and holds its own reservation**; charging this one too would spend two slots for one coordinator. The replay started nothing, which is what `:historical` says |
| Resume, `disposition: :fresh`, `control_entry: :acquiring` | **Cannot occur**, and the row says so rather than omitting it: a fresh resume waits for its own owner, so by the time it answers the entry it created is `:active` or the call has failed |
| Resume, `disposition: :fresh` | **Converted** — a coordinator started |
| Resume, `:historical` | Released — the replayed result is returned without starting an owner (`control.ex:311-312`) |
| Any of the three refusing — `runtime_command_conflict`, `store_unavailable`, an invalid identifier, a placement mismatch, an attach whose first leg answers `{:error, :runtime_unavailable}` on its 5 s default, any other `{:error, _}` | Released. An attach refused at its first leg is the same case as any other refusal, because that leg mutates nothing (`control.ex:1235-1251`) |
| A **resume** whose connection is lost while the call is in flight | **Held, then resolved by the relay**, which holds the call's real answer whether or not the process that asked is still there; where the daemon must re-establish it later, the client's replay under its original `command_id` carries the same `disposition`/`control_entry`. The existence query cannot answer this — it says `present` either way |
| A **create** whose connection is lost while the call is in flight | **Held, then resolved by the relay** the same way; a later replay under the same `command_id` returns the historical result and starts no coordinator (`control.ex:901-907`), carrying the same two fields. Same reservation key, so no second slot |
| An **attach whose connection process ends before it answers** | **Released with the connection**: the reservation is keyed by the connection, ADR 0032 binding a connection to at most one attachment, and core change 1 monitoring the attaching process. The daemon closes that connection, its process ends, and the dispatcher's `DOWN` handler drops the attachment. Nothing is observed, because nothing needs to be |

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

**`Runtime.attach/3` is two legs with two different bounds, which an earlier
revision flattened into one.** Its signature takes a runtime, a session ID and
options and no timeout at all (`runtime.ex:198-210`), and it was written here
as waiting `:infinity` throughout. It does not.

- **The first leg carries the default five seconds.**
  `control_call(runtime, {:begin_attach, …})` is called with **no timeout
  argument** (`runtime.ex:200`), so it takes `control_call/3`'s default of
  `5_000` (`:470`), and `safe_call/3` turns the resulting exit into
  `{:error, :runtime_unavailable}` rather than letting it reach the caller
  (`:529-535`). That is **safe**, and it is why the leg can afford a deadline:
  `begin_attach/3` reads the session entry, validates the options and detects
  repetition, and **mutates nothing** (`control.ex:1235-1251`). A refusal
  there — including a timeout refusal — leaves no attachment, no incarnation
  and no pending scan, so the daemon releases its reserved slot on the
  ordinary refusal row and there is nothing to observe.
- **The second leg waits `:infinity`, twice** — at the dispatcher and again at
  the install (`:538`, `:547`) — **precisely so a
  caller timeout cannot revoke a mutation it cannot see**, which is what the
  code says there in as many words: the dispatcher has already created the
  attachment and the install is registering its routing, so a caller that gave
  up would be revoking neither mutation, and could not report truthfully that
  the attach failed.

The daemon's rule follows the split rather than the call: **it adds no timeout
to a core call that has already changed something**, because a timeout it
could not act on truthfully would be worse than the wait, and it leaves the
first leg's existing five seconds alone because that leg changes nothing.
`create_session/3` and `resume_session/3` have no such split — they are
`:infinity` from the first line — so the two of them and attach's second leg
are what the reservation rows are written against.

**Who resolves a reservation when the asking process is gone: the relay.** The
relay's task performs the core call and returns core's answer whether or not
the connection that asked still exists, so for the two ticketed calls the
relay holds the `disposition` and `control_entry` and hands them to the
daemon's serial owner, which converts or releases by the row above. That is
the whole of the ordinary path, and it is why creates are ticketed. The
client, which saw nothing, recovers as it always does — by re-presenting the
same `command_id`, whose replay returns the historical result and the same two
fields, charging no second slot because the reservation key is the pair.

**A call whose answer the daemon holds no route to may still have started a
coordinator
or an attachment**, so releasing the reservation would let the ceiling be
exceeded and converting it would spend a slot that may not exist. What
resolves it differs by call, and an earlier revision used one resolution for
all three — core's existence query — which cannot discriminate for two of
them.

**Create: replay under the original `command_id`.** No session ID exists when
the reservation is taken, so the existence query cannot even be asked. The
replay returns the historical result without starting a coordinator
(`control.ex:901-907`) and now carries `disposition` and `control_entry`, which
say directly whether the original call started anything. The replay is
idempotent and carries the same reservation key, so it charges no second slot.

**Resume: replay under the original `command_id` too — not the existence
query.** The existence query answers `present` for *any* session a resume
could target, whether or not this resume activated it, so it cannot tell the
two apart: the two answers that must differ are identical. The replay can,
because core's resume result carries the same two fields: `:historical` with
`control_entry: :active` means the original call did activate it, `:historical`
with `control_entry: :dormant` means it did not, and the daemon converts or
releases on that.

**Attach: end the connection process and the attachment goes with it.** Core
exposes no attachment count, so there is nothing to observe — and nothing
needs to be. ADR 0032 binds a connection to **at most one attachment at a
time** (ADR 0032's transport section, with its release rule beside it), the daemon attaches from its
**per-connection process**, and core change 1 makes the dispatcher monitor
that process and drop its attachment on `DOWN`. So the reservation is keyed by
the connection, and a connection whose `session.attach` never answered is
closed by the daemon — the same path every connection close takes, whether the
client went away or the daemon gave up on it — its process ends, and the
attachment is released by the monitor. **"Gave up" here is the owner ending
that connection process from outside**, since the process itself is inside an
`:infinity` wait and cannot give up on its own; the `DOWN` is the release
either way, which is the point of keying the reservation to the process rather
than to the call. The reservation is released with the connection.

**And the attach must be made from that process**, not from a task the daemon
could bound: the attaching process *is* the release handle, so a bounded
attach and a monitor on the attacher are mutually exclusive. Choosing the
monitor is what makes an unanswered attach releasable at all.
Nothing new is called and nothing is observed; the release path is the one
core change 1 adds, and it is named in the inventory rather than assumed.

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

**Cursor, reconnection and re-acquisition.** The client remembers the last
event cursor it emitted and, on transport loss, reconnects at it,
deduplicating by session ID, event sequence and event ID; delivery is
contiguous and at least once, so a duplicate at the seam is expected and a gap
is a defect. A reconnecting **controller** does not resume its old authority:
the lease it held is expiring or expired, and it must acquire again and
receive a **fresh writer epoch** before any further mutation.

What that looks like in the CLI is written out, because "must acquire again"
leaves the interesting case unsaid. On reconnect the client **retries
`session.acquire_control` with backoff** until its own previous lease can have
expired — the lease term, at most 30 seconds — because until then the daemon
still records the old tenure as the holder and refuses. Once the lease is
gone, one of two things is true and the client says which: it acquires, and
holds a **fresh** lease with a fresh epoch, and continues; or another client
took over in the meantime, and it exits `control_held`, reporting that it no
longer controls the session rather than retrying indefinitely against a live
holder. An observer needs none of this and simply reattaches.

If the session went dormant in between — because the daemon restarted — it
must resume first, with a fresh resume command ID under that new epoch. That is the same
acquire → resume → attach → drive sequence ADR 0033 fixes, reached from a
different starting point, and the CLI contract and that ADR say it the same
way on purpose.

Exit status: `0` when the session reaches a terminal outcome or the operator
detaches; non-zero on a refusal, or on a transport loss reconnection could not
repair, with the reason class on `stderr`.

#### Where these are documented

| Contract | Operator page |
| --- | --- |
| `loopex sessions` offline, unchanged | `docs/operator/coding-sessions.md`, its existing command rows, reviewed unchanged |
| `loopex run` and `loopex resume` offline, unchanged | `docs/operator/coding-sessions.md`, reviewed unchanged |
| `loopex run --daemon`, `loopex resume --daemon` and the create-and-drive sequence | `docs/operator/daemon.md`, driving section |
| `loopex sessions --daemon`, `--limit`, `--after`, `--status`, `index_full` | `docs/operator/daemon.md`, listing section |
| `loopex daemon` composition inputs, readiness record, signals, exit classes | `docs/operator/daemon.md`, running section |
| `loopex attach` roles, one-shot control, `--after`, renewal loss, `session_dormant` at attach, the attempted release while the transport is writable, reconnect and re-acquisition with its backoff and its `control_held` ending | `docs/operator/daemon.md`, attaching section |

<a id="technical-plan-lifecycle"></a>
### Daemon Lifecycle and Orderly Shutdown

Concept: [Scope](M5.md#concept-plan-scope).

Outcome 1 requires that an orderly stop and an abrupt death both leave only
what the journal proves. That is a claim about a sequence, so the sequence is
written out rather than left implied by the words "foreground process".

**Startup, in order.** The order is written against the seam that actually
exists — one composition function that assembles every edge and ends with the
runtime — rather than against a staged one the plan would have to invent:

1. **Resolve root and socket path**, including the `--socket` constraint
   below; a path outside the root's `daemon/` directory is refused here with
   `invalid_socket_path`, before anything is acquired.
2. **Install the signal handlers**, for the reason the signal section gives:
   before this, the default handler would stop the VM outright and strand
   whatever the next steps take.
3. **Start the credential routing registry, the custody process and the
   tracing capability**, in that order. All three are
   the daemon's own, as ADR 0034's host, and all three must exist before the
   model configuration that carries the registry handle, the token and the
   capability reference is built. The capability is listed here rather than
   left to the process table: it is one of the ten links, ADR 0034 now makes
   it mandatory wherever a token is configured, and a startup sequence that
   named two of the three would have left the third's position to inference.
   It is handed the runtime reference as soon as step 4 returns one.
4. **Call the composition function**, which opens the Store and acquires the
   writer marker with `recover_stale_writer: true` and the three holder
   outcomes ADR 0032 fixes, then assembles the artifact transfers owner where
   enabled, the workspace lease, the executor and the runtime, and returns
   every pid it linked. A daemon that does not hold the marker fails here and
   never reads, unlinks or binds the socket path.
5. **Read the session directory and build the index**, refusing at the
   recorded-entry bound.
6. **Start the admission relay.** It is the ninth of the ten linked
   processes and the last before the listener: it needs the runtime step 4
   returned, and it must exist before any connection can be accepted, because
   every call that changes core state goes through it. An earlier
   revision gave it a row in the process table and no step here, which left
   the one process the admission cut depends on with no place in the order.
7. **Create the `0700` subdirectory, remove any stale socket pathname, and
   bind the `0600` socket**, then read back and verify ownership and mode.
   Removing the stale pathname is this daemon's right and only this daemon's:
   it holds the verified marker, which is the only moment at which removing a
   socket file is unambiguously correct. A predecessor that left one — every
   fail-stop leaves one — is cleaned up here rather than by itself.
8. **Begin accepting**, then **print the readiness line**.

No lease owner exists at this point, and none is started here: one is started
when a session is activated, which cannot happen before a client connects.

A failure at any step exits non-zero with that step's reason class, after the
reverse cleanup below, and touches nothing after it.


**Startup is interruptible, and the owner is monitored rather than linked —
both because a synchronous sequence inside one process is not, by itself,
process-safe.** The steps above run in the owner, and while they run the owner
is not reading its mailbox: a `SIGTERM` handled by `:erl_signal_server` becomes
a message that waits, and a linked component's `{:EXIT, …}` waits beside it.
Left alone, that means a daemon can take the marker, bind the socket and print
readiness *after* a stop it has already been told about, or after a component
it depends on has already died — and then read both and shut down, having
announced itself ready in between.

Four rules, each narrow:

- **The owner is started unlinked and monitored.** The escript command process
  calls **`GenServer.start/3`, not `start_link/3`**, and monitors the owner
  immediately. An earlier revision had it both link *and* monitor, which
  defeats the monitor: an abnormal exit travels the link first and kills the
  command process, so the `DOWN` that was supposed to produce `owner_lost` is
  never handled by anybody. Unlinked, the command process survives every way
  the owner can die, halts non-zero with `owner_lost` on `stderr` on the
  `DOWN`, and gives the operating system an exit status — which is the whole
  of its job. The inventory row says unlinked-and-monitored, and now the
  design does too.
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
  `{:ok, state, {:continue, :start}}`; the seven steps run in
  `handle_continue(:start, state)`. That is enough to make `GenServer.start/3`
  return before the first step, and the ordering is then explicit rather than
  incidental:

  | # | Who | What |
  | --- | --- | --- |
  | 1 | Command process | `GenServer.start(Owner, args)` |
  | 2 | Owner | `init/1` returns `{:ok, state, {:continue, :start}}`, having acquired nothing |
  | 3 | Command process | `Process.monitor(owner)` |
  | 4 | Command process | sends the owner `:go` |
  | 5 | Owner | `handle_continue/2` **waits for `:go`** before step 1 of the startup sequence, then runs the seven steps |

  **Step 5's wait is what makes the monitor provably installed**, and it is
  why the continue does not simply begin. Without it the ordering would rest
  on the command process winning a race it has no reason to win: the owner is
  runnable the instant `init/1` returns, and a scheduler is free to run its
  continue before the caller's next line. The `:go` message turns a hope about
  scheduling into a happens-before: the owner cannot pass step 5 until a
  message exists, and the message does not exist until the monitor does. The
  wait is bounded by the same phase-6 number every other wait uses, and a
  `:go` that never arrives — a command process that died between steps 2 and
  4 — ends the owner through the reverse cleanup with nothing acquired, which
  is correct, because there is nobody left to report a daemon to.

  The alternative was to keep the sequence in `init/1` and have the owner
  monitor the *command process* instead. It is rejected: it inverts the
  reporting direction, gives the operating system no exit status when the
  owner is the thing that dies, and still leaves the `{:error, reason}` return
  as the only account of an acquisition that already happened.
- **The owner drains and checks before every acquisition it performs itself.**
  Before taking the marker, before calling the composition function, before
  starting the relay, before
  binding the socket and before printing the readiness line, the owner reads
  whatever is in its mailbox for a stop message or an `{:EXIT, …}` and checks
  that every component it has already started is alive. Any of those aborts
  the start into the reverse cleanup above.
- **The composition function checks between its own edges, because the owner
  cannot.** Its chain is one synchronous `with` (`loopex_composition.ex:166-178`):
  the owner is inside that call for the whole of it and can read nothing
  between the Store and the runtime. An earlier revision claimed a mailbox
  check "before each edge the function returns to it", which is not a thing
  the owner can do. So the function takes an **interrupt checkpoint** as an
  option and calls it **before starting each edge**:

  ```elixir
  interrupt: (-> :continue | {:stop, term()})
  ```

  A zero-arity function, supplied by the caller, evaluated in the caller's own
  process, which the daemon implements as exactly the drain-and-check above.
  Where it answers `{:stop, reason}` the composition starts nothing further.

  **And on any early exit it returns what it has already started**, which the
  interrupt makes necessary and an edge failure needed anyway:

  ```elixir
  {:error, reason, %{store: pid, transfers: pid | nil, workspace_lease: pid, executor: pid, runtime_supervisor: pid}}
  ```

  — the same map shape a success returns, holding only the keys that exist
  yet. Without it, an interrupted or failed composition would leave the owner
  linked to edges it cannot name, and reverse cleanup would unwind less than
  exists. A caller that passes no `interrupt` sees the behaviour it sees
  today, so `RuntimeOwner` and the app-server host are unaffected.

Neither the monitor nor the checkpoint needs a new process or a supervisor:
the drain is a receive with a zero timeout and a liveness check, the interrupt
is a function the caller already has, and the monitor is the command process
doing what it is already there to do — wait for the daemon to end and give the
operating system an exit status.

**One cost of matching the seam is stated rather than hidden.** The directory
and index read is step 5, after the composition function has already taken the
workspace lease and started the executor, so a root whose directory exceeds
the recorded-entry bound is now refused *after* those were taken and released
rather than before they were taken. Nothing durable is at risk — the reverse
cleanup below releases them in order — and the alternative was worse: a staged
seam, two public composition functions where one suffices, so that the daemon
could interleave its own step between them. That is rejected; the minimalism
budget does not buy a second public function to reorder a refusal.

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

**It links a fixed set of ten processes — nine without artifact
transfers — and a bounded, dynamic population of lease owners beside them.**
Earlier drafts said four, then seven, then nine, each time having counted the
components the daemon *thinks* about rather than the processes that actually
exist. The fixed set is this:

| Start order | Linked process | Where it comes from | Optional? |
| --- | --- | --- | --- |
| 1 | The credential **routing registry** | The daemon's own, as the host ADR 0034 names | no |
| 2 | The credential **custody process** | The daemon's own, as the host ADR 0034 names | no |
| 3 | The **tracing capability** | The daemon's own, as the host ADR 0034 names; it holds the runtime reference and resolves the current tracer for `exclude_self/2` | no |
| 4 | The Store adapter | `start_edge(Store.Local, …)` | no |
| 5 | The artifact transfers owner | `start_edge(Transfers, …)` | **yes** — only when transfers are enabled |
| 6 | The workspace lease | `start_edge(WorkspaceLease, …)` | no |
| 7 | The local executor | `start_edge(Local, …)` | no |
| 8 | The runtime root | `start_edge(Loopex, …)` | no |
| 9 | The **admission relay** | The daemon's own; every one of the ten core calls that change core state is routed through it | no |
| 10 | The listener | Bound and permission-checked last, so nothing accepts before the rest exists | no |

The tracing capability starts with the other two host-owned processes and
before composition, for the reason all three share: model options carry their
references, and options are built before the runtime exists. It is handed the
runtime reference as soon as the composition function returns one.

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
  cut, every request on an open connection is refused `daemon_stopping`
  whatever its method** — transfers included, and reads included, the refusal
  being about the daemon's state and not about what the request would have
  done. A transfer already in flight when the cut answers either completes on
  its own or ends in phase 6 with its connection: the connection process ends,
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
  activation slot that create reserved. An earlier revision left creates
  outside the relay entirely, which made the cut a promise the daemon could
  not keep.

  **The tenth is `session.attach`, and it is ticketed for the cut alone.** An
  earlier revision called it a read and left it out, which it is not: its
  second leg **mutates the dispatcher**. `Runtime.attach/3` calls
  `{:attach, …}` on the dispatcher (`runtime.ex:199-210`, `:538`), whose
  handler spawns a scan worker, monitors the caller and records a pending scan
  in dispatcher state (`event_dispatcher.ex:168-199`), and whose completion
  installs the attachment into the `attachments` map and releases the
  transfers of anything it supersedes (`:805-824`). A cut that had not
  accounted for an attach in flight would have quiesce enumerating `Control`
  while core was still installing one. **Its ticket names no session for
  ordering purposes**: it takes no part in the per-session grant-blocking
  rule, because an attachment grants nothing and cannot overtake a mutation.
  It exists so the cut is total. **Reads stay unticketed** for the reason
  below, and the distinction is exactly this one — a read changes no core
  state, and an attach does.

  **`session.release_control` is not among the ten**, and the
  distinction is worth one line: it carries `writer_epoch` and
  is lease-authorized, but it starts no core call, so there is nothing for a
  ticket to account for. **Reads are not ticketed either.** An earlier
  revision said "every core call the daemon makes", which would have included
  `Loopex.Runtime.next_event/1` — an `:infinity` dispatcher call by
  construction (`runtime.ex:236-244`) — so a quiet observer sitting on a read
  would have blocked every takeover for that session for as long as it sat
  there. A read grants nothing, orders nothing and cannot overtake a mutation.
- **The ticket is recorded synchronously, before the call exists.** The lease
  owner — or, for a create, the connection process — **calls** the relay and
  waits for the acknowledgement, and only then
  does the relay spawn the monitored task that performs the core call. A cast
  would have left the window open at the other end: an owner could pass its
  holder check, send its ticket and die before the message arrived, and a
  replacement would see no ticket for a call that was about to be made.

  **That call carries an explicit bound and does not inherit
  `GenServer.call/2`'s hidden five seconds**, which is the same discipline the
  rest of this plan applies to every call that matters: the bound is the
  teardown number, 5 s, because the relay's whole job here is to write a row
  and answer, and a relay that cannot do that in five seconds is a relay the
  daemon has lost. An unanswered ticket call is therefore not a silent
  five-second stall inside a client's mutation; it is `relay_lost`, the class
  that already exists for a relay the daemon can no longer account through.
- **The relay installs that monitor inside the owner's first ticket call,
  before it acknowledges**, which is what makes the ordering argument below
  true rather than nearly true. A relay that monitored on some other occasion
  — at the owner's start, say — would have a window in which an owner had sent
  a ticket the relay had not yet begun watching for. Monitoring inside the
  synchronous call means the monitor exists before the first acknowledgement
  does, and every ticket that owner will ever send comes after it.
- **The relay monitors every lease owner**, so an owner's death is ordered
  *after* the tickets it sent. Message ordering between one sender and one
  receiver is guaranteed by the BEAM — signals from a process to a process are
  delivered in send order, and a monitor's `DOWN` is a signal from the same
  pair — so every ticket an owner sent before dying is in the relay's mailbox
  ahead of that owner's `DOWN`. The relay therefore knows, at the instant it
  learns an owner is gone, exactly which of that owner's calls it is holding.
- **A ticket settles only on a real core result**, and this is the part an
  earlier revision got backwards. The task returning core's answer — any
  answer, including a refusal — settles the ticket. The task **dying without
  one does not**: the relay does not know whether the call reached a
  coordinator, and a delivered `GenServer.call` completes whether or not its
  caller is alive, so "the task died" says nothing about the call. Treating
  that as `commit_unknown` would have admitted a successor while an older
  mutation was still on its way into core, which is the exact hole the relay
  exists to close.

  So a task that dies without a result **retains its ticket**, and the relay
  **exits `relay_lost`** — daemon-fatal, the class it already has. That is the
  honest answer: the daemon has lost track of a mutation it authorized and
  cannot say whether a successor would overtake it, and a daemon that cannot
  answer that question must not keep granting leases. It is rare by
  construction, the task's only job being one call.
- **A connection disappearing settles nothing**, because the call it made is
  still running inside core; the ticket outlives the connection exactly as the
  call does.
- **The relay never blocks its own loop, and that is why one session's stall
  is one session's.** A grant that must wait on an outstanding ticket is
  **deferred, not waited on**: the relay answers `{:noreply, …}` and replies
  later with `GenServer.reply/2` when the last of that session's tickets
  settles. A relay that ran the wait inside its callback would stop answering
  every other session's ticket calls for as long as one session's mutation
  took, and the five-second bound on a ticket call would then be measuring
  somebody else's core work rather than the relay's own responsiveness —
  turning an unrelated slow mutation into `relay_lost`. With deferral that
  bound measures exactly what it claims to: whether the relay is alive and
  reading its mailbox.
- **A replacement owner's first grant for a session blocks until that
  session's outstanding tickets have settled.** Not the daemon's admissions
  generally — just that session's, which is why the ticket names one. A create
  ticket and an attach ticket block no grant: the first names no session yet,
  and the second grants nothing that could be overtaken.
- **The admission cut is the relay's, because the relay is the only process
  that can answer for all ten.** The owner calls it once at the start of an
  orderly stop; it stops admitting, and it answers only when **every ticket it
  holds has settled** — not "settled or recorded", which an earlier revision
  wrote and which gives away the whole property. A ticket merely *recorded* is
  a call still running inside core, so quiesce would begin enumerating
  `Control` while an admission, a create or an attach was still changing it.
  Settling is the only acknowledgement worth having and it is reachable: every
  ticketed call is bounded by core's own work rather than by a client, and a
  ticket that cannot settle is the `relay_lost` case this section already
  defines. That answer is what makes "after this instant nothing enters core
  through the daemon **that could change what quiesce is about to read**" a
  fact rather than a policy, and it is why every call that mutates `Control`
  or the journal goes through this one process. The narrower claim is the true
  one; the transfer methods above are the reason it has to be narrow.

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
| When does one retire? | When the lease is free — released or expired — **and** no acquisition is waiting **and** the relay holds no outstanding ticket for that session. All three, because any one of them alone would retire an owner whose state something still depends on |
| When does one stop unconditionally? | At daemon exit, in the stop sequence below |
| How many can exist at once? | One per session under lease or acquisition, capped at **512, the per-daemon attachment ceiling ADR 0032 already fixes**, reused rather than invented, with the cap and its `control_capacity_reached` refusal stated in that pair's error inventory; a lease operation that would exceed it refuses with `control_capacity_reached`. The population is **independent of the activation ceiling**, which counts something else entirely |
| What does its death mean? | That **session's** collaboration state, not the daemon's — the one exception to fail-stop uniformity, below |

**Why not the activation ceiling.** An earlier revision bounded the population
at 64 by pointing at the activation ceiling. That was wrong in both
directions: a dormant session can have a lease owner without ever being
activated, and an activated session whose lease was released and whose tickets
have settled has no owner at all. The two populations are not the same set,
and tying one to the other's number would have made the bound wrong the first
time an operator took control of a dormant session.

**The registry, the custody process and the tracing capability are first, and
that is forced rather than chosen.** ADR 0034 makes the *host* own both, and for a daemon the host
is the daemon. The runtime's model configuration carries the registry handle
and the token in `options`, so both processes must exist before the
composition function builds that configuration — which means before the
runtime starts, and the composition function starts the runtime at the end of
its own chain, so before the composition call itself.

Order 3 to 7 is the composition's actual chain, not a tidied one: the Store
first, then the artifact placement and the executor's own edges, and the
runtime last within that chain, because it depends on all of them.

**The stop order is the reverse, with one deliberate exception.** Reversed:
listener, then **every lease owner**, then the **relay**, then runtime,
executor, workspace lease, transfers, then the tracing capability, custody and
the registry — and then **the
Store, last of all**, out of reverse order. The lease owners go before the
relay because the relay is what holds their tickets, and stopping it first
would discard a ticket an owner could still be waiting on. They are stopped
as **one collective sweep, not one at a time**, against phase 6's deadline:
up to 512 of them exist, and 512 sequential stops inside a five-second phase
is arithmetic that does not work. The sweep — every stop sent at once, one
wait for all of the exits, a kill for whatever is left at the phase's end —
and the disposition of a lease owner killed that way are written out with
phase 6 below. The
Store is moved to the end because its `terminate/2` releases the writer
marker, and the marker must outlive every operation the owner can end;
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
the fixed ten — nine without transfers — is `start_link`ed by the owner,
as is each lease owner beside them, and the owner's
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
step 3's clean return as `runtime_lost` — a daemon that could never exit `0`, and an
idle-shutdown witness that could never pass.

So the owner carries a `stopping` field naming **the component it is
currently stopping** — one pid at every step but phase 6's lease-owner sweep,
where it names that step's set of pids — set immediately before each stop
call. The EXIT clause
reads:

- an exit from the pid named in `stopping`, **whose reason is `:normal`,
  `:shutdown` or the owner's own `:killed`**, is **consumed** and clears the
  field — it is the stop the owner asked for, arriving as a signal;
- **every other exit is classified**, including one from the pid named in
  `stopping` whose reason is none of those three, and one from a
  component not yet stopped that dies of its own accord *during* another
  component's stop. A store that fails while the listener is being stopped is
  still `store_lost`, and must be: the daemon is going down either way, but
  the operator is owed the real reason rather than `operator_stop`.

**The field narrows *which* exits can be consumed; the reason decides
*whether* one is**, and an earlier revision had the field deciding on its own.
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
the grace, stopped with the grace the executor admits at its lower end
— the local executor validates it as `is_integer(cleanup_grace_ms) and
cleanup_grace_ms >= 0` (`apps/loopex_executor_local/lib/executor.ex:897`), so `1` is a composable value, not
a contrived one — run at both toolchain pairs:

| grace | `terminate/2` | what `GenServer.stop/3` did | `Process.alive?` right after | the link exit the owner then got |
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
   `GenServer.stop(pid, :normal, remaining(deadline))`, where `remaining/1` is
   what is left of the phase's own deadline and no component carries a budget
   of its own. The helper is monitored, never
   linked, so whatever that call raises, exits or returns dies with the helper
   and never reaches the owner. The owner needs nothing from it — not its
   return value, not its `DOWN` — and ignores both.

   **Killing the helper would not cancel the stop it has already delivered**,
   which is the same property that makes a dead coordinator's transaction
   commit and a dead relay task's mutation reach core. That is precisely why
   classification comes from the **exit reason on the owner's own link** and
   never from what became of the helper: the helper is a way to make a call
   without risking the caller, not a handle on the call.
3. The owner then waits on the link it already holds:

```elixir
receive do
  {:EXIT, ^pid, reason} -> reason
after
  grace ->
    Process.exit(pid, :kill)

    receive do
      {:EXIT, ^pid, reason} -> reason
    end
end
```

4. **The reason decides, and nothing else does.** `:normal` and `:shutdown`
   are the stop the owner asked for, so the exit is consumed. `:killed`
   following the owner's own kill is likewise the owner's doing — nothing else
   in the daemon holds these pids — and is consumed. **Every other reason is
   classified**, first class wins, and that is true whether the component died
   before the stop, during it, or of something unrelated at that moment.

This is smaller than what it replaces and it is total. There is no shape to
enumerate, because the owner reads the one thing the VM guarantees it: the
exit reason on a link it holds. The four-row catch table of the previous
revision, its `{:timeout, _}` / `{:noproc, _}` / catch-all clauses, its
`Process.alive?` guard and its "no daemon component exits with the bare atom
`:timeout`" rule are all withdrawn — they were an attempt to classify a
component's fate from what a library function did to the caller, and row 1
shows that is not derivable.

**What bounds each step.** The outer `receive` waits until the phase's
**absolute deadline** — the shared teardown deadline for every non-Store stop,
the Store's own fixed phase for the Store — and the helper is given what
remains of it, so a component is bounded once rather than twice and the phase
is bounded whatever the component does. The inner `receive` after the kill
carries no `after`, and needs none: `Process.exit(pid, :kill)` on a live
process is unconditional, and on one already dead the exit the owner is
waiting for is the one that made it dead, already queued. It is a wait for a
signal that exists, not a second bound.

**Other messages wait their turn.** Both receives are selective on the pid
this step is stopping — on the set of them, in phase 6's lease-owner sweep, by
the same discipline read over a set — so
an exit from another component, a client's frame, or anything else stays in
the mailbox and is read when the owner returns to its loop. Nothing is
skipped, only ordered — and nothing is lost even so, because of one invariant:
**a component that dies during the sequence always has its own step still
ahead of it.** One whose step has passed is already stopped and cannot die a
second time. So every unexpected death is met at its own step, by the wait
above, as a reason that is neither `:normal`, `:shutdown` nor the owner's own
`:killed` — and is classified there.

Two consequences the sequences below depend on, stated here once:

- **A class recorded during a stop does not abort the sequence.** The owner
  finishes stopping what remains — the components it has not reached still own
  things worth ending — and then halts with that class instead of `0`. The
  first class recorded wins; a later one does not overwrite it, so the
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

**One of them traps exits, and it is not the one an earlier draft named.**
The **Store adapter** traps (`local.ex:150`), so an owner that crashes rather
than stopping still runs its `terminate/2` and returns the marker; that is a
property M5 depends on and a change to it is a change to this plan.

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

The second rejected option is the one this section opened with: changing
`LoopexComposition` to surface store death and return the adapter pid. It is
a host convenience application the app server uses and the daemon does not
need for *lifetime*; widening it for daemon concerns would put them into an
application whose other caller has none. **The two hosts compose differently,
deliberately**: `LoopexAppServer.Host` keeps `with_runtime/2`, whose bracket
suits a process that lives and dies with one client's stdin, and the daemon
owns its own because it does not.

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
`{:stop, reason, commit_unknown, state}`, so it terminates *itself*, and its
`terminate/2` releases the writer marker on the way out. By the time anything
observes it, the store is gone and the marker is already released. A sequence
that ends "then stop the Store" cannot run when the Store is what died.

**Who may unlink the socket: nobody, except the next daemon that has proved it
holds the marker.** The socket path is not the daemon's by possession; it is
the daemon's *because it holds the writer marker*, which is what ADR 0032
already says. The permission therefore **ends when the marker does**, and the
marker is released by the Store's `terminate/2` (`local.ex:167`) — which can
happen without the daemon being asked and without the daemon noticing.

An earlier revision tried to keep the unlink by putting a precondition in
front of it: check the Store is alive and still holds its marker, then unlink.
**That is check-then-act across a process death, and it is wrong.** Between
the check and the `File.rm` the Store can die, release the marker, a successor
can acquire it, remove the stale path and bind its own — and the predecessor's
unlink then removes the successor's socket. No ordering of the two syscalls
closes it, because the thing being checked is owned by a process that can stop
being the answer at any instant.

So the rule is one line, and it has no precondition to get wrong:

- **No predecessor path ever unlinks.** Not the orderly stop, not any
  fail-stop, not reverse cleanup. The orderly stop closes the listener, tells
  clients, and **leaves the pathname where it is**.
- **Only the next verified marker holder removes it**, at startup, before it
  binds — the one moment at which removing a socket file is unambiguously
  correct, because the remover provably holds the exclusion the path belongs
  to. A stale `daemon.sock` is therefore an ordinary condition of startup
  rather than a failure of shutdown.

**What that costs, said plainly.** A stopped daemon leaves a socket file
behind. Nothing connects through it — no process is listening, so a client
gets `ECONNREFUSED` rather than a hang — and the next daemon removes it. An
operator inspecting a stopped root sees a file that looks live and is not,
which the operator page states; that is the price of never removing a file
that might belong to somebody else.

**Three things are deleted with the precondition.** The `File.stat` device and
inode guard, which tried to make unlinking safe after ownership had lapsed.
The admitted stat-then-unlink race, which this design no longer has because it
never unlinks at all. And **the read-only marker-ownership call the previous
revision added to the local adapter**: nothing else needed it, so
`loopex_store_local` is unchanged again, exactly as it was before that
revision invented a use for a query that could not be used safely.

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
other keyboard interrupt, and a command run at a prompt should end on both. A
daemon is not run at a prompt. It is started by a service manager or a
launcher, both of which stop a service with `SIGTERM`, and a daemon that also
died on `SIGHUP` would exit when the terminal that happened to start it
closed — which for a background service is a defect rather than a courtesy.
`SIGQUIT`'s default is a core dump, and taking it over to do a graceful stop
would take away the one signal an operator has for "stop and leave me a dump".
So the daemon handles `SIGTERM` and leaves `SIGHUP` and `SIGQUIT` at their
defaults.

**The contract therefore depends on the entry point, and the plan says so
rather than giving one answer for two different processes.** It has to,
because `apps/loopex_cli/bin/loopex` traps **`INT TERM HUP QUIT`** and
forwards every one of them to its child as `kill -TERM`
(`bin/loopex:60`) — so what a signal means is decided by whether it lands
on the launcher or on the escript:

| Signal | Sent to the **launcher** | Sent to the **escript** directly |
| --- | --- | --- |
| `SIGINT` | Orderly stop: forwarded as `SIGTERM` | Not this plan's to specify — `:os.set_signal/2` refuses `:sigint` (`interrupt.ex:13-17`) and the emulator's break handler owns it |
| `SIGTERM` | Orderly stop: forwarded as `SIGTERM` | Orderly stop: the one signal the daemon installs a handler for |
| `SIGHUP` | Orderly stop: forwarded as `SIGTERM` | The emulator's default — the daemon installs nothing, for the reason above |
| `SIGQUIT` | Orderly stop: forwarded as `SIGTERM` | The emulator's default, a dump |

So "the daemon dies on `SIGHUP` when its terminal closes" is false through the
escript and **true through the launcher**, which is the shipped path — and
that is the launcher's existing behaviour, deliberately left alone. An
earlier revision of this section gave `SIGHUP` and `SIGQUIT` one meaning each
without naming a route, which contradicted the launcher for two of the four.
**Changing the launcher was the alternative and is rejected**: it forwards
all four as `TERM` for every `loopex` command, that behaviour is released, and
narrowing it for the daemon's sake would change what `loopex run` does on
`SIGHUP` in the same change.

The witnesses are **one per signal per route** — eight cases, four of which
assert an orderly stop and four of which assert the entry point's own
behaviour — rather than the `SIGTERM`-and-forwarded-`SIGINT` pair an earlier
revision listed.

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
a signal arriving before startup completes ends a daemon that holds nothing.

**The handler does one thing: it sends the owner a stop message.** It runs in
`:erl_signal_server`, not in the owner, so it performs no teardown, holds no
state and makes no decision; the owner's own code runs the sequence, from its
own process, exactly as it does for every other path.

**The owner-loss backstop is the second route, not the first.** `owner_lost`
is normally observed by the **command process that started the owner and
monitors it**, which halts non-zero the moment its `DOWN` arrives — see the
startup rules above. The signal handler keeps its own version of the check for
the one case that monitor cannot cover: a signal arriving in the instant
between the owner's death and the monitor's `DOWN` being handled. In both
routes the class is `owner_lost` on `stderr`, and it is the one class no
linked component produces.

**Eight phases, each with a named bound, and the stop is their sum.** Earlier
revisions called this "three clocks" and then let two of them overlap: the
drain budget was the largest cancellation backstop — at the smallest admitted
grace that is already **22,001 ms** (`cancellation_bounds/1`,
`apps/loopex/lib/loopex/executor.ex:456-474`) — fencing began *after* it, and
the five-second teardown was expected to absorb a sequential stop of up to 512
lease owners and a Store call that can itself block 30 s
(`apps/loopex_store_local/lib/loopex/store/local.ex:65`, `:111`). None of that
adds up. The contract is now one phase at a time, each bounded by a number
that already exists somewhere, and the operator maximum is the sum:

| # | Phase | Bound | Where the number comes from |
| --- | --- | --- | --- |
| 1a | **Close admissions** | **5 s**, this plan's teardown number reused | A synchronous acknowledgement of a **state change**, not of any work: the relay sets a flag, refuses everything after it, and answers. It has nothing to finish, so this bound measures the relay's own responsiveness and nothing else; a relay that does not answer inside it is a relay the daemon has lost, and the stop becomes the `relay_lost` fail-stop |
| 1b | **Settle the admitted** | **300 s** — **ten** Store calls deep, the deepest ticket kind, counted from a traced run rather than from the code; **per phase, not per ticket**, the tickets settling concurrently | The tickets already inside core when 1a answered. The per-kind derivation is below, and at this bound the stop **proceeds** rather than waiting further |
| 2 | **Abort admission** | **150 s** — **five** Store calls deep, at 30 s each; **per phase, not per session**, because the sessions are admitted **concurrently** | The admission waits behind the **callback** a **ready** coordinator is already running, which is at most two commits and so four calls, and then makes its own, which is one |
| 3 | **Cancellation** | The derived backstop: `max` over drained sessions of `cancellation_bounds(g_i).cli_backstop_ms` | Core's own number for how long a cancellation may take |
| 4 | **Coordinator termination** | **5 s**, the coordinator's own `shutdown` (`session_coordinator.ex:134-142`); **per phase, concurrent** across **every** enumerated coordinator | The value core already gives a coordinator to stop in — and a ceiling nothing approaches, because a coordinator does **not** trap exits (`init/1` sets no flag, `session_coordinator.ex:260-292`, and the module's only `Process.flag(:trap_exit, true)` is at `:3108-3109`, inside the per-invocation provider guard it spawns), so it has no `terminate/2` to run and dies at once |
| 5 | **Fence** | **90 s** — **three** Store calls deep at worst, again **concurrent** across sessions | A head read, then the `advance_owner`, and on `commit_unknown` one `transaction_status` query. Three sequential calls, no retries |
| 6 | **Daemon teardown** | **5 s** | One of this plan's two chosen numbers, covering the notice, the closes, the lease owners, the relay, **the runtime tree** and the edges. The runtime stop is attempted with what remains and killed at the bound; its trapping descendants unwind afterwards on their own clock, which the daemon does not wait for |
| 7 | **Store** | **30 s**, its own `@call_timeout` | The stop that releases the marker |

> **Maximum graceful stop = 5 s + 300 s + 150 s + `budget_ms` + 5 s + 90 s +
> 5 s + 30 s = `budget_ms` + 585 s**, and `budget_ms` is the one term an
> operator cannot compute in advance.

**That is a worst case nobody approaches, and saying so is part of stating
it.** Every term but `budget_ms` is a count of the local adapter's 30 s
`@call_timeout`, and that timeout is a ceiling for a wedged filesystem, not a
cost: the calls it bounds are a `File.read`, an append and a directory sync,
microseconds apiece on a working disk. An ordinary stop of an idle daemon
finishes in milliseconds. The sum is what a `TimeoutStopSec` must not be
shorter than if a stop is never to be cut off, not what a stop takes.

**Every phase bound is a Store-call count, and an earlier revision counted
one where the sequence is two or three.** *Every* call into the local adapter
is the same 30 s: `transact/2` at `local.ex:111-113`, `ownership_head/3` at
`:130-132` and `transaction_status/4` at `:116-122` all pass `@call_timeout`
(`:65`). So a phase's bound is not "30 s because it is a Store call"; it is
**(the worst sequential count of Store calls in it) × 30 s**, and the counts
are these:

- **Phase 1b is ten, and the derivation is per ticket kind.** A ticket settles
  when its core call answers, and what that call does before answering is not
  the same for all ten. Counted from the code, in sequence:

  | Ticket kind | Sequential Store calls before the ticket settles | Where |
  | --- | --- | --- |
  | The seven non-resume lease-authorized mutations — `prompt`, `steer`, `follow_up`, `abort`, `respond_interaction`, `admit_resources`, `activate_skill` | **2** | One `OwnerLane.transact/2`, retried once on `commit_unknown` (`session_coordinator.ex:1752-1768`). The wait-behind does **not** apply: this call *is* the session's one in-flight transaction, and the coordinator's `command/3` waits `:infinity` for it (`:146-149`) |
  | `session.create`, fresh | **9**, or **10** with the one retry | Traced, not counted by eye — see below |
  | `session.attach` | **1 + ⌈events ÷ 1,024⌉** — traced at 1 over an empty session and 2 over eight events | The dispatcher's snapshot scan pages the session's events (`event_dispatcher.ex:169-199`, `:926`) |
  | `session.resume` | **no constant**, and traced at **11** over a twelve-record, eight-event session | `Store.runtime_command` (`control.ex:310`), then `load_records` ×2, `transaction_status` (`:1324-1335`), `ownership_head`, **`transact` ×2** — the staged owner attempt `owner_stage_tx` (`:1162-1167`) and then the advance (`:1363`) — then `load_records` ×2 and `load_events` ×2 |

  **A fresh create executes nine adapter calls, and the earlier figure of six
  was a reading of the code rather than a run of it.** Two errors, both of
  them the kind only execution finds:

  1. **`load_pages/4` always makes a terminating empty-page call.** It recurses
     while a page comes back non-empty and returns on `{:ok, []}`
     (`session_coordinator.ex:7090-7114`), so `load_all_records` over a session
     that holds its genesis record is **two** calls, not one — a page with the
     row, then a page without. An earlier revision counted one, having assumed
     a fresh session reads empty; it does not, because the genesis record is
     already there.
  2. **The genesis commit was never counted at all.**
     `create_session/2` calls `create_command_absent?/2` — one
     `Store.runtime_command` (`control.ex:959-965`) — and *then*
     `Store.create_session/3` with `resolve_transaction/2`
     (`:896-897`, `:1679-1684`), which is a second adapter call and which
     retries once on `commit_unknown` at `:1681`. Two calls inside `Control`
     before the coordinator is started at all.

  The executed sequence, in order: `runtime_command`, `transact` (both
  `Control`); then `load_records` ×2, `ownership_head`, `transact`,
  `load_records` ×2, `load_events` (the coordinator reaching `:ready` —
  `:1302-1309`, `:1338`, `:1363`, `:1397-1400`, `:1407`; `load_events` is one
  because a fresh session has no events yet). **Nine, or ten with the retry.**

  **The maximum over the kinds whose depth is a constant is ten**, which is a
  fresh create — constant because a fresh session holds exactly its genesis
  record and no events, so its two `load_records` and one `load_events` are
  fixed. So 1b is bounded at ten calls — **300 s**.

  **Two kinds have no constant depth**, attach and resume, both paging over
  the root's history at 1,024 rows a call. And the resume trace is worth
  reading rather than filing: a **twelve-record, eight-event** session — a
  small one by any measure — already executes **eleven**, one more than the
  bound. That is not an argument for raising the bound to cover it, because no
  number covers a session whose history is unbounded; it is the plainest
  possible demonstration that **1b is a bounded wait that then proceeds**, and
  that the `:acquiring` row in the classification table is an ordinary
  outcome rather than a remote one. An operator whose daemon is stopping with
  resumes in flight should expect the stop to reach 1b's bound and go on.
- **Phase 2 is three, and the unit that blocks is the callback rather than the
  call — of a coordinator that is *ready*.** The abort admission goes to a
  coordinator through `SessionCoordinator.command/3`, a `GenServer` call
  (`session_coordinator.ex:146-149`): what it waits behind is not one Store
  transaction but **whatever callback that coordinator is currently running**,
  to completion. A callback can make more than one adapter call, so the
  question is which callbacks the admission can actually meet.

  **It can only meet a ready coordinator's, and that is a rule rather than an
  observation.** Quiesce admits an abort **only into a session whose `Control`
  entry is `:active`**, which `Control` writes at the instant the owner is
  ready and not before (`control.ex:575-591`: the entry is `:acquiring` until
  `owner_ready` replaces it with `status: :active` at `:579` and replies to the
  waiting caller at `:590`). A session still acquiring has no ready
  coordinator, no active run and therefore **nothing to abort**: quiesce
  admits nothing for it, and it is terminated and fenced exactly as an
  unsettled session is. That is the ordinary outcome of phase 1b proceeding at
  its bound, not an exception to anything — the `:acquiring` row in the
  classification table is where it lands.

  **That matters because the acquisition callback is enormous and the ready
  ones are not.** `handle_continue(:acquire_owner, …)` (`:378`) runs
  `advance_acquisition/1` (`:1142-1145`) into `discover_and_advance_owner/1`
  (`:1186-1203`), `transact_owner/1` (`:1362-1395`) and
  `recover_committed_owner/1` (`:1397-1426`) **without returning**: three
  paging loops (`:1303`, `:1399`, `:1400`, each `load_pages/4` at
  `:7090-7114`, `@page_size 1_024` at `:49`), a `transaction_status`, an
  `ownership_head` and a commit, and it may re-enter itself up to
  `@max_historical_attempts` — **1,024** (`:83`). An earlier revision took
  *that* callback as phase 2's wait-behind and called it three calls, which
  under-counted it by an unbounded factor while over-counting what phase 2
  actually waits for. Both errors are fixed by admitting only into `:active`.

  **The ready coordinator's callbacks, traced.** Every adapter call this
  module makes is at one of nine sites, and they divide cleanly:

  **The enumeration below is over the calls this module makes; the bound needs
  the calls made in the coordinator's *process*.** Those differ if a
  coordinator callback calls out to something that reaches the Store itself.
  The table is what makes the claim checkable by reading; what makes it true
  is the **executed count**, and the phase-2 witness below is where it is
  measured rather than argued.

  | Site | Callback | On the ready path? |
  | --- | --- | --- |
  | `transaction_status` `:1214`, `OwnerLane.transact` `:1242`, `runtime_command` `:1265`, `transaction_status` `:1325`, `ownership_head` `:1338`, `OwnerLane.transact` `:1363` | acquisition only | **no** |
  | `load_records` `:7077`, `load_events` `:7088` | reached only from `discover_prior_tx_id/1` (`:1303`) and `recover_committed_owner/1` (`:1399-1400`) | **no** |
  | `OwnerLane.transact` `:1761-1762`, inside `resolve_transaction/2` | every ready commit, through `apply_transaction/3` (`:1702`) or `commit_internal_result/2` (`:6423`) | **yes** |

  So **no ready callback pages**, the two paging helpers having no caller
  outside acquisition, and every ready commit is **one adapter call, or two**
  where `resolve_transaction/2` re-presents on `commit_unknown`
  (`:1752-1768`).

  **A ready callback commits twice, and an earlier revision said once.** That
  revision argued that a committing callback ends by sending itself
  `:advance_work` and so cannot continue — which is true of
  `apply_transaction/3`, where that send sits (`:1720`), and of nothing else:
  the module has **thirteen** such sends (`:465`, `:627`, `:1425`, `:1720`,
  `:1996`, `:2237`, `:2249`, `:4013`, `:4051`, `:4078`, `:5894`, `:6304`,
  `:6775`), and reaching one is not the same as reaching it *before* the
  callback's second commit. There are **fifteen** paths into
  `commit_internal_result/2`: the thirteen `commit_internal/2` call sites and
  the two into `retain_terminal_operation_fact/2` (`:4062`, `:6381`).

  The traced double is the **cleanup-completion** callback,
  `complete_cleanup/3` (`:5045-5068`):

  1. `settle_executor_work/2` (`:5235`) → `put_executor_fact/3` (`:6379-6384`)
     → `retain_terminal_operation_fact/2` → `commit_internal_result/2` —
     **the executor fact**;
  2. `finish_settled_cleanup/4` (`:5070-5078`) → `finish_cleanup/4`
     (`:5080-5090`) → `commit_terminal/4` (`:2558-2563`) →
     `commit_internal/2` → `commit_internal_result/2` — **the run terminal**.

  Both inside one callback, with no return in between.

  **And never three, which is the part that needs an argument rather than a
  count.** The only candidate third is `settle_owned_operation/3`'s
  `:unconfirmed` clause (`:5399-5400`), which commits a tool result through
  `commit_owned_operation_unknown/2` (`:5426-5444`, the commit at `:5437`)
  between the two above. It cannot co-occur with the first, and the code says
  why in its own comment at `:5396-5398`: *"a run whose executor answered and
  whose fact committed has already left `effect_dispatched`, so this is a
  no-op there, and a `:cleaned` cleanup has nothing unproved to record."* The
  two are mutually exclusive by the stage the run is in — either the executor
  answered and step 1 committed the fact, or it did not and
  `commit_owned_operation_unknown/2` records the unproved result instead — so
  the callback commits the run terminal plus **exactly one** of them. Every
  other ready path reaches `commit_internal_result/2` once, each of the
  fifteen sites sitting in its own function.

  **Maximum over the ready callbacks: two commits, so four adapter calls.**
  Plus the drain's own admission, which is **one** because it does not
  retry — see the non-retrying commit below. **Five, in sequence.**

  **This bound rests on two claims and not on one**, and both are stated so a
  later change fails against them rather than around them: the rule that
  quiesce admits only into `:active`, which keeps the acquisition callback out
  of the wait; and this enumeration, that no ready callback reaches
  `commit_internal_result/2` more than twice. The executed-count witness below
  is what holds the second to a number.
- **Phase 5 is three at worst.** A head read, then the `advance_owner`, then,
  only where that answers `commit_unknown`, **one** `transaction_status` query.
- **And the drain retries nothing, which is a change to the coordinator rather
  than a statement about it.** Core's ordinary commit path retries a
  `commit_unknown` once — `resolve_transaction/2` re-presents the transaction
  on the second line of its own case (`session_coordinator.ex:1752-1768`) —
  and an earlier revision said the drain's abort "is not retried" while also
  saying the admission path was "otherwise untouched". Those cannot both hold:
  a drained abort that took the ordinary path **would** retry. So the drain's
  abort admission commits through a **non-retrying** path, and that is the
  **second half of core change 4's coordinator change**, beside the
  admit-and-pause split — one change with two halves, both in the same clause
  of the same function, and both named in the concept pair's core-change list
  and in the ownership table. A `commit_unknown` on a drained abort is
  therefore ambiguous immediately: the session is fenced, by the rule this
  section already states. An ambiguous **fence** is resolved by the one status
  query, not re-proposed. A **stale**
  fence is not reattempted at all, for the reason the fence table gives.

**The eight phases and the six steps are two cuts through the same stop, and
the mapping is stated rather than left to be inferred.** The numbered sequence
below is what the daemon's owner *does*; the phases are what each part of it
is *bounded by*. Phases 1a and 1b are step 1: 1a is the owner's call to the
relay, 1b is the owner's wait afterwards. **Phases 2 to 5 are
inside `quiesce/1`** — they are core's to enforce, because core owns the
admission, the cancellation, the coordinator's termination and the fence, and
the daemon
passes no deadline in — and together they are step 2. Of the four, only
phase 3's actual value is returned, as `budget_ms`; the other three are fixed
numbers an operator adds to it. Phase 6 begins the instant `quiesce/1` returns
and covers steps 3, 4, 5 and the non-Store part of step 6. Phase 7 is the
Store stop at the end of step 6. Nothing is bounded twice and nothing is
bounded by nobody.

**Who enforces a phase, since a bound with no enforcer is a wish.** Phases 2,
3, 4 and 5 are core's, and the admission and the fence cannot be bounded by
the call that does the work: a coordinator's `command/3` waits `:infinity` by design
(`session_coordinator.ex:146-149`), and must, because a timeout there is not
evidence of anything. So quiesce runs **each session's admission (phase 2) and each
session's fence (phase 5) in its own task**, and bounds the task rather than
the call: one task per session, a single `Task.yield_many/2` against what
remains of the phase's absolute deadline, then `Task.shutdown/2` for whatever
has not answered.

**Those tasks are started `async_nolink` under the runtime's own worker
`Task.Supervisor`**, not linked to whoever called `quiesce/1`, and that
matters now that the caller is the **daemon's owner**. A linked task is an
`{:EXIT, …}` at that owner, and the owner's EXIT clause classifies any exit it
did not ask for as a **fatal class** — so one crashing drain task would take
the daemon down mid-stop with a class naming nothing real. Unlinked, a task
that dies arrives as a `DOWN` the drain handles like any other
non-answer: the session is fenced. The supervisor is the runtime root's third
child, already resolved by `RuntimeSupervisor.children/1` as `workers`
(`runtime/supervisor.ex:73`, `:104`, `:113`), so this needs no new process and
no new option — it is what that supervisor is for. That is the ordinary bounded-task idiom, it needs no new mechanism,
and it is what makes "concurrent across sessions" and "bounded per phase"
the same sentence rather than two hopes.

What a shutdown means is decided, not left open, and the classification table
below carries both rows:

- **a phase-2 admission that does not answer** leaves the session's abort
  neither known-committed nor known-refused, which is the ambiguous case this
  section already handles: **no cleanup is released for it and it is fenced**;
- **a phase-5 fence that does not answer** is exactly a fence whose outcome
  the drain cannot read, so it is reported **`{:unknown, head}`** and the
  domain stays fenced — the same disposition a `commit_unknown` gets, reached
  by a different route;
- **phase 4 needs no task**, being `Supervisor`-shaped already: terminating a
  coordinator is bounded by the `shutdown: 5_000` its own child specification
  carries (`session_coordinator.ex:134-142`), which is the enforcer.

**Shutting down a task does not cancel the call it made**, and the phase-2
row's consequence is worth writing out rather than leaving as an
implication. `Task.shutdown/2` ends the task; the `GenServer` call that task
already delivered runs to completion in the coordinator regardless, which is
the same property that makes a dead caller's transaction commit and a dead
relay task's mutation reach core. So a phase-2 admission the drain gave up on
still **lands**: the coordinator admits the abort, writes the same
`command_admitted` record, and **pauses at the split** with no cancellation
released, because the drained path is what it is running. The drain simply
does not know which of those happened, which is why the session is fenced
rather than cancelled.

That is the right outcome and not a regrettable one: the journal ends up with
an admitted abort and no cleanup, which is exactly what an unsettled session's
journal holds on every other route to it. What the drain must not do — release
a cancellation for a command it cannot confirm — it does not do.

**One rule keeps a phase from starting work it cannot finish, and with the
counts above it can always be honoured.** *No Store
operation begins without at least its own 30 s remaining in its phase.* Because
each phase's bound **is** its worst sequential call count times 30 s, a phase
that has reached its *k*th call still has at least 30 s left **provided the
count is right**. That proviso is the whole of the invariant now, and it is
stated as a proviso rather than as a guarantee: an earlier revision said the
rule "never fires", which was true of a count that had missed four calls and
would have been false in practice. The rule is what catches a miscount — a
sequence deeper than the one this plan counted reaches its bound and stops
there rather than running past it — which is exactly the service it has to
perform, and the executed-count witnesses below are what keep it from being
needed.

**The escape an earlier revision gave it is deleted, because it was
circular.** That revision said a fence with four seconds left is not attempted
and "the session is reported `fence: :not_needed` if the head already moved
and `:unknown` otherwise" — but deciding whether the head moved *is* a Store
read, which is the very thing the rule has just refused. There is no way to
take that branch. `:not_needed` now means one thing only, decided from the
`Control` entry without reading the Store: **a session for which no
coordinator ever existed in this runtime**, where there is nothing that could
write. Every other enumerated session is fenced — settled, unsettled and
absent alike, for the reason phase 5 gives — and its entry is `:committed`,
`:superseded` or `{:unknown, …}`.

**Phase 6 stops the lease owners as a collective sweep, not one at a time.**
Up to 512 of them exist, and stopping them in sequence inside five seconds was
arithmetic nobody did: the owner spawns one stop helper **per lease owner, all
at once**, then waits in **one** loop until every one of those pids has
produced an exit on the owner's own link — the same link it already holds, so
the exits are `{:EXIT, pid, reason}` and not monitor `DOWN`s — and at the
phase's end kills whatever is left with `Process.exit(pid, :kill)` and reads
the exits that follow.

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

**`budget_ms` is still core's to derive and report**, for the reason below;
what changed is that it is one phase among eight rather than the whole drain.

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

**`teardown_ms` is phase 6's bound, `5_000`, and it is a number rather than a
formula.** An
earlier revision named the clock and never gave it a value, which left the
operator bound unstatable and every "what remains" reference undefined. Five
seconds is **chosen, not derived**: the notification writes are one
attempt into an existing buffer, the closes are closes, the lease owners and
the daemon's own processes run no `terminate/2`, and the transfers owner's
closes the descriptors it holds — each of them milliseconds.

**One process under this deadline is not like the others, and an earlier
revision's justification was false for it.** That revision said "of the
processes stopped here only the transfers owner runs a `terminate/2` at all",
which forgets that **step 5, the runtime stop, is inside phase 6**:
`Supervisor.stop(runtime_supervisor, :normal, remaining)` brings down a tree
whose `OwnerGroup` children trap exits, carry `shutdown: :infinity` and have a
`terminate/2` that stops their own worker supervisor with `:infinity`
(`owner_group.ex:14-19`, `:50`, `:86-90`). Nothing bounds that from inside.

So the rule is the one this file already argues for the kill path, applied
honestly here: **the runtime stop is attempted with what remains of phase 6
and killed at the bound.** A tree killed that way is crash-equivalent in the
only sense this plan ever claims — about the journal, not about processes —
and its trapping descendants go on unwinding on their own clock afterwards,
which the daemon does not wait for and the halt at the end of the sequence
ends. Five seconds is therefore a ceiling for the work phase 6 *performs*, not
a promise about what the runtime's subtree has finished, and the drain is why
that is affordable: by the time step 5 runs, every coordinator quiesce could
not settle has already been fenced and terminated inside core. It is
recorded in the limits table with that rationale.

**Phase 6's deadline starts when phase 5 ends**, which is when `quiesce/1`
returns, and it covers every
remaining non-Store action: the stop records, the connection closes, the
listener close, and every stop from the lease owners through the registry.
Every helper under it is given `remaining(teardown_deadline)` and nothing
else — no component has a budget of its own to spend — and the collective
sweep above is what makes 512 lease owners fit inside it.

**`budget_ms` is not knowable from the daemon's flags alone**, and the
operator page says so rather than implying a constant. The composed
`--cleanup-grace-ms` bounds the sessions this daemon *creates*; a root
carrying sessions created earlier may drain longer, because each session
drains under the grace it committed. What an operator can rely on is that the
figure actually used is **reported on the stop line**: `budget_ms`, as core
returned it, beside `drain_id` and the three counts. It is deliberately **not**
on `daemon.status`, and that took correcting — a status field would have to
answer "what budget *would* you use", which the daemon cannot compute, on a
key ADR 0032's DTO tables do not define. A `TimeoutStopSec` is therefore set
from the figure a previous stop reported rather than from one the daemon
guesses in advance. A service manager that kills the daemon sooner than that
turns the stop into a forced shutdown — the journal is still crash-equivalent, but work that would
have settled does not, and the marker may be left for the next daemon's
verified stale-writer recovery. The operator documentation states the bound
and that consequence together, so a `TimeoutStopSec` shorter than it is a
choice rather than an accident.

**Every wait is an absolute deadline, sliced — because the BEAM's `after` has
a domain the plan must respect.** Core admits a `cleanup_grace_ms` up to
`18_446_744_073_709_551_615` (`@max_cleanup_grace_ms`,
`apps/loopex/lib/loopex/executor.ex:75`), and the derived budgets above are
sums of such values. A `receive … after` does not accept numbers that large.
Probed at **both** toolchain pairs:

| `receive … after` | 1.18.5-otp-27 | 1.20.3-otp-29 |
| --- | --- | --- |
| `4_294_967_295` | accepted (waits) | accepted (waits) |
| `4_294_967_296` | **exits `:timeout_value` at once** | **exits `:timeout_value` at once** |
| `18_446_744_073_709_551_615` | **exits `:timeout_value` at once** | **exits `:timeout_value` at once** |

The limit is 2^32-1 milliseconds, about 49.7 days, and exceeding it is not a
long wait but an immediate exit in the waiting process — which for the owner
would be a shutdown that never runs. Nothing in this repository slices a wait
today, so the rule is stated here:

- **Every phase is an absolute instant**, `System.monotonic_time(:millisecond)
  + budget`, computed once. Deadlines compose by comparison, not by
  subtracting one timeout from another, so no arithmetic can produce a
  negative `after` — which is the other way `after` fails, as the 1 ms stop
  probe showed.
- **Every wait is taken in slices of at most `@wait_slice_ms`, 60_000**, a
  minute being long enough that slicing costs nothing measurable and short
  enough to be far inside the domain. After each slice the owner compares the
  clock with the deadline and either waits again or gives up. A budget of any
  admitted size is therefore reachable, and no `after` argument is ever larger
  than the slice.
- **The composition-input table says what a huge value does**: it is accepted,
  not refused, because core accepts it; the daemon simply never passes it to
  `after` unsliced. An operator who composes a grace of a year gets a daemon
  that waits a year, in minute slices, rather than one that exits instantly at
  the first stop.

**Daemon-initiated shutdown is a drain and then a teardown, in reverse
order.** `SIGTERM` reaches the owner — sent directly, or forwarded by the
launcher from a terminal `SIGINT` — and it performs these six
steps itself. They are the owner's code, not a supervisor's behaviour, which
is what lets each one carry a reason and lets the teardown use one deadline
the owner fixes.

1. **The listener stops accepting, and the relay closes admissions — a
   synchronous cut, not a policy.** An earlier revision said "the daemon
   refuses new admissions from that instant" and left the instant undefined:
   stopping the listener stops *new connections*, while every existing
   connection process is still free to submit, and `session.create` did not
   even pass through the relay. Quiesce would then have been snapshotting a
   set of sessions that could still grow underneath it.

   So the cut is a call **and then a wait**, which an earlier revision folded
   into one five-second step it could not possibly contain. The owner calls
   the **relay** — whose scope this
   extends to cover `session.create` and `session.attach` as well as every
   ticketed mutation, ten calls in all — and the relay **closes admissions and
   answers at once**: that is phase **1a**, an acknowledgement of a state
   change, five seconds being a bound on the relay's responsiveness and on
   nothing else. The owner then **waits for the tickets already inside core to
   settle**, which is phase **1b**, bounded at the deepest ticket kind's own
   Store-call depth.

   Folding the two together was the defect: a ticket settles only when its
   core call answers, a prompt's commit is bounded by the Store's 30 s and by
   core's one retry, and `SessionCoordinator.command/3` waits `:infinity` for
   it (`session_coordinator.ex:146-149`) — so a `SIGTERM` arriving during any
   ordinary prompt would have blown a five-second acknowledgement and turned
   an operator stop into `relay_lost`. Refusing new work is instant; waiting
   for admitted work is not, and the two now have their own bounds.

   **At 1b's bound the stop proceeds**, and what that costs is stated. A
   ticket still settling is a core call still running, so `Control` is not
   quite the frozen set an unconditional wait would have given: a still-running
   mutation leaves its session `:active`, which drains and fences exactly as
   any other active session does, and a still-running **create or resume**
   leaves it **`:acquiring`**, because that is the status `Control` writes
   while an owner is being started. So the `:acquiring` row in the
   classification table below is **live on this path, not defensive**, and it
   is classified `unsettled` and fenced for the reason given there. An attach
   still settling changes nothing about the classification at all: it installs
   into the dispatcher, not into `Control`.

   After the cut, no work can enter core through the
   daemon at all. A request of **any kind** arriving on an open connection
   after it is
   refused **`daemon_stopping`**, a generation-2 error code added for it.

   Nothing is written to clients yet and nothing is closed: the connections
   stay open across the drain, because a client that is about to be told
   something true is better served by being told it than by an early close.
2. **The runtime is quiesced within the budget core derives.** The owner
   calls core's `quiesce/1` — which takes no deadline, core owning the drain
   clock entirely — and waits for its answer, which names the sessions that
   settled, those that did not, those that were already gone, and the budget
   core used — and, by the time it answers, every session it could not settle
   has already been fenced
   and terminated inside core. This is the drain; what it does, and what it
   cannot do, is set out below.
3. **Clients are told, and the listener closes. The socket path is left
   where it is.** Each open connection gets one `daemon.stopping` naming
   `operator_stop`, bounded best-effort as ADR 0032 fixes — one write attempt
   into the existing 4 MiB output buffer — and is closed, and the listening
   socket is closed with them.

   **This is a collective sweep too, for the same arithmetic as the lease
   owners.** Up to 512 connections exist, and the write and the close are each
   microseconds — one non-blocking `send` into a buffer the daemon already
   holds, and one `close` — so the work is trivial; what is not trivial is
   doing 512 of them in sequence and then waiting for 512 process exits one
   after another inside phase 6. So the owner writes and closes **all of
   them at once**, then waits **once** for every connection process to exit,
   killing whatever is left at the phase's end. The processes must actually
   end, not merely stop being written to: core change 1's monitor is what
   releases each connection's attachment, and it fires on that process's
   `DOWN`. A connection killed here loses a buffered record it had not
   finished writing, which is the case ADR 0032 already admits when it says a
   client may learn of a shutdown only by its socket closing. **Nothing unlinks the pathname**, on this path
   or any other: the next daemon to prove it holds the marker removes it
   before binding, which is the only safe moment there is.
4. **Every lease owner stops as one sweep, then the admission relay**, inside
   phase 6's deadline. Every lease vanishes with the
   owners; the relay goes after them because it is what holds their admission
   tickets, and stopping it first would discard a ticket a lease owner could
   still be waiting on. Nothing durable is involved, and no client is left
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
   follows: `:normal` or `:shutdown` where the tree came down on its own,
   `:killed` where the kill ended it, anything else classified.

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
   custody and the registry, which hold nothing durable. Then the Store, whose `terminate/2` releases the writer marker —
   see the marker invariant in ADR 0031. The socket path is **left in place**
   by step 3 for the next marker holder to remove — "already gone" was a
   residue of the design that unlinked — so the last
   act is the halt: **`0`**, or the class,
   in the case above where something failed on the way out.

   **The executor is stopped before the lease, and that order is load-bearing**
   rather than alphabetical. The executor privately monitors the lease holder
   for a job's full life and reads its `DOWN` as cancellation evidence
   (`workspace_lease.ex:1-13`). Stopping the lease first would hand the
   executor a cancellation in the middle of its own cleanup; stopping the
   executor first means the lease's death is observed by nobody, which is
   what an orderly stop wants.

   **Each of these four is a helper calling
   `GenServer.stop(pid, :normal, bound)`, with the owner waiting on its own
   link** — the same rule as step 5, and all four are `GenServer`s
   (`apps/loopex_executor_local/lib/executor.ex:22`, `workspace_lease.ex:15`, `transfers.ex:26`,
   `local.ex:55`), so the same call fits all four. The bounds:

   | Process | Bound | What it is waiting for |
   | --- | --- | --- |
   | The executor | What remains of **`teardown_ms`** | Nothing, in the executor itself: it neither traps exits nor defines `terminate/2`, so this stop returns quickly. What takes the time is the Port-owning workers it sets going, which the owner does not hold and cannot wait for |
   | The workspace lease | What remains of `teardown_ms` | Nothing: it has no `terminate/2` and holds no file — the lease *is* the live process, so stopping it revokes it |
   | The transfers owner | What remains of `teardown_ms` | Closing the open transfer descriptors its `terminate/2` holds (`transfers.ex:146-149`) |
   | The tracing capability, then custody, then the registry | What remains of `teardown_ms` | Nothing durable |
   | **The Store** | A **fixed 30 s**, its own phase | Its `terminate/2`, which releases the writer marker (`local.ex:167`) |

   **"What remains" is one deadline, not one budget each.** The owner computes
   an absolute instant once — `System.monotonic_time(:millisecond) +
   teardown_ms` — and every non-Store stop from step 4 through this one waits
   until that instant or until its exit arrives, whichever comes first, then
   kills. So a slow lease owner spends the same clock a slow executor would;
   the worst case is `teardown_ms`, not `teardown_ms` multiplied by the number
   of components. An earlier revision gave each component its own grace, which
   made the worst-case stop a sum nobody had written down.

   **The Store's phase is separate and fixed** — phase 7, and the reason it is
   its own phase is that it is the one stop whose `terminate/2` releases a
   durable exclusion, and its length has nothing to do with any session's
   cancellation grace. It begins when phase 6's deadline is done with, runs
   for at most 30 s, and usually finishes in milliseconds.

   **The residual is stated.** A Store that has not released within its 30 s
   is killed, and the marker survives. That is the same stale marker ADR
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
   killed at phase 6's bound, and it goes on unwinding **while the Store is
   still alive**, because phase 7 gives that stop its own thirty seconds.

   **What refuses its commit is the fence, not a dead Store**, and an earlier
   revision had this exactly backwards. It said such a call "reaches a stopped
   Store and fails as it would after a VM death… a refusal, never a write",
   which is false for the whole of phase 7: the Store is not stopped yet, and
   a straggler's `session_commit` in that window would be an ordinary,
   acceptable transaction. It is refused because **phase 5 has already moved
   that session's owner epoch** — every enumerated session's, settled ones
   included, for exactly this reason — so the adapter answers
   `:stale_owner_epoch` (`state.ex:548-551`). The claim survives with a
   different mechanism under it, and it is a stronger mechanism: it holds
   whether the Store is alive or not, where "the Store is gone" only ever held
   after phase 7 had finished.

   One dependency this step relies on is worth naming rather than assuming:
   `Loopex.Store.Local` **traps exits**, so even an owner that crashes rather
   than stopping runs the Store's `terminate/2` and gives the marker back.
   The plan leans on that, and the adapter's own comment there says the same
   thing from the other side — a kill or a power loss leaves the marker, which
   is why recovery rather than release is what lets a successor open the
   path.

**What quiesce is, and why it is core's.** The Concept promises that an
orderly stop drains admitted work within the cleanup grace. A revision of this
file withdrew that promise for want of a mechanism; the maintainer restored it
on 2026-09-20 and gave it one. The mechanism is a **fourth core change**,
beside concurrent attachment, the existence query and the trace exclusion:

```elixir
Loopex.Runtime.quiesce(runtime) ::
  {:ok, %{
     settled: [session_id],
     unsettled: [session_id],
     absent: [session_id],
     budget_ms: non_neg_integer(),
     drain_id: binary(),
     fences: %{session_id => :committed | :superseded | :not_needed
                             | {:unknown, :no_head}
                             | {:unknown, %{owner_epoch: non_neg_integer(),
                                           journal_version: non_neg_integer()}}}
   }}
```

**One argument, six keys, and no deadline crosses the boundary.** An earlier
revision passed the daemon's teardown deadline in, which contradicted the rule
two paragraphs later that the teardown clock starts when `quiesce/1`
*returns*: a deadline cannot both bound the drain and begin after it. It takes
the runtime and nothing else. Core derives the budget, enforces it, and
returns it as `budget_ms`; the daemon's own five seconds start when the call
comes back. A long derived budget is not a hazard the argument would have
fixed either — it is what the operator bound above already reports, and what a
service manager's own timeout is set against.

Of the six keys, four answer questions the daemon cannot ask. `absent` names
the sessions `Control` still held — as `:active` with a dead coordinator, or
as `:unavailable` — for which there is no live coordinator to drain, which is
neither settled nor unsettled and must not be counted as
either. The classification table below is total over every status `Control`
can hold. `budget_ms` is the drain budget core derived and used. `drain_id` is
the label this drain reports, and `fences` is what the fence below actually
did for each session it touched — `:committed` where the epoch moved,
`:superseded` where the one transaction that could still linearize won the
race first, `:not_needed` where no coordinator ever existed for the session so nothing could write for it, and
`{:unknown, head}` where the Store could not say, **carrying the head the
fence was built from**, because that head is the only thing a successor can
discriminate on. **Without `fences` a fence's failure is
a thing no caller can observe**, which is the defect an earlier revision
carried: it described three outcomes and returned none of them.

**Three parts, in order, and the first two are one thing split in half.**

1. **Phase 2 of the stop, the abort admission: every live coordinator admits
   the abort, and then stops.**
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
   and an unknown answer is an unknown answer, which is what makes phase 2's
   third call the last one it can make and what lets the session be fenced
   rather than waited on. Two halves, one clause, one change.

   **What is genuinely untouched is the record**: `propose_new/3` for
   `%{type: :abort}` writes the same
   `command_admitted` record with `"command_type" => "abort"` and
   `"admission" => "accepted"` (`session_state.ex:1684-1700`), and answers
   `"admission" => "rejected_no_active_run"` where nothing is running
   (`:1750-1761`), which is the right answer for an idle session and needs no
   special case. Nothing about what is written changes; what changes is
   whether the commit is presented a second time and whether cleanup begins on
   the reply.

2. **Phase 3 of the stop, the cancellation: it is released, concurrently,
   only once every admission has resolved.** Core waits for phase 2 to finish for every
   session — committed, refused as having no active run, or failed — and then
   releases the paused cleanups together. That is what makes the Concept's
   ordering true globally rather than per session, and it is also why the two
   phases are inside core: a host that ran them would need two round trips per
   session and a way to hold a coordinator between them.

   **Concurrently, not in sequence**, because each session's cleanup is
   bounded by its own committed grace and running them one after another would
   add those bounds together.

   **Core derives each session's `cleanup_grace_ms` itself** from the durable
   state it already holds (`session_coordinator.ex:422`, `:5366`); the daemon
   passes no per-session number and does not know them. The drain budget is
   the maximum over the drained sessions of
   `cancellation_bounds(g_i).cli_backstop_ms`
   (`apps/loopex/lib/loopex/executor.ex:456-474`), and over an **empty** set
   of drained sessions that maximum is **`0`**: a daemon with nothing active
   drains instantly rather than waiting out a number derived from nothing.
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

   **Core mints it, fresh per session per drain, with the generator core
   already uses for identifiers it mints itself**: `:crypto.strong_rand_bytes(16)`
   rendered as lowercase base16, which is exactly how a runtime ID is formed
   (`session_directory.ex:545-548`) and how a journal token is formed
   (`journal.ex:360`), and the same 128-bit entropy class ADR 0033 fixes for a
   writer epoch. The result is a 32-byte identifier, well inside the
   256-byte bound `valid_identifier?/1` applies (`control.ex:40`, `:1726`).
   No new generator, no new format.

   **It is never derived from, nor shared with, a client's ID.** Deriving one
   would make a shutdown abort forgeable by a client that could guess the
   derivation; sharing one would make a drain collide with a command somebody
   actually sent. Because it is 128 bits of fresh randomness, a collision with
   a client's ID is the same negligible class as two client IDs colliding,
   which this system already lives with everywhere identifiers are minted.

   **What that means for replay, said plainly: every drain admits a new
   abort.** A drain is not a client command and is never replayed — nothing
   retries it under its original ID, because no client holds that ID. Nor can
   one session be drained twice in a lifetime: the daemon exits when the drain
   is done. Across lifetimes, a session's earlier shutdown abort is simply
   history, exactly as a client's earlier abort is, and the next daemon reads
   it as a command already admitted rather than as one to repeat.

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

3. **Terminate every coordinator, then fence every session — two phases, in
   that order, over the same set.** When the budget is spent, core terminates
   **every enumerated coordinator** — settled, unsettled and acquiring alike —
   and waits for every `DOWN`; that is **phase 4**, bounded at the 5 s the
   coordinator's own child specification carries and concurrent across them,
   which is a ceiling nothing approaches because a coordinator does not trap
   exits. Only then does it fence **every session it enumerated**, which is
   **phase 5**.

   **The order is the whole of it, and an earlier revision had the sets
   different.** That revision terminated only the *unsettled* coordinators
   while fencing every session, and then justified the fence's no-retry rule
   with "the coordinator is dead". For a settled session that was simply not
   true: its coordinator was still alive and still able to begin a transaction
   **between the fence's head read and its advance**, which is the one window
   the whole no-second-attempt argument assumes cannot produce a second
   writer. Terminating first makes the premise true for every session the
   fence touches, which is what the fence table's reasoning has always
   required and now actually gets.

   Terminating a settled session's coordinator costs nothing it was still
   doing, and "settled" is what makes that true: its terminal is already
   committed, which is what the word is defined to mean below. What phase 4
   buys is that no enumerated session still has a **process** that could start
   a transaction, so phase 5's fence **races at most one delivered
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

   So quiesce installs a fence the **Store** enforces, using machinery that
   already exists. After terminating an unsettled coordinator it commits an
   **`advance_owner` transaction** for that session (`store.ex:169-179`,
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
   | `tx_id` | **Derived from durable state, not from anything in memory**, by the discipline the coordinator already uses: `owner_identity/3` hashes a namespace, a succession identity and an attempt into a stable ID (`session_coordinator.ex:1346`, `:1490-1498`). Quiesce derives its own from **`("drain_fence", session_id, expected_owner_epoch, expected_journal_version)`** — every input read from the head it just read |
   | `expected_owner_epoch`, `expected_journal_version` | Read **fresh** from `Store.ownership_head/3`, exactly as the coordinator reads them (`session_coordinator.ex:1337-1343`), so the fence binds the state it is actually fencing |
   | `proposed_owner_incarnation_id` | **Derived from the same head inputs**, in the coordinator's `owner_identity/3` form rather than its `fresh_incarnation/2` form — see below |

   **The `tx_id` derives from durable state, and an earlier revision derived it
   from a random number held only in memory.** That revision minted one
   `drain_id` per call and hashed `(drain_id, session_id)`. It reads well and
   it breaks the one rule this fence exists under: a `commit_unknown` fence
   whose deriving process then dies leaves a preallocated ID **no successor can
   reconstruct**, because the only copy of `drain_id` was in a VM that is gone.
   The founding rule is that a preallocated ID be recoverable *from the owning
   command or operation identity* and that resolution be restart-safe
   (`vision-technical.md:710-715`), and a value in RAM is neither.

   So the identity is the head itself, and the drain **reports the head it
   fenced from** for every session it leaves `:unknown`: `fences` carries
   `{:unknown, %{owner_epoch: …, journal_version: …}}` for those, and the stop
   line names the same three values per session beside `drain_id`. That pair —
   the recorded head and the head a successor reads — is what discriminates.

   **The surface is the head, not the transaction status**, and an earlier
   revision got that exactly backwards. It had a successor reread
   `ownership_head/3`, recompute the `tx_id` **from the head it just read**,
   and ask `Store.transaction_status/4`. That question cannot answer anything:
   if the fence committed, the head has moved, so the id recomputed from the
   **new** head is an id nobody ever proposed and the status is `:absent`
   (`state.ex:48-60` answers `:absent` for any tx_id with no retained
   resolution); if the fence never linearized, the head has not moved, the id
   is the fence's own — and the status is `:absent` again. **Two different
   worlds, one answer.**

   The recovery is therefore two steps in this order:

   1. **Read `ownership_head/3` and compare it with the recorded head.** If it
      has moved, the fence is decided and the successor is done — either that
      fence was the mover or it can no longer linearize at all, the adapter
      refusing any transaction whose expected epoch or version no longer
      matches (`succession_refusal/3`, `state.ex:450-463`). Nothing is
      unresolved at the recorded version, and the successor's own ordinary
      owner advance proceeds from the head it just read.
   2. **Only if the head is unchanged**, recompute the `tx_id` from the
      **recorded** head — which is the current head, so the two agree — and ask
      `Store.transaction_status/4` (`apps/loopex/lib/loopex/store.ex:1026-1048`,
      the adapter's own at `local.ex:116-122`), whose closed result set —
      `{:terminal, :committed}`, `{:terminal, {:not_committed, reason}}`,
      `:absent`, `:unavailable` (`store.ex:293-297`) — resolves it.
      `{:terminal, :committed}` with an unmoved head cannot occur and is a
      defect if seen; `{:terminal, {:not_committed, _}}` and `:absent` both
      mean the fence is not there and the successor proceeds; `:unavailable`
      leaves the domain fenced, which is what the founding rule already
      requires of any unresolved unknown.

   That ordering also disposes of the check-then-act objection without an
   argument about windows: step 1's answer is the decision, and step 2 runs
   only in the world where step 1 said nothing has moved.

   **The incarnation is derived too, and it has to be.** The coordinator's
   `fresh_incarnation/2` hashes `make_ref()`
   (`session_coordinator.ex:1500-1509`), so two fences built from one unmoved
   head would carry the same `tx_id` and **different** incarnations — and the
   adapter refuses that: `resolve_known/2` compares the re-presented
   transaction's immutable binding with the retained one and answers
   `{:not_committed, :tx_id_conflict}` when they differ
   (`state.ex:137-144`). A successor resolving an unknown fence, or a second
   drain on a root whose head never moved, would meet that conflict rather
   than the resolution it asked for. The founding rule wants the preallocated
   ID bound to the canonical mutation digest
   (`vision-technical.md:710-716`), and a random incarnation is what breaks
   that binding. So the fence's incarnation derives from the same three inputs
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

   A `:tx_id_conflict` is nonetheless given a row, because a rule with no
   answer for a result the adapter can return is not total: it is handled
   **exactly as `commit_unknown` is** — the head is reread, and it decides. A
   moved head means the fence is done; an unmoved head with a conflict means
   something re-presented a different binding at this version, which is a
   defect, and the session is left `unsettled` with `{:unknown, head}` rather
   than reported as fenced.

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
   | The fence **commits** | The epoch has moved; any older `session_commit` linearized afterwards is refused `:stale_owner_epoch` (`state.ex:548-551`) | `:committed` | `unsettled`, fenced |
   | The fence is refused **`:stale_owner_epoch`** or **`:stale_journal_version`** | The one transaction that could still have been in flight linearized **first**. The fence lost the race on the epoch or on the version; either way the state it read is no longer the state there is, and there is **nothing left to fence** | `:superseded` | Classified **from the journal**, as whatever that commit made it. **No second attempt.** It is not reported as fenced, because it was not |
   | The fence answers **`commit_unknown`** | The Store cannot say whether it linearized | `{:unknown, head}` | Resolved by **one** `Store.transaction_status/4` query under the same derived `tx_id`; an answer that is still unknown after it leaves the session `unsettled` with `{:unknown, head}` carrying the head the fence read, and the domain fenced |
   | **No fence is attempted** | No coordinator ever existed for this session in this runtime, so nothing can write for it | `:not_needed` | As the entry left it |

   **Phase 5 fences every session quiesce enumerated — settled, unsettled and
   absent alike, every one of them with its coordinator already terminated in
   phase 4 — and an earlier revision fenced only the ones that had not
   settled.** That was a hole, and phase 7 is where it opened. The stop kills
   the runtime supervisor at phase 6's bound; `OwnerGroup` traps exits and
   carries `shutdown: :infinity` (`owner_group.ex:14-19`, `:50`, `:86-90`), so
   a trapping descendant of a **settled** session's coordinator can still be
   unwinding afterwards — and phase 7 then keeps the Store **alive** for up to
   thirty seconds more. A straggler's `session_commit` in that window would
   land on a session the drain had already reported `settled`, after the
   census was taken and with no fence to refuse it.

   So the fence is not a remedy for sessions that failed to settle; it is what
   makes the census true for **all** of them. One `advance_owner` per
   enumerated session, concurrent, inside phase 5's 90 s — the phase is three
   sequential calls whatever the session count is — and after `quiesce/1`
   returns, **no transaction for any enumerated session can commit**: the
   epoch has moved and the adapter refuses it `:stale_owner_epoch`
   (`state.ex:548-551`).

   `:not_needed` therefore survives for one case only, and it is decidable
   from the entry rather than from the outcome: a session for which **no
   coordinator ever existed in this runtime** — an entry that reached
   `:unavailable` without one — where there is nothing that could write and
   nothing to fence.

   The cost is stated: a settled session's next activation spends one ordinary
   epoch step, exactly as an unsettled one's does, and the journal a drained
   root carries holds one fence record per enumerated session beside the
   admitted abort. Both are records the released reader replays without a
   migration, which is the property the rollback claim rests on.

   **A stale refusal ends the fence rather than starting a second one, and the
   reason is the serial lane.** An earlier revision rereads the head and makes
   one new attempt — which would be right if more transactions could keep
   arriving, and none can. By the time a fence is attempted the coordinator is
   **dead**, and that holds for **every** session phase 5 fences because
   **phase 4 terminates every enumerated coordinator first** and waits for
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
   has anything to fence, and would make the phase's bound a number nobody
   could state. A
   `commit_unknown` is the opposite case: the transaction may have linearized,
   so it is **resolved once**, never re-proposed under a new identity and
   never retried into an unbounded loop.

   So the claim the plan makes is the one the mechanism supports: when
   `quiesce/1` returns, every session whose `fences` entry is `:committed` has
   had its epoch moved, and every other session is classified from what the
   journal actually holds. What it does **not** claim is that no transaction
   anywhere can still commit — a fence that is itself `commit_unknown` is
   precisely the case where the daemon says so rather than pretending, and it
   says so in a key a caller can read.

   **Phase 3 never releases a session whose admission it cannot account
   for.** A session whose phase-2 abort admission **failed or is ambiguous**
   — a refusal that is not `rejected_no_active_run`, or a `commit_unknown` on
   the admission itself — has no cleanup released for it at all. It is fenced
   like an unsettled session, or, where the fence too is unknown, left fenced
   and reported `unsettled` with `{:unknown, head}`. Releasing a
   cancellation for a session whose abort may or may not be in the journal is
   the one thing a drain must not do, because it would cancel work no command
   admitted.

   **The classification quiesce returns has three lists, not two, and it is
   total over what `Control` actually holds.** An earlier revision wrote it as
   though every entry were `:active`. `Control` has **three** statuses, and a
   session may have no entry at all, so the drain says what it does with each:

   | What `Control` holds | Why it can be there | Which list | Fenced? |
   | --- | --- | --- | --- |
   | `:active` with a live coordinator | The ordinary case | `settled` or `unsettled`, by whether the aborted run's **terminal fact is committed** — see the surface below | **Yes, either way** — see below |
   | `:active` whose coordinator is already dead | Its `DOWN` handler releases the dispatcher fence and **leaves the entry** (`control.ex:805-826`), which is right for residency and misleading for a drain | `absent` | **Yes** — an old transaction from that dead coordinator is precisely the case the fence exists for |
   | `:unavailable` | The status `Control` writes when an acquisition it was waiting on failed or its coordinator went down mid-acquisition (`control.ex:620`, `:818`, `:862`, `:1150`) | `absent` | **Yes**, for the same reason: there is no coordinator, and there may be a transaction |
   | `:acquiring` | The status while an owner is being started (`control.ex:569`, `:1030`, `:1189`) | `unsettled` | **Yes** |
   | No entry | The session is dormant in this daemon, or belongs to no daemon at all | In no list; quiesce enumerates `Control` and nothing else | No |
   | **A phase-2 admission that did not answer** inside the phase, its task shut down | The session's abort is neither known-committed nor known-refused **to the drain** — see below for what the coordinator does | `unsettled`, with no cleanup released | **Yes** |
   | **A phase-5 fence that did not answer** inside the phase, its task shut down **after** the head was read | The fence's outcome cannot be read | `unsettled`, `{:unknown, head}` | The attempt was made; the domain stays fenced |
   | **A phase-5 task shut down before its head read answered** | There is no head, so there is no identity a successor could recompute and nothing was proposed | `unsettled`, `{:unknown, :no_head}` | No fence was attempted. A successor reads the head itself and proceeds; nothing is outstanding at any version |

   **What `settled` means, and where it is read.** An earlier revision defined
   it as "whether its cancellation finished inside the budget" and named no
   observation point, which left the most consequential of the three lists
   with no surface at all — and made phase 4 able to kill a coordinator
   between its cleanup and its terminal commit and still report the session
   settled, with no terminal in the journal.

   **A session is `settled` exactly when the run the drain aborted has its
   terminal fact committed**, and that is read on a surface core already
   serves: the coordinator's own `{:session_status, owner}` call
   (`session_coordinator.ex:414-442`), whose reply carries `active_run_id`
   (`:421`) and `pending_work_ids` (`:425-426`) at the coordinator's committed
   cursor. A run whose terminal is committed appears in neither. **The two
   answers that must differ are therefore the aborted run present and the
   aborted run absent**, and the owner the call requires is the one quiesce
   read from `Control`'s enumeration, which is why that enumeration carries
   it.

   No core change is needed for this, which is worth saying plainly after
   several rounds of adding things: the read exists, quiesce is outside
   `Control` and can make it, and a coordinator that refuses it —
   `:session_unavailable` for a superseded or not-ready owner — is not a
   settled session anyway.

   **So a cancellation that finished without its terminal committed is
   `unsettled`, never `settled`**: terminated in phase 4, fenced in phase 5,
   and reconciled at the next activation like any other. Phase 4 therefore
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
   keeps phase 2's bound honest, the acquisition callback being far deeper
   than any ready one. What it costs is stated rather than hidden: an
   `:acquiring` entry whose cast is merely in flight is a session whose run is
   **ended crash-equivalent** by phase 4's termination rather than cancelled
   through its own grace. Its journal claims no terminal, its ambiguous
   mutation is `commit_unknown`, and the next activation reconciles it —
   which is exactly the unsettled disposition, reached without the drain
   having to guess at a cast it cannot see.

   **`:acquiring` is reachable, and an earlier revision called it unreachable.**
   That revision's argument was the cut: only `session.create` and
   `session.resume` write that status, both start a coordinator inside the
   call, both are ticketed, and the cut waited for every ticket to settle — so
   none could be in flight. The argument died with the phase split. Phase 1b
   waits for the admitted tickets and then **proceeds at its bound**, and a
   resume whose replay is paging a long history is exactly the ticket most
   likely to still be running when it does. So an `:acquiring` entry is an
   ordinary outcome of a stop that fell back on its bound, not a defect.

   It is classified `unsettled` and **fenced**, which is the safe answer and
   also the right one: the session's ownership is mid-advance, so either the
   owner transaction commits — and the fence, reading a head that has moved,
   is superseded and says so — or it does not, and the fence moves the epoch
   under a candidate that will then be refused. Both are decided outcomes.
   Quiesce admits no abort for it, because there is no ready coordinator to
   admit one.

   **Where "reports" lands, since a list in a return value is not a surface.**
   The daemon has two places to put what quiesce answers, and it uses both:
   the counts — settled, unsettled, absent — go in the **stop line on
   `stderr`** beside `budget_ms` and `drain_id`, which is what an operator
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

**`quiesce/1` runs in its caller's process, and putting it inside `Control`
would deadlock the runtime.** An earlier revision said `Control` "already
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

So `quiesce/1` is a function of **`Loopex.Runtime`** that executes in the
**caller's** process — the daemon's owner, which sits on no commit path —
and `Control` keeps serving `post_commit` and `current_owner` throughout.
What it asks `Control` for is exactly two bounded reads:

- **the enumeration**, once: every session entry with its status, its
  coordinator pid and its **owner**, which is what the per-session calls need
  to identify themselves as the current owner;
- **nothing else.** The drain's work — admitting, cancelling, terminating,
  fencing and reading status — is per-session calls the caller's own tasks
  make **directly to coordinators and to the Store**, never through
  `Control`.

Neither read blocks `Control` for longer than a map projection, so a
coordinator committing in the middle of phase 2 is served as usual. That is
the witness: **a commit made by a coordinator during phase 2 completes** — its
`post_commit` answered while the drain is running — **and its session
settles**. Under the design this replaces, that case hangs.

**Why core rather than the daemon.** The daemon cannot do this without
reaching into coordinator internals, which the dependency direction forbids,
or running a cancellation loop of its own, which is precisely the second loop
this milestone forbids — and it certainly cannot admit a durable command on
its own authority. Core owns coordinator lifetime, cancellation and admission,
so core is where a bounded settle belongs. It returns **plain data** — session
IDs, three lists and one integer — so nothing about a coordinator crosses the boundary.

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

**What queues while the owner waits for it.** The owner is blocked in the
`quiesce/1` call for at most the budget core derives, and while it is blocked it is not
reading its mailbox: a linked component's `{:EXIT, …}` waits, as does a second
signal. That is safe in one direction and deliberate in the other. The wait is
bounded, so nothing waits indefinitely; and when the call returns, the owner
reads what queued **before** telling a single client, so a Store that died
during the drain switches the daemon to the fail-stop path with its real class
rather than being reported as an orderly stop. A second `SIGTERM` during the
drain is idempotent: the sequence is already running, and the owner discards
it rather than restarting anything.

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
reason, and on `listener_lost` there is nothing left to write with. A client
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
the one where the thing the daemon would otherwise stop is already gone; the
other **nine** differ only in which component is missing by the time the owner
runs them. **Eleven classes reach this path**, one per linked component of the
fixed set: the two store classes, and `transfers_lost`,
`workspace_lease_lost`, `executor_lost`, `registry_lost`, `custody_lost`,
`capability_lost`, `runtime_lost`, `relay_lost` and `listener_lost` — ten in a
daemon without artifact transfers. Earlier revisions said six and eight here,
which was the count from a design with fewer linked processes. In every one of
them the owner has a class in hand, runs no ordered
sequence, and does not return to serving. A step whose component is already
gone is a no-op, by the rule the `stopping` field states above: under
`listener_lost` steps 1 and 2 are already true and the clients of that
listener learn by the close rather than by a `daemon.stopping` nothing is left
to write.

1. Refuse service immediately — no further admission, no further attach, and
   the listener closed.
2. Close every connection, after one bounded best-effort `daemon.stopping`
   carrying that class: `store_lost`, or `store_capacity_exceeded` when the
   store's own reason was the capacity refusal, and the failed component's own
   class on the other nine.
3. **Stop the executor** — on every class but `executor_lost`, where it is
   the component that already died — under the same discipline as every other
   stop: a monitored helper calling
   `GenServer.stop(pid, :normal, remaining(deadline))`, the owner waiting on
   its own link until the shared teardown deadline and killing on expiry — the
   same five-second deadline the ordered path uses, started when this path
   began. This is not tidiness: the executor is
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
   already gone and its `terminate/2` has already released the marker; there
   is nothing to stop. On the other nine, the Store is **still alive**, and
   because `System.halt/1` runs no `terminate/2`, halting past it would leave
   the marker file behind on a daemon that shut down deliberately. So the
   owner stops it here, in **its own fixed 30-second phase**, exactly as the
   orderly path gives it — no grace of any kind enters that number — so a
   deliberate fail-stop cannot kill it mid-release either.

   **If that stop times out and the Store is killed, the marker survives.**
   That is the one residual on this path and the plan states it rather than
   implying otherwise. It is bounded in consequence, not open-ended: the next
   daemon meets exactly the stale marker ADR 0031's recovery rule already
   covers, and reclaims it where the marker's own recorded holder is probed
   and found dead, refuses with `store_writer_unverifiable` where it cannot be
   decided, and refuses with `store_writer_active` where it is alive. A
   surviving marker is a case with a defined answer, not a corruption.
5. **The socket path is left alone**, exactly as the orderly path leaves it.
   No daemon unlinks a path on its way out, whatever class it is exiting with;
   the next verified marker holder removes it before binding. **The runtime root, the lease owners, the registry, the
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
6. Write the class on `stderr`, then **halt with the non-zero status** for
   that class.

   **A fail-stop has an operator bound too, and it is much smaller than an
   orderly stop's.** Only two of its steps can wait: the executor stop, under
   the same five seconds phase 6 uses, and the Store stop, in its own fixed
   thirty. Nothing else waits on anything — there is no drain, no admission,
   no fence, no coordinator to terminate and no runtime tree to bring down.
   So **the maximum for any fatal class is 5 s + 30 s = 35 s**, with no
   derived term in it at all, which is the one number an operator setting a
   restart policy needs and which an earlier revision left them to infer. On
   the two store classes it is 5 s, the Store being already gone. Nothing restarts anything: the owner `start_link`s its fixed
   set and restarts none, so an exit it did not cause is fatal by its own clause —
   which is why this path exists at all rather than being a restart.

Nothing durable is at risk in that ordering: whatever was ambiguous is
`commit_unknown` in the journal and is reconciled at the next activation, and
whatever was not committed was never promised.

**How the daemon actually ends, on either path.** The owner's last act is
`System.halt(status)` — `:erlang.halt/1` — with `0` for an operator stop and
the non-zero status for a fatal one. That matters to state because BEAM exit
semantics alone would not do it: a `:normal` exit from the owner is ignored by
every linked process that does not trap, so "the owner exits" is not by itself
a shutdown.

**And `halt` runs no callbacks**, which is the whole reason the sequences
above stop things explicitly rather than trusting the exit. `:erlang.halt/1`
terminates the VM immediately: no `terminate/2` anywhere, no `Application`
stop callbacks. The alternative, `:init.stop/0`, does run them — and is
rejected here precisely for that, because it would walk the application tree
and wait on whatever the orphaned owner-group subtree is doing, which is the
unbounded wait the grace exists to avoid. The daemon takes a bounded stop it
performs itself, then a halt that cannot hang.

**One consequence this had to fix.** `terminate/2` not running means the
Store's marker release does not happen at the halt. On the ordered path that
is fine — the Store was already stopped in step 6, and its `terminate/2` ran
then. On the **fatal** path it was not fine, and an earlier draft left a real
hole: for the classes where the Store is still alive (`runtime_lost`,
`transfers_lost`, `workspace_lease_lost`, `executor_lost`, `registry_lost`,
`custody_lost`, `capability_lost`, `relay_lost`, `listener_lost`), nothing
stopped the Store, so the halt
left the marker file behind on a daemon that had shut down deliberately. The
fail-stop path above therefore stops the Store on every fatal class
**except** the two store classes, where it is already gone.

**An abrupt death** — `SIGKILL`, power loss — runs neither path, and is safe
for the reasons the durability rules already give: nothing the journal does
not hold was ever promised, the marker left behind is reclaimed by the next
daemon's verified stale-writer recovery, and the socket file is a stale path
the next marker holder removes.

**The fatal-class map.** Every non-zero exit names one class on `stderr`. Its
**reader is the owner's `{:EXIT, pid, reason}` clause**, which matches the pid
against the fixed set it holds, maps it to a component and classifies the reason;
there is one place in the daemon where a class is decided, and this is it. The
set is closed: **one class per linked component**, so no linked process can
die without a name for it.

| Class | When | Wire reason |
| --- | --- | --- |
| `store_writer_active` | Startup: the marker is held by a live holder | — no socket exists |
| `store_writer_unverifiable` | Startup: the marker's holder cannot be decided | — |
| `store_log_too_large` | Startup: the log is already past the capacity bound | — |
| `session_index_too_large` | Startup: the directory holds more than the index bound | — |
| `socket_path_too_long` | Startup: the path exceeds the derived `sun_path` bound | — |
| `socket_permission_unverified` | Startup: subdirectory or socket ownership/mode could not be verified | — |
| `invalid_socket_path` | Startup: a `--socket` override outside the selected root's `daemon/` directory | — |
| `store_capacity_exceeded` | The Store exited **on the capacity refusal**, distinguished by its own reason | `store_capacity_exceeded` |
| `store_lost` | The Store exited for any other reason | `store_lost` |
| `transfers_lost` | The artifact transfers owner exited | `fatal:transfers_lost` |
| `workspace_lease_lost` | The workspace lease exited | `fatal:workspace_lease_lost` |
| `executor_lost` | The local executor exited | `fatal:executor_lost` |
| `registry_lost` | The credential routing registry exited | `fatal:registry_lost` |
| `custody_lost` | The credential custody process exited | `fatal:custody_lost` |
| `capability_lost` | The tracing capability exited | `fatal:capability_lost` |
| `runtime_lost` | The runtime root exited | `fatal:runtime_lost` |
| `relay_lost` | The admission relay exited, taking every outstanding admission ticket with it | `fatal:relay_lost` |
| `listener_lost` | The listener exited | — the listener is what would have written it |

**A lease owner's exit is the one that is not in this table**, and its absence
is the rule rather than an omission. The owner's clause maps that pid to the
session it belonged to and handles it per session: the daemon closes that
session's controller connection with `control_owner_lost` — the record
best-effort, then the close — leaves every
observer on its own connection attached, and keeps serving every other
session. The next
`session.acquire_control` for it starts a fresh owner with a fresh epoch, on
ADR 0033's ordinary takeover mechanics. The reason is stated there and it is
proportionality: one session's collaboration state is not grounds to end every
other session's, and the daemon-wide rows above are all components whose loss
leaves *nothing* working. `supervision_fault` is therefore gone from the class
set; a lease owner produces no daemon exit class at all.

The rows are named rather than numbered, because a number is a fact about the
start order and this table is a fact about which pid died; the two drifted
apart in an earlier revision and the numbers are gone for that reason. There
is one row per linked process, and the transfers row exists only in a daemon
that has one.

**`registry_lost`, `custody_lost` and `capability_lost` are fail-stop like
every other row, and that follows from ADR 0034 rather than adding to it.**
That ADR makes a dead registry answer `:unavailable` for every later
resolution *until the host recomposes*, and makes a sender that cannot
confirm its trace exclusion refuse rather than resolve; in a daemon,
recomposing is restarting the process. A daemon that
kept running would serve a runtime whose every model invocation refuses for a
reason no client can fix, which is exactly the shape the fail-stop rule
exists for.

**One class comes from outside this map:** `owner_lost`, which the signal
handler halts with when a signal arrives and the owner is not alive to run the
sequence. No linked process produces it, and it is the only exit class that is
not a row above.

The wire column matters because ADR 0032's `daemon.stopping` `reason` admits
`operator_stop`, `store_lost`, `store_capacity_exceeded` and `fatal:<class>`,
so every class above that a running daemon can reach has a reason a client can
receive — *if* there is still a socket and the write succeeds. The startup
classes have none, deliberately: no socket exists when they occur, so no
client is holding one. Neither does `listener_lost`, where the listener is
what died, nor `owner_lost`, where the process that would write it is gone:
those clients learn by EOF.

**The daemon's own log is bounded and redacted by the rules that already
exist.** Everything the daemon writes to `stderr` — refusals, warnings, the
fatal reason — is a bounded non-secret line under ADR 0029's discipline, and
carries no credential, no token, no model content, no tool argument or result,
and no artifact bytes, exactly as ADR 0030's metadata rule already forbids for
a trace or a telemetry span. Nothing here is a new logging plane: the daemon
has no diagnostic surface of its own beyond these lines and the records it
already sends on the wire, and the fatal-class map above is the whole
vocabulary of what a **fatal** exit may say. An **orderly** stop adds exactly
one line and no class: a census naming `drain_id`, `budget_ms`, the three
counts quiesce returned and, for every session it left `{:unknown, head}`,
that session's id with the `owner_epoch` and `journal_version` its fence read
— the values a successor compares against, and the only part of the census
that is recovery data rather than a count. That line is the only thing an ordinary stop writes
to `stderr`, and it names no fatal class, which is what a reader checks it
for.

**Reverse cleanup.** Startup happens inside the owner, so a failure at any
step unwinds what that step and its predecessors did, in reverse — and
"predecessors" means **every process the startup started**, not the three an
earlier revision named. A bound socket is **closed, and its path left in
place** — reverse cleanup unlinks nothing, for the same reason no shutdown
path does — a `daemon/` subdirectory this start created is removed **when it
is empty**, by the matrix below — no lease owner can exist
yet, since none is started before a session is activated — and **every pid the
composition function returned is stopped in reverse
start order** — runtime, executor, workspace lease, transfers where it exists
— then the tracing capability, custody and the registry, and the Store last, so its `terminate/2`
releases the marker.

Each of those stops is the same call and the same discipline as a shutdown
stop: a monitored helper running `GenServer.stop(pid, :normal, …)`, the owner
waiting on its own link against **one shared teardown deadline** and killing
on expiry, and — for the Store — **the same fixed 30 s phase** the orderly
path gives it, for the same reason: this is the stop that releases the marker,
and a failed start that killed the Store mid-release would leave exactly the
stale marker it is trying not to leave. Startup introduces no second teardown
mechanism; it reuses the one the shutdown sequence defines, against the pid
map it already holds.

The owner does this in its own start path rather than leaving it to a crash,
because a crashing owner would take the links down without releasing the
marker or removing the directory it made. A daemon that refuses to start
leaves **no marker held** — which is what lets an operator fix the cause and
try again without a recovery step.

**What a failed start leaves on disk is one matrix, because three passages
gave three answers.** One said a bound socket is closed with its path left in
place while the `daemon/` subdirectory is removed — which cannot both happen,
a directory holding a socket file not being empty. Two witnesses then asserted
"no socket file exists afterwards" while the no-unlink witness asserted the
opposite for the same failure. The rule is the bind:

| Where the start failed | Socket pathname | `daemon/` subdirectory |
| --- | --- | --- |
| **Before the bind** — path resolution, signal install, the registry, custody or capability, composition and the marker, the index read, the relay, the subdirectory create | **None exists**; nothing was bound, so nothing is left | Removed **only if this start created it and it is empty**; a subdirectory that was already there, or that holds anything, is left exactly as found |
| **At or after the bind** — the permission read-back, the accept, the readiness write, or any component dying during those | **Left in place**, closed but not unlinked, like every other exit path | **Left in place**, because it holds that pathname |

Both halves follow from one rule already stated and one plain fact: **no
predecessor path ever unlinks**, so a bound socket's pathname survives a
failed start exactly as it survives a stop; and a directory holding a file
cannot be removed, so the subdirectory removal is conditional on there being
nothing in it. A daemon that refuses to start may therefore leave a socket
pathname, which the next verified marker holder removes before binding, and
that is the one thing it leaves behind.

**Witnesses.** Most run a real daemon operating-system process; a few read
state no surface exposes and run **in-VM**, in the same VM as the daemon or
the runtime they are about. Each is labelled.

**A note on how these are written, added after a review found three that
could not be checked.** Every witness here names the **surface** it reads, the
**two answers** that must differ on it, and — where the surface is new — the
**change that creates it**. A case asserting "core holds N" without saying
where N is read is not a case anybody can write; nor is one whose difference
depends on a code path that does not exist. **Five** of this plan's surfaces
are new work rather than existing behaviour — one per core change, which is
not a coincidence: a core change that no witness could read would be a change
nothing proves. Each is named where it is used:

| Surface | Created by | Read by |
| --- | --- | --- |
| The dispatcher's release on `DOWN`, the attacher pid and monitor reference it keeps on the attachment to do it, and the transfers it releases with it | Core change 1 | The concurrent-attachment cases, the ADR 0028 transfer case, the scoped-replacement case and the attach connection-loss case |
| The existence query's five-result set | Core change 2 | `session_existence_query_test.exs`, one case per result, and Outcome 4's row |
| `Control`'s excluded-pid set, and `Entry`'s redaction of a keyword pair under its own key | Core change 3 | The trace-exclusion cases, and the render pair that must differ |
| `quiesce/1`'s three lists, `budget_ms`, `drain_id` and the per-session `fences` map | Core change 4 | The drain cases, the fence cases and the stop line |
| `disposition` and `control_entry`, on `create_session_detailed/3` and `resume_session_detailed/3` | Core change 5 | The create and resume connection-loss cases, and the case asserting `create_session/3`'s own return is byte-identical to today's |

Everything read outside those five exists today — the journal, a supervisor's
children, a pid's liveness, a socket's EOF, or the daemon's own `stderr`.

- **Idle shutdown.** A daemon with sessions activated and no work in flight
  receives `SIGTERM`, writes nothing further to `stdout`, closes every
  connection with the stop reason, leaves the socket pathname for the next
  marker holder, releases the marker and
  exits `0`; the foreground server then opens the same root immediately, which
  is what proves the marker was actually released. The case also asserts the
  negative that the `stopping` field exists for: **no fatal class is recorded
  at any point during the stop**, and `stderr` carries **nothing but the one
  census line** — `drain_id`, `budget_ms`, three counts and no unknown-fence
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
  Store's own step — where the stop raises `noproc` and is caught — then
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

  A fourth proves the recovery property, and its surface is the **head**,
  which is the correction a review found: the fence is made to answer
  `commit_unknown`, the drain records `{:unknown, head}` for that session and
  reports it on the stop line, the whole daemon is **killed** before it can
  resolve anything, and a **second process** reads
  `ownership_head/3` and compares it with the recorded head. The case runs
  **twice** and the two runs must give different answers on that surface: in
  the first the held fence is released so it linearizes, and the successor
  reads a head that has **moved**, concludes the fence is decided and asks no
  status at all; in the second it never linearizes, the successor reads the
  **unchanged** head, recomputes the `tx_id` from `(session_id, owner_epoch,
  journal_version)` and gets `:absent` from `Store.transaction_status/4`. The
  case that asserted `transaction_status/4` alone is withdrawn: that call
  answers `:absent` in **both** worlds — a committed fence moves the head, so
  the id recomputed from the new head was never proposed — and a witness whose
  two branches assert the same value proves nothing. Neither surface is
  reachable from anything the dead daemon held, which is the property the
  memory-held `drain_id` could not have given.
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
  on it. Both also assert its `command_id` is **an identifier no client in
  the case ever sent**, and that it differs between two sessions drained by
  the same stop, so a shared or derived ID would fail rather than pass
  quietly. The operator learns the cause from `daemon.stopping` and from
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
  settled and left phase 4 free to kill the write it still owed.

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
  equality: it holds exactly **two** more records per enumerated session — the
  admitted abort, and the `advance_owner` that fences it. An earlier revision
  said one, from the revision in which only unsettled sessions were fenced.
  What remains identical is what the abrupt-death case actually needs:
  the unresolved transaction and the outcome reconciliation produces.

  **A settled session's straggler is the case this fence exists for**, and it
  has its own assertion here: a transaction for a session the drain reported
  `settled` is held inside the Store and released during **phase 7**, while
  the Store is still alive and the runtime has already been killed. It is
  asserted refused `:stale_owner_epoch` and absent from the journal. Before
  every enumerated session was fenced, that commit would have landed after the
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
  sequence, because the marker was already released by the Store's own
  `terminate/2` before the daemon could act. A second daemon starts on that
  root immediately with no stale marker to recover. The capacity variant
  reports `store_capacity_exceeded` instead, and the case asserts the executor
  was stopped before the halt, and that its stop *returned* rather than timing
  out into a kill. It does **not** assert that no operating-system child is
  left behind: that is the residual this plan states, since the cleanup runs
  in workers the daemon cannot wait for.
- **One class per linked component of the fixed set.** Each is
  killed in turn, in its own case, and the daemon is asserted to exit with
  that component's class, to send that component's `fatal:<class>` on the wire
  where a socket still exists, and — for the classes where the Store is
  still alive — **to leave no stale marker**, proved by the next daemon
  opening that root with nothing to recover; nine of them in a daemon with
  transfers enabled and eight without — `runtime_lost`, `transfers_lost`,
  `workspace_lease_lost`, `executor_lost`, `registry_lost`, `custody_lost`,
  `capability_lost`, `relay_lost`, `listener_lost`, beside the two store
  classes. The set is closed for the
  fixed set, so one of those dying without a class is a failing case rather
  than a silent `:shutdown`. A lease owner is deliberately not in this case:
  its own witness is below, and it asserts the daemon **keeps running**.
- **No daemon ever unlinks, and a successor's socket survives.** Three cases,
  one per exit path, each asserting the **absence** of an unlink rather than
  its correctness. After an **orderly stop**, the pathname is still on disk
  and `connect` to it fails as refused rather than hanging; the next daemon
  removes it, binds and serves. After a **store-loss fail-stop**, the same.
  After a **failed start at or after the bind** — the marker acquired and the
  socket bound, then the permission read-back refused — the same again, with
  no marker held. The index-bound failure is **not** this case and is asserted
  the other way in the reverse-cleanup witness, because it happens before the
  bind and there is no pathname to leave.

  The race the old design had is then run directly: the first daemon is held
  at the instant it would have unlinked, its Store is killed so the marker is
  released, the second daemon acquires, removes the stale path, binds and
  prints readiness, and the first is released. The case asserts the second
  daemon's socket is **still bound and still serving a client** afterwards —
  which a predecessor that unlinked under any precondition would have
  broken.
- **A `--socket` path outside the root is refused.** A path in a directory
  that is otherwise perfectly valid — right owner, right mode — but outside
  the selected root's `daemon/` directory exits `invalid_socket_path` with no
  marker taken, no socket bound and nothing left behind.
- **Signals, one case per signal per route, and the route is what decides.**
  Four cases send `INT`, `TERM`, `HUP` and `QUIT` **to the launcher**,
  `apps/loopex_cli/bin/loopex`, and each asserts the **orderly sequence** —
  because the launcher traps all four and forwards `kill -TERM`
  (`bin/loopex:60`), so through the shipped path all four mean stop. Four
  more send the same signals **to the escript process itself**: `TERM` asserts
  the orderly sequence, and `HUP` and `QUIT` assert the emulator's own
  behaviour with **no** orderly stop — no `daemon.stopping` record, no drain —
  which is what makes "the daemon installs on `SIGTERM` and nothing else" a
  checked claim rather than a preference. `SIGINT` to the escript has no case
  and states why: `:os.set_signal/2` refuses `:sigint` (`interrupt.ex:13-17`)
  and the emulator's break handler owns it, so there is nothing of this plan's
  to assert. Every case names which process it signals, which is the whole
  point of the pair. A ninth asserts the install order: a `SIGTERM`
  delivered before startup completes ends a daemon that holds no marker and
  has bound no socket, proved by a following daemon starting with nothing to
  recover.
- **`owner_lost`, by the monitor and not by a later signal.** The owner is
  killed while the daemon is otherwise healthy and **nothing else happens**:
  no signal is sent. The case asserts the process halts non-zero with
  `owner_lost` on `stderr` within a bounded time of the kill — the bare class,
  since nothing writes a `fatal:` reason anywhere but the wire and there is no
  client to tell — which is
  the command process's monitor doing it. A second case kills the owner and
  *then* sends `SIGTERM`, asserting the same class by whichever route wins, so
  the two cannot both fail silently.

  **Two more cases straddle the marker, and they are what the `{:continue,
  :start}` ordering exists for.** The owner is killed **before** it acquires
  the marker and again **after** it has acquired it but before the socket is
  bound. Both assert the same two answers on the same two surfaces: the
  process exits non-zero with `owner_lost` on `stderr`, and a following daemon
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
  daemon starts cleanly with nothing to recover. A third kills the Store immediately
  after the composition call returns and asserts the start aborts into reverse
  cleanup rather than binding a socket and announcing readiness on top of a
  dead component.
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
- **A relay task that dies without a result keeps its ticket and takes the
  daemon down.** The task performing a ticketed mutation is killed while the
  call is in flight. The case asserts the ticket is **still outstanding**,
  that no replacement owner is granted the session in the meantime, and that
  the daemon exits `relay_lost` — **not** that the mutation is treated as
  settled. It is the case that separates this design from the one that
  admitted a successor over a call it had lost track of.
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
  acquisition through.
- **The credential processes are fatal like every other component.** The
  registry, the custody process and the tracing capability are each killed in
  their own case; the daemon exits `registry_lost`, `custody_lost` and
  `capability_lost` respectively, sends that
  `fatal:<class>` on the wire, and leaves no stale marker.
- **The stop timeout is exercised, not assumed.** A session is made to hold
  the runtime's teardown past the shared teardown deadline. The case asserts the
  owner **survives** rather than dying of whatever the stop did to the helper,
  that it then kills the runtime supervisor, and that it still reaches the
  Store stop — the step a stop called inline would skip.
- **Cleanup grace 1 ms: the owner survives, classifies from the exit, and
  still releases the marker.** The same daemon is composed with
  `cleanup_grace_ms: 1` — the smallest admitted value, since `0` is refused
  with `cleanup_grace_invalid` — and stopped with a component whose teardown
  takes longer than that. This is the case that broke every inline design: at
  that grace `GenServer.stop/3` raises `ErlangError`/`:timeout_value` rather
  than exiting, so no `catch :exit` clause would have run. The case asserts
  the owner survives, that it kills and reads the exit, that the class follows
  the **exit reason** and not the stop's outcome — `operator_stop` and exit
  `0` where the component still managed to exit `:normal`, its own class where
  it did not — and that the sequence still reaches the Store stop.

  It also asserts the thing a grace of 1 ms would otherwise have broken:
  **the next daemon opens that root with no stale marker to recover.** That is
  the Store's own phase doing its work — the Store is waited on for a fixed
  30 s that no grace can shorten — and without it this case would have left a
  marker behind on a deliberate operator stop.

  Two more cases sit beside it. One composes `cleanup_grace_ms: 0` and asserts
  the daemon refuses at startup with `cleanup_grace_invalid`, holding no
  marker and binding no socket. One composes a grace **larger than 2^32-1
  milliseconds** — admitted, because core admits up to
  `18_446_744_073_709_551_615` — and asserts the daemon starts, stops and
  releases the marker normally: the value reaches no `receive … after`
  unsliced, which is what the wait rule promises and what a direct `after`
  would have turned into an immediate `:timeout_value` exit. All of them run
  at both toolchain pairs, because both timeout results were observed at
  both.
- **A replayed create repairs, a fresh create charges.** Two cases on the
  create disposition. A session whose directory entry was never written is
  recovered by replaying `session.create` with the original `command_id`: the
  case asserts core answers `disposition: :historical` with
  `control_entry: :dormant`, that **no activation is charged**, that no
  coordinator starts, and that the daemon repairs the directory entry and
  index row from that answer alone. A genuinely fresh create asserts
  `disposition: :fresh`, one activation charged, and a live coordinator. A
  third asserts the pair for a session that is already active —
  `:historical` with `control_entry: :active` — and that the daemon repairs
  nothing, because an activated session already recorded both.
- **At the ceiling, every create is refused.** A daemon at its 64th activation
  refuses `session.create` with `activation_ceiling_reached` **whether the
  create is fresh or a replay**, and the case asserts the replay is refused
  too — the stated cost — and that no coordinator was started by the attempt.
- **The ceiling holds under concurrency, which counting afterwards would not.**
  A daemon at **63** activations receives two activation-capable calls at
  once — one create and one resume, on two connections. The case asserts
  **exactly one** succeeds, the other is refused `activation_ceiling_reached`,
  and that core started **one** coordinator, not two: the refusal happens
  before the second call is made, so there is no second coordinator to
  discover afterwards.
- **A dormant resume at the ceiling is refused before the call.** A daemon at
  **64** receives `session.resume` for a dormant session. The case asserts the
  refusal, and asserts core was **not called** — proved by that session having
  no coordinator and no new journal record — which a post-call count would
  have failed by starting a sixty-fifth.
- **Two concurrent attaches at the attachment ceiling.** A daemon at 511
  attachments receives two `session.attach` calls at once. On the wire the
  case asserts exactly one result and one refusal — two answers that plainly
  differ. The count is **in-VM**: core exposes no attachment count, so the
  case reads **the dispatcher's `attachments` map** (`event_dispatcher.ex:154`,
  `:823`) in the same VM and asserts **512**, not 513. Saying "proved by core holding 512" without saying where
  that number is read would have been the same unobservable claim this round
  removed elsewhere.
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
- **Reverse cleanup, on both sides of the bind.** A startup made to fail
  **before** the bind — at the index bound, after the marker is acquired —
  leaves no marker held, **no socket pathname** and no `daemon/` subdirectory
  it created. A startup made to fail **at or after** the bind — at the socket
  permission read-back — leaves no marker held, **the socket pathname in
  place** and the subdirectory with it. Both are proved by a second daemon
  starting cleanly on the same root with no recovery step, and the two
  assertions about the pathname are opposite, which is the point: an earlier
  revision asserted the same answer for both and contradicted the no-unlink
  rule for one of them.
- **Readiness ordering.** A client that connects the instant the readiness
  line appears is served; no readiness line is printed when the marker is
  held elsewhere, the socket permission check fails, or the index bound is
  exceeded, and each of those exits non-zero with its own class.

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

**The daemon's fixed processes — eleven rows, ten without transfers: the owner
and the ten it links.** The count is stated that way because the table has one
more row than the link set does, the owner being the process that holds the
links rather than one of them, and an earlier revision headed eleven rows
"ten".

| Process | Started by | Linked to | Stopped by | Its death |
| --- | --- | --- | --- | --- |
| **Daemon owner** | The `loopex daemon` command process, `GenServer.start/3` — **unlinked**, monitored immediately, with `init/1` acquiring nothing and the startup sequence running in `handle_continue(:start, …)` behind a `:go` the caller sends after the monitor | Nothing; the command process holds a monitor | Itself; it halts the VM | The command process halts non-zero with `owner_lost`; the signal handler's backstop is the second route |
| Credential routing **registry** (ADR 0034) | Daemon owner, first | Daemon owner | Orderly step 6 | `registry_lost`, daemon-fatal |
| Credential **custody process** (ADR 0034), one for the one composed model configuration | Daemon owner, second | Daemon owner | Orderly step 6 | `custody_lost`, daemon-fatal |
| **Tracing capability** (ADR 0034) | Daemon owner, third, before composition | Daemon owner | Orderly step 6 | `capability_lost`, daemon-fatal: a sender that cannot confirm its trace exclusion refuses rather than resolves, so every model invocation would fail for a reason no client can fix |
| **Store adapter** (ADR 0031) | The composition function, in the owner's process | Daemon owner | Orderly step 6, **last**, in its own fixed 30 s phase | `store_lost`, or `store_capacity_exceeded` on its own capacity refusal |
| **Artifact transfers owner** | The composition function | Daemon owner | Orderly step 6 | `transfers_lost`. **Absent** where transfers are disabled |
| **Workspace lease** | The composition function | Daemon owner | Orderly step 6 | `workspace_lease_lost` |
| **Local executor** | The composition function | Daemon owner | Orderly step 6, before the lease | `executor_lost` |
| **Runtime root** (a supervisor; its children are core's, below) | The composition function | Daemon owner | Orderly step 5 | `runtime_lost` |
| **Admission relay** | Daemon owner, after the runtime | Daemon owner | Orderly step 4, after the lease owners whose tickets it holds | `relay_lost`, daemon-fatal |
| **Listener** | Daemon owner, last of the fixed set | Daemon owner | Step 1 stops it accepting; step 3 closes it, leaving the pathname | `listener_lost`, and the one fatal class no client can be told |

**The daemon's dynamic processes, each with its bound:**

| Group | Started by | Bound | Its death |
| --- | --- | --- | --- |
| **Lease owners**, one per session under lease or acquisition | Daemon owner, on the first lease operation after existence validation | At most 512 at once, ADR 0032's per-daemon ceiling reused | **Session-scoped**: that session's controller closes with `control_owner_lost`, observers stay, the replacement's first grant waits on the relay's tickets |
| **Connections**, one per accepted client | The listener | **512 concurrent**, ADR 0032's connection ceiling — the attachment number reused, and not the attachment ceiling itself, which bounds nothing about a client that never attaches | That client's connection closes |
| **Stop helpers**, one per stop | Daemon owner, `spawn_monitor` | One at a time, except phase 6's lease-owner sweep, which spawns one per lease owner at once and so is bounded by the 512 above | Nothing: monitored, never linked |
| **Relay tasks**, one per ticketed call — the eight lease-authorized mutations, `session.create` and `session.attach`; **not** the three artifact-transfer methods, which mutate neither `Control` nor the journal | The relay, after the ticket is acknowledged | One per outstanding ticket | Keeps its ticket; the relay exits `relay_lost` |

**Core's processes, as groups with their owner.** The runtime root supervises
seven children under `:rest_for_one` (`runtime/supervisor.ex:64-90`, strategy
at `:92`), in this order: the tool
registry, `Control`, a worker task supervisor, an owner-group dynamic
supervisor, a session dynamic supervisor, the event dispatcher and the tracer.
The order is load-bearing under that strategy: a restart of the *n*th child
restarts every child after it, so `Control`'s restart takes the five beneath
it including every session coordinator, and the tracer's takes nothing.
The daemon holds none of them and names none of them in its fatal map — it
links the **root**, and a death anywhere beneath it that the root does not
survive arrives as `runtime_lost`.

| Group | Owner | Count | What its loss means to the daemon |
| --- | --- | --- | --- |
| **Session coordinators** | Core's session supervisor, `restart: :temporary` | One per active session | Core's own refusal on the next command; **no signal reaches the daemon and none is owed**. `quiesce/1` terminates and fences them at the drain deadline |
| **Owner groups and their workers** | Core, beneath a coordinator | Per coordinator | Core's; a trapping owner group unwinds on its own clock and the daemon does not wait |
| **Event dispatcher** | The runtime root | **One per runtime**, holding the per-attachment queues — not one per attachment, which an earlier revision of this table said | Restarted by the root under `:rest_for_one`, which restarts the tracer with it |
| **`Control`** | The runtime root | One per runtime | Holds the trace exclusion set and the session entries; it is the root's **second** child, so under `:rest_for_one` its restart carries the workers, the owner groups, the sessions, the dispatcher and the tracer with it — every live coordinator, not merely every trace session |
| **Tracer** | The runtime root, **last** child | One per runtime | Restarts alone, changing pid, which is why nothing holds a tracer pid |

**The adapter's and executor's processes, likewise:**

| Group | Owner | Count | Its death |
| --- | --- | --- | --- |
| **Provider sender and guardian** (ADR 0034) | The adapter, inside the calling process | Two per invocation | That invocation's refusal, one of the seven atoms. No daemon class |
| **Provider child, its Port and OS process** (ADR 0019) | The adapter's launcher | One per invocation | That invocation's refusal |
| **Per-job Port worker, carrier and guard** (ADR 0022) | The local executor | One set per job | The job's outcome, reconciled through `commit_unknown`. **These are the processes the daemon cannot wait for at a halt** |

| Boundary | Owner | What fails | Who observes it, and how | What the client sees | Durable / not durable |
| --- | --- | --- | --- | --- | --- |
| **Store ↔ daemon** | `loopex_store_local` owns the marker and the log; the **daemon owner process** holds the Store's link and pid | Append error, including the capacity refusal | The Store stops **itself** (`local.ex:251-270` answers `{:stop, reason, commit_unknown, state}`) and releases the marker in `terminate/2` (`local.ex:167`). The owner's `{:EXIT, store_pid, reason}` clause receives it **with the store's real reason**, which is what distinguishes `store_capacity_exceeded` from `store_lost` | `daemon.stopping` with `store_lost` or `store_capacity_exceeded`, one bounded attempt, then the socket closes | **Durable:** whatever committed. **Not:** the failed append; the in-flight transaction is `commit_unknown` and reconciles later |
| **Store ↔ daemon (startup)** | The adapter | Marker held, unverifiable, log too large | `WriterLock.acquire` refuses with `store_writer_active` / `store_writer_unverifiable`; `Log.open` refuses `store_log_too_large` (`log.ex:80-84`) | Nothing — no socket exists yet | **Not durable:** nothing was written. Reverse cleanup leaves no marker |
| **Core ↔ daemon: existence query** | `loopex` answers; the daemon asks | Root unreadable, malformed ID, unrecognised answer | The query's own closed result set — `present`, `absent`, `invalid_id`, `store_unavailable`, `unexpected` (this plan's new core operation) | The matching refusal, four of them distinct; nothing created, nothing attached, no lease | **Not durable:** the query writes nothing, proved by a byte-identical root |
| **Core ↔ daemon: attach** | `loopex` owns the cursor barrier, snapshot and queues | Barrier race, stale handle, queue overflow, **an attachment whose holder is gone** | Core's existing attach transaction and stale-handle checks; **and core change 1's monitor on the attaching process, which is what releases an attachment when its holder exits — the daemon attaches from its per-connection process, so a closed connection releases its attachment with no call**; the daemon reads no coordinator state to repair a race | Snapshot then contiguous at-least-once events, or detachment at the last emitted cursor with a stable reason | **Durable:** the events. **Not:** the attachment, the window, the buffer |
| **Core ↔ daemon: resume** | `loopex` | Placement mismatch, unknown session, already-resolved command | Core's existing resume path and command idempotency (`control.ex:901-907` returns the historical result without starting an owner) | Core's refusal, forwarded unchanged | **Durable:** the resume command and its result |
| **Core ↔ daemon: commands** | `loopex` admits; the daemon forwards | **Coordinator death** | Core's `DynamicSupervisor` (`restart: :temporary`, `session_coordinator.ex:134-142`); `Control` consumes the `DOWN`, releases the fence and leaves the entry (`control.ex:821`). **No signal reaches the daemon, and none is owed** — the daemon supervises the runtime, not the coordinators beneath it | Core's existing refusal on the next command for that session, forwarded unchanged. `residency` still reads `active`, which remains true: this daemon did activate it | **Durable:** whatever committed before. **Not:** any claim about liveness |
| **Lease owner ↔ connections** | `loopex_daemon` | A session's lease owner dies; its in-flight admission set goes with it, and the relay's ticket for any mutation it had authorized does not | The owner's `{:EXIT, pid, reason}` clause maps the pid to **its session** rather than to a daemon class — the one session-scoped row in this table, on the maintainer's decision of 2026-09-20 | That session's controller connection is sent `control_owner_lost` and closed with its attachment; every observer, being on a connection of its own, stays attached; the next `session.acquire_control` starts a fresh owner and mints a fresh epoch, its first grant waiting until the relay's outstanding tickets for that session settle | **Not durable:** the lease, the epoch, the in-flight set. The journal is untouched, and a mutation already inside core settles or refuses exactly once under core's serial ownership |
| **Lease owner ↔ connections (expiry)** | `loopex_daemon` | A holder stops renewing, or a mutation is unresolved at the deadline | The lease owner's own monotonic deadline; the in-flight set decides when a takeover is granted | The holder's next mutation refuses; a takeover is eligible at the deadline and granted when the in-flight set empties | **Not durable:** the lease. The mutation that was in flight settles or refuses exactly once |
| **Listener ↔ connections** | `loopex_daemon` | Foreign peer, malformed frame, over-long path, backpressure | Filesystem permission verified after bind, then the per-platform peer-credential read (`LOCAL_PEERCRED` / `SO_PEERCRED`), then ADR 0023's framing refusals; backpressure at the 4 MiB output buffer | Closed before initialize for a peer refusal; a stable framing reason otherwise; detachment at the last emitted cursor under backpressure | **Not durable:** connections, buffers, windows |
| **Registry ↔ sender ↔ custody** | The **host** owns the registry, custody and the tracing capability; the adapter owns the sender. The token is bound at composition, resolved per invocation | No registry row, registry dead, custody dead, refusal, malformed reply, deadline, or a trace exclusion that cannot be confirmed | `route(handle, token)` answers `:unavailable`; resolution fails as one of the six atoms produced below the guardian (`:no_token`, `:invalid_token`, `:missing`, `:expired`, `:oversized`, `:unavailable`); the **guardian** enforces the deadline, kills the sender and reports the seventh, `:timeout` | The adapter's existing `Loopex.Model` refusal shape, with the atom in the bounded diagnostic | **Not durable:** nothing about credentials is ever journaled, and no span or record carries model `options` — the model span is a fixed identity map. The invocation's failure is durable |
| **CLI ↔ socket** | `loopex_cli` | Socket unreachable, refusal, transport loss, renewal failure | The client's own reconnect loop and its renewal timer | Reconnect at the retained cursor, deduplicating; a failed renewal drops to observer with the loss on `stderr`; a reconnecting controller must acquire again for a fresh epoch | **Durable:** nothing the client holds. The cursor is a client-side position |
| **Daemon ↔ OS: signals** | The operator | `SIGTERM`, delivered to the handler the daemon installs before it takes the marker; a terminal `SIGINT` reaches it only as the `SIGTERM` the launcher forwards, since `:os.set_signal/2` refuses `:sigint` | The owner drains through core's `quiesce/1` within the derived drain budget, tells clients, closes the listener while **leaving the socket pathname for the next verified marker holder**, and then stops its linked processes in reverse order — lease owners, the relay, runtime, edges, and the Store last in its own fixed 30 s phase — each stop driven by a monitored helper calling `GenServer.stop/3` while the owner waits on its own link until the shared teardown deadline and kills on expiry. Classification is from the observed exit reason alone: `:normal`, `:shutdown` and the owner's own `:killed` are consumed, everything else is classified | `daemon.stopping` with `operator_stop`, then close | **Durable:** whatever committed. **Not:** work ended crash-equivalently — a claim about the journal, not about every process being gone |
| **Daemon ↔ OS: kill** | The operator | `SIGKILL`, power loss | Nothing runs — no handler, no `terminate/2` | The socket closes with no record at all | **Durable:** the journal. The marker is left for the next daemon's verified stale-writer recovery |
| **Daemon ↔ OS: socket file** | `loopex_daemon` | A stale `daemon.sock` left by any exit path | Only a daemon that has acquired and verified the marker removes it, at startup, before binding; no daemon removes one on its way out, so no predecessor can delete a successor's socket | The loser of two simultaneous starts exits without touching the socket; a client meeting a stale path is refused rather than hung | **Not durable:** the socket file is a path, never state |
| **Daemon ↔ OS: marker** | `loopex_store_local` | Released in order, released early, or left behind | Four dispositions, and the plan states all four: `terminate/2` in an orderly stop; `terminate/2` early, before the daemon can act, on store loss; `terminate/2` on a **fatal class where the Store is still alive**, because the fail-stop path stops it before halting; and **nothing** on a `SIGKILL`, a power loss, or a Store stop that timed out and was killed | The client sees only the `daemon.stopping` reason; the marker is invisible to it | **Not durable in the journal sense:** the marker is exclusion, not truth. A surviving marker is the case ADR 0031's recovery rule answers |

Three rows deserve their reading stated, because they are where earlier drafts
went wrong. The **coordinator death** row is the one that forced `residency`
to mean a daemon fact: there is no observer column entry available, so any
design that needed one was unimplementable. The **Store ↔ daemon** row is the
one that forced the fail-stop split — the marker is already released by the
time anything can act, so an ordered shutdown ending "stop the Store" had
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
concurrent-attachment change with two halves** — supersession stops removing
an attachment *unconditionally*, becoming conditional on ADR 0023's existing
`replace` flag and scoped to the attaching process's own prior attachment, and
the dispatcher monitors the attaching process, keeps that monitor and the
attacher pid **on the installed attachment**, and removes
on its `DOWN`, releasing that attachment's transfers — because the first half
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
which is a race. **One bounded `quiesce/1`, and the one coordinator change it needs** — the
admit-and-pause split and the non-retrying drained commit, which are two
halves of one clause rather than two changes, and neither of which is
reachable from outside a drain. It unifies nothing today and says so:
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
output buffer, one session index with bounded pages, three CLI commands and
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

**The numbers M5 commits to.** Every one comes from an accepted or proposed
decision named above, or from a constant in the code it bounds, named with its
line; M5 introduces none of its own.

| Ceiling | Value | Source |
| --- | --- | --- |
| Log capacity per state root | 256 MiB; an append past it refused as `store_capacity_exceeded`, which terminates the store and closes the daemon, a log already past it refused at open as `store_log_too_large` | ADR 0031 |
| Frame ceiling on any single store record | 4 MiB | ADR 0031 |
| Retention and replay | Full history, no compaction, full replay at open | ADR 0031 |
| Concurrent connections per daemon | 512, the attachment number reused; the 513th is refused `capacity_exceeded` at `initialize` and closed | ADR 0032 |
| Time an accepted connection may take to complete `initialize` | 30 s, advertised under its own limits key `initialize_deadline_ms`, after which the connection is closed with no record; without it the connection ceiling would bound nothing | ADR 0032, its value derived from ADR 0033's lease term rather than chosen, and carried as a separate key so neither contract moves the other |
| Attachments per session | 64 | ADR 0032 |
| Attachments per daemon | 512 | ADR 0032, its attachment-lifecycle list, with the limit key in its limits table |
| Core event-count queue per attachment | 1,024 events | ADR 0032 |
| Daemon socket output buffer per connection | 4 MiB encoded | ADR 0032 |
| Resident window per session | 4,096 events and 16 MiB encoded | ADR 0032 |
| Aggregate retained encoded events per daemon | 512 MiB | ADR 0032, its queue-ownership and attachment-lifecycle sections |
| Concurrent lease owners | 512, the attachment number reused rather than a second limit; the refusal is `control_capacity_reached` | ADR 0032, where that refusal is defined |
| Idle time before an attachment is evicted and its window and buffer released | 10 minutes; it never stops a coordinator | ADR 0032 |
| Sessions activated per daemon lifetime | 64; the 65th activation refused, the remedy being to restart the daemon. It is per lifetime rather than concurrent because nothing deactivates a coordinator, which is recorded as a limitation | ADR 0032 |
| Recorded session index entries per root | 4,096; a root whose directory holds more refused at daemon start. The ceiling is on recorded entries and never on reachability: a session reached by ID beyond it is activated and not recorded, and the listing carries `index_full` | ADR 0032 |
| `session.list` page | at most 256 entries, `limit` in 1 to 256 | ADR 0032 |
| Socket path bound, over `<root>/daemon/daemon.sock` | the platform's usable `sun_path`, one byte less than the structure because of the terminator: at most 103 bytes on Darwin and 107 on Linux, derived and tested per platform rather than assumed, refused at start as `socket_path_too_long` | ADR 0032 |
| Protocol frame ceiling on the wire | unchanged from ADR 0023 | ADR 0032 |
| Cleanup grace | an integer of 1 or more, refusing `0` with `cleanup_grace_invalid`, because core's `cancellation_bounds/1` admits `grace_ms >= 1` (`apps/loopex/lib/loopex/executor.ex:456`) | This plan, against core's existing validation |
| Phase 1a, closing admissions | **5_000 ms**, the teardown number reused; it bounds the relay's answer to a state change, not any work, and an unanswered close becomes the `relay_lost` fail-stop | This plan |
| Phase 1b, settling the admitted | **300 s** — ten sequential Store calls, a fresh `session.create` being the deepest ticket kind whose depth is a constant; the stop **proceeds** at this bound rather than waiting further | This plan, counted from a **traced run** of that path: `control.ex:959-965`, `:896-897`, `:1679-1684` and `session_coordinator.ex:1302-1309`, `:1338`, `:1363`, `:1397-1400`, `:1407`, `:7090-7114` |
| Phase 2, abort admission | a fixed **150 s** — five sequential Store calls at the adapter's own 30 s `@call_timeout`: the four of the deepest callback a **ready** coordinator may be running, which is **two** commits each re-presented once, and then the drain's own admission, which does not retry; one phase for every session, because they are admitted concurrently. It rests on two claims — quiesce admits only into an `:active` entry, so the acquisition callback is never what an admission waits behind, and no ready callback reaches `commit_internal_result/2` more than twice | Core, against `apps/loopex_store_local/lib/loopex/store/local.ex:65`, `:111-113` and `session_coordinator.ex:146-149`, `:1752-1768`, `:5045-5068`, `:5396-5400`, `control.ex:575-591` |
| Phase 3, the drain budget | `max` over drained sessions of `cancellation_bounds(g_i).cli_backstop_ms`, returned as `budget_ms` | Derived from `apps/loopex/lib/loopex/executor.ex:456-474`; no number chosen |
| Phase 4, coordinator termination | **5_000 ms**, the coordinator's own `shutdown` value (`apps/loopex/lib/loopex/runtime/session_coordinator.ex:134-142`), concurrent across **every** enumerated coordinator; it runs **before** the fence, so the fence races no live **writer** — at most the one transaction the serial lane may already have delivered, which its stale handling covers | Core's existing child specification |
| Phase 5, the fence | a fixed **90 s** — three sequential Store calls at 30 s: the head read, the `advance_owner`, and at most one `transaction_status` query; concurrent across sessions, and no retries | Core, against `local.ex:65`, `:111-113`, `:116-122`, `:130-132` |
| Phase 6, non-Store teardown | **5_000 ms**, one absolute deadline from the instant `quiesce/1` returns, covering the stop records, the connection and listener closes, the collective lease-owner sweep, **the runtime tree's stop** and every other non-Store stop | This plan. Chosen, not derived. A ceiling for the work the phase performs rather than a promise about the runtime's subtree: an `OwnerGroup` traps exits and carries `shutdown: :infinity` (`owner_group.ex:14-19`, `:50`, `:86-90`), so the runtime stop is attempted with what remains and killed at the bound |
| Phase 7, the Store stop | a fixed 30 s, the Store's own `@call_timeout` (`apps/loopex_store_local/lib/loopex/store/local.ex:65`), independent of any grace; the usual release takes milliseconds | This plan, against the Store's existing bound |
| Maximum fail-stop exit | **35 s** — 5 s for the executor stop and the Store's own fixed 30 s, the only two steps of that path that wait; 5 s on the two store classes, where the Store is already gone | This plan, as the sum of its parts |
| Maximum graceful stop | `budget_ms` + **585 s**, the sum of the seven fixed phases above — eight phases, of which only the drain budget is derived; a worst case built from the adapter's wedged-filesystem ceiling, not the cost of an ordinary stop | This plan, as the sum of its parts |
| Wait slice | 60_000 ms, so no `receive … after` argument approaches the BEAM's 2^32-1 limit, probed at both pairs | This plan; the limit is the VM's |
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
concurrent *lease owners*, and at most 512 concurrent *connections* — the last
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
