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
After M4 closes and the refreshed M5 branch-only opening gate checkpoint is
established, but before ADR 0031 or M5 acceptance, the two store candidates
run under explicit bounded maintainer authorization in separate disposable
branches or task roots. Their code and dependencies do not join the Open M5
candidate or the product branch. Retain the exact candidate source identities,
commands, shared conformance and fault results, fixture identities and
comparison with the ADR 0031 decision. These experiments grant no M5 product
implementation authority.
At final acceptance all inherited gates are green and the M5 boundary remains
truthfully red for the missing daemon. No draft candidate from the unavailable
opening is eligible for acceptance or integration.

M5 accepts three decisions before dependent work:

| Decision | Owner and acceptance point | Effect |
| --- | --- | --- |
| [**ADR 0031**](../adr/0031-daemon-grade-store-selection-and-migration.md#concept) | Maintainer, before M5 acceptance; both candidates run the shared conformance and fault-injection suites as isolated, disposable contract experiments after M4 closes, before this decision is accepted | The daemon-grade session-store adapter behind the unchanged private ports, its one-way import from an M4 local log with interrupted-migration recovery, the exact M4 binary's safe refusal of a daemon root, and backup and restore |
| [**ADR 0032**](../adr/0032-daemon-attachment-residency-and-replay.md#concept) | Maintainer, before M5 acceptance; must bind every residency number below | The Unix-domain-socket transport carrying ADR 0023 unchanged, generation 2's daemon methods, owner-only peer access, the bounded socket path, race-free attach with a resident window, bounded queues, detachment at the last emitted cursor, idle eviction and `cursor_expired` |
| [**ADR 0033**](../adr/0033-collaboration-controller-lease-and-takeover.md#concept) | Maintainer, before M5 acceptance; must fix the lease terms below and generation-1 exclusion | One daemon-owned controller lease per generation-2 session in a separate durable runtime-control store surface, admission that binds the holder connection, held state, unexpired term and writer epoch, explicit takeover with a durable epoch advance, generation-1 exclusive session access, cross-process abort through the core's own cancellation, and no authority from content, metadata or order |

**Residency and lease profile (proposed, bound at acceptance).** 64
attachments per session and 512 per daemon, refused independently; a
1,024-durable-event and 4 MiB encoded-byte queue per attachment, detaching
at the last completely emitted cursor before the next event would exceed
either bound; a
4,096-event and 16 MiB encoded-byte resident window per session with store
replay behind it and `cursor_expired` beyond retained history; 512 MiB total
retained encoded durable-event bytes across all attachment queues and resident
windows in one daemon, with pressure detached or evicted before that total is
exceeded; eviction after ten minutes without consumption, naming the
resumable cursor; a thirty-second lease renewed every ten seconds, takeover
admitted at expiry with no further grace, release on orderly disconnect; the
ADR 0023 frame ceiling unchanged. These are retained-payload ceilings, not
an exact BEAM RSS promise. Measure and report actual process RSS under the
maximum attachment count and at payload pressure separately.

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
| `apps/loopex/lib/mix/tasks/loopex.deps_budget.ex`, `apps/loopex/test/deps_budget_test.exs`, `apps/loopex_daemon`, `apps/loopex_store_daemon` | M1 (the applications are unbound M5 product) | Ten-application inventory after M4; both applications absent | Twelve-application inventory, the daemon as a client-role application depending inward on core, protocol and composition, the store adapter in the local adapter's role depending inward on core, negative tests, and the minimal two applications in the same proposal | B | One Closed-M1 v2 proposal `A` carrying M1's next gate generation, both dependency-oracle artifacts and the minimal applications, following the M1 Amendment 7 pattern M4's phase B reuses; review and accept `A`; governance-only `R` |
| `VERSION`, application versions, and every version-aware runner and verifier M4's closure made version-aware | M1, M2, M3, M4 | 0.1.0 after M4 closure | 0.2.0 | C | Separately approved version transition; v2 for Closed M1, M2, M3 and M4 in register order, then Accepted M5 last through its own v1 amendment and rebind |

`.tool-versions` is unchanged. The generation-2 schema and vectors are new
files; M4's bound generation-1 bytes are not touched, so M4 is not a holder
there. If the SQLite candidate is selected under ADR 0031, its NIF binding
joins the version train through the same M1 dependency-oracle transaction
and the release archive proof names its build; the native candidate adds no
dependency. Phase B and C bindings settle before the rejoin or closure
candidate that depends on them; closure cannot be recorded while any is
stale.

M4 owns interactions, transfers, the foreground server and observability; an
inherited defect is reproduced at the exact base and repaired at its owner,
and a daemon workaround cannot conceal it.

<a id="technical-plan-ownership"></a>
### Ownership, Decision Owners, and Rejoin Barriers

Concept: [Scope](M5.md#concept-plan-scope).

| Component | Owns | Cannot own |
| --- | --- | --- |
| `loopex` | Durable session truth, race-free attach barrier and cursor, independent concurrent attachments to the same session, dispatcher queues, cancellation and recovery | A lease, a transport, residency policy or any daemon fact |
| `loopex_protocol` | Generation-2 DTOs, validators, schema and vectors | Daemon behaviour or lease semantics |
| `loopex_store_daemon` | A separate durable daemon-control surface for atomic lease records, usable alongside the local session adapter before the selected daemon-grade session adapter rejoins; then that adapter, its root manifest, snapshots, index, migration ledger, backup and restore | Public data model, session semantics or authority |
| `loopex_daemon` | Process and socket lifetime, peer-credential check, generation negotiation, attachment residency and eviction, the controller lease and writer-epoch check, session list and stop, and diagnostics | Store or coordinator internals, a second loop, policy selection, host identity |
| `loopex_app_server` | The foreground stdio server unchanged, sharing the protocol mapping the daemon reuses | Daemon lifetime or residency |
| `loopex_cli` | `loopex daemon`, `loopex attach`, `loopex sessions` and takeover presentation | Normative lease or session semantics |
| TypeScript consumer | Socket connection, observer following and takeover presentation | Normative semantics |

The ordered rejoin is prerequisite decisions → holder transaction for the two
minimal applications → narrow core multi-attachment support and the separate
durable daemon-control store surface → daemon lifetime and socket over the
local session adapter → collaboration lease and takeover → residency, replay
and backpressure → selected daemon-grade session adapter and migration →
two-process workflow with the reference CLI and TypeScript consumer →
integrated audit → independent review. Prove lifetime, refusal of a second
daemon, independent simultaneous core attachments, snapshot-then-contiguous
delivery, stale-epoch refusal, takeover and cross-process abort before the
session adapter rejoins. The early lease surface is already durable and is
reproved unchanged after the adapter rejoin.

Use the existing command identity for every mutating method; request
identities never enter journals. Generation-2 `session.create` has no existing
session or epoch to authorize: it creates an uncontrolled session, after which
a client may attach before or after acquiring control, while `session.resume`
requires acquiring control first. Existing-session mutation requires control.
The lease record is
atomically compared and committed through the separate daemon-control store
surface, not the session
Store ports or journal. Its storage works with the local adapter during the
first integration stages and survives daemon restart. For every generation-2
existing-session mutation, the daemon checks the requesting connection
identity, current epoch, held state and unexpired term together before
forwarding to core; an epoch alone is not authority. Generation-1 clients
keep their wire contract, but one connection obtains an internal exclusive
lease before attach or resume enters core and excludes every other connection
from that session. A session with generation-2 attachments or an unexpired
held lease excludes generation 1. Attach reuses the runtime's cursor
transaction; the core keeps attachments independent, while the daemon buffers
and evicts above it and never reads coordinator state. Cross-process abort
forwards the existing durable `session.abort` command; no daemon-side
cancellation path exists.

<a id="technical-plan-evidence"></a>
### Evidence Obligations and Mapping

Concept: [Outcomes](M5.md#concept-plan-outcomes).

| Outcome | Mandatory proof beyond a unit test |
| --- | --- |
| 1 | Real daemon process per state root; sessions progress with zero attachments; orderly stop releases the writer marker and records nothing false; abrupt kill followed by restart recovers every session under the same placement identity with no duplicate effect; a second daemon on the same root refused by the held marker; session list, open and stop through the socket only |
| 2 | Raw-byte client over the socket negotiates the same generation, schema digest and limits the foreground server negotiates; identical durable identities for the same command corpus through facade, foreground server and socket; foreign-uid peer refused before initialize; frame, fragment, malformed-input and over-long socket path refusals with distinct stable reasons; client disconnect recorded as transport loss with no cancellation and no interaction change |
| 3 | One durable lease per generation-2 session with observers attached; connection identity, epoch, held state and unexpired term checked together before core admission or durable write, including a known current epoch sent by an observer; takeover only after release or expiry with a durable epoch advance before the successor's first command; killed controller fenced and its late commands refused; exclusive generation-1 attachment and mixed-generation refusal, including a connected idle holder detached and fenced at expiry before successor access; controller abort cancelling work dispatched under an earlier process with a truthful cleanup outcome; no control from content, metadata, answers or attachment order; lease record surviving daemon restart and the session-adapter rejoin |
| 4 | Several core attachments to one session remain independent when one detaches or backpressures; snapshot anchored at the committed sequence then contiguous buffered and live delivery across the window boundary with no gap; `cursor_expired` with a fresh snapshot beyond retention; slow observer detached at its last emitted cursor while the controller and other attachments continue; per-session and per-daemon limits refusing independently; idle eviction and reconnect with no duplicate or missing durable event; retained encoded bytes at or below the 4 MiB queue, 16 MiB window and 512 MiB aggregate ceilings, separately exercising 512 attachments and maximum-sized output records, with observed process RSS recorded; progress coalesced or dropped with counted drops and no journal delay |
| 5 | Before acceptance, both ADR 0031 candidates run in isolated contract experiments through the shared conformance suite unchanged and fault fixtures at every commit cut; after acceptance the selected adapter repeats them, resolves commit ambiguity to one outcome and bounds replay on a hundred-thousand-record session; forward migration of a genuine M4 log with identical replay; interruption at each ledger step detected on reopen; the exact M4 binary refusing a daemon root with `store_file_invalid` without mutating it; backup and restore with every identity and sequence intact |
| 6 | From a fresh extraction of the exact source candidate, an operator follows the documented prerequisites and commands, supplies workspace, provider and policy inputs, starts the daemon, and drives one session from the reference CLI as controller and the TypeScript consumer as observer, kills the controller, takes over from the observer and aborts cross-process work; the attended real-provider selector runs from the extracted tree; every daemon boundary emits ADR 0030 spans and a daemon-scoped trace session captures identities only; every operator and developer documentation file receives an exact-source final documentation audit and independent finding disposition; after gate green, independent closure review, explicit combined closure and release/tag authority and integration, verify the annotated tag and source archive against the exact reviewed integrated closure commit and retain their identities and digest |

The final documentation audit enumerates every tracked file beneath
`docs/operator/` and `docs/developer/` in the exact closure source tree,
including new, materially updated and reviewed-unchanged files. Retain one
row per file with path, source SHA, file SHA-256, role for its reader, audit
disposition and finding resolution. Inspect content for consistency with the
daemon, socket, controller and observer rules, residency and store behavior,
the source-only `v0.2.0` release sequence, current M5 information, relevance,
working links and directory-index routing where applicable, and stale
foreground-only claims.
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
acceptance, implement the daemon, its store, the CLI commands and the
consumer workflow; every lane must pass before closure. A daemon that proxies
several socket connections to one replaceable core attachment cannot pass,
because independent concurrent attachments, lifetime with zero attachments,
fencing after a real kill and cross-process abort are required.

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
freeze. All surfaces remain experimental. Generation 2 is additive over
generation 1 with the exact-generation rule; a generation-1 client sees no
daemon method and no lease field. The daemon enforces one generation-1
connection per session and refuses simultaneous generation-1/generation-2 use
of that session, while leaving generation-1 wire records and methods
unchanged. The private
journal gains a second adapter and a format version; the embedded API, public
events, snapshots, artifact formats and executor protocol are unchanged.
Source VERSION is distinct from protocol generation, journal format version,
provider build and schema digest.

<a id="technical-plan-migration"></a>
### Migration and Rollback

Concept: [Scope](M5.md#concept-plan-scope).

Prove forward import of a genuine M4 local log, interrupted-migration
detection and completion or rollback on reopen, and the exact M4 binary's
safe `store_file_invalid` refusal when pointed at the daemon-grade root
directory, with no write to that root, plus backup and restore. Retain the original
log untouched as the rollback pair; restoring it is a copy, not a reverse
migration. Removing the daemon restores the M4 foreground server and CLI on
the local adapter with no durable dependency on residency or lease state.
Restore floor, version and inventory protections through governed
transactions. No in-place downgrade, installed-data migration or
service-manager claim.

<a id="technical-plan-packaging"></a>
### Packaging

Concept: [Scope](M5.md#concept-plan-scope).

Add exactly two applications: `loopex_daemon`, the eleventh, with role
`:client`, depending inward on core, protocol and composition and reusing the
foreground server's protocol mapping; and `loopex_store_daemon`, the twelfth,
in the local store adapter's role, depending inward on core only. The
application inventory and role rules in `loopex.deps_budget.ex` change under
M1's transaction. The native store candidate adds no external dependency; if
the SQLite candidate is selected, its NIF binding is the only addition and is
named in the release archive proof. No transport library, socket abstraction
layer or service-manager integration enters any application; the socket is
the runtime's own `gen_tcp` local address family.

Supply `loopex daemon`, `loopex attach` and `loopex sessions` in the
reference CLI, extend the TypeScript consumer to connect over the socket and
to follow and take over, and reuse the M4 Elixir and Python conformance
clients for generation 2. Pin Node and Python execution versions in
`scripts/fixtures/m5/client-toolchain.txt`; the runner verifies the pinned
executables before any client lane and reports absence or mismatch as
UNAVAILABLE. At the separately approved version transition set source
VERSION and application versions to 0.2.0. The full gate stages a tar source
archive from its exact committed candidate, extracts it outside the checkout,
compiles it, and runs the attended two-process selector from the extracted
tree following the operator guide. Gate green and independent exact-SHA
closure review precede an explicit combined closure and release/tag
disposition. Record the closure transition under that authority, obtain its
required read-only exact-SHA review, and integrate that same reviewed commit
to `main` without rewrite. Create one annotated `v0.2.0` tag on precisely
that integrated commit. A required post-tag check verifies the tag object is
annotated, `v0.2.0^{commit}` is the reviewed integration commit and is
reachable from `main`, and the source archive was generated from that commit;
retain the archive SHA-256, source commit and tree, and tag object identity.
Only after those facts are retained is the M5 closure workflow complete.
The pre-closure full gate cannot claim this post-tag result. Do not move the
tag or publish packages, binaries, installers or service units.

<a id="technical-plan-minimalism"></a>
### Proportional Minimalism Budget

Concept: [Scope](M5.md#concept-plan-scope).

Two applications, one socket listener, one narrow core concurrent-attachment
change, one separate durable daemon-control surface with one atomic lease
record and admission check, one resident window and eviction policy, one
session-store adapter with a migration ledger, three CLI commands and the
consumer's socket mode justify growth. No
lease, transport or residency policy in core; no second loop, event
dispatcher, cancellation path or protocol codec; no transport registry,
plugin socket layer or generic service framework; no daemon-side session
state beyond the lease and residency facts it owns. Implement lifetime,
transport and collaboration once against the local session adapter and the
durable control surface, then prove the selected daemon-grade session adapter
against the same witnesses. Raw line count is a review
signal; behaviour and measured limits govern.
<!-- loopex:plan-technical-envelope:end -->
