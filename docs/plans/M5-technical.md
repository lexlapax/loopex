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
| `loopex` | Durable session truth, the race-free attach barrier and cursor, independent concurrent attachments to one session, the read-only session-existence query, the per-attachment event-count dispatcher queues, cancellation and recovery | A lease, a transport, a byte limit, residency policy or any daemon fact |
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
| 1 | `apps/loopex_daemon/test/session_lifetime_test.exs` | A real daemon operating-system process per state root. The startup ordering and its readiness line: the line appears on `stdout` only after the marker is held and the socket is bound, permission-checked and accepting, a client connecting the instant it appears is served, and each of a held marker elsewhere, a failed socket permission check and an exceeded index bound prints no readiness line and exits non-zero with its own class. Orderly shutdown on `SIGTERM` and on `SIGINT`: new connections refused and new admissions refused from that instant, a dispatched tool effect and an unresolved mutation ended crash-equivalently once the cleanup grace elapses with **no terminal claimed for either** — no `cancelled`, no `outcome_unknown`, no abort record — the ambiguous mutation left as `commit_unknown` and resolved to exactly one outcome when that session is next activated, every client given one bounded best-effort `daemon.stopping` naming `operator_stop`, the socket unlinked, the Store stopped last, and exit `0` — with the foreground server opening the same root immediately afterwards, which is what proves the marker was released, and the journal byte-identical to what an abrupt death at the same instant would have left. **Store loss is a separate fail-stop, not that sequence**: the Store terminates itself and releases the marker before the daemon can act, so the daemon observes the death, refuses service, closes every connection with `store_lost` (or `store_capacity_exceeded` where that was the reason), unlinks and exits non-zero with that class on `stderr`, attempting no Store stop because there is none to attempt — proved by a second daemon starting on that root with no stale marker to recover. An active session progresses with zero attachments. An orderly stop releases the writer marker and records nothing false; an abrupt kill followed by restart activates nothing, then activates each session the root records when a client reaches for it, under the same placement identity and with no duplicate effect. The restart proves the marker path explicitly: the daemon opens with `recover_stale_writer: true`, a marker whose holder is proved dead is reclaimed, a marker whose holder is alive refuses with `store_writer_active`, and a marker whose holder cannot be decided refuses with `store_writer_unverifiable` — all three before the socket path is read, unlinked or bound. Simultaneous starts on one root resolve at the writer marker with exactly one listener and the loser never touching the socket. A root driven to the 256 MiB log capacity refuses the append with `store_capacity_exceeded`, the store terminates, the caller sees `commit_unknown`, and the daemon closes the listener and every connection and exits naming the capacity with nothing committed lost; a root whose log is already past that bound is refused at open with `store_log_too_large` rather than opened and truncated. `session.list` returns pages of at most 256 entries in session-ID order with an exact continuation cursor from the daemon index, carrying only session identity, recorded placement identity, `residency` and `controlled`. A session committed to the Store whose directory entry was never written — injected at that exact cut — is absent from the listing, still reachable by ID, and present in every listing after the activation that records it. A detached long-running command and a pending admission each cross the idle deadline with every client gone and run to completion, proving dormancy releases attachments and never a coordinator. The activation ceiling refuses the 65th activation of a daemon lifetime with its stable reason and the restart remedy, and the count starts again after a restart because it counts per lifetime; killing an activated session's coordinator leaves the daemon serving: the listing still reports `residency: active`, which remains true because this daemon did activate that session, and the next command for it returns core's own refusal forwarded unchanged, with the daemon adding and interpreting nothing; a root whose directory exceeds the recorded-entry bound refuses at start; at that bound a session reached by ID is activated and not recorded and the listing carries `index_full`; a session committed to the Store whose directory entry was never written is recovered both by its ID — validated through core's read-only existence query, with the case asserting the validation itself created no attachment and no durable record — and, by a client that never saw the ID, through ADR 0032's full command-identity sequence run to the end — replay `session.create` with the original `command_id`, core returns the historical result and so the session ID **without starting a coordinator**, the existence query answers `present`, the daemon repairs the directory entry and index row, control is acquired, and `session.resume` with a fresh resume command ID under the granted writer epoch is what activates the session — with the case asserting exactly one session in the root, the returned ID equal to the committed one, the replay itself starting no coordinator, the directory entry and index row present afterwards, the session listed, a live coordinator existing after the resume with the activation count risen by one, and a later prompt landing on that session and producing its events rather than on a second session or on nothing; an unknown ID answers negative from that query with nothing created, nothing attached and no lease granted; a directory write that fails during activation is reported to that client, leaves the session usable and reachable by ID while absent from `session.list`, and is written by the retry the next time the live daemon holds that ID — right after activation, on a later command for the session, or when a client reaches it by ID; a recorded session the daemon's composition cannot serve refuses at activation by name while every other session in the root activates. After an orderly stop the foreground server and the reference CLI reopen the same root and resume a daemon-created session under the same placement identity with identical replay. No durable method reaches the socket |
| 2 | `apps/loopex_daemon/test/socket_transport_test.exs`, `apps/loopex_protocol/test/public_schema_conformance_test.exs` | A raw-byte client over the socket negotiates generation 2 and receives generation 2's **own** exact schema digest, written out as a literal in the conformance module beside generation 1's and different from it by construction: `LoopexProtocol.Session.schema_digest/0` is taken over the generation, the ordered methods, the ordered record families, the ordered error codes and the limits, and generation 2 changes the first two, so a generation 2 that negotiated generation 1's digest would be reporting a contract it does not serve. Generation 1's bytes, digest, method inventory and limits are proved unchanged in the same module and at their own literals — the `3a17…08f4` schema digest, the schema file digest and the vectors file digest the conformance module already pins — so the generation-2 work is proved additive rather than asserted to be. A generation-1-only initialize is refused with nothing created. Generation 2's record families include `daemon.stopping`, with literal vectors for each reason a **client can actually receive** — `operator_stop`, `store_lost`, `store_capacity_exceeded` and `fatal:supervision_fault` — and explicitly none for the startup-phase classes, which carry no vector because no socket exists when they occur and no client can be holding one, and its presence in the digest is what a generation 2 omitting it would fail on. Its delivery bound is proved both ways: a reading client receives the record before the close, and a client that has stopped reading until its 4 MiB output buffer is full receives nothing and is closed anyway, with the daemon making exactly one attempt and never blocking on it. Identical durable identities for the same command corpus through facade, foreground server and socket. Owner-only peer access proved in both layers: the socket's `0700` daemon-owned subdirectory and `0600` socket mode read back after bind, a permissive subdirectory or socket mode refused at start, a subdirectory the daemon does not own refused, a path component below the root that it did not create refused — and a state root at the ordinary `0755` the foreground server creates it with accepted, not refused, because the daemon owns the subdirectory and never re-permissions the root — and an unreadable or undecodable peer credential closing the connection before initialize — all in the fast check, which needs no second user — with the real cross-uid refusal and the same-uid success carried by two `@tag :cross_uid` cases the release check runs as `mix test --only cross_uid` on its single run, which closure requires to be on Linux, and where the script asserts exactly two executed tests so neither a zero nor a lone survivor can pass. Frame, fragment, malformed-input and over-long socket path refusals with distinct stable reasons, the path cases binding at the derived bound and at one byte past it on each platform the release check runs. A client disconnect recorded as transport loss with no cancellation and no interaction change. The generation-2 vectors are literal bytes with literal verdicts, held beside generation 1's in `apps/loopex_protocol/test/public_schema_conformance_test.exs`, never values generated from the implementation they check |
| 3 | `apps/loopex_daemon/test/collaboration_test.exs` | One lease per session in daemon memory with observers attached. Connection identity, epoch, held state and unexpired term checked together before core admission or any durable write, including a known current epoch sent by an observer. Takeover only after release or expiry, with a fresh epoch minted before the successor's first command. A killed controller fenced and its late commands refused. The three ways a controller stops holding, proved separately because the transport cannot tell two of them apart: an explicit `session.release_control` frees the lease at once, while an EOF from a politely closed client and a killed client both wait for expiry, with a takeover refused before the deadline and granted after. A per-session lease owner killed while a mutation is in flight taking the listener, every connection and the daemon down with it, after which the restarted daemon holds no lease and the previous holder's delayed command is refused on both the holder and the epoch check. A daemon restart leaving every session uncontrolled with every earlier epoch refused. A controller abort cancelling work dispatched under an earlier process with a truthful cleanup outcome. The expiry linearization: a mutation blocked inside core across the deadline settles under its own lease while the eligible takeover waits and is granted only after it resolves; the holder's next mutation refused at the deadline; the acquiring request refusing with its stable reason when its own deadline elapses first; and the holder disconnecting while a mutation is in flight — in every case exactly one of settle or refuse, never both. No control from content, metadata, answers or attachment order. Forward and backward wall-clock jumps changing neither live admission nor takeover timing |
| 4 | `apps/loopex/test/concurrent_attachments_test.exs`, `apps/loopex/test/session_existence_query_test.exs`, `apps/loopex_daemon/test/replay_residency_test.exs` | Core's read-only session-existence query answers exactly one of the closed set `present`, `absent`, `invalid_id`, `store_unavailable` and `unexpected`, from a fresh process against a real root, with one case per result. `store_unavailable` is injected through the controllable fault store the suite already has, `Loopex.M1RuntimeTestStore`, whose `fail_reads/2` hook makes its reads refuse — not by making the root unreadable, which cannot produce that answer on the real adapter: `Loopex.Store.Local` answers `ownership_head` from `state.store`, in memory, so a root that has become unreadable on disk still answers. `unexpected` is injected by a stub answering outside the set. It is proved to create no attachment, no incarnation, no durable record and no Store write: the root's journal and session directory are byte-identical before and after a run of queries, including for unknown and malformed IDs. Control acquisition proceeds only on `present`; the other four fail closed with no attachment, no lease and no activation, and name four distinct reasons, so an unreadable store is never reported as an unknown session. Several core attachments to one session remain independent when one detaches or backpressures. A snapshot anchored at the committed sequence, then contiguous at-least-once buffered and live delivery across the window boundary with no gap. Core is the only replay owner: every delivery case runs a second time with the daemon's resident window disabled and a third with it dropped mid-stream, all three byte for byte identical, so the window is proved to establish no snapshot and no cursor. Aggregate reclamation follows the fixed order ADR 0032 sets — zero-attachment windows by ascending last delivery, then the furthest-behind session's window, then detachment — including the case where zero-attachment windows alone consume the ceiling. A slow observer detached at its last emitted cursor while the controller and the other attachments continue. Per-session and per-daemon limits refusing independently. Idle eviction and reconnect with no missing durable event, any duplicate deduplicated by session ID, sequence and event ID. Retained encoded bytes at or below the 4 MiB output buffer, 16 MiB window and 512 MiB aggregate ceilings, enforced in the daemon-owned stages, exercising 512 attachments and maximum-sized output records separately, with observed process RSS recorded beside the ceilings. Progress coalesced or dropped with counted drops and no journal delay |
| 5 | `apps/loopex_daemon/test/multi_client_workflow_test.exs`, `apps/loopex_daemon/test/external_socket_workflow_test.exs`, `docs/evidence/M5-closure-runs.md` | The operator workflow end to end, each step a command an operator types: `loopex daemon` refusing once per missing or invalid composition input with its own class and leaving no marker or socket behind, then starting and printing the one-line JSON readiness record; `loopex run --daemon` creating and driving a session; `loopex resume --daemon` activating a dormant one through acquire, resume with a fresh command ID, attach; `loopex attach` refused with `session_dormant` at the **attach** step against a session this daemon has not activated, in both roles, while `loopex resume --daemon` acquires that same dormant session and succeeds — the two asserted together, since refusing dormancy at acquisition would break the resume path; `--take-over` on a dormant session asserted to release its lease before exiting, proved by `loopex resume --daemon` succeeding immediately afterwards rather than refusing `control_held`; a CLI holding a lease releasing it explicitly on every exit path; `--after` starting strictly after a sequence and its absence replaying from `0`; a controller whose renewal fails continuing as an observer and sending no further mutation; a reconnecting controller acquiring again and receiving a fresh epoch before any mutation. From a fresh extraction of the exact candidate — staged with `git archive`, extracted and built outside the checkout — an operator follows the documented prerequisites and commands, supplies workspace, provider and policy inputs, starts the daemon, and drives one session from the reference CLI as controller and the Node client as observer, kills the controller, takes over from the observer and aborts cross-process work. The documented CLI build and the provider companion build both run inside that extraction, on the archive-carried source identity rather than on `.git`, with the missing, unsubstituted-or-malformed, changed-during-build and mismatched-commit refusals each proved and the identity the build reports asserted equal to the commit the archive was staged from. The attended real-provider cases run from that extraction, against the escript it built there. The workflow drives ADR 0030's existing core spans end to end — command admission, commit, effect intent, publication, interaction, and the model, store, policy and executor port callbacks — with the same bounded identity metadata an embedded caller produces, and no event outside that closed inventory is emitted by anything M5 adds. Daemon-internal functions are proved by the daemon's own tests and logs: `Loopex.Trace` traces only processes the runtime owns, flagged with `set_on_spawn` from the runtime's supervisor, and the daemon's listener, connections and lease owners are host processes above the runtime, so no trace-session witness is claimed for them. `VERSION` in the extracted tree is exactly `0.2.0`. Every tracked file under `docs/operator/` and `docs/developer/` has been read against the candidate, including the ones M5 leaves unchanged, recorded as a checklist derived at that commit — `git ls-files -- docs/operator docs/developer`, sorted, one row per path, each row marked *updated* or *reviewed unchanged* — retained with the closure runs. The derivation is over **every tracked file** in those two trees, not only Markdown, and that is deliberate: the gate promises that every file under them was read, so a diagram, a fixture or a data file added later must appear rather than slip through a `*.md` filter that was true when it was written and silently false afterwards. It also avoids a pathspec trap, checked rather than assumed: `git ls-files 'docs/operator/**/*.md'` without `:(glob)` matches nothing at all and would have made the gate pass vacuously. The directory form returns 26 tracked files as of this revision — 18 under `docs/developer/` and 8 under `docs/operator/`, all Markdown today — and the closure checklist states the count it derived so a reviewer can see the list was not empty, with every path in the tree present, no row unmarked, and each finding named and resolved before the closure packet |
| 6 | `apps/loopex_llm_reqllm/test/credential_plane_test.exs`, `apps/loopex_llm_reqllm/test/adapter_test.exs`, `apps/loopex_llm_reqllm/test/provider_retainer_boundaries_test.exs`, `docs/evidence/M5-closure-runs.md` | From the completion of a reference host's composition onward, the parent VM's environment holds no credential under the adapter's name and no value equal to the credential in use, before, during or after a call — "during" observed from inside the call at child readiness; composition is proved to read the operator's variable once and delete it. Every row of ADR 0034's failure table resolves to its closed-set atom and retains no copy: `:no_token` for an absent token, `:invalid_token` for a malformed one, `:unavailable` for a token with no registry row, a gone registry, a dead custody process and a malformed successful reply, and each of `:missing`, `:expired` and `:oversized`, a term outside the closed set reported as `:unavailable`, and a custody process blocking past the invocation deadline, where the **guardian** kills the sender and reports `:timeout`, asserted distinct from every refusal so the guardian can tell a refusal from a silence and asserted to bound the invocation whatever the custody process does. Two resolutions in flight at once is a success case, not a refusal: both invocations complete with their own credentials. Tracing is proved in two tiers, against `Loopex.Trace` as implemented rather than against ADR 0030's prose: under the **default** configuration no trace entry names `ProviderBridge.route_credential/2`, `receive_custody_reply/2` or `write_credential_frame/2`, the tracer receives no raw trace message for them and no credential bytes or token appear in any entry — because `modules/1` expands a namespace through the application's own module list and the adapter is not a `:loopex` module; under a configuration that **explicitly names** the adapter module, entries for the three may exist and each is asserted to carry placeholders and no credential bytes and no token. That second tier holds because ADR 0034 binds the **shape**: the three carry credential bytes only under a credential-named key, which `@credential_pattern` placeholders at any size. It does not hold by size — running `Entry.render/2` shows a bare or tuple-wrapped credential of 1, 40, 51 or 64 bytes rendered verbatim, and only a credential-keyed value placeholdered at every size — so the witness calls each of the three with a **one-byte** credential under a session naming the module, and asserts no entry contains that byte. A third case asserts the three identities, so neither tier can pass vacuously. The registry lookup is proved to carry no credential. Two runtimes composed in one VM, each with its own registry, custody and token, are proved isolated: a token minted for one answers `:unavailable` in the other, so tokens do not cross runtimes, and neither runtime's child — nor either child's diagnostics — ever observes the other's credential. That case subsumes the old within-one-runtime concurrency witness, which a composition-bound token makes meaningless: two invocations of one runtime necessarily carry the same token, so what has to be proved independent is two *runtimes*. A registry killed under a composed runtime makes every later resolution through that handle answer `:unavailable`, and the adapter is proved not to retry, wait or rebuild — recomposition is the only repair. Every re-pointed case of `apps/loopex_llm_reqllm/test/credential_plane_test.exs` passes with its assertion unchanged in meaning: version refusal and bootstrap refusal before any credential, late delivery after expiry impossible, rotation between invocations, two live credentials in one VM, sink loss, one child's loss not poisoning another, ordinary host messages and returned reasons, every child Logger form and metadata, and the four crash-report cases. The child-environment witness inside the version-refusal and bootstrap-refusal cases — the child's recorded `entry-env` marker refuting `Adapter.credential_variable()` — holds unchanged. The 65,536-byte ceiling case in `provider_retainer_boundaries_test.exs` is re-pointed too, because that module delivers its credential through `System.put_env` in its `setup` and again in the case body; that invocation's own custody process holds the oversized value instead. The drift-protection case in `adapter_test.exs` survives strengthened, with an exact allowlist: `[]` for `provider_bridge.ex`, the arity-zero enumeration and only that for `provider_launcher.ex` because it is ADR 0019's first-image scrubbing rather than a credential read, `provider_worker.ex`'s two non-secret crash-dump names, and `[]` everywhere else. Because the launcher's read survives, the case also asserts its *use*: the enumeration's result flows only into the Port's removal list, every name is mapped to `false`, none is compared against `credential_variable/0`, and no value reaches the sender, the frame or any caller. Its scan is widened from one `System.get_env(...)` expression to every route an environment read can be written — `System.get_env/0`, `/1` and `/2`, `System.fetch_env/1` and `fetch_env!/1`, `:os.getenv/0`, `/1` and `/2`, `:os.env/0`, and indirect application through `apply/3` or a captured function — each unpinned route refuted outright. The `req_llm` move to `~> 1.24.0` — pinned to that minor, not to `~> 1.24`, so the reviewed diff is the version actually built against — lands as its own reviewed change before the credential change, with the reviewed changelog diff across the intervening releases named in the commit, the adapter and streaming-conformance suites green, and the *existing* real-provider case at closure run against it. It adds no call path: nothing in M5 calls anything `1.24.0` makes newly reachable, and no second provider, second credential or new release-check case enters this milestone. It is explicit M5 scope, separate from ADR 0035 and not conditional on it. A security review by someone other than the implementer is recorded. The twelve modules are then converted to run concurrently one at a time, each kept only while its application's suite stays green, any module that stays serial keeping its reason beside it, and the measured duration is recorded beside the M4-closure baseline as evidence about the change rather than a threshold |

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
| Cleanup grace | `--cleanup-grace-ms` | the composition default | `cleanup_grace_invalid` |
| Project resources | as the host already takes them | as today | as today |
| Socket path | `--socket` | `<root>/daemon/daemon.sock` | `socket_path_too_long`, `socket_permission_unverified` |

