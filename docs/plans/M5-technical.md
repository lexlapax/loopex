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
| [ADR 0034](../adr/0034-provider-credential-handoff-over-bootstrap-channel.md#concept) | Before the adapter's credential resolution changes, so before workstream 5's credential item | The credential as a per-invocation input named by an opaque token, routed by a host-owned registry that holds routing only, resolved from a host-owned custody process only inside the sender that writes the credential frame, after the child proves nonce, codec version and build manifest digest and before the invocation frame; custody and registry ownership, rotation, the guardian-enforced deadline, `:unavailable` on lost custody or registry with no reconstruction, and every failure outcome; no credential environment read anywhere in the adapter's library tree, with `provider_bridge` reading none at all and the launcher's ADR 0019 scrubbing enumeration kept exactly where it is, which is what leaves ADR 0019 unamended; the re-pointed credential-plane proofs and the security review as acceptance points |

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
| `loopex_store_local` | The unchanged local adapter, its 256 MiB log and 4 MiB frame ceilings, its `store_capacity_exceeded` and `store_log_too_large` refusals and its writer marker, which the daemon holds for its process's lifetime | Any daemon fact, lease, index or residency state |
| `loopex_daemon` | Marker-first process and socket lifetime, existence validation by calling core's query rather than by attaching or resuming, the peer-credential check, generation-2 negotiation, per-connection socket output buffers, the resident window and aggregate byte ceiling, attachment residency and eviction, the in-memory controller lease and writer-epoch check, the session index with its recorded-entry bound and its bounded pages, attachment residency and the one-way activation ceiling, and diagnostics | Store or coordinator internals, a second loop, policy selection, host identity, a durable record or a durable method |
| `loopex_app_server` | The foreground stdio server unchanged, sharing the protocol mapping the daemon reuses | Daemon lifetime or residency |
| `loopex_cli` | `loopex daemon`, `loopex attach`, `loopex sessions` and takeover presentation | Normative lease or session semantics |
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
| Host composition — `apps/loopex_composition`, `apps/loopex_app_server/lib/loopex_app_server/host.ex`, `apps/loopex_cli` | The credential item makes every host compose a routing registry and a custody process, pass a token with the call and delete the operator's variable; the daemon *is* a new host composed the same way, and `host.ex:221` is where the variable is read today |
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
handoff, and a restart of that owner leaves the session uncontrolled. For
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
| 1 | `apps/loopex_daemon/test/session_lifetime_test.exs` | A real daemon operating-system process per state root. An active session progresses with zero attachments. An orderly stop releases the writer marker and records nothing false; an abrupt kill followed by restart activates nothing, then activates each session the root records when a client reaches for it, under the same placement identity and with no duplicate effect. The restart proves the marker path explicitly: the daemon opens with `recover_stale_writer: true`, a marker whose holder is proved dead is reclaimed, a marker whose holder is alive refuses with `store_writer_active`, and a marker whose holder cannot be decided refuses with `store_writer_unverifiable` — all three before the socket path is read, unlinked or bound. Simultaneous starts on one root resolve at the writer marker with exactly one listener and the loser never touching the socket. Store-child failure closes the listener and every connection before exit. A root driven to the 256 MiB log capacity refuses the append with `store_capacity_exceeded`, the store terminates, the caller sees `commit_unknown`, and the daemon closes the listener and every connection and exits naming the capacity with nothing committed lost; a root whose log is already past that bound is refused at open with `store_log_too_large` rather than opened and truncated. `session.list` returns pages of at most 256 entries in session-ID order with an exact continuation cursor from the daemon index, carrying only session identity, recorded placement identity, `residency` and `controlled`. A session committed to the Store whose directory entry was never written — injected at that exact cut — is absent from the listing, still reachable by ID, and present in every listing after the activation that records it. A detached long-running command and a pending admission each cross the idle deadline with every client gone and run to completion, proving dormancy releases attachments and never a coordinator. The activation ceiling refuses the 65th activation of a daemon lifetime with its stable reason and the restart remedy; a root whose directory exceeds the recorded-entry bound refuses at start; at that bound a session reached by ID is activated and not recorded and the listing carries `index_full`; a session committed to the Store whose directory entry was never written is recovered both by its ID — validated through core's read-only existence query, with the case asserting the validation itself created no attachment and no durable record — and, by a client that never saw the ID, through the create command's durable `command_id` returning the historical result rather than a second session; an unknown ID answers negative from that query with nothing created, nothing attached and no lease granted; a directory write that fails during activation is reported to that client, leaves the session usable, and is retried at the next activation; a recorded session the daemon's composition cannot serve refuses at activation by name while every other session in the root activates. After an orderly stop the foreground server and the reference CLI reopen the same root and resume a daemon-created session under the same placement identity with identical replay. No durable method reaches the socket |
| 2 | `apps/loopex_daemon/test/socket_transport_test.exs`, `apps/loopex_protocol/test/public_schema_conformance_test.exs` | A raw-byte client over the socket negotiates generation 2 and receives generation 2's **own** exact schema digest, written out as a literal in the conformance module beside generation 1's and different from it by construction: `Loopex.Protocol.Session.schema_digest/0` is taken over the generation, the ordered methods, the ordered record families, the ordered error codes and the limits, and generation 2 changes the first two, so a generation 2 that negotiated generation 1's digest would be reporting a contract it does not serve. Generation 1's bytes, digest, method inventory and limits are proved unchanged in the same module and at their own literals — the `3a17…08f4` schema digest, the schema file digest and the vectors file digest the conformance module already pins — so the generation-2 work is proved additive rather than asserted to be. A generation-1-only initialize is refused with nothing created. Identical durable identities for the same command corpus through facade, foreground server and socket. Owner-only peer access proved in both layers: the socket's `0700` daemon-owned subdirectory and `0600` socket mode read back after bind, a permissive subdirectory or socket mode refused at start, a subdirectory the daemon does not own refused, a path component below the root that it did not create refused — and a state root at the ordinary `0755` the foreground server creates it with accepted, not refused, because the daemon owns the subdirectory and never re-permissions the root — and an unreadable or undecodable peer credential closing the connection before initialize — all in the fast check, which needs no second user — with the real cross-uid refusal and the same-uid success proved on the release check's Linux lane. Frame, fragment, malformed-input and over-long socket path refusals with distinct stable reasons, the path cases binding at the derived bound and at one byte past it on each platform the release check runs. A client disconnect recorded as transport loss with no cancellation and no interaction change. The generation-2 vectors are literal bytes with literal verdicts, held beside generation 1's in `apps/loopex_protocol/test/public_schema_conformance_test.exs`, never values generated from the implementation they check |
| 3 | `apps/loopex_daemon/test/collaboration_test.exs` | One lease per session in daemon memory with observers attached. Connection identity, epoch, held state and unexpired term checked together before core admission or any durable write, including a known current epoch sent by an observer. Takeover only after release or expiry, with a fresh epoch minted before the successor's first command. A killed controller fenced and its late commands refused. A per-session lease owner killed while a mutation is in flight taking the listener, every connection and the daemon down with it, after which the restarted daemon holds no lease and the previous holder's delayed command is refused on both the holder and the epoch check. A daemon restart leaving every session uncontrolled with every earlier epoch refused. A controller abort cancelling work dispatched under an earlier process with a truthful cleanup outcome. The expiry linearization: a mutation blocked inside core across the deadline settles under its own lease while the eligible takeover waits and is granted only after it resolves; the holder's next mutation refused at the deadline; the acquiring request refusing with its stable reason when its own deadline elapses first; and the holder disconnecting while a mutation is in flight — in every case exactly one of settle or refuse, never both. No control from content, metadata, answers or attachment order. Forward and backward wall-clock jumps changing neither live admission nor takeover timing |
| 4 | `apps/loopex/test/concurrent_attachments_test.exs`, `apps/loopex/test/session_existence_query_test.exs`, `apps/loopex_daemon/test/replay_residency_test.exs` | Core's read-only session-existence query answers plain data for a session that exists and for one that does not, from a fresh process against a real root, and is proved to create no attachment, no incarnation, no durable record and no Store write: the root's journal and session directory are byte-identical before and after a run of queries, including for unknown IDs. Several core attachments to one session remain independent when one detaches or backpressures. A snapshot anchored at the committed sequence, then contiguous at-least-once buffered and live delivery across the window boundary with no gap. Core is the only replay owner: every delivery case runs a second time with the daemon's resident window disabled and a third with it dropped mid-stream, all three byte for byte identical, so the window is proved to establish no snapshot and no cursor. Aggregate reclamation follows the fixed order ADR 0032 sets — zero-attachment windows by ascending last delivery, then the furthest-behind session's window, then detachment — including the case where zero-attachment windows alone consume the ceiling. A slow observer detached at its last emitted cursor while the controller and the other attachments continue. Per-session and per-daemon limits refusing independently. Idle eviction and reconnect with no missing durable event, any duplicate deduplicated by session ID, sequence and event ID. Retained encoded bytes at or below the 4 MiB output buffer, 16 MiB window and 512 MiB aggregate ceilings, enforced in the daemon-owned stages, exercising 512 attachments and maximum-sized output records separately, with observed process RSS recorded beside the ceilings. Progress coalesced or dropped with counted drops and no journal delay |
| 5 | `apps/loopex_daemon/test/multi_client_workflow_test.exs`, `apps/loopex_daemon/test/external_socket_workflow_test.exs`, `docs/evidence/M5-closure-runs.md` | From a fresh extraction of the exact candidate — staged with `git archive`, extracted and built outside the checkout — an operator follows the documented prerequisites and commands, supplies workspace, provider and policy inputs, starts the daemon, and drives one session from the reference CLI as controller and the Node client as observer, kills the controller, takes over from the observer and aborts cross-process work. The documented CLI build and the provider companion build both run inside that extraction, on the archive-carried source identity rather than on `.git`, with the missing, unsubstituted-or-malformed, changed-during-build and mismatched-commit refusals each proved and the identity the build reports asserted equal to the commit the archive was staged from. The attended real-provider cases run from that extraction, against the escript it built there. The workflow drives ADR 0030's existing core spans end to end — command admission, commit, effect intent, publication, interaction, and the model, store, policy and executor port callbacks — with the same bounded identity metadata an embedded caller produces, and no event outside that closed inventory is emitted by anything M5 adds. Daemon-internal functions are proved by the daemon's own tests and logs: `Loopex.Trace` traces only processes the runtime owns, flagged with `set_on_spawn` from the runtime's supervisor, and the daemon's listener, connections and lease owners are host processes above the runtime, so no trace-session witness is claimed for them. `VERSION` in the extracted tree is exactly `0.2.0`. Every tracked file under `docs/operator/` and `docs/developer/` has been read against the candidate, including the ones M5 leaves unchanged, recorded as a checklist derived at that commit — `git ls-files -- ':(glob)docs/operator/**/*.md' ':(glob)docs/developer/**/*.md'`, sorted, one row per path, each row marked *updated* or *reviewed unchanged* — retained with the closure runs. The pathspec glob magic is load-bearing and was checked rather than assumed: without `:(glob)`, git's default pathspec treats `**` as an ordinary wildcard that does not cross directory separators the same way and the command returns **no paths at all**, which would have made the gate pass vacuously. With it, the command returns 26 tracked files as of this revision — 18 under `docs/developer/` and 8 under `docs/operator/` — and the closure checklist states the count it derived so a reviewer can see the list was not empty, with every path in the tree present, no row unmarked, and each finding named and resolved before the closure packet |
| 6 | `apps/loopex_llm_reqllm/test/credential_plane_test.exs`, `apps/loopex_llm_reqllm/test/adapter_test.exs`, `apps/loopex_llm_reqllm/test/provider_retainer_boundaries_test.exs`, `docs/evidence/M5-closure-runs.md` | From the completion of a reference host's composition onward, the parent VM's environment holds no credential under the adapter's name and no value equal to the credential in use, before, during or after a call — "during" observed from inside the call at child readiness; composition is proved to read the operator's variable once and delete it. Every row of ADR 0034's failure table resolves to its closed-set atom and retains no copy: absent reference, malformed reference, a resolver module without the callback, each of `:missing`, `:expired`, `:oversized` and `:unavailable`, a term outside the closed set reported as `:unavailable`, and a resolver silent past the deadline instant reported as `:timeout` and asserted distinct from every refusal, so the guardian can tell a refusal from a silence. Two resolutions in flight at once is a success case, not a refusal: both invocations complete with their own credentials. The one permitted credential-bearing message — the custody process's reply to the sender — is proved redacted under a trace session at the `arguments` level, which shows placeholders and no credential bytes. Two invocations with distinct credentials run at once and neither child, nor either child's diagnostics, observes the other's. Every re-pointed case of `apps/loopex_llm_reqllm/test/credential_plane_test.exs` passes with its assertion unchanged in meaning: version refusal and bootstrap refusal before any credential, late delivery after expiry impossible, rotation between invocations, two live credentials in one VM, sink loss, one child's loss not poisoning another, ordinary host messages and returned reasons, every child Logger form and metadata, and the four crash-report cases. The child-environment witness inside the version-refusal and bootstrap-refusal cases — the child's recorded `entry-env` marker refuting `Adapter.credential_variable()` — holds unchanged. The 65,536-byte ceiling case in `provider_retainer_boundaries_test.exs` is re-pointed too, because that module delivers its credential through `System.put_env` in its `setup` and again in the case body; it supplies the oversized value as that invocation's reference instead. The drift-protection case in `adapter_test.exs` survives strengthened, with an exact allowlist: `[]` for `provider_bridge.ex`, the arity-zero enumeration and only that for `provider_launcher.ex` because it is ADR 0019's first-image scrubbing rather than a credential read, `provider_worker.ex`'s two non-secret crash-dump names, and `[]` everywhere else. Because the launcher's read survives, the case also asserts its *use*: the enumeration's result flows only into the Port's removal list, every name is mapped to `false`, none is compared against `credential_variable/0`, and no value reaches the sender, the frame or any caller. Its scan is widened from one `System.get_env(...)` expression to every route an environment read can be written — `System.get_env/0`, `/1` and `/2`, `System.fetch_env/1` and `fetch_env!/1`, `:os.getenv/0`, `/1` and `/2`, `:os.env/0`, and indirect application through `apply/3` or a captured function — each unpinned route refuted outright. The `req_llm` move to `~> 1.24.0` — pinned to that minor, not to `~> 1.24`, so the reviewed diff is the version actually built against — lands as its own reviewed change before the credential change, with the reviewed changelog diff across the intervening releases named in the commit, the adapter and streaming-conformance suites green, and the *existing* real-provider case at closure run against it. It adds no call path: nothing in M5 calls anything `1.24.0` makes newly reachable, and no second provider, second credential or new release-check case enters this milestone. It is explicit M5 scope, separate from ADR 0035 and not conditional on it. A security review by someone other than the implementer is recorded. The twelve modules are then converted to run concurrently one at a time, each kept only while its application's suite stays green, any module that stays serial keeping its reason beside it, and the measured duration is recorded beside the M4-closure baseline as evidence about the change rather than a threshold |

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
`bash scripts/check-release.sh` runs once on the current pair with the
provider credential and the pinned Node version in
`scripts/fixtures/m4/client-toolchain.txt`. That release check is where
Outcome 2's cross-UID witness lives, and closure is bound to it: the Linux
lane must record a connection from a foreign uid refused before initialize and
one from the daemon's own uid accepted. The fast check cannot supply it,
because it has no second user, so an absent Linux-lane result is missing
evidence rather than a pass. `loopex_daemon` joins that
script's `release_apps` list in the change that adds its first release case,
and only that list: every `release_apps` lane already runs
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

Supply `loopex daemon`, `loopex attach` and `loopex sessions` in the reference
CLI, and extend the client in `clients/node` to connect over the socket, to
follow as an observer and to take over. It stays a plain client with no build
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

<a id="technical-plan-minimalism"></a>
### Proportional Minimalism Budget

Concept: [Scope](M5.md#concept-plan-scope).

The smallest sufficient system wins, and each addition below names what it
unifies and why direct code is insufficient. One application, because a
daemon is a host and a host is an application. One socket listener, one narrow
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
| Credential frame cap | 69,632 bytes | ADR 0019, unchanged by ADR 0034 |

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
