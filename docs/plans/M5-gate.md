# M5 Gate

Open candidate for the durable service, opened as the one permitted planning
lookahead on M4's integrated acceptance checkpoint. Its three prerequisite
ADRs are Proposed, this M5 plan pair and gate are not accepted by this
revision, and M5 product implementation has not begun. The runner binds a
real behavioral opening probe, executable closure lanes and exact future
witness identities. Under the same preparation rule M3 recorded, future test
bodies are written during implementation; every named witness must pass
before closure. The [Concept plan](M5.md#concept) owns the six outcomes and
the [technical plan](M5-technical.md#technical-depth) owns the contracts and
evidence.

The complete command to bind at acceptance is:

```text
bash scripts/check-m5-gate.sh
```

<a id="amendment-transaction-v1"></a>

After acceptance, amendments use the direct proposal/rebind transaction unless
a named maintainer override expressly replaces that procedure. A maintainer
override may replace only a named development-time transaction or procedure;
its disposition lands alone and receives exact-SHA read-only review before
dependent work. It cannot replace an accepted ADR decision or released public
contract. Each changed digest holder still lands its replacement row through
that holder's own status-checked, exact-SHA-reviewed commit before the next
holder proceeds. Historical bindings and unaffected evidence stay enforced. No
acceptance, amendment or override is recorded by this Open gate.

## Current Opening Observation

The runner compiles protocol, core and the real local Store into an isolated
root and drives one actual session in one operating-system process with a
deterministic model that answers in one turn without tools. A second
attachment inside that process replays exactly the committed events, which
proves the attach and replay path. The runner then executes the same probe
as a second operating-system process while the first still holds the
session: that process must reach the live session. Today the local Store
refuses the path as `store_writer_active` and no daemon socket exists at the
state root's canonical path, so the second process cannot attach. After the
first process stops, a third process resumes the session under the same
placement identity and replays the same tail, which proves that durable
truth crosses processes once the writer is gone.

```text
M5 gate RED: a second process cannot attach to a live session; the local Store refuses the path as store_writer_active and no daemon socket exists
```

This is a credential-free behavioral red for outcomes 1 and 2. It observes
a real writer marker and a real socket address through actual process
boundaries; it does not depend on acceptance state, exported function names,
source text or case counts. Its green is exact: while the first process still
holds the session, the second process connects to the daemon socket,
initializes with ADR 0023's handshake, attaches, and receives a snapshot
naming the session at a cursor no older than the controller's committed
tail, and the direct Store open is still refused. A second process that opens
the held Store is a broken exclusion and a WITNESS ERROR; so is a socket that
accepts a connection but never attaches. Compile or tool failure is
UNAVAILABLE (exit 2); a failed positive control is a named WITNESS ERROR
(exit 2); the observed defect is RED (exit 1). Inspection can pass without a
behavior claim. Full mode continues into its closure lanes only after this
probe becomes green. Checkpoint mode retains the observed red while running
the selected diagnostics. A missing future selector or unavailable dependency
is UNAVAILABLE, never a full-gate PASS.

## Readiness Work Before Acceptance

Before acceptance:

1. Settle ADRs 0031, 0032 and 0033 and their complete daemon, store and
   collaboration contracts. ADR 0031 fixes the adapter on the evidence of
   both candidates through the shared suites; ADR 0032 must bind every
   residency number the technical plan names and the generation-2 method
   inventory; ADR 0033 must fix the lease terms. Advertise only implemented
   semantic capabilities; unknown input rules and every limit are exact.
2. Keep the real opening red on the unchanged base and bind the exact
   selectors and witness names, the canonical generation-2 schema and vector
   bytes, the client interpreter pins in
   `scripts/fixtures/m5/client-toolchain.txt`, the exact residency and lease
   numbers and the fail-closed routing. Use the existing standalone result
   channel; do not build a second result or evidence framework.
3. Wait for M4 to be Closed and integrated, absorb that exact product base,
   and re-prove every inherited gate green and this gate's own distinct red on
   it. Inherited green requires M4's Workstream 0 to have repaired the Closed
   M1 and M2 runners; until it lands, those gates are unavailable evidence
   under the recorded waiver and this plan claims nothing for them.
4. Present the refreshed candidate for fresh exact-SHA review and explicit
   acceptance.

After acceptance, during implementation:

5. Build the daemon over the local adapter to the full lifetime, socket,
   collaboration and residency workflow; require local core and daemon greens
   before the daemon-grade store rejoins.
6. Implement the store adapter, its migration, the CLI commands and the
   consumer workflow against the bound vectors and pins.

Before closure, every lane must pass: isolated compile and probe, inherited
gates, authoritative protected selectors, whole suite, independent clients,
attended two-process real-provider workflow and retained-evidence validation.
Neither document presence nor acceptance state can satisfy the opening. The
opening probe is proof of one missing cross-process behavior, not of leases,
residency, migration or the operator workflow.

## Required Two-Process Conjunction

Two separate client processes, without loading any daemon-private module,
observe against one daemon:

- one daemon per state root holding the writer marker; a second daemon
  refused;
- initialize over the socket with the same generation, schema digest and
  limits the foreground server negotiates, and generation-1 clients served
  unchanged;
- snapshot anchored at the committed sequence, then contiguous buffered and
  live durable events, with `cursor_expired` beyond retention;
- exactly one controller; observers read-only; a stale writer epoch refused
  before any durable write;
- the controller killed, its late commands fenced, and the observer taking
  over after expiry with a durable epoch advance;
- the new controller's abort cancelling work the old controller started, with
  a truthful cleanup outcome;
- a slow observer detached at its last emitted cursor while the other client
  continues;
- protocol records only on the socket and bounded diagnostics only on the
  daemon's stderr.

A daemon that forwards every connection to one in-process attachment, or
that lets any connection command the session, fails this conjunction.

## Bound Artifacts

Acceptance binds these runner, manifest, configuration and authoritative-channel
bytes. Product test bodies may grow during implementation; their protected
identities and required state are fixed in `scripts/m5-outcomes.exs`. The M5
support script reuses the M3-bound support module for shared machinery, so
both are bound here; a change to either under its holder's transaction is a
stale binding this gate must rebind. Existing Closed and Accepted gate and
bound-artifact bytes remain unchanged. The inherited M1 harness corpus retains
its existing binding.

| SHA-256 | Path |
| --- | --- |
| `8fa87635eee9d0bff7e5378e84234017dd0387a0c91783f7fc7885c497560a3a` | `scripts/check-m5-gate.sh` |
| `391439dcf72c0aad8ddebfa4e7a5798bb18b88c616f90592898e179bc3212ac7` | `scripts/m5-opening-probe.exs` |
| `fffd6ffc6bf882c6359b8ac5411ab9982551f78500fad6778ca89f957558278f` | `scripts/m5-gate-support.exs` |
| `65d0de9dcd1218af542f00e32c2177d2612a2f1232f22db37b9942200c84cf66` | `scripts/m3-gate-support.exs` |
| `c4d485ca3229441c678abe1e8733f90216e89e0dfb9e81786f58f525619aec29` | `scripts/check-closed-gates.sh` |
| `df3e35c5e23850d1e8343eb9e2a8cbfadd9bfa8bc9f18ec4301abaa30d6439ac` | `scripts/m5-outcomes.exs` |
| `53d8219bdee584a3849a85a1102e405520d5dd0dfbe21d259434bc9edfc5fcc0` | `scripts/m1-exunit-runner.exs` |
| `c36253cff3d74ddff1b330695edbc4bde0a4565c1412c67c1293b2fb7ca6129b` | `apps/loopex/test/m1_exunit_runner_test.exs` |
| `fea095ecec784a4440b872ad5f53a8da2cb4e13e43b6f05add5cfd75bb352879` | `.tool-versions` |
| `ac93646ab8af588f848de9f824e8d56e287ce311f12ca695ff0d1119c82f4a46` | `scripts/fixtures/m5/client-toolchain.txt` |

## Runner Modes and Evidence Cost

| Mode | Executed role | Evidence meaning |
| --- | --- | --- |
| `--inspect` | Bound artifacts, manifest shape and bootstrap back-edge check; no scratch allocation or source identity | Inspection only; no behavioral PASS |
| `--preflight` | Clean committed-source identity, isolated compile and the two-process opening observation | Declared missing behavior or opening-only green |
| `--checkpoint <comparison-SHA>` | Working-source identity, opening and changed-outcome deterministic selectors | Focused diagnostics; retains an opening red after selected checks pass |
| No flag | Opening; once green, every complete lane below | PASS only after all closure obligations execute successfully |

Checkpoint results are focused diagnostics, never acceptance or closure proof.
The checkpoint role takes an explicit retained comparison SHA, selects all
deterministic outcomes on shared or unclassified product changes, and includes
relevant untracked work. The comparison is a complete 40-character commit SHA
retained as an ancestor of `HEAD`. The executable path map lives in the bound
support script. An invalid comparison never becomes an empty change set. Exact
`HEAD` with no working change prints a distinct no-outcomes diagnostic and
returns the opening result. An opening red stops full and preflight mode.
Checkpoint mode continues its selected diagnostics, returns 1 if they pass
while the opening remains red, and returns 2 if a selected witness is
unavailable. Before either a checkpoint-success line or full-gate
continuation, an exact ordered selector ledger must account for every
manifest-derived lane.

The inherited lane is register-derived through `scripts/check-closed-gates.sh
--before M5`. While M4 is Accepted rather than Closed the aggregate reports
UNAVAILABLE by design, exactly as M4's did before M3 closed; the lookahead
posture is proved instead by running the bootstrap aggregate and M4's
accepted opening red separately from this gate's own red, so neither masks
the other. Run the inherited aggregate at the refreshed acceptance base, every
parallel-workstream rejoin, every rebind child, closure candidate and whenever
product or Closed-bound bytes invalidate its later evidence. Unknown
acceptance impact fails closed to the full gate. Protected-selector execution
never invokes the aggregate itself.

The shell keeps byte-counted parsing under `LC_ALL=C`; every Elixir and Mix
child runs under `C.UTF-8`. Full and preflight roles require one clean
committed source identity. Checkpoint mode binds tracked and untracked working
bytes at entry and rechecks them before its result. Once the opening red is
repaired, full mode refuses a missing provider frame before dependency
materialization or closure lanes. Bootstrap runs with the same private
activity sentinel M3 introduced and the gate rejects that invocation ledger.

## Required Full Lanes

| Lane | Complete executable obligation |
| --- | --- |
| Inspection | Artifact identity, exact outcome manifest and bootstrap topology; full status and pairing checked by bootstrap |
| Opening | Isolated compile; real Store, session and second-process observation with two positive controls |
| Inherited | Bootstrap and all required Closed commands, including Closed M4, with credential lanes and truthful propagation |
| Protected outcomes | Standalone authoritative ExUnit result channel, seed 3107, exact required witness identities and runnable states |
| Whole suite | Complete deterministic suite, format, warning-free compile, documentation and dependency checks |
| Source archive | Stage `git archive` from the exact committed candidate, retain its SHA-256, commit, tree, `VERSION` and `mix.lock` digest, extract it outside the checkout and compile there; the attended selector executes from that extraction |
| Real workflow | Separately selected attended real-provider task from the extracted source, following the operator guide with operator-supplied inputs through the daemon, the reference CLI and the TypeScript consumer |
| Retained evidence | One final report line in the exact grammar below, validated by the bound support script before it is printed; the real selector's authoritative report binds provider, model, endpoint and version-aware adapter and executor build identities; save that output without relabelling its source |

The pinned Node and Python interpreters are verified immediately before each
client-backed selector (the two-process workflow and its real-provider file)
in checkpoint and full modes alike; absence or mismatch is UNAVAILABLE, never
RED.

The retained final report has exactly this grammar, one line, fields in this
order, each present once:

```text
LOOPEX_M5_GATE_REPORT source=<40 hex> tree=<40 hex> archive=sha256:<64 hex> archive_build=sha256:<64 hex> lock=sha256:<64 hex> gate=sha256:<64 hex> version=<major.minor.patch> role=full seed=3107 outcome_ids=1,2,3,4,5,6 selectors=<count> elapsed_seconds=<n> elixir=<exact> otp=<exact, e.g. 29.0.5> erts=<exact> platform=<system architecture> node=<pinned> python=<pinned> clients=sha256:<64 hex> schema=sha256:<64 hex> inherited=true fresh_source=true real_workflow=true result=PASS
```

`source` and `tree` name the staged candidate commit and tree. `archive` is
the SHA-256 of the tar file produced from that commit; `archive_build` names
the extracted source's isolated test build. `lock` is the SHA-256 of the
extracted `mix.lock`. `fresh_source=true` means the gate compiled the
extraction and ran the attended selector from it. `role` names the command
role that produced the line; `selectors` is the number of authoritative
selector reports the ledger accounted for; `elapsed_seconds` is the whole
run's wall time; `clients` is the digest of the bound client toolchain pins;
`schema` is the digest of the canonical schema bytes the protocol application
ships for the negotiated generation, which the acceptance refresh binds as
the generation-2 file. The support script refuses a line with a missing,
duplicated, reordered or malformed field.

Real-provider tests live in the dedicated
`apps/loopex_daemon/test/multi_client_workflow_real_test.exs`. Full mode runs
that tracked selector and its compiled applications from the fresh source
archive extraction. The selector follows `docs/operator/daemon.md` to start
the source-built daemon and drive it from the reference CLI and the
TypeScript consumer; a checkout-only workflow cannot satisfy its protected
case. Full mode accepts only the bounded stdin frame
`LOOPEX_M5_PROVIDER_V1\0<key>\0` (key at most 16,384 bytes); the unexported
value reaches only the real selector and the existing required inherited
credential lanes through the aggregate's declared `LOOPEX_M3_PROVIDER_V1`
input contract. Diagnostic roles accept no provider input. The inherited
real-provider lanes use the reference model `anthropic:claude-haiku-4-5`;
the credential must belong to that Anthropic provider.

## Protected Outcome Obligations

| Outcome | Protected selector family | Required clauses |
| --- | --- | --- |
| 1 | `apps/loopex_daemon/test/session_lifetime_test.exs` | One daemon per state root owning every session; sessions progressing with zero attachments; orderly stop releasing the marker and recording nothing false; abrupt death then restart recovering every session under the same placement identity; a second daemon refused by the held marker; session list, open and stop only through the socket |
| 2 | `apps/loopex_daemon/test/socket_transport_test.exs` | Same generation, schema digest and limits as the foreground server; identical durable identities for one command corpus through facade, foreground server and socket; foreign-uid peer refused before initialize; frame, fragment, malformed-input and over-long socket path refusals; client disconnect as transport loss with no cancellation and no interaction change |
| 3 | `apps/loopex_daemon/test/collaboration_test.exs` | Exactly one controller with observers read-only; stale writer epoch refused before core admission; takeover only after release or expiry with a durable epoch advance; killed controller fenced and its late commands refused; controller abort cancelling work dispatched under an earlier process with a truthful outcome; no authority from content, metadata, answers or order |
| 4 | `apps/loopex_daemon/test/replay_residency_test.exs` | Snapshot then contiguous stream with no gap; `cursor_expired` beyond retention; slow observer detached at its last emitted cursor while others continue; idle eviction with exact reconnect; per-daemon memory within the ceiling at maximum attachments; progress coalesced or dropped under pressure with no journal delay |
| 5 | `apps/loopex_store_daemon/test/store_conformance_test.exs`, `apps/loopex_store_daemon/test/migration_test.exs` | Shared conformance suite unchanged; torn writes, crashes between framing and sync and corrupt frames detected, repaired or refused; commit ambiguity resolved to one outcome; writer ownership and epochs fencing a stale writer; bounded replay equal to full replay; forward migration of a genuine M4 log with identical replay; interrupted migration detected and completed or rolled back; previous binary refusing explicitly with the documented rollback; backup and restore preserving every identity and sequence |
| 6 | `apps/loopex_daemon/test/multi_client_workflow_test.exs`, `apps/loopex_daemon/test/multi_client_workflow_real_test.exs` | Two real client processes over one daemon through controller work, observer following, controller kill and takeover; fresh extraction of the exact candidate following the operator guide with operator-supplied inputs; the reference CLI attaching, listing and aborting cross-process work; ADR 0030 spans at every daemon boundary and a daemon-scoped trace session capturing identities only; the attended real-provider workflow from the extracted source |

Each required clause maps to a named decisive witness in
`scripts/m5-outcomes.exs`. Related clauses may share one named case only when
it contains distinct observed assertions for them. Additional ordinary-suite
negatives remain required to pass but their names and whole-file counts are
not locked. Canonical fixture, harness and result-channel bytes are
digest-bound; mutable test files are protected by witness identity and
required state. No protected witness may be removed, renamed, skipped or
excluded without an accepted amendment or an explicitly approved scoped
override. Exactly twelve application identities and the existing role set are
checked after their prerequisite transactions settle.

## Isolation, Evidence and Review

Retain the existing isolated build, offline lock-verified dependency
materializer, bounded stdin credential delivery and whole-child-group cleanup
design. Extend its real lane to the two-process workflow. Secrets never enter
ordinary children, fixtures, diagnostics or evidence; an inherited M2, M3 or
M4 task is not proof of M5's daemon workflow. Output and queue bounds apply at
the receiver before decode.

Every result names exact source, gate, command, seed, count and limits,
toolchain, platform, client and schema identity and non-secret provider and
executor build details. Run Darwin floor/current and Linux current lanes early
and again at the required final source. Use the actual built daemon, CLI and
consumer outside the checkout. Perform the M3 self-audit for facade, CLI,
socket and recovery before final independent review. Test honest boundary
witnesses and clause and sibling mutations. A repeated finding class triggers
a root-cause audit; no fixed review-round promise or weakened evidence rule is
introduced.

A missing real path, platform, interpreter or artifact is unavailable
evidence. A red required check, unresolved blocking finding or same-source
disappearing failure blocks closure. Relevant byte changes invalidate affected
evidence; shared or unknown impact requires the full gate. Closure, version
transitions, source-release tagging, package publication and compatibility
acceptance retain their distinct authorities. The full gate proves a staged
source candidate, not a pre-existing tag. After independent closure review,
explicit closure and release/tag authority, and integration to `main`, an
annotated `v0.2.0` tag names the exact integration commit on `main`
containing the reviewed closure transition. Neither final tag nor final
release archive is created by this gate.

## Documentation Obligations

| Category | Required closure disposition |
| --- | --- |
| Operator-facing documentation | `docs/operator/daemon.md`, `docs/operator/app-server.md`, `docs/operator/coding-sessions.md`, `docs/operator/runtime.md`, `docs/operator/observability.md`, `docs/operator/tools-and-policy.md`, `docs/operator/how-a-run-works.md`, `docs/operator/how-a-run-works-technical.md` |
| Operator README | `docs/operator/README.md` |
| Developer-facing documentation | `docs/developer/daemon.md`, `docs/developer/daemon-technical.md`, `docs/developer/app-server-protocol.md`, `docs/developer/app-server-protocol-technical.md`, `docs/developer/observability.md`, `docs/developer/observability-technical.md`, `docs/developer/architecture.md`, `docs/developer/architecture-technical.md`, `docs/developer/runtime-and-embedding.md`, `docs/developer/compatibility-surfaces.md`, `docs/developer/agent-context-map.md` |
| Developer README | `docs/developer/README.md` |
| Documentation README | `docs/README.md` |
| Root README | `README.md` |
| Changelog | `CHANGELOG.md` |

This set is inclusive of the M4 gate's complete documentation set: every
document M4 must update at its closure appears above, because M5 builds on
the same operator and developer surfaces and its closure re-describes them
for the daemon, the socket, collaboration and the daemon-grade store. A
document added to M4's set by an accepted amendment is added here too.

Each row is complete only when the documents state what M5 actually changed
for its reader, in the charter's Concept-then-Technical-depth form where the
document is a pair:

- **Operator-facing.** How to start and stop the daemon, where its socket and
  root live and the path bound, who may connect, how to attach from the CLI
  and the TypeScript consumer, what a controller and an observer each see,
  how takeover works after a crash and what an abort does to work another
  process started, what reconnecting after a disconnect or eviction returns,
  the residency and lease numbers, how to import an M4 state root and how to
  roll back, backup and restore, the `0.2.0` source version and the
  source-only release workflow, and what remains experimental or unavailable
  (no remote transport, no multi-user authorization, no service unit, no
  package).
- **Developer-facing.** The daemon pair as the reference for lifetime, socket,
  residency and lease contracts; the protocol pair extended with generation
  2's methods, fields, schema and vector identities; the daemon-grade store
  and its migration as embedding contracts; the eleventh and twelfth
  applications and the dependency direction; the experimental labels and
  exact-generation rule in the compatibility surfaces; and the context map's
  routing for M5's ADRs, documents and gate.
- **Repository-wide.** `docs/README.md`, `README.md` and `CHANGELOG.md`
  describe the two applications, the new operator and developer documents,
  the version transition, the source-only `v0.2.0` release and M5 outcome
  evidence, without claiming a package, binary, installer, service unit or
  compatibility freeze.

The status check limits the developer-facing row to `docs/developer/` paths,
so `DEVELOPMENT.md` is named here instead, and its drift blocks closure
exactly like a row above: it is updated for the two applications, the M5
runner commands, the daemon launch during development and the client toolchain
pins.