Every one of these is refused **before** the marker is acquired where that is
possible, so the common operator mistake costs nothing and leaves nothing
behind; the ones that can only fail later are covered by the reverse-cleanup
rule.

A `--socket` override is constrained exactly as the default is: its parent
directory must be owned by the daemon's user and mode `0700`, no component
below the state root may be a symbolic link the daemon did not create, and the
socket is created `0600` and verified after bind. An override does not buy a
weaker rule; it only moves where the rule applies.

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

**Stopping.** `SIGTERM` and `SIGINT` both begin the orderly shutdown below.
There is no `daemon.stop` method on the wire: stopping is an operator act
against the process, and a client-issued stop would let one connection end
every other client's session residency, which is authority the socket does not
carry and this milestone does not grant.

**Exit status.** `0` when an orderly shutdown completes, whatever the sessions
were doing. Non-zero, with one reason line on `stderr`, for every fatal exit,
naming its class rather than a stack: `store_writer_active`,
`store_writer_unverifiable`, `store_log_too_large`, `socket_path_too_long`,
`socket_permission_unverified`, `session_index_too_large`, `store_lost`, and
`supervision_fault` for the daemon-fatal rules ADR 0032 and ADR 0033 define.

#### How a session is created and driven over the socket

`loopex attach` alone cannot start work, because a session has to exist and be
resumed before anything can be sent to it. The daemon forms of the two
released commands are what reach the socket:

