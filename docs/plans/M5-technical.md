<a id="technical-depth"></a>
## Technical depth

Concept: [Durable service](M5.md#concept).

<!-- loopex:plan-technical-envelope:start -->
## Normative Technical Envelope

<a id="technical-plan-prerequisites"></a>
### Prerequisites and Acceptance Points

Concept: [Scope](M5.md#concept-plan-scope).

Concept: [non-goals](M5.md#concept-plan-non-goals).

M5 opened as the one permitted planning lookahead after M4's accepted
governance checkpoint integrated to `main`. Its opening base is
`6f973f774a403f76330058e3d0a59f7b83e038f1`, retained as an ancestor without
rebasing or squashing bound history. M4 is Accepted and remains the sole
implementation authority; M5 holds none. Before M5 can be accepted, M4 must be
Closed and integrated; M5 then absorbs that exact product base, re-proves
every inherited gate green and its own distinct red on it, binds the
generation-2 schema and vector bytes and proves their fixture shape and digest
integrity on both locked toolchain pairs, and obtains fresh exact-SHA review.
Inherited green is possible only after M4's Workstream 0 repairs the Closed M1
and M2 runners; until then their state is unavailable, not green, and this
plan does not claim otherwise. At final acceptance all inherited gates are
green and the M5 boundary remains truthfully red for the missing daemon.

M5 accepts three decisions before dependent work:

| Decision | Owner and acceptance point | Effect |
| --- | --- | --- |
| [**ADR 0031**](../adr/0031-daemon-grade-store-selection-and-migration.md#concept) | Maintainer, before M5 acceptance; the two candidates run the shared conformance and fault-injection suites before the decision is accepted | The daemon-grade store adapter behind the unchanged private ports, its one-way import from an M4 local log with interrupted-migration recovery, the format version the previous binary refuses, and backup and restore |
| [**ADR 0032**](../adr/0032-daemon-attachment-residency-and-replay.md#concept) | Maintainer, before M5 acceptance; must bind every residency number below | The Unix-domain-socket transport carrying ADR 0023 unchanged, generation 2's daemon methods, owner-only peer access, the bounded socket path, race-free attach with a resident window, bounded queues, detachment at the last emitted cursor, idle eviction and `cursor_expired` |
| [**ADR 0033**](../adr/0033-collaboration-controller-lease-and-takeover.md#concept) | Maintainer, before M5 acceptance; must fix the lease terms below | One daemon-owned controller lease per session in the runtime-control namespace, writer epochs refused before admission, explicit takeover with a durable epoch advance, cross-process abort through the core's own cancellation, and no authority from content, metadata or order |

**Residency and lease profile (proposed, bound at acceptance).** 64
attachments per session and 512 per daemon, refused independently; a
1,024-durable-event queue per attachment, detaching at the last completely
emitted cursor when full; a 4,096-event resident window per session with
store replay behind it and `cursor_expired` beyond retained history; eviction
after ten minutes without consumption, naming the resumable cursor; a
thirty-second lease renewed every ten seconds, takeover admitted at expiry
with no further grace, release on orderly disconnect; the ADR 0023 frame
ceiling unchanged. These are safety ceilings to prove, not measured service
promises.

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
| `loopex` | Durable session truth, race-free attach barrier and cursor, dispatcher queues, cancellation and recovery exactly as accepted | A lease, a transport, residency policy or any daemon fact |
| `loopex_protocol` | Generation-2 DTOs, validators, schema and vectors | Daemon behaviour or lease semantics |
| `loopex_store_daemon` | The daemon-grade adapter, its root manifest, snapshots, index, migration ledger, backup and restore, and the runtime-control lease namespace it stores | Public data model, session semantics or authority |
| `loopex_daemon` | Process and socket lifetime, peer-credential check, generation negotiation, attachment residency and eviction, the controller lease and writer-epoch check, session list and stop, and diagnostics | Store or coordinator internals, a second loop, policy selection, host identity |
| `loopex_app_server` | The foreground stdio server unchanged, sharing the protocol mapping the daemon reuses | Daemon lifetime or residency |
| `loopex_cli` | `loopex daemon`, `loopex attach`, `loopex sessions` and takeover presentation | Normative lease or session semantics |
| TypeScript consumer | Socket connection, observer following and takeover presentation | Normative semantics |

The ordered rejoin is prerequisite decisions → daemon lifetime and socket over
the local adapter → collaboration lease and takeover → residency, replay and
backpressure → daemon-grade store and migration → two-process workflow with
the reference CLI and TypeScript consumer → integrated audit → independent
review. Prove lifetime, refusal of a second daemon, snapshot-then-contiguous
delivery, stale-epoch refusal, takeover and cross-process abort before the
store rejoins, so every store claim is proved against behaviour already known
to hold on the local adapter.

Use the existing command identity for every mutating method; request
identities never enter journals. The lease record is written through the
runtime-control store surface, not the session journal. Attach reuses the
runtime's cursor transaction; the daemon buffers and evicts above it and never
reads coordinator state. Cross-process abort forwards the existing durable
`session.abort` command; no daemon-side cancellation path exists.

<a id="technical-plan-evidence"></a>
### Evidence Obligations and Mapping

Concept: [Outcomes](M5.md#concept-plan-outcomes).

| Outcome | Mandatory proof beyond a unit test |
| --- | --- |
| 1 | Real daemon process per state root; sessions progress with zero attachments; orderly stop releases the writer marker and records nothing false; abrupt kill followed by restart recovers every session under the same placement identity with no duplicate effect; a second daemon on the same root refused by the held marker; session list, open and stop through the socket only |
| 2 | Raw-byte client over the socket negotiates the same generation, schema digest and limits the foreground server negotiates; identical durable identities for the same command corpus through facade, foreground server and socket; foreign-uid peer refused before initialize; frame, fragment, malformed-input and over-long socket path refusals with distinct stable reasons; client disconnect recorded as transport loss with no cancellation and no interaction change |
| 3 | One lease per session with observers attached; stale writer epoch refused before core admission and before any durable write; takeover only after release or expiry with a durable epoch advance before the successor's first command; killed controller fenced and its late commands refused; controller abort cancelling work dispatched under an earlier process with a truthful cleanup outcome; no control from content, metadata, answers or attachment order; lease record surviving daemon restart |
| 4 | Snapshot anchored at the committed sequence then contiguous buffered and live delivery across the window boundary with no gap; `cursor_expired` with a fresh snapshot beyond retention; slow observer detached at its last emitted cursor while the controller and other attachments continue; per-session and per-daemon limits refusing independently; idle eviction and reconnect with no duplicate or missing durable event; memory per daemon within the documented ceiling at the maximum attachment count; progress coalesced or dropped with counted drops and no journal delay |
| 5 | Both ADR 0031 candidates through the shared conformance suite unchanged and the fault fixtures at every commit cut; commit ambiguity resolved to one outcome; bounded replay measured on a hundred-thousand-record session; forward migration of a genuine M4 log with identical replay; interruption at each ledger step detected on reopen; previous binary's explicit refusal; backup and restore with every identity and sequence intact |
| 6 | From a fresh extraction of the exact source candidate, an operator follows the documented prerequisites and commands, supplies workspace, provider and policy inputs, starts the daemon, and drives one session from the reference CLI as controller and the TypeScript consumer as observer, kills the controller, takes over from the observer and aborts cross-process work; the attended real-provider selector runs from the extracted tree; every daemon boundary emits ADR 0030 spans and a daemon-scoped trace session captures identities only |

The opening runner binds one real behavioral red for outcomes 1 and 2:
through a real local Store and session in one operating-system process, a
second operating-system process cannot attach to the live session, because
the local Store refuses the path as `store_writer_active` and no daemon socket
exists at the state root's canonical path. Two positive controls hold: a
second attachment inside the controller's own VM replays exactly the
committed events, and after the controller stops a fresh process resumes the
session under the same placement identity and replays the same tail. Green is
exact: the second process, while the first still holds the session, connects
to the daemon socket, initializes, attaches and receives a snapshot naming the
session at a cursor no older than the controller's committed tail, and the
direct Store open is still refused; a store that admits the second writer is
a WITNESS ERROR. Before acceptance, bind the real opening red, the exact
selectors and witness names, the generation-2 schema and vector bytes, the
client interpreter pins, the exact residency and lease numbers and the
fail-closed routing. After acceptance, implement the daemon, its store, the
CLI commands and the consumer workflow; every lane must pass before closure.
A daemon that proxies to a single in-process attachment cannot pass, because
lifetime with zero attachments, fencing after a real kill and cross-process
abort are required.

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
generation 1 with the exact-generation rule and no mixed-generation promise;
a generation-1 client sees no daemon method and no lease field. The private
journal gains a second adapter and a format version; the embedded API, public
events, snapshots, artifact formats and executor protocol are unchanged.
Source VERSION is distinct from protocol generation, journal format version,
provider build and schema digest.

<a id="technical-plan-migration"></a>
### Migration and Rollback

Concept: [Scope](M5.md#concept-plan-scope).

Prove forward import of a genuine M4 local log, interrupted-migration
detection and completion or rollback on reopen, the previous binary's explicit
refusal of a daemon-grade root, and backup and restore. Retain the original
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
tree following the operator guide. After independent closure review, explicit
closure and release/tag authority, and integration to `main`, create one
annotated `v0.2.0` tag on the exact integration commit, generate the release
archive from it and retain its digest, commit and tree. Do not move the tag
or publish packages, binaries, installers or service units.

<a id="technical-plan-minimalism"></a>
### Proportional Minimalism Budget

Concept: [Scope](M5.md#concept-plan-scope).

Two applications, one socket listener, one lease record and check, one
resident window and eviction policy, one store adapter with a migration
ledger, three CLI commands and the consumer's socket mode justify growth. No
lease, transport or residency policy in core; no second loop, event
dispatcher, cancellation path or protocol codec; no transport registry,
plugin socket layer or generic service framework; no daemon-side session
state beyond the lease and residency facts it owns. Implement lifetime,
transport and collaboration once against the local adapter, then prove the
daemon-grade store against the same witnesses. Raw line count is a review
signal; behaviour and measured limits govern.
<!-- loopex:plan-technical-envelope:end -->
