# M4 Gate

Accepted gate for the headless external consumer on M3's Closed product
base. Its five prerequisite ADRs are accepted, the M4 plan pair and this gate
were accepted on 2026-09-14 as the plan's Acceptance row records, and M4
product implementation proceeds on branch `m4` against this locked gate,
which stays red until its declared missing behavior exists. The runner binds
a real behavioral opening probe,
executable closure lanes and exact future witness identities. Under the same
preparation rule M3 recorded, future test bodies are written during
implementation; every named witness must pass before closure. The
[Concept plan](M4.md#concept) owns the seven outcomes and the
[technical plan](M4-technical.md#technical-depth) owns the contracts and evidence.
The reviewed
[planning-revision aggregate override](../developer/agent-context-map.md#override-disposition-m4-planning-aggregate-2026-09-11)
and its reviewed
[widened scope](../developer/agent-context-map.md#override-disposition-m4-planning-aggregate-scope-2026-09-11)
covered earlier revisions of this Open lineage (plan and gate documents,
manifests, runner and support work, ADR proposals, documentation, and
repository-status enforcement with its tests, with no product bytes and
bootstrap green). Those revisions relied on the M0–M2 aggregate proved at the
opening candidate; the override waives nothing for product changes,
Closed-bound bytes, the refresh, acceptance, rejoin, rebind or
closure.

The complete command to bind at acceptance is:

```text
bash scripts/check-m4-gate.sh
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
acceptance or override is recorded by this gate document itself.
[Amendment 1](#amendment-1) is the pre-acceptance binding refresh that the
shared-holder sequence required of every holder whose bound bytes changed; it
preceded acceptance and was completed by the Acceptance row itself. Later
amendments follow the transaction above.

## Current Opening Observation

The runner compiles protocol, core and the real local Store into an isolated
root and drives three actual sessions with a deterministic model that requests
exactly one tool call. An allowing policy proves the call reaches the fixture
executor and commits an effect intent and a completed receipt. A denying policy
proves the call is journaled as `denied` with `policy_denied` and no intent or
executor invocation. A deferring policy must commit one pending interaction and
suspend the run without executor intent; the current product instead denies the
call as `interaction_unsupported` and settles the run.

```text
M4 gate RED: policy defer denies the tool call as interaction_unsupported instead of committing a durable pending interaction
```

This is a credential-free behavioral red for outcome 3. It reads the retained
journal through the real Store, observes settlement through the public facade
and counts executor invocations; it does not depend on acceptance state,
exported function names, source text, case counts or an invented record member.
Its green is exact: the facade status must report the run suspended on one
pending interaction, the journal must hold the pending-interaction record
naming that interaction and the probe's tool call, and no terminal, effect
intent or executor invocation may exist. A run that fails to settle without
that explicit pending state is a WITNESS ERROR, so a deadlock cannot pass.
Compile/tool failure is UNAVAILABLE (exit 2); a failed positive control is a
named WITNESS ERROR (exit 2); the observed defect is RED (exit 1). Inspection can
pass without a behavior claim. Full mode continues into its closure lanes only
after this probe becomes green. Checkpoint mode retains the observed red while
running the selected diagnostics. A missing future selector or unavailable
dependency is UNAVAILABLE, never a full-gate PASS.

## Readiness Work Before Acceptance

Before acceptance:

1. Settle ADRs 0023/0024/0026/0028/0030 and their complete core/port contracts,
   then reconcile DTO/schema/vector bytes with the actual M3 resource facade.
   ADR 0028 carries the decided one-verification-per-transfer design and must
   bind every limit the technical plan names; ADR 0023 must carry the connection
   state table; ADR 0024 must fix the successive-round bound; ADR 0030 carries
   the emission inventory, the exact trace limits and the edge-owned handler
   rule. Advertise only implemented semantic capabilities; unknown input rules
   and every limit are exact.
2. Keep the real opening red on the unchanged base and bind the exact
   selectors and witness names, the canonical schema and vector bytes, the
   client interpreter pins in `scripts/fixtures/m4/client-toolchain.txt`, the
   exact limits and the fail-closed routing. The runner verifies the pinned
   executables before any client-backed selector; absence or mismatch is
   UNAVAILABLE, never PASS or an ordinary RED. Use the existing standalone
   result channel; do not build a second result/evidence framework.
3. Settle the phase A floor holder transactions, including M3, or an
   explicitly approved development-time procedural replacement, before M4
   binds replacement bytes. Name every holder and complete its own replacement
   commit, holder-scoped artifact validation with a named pending-holder list,
   and exact-SHA review in sequence. Do not report global status, bootstrap or
   all inherited gates green during an unfinished shared binding sequence;
   prove those after Open M4 refreshes its final binding.
4. M3 is Closed and integrated, and M4 has absorbed its exact base. After the
   floor holders settle and Open M4 refreshes its binding, run
   `elixir -r scripts/check-m4-fixtures.exs -e 'Loopex.M4FixtureCheck.run!()'` and
   `elixir scripts/check_m4_fixtures_test.exs` on the refreshed floor and
   current toolchains. The bound checker uses only standard-library JSON and
   proves key schema/vector inventories, LF/hex frame shape and their
   cross-file digest; its mutation tests reject altered shape or bytes.
   Neither command is behavioral client conformance evidence. Re-prove every
   inherited gate green and this gate's own distinct red on that refreshed
   base, then present the candidate for fresh exact-SHA review and explicit
   acceptance.

After acceptance, during implementation:

5. Build the independent raw-process probe to the full foundation workflow:
   initialize, create, attach, select an admitted skill, submit prompt, observe
   durable admission, answer the exact interaction, observe policy re-evaluation
   and the committed grant/intent, observe the tool receipt, verify actual
   artifact bytes and a settled snapshot. Require local core/port greens before
   the wire implementation rejoins.
6. Implement the server, the TypeScript consumer workflow and the independent
   Elixir/Python conformance clients against the bound vectors and pins.

Before closure, every lane must pass: isolated compile and probe, inherited
gates, authoritative protected selectors, whole suite, independent clients,
attended real-provider workflow and retained-evidence validation. Neither
document presence nor acceptance state can satisfy the opening. The opening
probe is proof of one missing core behavior, not of skills, interactions, the
TypeScript workflow or artifact integrity.

## Required Raw-Process Conjunction

A separate program, without loading the product codec, observes:

- exact `loopex.experimental/1`, schema digest, capabilities and bounded limits;
- no durable mutation before initialization and snapshot/cursor before live work;
- distinct transport request, durable command and interaction identities;
- command-bound admission before correlated asynchronous delivery;
- unchanged M3 catalog/selection identity and actual staged skill-use evidence;
- pending interaction, committed response, host-policy resolution and completed
  tool receipt for the exact tool call;
- bounded artifact transfer with distinct full-object and chunk hashes and one
  verification per transfer;
- gap-free committed events, truthful progress fallback, run.finished and
  session.settled, and a fresh authoritative settled attachment;
- protocol records only on stdout and bounded diagnostics on stderr.

A fake echo or auto-approval server fails this conjunction. Shape extraction is
not a general JSON conformance claim; independent decoding/vector tests prove
order-independent semantics and duplicate-key refusal.

Abrupt process death and fresh-process resume use actual Store data and prove no
duplicate effect. Clean stdin EOF is a separate case that shuts down in order
without cancelling, and `session.abort` is the only cancellation; a pending
interaction survives the first two and an aborted one never becomes pending on
restart.

## Bound Artifacts

Acceptance binds these runner, manifest, configuration and authoritative-channel
bytes. Product test bodies may grow during implementation; their protected
identities and required state are fixed in `scripts/m4-outcomes.exs`. The M4
support script reuses the M3-bound support module for shared machinery, so
both are bound here; a change to either under its holder's transaction is a
stale binding this gate must rebind. Existing Closed gate and bound-artifact
bytes remain unchanged. The inherited M1 harness corpus retains its existing
binding.

| SHA-256 | Path |
| --- | --- |
| `baa80842b486abeb3f092f042d9ac64d83eb7eea4028d3b72b08bc62df398240` | `scripts/check-m4-gate.sh` |
| `a559bd9f44f1f46f65aaff0bdcfcac2e5124301bc367c58c85966fd6409ba68f` | `scripts/m4-opening-probe.exs` |
| `6eb691a5fd4b1b3c3896cc38f7719c21db637b12e3c17de9dd42f24a154cefdd` | `scripts/m4-gate-support.exs` |
| `65d0de9dcd1218af542f00e32c2177d2612a2f1232f22db37b9942200c84cf66` | `scripts/m3-gate-support.exs` |
| `c4d485ca3229441c678abe1e8733f90216e89e0dfb9e81786f58f525619aec29` | `scripts/check-closed-gates.sh` |
| `8c94069e737ba66c658071c52232ae3f9462fb79ca8d0221fe071d63367765c7` | `scripts/m4-outcomes.exs` |
| `f04f17db1f5f26e558366cf8c9c73c439647ad3da6a2eee255f59123cc1ccc4e` | `scripts/check-m4-fixtures.exs` |
| `b237fb3c5dbd4d903255317f4ab0c521f8458a3cd64c49266582221690b6435e` | `scripts/check_m4_fixtures_test.exs` |
| `53d8219bdee584a3849a85a1102e405520d5dd0dfbe21d259434bc9edfc5fcc0` | `scripts/m1-exunit-runner.exs` |
| `c36253cff3d74ddff1b330695edbc4bde0a4565c1412c67c1293b2fb7ca6129b` | `apps/loopex/test/m1_exunit_runner_test.exs` |
| `fea095ecec784a4440b872ad5f53a8da2cb4e13e43b6f05add5cfd75bb352879` | `.tool-versions` |
| `ac93646ab8af588f848de9f824e8d56e287ce311f12ca695ff0d1119c82f4a46` | `scripts/fixtures/m4/client-toolchain.txt` |
| `a4c286cf45442273011d8f51d25d867334cb3dc0ce3621e86564cba520e1bcff` | `apps/loopex_protocol/priv/schema/loopex-experimental-1.json` |
| `a7f2dc36f9206dc48d258bc7b49a8d390ec3a0e93c51ed5a35f45153052e1951` | `apps/loopex_protocol/priv/vectors/loopex-experimental-1.json` |

## Runner Modes and Evidence Cost

| Mode | Executed role | Evidence meaning |
| --- | --- | --- |
| `--inspect` | Bound artifacts, manifest shape and bootstrap back-edge check; no scratch allocation or source identity | Inspection only; no behavioral PASS |
| `--preflight` | Clean committed-source identity, isolated compile and real-session opening observation | Declared missing behavior or opening-only green |
| `--checkpoint <comparison-SHA>` | Working-source identity, opening and changed-outcome deterministic selectors | Focused diagnostics; retains an opening red after selected checks pass |
| No flag | Opening; once green, every complete lane below | PASS only after all closure obligations execute successfully |

Checkpoint results are focused diagnostics, never acceptance or closure proof.
The checkpoint role takes an explicit retained comparison SHA, selects all
deterministic outcomes on shared/unclassified product changes, and includes
relevant untracked work. The comparison is a complete 40-character commit SHA
retained as an ancestor of `HEAD`. The executable path map lives in the bound
support script. An invalid comparison never becomes an empty change set. Exact
`HEAD` with no working change prints a distinct no-outcomes diagnostic and
returns the opening result. An opening red stops full/preflight mode.
Checkpoint mode continues its selected diagnostics, returns 1 if they pass
while the opening remains red, and returns 2 if a selected witness is
unavailable. Before either a checkpoint-success line or full-gate continuation,
an exact ordered selector ledger must account for every manifest-derived lane.

The inherited lane is register-derived through `scripts/check-closed-gates.sh
--before M4` and now includes Closed M3. The earlier lookahead posture was
proved at the opening candidate by running the then-Closed aggregate and the
M3 opening probe separately, so neither red masked the other; its recorded
waiver did not cover the M3 refresh. Run the inherited aggregate at the
refreshed acceptance base, every parallel-workstream rejoin, every rebind child,
closure candidate and whenever product or Closed-bound bytes invalidate its
later evidence.
Unknown acceptance impact fails closed to the full gate. Protected-selector
execution never invokes the aggregate itself.

The shell keeps byte-counted parsing under `LC_ALL=C`; every Elixir and Mix child
runs under `C.UTF-8`. Full and preflight roles require one clean committed source
identity. Checkpoint mode binds tracked and untracked working bytes at entry and
rechecks them before its result. Once the opening red is repaired, full mode
refuses a missing provider frame before dependency materialization or closure
lanes. Bootstrap runs with the same private activity sentinel M3 introduced and
the gate rejects that invocation ledger.

## Required Full Lanes

| Lane | Complete executable obligation |
| --- | --- |
| Inspection | Artifact identity, exact outcome manifest and bootstrap topology; full status/pairing checked by bootstrap |
| Opening | Isolated compile; real Store/session policy-defer observation with positive controls |
| Inherited | Bootstrap and all required Closed commands, including Closed M3, with credential lanes and truthful propagation |
| Protected outcomes | Standalone authoritative ExUnit result channel, seed 3107, exact required witness identities and runnable states |
| Whole suite | Complete deterministic suite, format, warning-free compile, documentation and dependency checks |
| Source archive | Stage `git archive` from the exact committed candidate, retain its SHA-256, commit, tree, `VERSION` and `mix.lock` digest, extract it outside the checkout and compile there; the attended selector executes from that extraction |
| Real workflow | Separately selected attended real-provider task from the extracted source, following the operator guide with operator-supplied inputs through the shipped server and TypeScript consumer |
| Retained evidence | One final report line in the exact grammar below, validated by the bound support script before it is printed; the real selector's authoritative report binds provider/model/endpoint and version-aware adapter/executor build identities; save that output without relabelling its source |

The pinned Node and Python interpreters are verified immediately before each
client-backed selector (the external workflow, its real-provider file and the
schema conformance file) in checkpoint and full modes alike; absence or
mismatch is UNAVAILABLE, never RED.

The retained final report has exactly this grammar, one line, fields in this
order, each present once:

```text
LOOPEX_M4_GATE_REPORT source=<40 hex> tree=<40 hex> archive=sha256:<64 hex> archive_build=sha256:<64 hex> lock=sha256:<64 hex> gate=sha256:<64 hex> version=<major.minor.patch> role=full seed=3107 outcome_ids=1,2,3,4,5,6,7 selectors=<count> elapsed_seconds=<n> elixir=<exact> otp=<exact, e.g. 29.0.5> erts=<exact> platform=<system architecture> node_pin=<pinned> python_pin=<pinned> clients=sha256:<64 hex> schema=sha256:<64 hex> inherited=true fresh_source=true real_workflow=true result=PASS
```

`source` and `tree` name the staged candidate commit and tree. `archive` is
the SHA-256 of the tar file produced from that commit; `archive_build` names
the extracted source's isolated test build. `lock` is the SHA-256 of the
extracted `mix.lock`. `fresh_source=true` means the gate compiled the
extraction and ran the attended selector from it. `role` names the command role
that produced the line (only the full role reports); `selectors` is the number
of authoritative selector reports the ledger accounted for;
`elapsed_seconds` is the whole run's wall time;
`clients` is the digest of the bound client toolchain pins; `schema` is the
digest of `apps/loopex_protocol/priv/schema/loopex-experimental-1.json`, the
canonical schema bytes the protocol application ships, which also carry every
negotiated limit. The support script refuses a line with a missing, duplicated,
reordered or malformed field, and the bound
`apps/loopex/test/m4_gate_support_test.exs` witnesses retain that refusal for
both report kinds and the final grammar.

Real-provider tests live in the dedicated
`apps/loopex_app_server/test/external_workflow_real_test.exs`. Full mode runs
that tracked selector and its compiled applications from the fresh source
archive extraction. The selector follows `docs/operator/app-server.md` to
launch the source-built server and TypeScript consumer; a checkout-only
workflow cannot satisfy its protected case. Full mode accepts
only the bounded stdin frame `LOOPEX_M4_PROVIDER_V1\0<key>\0` (key at most
16,384 bytes); the unexported value reaches only the real selector and the
existing required inherited credential lanes through the aggregate's declared
`LOOPEX_M3_PROVIDER_V1` input contract. Diagnostic roles accept no provider
input. The aggregate emits each predecessor's existing input format; it does
not change that predecessor's credential contract. No mixed-file exclusion
inventory is locked. The inherited real-provider lanes use the reference model
`anthropic:claude-haiku-4-5`; the credential must belong to that Anthropic
provider. Node/TypeScript and Python execution versions for the client lanes
are pinned before acceptance, not by this opening.

## Protected Outcome Obligations

| Outcome | Protected selector family | Required clauses |
| --- | --- | --- |
| 1 | `apps/loopex_app_server/test/initialization_test.exs` | Exact generation/schema/limit negotiation before mutation; mutation-before-init and duplicate-init refusal without durable work; stdout purity and real process boundary; strict UTF-8/LF framing and the exact method inventory, including unavailable `session.list` and project-trust methods, with unknown mutating methods refused before admission and unknown queries answered with a bounded error; every ADR 0023 connection-state row from before initialize through restart |
| 2 | `apps/loopex/test/session_settled_event_test.exs`, `apps/loopex_app_server/test/session_mapping_test.exs` | Core emits exactly one distinct `session.settled` after `run.finished` in the same no-follow-up terminal transaction, none during follow-up promotion, and replay/reattach never duplicates either fact; this repairs a missing accepted ADR 0011 event rather than claiming inherited M3 parity. Same corpus facade/wire; independent request and command identity with replay idempotency; admission vs completion; snapshot/live ordering and an open-interaction view captured at the same cursor as the unchanged revision-2 snapshot; second-attach refusal or explicit replacement at the last emitted cursor; in-flight request-ID reuse refused and post-completion reuse ordinary; pre-admission pressure refusing before any durable write and post-admission pressure dropping progress first then detaching at the last emitted cursor; snapshot, event, progress and diagnostic record families kept separate with a fresh settled attachment as the final authority |
| 3 | `apps/loopex/test/interaction_lifecycle_test.exs`, `apps/loopex_app_server/test/foundation_mapping_test.exs` | Durable request/answer/policy/intent cuts journaled before publication and before any intent, fixed timestamps through uncertain commits, expiry/abort/restart races, the exact successive-round bound, old-reader refusal; answered-but-unresolved recovery without speculation, acknowledgement or dispatch; identical replay returns the historical admission while changed content, wrong-target, resolved, expired or absent interactions refuse with stable reasons; invalid answers, malformed policy output and failed or timed-out re-evaluation dispatch nothing and resolve as denial; policy-request, interaction-request and answer digests with their preimages preserved through commit_unknown and restart under the same policy identity and revision; exact resources, missing/stale trust, manual-only selection, answer admission separate from re-evaluation and grant/intent, immutable launch inputs unreplaceable from the wire |
| 4 | `apps/loopex_store_local/test/artifact_transfer_test.exs`, `apps/loopex_app_server/test/delivery_bounds_test.exs` | The attachment-owned open/read/close API refusing another attachment, session or runtime and disclosing no path; complete verification at open with one verification per transfer, distinct object/chunk digests, unsupported-store refusal; whole, first, last, empty and overrun windows and every distinct refusal reason; wrong-session use, object/use swap, corruption outside the requested window, post-open same-size rewrite never reaching a chunk; open deadline or work-budget exhaustion refusing before any chunk bytes leave the store and removing any partial snapshot; per-connection and per-runtime transfer limits refusing independently; connection-work exhaustion, lifetime expiry, cancellation, descriptor and snapshot release across repeated kill/restart, streaming memory bounded well above the chunk ceiling and startup scavenging touching only owned regular files; genuine old-format artifacts readable and capability removal restoring the prior API; chunk/read-deadline budgets; at the wire, a transfer reference from another connection refused and connection loss closing every transfer it opened; malformed UTF-8, duplicate keys, nesting, fragmented/multiple/oversized frames, blocked reader, detach cursor, late progress and actual cleanup |
| 5 | `apps/loopex_app_server/test/external_workflow_test.exs`, `apps/loopex_app_server/test/external_workflow_real_test.exs` | Fresh extraction of the exact source candidate follows the operator guide, builds the foreground server and TypeScript consumer, and runs them with operator-supplied inputs; the attended real-provider selector runs from that extraction and proves the same skill → interaction answer → policy re-evaluation → committed grant/intent → actual tool → artifact → abrupt restart workflow with no embedded identities; clean stdin EOF performs orderly shutdown with no cancellation; abrupt death records nothing; a pending interaction survives both; `session.abort` is the only cancellation and an aborted interaction never reappears |
| 6 | `apps/loopex_protocol/test/public_schema_conformance_test.exs`, `apps/loopex/test/m4_gate_support_test.exs` | Independently executed Elixir, Python and TypeScript clients over canonical positive/negative vectors under the pinned interpreters; exact version and platform identities; retained refusal of missing, duplicated, reordered, wrong-kind, stale-version and malformed evidence fields |
| 7 | `apps/loopex/test/trace_session_test.exs`, `apps/loopex/test/telemetry_boundary_test.exs` | Session scoped to owned processes and allowed modules with a second VM tracer unaffected; documented fields per level; redaction of credential references, model content, tool arguments and artifact bytes at the `arguments` level; the exact 4,096-byte, 2,000-per-second and 8,192-entry limits drop with a counted entry without blocking; no session command, client content, model output, project resource or wire request starts, changes or stops a session; stop releases every flag; unavailability on a release without trace sessions; every callback and transaction cut in the ADR 0030 inventory emits start/stop or exception with duration and documented metadata only; crashing handler isolated; a slow or blocked `loopex_telemetry` forwarding sink never delays a coordinator and drops with a counted entry; the dispatcher's bounded diagnostics admission (one atomic owner-recording slot claim before send under racing senders, 4,096-slot ceiling on the Loopex-owned backlog, a sender killed at each crash cut, after taking a ticket, after a failed claim, after a successful claim and after the send, holding afterwards exactly its claimed-but-unsent slots released at its `DOWN` while a concurrent sender's slot stays live and admits, a release freeing only the exact claim it names, counted drops without a send, a drain summary carrying the exact count of counted drops, host sink backpressured only) observed through the asynchronous path; overheads measured |

Each required clause maps to a named decisive witness in `scripts/m4-outcomes.exs`.
Related clauses may share one named case only when it contains distinct observed
assertions for them. Additional ordinary-suite negatives remain required to pass
but their names and whole-file counts are not locked. Canonical fixture, harness
and result-channel bytes are digest-bound; mutable test files are protected by
witness identity and required state. No protected witness may be removed,
renamed, skipped or excluded without an accepted amendment or an explicitly
approved scoped override. The app-server adds zero external production
dependencies; the existing ReqLLM edge dependency closure remains allowed.
Exactly ten application identities and the existing role set are checked after
their prerequisite transactions settle.

## Isolation, Evidence and Review

Retain the existing isolated build, offline lock-verified dependency materializer,
bounded stdin credential delivery and whole-child-group cleanup design. Extend
its real lane to the new workflow. Secrets never enter ordinary children,
fixtures, diagnostics or evidence; an inherited M2 or M3 task is not proof of
M4's external workflow. Output and queue bounds apply at the receiver before
decode, and the server never bypasses ADR 0028's bounded artifact read with a
whole-object allocation.

Every result names exact source, gate, command, seed/count/limits, toolchain,
platform, client/schema identity and non-secret provider/executor build details.
Run Darwin floor/current and Linux current early and again at the required final
source. Use the actual built server and provider companion outside the checkout.
Perform M3's entrypoint/lifetime/compatibility self-audit for facade, CLI, wire and
recovery before final independent review. Test honest boundary witnesses and
clause/sibling mutations. A repeated finding class triggers a root-cause audit;
no fixed review-round promise or weakened evidence rule is introduced.

A missing real path, platform, interpreter or artifact is unavailable evidence.
A red required check, unresolved blocking finding or same-source disappearing
failure blocks closure. Relevant byte changes invalidate affected evidence;
shared or unknown impact requires the full gate. Closure, version transitions,
source-release tagging, package publication and compatibility acceptance retain
their distinct authorities. The full gate proves a staged source candidate, not
a pre-existing tag. After independent closure review, explicit closure and
release/tag authority, and integration to `main`, an annotated `v0.1.0` tag names
the exact integration commit on `main` containing the reviewed closure
transition. Verify that the integration tree preserves the reviewed closure
tree apart from approved governance transition bytes. Generate the final
source archive from that tag and verify its digest, commit, tree and `VERSION`
against the tagged commit. Neither
final tag nor final release archive is created by this gate.

## Documentation Obligations

| Category | Required closure disposition |
| --- | --- |
| Operator-facing documentation | `docs/operator/app-server.md`, `docs/operator/observability.md`, `docs/operator/runtime.md`, `docs/operator/coding-sessions.md`, `docs/operator/tools-and-policy.md`, `docs/operator/how-a-run-works.md`, `docs/operator/how-a-run-works-technical.md` |
| Operator README | `docs/operator/README.md` |
| Developer-facing documentation | `docs/developer/app-server-protocol.md`, `docs/developer/app-server-protocol-technical.md`, `docs/developer/observability.md`, `docs/developer/observability-technical.md`, `docs/developer/architecture.md`, `docs/developer/architecture-technical.md`, `docs/developer/runtime-and-embedding.md`, `docs/developer/agent-loop-and-tools.md`, `docs/developer/compatibility-surfaces.md`, `docs/developer/agent-context-map.md` |
| Developer README | `docs/developer/README.md` |
| Documentation README | `docs/README.md` |
| Root README | `README.md` |
| Changelog | `CHANGELOG.md` |

This set is inclusive of the M3 gate's complete documentation set: every
document M3 must update at its closure appears above, because M4 builds on
those same operator and developer surfaces and its closure re-describes them
for the app server, interactions and transfers. A document added to M3's set
by an accepted amendment is added here too.

Each row is complete only when the documents state what M4 actually changed
for its reader, in the charter's Concept-then-Technical-depth form where the
document is a pair:

- **Operator-facing.** How to turn tracing on and off at launch or through
  the host, what each trace level shows, what is redacted and why, and how to
  consume telemetry events; how to launch the app server and the TypeScript
  consumer from a source build; what the operator sees at initialize, attach,
  prompt, pending interaction, answer, tool receipt, artifact transfer and
  settlement; the exact meaning of clean EOF, abrupt death and `session.abort`;
  answering an interaction after a restart; the artifact transfer limits and
  what "one verification per transfer" costs; the refreshed floor pair, the
  client interpreter pins, the 0.1.0 source version and the documented
  source-only release workflow; and what remains experimental or unavailable
  (no daemon, sockets, takeover, Hex package, binary or installer).
- **Developer-facing.** The observability pair as the reference for the
  trace-session contract, the telemetry event catalog and the redaction and
  limit rules; the protocol pair as the normative wire reference
  (methods, records, identities, limits, schema and vector identities); the
  ninth and tenth applications, the changed dependency rules and the
  dependency direction; the core interaction lifecycle and the ArtifactStore
  transfer capability as embedding contracts; the experimental labels and
  exact-generation rule in the compatibility surfaces; and the context map's
  routing for M4's ADRs, documents and gate.
- **Repository-wide.** `docs/README.md`, `README.md` and `CHANGELOG.md`
  describe the ninth and tenth applications, the new operator and developer documents,
  the version transition, the source-only `v0.1.0` release and M4 outcome
  evidence, without claiming a package, binary, installer, service image or
  compatibility freeze.

The status check limits the developer-facing row to `docs/developer/` paths, so
two root documents are named here instead, and their drift blocks closure
exactly like a row above. `DEVELOPMENT.md` is updated for the ninth and tenth
applications, the refreshed floor pair, the client toolchain pins, the M4
runner commands, and how to enable a trace session and read telemetry while
developing. `AGENTS.md` is updated once outcome 7 is green, in the same
milestone, so its debugging guidance directs agents to use runtime trace
sessions and telemetry events for diagnosing Loopex rather than ad hoc
printing; that edit changes development guidance only and names no authority
change.

<a id="amendment-1"></a>
## Amendment 1 — Refresh the floor pair binding to Elixir 1.18.5 with OTP 27.3.4

This Open gate has no Acceptance row to rebind, so this section is not a
post-acceptance amendment. It is the binding refresh the shared-holder
sequence requires of the last holder of `.tool-versions`: accepted
[ADR 0026](../adr/0026-development-floor-refresh.md#concept) chose the
validation pairs explicitly, Closed M0, M1, M2 and M3 settled the shared
bytes through their
[generation 7](../developer/agent-context-map.md#disposition-m0-gate-generation-7-2026-09-13),
[generation 10](../developer/agent-context-map.md#disposition-m1-gate-generation-10-2026-09-14),
[generation 11](../developer/agent-context-map.md#disposition-m2-gate-generation-11-2026-09-14)
and
[generation 4](../developer/agent-context-map.md#disposition-m3-gate-generation-4-2026-09-14),
and Open M4 now refreshes its own Bound Artifacts row directly, as its
technical plan's phase A prescribes.

This refresh rebinds only the `.tool-versions` row above; the runner reads
this table rather than embedding the digest, so no runner, support script,
manifest, fixture, selector or witness identity changes. The technical plan's
holder ledger, the developer setup guide's toolchain commands and the
development contract's bootstrap-floor sentence are updated in the same
revision to name the accepted pair; those are conforming explanations of the
accepted decision, not new decisions.

The revision carrying this refresh is the M4 acceptance candidate. Until the
Acceptance row binds that exact revision, binding validation, bootstrap and
every inherited gate that invokes them stop only on the shared binding
sequence this last holder closes; the Acceptance transition is the rebind
that completes it. At that transition, and not before, global status and
bootstrap become eligible for green, and the inherited M0–M3 gates and this
gate's own distinct red are proved on both pairs; a recorded M0 run under
the new floor pair is part of that proof. This refresh records no acceptance
and grants no waiver, closure or release.

| Generation | Artifact | Rebound SHA-256 |
| --- | --- | --- |
| 1 | `.tool-versions` | `fea095ecec784a4440b872ad5f53a8da2cb4e13e43b6f05add5cfd75bb352879` |

<a id="amendment-2"></a>
## Amendment 2 — Rename the pinned-interpreter report fields

**Acceptance: OUTSTANDING.** Accepted M4 amends its gate under
`amendment-transaction-v1`: this proposal `A` advances the generation and
retains the Acceptance row and lifecycle state; its immediate child `R`
rebinds Acceptance to exact `A` after explicit acceptance.

The first M0 gate run under the refreshed floor pair, taken as M4's
Workstream 0 baseline on 2026-09-14, was red at outcome 8: the closed M0
gate scans every tracked byte for an interpreter invocation that could bypass
its retired-dependency shadow, and the report grammar above spelled the
Python pin as an assignment token followed by a bare `python` field, which is
one of the shapes that scan refuses however it is quoted. The M0 gate is
locked, its scan is deliberate, and the bytes it refused are this gate's own,
so the repair belongs here. The two pin fields are renamed to `node_pin` and
`python_pin` in the report grammar, the runner's printed report and the
support script's grammar table. The same revision conforms this document's
opening paragraphs to the recorded acceptance, which they still described as
pending; that is explanation, not a decision. No outcome, selector, witness,
limit, client pin or evidence class changes, and no lifecycle state reopens.

Binding validation, bootstrap and every inherited gate that invokes them stop
at this proposal only on the stale binding of this gate; the M4 preflight
reproduces the same declared opening red here as at the accepted candidate.
After exact-SHA review and explicit acceptance of `A`, `R` rebinds the
Acceptance row and adds one amendment-specific disposition. This proposal
records no acceptance and grants no waiver, closure or release.

| Generation | Artifact | Rebound SHA-256 |
| --- | --- | --- |
| 2 | `scripts/check-m4-gate.sh` | `baa80842b486abeb3f092f042d9ac64d83eb7eea4028d3b72b08bc62df398240` |
| 2 | `scripts/m4-gate-support.exs` | `6eb691a5fd4b1b3c3896cc38f7719c21db637b12e3c17de9dd42f24a154cefdd` |