- **`loopex run --daemon <socket> --policy … "<prompt>"`** — creates a session
  and sends its first prompt. Its sequence is `session.create`,
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

So the daemon's **attach** handler is where it belongs. That handler consults
the daemon's own residency index — a daemon fact the daemon owns, needing
nothing from core — and refuses `session_dormant` for a session this lifetime
has not activated. `loopex resume --daemon` is unaffected: it acquires,
resumes, and only then attaches, by which time the session is active.

`loopex attach --take-over` against a dormant session therefore acquires
successfully and is refused at attach, holding a lease it no longer wants.
That is exactly why the general rule matters: **a CLI that holds a lease
releases it explicitly before exiting**, by sending `session.release_control`,
because ADR 0033 binds early release to that call alone and treats every
transport loss — including a clean client exit — as a wait for expiry. On this
path the client releases, exits non-zero, and names `loopex resume --daemon`
as the remedy. Without that release it would strand the operator: the command
the refusal recommends begins by acquiring the same lease, and would refuse
`control_held` for the rest of the term.

**Cursor, reconnection and re-acquisition.** The client remembers the last
event cursor it emitted and, on transport loss, reconnects at it,
deduplicating by session ID, event sequence and event ID; delivery is
contiguous and at least once, so a duplicate at the seam is expected and a gap
is a defect. A reconnecting **controller** does not resume its old authority:
the lease it held is expiring or expired, and it must acquire again and
receive a **fresh writer epoch** before any further mutation. If the session
went dormant in between — because the daemon restarted — it must resume
first, with a fresh resume command ID under that new epoch. That is the same
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
| `loopex attach` roles, one-shot control, `--after`, renewal loss, `session_dormant` at attach, explicit release on every exit path, reconnect and re-acquisition | `docs/operator/daemon.md`, attaching section |

