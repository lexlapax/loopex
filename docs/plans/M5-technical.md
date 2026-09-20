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
| [ADR 0031](../adr/0031-daemon-grade-store-selection-and-migration.md#concept) | Before the daemon opens a state root, so before workstream 1 lands | The existing local adapter as the daemon's store for `0.2.0`, with the 256 MiB log capacity, 4 MiB frame ceiling, full retention, `store_capacity_exceeded` refusal and operator root-retirement procedure documented; the daemon-grade adapter, its experiments and its migration reserved for the successor milestone |
| [ADR 0032](../adr/0032-daemon-attachment-residency-and-replay.md#concept) | Before the socket is bound or the core attachment change lands, so before workstreams 2 and 4 | The Unix-domain-socket transport reusing ADR 0023 unchanged, generation 2's methods, refusal of a generation-1-only client, owner-only peer access, the bounded socket path, marker-first startup, race-free attach with at-least-once contiguous delivery, the resident window, daemon-owned output buffers, detachment at the last emitted cursor, idle eviction and bounded session pages, and every residency number below |
| [ADR 0033](../adr/0033-collaboration-controller-lease-and-takeover.md#concept) | Before any admission check is written, so before workstream 3 | One daemon-owned controller lease per session held in daemon memory with a fresh opaque writer epoch per grant, admission that binds holder connection, held state, unexpired term and epoch together, explicit takeover, cross-process abort through the core's own cancellation, and no authority from content, metadata or order |
| [ADR 0034](../adr/0034-provider-credential-handoff-over-bootstrap-channel.md#concept) | Before the adapter's credential resolution changes, so before workstream 5 | The credential as a per-invocation input resolved only inside the sender that writes the credential frame, after the child proves nonce, codec version and build manifest digest and before the invocation frame; no environment read in the adapter's call path; the re-pointed credential-plane proofs and the security review as acceptance points |

ADR 0031's daemon-grade adapter, its contract experiments and its migration
belong to the successor milestone and bind nothing in M5; only its
local-adapter selection and documented limits are M5 prerequisites.

M4 owns interactions, transfers, the foreground server and observability. An
inherited defect is reproduced at the exact base and repaired at its owner; a
daemon workaround cannot conceal one.

<a id="technical-plan-ownership"></a>
### Ownership, Decision Owners, and Rejoin Barriers

Concept: [Scope](M5.md#concept-plan-scope).

| Component | Owns | Cannot own |
| --- | --- | --- |
| `loopex` | Durable session truth, the race-free attach barrier and cursor, independent concurrent attachments to one session, the per-attachment event-count dispatcher queues, cancellation and recovery | A lease, a transport, a byte limit, residency policy or any daemon fact |
| `loopex_protocol` | Generation-2 records, validators, schema and vectors | Daemon behaviour or lease semantics |
| `loopex_store_local` | The unchanged local adapter, its 256 MiB log and 4 MiB frame ceilings, its `store_capacity_exceeded` refusal and its writer marker, which the daemon holds for its process's lifetime | Any daemon fact, lease, index or residency state |
| `loopex_daemon` | Marker-first process and socket lifetime, the peer-credential check, generation-2 negotiation, per-connection socket output buffers, the resident window and aggregate byte ceiling, attachment residency and eviction, the in-memory controller lease and writer-epoch check, the session index and its bounded pages, session stop, and diagnostics | Store or coordinator internals, a second loop, policy selection, host identity or any durable record |
| `loopex_app_server` | The foreground stdio server unchanged, sharing the protocol mapping the daemon reuses | Daemon lifetime or residency |
| `loopex_cli` | `loopex daemon`, `loopex attach`, `loopex sessions` and takeover presentation | Normative lease or session semantics |
| `loopex_llm_reqllm` | The credential handoff, its sender, the re-pointed credential-plane proofs and the provider suite's concurrency | Any host credential policy, any new credential scope, or anything outside the adapter |
| `clients/node` | Socket connection, observer following and takeover presentation for the independent client | Normative semantics |

**Rejoin order.** Prerequisite decisions, then the one new application and the
narrow core attachment change, then marker-first daemon lifetime and the
socket over the local adapter, then collaboration and takeover on that base,
then residency, replay and backpressure, then the two-process workflow with
the reference CLI and the independent Node client, then the documentation and
the source-archive proof, then independent review of the closure candidate.

Prove lifetime, refusal of a second daemon at the marker, shutdown on store
loss, capacity refusal, reopening under the foreground server after an orderly
stop, independent simultaneous core attachments, snapshot-then-contiguous
delivery, stale-epoch refusal, takeover and cross-process abort before the
client workflow rejoins. Workstream 5, the credential handoff, is independent
of every other workstream: it touches `apps/loopex_llm_reqllm` and the host
composition sites that read the credential variable, shares no file with the
daemon work, and may land at any point after ADR 0034 is accepted.

Parallel writers take one worktree each over these non-overlapping paths, and
one integrator owns rejoin, conflicts and post-rejoin verification, as the
[milestone guide](../developer/milestones-technical.md#technical-milestones-develop)
sets out.

**Semantics the rejoin must preserve.** Use the existing command identity for
every mutating method; request identities never enter journals.
`session.create` has no existing session or epoch to authorize: it creates an
uncontrolled session, after which a client may attach before or after
acquiring control, while `session.resume` requires acquiring control first.
Existing-session mutation requires control. The lease record lives in the
daemon's memory, keyed by session, for the daemon process's lifetime; one
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

| Outcome | What must be proved, beyond ordinary unit tests |
| --- | --- |
| 1 | A real daemon operating-system process per state root. Sessions progress with zero attachments. An orderly stop releases the writer marker and records nothing false; an abrupt kill followed by restart recovers every session under the same placement identity with no duplicate effect. Simultaneous starts on one root resolve at the writer marker with exactly one listener and the loser never touching the socket. Store-child failure closes the listener and every connection before exit. A root driven to the 256 MiB log capacity refuses further mutation with `store_capacity_exceeded` while observers stay attached and an orderly stop still succeeds. `session.list` returns pages of at most 256 entries in session-ID order with an exact continuation cursor from the daemon index. After an orderly stop the foreground server and the reference CLI reopen the same root and resume a daemon-created session under the same placement identity with identical replay. Session open and stop through the socket only |
| 2 | A raw-byte client over the socket negotiates generation 2 with the same schema digest and limits the foreground server negotiates for its own generation, and a generation-1-only initialize is refused with nothing created. Identical durable identities for the same command corpus through facade, foreground server and socket. A foreign-uid peer refused before initialize. Frame, fragment, malformed-input and over-long socket path refusals with distinct stable reasons. A client disconnect recorded as transport loss with no cancellation and no interaction change. The generation-2 vectors are literal bytes with literal verdicts, held beside generation 1's in `apps/loopex_protocol/test/public_schema_conformance_test.exs`, never values generated from the implementation they check |
| 3 | One lease per session in daemon memory with observers attached. Connection identity, epoch, held state and unexpired term checked together before core admission or any durable write, including a known current epoch sent by an observer. Takeover only after release or expiry, with a fresh epoch minted before the successor's first command. A killed controller fenced and its late commands refused. The per-session lease owner crashing and restarting while the daemon and the client sockets survive, with the previous holder's delayed command refused and no epoch ever reused. A daemon restart leaving every session uncontrolled with every earlier epoch refused. A controller abort cancelling work dispatched under an earlier process with a truthful cleanup outcome. No control from content, metadata, answers or attachment order. Forward and backward wall-clock jumps changing neither live admission nor takeover timing |
| 4 | Several core attachments to one session remain independent when one detaches or backpressures. A snapshot anchored at the committed sequence, then contiguous at-least-once buffered and live delivery across the window boundary with no gap. A slow observer detached at its last emitted cursor while the controller and the other attachments continue. Per-session and per-daemon limits refusing independently. Idle eviction and reconnect with no missing durable event, any duplicate deduplicated by session ID, sequence and event ID. Retained encoded bytes at or below the 4 MiB output buffer, 16 MiB window and 512 MiB aggregate ceilings, enforced in the daemon-owned stages, exercising 512 attachments and maximum-sized output records separately, with observed process RSS recorded beside the ceilings. Progress coalesced or dropped with counted drops and no journal delay |
| 5 | From a fresh extraction of the exact candidate — staged with `git archive`, extracted and built outside the checkout — an operator follows the documented prerequisites and commands, supplies workspace, provider and policy inputs, starts the daemon, and drives one session from the reference CLI as controller and the Node client as observer, kills the controller, takes over from the observer and aborts cross-process work. The attended real-provider cases run from that extraction. Every daemon boundary emits its ADR 0030 spans and a daemon-scoped trace session captures identities only. `VERSION` in the extracted tree is exactly `0.2.0`. Every tracked file under `docs/operator/` and `docs/developer/` has been read against the candidate, including the ones M5 leaves unchanged, and each finding is resolved before the closure packet |
| 6 | The parent VM's environment holds no credential under the adapter's name, and no value equal to the credential in use, before, during or after a call — "during" observed from inside the call at child readiness. Two invocations with distinct credentials run at once and neither child, nor either child's diagnostics, observes the other's. Every re-pointed case of `apps/loopex_llm_reqllm/test/credential_plane_test.exs` passes with its assertion unchanged in meaning: version refusal and bootstrap refusal before any credential, late delivery after expiry impossible, rotation between invocations, two live credentials in one VM, sink loss, one child's loss not poisoning another, ordinary host messages and returned reasons, every child Logger form and metadata, and the four crash-report cases. The child-environment case in `m0_child_environment_conformance_test.exs` and the 65,536-byte ceiling case in `provider_retainer_boundaries_test.exs` carry over unchanged. A security review by someone other than the implementer is recorded. The provider suite's modules run concurrently and the measured duration is recorded beside the M4-closure baseline |

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
  spawn, control-pipe and cleanup shape the executor's has, so the touched
  cases run under `bash scripts/fixtures/pinned-load.sh` on a Linux host:
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
`scripts/fixtures/m4/client-toolchain.txt`. Each run's revision, platform,
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
`docs/developer/agent-context-map.md`, the indexes
`docs/operator/README.md`, `docs/developer/README.md`, `docs/README.md` and
`README.md`, and `CHANGELOG.md`. Outcome 6 adds the operator's credential
sentence and the developer note on host composition to the pages that describe
provider configuration. Every other tracked file under `docs/operator/` and
`docs/developer/` is read at the candidate and left unchanged only
deliberately.

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
framing, handshake, records and limits unchanged. Generation 2 is additive
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
for it supplies a credential reference with the call instead, and gets the
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

A root that reaches the local log's 256 MiB capacity is retired, not migrated:
stop the daemon, move the root aside, start a fresh root. A session in a
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
or service-manager integration enters any application; the socket is the
runtime's own `gen_tcp` local address family.

Supply `loopex daemon`, `loopex attach` and `loopex sessions` in the reference
CLI, and extend the client in `clients/node` to connect over the socket, to
follow as an observer and to take over. It stays a plain client with no build
step, package manifest or dependency, as the maintainer decided for M4 on
2026-09-15. The Node version stays pinned in
`scripts/fixtures/m4/client-toolchain.txt` and `scripts/check-release.sh`
continues to verify it before any client runs; the release check's application
list gains `loopex_daemon` in the same change that adds its release cases.

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
core concurrent-attachment change, one in-memory lease record and one
admission check, one resident window and eviction policy, one per-connection
output buffer, one session index with bounded pages, three CLI commands and
the Node client's socket mode. Outcome 6 adds no module and no abstraction: it
changes where one value is resolved and deletes an environment read.

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
| Log capacity per state root | 256 MiB, refused as `store_capacity_exceeded` | ADR 0031 |
| Frame ceiling on any single store record | 4 MiB | ADR 0031 |
| Retention and replay | Full history, no compaction, full replay at open | ADR 0031 |
| Attachments per session | 64 | ADR 0032 |
| Attachments per daemon | 512 | ADR 0032 |
| Core event-count queue per attachment | 1,024 events | ADR 0032 |
| Daemon socket output buffer per connection | 4 MiB encoded | ADR 0032 |
| Resident window per session | 4,096 events and 16 MiB encoded | ADR 0032 |
| Aggregate retained encoded events per daemon | 512 MiB | ADR 0032 |
| Idle time before eviction | 10 minutes | ADR 0032 |
| `session.list` page | at most 256 entries, `limit` in 1 to 256 | ADR 0032 |
| Socket path bound | the platform's, 104 bytes on Darwin and 108 on Linux, refused at start as `socket_path_too_long` | ADR 0032 |
| Protocol frame ceiling on the wire | unchanged from ADR 0023 | ADR 0032 |
| Lease term | 30 seconds | ADR 0033 |
| Lease renewal interval for the reference clients | 10 seconds | ADR 0033 |
| Takeover grace beyond expiry | none | ADR 0033 |
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
