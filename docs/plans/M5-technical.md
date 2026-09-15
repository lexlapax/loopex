<a id="technical-depth"></a>
## Technical depth

Concept: [Durable service](M5.md#concept).

<!-- loopex:plan-technical-envelope:start -->
## Normative Technical Envelope

<a id="technical-plan-prerequisites"></a>
### Prerequisites and Acceptance Points

Concept: [Scope](M5.md#concept-plan-scope).

Concept: [non-goals](M5.md#concept-plan-non-goals).

The Open M5 planning bytes were drafted on M4's accepted governance checkpoint
`6f973f774a403f76330058e3d0a59f7b83e038f1`, but inherited M1 and M2
gates were unavailable there. The M4-specific waiver and deferral do not
authorize this opening. M4 is Accepted and remains the sole implementation
authority; these M5 bytes confer none. Before M5 can be accepted, M4 must be
Closed and integrated; reconstruct M5's branch-only opening checkpoint on
that exact inherited-green product base, re-prove every inherited gate green
and its own distinct red on it, bind the generation-2 schema and vector
bytes, prove their fixture shape and digest integrity on both locked
toolchain pairs, and obtain fresh exact-SHA review.
At final acceptance all inherited gates are green and the M5 boundary remains
truthfully red for the missing daemon. No draft candidate from the unavailable
opening is eligible for acceptance or integration.

M5 accepts three decisions before dependent work:

| Decision | Owner and acceptance point | Effect |
| --- | --- | --- |
| [**ADR 0031**](../adr/0031-daemon-grade-store-selection-and-migration.md#concept) | Maintainer, before M5 acceptance; binds the local-adapter selection, its exact limits and the retirement procedure, and fixes the successor's selection procedure without running it | The existing local adapter as the daemon's store for `0.2.0`, with the 256 MiB log capacity, 4 MiB frame ceiling, full retention, `store_capacity_exceeded` refusal and root retirement documented; the daemon-grade adapter, its experiments and migration reserved for the successor |
| [**ADR 0032**](../adr/0032-daemon-attachment-residency-and-replay.md#concept) | Maintainer, before M5 acceptance; must bind every residency number below, the generation-2-only negotiation rule, the marker-first startup order and the `session.list` page contract | The Unix-domain-socket transport reusing ADR 0023 unchanged, generation 2's daemon methods, refusal of a generation-1-only client, owner-only peer access, the bounded socket path, race-free attach with at-least-once contiguous delivery, a resident window, daemon-owned output buffers, detachment at the last emitted cursor, idle eviction and bounded session pages |
| [**ADR 0033**](../adr/0033-collaboration-controller-lease-and-takeover.md#concept) | Maintainer, before M5 acceptance; must fix the lease terms below | One daemon-owned controller lease per session held in daemon memory with a fresh opaque writer epoch per grant, admission that binds the holder connection, held state, unexpired term and writer epoch, explicit takeover, cross-process abort through the core's own cancellation, and no authority from content, metadata or order |

ADR 0031's daemon-grade adapter, contract experiments and migration belong to
the successor milestone and bind nothing in M5; only its local-adapter
selection and documented limits are M5 prerequisites.

**Residency and lease profile (proposed, bound at acceptance).** 64
attachments per session and 512 per daemon, refused independently; a
1,024-durable-event core queue per attachment and a 4 MiB encoded-byte
daemon-owned socket output buffer per connection, detaching at the last
completely emitted cursor before the next event would exceed either bound; a
4,096-event and 16 MiB encoded-byte daemon-owned resident window per session
with store replay behind it, which on the local adapter always succeeds; 512
MiB total retained encoded durable-event bytes across all output buffers and
resident windows in one daemon, with pressure detached or evicted before that
total is exceeded; eviction after ten minutes without consumption, naming the
resumable cursor; `session.list` pages of at most 256 entries with an exact
continuation cursor; a thirty-second lease renewed every ten seconds,
takeover admitted at expiry with no further grace, release on orderly
disconnect; the ADR 0023 frame ceiling unchanged. These are retained-payload
ceilings, not an exact BEAM RSS promise. Measure and report actual process
RSS under the maximum attachment count and at payload pressure separately.

**Daemon launch inputs.** State root, socket path, placement identity, policy
module with identity and revision, provider, executor, ArtifactStore and
project resource snapshot are fixed when the daemon starts. No connection
replaces any of them; a client may select admitted resources and answer
interactions exactly as under M4, and may acquire control only through the
lease.

**Holder transactions.** M5 changes bytes that Closed gates bind in two
places, both after acceptance:

| Artifact | Holders | Restriction today | Planned change | Phase | Route and checks |
| --- | --- | --- | --- | --- | --- |
| `apps/loopex/lib/mix/tasks/loopex.deps_budget.ex`, `apps/loopex/test/deps_budget_test.exs`, `apps/loopex_daemon` | M1 (the application is unbound M5 product) | Ten-application inventory after M4; the daemon application absent | Eleven-application inventory, the daemon as a client-role application depending inward on core, protocol and composition, negative tests, and the minimal application in the same proposal | B | One Closed-M1 v2 proposal `A` carrying M1's next gate generation, both dependency-oracle artifacts and the minimal application, following the M1 Amendment 7 pattern M4's phase B reuses; review and accept `A`; governance-only `R` |
| `VERSION`, application versions, and every version-aware runner and verifier M4's closure made version-aware | M1, M2, M3, M4 | 0.1.0 after M4 closure | 0.2.0 | C | Separately approved version transition; v2 for Closed M1, M2, M3 and M4 in register order, then Accepted M5 last through its own v1 amendment and rebind |

`.tool-versions` is unchanged. The generation-2 schema and vectors are new
files; M4's bound generation-1 bytes are not touched, so M4 is not a holder
there. M5 adds no external dependency. Phase B and C bindings settle before
the rejoin or closure candidate that depends on them; closure cannot be
recorded while any is stale.

M4 owns interactions, transfers, the foreground server and observability; an
inherited defect is reproduced at the exact base and repaired at its owner,
and a daemon workaround cannot conceal it.

<a id="technical-plan-ownership"></a>
### Ownership, Decision Owners, and Rejoin Barriers

Concept: [Scope](M5.md#concept-plan-scope).

| Component | Owns | Cannot own |
| --- | --- | --- |
| `loopex` | Durable session truth, race-free attach barrier and cursor, independent concurrent attachments to the same session, the per-attachment event-count dispatcher queues, cancellation and recovery | A lease, a transport, a byte limit, residency policy or any daemon fact |
| `loopex_protocol` | Generation-2 DTOs, validators, schema and vectors | Daemon behaviour or lease semantics |
| `loopex_store_local` | The unchanged local adapter, its 256 MiB log and 4 MiB frame ceilings, its `store_capacity_exceeded` refusal and its writer marker, which the daemon holds for its process's lifetime | Any daemon fact, lease, index or residency state |
| `loopex_daemon` | Marker-first process and socket lifetime, peer-credential check, generation-2 negotiation, per-connection socket output buffers, the resident window and aggregate byte ceiling, attachment residency and eviction, the in-memory controller lease and writer-epoch check, the session index and its bounded pages, session stop, and diagnostics | Store or coordinator internals, a second loop, policy selection, host identity or any durable record |
| `loopex_app_server` | The foreground stdio server unchanged, sharing the protocol mapping the daemon reuses | Daemon lifetime or residency |
| `loopex_cli` | `loopex daemon`, `loopex attach`, `loopex sessions` and takeover presentation | Normative lease or session semantics |
| TypeScript consumer | Socket connection, observer following and takeover presentation | Normative semantics |

The ordered rejoin is prerequisite decisions → holder transaction for the one
minimal application → narrow core multi-attachment support → marker-first
daemon lifetime and socket over the local adapter → collaboration lease and
takeover → residency, replay and backpressure → two-process workflow with the
reference CLI and TypeScript consumer → integrated audit → independent
review. Prove lifetime, refusal of a second daemon at the marker, shutdown on
store loss, capacity refusal, reopening under the foreground server after an
orderly stop, independent simultaneous core attachments,
snapshot-then-contiguous delivery, stale-epoch refusal, takeover and
cross-process abort before the client workflow rejoins.

Use the existing command identity for every mutating method; request
identities never enter journals. `session.create` has no existing session or
epoch to authorize: it creates an uncontrolled session, after which a client
may attach before or after acquiring control, while `session.resume` requires
acquiring control first. Existing-session mutation requires control. The
lease record lives in the daemon's memory, keyed by session, for the daemon
process's lifetime; one owner process per session serializes its lease
transitions with its admission handoff, and a restart of that owner leaves
the session uncontrolled. For every existing-session mutation, the daemon
checks the requesting connection identity, current epoch, held state and
unexpired term together before forwarding to core; an epoch alone is not
authority, and every epoch is minted fresh at grant so no earlier value can
match. Attach reuses the runtime's cursor transaction; the core keeps
attachments independent and its event-count queues, while the daemon
buffers encoded output, evicts above it and never reads coordinator state.
Cross-process abort forwards the existing durable `session.abort` command;
no daemon-side cancellation path exists.

<a id="technical-plan-evidence"></a>
### Evidence Obligations and Mapping

Concept: [Outcomes](M5.md#concept-plan-outcomes).

| Outcome | Mandatory proof beyond a unit test |
| --- | --- |
| 1 | Real daemon process per state root; sessions progress with zero attachments; orderly stop releases the writer marker and records nothing false; abrupt kill followed by restart recovers every session under the same placement identity with no duplicate effect; simultaneous starts on one root resolve at the writer marker with exactly one listener and the loser never touching the socket; Store-child failure closes the listener and every connection before exit; a root driven to the 256 MiB log capacity refuses further mutation with `store_capacity_exceeded` while observers stay attached and an orderly stop still succeeds; `session.list` pages of at most 256 entries in session-ID order with an exact continuation cursor from the daemon index; after an orderly stop the foreground server and the reference CLI reopen the same root and resume a daemon-created session under the same placement identity with identical replay; session open and stop through the socket only |
| 2 | Raw-byte client over the socket negotiates generation 2 with the same schema digest and limits the foreground server negotiates for its generation, and a generation-1-only initialize is refused with nothing created; identical durable identities for the same command corpus through facade, foreground server and socket; foreign-uid peer refused before initialize; frame, fragment, malformed-input and over-long socket path refusals with distinct stable reasons; client disconnect recorded as transport loss with no cancellation and no interaction change |
| 3 | One lease per session in daemon memory with observers attached; connection identity, epoch, held state and unexpired term checked together before core admission or durable write, including a known current epoch sent by an observer; takeover only after release or expiry with a fresh epoch minted before the successor's first command; killed controller fenced and its late commands refused; the per-session lease owner crashing and restarting while the daemon and client sockets survive, with the previous holder's delayed command refused and no epoch ever reused; daemon restart leaving every session uncontrolled with every earlier epoch refused; controller abort cancelling work dispatched under an earlier process with a truthful cleanup outcome; no control from content, metadata, answers or attachment order |
| 4 | Several core attachments to one session remain independent when one detaches or backpressures; snapshot anchored at the committed sequence then contiguous at-least-once buffered and live delivery across the window boundary with no gap; slow observer detached at its last emitted cursor while the controller and other attachments continue; per-session and per-daemon limits refusing independently; idle eviction and reconnect with no missing durable event and any duplicate deduplicated by session ID, sequence and event ID; retained encoded bytes at or below the 4 MiB output buffer, 16 MiB window and 512 MiB aggregate ceilings enforced in the daemon-owned stages, separately exercising 512 attachments and maximum-sized output records, with observed process RSS recorded; progress coalesced or dropped with counted drops and no journal delay |
| 5 | From a fresh extraction of the exact source candidate, an operator follows the documented prerequisites and commands, supplies workspace, provider and policy inputs, starts the daemon, and drives one session from the reference CLI as controller and the TypeScript consumer as observer, kills the controller, takes over from the observer and aborts cross-process work; the attended real-provider selector runs from the extracted tree; every daemon boundary emits ADR 0030 spans and a daemon-scoped trace session captures identities only; every operator and developer documentation file receives an exact-source final documentation audit and independent finding disposition; the full gate's staged source archive of the exact candidate, with source `VERSION` exactly `0.2.0`, extracts, compiles and carries the attended workflow, and its report is retained |

The final documentation audit enumerates every tracked file beneath
`docs/operator/` and `docs/developer/` in the exact closure source tree,
including new, materially updated and reviewed-unchanged files. Retain one
row per file with path, source SHA, file SHA-256, role for its reader, audit
disposition and finding resolution. Inspect content for consistency with the
daemon, socket, controller and observer rules, residency, restart and
local-store limit behavior, the source-only `v0.2.0` release sequence,
current M5 information, relevance, working links and directory-index routing
where applicable, and stale foreground-only claims.
The exact seven-row Documentation Obligations table names required material
updates; this broader audit is required even for files outside that table.
Automated status and link checks contribute evidence but cannot replace the
per-file content judgment. The independent closure reviewer examines the
complete inventory and every finding disposition at the exact source SHA;
unresolved blocking or high-severity documentation findings block closure.

The opening runner binds one real behavioral red for outcomes 1 and 2. Local
positive controls prove same-VM attachment replay and cross-process recovery
after Store release. Its fixture then starts a separate daemon operating-system
process through
`Loopex.Daemon.start_link(state_root: root, runtime_options: runtime_opts)`;
the daemon alone owns the session Store and session. The fixture root is short
enough for ADR 0032's default `<state root>/daemon.sock`. Two independent
client processes use only ADR 0023 JSONL over that socket: the first
initializes generation 2, creates an uncontrolled session, attaches, acquires
control and commits a deterministic turn with its writer epoch; the second
initializes and attaches while the daemon still owns the session. Its
correlated snapshot has top-level `event_cursor` equal to
`snapshot.event_sequence`, at or beyond the committed tail. On the opening
base no daemon start or socket exists, so the declared behavior is red. Green
requires that daemon-owned socket path and those correlated protocol records
to complete. Second-daemon writer exclusion is proved separately under
Outcome 1. Before acceptance, bind
that real opening red, the exact selectors and witness names, the
generation-2 schema and vector bytes, the client interpreter pins, the exact
residency, encoded-byte and lease numbers and the fail-closed routing. After
acceptance, implement the daemon, the CLI commands and the consumer workflow;
every lane must pass before closure. A daemon that proxies several socket
connections to one replaceable core attachment cannot pass, because
independent concurrent attachments, lifetime with zero attachments, fencing
after a real kill and cross-process abort are required.

Every protected selector uses the existing authoritative standalone ExUnit
channel. Preserve the inherited repair manifest rather than re-listing old
case counts in this plan. The complete gate runs inherited predecessors,
protected selectors, whole suite, language clients and retained-evidence
validation, with M3-style checkpoint and full modes and one decisive named
witness per clause. Real provider cases live in separate files. Under the
same preparation rule M3 recorded, future test bodies are written with
implementation; a missing witness is never a pass.

Apply the M3 integrated audit and the M4 self-audit to the daemon, the socket,
the CLI commands and the recovery path. Test every lifetime, lease and
residency cut and each decoder-side negative at the receiver. Run actual
Darwin floor/current and Linux current lanes early. A repeated finding class
triggers a full adjacent-path audit. Final exact-source evidence and
independent review remain mandatory; no fixed review-round limit or
retry-to-green rule.

<a id="technical-plan-compatibility"></a>
### Compatibility

Concept: [Scope](M5.md#concept-plan-scope).

The `v0.2.0` source tag identifies a numbered release, not a compatibility
freeze. All surfaces remain experimental. The socket reuses ADR 0023's
framing, handshake, records and limits unchanged; generation 2 is additive
over generation 1's method set with the exact-generation rule, a
generation-1 client sees no daemon method and no lease field, the daemon
refuses a generation-1-only initialize, and the foreground server keeps
serving generation 1 unchanged. The private journal, its adapter and its
format are unchanged; the embedded API, public events, snapshots, artifact
formats and executor protocol are unchanged. Source VERSION is distinct from
protocol generation, provider build and schema digest.

<a id="technical-plan-migration"></a>
### Migration and Rollback

Concept: [Scope](M5.md#concept-plan-scope).

No journal migration exists in M5. The daemon reads and writes the same local
log the M4 foreground server and CLI write, under the same placement
identity, so a state root moves between the daemon and the foreground
surfaces by stopping one and starting the other. Prove that an orderly daemon
stop releases the writer marker and that the foreground server and the CLI
then resume a daemon-created session with identical replay. A root that
reaches the local log's 256 MiB capacity is retired, not migrated: stop the
daemon, move the root aside, start a fresh root; a session in a retired root
is resumed only by reopening that root. Rollback is stopping the daemon:
removing it restores the M4 foreground server and CLI on the same root with
no durable dependency on residency, index or lease state. Restore floor,
version and inventory protections through governed transactions. No in-place
downgrade, installed-data migration or service-manager claim.

<a id="technical-plan-packaging"></a>
### Packaging

Concept: [Scope](M5.md#concept-plan-scope).

Add exactly one application: `loopex_daemon`, the eleventh, with role
`:client`, depending inward on core, protocol and composition and reusing the
foreground server's protocol mapping. The application inventory and role
rules in `loopex.deps_budget.ex` change under M1's transaction. M5 adds no
external dependency. No transport library, socket abstraction layer or
service-manager integration enters any application; the socket is the
runtime's own `gen_tcp` local address family.

Supply `loopex daemon`, `loopex attach` and `loopex sessions` in the
reference CLI, extend the TypeScript consumer to connect over the socket and
to follow and take over, and reuse the M4 Elixir and Python conformance
clients for generation 2. Pin Node and Python execution versions in
`scripts/fixtures/m5/client-toolchain.txt`; the runner verifies the pinned
executables before any client lane and reports absence or mismatch as
UNAVAILABLE. At the separately approved version transition set source
VERSION and application versions to 0.2.0; the full gate's report validator
accepts exactly `0.2.0` and nothing else. The full gate stages a tar source
archive from its exact committed candidate, extracts it outside the checkout,
compiles it, and runs the attended two-process selector from the extracted
tree following the operator guide; that staged, release-ready archive report
is the last Purpose obligation. Gate green and independent exact-SHA closure
review precede an explicit combined closure and release/tag disposition.
Record the closure transition under that authority, obtain its required
read-only exact-SHA review, and integrate that same reviewed commit to
`main` without rewrite. Release completion then follows closure: create one
annotated `v0.2.0` tag on precisely that integrated commit, and run the
post-tag check, which verifies the tag object is annotated, `v0.2.0^{commit}`
is the reviewed integration commit and is reachable from `main`, that
`git show <that commit>:VERSION` is exactly `0.2.0`, and that the source
archive was generated from that commit; retain the archive SHA-256, source
commit and tree, and tag object identity. That completion is required by
this plan and is not a closure condition. Do not move the tag or publish
packages, binaries, installers or service units.

<a id="technical-plan-minimalism"></a>
### Proportional Minimalism Budget

Concept: [Scope](M5.md#concept-plan-scope).

One application, one socket listener, one narrow core concurrent-attachment
change, one in-memory lease record and admission check, one resident window
and eviction policy, one per-connection output buffer, one session index
with bounded pages, three CLI commands and the consumer's socket mode
justify growth. No lease, transport, byte limit or residency policy in core;
no second loop, event dispatcher, cancellation path or protocol codec; no
transport registry, plugin socket layer, generic service framework, store
adapter, control store or durable daemon record; no daemon-side session
state beyond the lease, index and residency facts it holds in memory.
Implement lifetime, transport and collaboration once against the local
adapter. Raw line count is a review signal; behaviour and measured limits
govern.
<!-- loopex:plan-technical-envelope:end -->