<a id="technical-plan-lifecycle"></a>
### Daemon Lifecycle and Orderly Shutdown

Concept: [Scope](M5.md#concept-plan-scope).

Outcome 1 requires that an orderly stop and an abrupt death both leave only
what the journal proves. That is a claim about a sequence, so the sequence is
written out rather than left implied by the words "foreground process".

**Startup, in order.** Resolve root and socket path; open the Store and
acquire the writer marker, with `recover_stale_writer: true` and the three
holder outcomes ADR 0032 fixes; read the session directory and build the
index, refusing at the recorded-entry bound; create the `0700` subdirectory
and bind the `0600` socket, then read back and verify ownership and mode;
begin accepting; print the readiness line. A failure at any step exits
non-zero with that step's reason class and touches nothing after it — in
particular, a daemon that does not hold the marker never reads, unlinks or
binds the socket path.

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
  exit reason, so `store_lost`, `store_capacity_exceeded` and
  `supervision_fault` would be indistinguishable at exactly the moment the
  daemon must name one.

So `apps/loopex_daemon` has one top-level process, `Loopex.Daemon.Owner`, a
`GenServer` that traps exits and holds the links itself — the same pattern
`RuntimeOwner` already uses, for the same reason. It starts and links four
things, in this order:

| # | Child | Started how | What the owner keeps |
| --- | --- | --- | --- |
| 1 | The Store adapter | `Loopex.Store.Local.start_link/1` with the root and `recover_stale_writer: true` — the same call composition makes | The **pid**, so `{:EXIT, store_pid, reason}` identifies it and carries the store's own reason |
| 2 | The runtime | `Loopex.Runtime.start_link/1` | The `%Loopex.Runtime{}` **struct** — which is why this cannot be a supervisor child, and is fine for a process that simply holds it |
| 3 | The lease owner | The daemon's own, under ADR 0033 | Its pid |
| 4 | The listener | Bound and permission-checked last, so nothing accepts before the rest exists | Its pid |

**There is no restart strategy, because there are no restarts.** Every child is
`start_link`ed by the owner, and the owner's `handle_info({:EXIT, pid, reason}, state)`
clause is the whole failure rule: any linked exit, whatever the reason, is
fatal to the daemon instance. That clause is also the **reader** the
fatal-class map needs — it matches the pid against the four it holds,
classifies `reason`, and has the class in hand before anything else happens.
Nothing here is `rest_for_one`, `one_for_all` or `max_restarts`; those words
belonged to the withdrawn design and are gone.

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

**Daemon-initiated shutdown is the owner stopping its children, in reverse
order.** `SIGTERM` or `SIGINT` reaches the owner, which performs these four
steps itself. They are the owner's code, not a supervisor's behaviour, which
is what lets each one carry a reason and lets step 3 use a bound the owner
chooses.

1. **The listener stops first.** It stops accepting, so a new connection is
   refused rather than queued; it writes each open connection one
   `daemon.stopping` naming `operator_stop`, bounded best-effort as ADR 0032
   fixes — one write attempt into the existing 4 MiB output buffer — and
   closes it. Clients therefore learn *first*, before anything else is torn
   down, which is the right order for the one party that cannot see inside the
   daemon.
2. **The lease owner stops.** Every lease vanishes with it. Nothing durable is
   involved, and no client is left holding one, because no connection survived
   step 1.
3. **The runtime stops, and this is where admitted work ends.** The owner
   calls `Loopex.Runtime.stop/1` on the struct it kept, under its own bound:
   the **composed cleanup grace**, the same value the sessions were composed
   with, so no number is introduced. Work that settles within it settles
   normally. If the call has not returned when the grace elapses, the owner
   kills the runtime supervisor outright — `Process.exit(runtime.supervisor,
   :kill)`, the pid the struct exposes — which is **crash-equivalent by
   definition**: no terminal mutation is claimed, no `cancelled`, no
   `outcome_unknown`, no abort record. A mutation whose commit was ambiguous
   stays `commit_unknown` and fenced, and the reconciliation ADR 0006 and
   ADR 0018 already define settles it at the next activation — exactly as
   after an abrupt death.

   The owner can do this precisely *because* it is not a supervisor: there is
   no restart intensity for a deliberate kill to trip, and the exit it causes
   arrives at its own `{:EXIT, …}` clause, which knows this teardown is in
   progress and does not re-enter the fail-stop path.

   **The daemon supplies that bound rather than trusting the runtime's own,
   which is not one.** Core declares `shutdown: 5_000` for a session
   coordinator but `shutdown: :infinity` for an owner group — whose
   `terminate/2` itself calls `Supervisor.stop(workers, :shutdown,
   :infinity)` — and three of the runtime supervisor's children are
   supervisors, which default to `:infinity`. `Supervisor.stop/3` takes an
   `:infinity` call timeout by default. "5,000 ms for a coordinator" is not
   the bound of anything, and an earlier draft that claimed it was is
   withdrawn.
4. **The Store stops last**, and its `terminate/2` releases the writer marker
   — see the marker invariant in ADR 0031. Stopping it last is what makes the
   marker outlive every session operation that might still have needed it.
   Then the socket path is unlinked and the owner **exits `0`**.

One ordering consequence is worth stating because it reverses an earlier
draft: clients are told *before* work is drained, not after. That is
deliberate. The drain does not need connections to exist, and a client that
must reconnect elsewhere is better served by learning immediately than by
waiting out a cleanup grace it cannot see.

**Cancellation is not the daemon's to run**, which an earlier draft claimed.
It is the coordinator's, as part of a session's own durable command, and a
daemon-side cancellation path is precisely the second loop this milestone
forbids. Two alternatives were rejected with it. Host-authorized durable
aborts — the daemon admitting an abort per session on the way down — would
have the daemon issuing mutations on nobody's authority, at the moment it is
least able to see them through. An unbounded natural drain would make
`SIGTERM` unbounded, which is not a stop.

**Store loss, a fail-stop path.** The owner holds the Store's link and its
pid, so the adapter's termination arrives as `{:EXIT, store_pid, reason}` at
the owner's own clause, carrying the store's real reason. That clause is the
fatal-class map's reader: it matches the pid, classifies `reason` as
`store_capacity_exceeded` where that was the store's own refusal and
`store_lost` otherwise, and has the class in hand before it does anything
else. No link the owner does not already hold, no monitor to remember, and no
information lost on the way. Then, without the ordered sequence:

1. Refuse service immediately — no further admission, no further attach, and
   the listener closed.
2. Close every connection, after one bounded best-effort `daemon.stopping`
   carrying `store_lost`, or `store_capacity_exceeded` when the store's own
   reason was the capacity refusal.
3. Unlink the socket.
4. Exit non-zero with that class on `stderr`. **There is no "stop the Store"
   step**, because the Store already stopped and the marker is already
   released; the next daemon finds no marker to recover rather than a stale
   one. Nothing restarts the Store: the owner start_links its children and
   restarts none of them, so any linked exit is fatal by its own clause —
   which is why this path exists at all rather than being a restart.

Nothing durable is at risk in that ordering: whatever was ambiguous is
`commit_unknown` in the journal and is reconciled at the next activation, and
whatever was not committed was never promised.

**An abrupt death** — `SIGKILL`, power loss — runs neither path, and is safe
for the reasons the durability rules already give: nothing the journal does
not hold was ever promised, the marker left behind is reclaimed by the next
daemon's verified stale-writer recovery, and the socket file is a stale path
the next marker holder removes.

**The fatal-class map.** Every non-zero exit names one class on `stderr`:

| Class | When |
| --- | --- |
| `store_writer_active` | Startup: the marker is held by a live holder |
| `store_writer_unverifiable` | Startup: the marker's holder cannot be decided |
| `store_log_too_large` | Startup: the log is already past the capacity bound |
| `session_index_too_large` | Startup: the directory holds more than the index bound |
| `socket_path_too_long` | Startup: the path exceeds the derived `sun_path` bound |
| `socket_permission_unverified` | Startup: subdirectory or socket ownership/mode could not be verified |
| `store_lost` | Fail-stop: the Store terminated under a live listener |
| `store_capacity_exceeded` | Fail-stop: the Store terminated on the capacity refusal specifically |
| `supervision_fault` | Fail-stop: a lease owner failed, under ADR 0033's daemon-fatal rule. On the wire this is `fatal:supervision_fault`, since ADR 0032's `reason` set admits the fatal classes only under that prefix |

**The daemon's own log is bounded and redacted by the rules that already
exist.** Everything the daemon writes to `stderr` — refusals, warnings, the
fatal reason — is a bounded non-secret line under ADR 0029's discipline, and
carries no credential, no token, no model content, no tool argument or result,
and no artifact bytes, exactly as ADR 0030's metadata rule already forbids for
a trace or a telemetry span. Nothing here is a new logging plane: the daemon
has no diagnostic surface of its own beyond these lines and the records it
already sends on the wire, and the fatal-class map above is the whole
vocabulary of what an exit may say.

**Reverse cleanup.** Every startup failure *after* the marker is acquired
unwinds what it has done, in reverse: an unlinked-and-bound socket is closed
and its path unlinked, a created `daemon/` subdirectory it made is removed,
and the Store is stopped so its `terminate/2` releases the marker. A daemon
that refuses to start leaves no marker and no socket file behind, which is
what lets an operator fix the cause and try again without a recovery step.

**Witnesses**, all on real operating-system processes:

- **Idle shutdown.** A daemon with sessions activated and no work in flight
  receives `SIGTERM`, writes nothing further to `stdout`, closes every
  connection with the stop reason, unlinks the socket, releases the marker and
  exits `0`; the foreground server then opens the same root immediately, which
  is what proves the marker was actually released.
- **In-flight shutdown.** A daemon with a dispatched tool effect and an
  unresolved mutation receives `SIGTERM`. What has not settled within the
  cleanup grace is ended crash-equivalently, and the case asserts the negative
  that matters: **no terminal mutation is claimed** for it — no `cancelled`,
  no `outcome_unknown`, no abort record appears in the journal on the way
  down. The ambiguous mutation stays `commit_unknown`, every client receives
  the stop reason, and the exit is still `0`. Activating that session again
  afterwards resolves the transaction to exactly one outcome through the
  existing reconciliation, and the journal is byte-identical to what an
  abrupt death at the same instant would have left.
- **Store-loss fail-stop.** The Store is made to terminate under a live
  listener. The case asserts the daemon observed it, closed the listener and
  every connection with `store_lost`, unlinked the socket, and exited non-zero
  with that class on `stderr` — and that it did **not** attempt the ordered
  sequence, because the marker was already released by the Store's own
  `terminate/2` before the daemon could act. A second daemon starts on that
  root immediately with no stale marker to recover. The capacity variant
  reports `store_capacity_exceeded` instead.
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

| Boundary | Owner | What fails | Who observes it, and how | What the client sees | Durable / not durable |
| --- | --- | --- | --- | --- | --- |
| **Store ↔ daemon** | `loopex_store_local` owns the marker and the log; the **daemon owner process** holds the Store's link and pid | Append error, including the capacity refusal | The Store stops **itself** (`local.ex:251-270` answers `{:stop, reason, commit_unknown, state}`) and releases the marker in `terminate/2` (`local.ex:166`). The owner's `{:EXIT, store_pid, reason}` clause receives it **with the store's real reason**, which is what distinguishes `store_capacity_exceeded` from `store_lost` | `daemon.stopping` with `store_lost` or `store_capacity_exceeded`, one bounded attempt, then the socket closes | **Durable:** whatever committed. **Not:** the failed append; the in-flight transaction is `commit_unknown` and reconciles later |
| **Store ↔ daemon (startup)** | The adapter | Marker held, unverifiable, log too large | `WriterLock.acquire` refuses with `store_writer_active` / `store_writer_unverifiable`; `Log.open` refuses `store_log_too_large` (`log.ex:80-84`) | Nothing — no socket exists yet | **Not durable:** nothing was written. Reverse cleanup leaves no marker |
| **Core ↔ daemon: existence query** | `loopex` answers; the daemon asks | Root unreadable, malformed ID, unrecognised answer | The query's own closed result set — `present`, `absent`, `invalid_id`, `store_unavailable`, `unexpected` (this plan's new core operation) | The matching refusal, four of them distinct; nothing created, nothing attached, no lease | **Not durable:** the query writes nothing, proved by a byte-identical root |
| **Core ↔ daemon: attach** | `loopex` owns the cursor barrier, snapshot and queues | Barrier race, stale handle, queue overflow | Core's existing attach transaction and stale-handle checks; the daemon reads no coordinator state to repair a race | Snapshot then contiguous at-least-once events, or detachment at the last emitted cursor with a stable reason | **Durable:** the events. **Not:** the attachment, the window, the buffer |
| **Core ↔ daemon: resume** | `loopex` | Placement mismatch, unknown session, already-resolved command | Core's existing resume path and command idempotency (`control.ex:901-907` returns the historical result without starting an owner) | Core's refusal, forwarded unchanged | **Durable:** the resume command and its result |
| **Core ↔ daemon: commands** | `loopex` admits; the daemon forwards | **Coordinator death** | Core's `DynamicSupervisor` (`restart: :temporary`, `session_coordinator.ex:134-142`); `Control` consumes the `DOWN`, releases the fence and leaves the entry (`control.ex:821`). **No signal reaches the daemon, and none is owed** — the daemon supervises the runtime, not the coordinators beneath it | Core's existing refusal on the next command for that session, forwarded unchanged. `residency` still reads `active`, which remains true: this daemon did activate it | **Durable:** whatever committed before. **Not:** any claim about liveness |
| **Lease owner ↔ connections** | `loopex_daemon` | The per-session lease owner dies, taking the in-flight admission set with it | The owner's `{:EXIT, pid, reason}` clause, which treats any linked exit as fatal — ADR 0033's daemon-fatal rule, obtained from one clause rather than from a strategy | `daemon.stopping` with `fatal:supervision_fault`, then every connection closes; the daemon restarts uncontrolled | **Not durable:** the lease, the epoch, the in-flight set. The journal is untouched |
| **Lease owner ↔ connections (expiry)** | `loopex_daemon` | A holder stops renewing, or a mutation is unresolved at the deadline | The lease owner's own monotonic deadline; the in-flight set decides when a takeover is granted | The holder's next mutation refuses; a takeover is eligible at the deadline and granted when the in-flight set empties | **Not durable:** the lease. The mutation that was in flight settles or refuses exactly once |
| **Listener ↔ connections** | `loopex_daemon` | Foreign peer, malformed frame, over-long path, backpressure | Filesystem permission verified after bind, then the per-platform peer-credential read (`LOCAL_PEERCRED` / `SO_PEERCRED`), then ADR 0023's framing refusals; backpressure at the 4 MiB output buffer | Closed before initialize for a peer refusal; a stable framing reason otherwise; detachment at the last emitted cursor under backpressure | **Not durable:** connections, buffers, windows |
| **Registry ↔ sender ↔ custody** | The **host** owns the registry and custody; the adapter owns the sender. The token is bound at composition, resolved per invocation | No registry row, registry dead, custody dead, refusal, malformed reply, deadline | `route(handle, token)` answers `:unavailable`; custody answers one of the four atoms; the **guardian** enforces the deadline and kills the sender | The adapter's existing `Loopex.Model` refusal shape, with the atom in the bounded diagnostic | **Not durable:** nothing about credentials is ever journaled, and no span or record carries model `options` — the model span is a fixed identity map. The invocation's failure is durable |
| **CLI ↔ socket** | `loopex_cli` | Socket unreachable, refusal, transport loss, renewal failure | The client's own reconnect loop and its renewal timer | Reconnect at the retained cursor, deduplicating; a failed renewal drops to observer with the loss on `stderr`; a reconnecting controller must acquire again for a fresh epoch | **Durable:** nothing the client holds. The cursor is a client-side position |
| **Daemon ↔ OS: signals** | The operator | `SIGTERM` / `SIGINT` | The owner stops its children in reverse order itself — listener, lease owner, runtime, Store — calling `Runtime.stop/1` under the composed cleanup grace and killing `runtime.supervisor` on expiry | `daemon.stopping` with `operator_stop`, then close | **Durable:** whatever committed. **Not:** work ended crash-equivalently, for which no terminal is claimed |
| **Daemon ↔ OS: kill** | The operator | `SIGKILL`, power loss | Nothing runs — no handler, no `terminate/2` | The socket closes with no record at all | **Durable:** the journal. The marker is left for the next daemon's verified stale-writer recovery |
| **Daemon ↔ OS: socket file** | `loopex_daemon` | A stale `daemon.sock` from a dead daemon | Only the marker holder may unlink and rebind, so two starts resolve at the marker and never at the socket | The loser exits without touching the socket | **Not durable:** the socket file is a path, never state |
| **Daemon ↔ OS: marker** | `loopex_store_local` | Released in order, released early, or left behind | `terminate/2` in an orderly stop; `terminate/2` early on store loss; nothing on a kill | Nothing directly; the next daemon's start succeeds, succeeds, or recovers | **Not durable in the journal sense:** the marker is exclusion, not truth |

