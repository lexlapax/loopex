# M5 Gate

Open planning candidate for the durable service, drafted on M4's integrated
acceptance checkpoint. Its inherited M1 and M2 gates were unavailable there;
the M4-specific waiver and deferral do not establish a valid M5 lookahead
opening. Its two prerequisite ADRs are Proposed, this M5 plan pair and gate
are not accepted by this revision, and M5 product implementation has not
begun. The runner binds a
real behavioral opening probe, executable closure lanes and exact future
witness identities. Under the same preparation rule M3 recorded, future test
bodies are written during implementation; every named witness must pass
before closure. The [Concept plan](M5.md#concept) owns the five outcomes and
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

The runner compiles protocol, core and the real local Store in an isolated
root. Local positive controls first prove that a second attachment in one VM
replays the committed events and that a fresh operating-system process
resumes the session after Store release under the same placement identity.
The runner then starts the daemon fixture in another operating-system process
at a short state root with the default `<state root>/daemon.sock` address.
The fixture calls
`Loopex.Daemon.start_link(state_root: root, runtime_options: runtime_opts)`;
the daemon alone owns the session Store, runtime and session lifetime. A
controller socket client initializes generation 2, creates an uncontrolled
session, attaches, acquires control and commits a deterministic turn with its
writer epoch. An independent operating-system process acts only as another
ADR 0023 JSONL socket client. It initializes generation 2 and attaches while
the daemon retains that session, receiving a correlated snapshot whose
top-level `event_cursor` equals `snapshot.event_sequence` and is no older
than the controller's committed tail. The opening base has no daemon or
socket, so this complete cross-process path is absent.

```text
M5 gate RED: no daemon owns an attachable session at the state root's daemon.sock
```

This is a credential-free behavioral red for outcomes 1 and 2. It observes
real daemon and client process boundaries, a real socket address, the
correlated initialize and attach records, and the committed snapshot cursor.
The daemon-start entrypoint is a fixture contract; merely exporting it cannot
produce green. Acceptance state, source text and case counts cannot satisfy
the observation. Its green is exact:

```text
M5 opening GREEN: two client processes attach to one daemon-owned session through daemon.sock at the committed cursor
```

A socket that accepts a connection but never attaches is a WITNESS ERROR.
Second-daemon writer exclusion is proved separately under Outcome 1; the
opening does not require a client to open the daemon's Store. Compile or tool
failure is UNAVAILABLE (exit 2); a failed positive control is a named
WITNESS ERROR (exit 2); the observed missing behavior is RED (exit 1).
Inspection can pass without a behavior claim. Full mode continues into its
closure lanes only after this probe becomes green. Checkpoint mode retains
the observed red while running selected diagnostics. A missing future
selector or unavailable dependency is UNAVAILABLE, never a full-gate PASS.

## Readiness Work Before Acceptance

Before acceptance:

1. Wait for M4 to be Closed and integrated. Reconstruct the M5 branch-only
   checkpoint on that exact product base, proving every inherited gate green
   and this gate's distinct daemon-absent red. The current M4 acceptance base
   had unavailable M1 and M2 gates; M4's waiver and deferral do not authorize
   an M5 exception or an acceptance candidate from that base.
2. Settle ADRs 0032 and 0033 before M5 acceptance. ADR 0032 must bind every
   event-count and encoded-byte residency ceiling, the generation-2 method
   inventory and the generation-2-only negotiation rule; ADR 0033 must bind
   the in-memory lease, atomic admission, the incarnation-scoped writer epoch
   and the lease terms. ADR 0031 is not an M5 prerequisite; the daemon-grade
   store belongs to the successor milestone. Advertise only implemented
   semantic capabilities; unknown input rules and every limit are exact.
3. Keep the real opening red on the valid base and bind the exact selectors
   and witness names, the canonical generation-2 schema and vector bytes,
   and fixture shape and digest checks on both locked toolchain pairs. Bind
   the client interpreter pins in
   `scripts/fixtures/m5/client-toolchain.txt`, the exact residency and lease
   numbers, generation-2 Python conformance execution, and fail-closed
   routing. Refresh the schema digest that the runner and retained report
   check from generation 1 to the canonical generation-2 file. Use the
   existing standalone result channel; do not build a second result or
   evidence framework.
4. Present the refreshed candidate for fresh exact-SHA review and explicit
   acceptance.

After acceptance, during implementation:

5. Land the one minimal application through its holder transaction, then
   the narrow core concurrent-attachment change. Build the daemon over the
   local adapter to the full lifetime, socket, collaboration and residency
   workflow; require core and daemon greens before the client workflow
   rejoins.
6. Implement the CLI commands and the consumer workflow against the bound
   vectors and pins.

Before closure, every lane must pass: isolated compile and probe, inherited
gates, authoritative protected selectors, whole suite, independent clients,
attended two-process real-provider workflow and retained-evidence validation.
Neither document presence nor acceptance state can satisfy the opening. The
opening probe is proof of one missing cross-process behavior, not of leases,
residency or the operator workflow.

## Required Two-Process Conjunction

Two separate client processes, without loading any daemon-private module,
observe against one daemon:

- one daemon per state root holding the writer marker; a second daemon
  refused;
- initialize over the socket selecting generation 2 with the same schema
  digest and limits the foreground server negotiates for its generation, and
  a generation-1-only client refused at initialize with nothing created;
- snapshot anchored at the committed sequence, then contiguous buffered and
  live durable events, with `cursor_expired` beyond retention;
- exactly one controller; observers read-only; session creation creates an
  uncontrolled session, then existing-session mutation requires the holder
  connection, current epoch, held state and unexpired term together before
  any durable write; an observer's known current epoch grants nothing;
- the controller killed, its late commands fenced, and the observer taking
  over after expiry with an epoch advance;
- a daemon restart leaving every session uncontrolled and an epoch from the
  previous incarnation refused;
- the new controller's abort cancelling work the old controller started, with
  a truthful cleanup outcome;
- a slow observer detached at its last emitted cursor while the other client
  continues;
- after an orderly daemon stop, the foreground server or the reference CLI
  reopening the same root and resuming a daemon-created session;
- protocol records only on the socket and bounded diagnostics only on the
  daemon's stderr.

A daemon that forwards every connection to one replaceable in-process
attachment, or that lets any connection command the session, fails this
conjunction. Independent concurrent core attachments must also keep their
own cursors when one detaches or backpressures.

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
| `523933694fbc16ff82583e536fe982e780a2dff9d1ad820a114e777d9cf917e8` | `scripts/check-m5-gate.sh` |
| `f714516e94e77607a58892749ad2c2a39a1e4c57028fc0800cda586b4b4ba662` | `scripts/m5-opening-probe.exs` |
| `ed3246aa3324f03742b5d7ebc9856935d4de7e46c1bd3b23c37fdc2888ff4c42` | `scripts/m5-gate-support.exs` |
| `65d0de9dcd1218af542f00e32c2177d2612a2f1232f22db37b9942200c84cf66` | `scripts/m3-gate-support.exs` |
| `c4d485ca3229441c678abe1e8733f90216e89e0dfb9e81786f58f525619aec29` | `scripts/check-closed-gates.sh` |
| `1b9e9b05b8bbff814c213c54d41e3904d7681ef61a0307120a818c4a3520d174` | `scripts/m5-outcomes.exs` |
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
| Opening | Isolated compile; two local Store controls, then a separate daemon owner and two socket-client processes with correlated initialize, attach and snapshot records |
| Inherited | Bootstrap and all required Closed commands, including Closed M4, with credential lanes and truthful propagation |
| Protected outcomes | Standalone authoritative ExUnit result channel, seed 3107, exact required witness identities and runnable states, including core concurrent attachments and generation-2 Python conformance |
| Whole suite | Complete deterministic suite, format, warning-free compile, documentation and dependency checks |
| Source archive | Stage `git archive` from the exact committed candidate, retain its SHA-256, commit, tree, `VERSION` and `mix.lock` digest, extract it outside the checkout and compile there; the attended selector executes from that extraction |
| Real workflow | Separately selected attended real-provider task from the extracted source, following the operator guide with operator-supplied inputs through the daemon, the reference CLI and the TypeScript consumer |
| Final documentation structure | At the end of full mode, run `mix loopex.status` and then `mix loopex.docs_check` against the exact committed source; status, pairing, index, link and public-code-documentation checks must pass before the final report. Per-file semantic audit and independent finding disposition remain required closure evidence, not a claimed automated semantic result |
| Retained evidence | One final report line in the exact grammar below, validated by the bound support script before it is printed; the real selector's authoritative report binds provider, model, endpoint and version-aware adapter and executor build identities; save that output without relabelling its source |

The pinned Node and Python interpreters are verified immediately before each
client-backed selector, including generation-2 Python conformance, the
two-process workflow and its real-provider file, in checkpoint and full modes
alike; absence or mismatch is UNAVAILABLE, never RED.

The retained final report has exactly this grammar, one line, fields in this
order, each present once:

```text
LOOPEX_M5_GATE_REPORT source=<40 hex> tree=<40 hex> archive=sha256:<64 hex> archive_build=sha256:<64 hex> lock=sha256:<64 hex> gate=sha256:<64 hex> version=<major.minor.patch> role=full seed=3107 outcome_ids=1,2,3,4,5 selectors=<count> elapsed_seconds=<n> elixir=<exact> otp=<exact, e.g. 29.0.5> erts=<exact> platform=<system architecture> node=<pinned> python=<pinned> clients=sha256:<64 hex> schema=sha256:<64 hex> inherited=true fresh_source=true real_workflow=true result=PASS
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
| 1 | `apps/loopex_daemon/test/session_lifetime_test.exs` | One daemon per state root owning every session; sessions progressing with zero attachments; orderly stop releasing the marker and recording nothing false; abrupt death then restart recovering every session under the same placement identity; a second daemon refused by the held marker; after an orderly stop the foreground server and the reference CLI reopening the same root and resuming a daemon-created session under the same placement identity with identical replay; session list, open and stop only through the socket |
| 2 | `apps/loopex_daemon/test/socket_transport_test.exs`, `apps/loopex_daemon/test/python_client_conformance_test.exs` | Generation 2 selected with the same schema digest and limits the foreground server negotiates for its generation; a generation-1-only initialize refused with `unsupported_generation` and nothing created; identical durable identities for one command corpus through facade, foreground server and socket; foreign-uid peer refused before initialize; frame, fragment, malformed-input and over-long socket path refusals; client disconnect as transport loss with no cancellation and no interaction change; pinned Python client executes generation-2 schema and vectors over the socket and refuses a digest mismatch |
| 3 | `apps/loopex_daemon/test/collaboration_test.exs` | Exactly one controller with observers read-only; an observer with a known current epoch refused because its connection is not holder; admission requires matching epoch, held state and unexpired term before core; takeover only after release or expiry with an epoch advance before the successor's first command; killed controller fenced and its late commands refused; a daemon restart leaving every session uncontrolled with an epoch from the previous incarnation refused; controller abort cancelling work dispatched under an earlier process with a truthful outcome; no authority from content, metadata, answers or order |
| 4 | `apps/loopex/test/concurrent_attachments_test.exs`, `apps/loopex_daemon/test/replay_residency_test.exs` | Two core attachments to one session coexist with independent ordered delivery and one detaching without replacing the other; snapshot then contiguous stream with no gap; `cursor_expired` beyond retention; slow observer detached at its last emitted cursor while others continue; idle eviction with exact reconnect; 4 MiB per-attachment, 16 MiB per-session and 512 MiB aggregate retained encoded-event ceilings at count and payload pressure, with process RSS observed and reported; progress coalesced or dropped under pressure with no journal delay |
| 5 | `apps/loopex_daemon/test/multi_client_workflow_test.exs`, `apps/loopex_daemon/test/multi_client_workflow_real_test.exs` | Two real client processes over one daemon through controller work, observer following, controller kill and takeover; fresh extraction of the exact candidate following the operator guide with operator-supplied inputs; the reference CLI attaching, listing and aborting cross-process work; ADR 0030 spans at every daemon boundary and a daemon-scoped trace session capturing identities only; the attended real-provider workflow from the extracted source. Required post-tag release evidence is checked after reviewed closure integration, outside the pre-closure full gate |

Each required clause maps to a named decisive witness in
`scripts/m5-outcomes.exs`. Related clauses may share one named case only when
it contains distinct observed assertions for them. Additional ordinary-suite
negatives remain required to pass but their names and whole-file counts are
not locked. Canonical fixture, harness and result-channel bytes are
digest-bound; mutable test files are protected by witness identity and
required state. No protected witness may be removed, renamed, skipped or
excluded without an accepted amendment or an explicitly approved scoped
override. Exactly eleven application identities and the existing role set are
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
evidence; shared or unknown impact requires the full gate. Version
transitions, package publication and compatibility acceptance retain their
distinct authorities. The full gate proves a staged source candidate, not a
pre-existing tag. After gate green and independent closure review, an
explicit combined closure and release/tag disposition authorizes the closure
transition, integration and tag. Neither final tag nor final release archive
is created by the pre-closure gate.

## Post-Tag Closure Completion

The closure workflow requires this sequence after the green full-gate report:
the acceptance authority gives one explicit disposition naming both M5
closure and source-only `v0.2.0` release/tag authority; the closure transition
records it; an independent read-only reviewer checks that exact transition
SHA; the unchanged reviewed commit integrates to `main`; the annotated tag
is created on that commit; and source archive proof is retained. The same
disposition does not approve an unrelated release, package or publication.

The post-tag check takes the reviewed integrated closure SHA as its expected
input and fails unless `git cat-file -t refs/tags/v0.2.0` returns `tag`,
`git rev-parse refs/tags/v0.2.0^{commit}` equals that exact SHA, and
`git merge-base --is-ancestor <reviewed-closure-SHA> main` succeeds. Generate
the final tar with `git archive --format=tar <reviewed-closure-SHA>` from
that commit. Retain its SHA-256, the commit and `git rev-parse
<reviewed-closure-SHA>^{tree}`, and the annotated tag object's
`git rev-parse refs/tags/v0.2.0` identity with the command outputs. A
pre-closure staged archive or a green full gate cannot stand in for this
proof. Only after the exact post-tag check passes and its evidence is
retained is the M5 closure workflow complete.

## Documentation Obligations

| Category | Required closure disposition |
| --- | --- |
| Operator-facing documentation | `docs/operator/daemon.md`, `docs/operator/app-server.md`, `docs/operator/coding-sessions.md`, `docs/operator/runtime.md`, `docs/operator/observability.md`, `docs/operator/tools-and-policy.md`, `docs/operator/how-a-run-works.md`, `docs/operator/how-a-run-works-technical.md` |
| Operator README | `docs/operator/README.md` |
| Developer-facing documentation | `docs/developer/daemon.md`, `docs/developer/daemon-technical.md`, `docs/developer/app-server-protocol.md`, `docs/developer/app-server-protocol-technical.md`, `docs/developer/observability.md`, `docs/developer/observability-technical.md`, `docs/developer/architecture.md`, `docs/developer/architecture-technical.md`, `docs/developer/runtime-and-embedding.md`, `docs/developer/agent-loop-and-tools.md`, `docs/developer/compatibility-surfaces.md`, `docs/developer/agent-context-map.md` |
| Developer README | `docs/developer/README.md` |
| Documentation README | `docs/README.md` |
| Root README | `README.md` |
| Changelog | `CHANGELOG.md` |

This Open set includes every document in the current M4 gate's documentation
table, plus M5's daemon documents. At the refreshed M5 acceptance candidate,
compare it to M4's final Closed gate and fix the exact seven-row set before
locking it. Once M5 is accepted, additions or removals require its governed
amendment route; this gate cannot acquire new document paths implicitly.

Each row is complete only when the documents state what M5 actually changed
for its reader, in the charter's Concept-then-Technical-depth form where the
document is a pair:

- **Operator-facing.** How to start and stop the daemon, where its socket and
  root live and the path bound, who may connect, how to attach from the CLI
  and the TypeScript consumer, what a controller and an observer each see,
  how takeover works after a crash and what an abort does to work another
  process started, what reconnecting after a disconnect or eviction returns,
  what a daemon restart does to control, the residency and lease numbers,
  how to stop the daemon and reopen the same root with the foreground server
  or CLI, the `0.2.0` source version and the source-only release workflow,
  and what remains experimental or unavailable (no remote transport, no
  multi-user authorization, no service unit, no package, no daemon-grade
  store).
- **Developer-facing.** The daemon pair as the reference for lifetime, socket,
  residency and lease contracts; the protocol pair extended with generation
  2's methods, fields, schema and vector identities and the daemon's
  generation-2-only negotiation; the eleventh application and the dependency
  direction; the experimental labels and exact-generation rule in the
  compatibility surfaces; and the context map's routing for M5's ADRs,
  documents and gate.
- **Repository-wide.** `docs/README.md`, `README.md` and `CHANGELOG.md`
  describe the application, the new operator and developer documents, the
  version transition, the source-only `v0.2.0` release and M5 outcome
  evidence, without claiming a package, binary, installer, service unit or
  compatibility freeze.

The status check limits the developer-facing row to `docs/developer/` paths,
so `DEVELOPMENT.md` is named here instead, and its drift blocks closure
exactly like a row above: it is updated for the application, the M5 runner
commands, the daemon launch during development and the client toolchain
pins.

## Final Documentation Gate

At the final M5 source candidate, enumerate the complete committed file
inventory below `docs/operator/` and `docs/developer/`, including files newly
added by M5, files materially updated under the seven-row table, and files
reviewed without edits. Retain one audit row for every file with its path,
candidate source SHA, file SHA-256, reader role, `new`, `materially updated` or
`reviewed unchanged` disposition, and any finding and its resolution. The
inventory must match the exact source tree; an omitted file is a failed audit.

Inspect each file for current M5 facts, relevance to its reader, working
links and index routing where applicable, consistent Concept and Technical
depth companion claims where paired, and stale foreground-only assertions.
Check the daemon,
socket, controller/observer, residency, restart and rollback descriptions
against the accepted plan and ADRs. Release documentation must accurately
describe the required source-only `v0.2.0` tag and archive sequence while
making no pre-tag claim that they already exist. Resolve inaccurate or stale
claims before the final gate and repeat invalidated checks on changed bytes.

At the end of full mode, the runner executes `mix loopex.status` and then
`mix loopex.docs_check` on the exact source candidate before it can print
PASS. Their structural checks do not decide semantic accuracy: an
independent read-only closure reviewer examines the per-file audit and exact
source SHA, checks every finding disposition, and treats unresolved blocking
or high-severity documentation findings as closure blockers. This final audit
is broader than the seven-row material-update set and cannot be satisfied by
the structural check alone.
