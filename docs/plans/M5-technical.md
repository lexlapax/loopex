<a id="technical-depth"></a>
## Technical depth

Concept: [Durable service purpose and outcomes](M5.md#concept).

<a id="technical-plan-prerequisites"></a>
### Prerequisites and Acceptance Points

Concept: [Scope](M5.md#concept-plan-scope).

Concept: [Non-goals](M5.md#concept-plan-non-goals).

M5 waits on four decisions. Each is accepted before the implementation that
depends on it, not before unrelated work, and none may be outstanding at
closure. The repository status check reads the links in this section, so a
decision named only in prose declares nothing.

| Decision | Acceptance point | What its acceptance settles |
| --- | --- | --- |
| [ADR 0031](../adr/0031-daemon-grade-store-selection-and-migration.md#concept) | Before the daemon opens a state root, so before workstream 2 lands | The existing local adapter as the daemon's store for `0.2.0`, with the 256 MiB log capacity, 4 MiB frame ceiling, full retention, `store_capacity_exceeded` refusal, the capacity-as-store-loss consequence, explicit stale-writer recovery and the operator root-retirement procedure documented; a daemon-grade adapter and any migration left open for a separate decision |
| [ADR 0032](../adr/0032-daemon-attachment-residency-and-replay.md#concept) | Before the socket is bound or either core change lands, so before workstreams 1 and 3 | The Unix-domain-socket transport reusing ADR 0023 unchanged, generation 2's methods, durable existence established by core's read-only query rather than by attaching or resuming, refusal of a generation-1-only client, owner-only peer access, the bounded socket path, marker-first startup, race-free attach with at-least-once contiguous delivery, the resident window, daemon-owned output buffers, detachment at the last emitted cursor, idle eviction and bounded session pages, and every residency number below |
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
| `loopex` | Durable session truth, the race-free attach barrier and cursor, independent concurrent attachments to one session, the read-only session-existence query, **`Loopex.Trace`'s excluded-MFA list, which keeps a named function out of a trace session before any message is delivered**, **the bounded `quiesce/2` that settles every active coordinator or names what it could not**, the per-attachment event-count dispatcher queues, cancellation and recovery | A lease, a transport, a byte limit, residency policy or any daemon fact |
| `loopex_protocol` | Generation-2 records, validators, schema and vectors | Daemon behaviour or lease semantics |
| `loopex_store_local` | The unchanged local adapter, its 256 MiB log and 4 MiB frame ceilings, its `store_capacity_exceeded` and `store_log_too_large` refusals and its writer marker, which it takes at start and releases in its own `terminate/2` — so the daemon owns the Store *process* and stops it last in an orderly shutdown, and a store loss releases the marker before the daemon can act | Any daemon fact, lease, index or residency state |
| `loopex_daemon` | Marker-first process and socket lifetime, existence validation by calling core's query rather than by attaching or resuming, the peer-credential check, generation-2 negotiation, per-connection socket output buffers, the resident window and aggregate byte ceiling, attachment residency and eviction, the in-memory controller lease and writer-epoch check, the session index with its recorded-entry bound and its bounded pages, attachment residency and the one-way activation ceiling, and diagnostics | Store or coordinator internals, a second loop, policy selection, host identity, a durable record or a durable method |
| `loopex_composition` | The edge-assembly sequence, and the one new public function that runs it in the caller's process and returns the edges — used by `RuntimeOwner` and by the daemon's owner | Daemon lifetime, ownership of what it assembles, or any knowledge of a daemon |
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
in the daemon's memory, keyed by session, for the daemon process's lifetime; one
owner process per session serializes its lease transitions with its admission
handoff, and that owner's failure is fatal to the daemon instance rather than
survivable — it holds the session's in-flight admission set, which a takeover
waits on, so a restart beneath live sockets could grant a successor while a
forgotten admission could still settle. ADR 0033 fixes the rule; the daemon
restarts with no lease, no connection and no activated session. For
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
| 1 | `apps/loopex_daemon/test/session_lifetime_test.exs` | A real daemon operating-system process per state root. The startup ordering and its readiness line: the line appears on `stdout` only after the marker is held and the socket is bound, permission-checked and accepting, a client connecting the instant it appears is served, and each of a held marker elsewhere, a failed socket permission check and an exceeded index bound prints no readiness line and exits non-zero with its own class. Orderly shutdown on `SIGTERM` sent to the daemon, and on `SIGINT` sent to the launcher that forwards it as `SIGTERM`: new connections refused and new admissions refused from that instant, then core's `quiesce/2` driving every active coordinator to settle within the composed cleanup grace and naming the sessions that did and did not — **both halves asserted**: a dispatched tool effect that settles inside the grace carries its ordinary terminal fact in the journal, and one held past the deadline is ended crash-equivalently with **no terminal claimed for it** — no `cancelled`, no `outcome_unknown`, no abort record — its ambiguous mutation left as `commit_unknown` and resolved to exactly one outcome when that session is next activated, one bounded best-effort `daemon.stopping` naming `operator_stop` attempted per open connection — asserted received where the transport accepts it and an EOF alone accepted where it does not — the socket unlinked while the marker is still held, the Store stopped last, and exit `0` — with the foreground server opening the same root immediately afterwards, which is what proves the marker was released, and the journal byte-identical to what an abrupt death at the same instant would have left. **Store loss is a separate fail-stop, not that sequence**: the Store terminates itself and releases the marker before the daemon can act, so the daemon observes the death, refuses service, closes every connection with `store_lost` (or `store_capacity_exceeded` where that was the reason), unlinks and exits non-zero with that class on `stderr`, attempting no Store stop because there is none to attempt — proved by a second daemon starting on that root with no stale marker to recover. An active session progresses with zero attachments. An orderly stop releases the writer marker and records nothing false; an abrupt kill followed by restart activates nothing, then activates each session the root records when a client reaches for it, under the same placement identity and with no duplicate effect. The restart proves the marker path explicitly: the daemon opens with `recover_stale_writer: true`, a marker whose holder is proved dead is reclaimed, a marker whose holder is alive refuses with `store_writer_active`, and a marker whose holder cannot be decided refuses with `store_writer_unverifiable` — all three before the socket path is read, unlinked or bound. Simultaneous starts on one root resolve at the writer marker with exactly one listener and the loser never touching the socket. A root driven to the 256 MiB log capacity refuses the append with `store_capacity_exceeded`, the store terminates, the caller sees `commit_unknown`, and the daemon closes the listener and every connection and exits naming the capacity with nothing committed lost; a root whose log is already past that bound is refused at open with `store_log_too_large` rather than opened and truncated. `session.list` returns pages of at most 256 entries in session-ID order with an exact continuation cursor from the daemon index, carrying only session identity, recorded placement identity, `residency` and `controlled`. A session committed to the Store whose directory entry was never written — injected at that exact cut — is absent from the listing, still reachable by ID, and present in every listing after the activation that records it. A detached long-running command and a pending admission each cross the idle deadline with every client gone and run to completion, proving dormancy releases attachments and never a coordinator. The activation ceiling refuses the 65th activation of a daemon lifetime with `activation_ceiling_reached` and the restart remedy, and the count starts again after a restart because it counts per lifetime; a fresh `session.create` raises the count by one, and at the ceiling a create is refused with that same reason, so creation is proved to spend an activation rather than being exempt from the bound; attach consults the activation set rather than the listing index, proved at the 4,096-entry ceiling where a session activated but deliberately unrecorded still attaches; killing an activated session's coordinator leaves the daemon serving: the listing still reports `residency: active`, which remains true because this daemon did activate that session, and the next command for it returns core's own refusal forwarded unchanged, with the daemon adding and interpreting nothing; a root whose directory exceeds the recorded-entry bound refuses at start; at that bound a session reached by ID is activated and not recorded and the listing carries `index_full`; a session committed to the Store whose directory entry was never written is recovered both by its ID — validated through core's read-only existence query, with the case asserting the validation itself created no attachment and no durable record — and, by a client that never saw the ID, through ADR 0032's full command-identity sequence run to the end — replay `session.create` with the original `command_id`, core returns the historical result and so the session ID **without starting a coordinator**, the existence query answers `present`, the daemon repairs the directory entry and index row, control is acquired, and `session.resume` with a fresh resume command ID under the granted writer epoch is what activates the session — with the case asserting exactly one session in the root, the returned ID equal to the committed one, the replay itself starting no coordinator, the directory entry and index row present afterwards, the session listed, a live coordinator existing after the resume with the activation count risen by one, and a later prompt landing on that session and producing its events rather than on a second session or on nothing; an unknown ID answers negative from that query with nothing created, nothing attached and no lease granted; a directory write that fails during activation is reported to that client, leaves the session usable and reachable by ID while absent from `session.list`, and is written by the retry the next time the live daemon holds that ID — right after activation, on a later command for the session, or when a client reaches it by ID; a recorded session the daemon's composition cannot serve refuses at activation by name while every other session in the root activates. After an orderly stop the foreground server and the reference CLI reopen the same root and resume a daemon-created session under the same placement identity with identical replay. No durable method reaches the socket |
| 2 | `apps/loopex_daemon/test/socket_transport_test.exs`, `apps/loopex_protocol/test/public_schema_conformance_test.exs` | A raw-byte client over the socket negotiates generation 2 and receives generation 2's **own** exact schema digest, written out as a literal in the conformance module beside generation 1's and different from it by construction: `LoopexProtocol.Session.schema_digest/0` is taken over the generation, the ordered methods, the ordered record families, the ordered error codes and the limits, and generation 2 changes the first two, so a generation 2 that negotiated generation 1's digest would be reporting a contract it does not serve. Generation 1's bytes, digest, method inventory and limits are proved unchanged in the same module and at their own literals — the `3a17…08f4` schema digest, the schema file digest and the vectors file digest the conformance module already pins — so the generation-2 work is proved additive rather than asserted to be. A generation-1-only initialize is refused with nothing created. Generation 2's record families include `daemon.stopping`, with literal vectors for each reason a **client can actually receive** — `operator_stop`, `store_lost`, `store_capacity_exceeded`, and one `fatal:<class>` per linked component of the fixed set (`runtime_lost`, `transfers_lost`, `workspace_lease_lost`, `executor_lost`, `registry_lost`, `custody_lost`, `listener_lost`), plus `control_owner_lost`, which closes one session's controller attachment without ending the daemon — and explicitly none for the startup-phase classes, which carry no vector because no socket exists when they occur and no client can be holding one, and its presence in the digest is what a generation 2 omitting it would fail on. Its delivery bound is proved both ways: a reading client receives the record before the close, and a client that has stopped reading until its 4 MiB output buffer is full receives nothing and is closed anyway, with the daemon making exactly one attempt and never blocking on it. Identical durable identities for the same command corpus through facade, foreground server and socket. Owner-only peer access proved in both layers: the socket's `0700` daemon-owned subdirectory and `0600` socket mode read back after bind, a permissive subdirectory or socket mode refused at start, a subdirectory the daemon does not own refused, a path component below the root that it did not create refused — and a state root at the ordinary `0755` the foreground server creates it with accepted, not refused, because the daemon owns the subdirectory and never re-permissions the root — and an unreadable or undecodable peer credential closing the connection before initialize — all in the fast check, which needs no second user — with the real cross-uid refusal and the same-uid success carried by two `@tag :cross_uid` cases the release check runs as `mix test --only cross_uid` on its single run, which closure requires to be on Linux, and where the script asserts exactly two executed tests so neither a zero nor a lone survivor can pass. Frame, fragment, malformed-input and over-long socket path refusals with distinct stable reasons, the path cases binding at the derived bound and at one byte past it on each platform the release check runs. A client disconnect recorded as transport loss with no cancellation and no interaction change. The generation-2 vectors are literal bytes with literal verdicts, held beside generation 1's in `apps/loopex_protocol/test/public_schema_conformance_test.exs`, never values generated from the implementation they check |
| 3 | `apps/loopex_daemon/test/collaboration_test.exs` | One lease per session in daemon memory with observers attached. Connection identity, epoch, held state and unexpired term checked together before core admission or any durable write, including a known current epoch sent by an observer. Takeover only after release or expiry, with a fresh epoch minted before the successor's first command. A killed controller fenced and its late commands refused. The three ways a controller stops holding, proved separately because the transport cannot tell two of them apart: an explicit `session.release_control` frees the lease at once, while an EOF from a politely closed client and a killed client both wait for expiry, with a takeover refused before the deadline and granted after. A lease owner killed while a mutation is in flight taking the listener, every connection and the daemon down with it, after which the restarted daemon holds no lease and the previous holder's delayed command is refused on both the holder and the epoch check. A daemon restart leaving every session uncontrolled with every earlier epoch refused. A controller abort cancelling work dispatched under an earlier process with a truthful cleanup outcome. The expiry linearization: a mutation blocked inside core across the deadline settles under its own lease while the eligible takeover waits and is granted only after it resolves; the holder's next mutation refused at the deadline; the acquiring request refusing with `control_pending` when its own deadline elapses first; and the holder disconnecting while a mutation is in flight — in every case exactly one of settle or refuse, never both. No control from content, metadata, answers or attachment order. Forward and backward wall-clock jumps changing neither live admission nor takeover timing |
| 4 | `apps/loopex/test/concurrent_attachments_test.exs`, `apps/loopex/test/session_existence_query_test.exs`, `apps/loopex_daemon/test/replay_residency_test.exs` | Core's read-only session-existence query answers exactly one of the closed set `present`, `absent`, `invalid_id`, `store_unavailable` and `unexpected`, from a fresh process against a real root, with one case per result. `store_unavailable` is injected through the controllable fault store the suite already has, `Loopex.M1RuntimeTestStore`, whose `fail_reads/2` hook makes its reads refuse — not by making the root unreadable, which cannot produce that answer on the real adapter: `Loopex.Store.Local` answers `ownership_head` from `state.store`, in memory, so a root that has become unreadable on disk still answers. `unexpected` is injected by a stub answering outside the set. It is proved to create no attachment, no incarnation, no durable record and no Store write: the root's journal and session directory are byte-identical before and after a run of queries, including for unknown and malformed IDs. Control acquisition proceeds only on `present`; the other four fail closed with no attachment, no lease and no activation, and name four distinct reasons, so an unreadable store is never reported as an unknown session. Several core attachments to one session remain independent when one detaches or backpressures. A snapshot anchored at the committed sequence, then contiguous at-least-once buffered and live delivery across the window boundary with no gap. Core is the only replay owner: every delivery case runs a second time with the daemon's resident window disabled and a third with it dropped mid-stream, all three byte for byte identical, so the window is proved to establish no snapshot and no cursor. Aggregate reclamation follows the fixed order ADR 0032 sets — zero-attachment windows by ascending last delivery, then the furthest-behind session's window, then detachment — including the case where zero-attachment windows alone consume the ceiling. A slow observer detached at its last emitted cursor while the controller and the other attachments continue. Per-session and per-daemon limits refusing independently. Idle eviction and reconnect with no missing durable event, any duplicate deduplicated by session ID, sequence and event ID. Retained encoded bytes at or below the 4 MiB output buffer, 16 MiB window and 512 MiB aggregate ceilings, enforced in the daemon-owned stages, exercising 512 attachments and maximum-sized output records separately, with observed process RSS recorded beside the ceilings. Progress coalesced or dropped with counted drops and no journal delay |
| 5 | `apps/loopex_daemon/test/multi_client_workflow_test.exs`, `apps/loopex_daemon/test/external_socket_workflow_test.exs`, `docs/evidence/M5-closure-runs.md` | The operator workflow end to end, each step a command an operator types: `loopex daemon` refusing once per missing or invalid composition input with its own class and leaving no marker or socket behind, then starting and printing the one-line JSON readiness record; `loopex run --daemon` creating and driving a session; `loopex resume --daemon` activating a dormant one through acquire, resume with a fresh command ID, attach; `loopex attach` refused with `session_dormant` at the **attach** step against a session this daemon has not activated, in both roles, while `loopex resume --daemon` acquires that same dormant session and succeeds — the two asserted together, since refusing dormancy at acquisition would break the resume path; `--take-over` on a dormant session asserted to release its lease before exiting, proved by `loopex resume --daemon` succeeding immediately afterwards rather than refusing `control_held`; a CLI holding a lease attempting an explicit release on every exit path where its transport is still writable, and the killed-client case asserted to differ — no release, the lease waiting out its term, which is what ADR 0033 already fixes; `--after` starting strictly after a sequence and its absence replaying from `0`; a controller whose renewal fails continuing as an observer and sending no further mutation; a reconnecting controller retrying acquisition with backoff until its own lease can have expired and then holding a fresh lease with a fresh epoch before any mutation, and the variant where another client took over meanwhile exiting `control_held` rather than retrying against a live holder. From a fresh extraction of the exact candidate — staged with `git archive`, extracted and built outside the checkout — an operator follows the documented prerequisites and commands, supplies workspace, provider and policy inputs, starts the daemon, and drives one session from the reference CLI as controller and the Node client as observer, kills the controller, takes over from the observer and aborts cross-process work. The documented CLI build and the provider companion build both run inside that extraction, on the archive-carried source identity rather than on `.git`, with the missing, unsubstituted-or-malformed, changed-during-build and mismatched-commit refusals each proved and the identity the build reports asserted equal to the commit the archive was staged from. The attended real-provider cases run from that extraction, against the escript it built there. The workflow drives ADR 0030's existing core spans end to end — command admission, commit, effect intent, publication, interaction, and the model, store, policy and executor port callbacks — with the same bounded identity metadata an embedded caller produces, and no event outside that closed inventory is emitted by anything M5 adds. Daemon-internal functions are proved by the daemon's own tests and logs: `Loopex.Trace` traces only processes the runtime owns, flagged with `set_on_spawn` from the runtime's supervisor, and the daemon's listener, connections and lease owners are host processes above the runtime, so no trace-session witness is claimed for them. `VERSION` in the extracted tree is exactly `0.2.0`. Every tracked file under `docs/operator/` and `docs/developer/` has been read against the candidate, including the ones M5 leaves unchanged, recorded as a checklist derived at that commit — `git ls-files -- docs/operator docs/developer`, sorted, one row per path, each row marked *updated* or *reviewed unchanged* — retained with the closure runs. The derivation is over **every tracked file** in those two trees, not only Markdown, and that is deliberate: the gate promises that every file under them was read, so a diagram, a fixture or a data file added later must appear rather than slip through a `*.md` filter that was true when it was written and silently false afterwards. It also avoids a pathspec trap, checked rather than assumed: `git ls-files 'docs/operator/**/*.md'` without `:(glob)` matches nothing at all and would have made the gate pass vacuously. The directory form returns 26 tracked files as of this revision — 18 under `docs/developer/` and 8 under `docs/operator/`, all Markdown today — and the closure checklist states the count it derived so a reviewer can see the list was not empty, with every path in the tree present, no row unmarked, and each finding named and resolved before the closure packet |
| 6 | `apps/loopex_llm_reqllm/test/credential_plane_test.exs`, `apps/loopex_llm_reqllm/test/adapter_test.exs`, `apps/loopex_llm_reqllm/test/provider_retainer_boundaries_test.exs`, `docs/evidence/M5-closure-runs.md` | From the completion of a reference host's composition onward, the parent VM's environment holds no credential under the adapter's name and no value equal to the credential in use, before, during or after a call — "during" observed from inside the call at child readiness; composition is proved to read the operator's variable once and delete it. Every row of ADR 0034's failure table resolves to its closed-set atom and retains no copy: `:no_token` for an absent token, `:invalid_token` for a malformed one, `:unavailable` for a token with no registry row, a gone registry, a dead custody process and a malformed successful reply, and each of `:missing`, `:expired` and `:oversized`, a term outside the closed set reported as `:unavailable`, and a custody process blocking past the invocation deadline, where the **guardian** kills the sender and reports `:timeout`, asserted distinct from every refusal so the guardian can tell a refusal from a silence and asserted to bound the invocation whatever the custody process does. Two resolutions in flight at once is a success case, not a refusal: both invocations complete with their own credentials. Tracing is proved in three tiers, against `Loopex.Trace` including the excluded-MFA list M5 adds to it: under the **default** configuration no trace entry names `ProviderBridge.route_credential/2`, `receive_custody_reply/2` or `write_credential_frame/2`, the tracer receives no raw trace message for them and no credential bytes or token appear in any entry — because `modules/1` expands a namespace through the application's own module list and the adapter is not a `:loopex` module; under a configuration that **explicitly names** `Loopex.LLM.ReqLLM.ProviderBridge` and `Loopex.LLM.ReqLLM.ProviderCodec`, the tracer is asserted to receive **no raw trace message at all** for any excluded identity — read from the tracer process, which is where a pre-delivery claim is decidable — while a non-excluded function of the same module is asserted to produce one, so the case cannot pass by tracing nothing; and the keyed-shape tier, defence in depth if an exclusion were ever lost, calls each of the three bridge functions with a **one-byte** credential and asserts no captured entry contains that byte. The shape tier matters because size alone does not protect: running `Entry.render/2` shows a bare or tuple-wrapped credential of 1, 40, 51 or 64 bytes rendered verbatim, and only a credential-keyed value placeholdered at every size. A fourth case asserts the three identities, so no tier can pass vacuously. The exclusion mechanism itself is proved in core's own suite: a module pattern installed and one `{module, function, arity}` cleared after it, with the tracer receiving the non-excluded call and nothing for the excluded one, at both toolchain pairs The registry lookup is proved to carry no credential. Two runtimes composed in one VM, each with its own registry, custody and token, are proved isolated: a token minted for one answers `:unavailable` in the other, so tokens do not cross runtimes, and neither runtime's child — nor either child's diagnostics — ever observes the other's credential. That case subsumes the old within-one-runtime concurrency witness, which a composition-bound token makes meaningless: two invocations of one runtime necessarily carry the same token, so what has to be proved independent is two *runtimes*. A registry killed under a composed runtime makes every later resolution through that handle answer `:unavailable`, and the adapter is proved not to retry, wait or rebuild — recomposition is the only repair. Every re-pointed case of `apps/loopex_llm_reqllm/test/credential_plane_test.exs` passes with its assertion unchanged in meaning: version refusal and bootstrap refusal before any credential, late delivery after expiry impossible, rotation between invocations, two live credentials in one VM, sink loss, one child's loss not poisoning another, ordinary host messages and returned reasons, every child Logger form and metadata, and the four crash-report cases. The child-environment witness inside the version-refusal and bootstrap-refusal cases — the child's recorded `entry-env` marker refuting `Adapter.credential_variable()` — holds unchanged. The 65,536-byte ceiling case in `provider_retainer_boundaries_test.exs` is re-pointed too, because that module delivers its credential through `System.put_env` in its `setup` and again in the case body; that invocation's own custody process holds the oversized value instead. The drift-protection case in `adapter_test.exs` survives strengthened, with an exact allowlist: `[]` for `provider_bridge.ex`, the arity-zero enumeration and only that for `provider_launcher.ex` because it is ADR 0019's first-image scrubbing rather than a credential read, `provider_worker.ex`'s two non-secret crash-dump names, and `[]` everywhere else. Because the launcher's read survives, the case also asserts its *use*: the enumeration's result flows only into the Port's removal list, every name is mapped to `false`, none is compared against `credential_variable/0`, and no value reaches the sender, the frame or any caller. Its scan is widened from one `System.get_env(...)` expression to every route an environment read can be written — `System.get_env/0`, `/1` and `/2`, `System.fetch_env/1` and `fetch_env!/1`, `:os.getenv/0`, `/1` and `/2`, `:os.env/0`, and indirect application through `apply/3` or a captured function — each unpinned route refuted outright. The `req_llm` move to `~> 1.24.0` — pinned to that minor, not to `~> 1.24`, so the reviewed diff is the version actually built against — lands as its own reviewed change before the credential change, with the reviewed changelog diff across the intervening releases named in the commit, the adapter and streaming-conformance suites green, and the *existing* real-provider case at closure run against it. It adds no call path: nothing in M5 calls anything `1.24.0` makes newly reachable, and no second provider, second credential or new release-check case enters this milestone. It is explicit M5 scope, separate from ADR 0035 and not conditional on it. A security review by someone other than the implementer is recorded. The twelve modules are then converted to run concurrently one at a time, each kept only while its application's suite stays green, any module that stays serial keeping its reason beside it, and the measured duration is recorded beside the M4-closure baseline as evidence about the change rather than a threshold |

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

They are excluded from an ordinary run at the source, on the app-server's
precedent: `apps/loopex_daemon/test/test_helper.exs` ends
`ExUnit.start(exclude: [:cross_uid])`, exactly as
`apps/loopex_app_server/test/test_helper.exs` excludes `:node_client` and
`:real_provider` so an ordinary `mix test` needs neither Node nor a
credential. The fast check therefore never runs these two, and they run only
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
  which is what lets any lane assert a count at all; and
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
provider configuration. Every other tracked file under `docs/operator/` and
`docs/developer/` is read at the candidate and left unchanged only
deliberately, and the derived checklist in Outcome 5's evidence row is what
makes that auditable rather than asserted.

**Test honesty.** Future test bodies are written with their implementation; a
missing witness is never a pass. Real-provider cases live in their own files
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
`writer_epoch`. Saying "records reused unchanged" without that exception would
be wrong in the one place a reader checks it, at the schema digest, which is
precisely why generation 2 needs its own. Generation 2 is additive
over generation 1's method set under the exact-generation rule: a generation-1
client sees no daemon method and no lease field, the daemon refuses a
generation-1-only initialize, and the foreground server keeps serving
generation 1 unchanged. No mixed-generation stream is promised. The private
journal, its adapter and its format are unchanged; the embedded API, public
events, snapshots, artifact formats and the executor protocol are unchanged.
Source `VERSION` is distinct from protocol generation, provider build and
schema digest.

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
  checkout and which the resolver proves here by a SHA-256 over the extracted
  tracked source paths, sorted, taken before the build and again after and
  required equal;
- the provider build manifest embeds the resolved commit id together with that
  source digest, so an identity naming a commit whose tree is not what was
  built is detectable rather than merely trusted.

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
  daemon incarnation, socket path, attachment, activation and index counts
  against their limits, and uptime.

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
| Cleanup grace | `--cleanup-grace-ms` | the composition default | `cleanup_grace_invalid`, and the admitted domain is **an integer of 1 or more**. Zero is refused, which the local executor's own validation would admit (`apps/loopex_executor_local/lib/executor.ex:897`, `>= 0`) but core's `cancellation_bounds/1` refuses (`apps/loopex/lib/loopex/executor.ex:456`, `grace_ms >= 1`): a daemon composed with zero would carry a grace core cannot derive bounds from |
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
daemon entitled to bind or unlink. An override therefore moves where the rule
applies, never which root it applies within.

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

**Stopping.** **`SIGTERM`** begins the orderly shutdown below — or `SIGINT`
through the launcher, `apps/loopex_cli/bin/loopex`, which forwards it as
`SIGTERM`. The daemon itself installs no `SIGINT` handler and cannot: the
emulator reserves that signal and `:os.set_signal/2` refuses the name, as the
signal section below sets out.
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
  `workspace_lease_lost`, `executor_lost`, `registry_lost`, `custody_lost`
  and `listener_lost`. A lease owner's death is **not** in this list: it is
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
3. **Start the credential routing registry and the custody process.** They are
   the daemon's own, as ADR 0034's host, and they must exist before the model
   configuration that carries the registry handle and the token is built.
4. **Call the composition function**, which opens the Store and acquires the
   writer marker with `recover_stale_writer: true` and the three holder
   outcomes ADR 0032 fixes, then assembles the artifact transfers owner where
   enabled, the workspace lease, the executor and the runtime, and returns
   every pid it linked. A daemon that does not hold the marker fails here and
   never reads, unlinks or binds the socket path.
5. **Read the session directory and build the index**, refusing at the
   recorded-entry bound.
6. **Create the `0700` subdirectory and bind the `0600` socket**, read back
   and verify ownership and mode, and **capture the bound path's device and
   inode** — the identity the fail-stop unlink rule below compares against.
7. **Begin accepting**, then **print the readiness line**.

No lease owner exists at this point, and none is started here: one is started
when a session is activated, which cannot happen before a client connects.

A failure at any step exits non-zero with that step's reason class, after the
reverse cleanup below, and touches nothing after it.

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
  before the daemon has told a single client or unlinked the socket.
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

**It links a fixed set of eight processes — seven without artifact
transfers — and a bounded, dynamic population of lease owners beside them.**
Earlier drafts said four, then seven, each time having counted the components
the daemon *thinks* about rather than the processes that actually exist. The
fixed set is this:

| Start order | Linked process | Where it comes from | Optional? |
| --- | --- | --- | --- |
| 1 | The credential **routing registry** | The daemon's own, as the host ADR 0034 names | no |
| 2 | The credential **custody process** | The daemon's own, as the host ADR 0034 names | no |
| 3 | The Store adapter | `start_edge(Store.Local, …)` | no |
| 4 | The artifact transfers owner | `start_edge(Transfers, …)` | **yes** — only when transfers are enabled |
| 5 | The workspace lease | `start_edge(WorkspaceLease, …)` | no |
| 6 | The local executor | `start_edge(Local, …)` | no |
| 7 | The runtime root | `start_edge(Loopex, …)` | no |
| 8 | The listener | Bound and permission-checked last, so nothing accepts before the rest exists | no |

**Beside them, one lease owner per activated session**, which ADR 0033
requires and the maintainer confirmed on 2026-09-20 in preference to one
process holding a record per session. That population is dynamic, and every
question a dynamic population raises is answered here rather than left to the
implementation:

| Question | Answer |
| --- | --- |
| When does one start? | When the session is **activated in this daemon lifetime** — by `session.create` or by `session.resume` — started and linked by the daemon's owner process, like every other linked process |
| When does one stop? | At daemon exit, and in the stop sequence below. There is no deactivation in M5, so there is no retirement rule to invent |
| How many can exist? | At most **64**, because activation is one-way and the activation ceiling is 64 per daemon lifetime; the 65th activation refuses with `activation_ceiling_reached` before any owner could be started. The population bound is the ceiling, not a second number |
| What does its death mean? | That **session's** collaboration state, not the daemon's — the one exception to fail-stop uniformity, below |

**The registry and the custody process are first, and that is forced rather
than chosen.** ADR 0034 makes the *host* own both, and for a daemon the host
is the daemon. The runtime's model configuration carries the registry handle
and the token in `options`, so both processes must exist before the
composition function builds that configuration — which means before the
runtime starts, and the composition function starts the runtime at the end of
its own chain, so before the composition call itself.

Order 3 to 7 is the composition's actual chain, not a tidied one: the Store
first, then the artifact placement and the executor's own edges, and the
runtime last within that chain, because it depends on all of them.

**The stop order is the reverse, with one deliberate exception.** Reversed:
listener, then **every lease owner**, then runtime, executor, workspace lease,
transfers, custody, registry — and then **the Store, last of all**, out of
reverse order. The lease owners are stopped **in sequence, not concurrently**,
and they share one grace between them rather than each taking one: each stop
is a process with no `terminate/2` and nothing to release, so the sequence
costs no measurable time, while a concurrent stop would need a second wait
rule and a way to attribute a timeout to one of sixty-four pids. Sequence is
the smaller mechanism for the same result. The
Store is moved to the end because its `terminate/2` releases the writer
marker, and the marker must outlive every operation the owner can end;
custody and registry hold nothing durable, so stopping them before it costs
nothing and keeps the one exception to one line. The socket is unlinked
earlier still, for the reason the socket-ownership rule below gives.

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
the fixed eight — seven without transfers — is `start_link`ed by the owner,
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

So the owner carries a `stopping` field naming **the one component it is
currently stopping**, set immediately before each stop call. The EXIT clause
reads:

- an exit from the pid named in `stopping`, while it is named, is **consumed**
  and clears the field — it is the stop the owner asked for, arriving as a
  signal;
- **every other exit is classified exactly as before**, including one from a
  component not yet stopped that dies of its own accord *during* another
  component's stop. A store that fails while the listener is being stopped is
  still `store_lost`, and must be: the daemon is going down either way, but
  the operator is owed the real reason rather than `operator_stop`.

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
   `GenServer.stop(pid, :normal, grace)`. The helper is monitored, never
   linked, so whatever that call raises, exits or returns dies with the helper
   and never reaches the owner. The owner needs nothing from it — not its
   return value, not its `DOWN` — and ignores both.
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

**What bounds each step.** The outer `receive` carries `after grace`, the
composed cleanup grace — one bound per component, the same number everywhere,
and the same number the helper passed to `GenServer.stop/3`, so a component
gets the grace once rather than twice. The inner `receive` after the kill
carries no `after`, and needs none: `Process.exit(pid, :kill)` on a live
process is unconditional, and on one already dead the exit the owner is
waiting for is the one that made it dead, already queued. It is a wait for a
signal that exists, not a second bound.

**Other messages wait their turn.** Both receives are selective on one pid, so
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
  `terminate/2`, `GenServer.stop(executor, :normal, grace)` returns about as
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
would leave the socket unlinked and no client told, so a fifth component
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

**Who may unlink the socket, and when that stops being this daemon.** The
socket path is not the daemon's by possession; it is the daemon's *because it
holds the writer marker*, which is what ADR 0032 already says — only the
marker holder may unlink or bind. The consequence an earlier revision missed
is that the permission **ends when the marker does**, and the marker is
released by the Store's `terminate/2` (`local.ex:166`), which can happen
before the daemon is finished.

Two paths, two rules:

- **Orderly stop: unlink while still holding the marker.** Step 1 does it,
  immediately after the listener stops and long before the Store. No successor
  can have acquired the marker yet, so the path being unlinked is certainly
  this daemon's. Leaving the unlink to the end — where earlier revisions had
  it — meant unlinking after the marker was already released, and a successor
  that acquired it in that window would have had *its* socket removed by a
  daemon on its way out.
- **Fail-stop where the marker is already gone.** On `store_lost` and
  `store_capacity_exceeded` the Store released the marker before the daemon
  could act, so the daemon can no longer assume the path is its own. It
  therefore compares identity rather than presence: at bind it captured the
  path's `File.stat` device and inode, and at unlink it stats the path again.
  **Equal device and inode: unlink. Anything else — a different inode, or
  `{:error, :enoent}` — leave the path alone.** A successor's socket is a
  different inode, which is what makes this decidable; verified by probe: a
  bound path stats as `type: :other` with an inode, and a rebind of the same
  path yields a different inode.

**The residual is the window between the stat and the unlink**, and it is
stated rather than papered over: a successor that acquires the marker, removes
the stale path and binds entirely between our two syscalls would still lose
its socket file. Nothing narrows that further without a second lock, and a
second daemon-owned lock file is rejected — it would duplicate the marker's
stale-writer recovery machinery, including its own staleness question, to
guard a window one syscall pair wide. What is at stake is also bounded: the
socket is a path, never durable truth. A successor that loses its file serves
no client and is restarted; the marker it holds, which is the real exclusion,
is untouched, so nothing can write to the root behind it.

**`--socket` is constrained to the selected root.** An override must resolve
inside that root's `daemon/` directory — the same directory the default path
sits in, under the same owner and symbolic-link rules — and a path outside it
is refused at startup with `invalid_socket_path`, before the marker is
acquired. Without that constraint two daemons on *different* roots could be
pointed at one path, and neither's marker would say anything about the other's
socket: the identity rule above would be comparing inodes between daemons that
have no exclusion between them at all. Inside one root, the marker is the
exclusion and there is exactly one holder.

**How a signal reaches the owner, and when the handler is installed.** The
daemon does not inherit a usable signal disposition; it installs one, and the
order matters more than the mechanism.

`SIGINT` cannot be installed on at all: the emulator reserves it for its break
handler and `:os.set_signal/2` refuses the name outright, which
`LoopexCli.Interrupt` states as a fact about that function rather than about
the command (`interrupt.ex:13-17`). So a terminal `Ctrl-C` reaches a daemon
the only way a reserved signal can — from outside the emulator.
`apps/loopex_cli/bin/loopex` traps `INT TERM HUP QUIT` and forwards
`kill -TERM` to its child (`bin/loopex:51-60`), so **`SIGINT` is a launcher
concern and `SIGTERM` is the escript's**. A daemon started without that
launcher has no `SIGINT` behaviour to specify, and the plan says so rather
than implying one.

For `SIGTERM`, `SIGHUP` and `SIGQUIT` the daemon does what the CLI already
does, and reuses the same mechanism rather than inventing one:
`:os.set_signal(signal, :handle)` (`interrupt.ex:782`), a `:gen_event` handler
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

**The owner-loss backstop.** If the owner is not alive when the signal
arrives — it crashed, or the signal raced its own start — there is nobody to
run the sequence and nothing to wait for. The handler halts with
`fatal:owner_lost` on `stderr` rather than returning and leaving the process
running with a handler and no owner. That class is in the exit list above and
in the fatal-class map's note, and it is the one class no linked component
produces.

**Daemon-initiated shutdown is a drain and then a teardown, in reverse
order.** `SIGTERM` reaches the owner — sent directly, or forwarded by the
launcher from a terminal `SIGINT` — and it performs these six
steps itself. They are the owner's code, not a supervisor's behaviour, which
is what lets each one carry a reason and lets the teardown use a bound the
owner chooses.

1. **The listener stops accepting, and the daemon refuses new admissions.**
   A new connection is refused rather than queued, and a command arriving on
   an open connection is refused from that instant. Nothing is written to
   clients yet and nothing is closed: the connections stay open across the
   drain, because a client that is about to be told something true is better
   served by being told it than by an early close.
2. **The runtime is quiesced within the composed cleanup grace.** The owner
   calls core's `quiesce/2` and waits for its answer, which names the sessions
   that settled and the sessions that did not. This is the drain, and it is
   the step that makes the Concept's promise true rather than aspirational;
   what it does, and what it cannot do, is set out below.
3. **Clients are told, and the socket path is unlinked.** Each open connection
   gets one `daemon.stopping` naming `operator_stop`, bounded best-effort as
   ADR 0032 fixes — one write attempt into the existing 4 MiB output buffer —
   and is closed. **Then the owner unlinks the socket path, here and not at
   the end**, because this is the last moment at which the daemon is certainly
   still the marker holder.
4. **Every lease owner stops**, in sequence, sharing one grace. Every lease
   vanishes with them. Nothing durable is involved, and no client is left
   holding one, because no connection survived step 3. Their exits are
   consumed like any other the owner asks for — a lease owner stopped here
   closes no controller attachment and produces no `control_owner_lost`,
   because there is no attachment left to close.
5. **The runtime stops, and this is where whatever did not settle ends.** The
   helper for this step calls `Supervisor.stop(runtime_supervisor, :normal, grace)`
   on the pid the composition function handed it, with `grace` the **composed
   cleanup grace** — the same value the sessions were composed with, so no
   number is introduced. It does **not** call `Loopex.Runtime.stop/1`: that is
   arity one and uses the default `:infinity` timeout, which is exactly the
   bound this step exists to supply.

   `Supervisor.stop/3` is `GenServer.stop(supervisor, reason, timeout)`
   (supervisor.ex:1152-1154 at the floor pair, :1197-1199 at the current
   pair), so it is the same call the general rule above describes, made in the
   same place — the helper — and its outcome is read the same way, from the
   exit on the owner's link. What `:proc_lib.stop/3` does to *its* caller on
   expiry, whatever shape that takes, is the helper's business and dies with
   it. The owner's `after grace` fires, it kills the runtime supervisor with
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
   terminating the captured process groups. Then custody and the registry,
   which hold nothing durable. Then the Store, whose `terminate/2` releases the writer marker —
   see the marker invariant in ADR 0031. The socket path is already gone,
   unlinked in step 3, so the last act is the halt: **`0`**, or the class,
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
   | The executor | The **composed cleanup grace** | Nothing, in the executor itself: it neither traps exits nor defines `terminate/2`, so this stop returns quickly and the bound is a ceiling. What takes the time is the Port-owning workers it sets going, which the owner does not hold and cannot wait for |
   | The workspace lease | The same grace | Nothing: it has no `terminate/2` and holds no file — the lease *is* the live process, so stopping it revokes it. The bound is a ceiling it will not reach |
   | The transfers owner | The same grace | Closing the open transfer descriptors its `terminate/2` holds (`transfers.ex:146-149`) |
   | The Store | `max(grace, 30_000)` — the one exception, below | Its `terminate/2`, which releases the writer marker (`local.ex:166`) |

   No number is invented here: three of the four bounds are the composed
   cleanup grace, which is what step 5 uses and what the sessions carry, and
   the Store's floor is the Store's own existing call bound. Splitting the
   grace into fractions would mean inventing ratios, and the minimalism budget
   takes every number from an accepted or proposed decision or from the code
   it already governs. **All four are
   ceilings rather than expected waits**, which is the corrected reading: an
   earlier revision expected the executor to spend real time here, on the
   mistaken belief that it traps exits and cleans up in its own process. Only
   the transfers owner and the Store run a `terminate/2` at all, and both are
   short. **The transfers owner exists only when artifact transfers
   were enabled**, as the composed set above says (`transfers` is listed there
   as absent when disabled); where it is absent its row is not a stop the
   owner skips at runtime so much as a pid it never held, and the step for it
   does not exist in that daemon's sequence at all.

   Each of these bounds is the `after grace` on the owner's own wait, not a
   second clock: the helper passes the same number to `GenServer.stop/3`, so a
   component is given the grace once. The wait after the kill carries no
   `after`, for the reason the general rule gives — it waits for a signal that
   already exists.

   **The Store's wait has a floor, and the reason is a defect this plan would
   otherwise have shipped.** The kill after a wait is `Process.exit(pid,
   :kill)`, which runs no `terminate/2`. So at a small grace — and `1` is a
   composable value — the owner's `after grace` fires before the Store can
   finish releasing the marker, and the kill leaves the marker **on a
   deliberate operator stop**, which is exactly what this plan promises never
   happens. An operator flag would have quietly broken a durability claim.

   The Store's wait is therefore `max(grace, 30_000)`. The number is not
   invented: `30_000` is the Store's own `@call_timeout`
   (`apps/loopex_store_local/lib/loopex/store/local.ex:65`), the bound it
   already puts on its synchronous, synced call path — and releasing the
   marker is the same class of work against the same root, `File.read`,
   `File.rm` and a parent-directory sync (`writer_lock.ex:105-115`). Using the
   Store's own bound for the Store's own file I/O introduces no number and
   asks no one to pick one.

   This is a **ceiling, not a wait**: a healthy Store releases in
   milliseconds, so an ordinary stop is not lengthened at all. It bites only
   when the filesystem is wedged, which is precisely when killing the Store
   mid-release is the wrong thing to do. No other component gets a floor,
   because no other component's `terminate/2` releases a durable exclusion.

   **The residual is stated.** A Store that has not released within
   `max(grace, 30_000)` is killed, and the marker survives. That is the same
   stale marker ADR 0031's recovery rule already answers: the next daemon
   probes the marker's recorded holder and reclaims it where that holder is
   proved dead, refuses `store_writer_unverifiable` where it cannot be
   decided, and refuses `store_writer_active` where it is alive.

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
   an orphaned owner-group worker may still be unwinding when the Store goes,
   and any call it then makes reaches a stopped Store and **fails as it would
   after a VM death**. That is a refusal, never a write — the Store is gone,
   so nothing can be appended behind the daemon's back — and it is why the
   durability claim is about the journal rather than about quiescence.

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
Loopex.Runtime.quiesce(runtime, deadline_ms) ::
  {:ok, %{settled: [session_id], unsettled: [session_id]}}
```

It is defined entirely in terms of mechanisms that already exist:

- **Refusal comes first.** Every active coordinator stops admitting new
  commands for the duration. Nothing new can be started while the drain runs,
  and no client command can arrive anyway, because step 1 has already refused
  admissions at the daemon.
- **What is in flight is driven through the cancellation that exists**, not
  through a new one. That is the sequence a coordinator already runs for an
  abort: `Loopex.Executor.cancel/4` (core) under the bounds
  `Loopex.Executor.cancellation_bounds/1` derives from the session's committed
  cleanup grace (`apps/loopex/lib/loopex/executor.ex:456-474`), which the coordinator already uses at
  `session_coordinator.ex:3614` and `:5366`. Quiesce adds no bound, no
  callback and no durable command.
- **It returns when every coordinator has settled or the deadline passes**,
  naming both sets. `Loopex.Runtime.Control` already holds every active
  session and its coordinator pid, so there is nowhere else this could live
  and nothing to enumerate that core does not already have.

**Why core rather than the daemon.** The daemon cannot do this without
reaching into coordinator internals, which the dependency direction forbids,
or running a cancellation loop of its own, which is precisely the second loop
this milestone forbids. Core owns coordinator lifetime and cancellation, so
core is where a bounded settle belongs. It returns **plain data** — session
IDs and two lists — so nothing about a coordinator crosses the boundary.

**What it does not promise, stated because the numbers say so.**
`cancellation_bounds/1` derives an executor observation bound of
`max(10_000, grace_ms + 2_000)` (`apps/loopex/lib/loopex/executor.ex:458`). A daemon composed with a
cleanup grace below about ten seconds will therefore reach its own deadline
while an effect's cancellation is still within *its* bound. That effect is
reported **unsettled**, and the teardown ends it crash-equivalently: the
deadline is the daemon's, not the executor's, and quiesce does not extend one
to satisfy the other.

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

**Cancellation is not the daemon's to run**, which an earlier draft claimed.
It is the coordinator's, as part of a session's own durable command, and a
daemon-side cancellation path is precisely the second loop this milestone
forbids. Two alternatives were rejected with it. Host-authorized durable
aborts — the daemon admitting an abort per session on the way down — would
have the daemon issuing mutations on nobody's authority, at the moment it is
least able to see them through. An unbounded natural drain would make
`SIGTERM` unbounded, which is not a stop.

**The drain is core's, not the daemon's**, and that is the same rule seen from
the other side. The daemon asks for a bounded settle and waits for the answer;
every decision inside it — which effect to cancel, under what bound, what to
record — is the coordinator's, running the paths it already has. The daemon
neither issues a cancellation nor interprets one, and a coordinator that
cannot settle in time is reported rather than overridden.

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
other six differ only in which component is missing by the time the owner
runs them. In all eight the owner has a class in hand, runs no ordered
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
   class on the other six.
3. **Stop the executor** — on every class but `executor_lost`, where it is
   the component that already died — under the same discipline as every other
   stop: a monitored helper calling `GenServer.stop(pid, :normal, grace)`, the
   owner waiting on its own link with `after grace` and killing on expiry, and
   the composed cleanup grace the ordered path's step 6 uses. This is not tidiness: the executor is
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
   is nothing to stop. On the other six, the Store is **still alive**, and
   because `System.halt/1` runs no `terminate/2`, halting past it would leave
   the marker file behind on a daemon that shut down deliberately. So the
   owner stops it here, under the same bounded treatment as every other stop
   and under the same floor: the Store's wait is `max(grace, 30_000)`, so a
   deliberate fail-stop cannot kill it mid-release either.

   **If that stop times out and the Store is killed, the marker survives.**
   That is the one residual on this path and the plan states it rather than
   implying otherwise. It is bounded in consequence, not open-ended: the next
   daemon meets exactly the stale marker ADR 0031's recovery rule already
   covers, and reclaims it where the marker's own recorded holder is probed
   and found dead, refuses with `store_writer_unverifiable` where it cannot be
   decided, and refuses with `store_writer_active` where it is alive. A
   surviving marker is a case with a defined answer, not a corruption.
5. Unlink the socket **only if it is still ours**. On the six classes where
   the daemon still holds the marker this is unconditional. On the two store
   classes the marker is already gone, so the owner applies the identity rule
   above: stat the path, unlink on an equal device and inode, leave it alone
   on anything else. **The runtime root, the lease owners, the registry, the
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
   that class. Nothing restarts anything: the owner `start_link`s its fixed
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
`custody_lost`, `listener_lost`), nothing stopped the Store, so the halt
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
| `runtime_lost` | The runtime root exited | `fatal:runtime_lost` |
| `listener_lost` | The listener exited | `fatal:listener_lost` |

**A lease owner's exit is the one that is not in this table**, and its absence
is the rule rather than an omission. The owner's clause maps that pid to the
session it belonged to and handles it per session: the daemon closes that
session's controller attachment with `control_owner_lost`, leaves every
observer attached, and keeps serving every other session. The next
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

**`registry_lost` and `custody_lost` are fail-stop like every other row, and
that follows from ADR 0034 rather than adding to it.** That ADR makes a dead
registry answer `:unavailable` for every later resolution *until the host
recomposes*; in a daemon, recomposing is restarting the process. A daemon that
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
vocabulary of what an exit may say.

**Reverse cleanup.** Startup happens inside the owner, so a failure at any
step unwinds what that step and its predecessors did, in reverse — and
"predecessors" means **every process the startup started**, not the three an
earlier revision named. A bound socket is closed and its path unlinked, a
`daemon/` subdirectory the owner created is removed — no lease owner can exist
yet, since none is started before a session is activated — and **every pid the
composition function returned is stopped in reverse
start order** — runtime, executor, workspace lease, transfers where it exists
— then custody and the registry, and the Store last, so its `terminate/2`
releases the marker.

Each of those stops is the same call and the same discipline as a shutdown
stop: a monitored helper running `GenServer.stop(pid, :normal, grace)` with
the composed cleanup grace, the owner waiting on its own link with `after
grace`, and a kill on expiry. Startup introduces no second teardown
mechanism; it reuses the one the shutdown sequence defines, against the pid
map it already holds.

The owner does this in its own start path rather than leaving it to a crash,
because a crashing owner would take the links down without unlinking the
socket file, which no exit signal removes. A daemon that refuses to start
leaves no marker and no socket file behind, which is what lets an operator fix
the cause and try again without a recovery step.

**Witnesses**, all on real operating-system processes:

- **Idle shutdown.** A daemon with sessions activated and no work in flight
  receives `SIGTERM`, writes nothing further to `stdout`, closes every
  connection with the stop reason, unlinks the socket, releases the marker and
  exits `0`; the foreground server then opens the same root immediately, which
  is what proves the marker was actually released. The case also asserts the
  negative that the `stopping` field exists for: **no fatal class is recorded
  at any point during the stop**, and nothing appears on `stderr` — stopping
  every linked process deliberately produces an exit from each, and every one of
  them must be consumed rather than classified.
- **A real failure during an orderly stop is still classified, and the
  sequence still finishes.** The Store is made to fail while the listener is
  being stopped. The case asserts three things, because the second and third
  are what an earlier draft would have failed: the daemon exits with
  `store_lost` rather than `operator_stop`, since the Store is not the
  component named in `stopping` and the operator is owed the reason it
  actually went down for; **the sequence runs to its end**, reaching the
  Store's own step — where the stop raises `noproc` and is caught — then
  unlinking the socket; and the class reaches `stderr` with a non-zero exit
  rather than the owner dying of `noproc` with no status, no message and a
  socket file left behind. A second daemon opens the same root immediately
  afterwards, which is what proves the path completed.
- **A component that fails while it is being stopped.** The transfers owner
  is made to raise in its own `terminate/2` during an orderly stop, so its
  stop returns that reason rather than `:normal` and the two-clause catch
  would have killed the owner. The case asserts the sequence completes — the
  Store still stopped, the socket still unlinked — and that the exit class is
  `transfers_lost` rather than `operator_stop`, because the component died of
  its own reason and not because the owner asked.
- **In-flight shutdown, both halves of it.** Two cases, because the drain
  has two outcomes and proving one would hide the other.

  *It settles.* A daemon with a dispatched tool effect that **can** be
  cancelled inside the composed cleanup grace receives `SIGTERM`. The case
  asserts the effect settles during `quiesce/2`, that its session is in the
  returned `settled` list, that the journal carries its ordinary terminal
  fact, and that the `daemon.stopping` record is written **after** the drain
  rather than before it.

  *It does not.* A daemon with an effect held past the deadline and an
  unresolved mutation receives `SIGTERM`. The case asserts the session is in
  the `unsettled` list, and then the negative that matters: **no terminal
  mutation is claimed** for it — no `cancelled`, no `outcome_unknown`, no
  abort record appears in the journal on the way down. The ambiguous mutation
  stays `commit_unknown`, each client is sent the stop reason on a transport
  that accepts it and sees the close either way, and the exit is still `0`.
  Activating that session again afterwards resolves the transaction to exactly
  one outcome through the existing reconciliation, and the journal is
  byte-identical to what an abrupt death at the same instant would have left.
- **Store-loss fail-stop.** The Store is made to terminate under a live
  listener. The case asserts the daemon observed it, closed the listener and
  every connection with `store_lost`, unlinked the socket, and exited non-zero
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
  opening that root with nothing to recover; seven of them in a daemon with
  transfers enabled and six without — `runtime_lost`, `transfers_lost`,
  `workspace_lease_lost`, `executor_lost`, `registry_lost`, `custody_lost`,
  `listener_lost`, beside the two store classes. The set is closed for the
  fixed set, so one of those dying without a class is a failing case rather
  than a silent `:shutdown`. A lease owner is deliberately not in this case:
  its own witness is below, and it asserts the daemon **keeps running**.
- **A successor's socket survives its predecessor's exit.** Two daemons on
  one root. The first is paused between the Store's marker release and its
  unlink — the fail-stop window, reached by making the Store terminate and
  holding the owner at that point. The second acquires the marker, removes the
  stale path, binds its own socket, and prints readiness. The first is then
  released. The case asserts that it **does not unlink** the path, because the
  inode it stats is not the one it captured at bind, and that the second
  daemon's socket is still bound and still serving a client afterwards. The
  orderly variant asserts the other half: the unlink happens in step 1, while
  the marker is still held, so a successor cannot even reach that window.
- **A `--socket` path outside the root is refused.** A path in a directory
  that is otherwise perfectly valid — right owner, right mode — but outside
  the selected root's `daemon/` directory exits `invalid_socket_path` with no
  marker taken, no socket bound and nothing left behind.
- **Signals, one case per delivery route.** `SIGTERM` sent to the daemon
  process itself begins the orderly sequence; `SIGINT` is sent **to the
  launcher**, `apps/loopex_cli/bin/loopex`, which forwards `SIGTERM` to the
  child, because `:os.set_signal/2` refuses `:sigint` and a `SIGINT` sent to
  the daemon process directly is not this plan's to specify. Each case names
  which process it signals. A third asserts the install order: a `SIGTERM`
  delivered before startup completes ends a daemon that holds no marker and
  has bound no socket, proved by a following daemon starting with nothing to
  recover.
- **`owner_lost`.** The owner is killed while the daemon is otherwise healthy,
  then `SIGTERM` is delivered. The process halts with `fatal:owner_lost` on
  `stderr` rather than sitting with a handler and no owner.
- **A lease owner's death is session-scoped.** A session is activated, a
  controller acquires it and an observer attaches; that session's lease owner
  is killed. The case asserts the **daemon keeps running** — every other
  session still serves, and the process does not exit — that the controller's
  attachment closes with `control_owner_lost` while the observer stays
  attached and keeps receiving events, that a following
  `session.acquire_control` succeeds and returns an epoch **different** from
  the dead owner's, and that the activation count is **unchanged**, because a
  fresh owner is not a fresh activation.
- **The lease-owner population is bounded by the activation ceiling.** A
  daemon driven to its 64th activation holds 64 owners; the 65th activation
  refuses with `activation_ceiling_reached` and the case asserts **no
  sixty-fifth owner was started**, so the population bound is the ceiling
  rather than a second limit that could drift from it.
- **The credential processes are fatal like every other component.** The
  registry and the custody process are each killed in their own case; the
  daemon exits `registry_lost` and `custody_lost` respectively, sends that
  `fatal:<class>` on the wire, and leaves no stale marker.
- **The stop timeout is exercised, not assumed.** A session is made to hold
  the runtime's teardown past the composed cleanup grace. The case asserts the
  owner **survives** rather than dying of whatever the stop did to the helper,
  that it then kills the runtime supervisor, and that it still reaches the
  Store stop and the socket unlink — the step a stop called inline would skip.
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
  it did not — and that the sequence still reaches the Store stop and the
  socket unlink.

  It also asserts the thing a grace of 1 ms would otherwise have broken:
  **the next daemon opens that root with no stale marker to recover.** That is
  the Store's floor doing its work — the Store is waited on for
  `max(grace, 30_000)`, not for 1 ms — and without it this case would have
  left a marker behind on a deliberate operator stop. A second case composes
  `cleanup_grace_ms: 0` and asserts the daemon refuses at startup with
  `cleanup_grace_invalid`, holding no marker and binding no socket. Both run
  at both toolchain pairs, because the timeout result was observed at both.
- **Reverse cleanup.** A startup made to fail after the marker is acquired —
  at the socket permission check and at the index bound, separately — leaves
  no marker held and no socket file behind, proved by a second daemon starting
  cleanly on the same root with no recovery step.
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

**First, the process inventory**, because more than one review found two
documents counting the same processes differently. Every process any document
in this set names appears here once, with who starts it, who holds its link,
who stops it and what its death means.

| Process | Started by | Linked to | Stopped by | Its death |
| --- | --- | --- | --- | --- |
| **Daemon owner** | The `loopex daemon` escript | — | Itself; it halts the VM | There is nothing above it; the signal handler's backstop halts with `owner_lost` if a signal finds it gone |
| Credential routing **registry** (ADR 0034) | Daemon owner, first | Daemon owner | Orderly step 6 | `registry_lost`, daemon-fatal |
| Credential **custody process** (ADR 0034), **one per configured provider token** | Daemon owner, second | Daemon owner | Orderly step 6 | `custody_lost`, daemon-fatal. M5 composes one provider, so one process; a host configuring two carries two, each with its own registry row (`0034-…-technical.md:95-98`) |
| **Store adapter** (ADR 0031) | The composition function, in the owner's process | Daemon owner | Orderly step 6, **last of all** | `store_lost`, or `store_capacity_exceeded` on its own capacity refusal — both fail-stop |
| **Artifact transfers owner** | The composition function | Daemon owner | Orderly step 6 | `transfers_lost`, daemon-fatal. **Absent** where transfers are disabled |
| **Workspace lease** | The composition function | Daemon owner | Orderly step 6 | `workspace_lease_lost`, daemon-fatal |
| **Local executor** | The composition function | Daemon owner | Orderly step 6, before the lease | `executor_lost`, daemon-fatal |
| **Runtime root** (a supervisor) | The composition function | Daemon owner | Orderly step 5 | `runtime_lost`, daemon-fatal |
| **Listener** | Daemon owner, last of the fixed set | Daemon owner | Orderly step 1 stops it accepting; step 3 closes and unlinks | `listener_lost`, daemon-fatal, and the one fatal class no client can be told |
| **Lease owner, one per activated session** (ADR 0033) | Daemon owner, on activation | Daemon owner | Orderly step 4, in sequence | **Session-scoped**: that session's controller closes with `control_owner_lost`, observers stay, the next acquisition starts a fresh owner with a fresh epoch. Population bounded by the 64-activation ceiling |
| **Connection**, one per accepted client | The listener | The listener | Orderly step 3, or the client | That client's connection closes. Nothing else |
| **Stop helper**, one per stop | Daemon owner, `spawn_monitor` | Monitored, never linked | Its own call returning or raising | Nothing: it is monitored so that whatever `GenServer.stop/3` does to it cannot reach the owner |
| **Session coordinator** | Core, under a `DynamicSupervisor` (`restart: :temporary`) | Core | Core, when the runtime stops | Core's own refusal on the next command for that session; **no signal reaches the daemon and none is owed** |
| **Owner group and workers** | Core, beneath a coordinator | Core | Core | Core's; a trapping owner group unwinds on its own clock and the daemon does not wait for it |
| **Attachment dispatcher** | Core, per attachment | Core | Core | That attachment's, and core's existing detachment rules |
| **Trace tracer** | Core, per trace session | Core | Core | The trace session's; it carries no daemon meaning |
| **Provider sender and guardian** (ADR 0034) | The adapter, per invocation, inside the calling process | Neither is linked to the daemon owner | The guardian kills the sender at the deadline; both end with the invocation | That invocation's refusal, as one of the seven atoms. No daemon class |
| **Provider child**, its Port and OS process (ADR 0019) | The adapter's launcher, per invocation | The Port's owner | The invocation | That invocation's refusal |
| **Per-job Port worker, carrier and guard** (ADR 0022) | The local executor, per job | The worker is monitored by the executor; the carrier and guard are OS processes | The worker terminates the captured group when the executor goes | The job's outcome, reconciled through `commit_unknown`. **These are the processes the daemon cannot wait for at a halt** |

| Boundary | Owner | What fails | Who observes it, and how | What the client sees | Durable / not durable |
| --- | --- | --- | --- | --- | --- |
| **Store ↔ daemon** | `loopex_store_local` owns the marker and the log; the **daemon owner process** holds the Store's link and pid | Append error, including the capacity refusal | The Store stops **itself** (`local.ex:251-270` answers `{:stop, reason, commit_unknown, state}`) and releases the marker in `terminate/2` (`local.ex:166`). The owner's `{:EXIT, store_pid, reason}` clause receives it **with the store's real reason**, which is what distinguishes `store_capacity_exceeded` from `store_lost` | `daemon.stopping` with `store_lost` or `store_capacity_exceeded`, one bounded attempt, then the socket closes | **Durable:** whatever committed. **Not:** the failed append; the in-flight transaction is `commit_unknown` and reconciles later |
| **Store ↔ daemon (startup)** | The adapter | Marker held, unverifiable, log too large | `WriterLock.acquire` refuses with `store_writer_active` / `store_writer_unverifiable`; `Log.open` refuses `store_log_too_large` (`log.ex:80-84`) | Nothing — no socket exists yet | **Not durable:** nothing was written. Reverse cleanup leaves no marker |
| **Core ↔ daemon: existence query** | `loopex` answers; the daemon asks | Root unreadable, malformed ID, unrecognised answer | The query's own closed result set — `present`, `absent`, `invalid_id`, `store_unavailable`, `unexpected` (this plan's new core operation) | The matching refusal, four of them distinct; nothing created, nothing attached, no lease | **Not durable:** the query writes nothing, proved by a byte-identical root |
| **Core ↔ daemon: attach** | `loopex` owns the cursor barrier, snapshot and queues | Barrier race, stale handle, queue overflow | Core's existing attach transaction and stale-handle checks; the daemon reads no coordinator state to repair a race | Snapshot then contiguous at-least-once events, or detachment at the last emitted cursor with a stable reason | **Durable:** the events. **Not:** the attachment, the window, the buffer |
| **Core ↔ daemon: resume** | `loopex` | Placement mismatch, unknown session, already-resolved command | Core's existing resume path and command idempotency (`control.ex:901-907` returns the historical result without starting an owner) | Core's refusal, forwarded unchanged | **Durable:** the resume command and its result |
| **Core ↔ daemon: commands** | `loopex` admits; the daemon forwards | **Coordinator death** | Core's `DynamicSupervisor` (`restart: :temporary`, `session_coordinator.ex:134-142`); `Control` consumes the `DOWN`, releases the fence and leaves the entry (`control.ex:821`). **No signal reaches the daemon, and none is owed** — the daemon supervises the runtime, not the coordinators beneath it | Core's existing refusal on the next command for that session, forwarded unchanged. `residency` still reads `active`, which remains true: this daemon did activate it | **Durable:** whatever committed before. **Not:** any claim about liveness |
| **Lease owner ↔ connections** | `loopex_daemon` | A session's lease owner dies, taking that session's in-flight admission set with it | The owner's `{:EXIT, pid, reason}` clause maps the pid to **its session** rather than to a daemon class — the one session-scoped row in this table, on the maintainer's decision of 2026-09-20 | That session's controller attachment closes with `control_owner_lost`; observers stay attached; the next `session.acquire_control` starts a fresh owner and mints a fresh epoch | **Not durable:** the lease, the epoch, the in-flight set. The journal is untouched, and a mutation already inside core settles or refuses exactly once under core's serial ownership |
| **Lease owner ↔ connections (expiry)** | `loopex_daemon` | A holder stops renewing, or a mutation is unresolved at the deadline | The lease owner's own monotonic deadline; the in-flight set decides when a takeover is granted | The holder's next mutation refuses; a takeover is eligible at the deadline and granted when the in-flight set empties | **Not durable:** the lease. The mutation that was in flight settles or refuses exactly once |
| **Listener ↔ connections** | `loopex_daemon` | Foreign peer, malformed frame, over-long path, backpressure | Filesystem permission verified after bind, then the per-platform peer-credential read (`LOCAL_PEERCRED` / `SO_PEERCRED`), then ADR 0023's framing refusals; backpressure at the 4 MiB output buffer | Closed before initialize for a peer refusal; a stable framing reason otherwise; detachment at the last emitted cursor under backpressure | **Not durable:** connections, buffers, windows |
| **Registry ↔ sender ↔ custody** | The **host** owns the registry and custody; the adapter owns the sender. The token is bound at composition, resolved per invocation | No registry row, registry dead, custody dead, refusal, malformed reply, deadline | `route(handle, token)` answers `:unavailable`; resolution fails as one of the six atoms produced below the guardian (`:no_token`, `:invalid_token`, `:missing`, `:expired`, `:oversized`, `:unavailable`); the **guardian** enforces the deadline, kills the sender and reports the seventh, `:timeout` | The adapter's existing `Loopex.Model` refusal shape, with the atom in the bounded diagnostic | **Not durable:** nothing about credentials is ever journaled, and no span or record carries model `options` — the model span is a fixed identity map. The invocation's failure is durable |
| **CLI ↔ socket** | `loopex_cli` | Socket unreachable, refusal, transport loss, renewal failure | The client's own reconnect loop and its renewal timer | Reconnect at the retained cursor, deduplicating; a failed renewal drops to observer with the loss on `stderr`; a reconnecting controller must acquire again for a fresh epoch | **Durable:** nothing the client holds. The cursor is a client-side position |
| **Daemon ↔ OS: signals** | The operator | `SIGTERM`, delivered to the handler the daemon installs before it takes the marker; a terminal `SIGINT` reaches it only as the `SIGTERM` the launcher forwards, since `:os.set_signal/2` refuses `:sigint` | The owner drains through core's `quiesce/2` within the composed cleanup grace, tells clients, unlinks the socket while it still holds the marker, and then stops its linked processes in reverse order — lease owners, runtime, edges, Store last — each stop driven by a monitored helper calling `GenServer.stop(pid, :normal, grace)` while the owner waits on its own link with `after grace` and kills on expiry. Classification is from the observed exit reason alone: `:normal`, `:shutdown` and the owner's own `:killed` are consumed, everything else is classified | `daemon.stopping` with `operator_stop`, then close | **Durable:** whatever committed. **Not:** work ended crash-equivalently — a claim about the journal, not about every process being gone |
| **Daemon ↔ OS: kill** | The operator | `SIGKILL`, power loss | Nothing runs — no handler, no `terminate/2` | The socket closes with no record at all | **Durable:** the journal. The marker is left for the next daemon's verified stale-writer recovery |
| **Daemon ↔ OS: socket file** | `loopex_daemon` | A stale `daemon.sock` from a dead daemon | Only the marker holder may unlink and rebind, so two starts resolve at the marker and never at the socket | The loser exits without touching the socket | **Not durable:** the socket file is a path, never state |
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
second copy of the whole wiring layer. One socket listener, one narrow
core concurrent-attachment change, **one excluded-MFA list in `Loopex.Trace`**
— which unifies nothing and is not asked for by this milestone's features at
all: it exists because accepted ADR 0030 already requires that a key-bearing
call be excluded by match specification before delivery, and the
implementation did not do it. Direct code cannot supply it, because exclusion
has to happen where the patterns are installed; redaction at the sink is too
late, the raw call having already reached the tracer. It is the smallest form
of the requirement: a list of `{module, function, arity}` identities cleared
after the module pattern, using `:trace.function/4` exactly as it already
does. **One bounded `quiesce/2`** — which unifies nothing today and says so:
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
decision named above; M5 introduces none of its own.

| Ceiling | Value | Source |
| --- | --- | --- |
| Log capacity per state root | 256 MiB; an append past it refused as `store_capacity_exceeded`, which terminates the store and closes the daemon, a log already past it refused at open as `store_log_too_large` | ADR 0031 |
| Frame ceiling on any single store record | 4 MiB | ADR 0031 |
| Retention and replay | Full history, no compaction, full replay at open | ADR 0031 |
| Attachments per session | 64 | ADR 0032 |
| Attachments per daemon | 512 | ADR 0032 |
| Core event-count queue per attachment | 1,024 events | ADR 0032 |
| Daemon socket output buffer per connection | 4 MiB encoded | ADR 0032 |
| Resident window per session | 4,096 events and 16 MiB encoded | ADR 0032 |
| Aggregate retained encoded events per daemon | 512 MiB | ADR 0032 |
| Idle time before an attachment is evicted and its window and buffer released | 10 minutes; it never stops a coordinator | ADR 0032 |
| Sessions activated per daemon lifetime | 64; the 65th activation refused, the remedy being to restart the daemon. It is per lifetime rather than concurrent because nothing deactivates a coordinator, which is recorded as a limitation | ADR 0032 |
| Recorded session index entries per root | 4,096; a root whose directory holds more refused at daemon start. The ceiling is on recorded entries and never on reachability: a session reached by ID beyond it is activated and not recorded, and the listing carries `index_full` | ADR 0032 |
| `session.list` page | at most 256 entries, `limit` in 1 to 256 | ADR 0032 |
| Socket path bound, over `<root>/daemon/daemon.sock` | the platform's usable `sun_path`, one byte less than the structure because of the terminator: at most 103 bytes on Darwin and 107 on Linux, derived and tested per platform rather than assumed, refused at start as `socket_path_too_long` | ADR 0032 |
| Protocol frame ceiling on the wire | unchanged from ADR 0023 | ADR 0032 |
| Cleanup grace | an integer of 1 or more, refusing `0` with `cleanup_grace_invalid`, because core's `cancellation_bounds/1` admits `grace_ms >= 1` (`apps/loopex/lib/loopex/executor.ex:456`) | This plan, against core's existing validation |
| Floor on the Store's stop | `max(grace, 30_000)`, the Store's own `@call_timeout` (`apps/loopex_store_local/lib/loopex/store/local.ex:65`), so a small grace cannot kill it before `terminate/2` releases the marker | This plan, against the Store's existing bound |
| Lease term | 30 seconds | ADR 0033 |
| Lease renewal interval for the reference clients | 10 seconds | ADR 0033 |
| Takeover grace beyond expiry | none; takeover is eligible at expiry and granted once the session's in-flight admission set is empty | ADR 0033 |
| Writer epoch | opaque, at most 64 bytes, at least 128 bits of fresh randomness, minted per grant | ADR 0033 |
| Credential size | 1 to 65,536 bytes | ADR 0019, unchanged by ADR 0034 |
| Credential frame cap | 69,632 bytes | ADR 0034, which is where the frame's shape is written; no ADR 0019 file states it |
| `req_llm` version pin | `~> 1.24.0` | Maintainer decision 4B of 2026-09-20, a **plan** decision. A dependency pin is not a contract number: it binds what this milestone builds against and is changed by an ordinary reviewed dependency change, not by an ADR amendment |

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