Three rows deserve their reading stated, because they are where earlier drafts
went wrong. The **coordinator death** row is the one that forced `residency`
to mean a daemon fact: there is no observer column entry available, so any
design that needed one was unimplementable. The **Store ↔ daemon** row is the
one that forced the fail-stop split: the marker is already released by the
time anything can act, so an ordered shutdown ending "stop the Store" had
nothing to stop. And that same row is why the daemon supervises its own tree:
an earlier draft filled its observer column with a link and a monitor the
daemon could not actually hold, because `LoopexComposition` takes the link in
a process it spawns and returns no adapter pid. Every observer cell in this
table is now a parent-child relationship the daemon itself establishes, or a
mechanism inside core with a line number, and nothing in between.

<a id="technical-plan-minimalism"></a>
### Proportional Minimalism Budget

Concept: [Scope](M5.md#concept-plan-scope).

The smallest sufficient system wins, and each addition below names what it
unifies and why direct code is insufficient. One application, because a
daemon is a host and a host is an application. One daemon owner process, one new public composition function — which unifies
the two callers that need the edges assembled, `RuntimeOwner` and the daemon's
owner, and which direct code cannot replace because the alternative is a
second copy of the whole wiring layer. One socket listener, one narrow
core concurrent-attachment change, one read-only core existence query — which
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
