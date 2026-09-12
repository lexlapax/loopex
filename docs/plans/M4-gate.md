# M4 Gate

Open planning-lookahead candidate for the headless external consumer. No plan
or ADR is accepted by this revision, and M3 remains the sole implementation
authority. The runner binds a real behavioral opening probe, executable closure
lanes and exact future witness identities. Under the same preparation rule M3
recorded, future test bodies are written during implementation; every named
witness must pass before closure. The
[Concept plan](M4.md#concept) owns the seven outcomes and the
[technical plan](M4-technical.md#technical-depth) owns the contracts and evidence.
The reviewed
[planning-revision aggregate override](../developer/agent-context-map.md#override-disposition-m4-planning-aggregate-2026-09-11)
and its reviewed
[widened scope](../developer/agent-context-map.md#override-disposition-m4-planning-aggregate-scope-2026-09-11)
let every revision of this Open lineage (plan and gate documents, manifests,
runner and support work, ADR proposals, documentation, and repository-status
enforcement with its tests, with no product bytes and bootstrap green) rely on
the M0–M2 aggregate proved at the opening candidate; they waive nothing for
product changes, Closed-bound bytes, the refresh, acceptance, rejoin, rebind or
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
acceptance, amendment or override is recorded by this opening.

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

1. Settle ADRs 0023/0024/0026/0028 and their complete core/port contracts, then
   reconcile DTO/schema/vector bytes with the actual M3 resource facade. ADR 0028
   carries the decided one-verification-per-transfer design and must bind every
   limit the technical plan names; ADR 0023 must carry the connection state
   table; ADR 0024 must fix the successive-round bound. Advertise only
   implemented semantic capabilities; unknown input rules and every limit are
   exact.
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
   commit, status check and exact-SHA review in sequence.
4. After M3 closes and integrates, absorb that exact base, re-prove every
   inherited gate green and this gate's own distinct red, and present the
   refreshed candidate for fresh exact-SHA review and explicit acceptance.

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
| `696b6a8c34cd3f92a7fe7e3473ec3e25e77384a48241c94aa777323fb085a502` | `scripts/check-m4-gate.sh` |
| `a559bd9f44f1f46f65aaff0bdcfcac2e5124301bc367c58c85966fd6409ba68f` | `scripts/m4-opening-probe.exs` |
| `8941f7f0e84b68feabac8e4f6e5706a0aabba6049dca6be8b5745e81f8fcc57e` | `scripts/m4-gate-support.exs` |
| `65d0de9dcd1218af542f00e32c2177d2612a2f1232f22db37b9942200c84cf66` | `scripts/m3-gate-support.exs` |
| `c4d485ca3229441c678abe1e8733f90216e89e0dfb9e81786f58f525619aec29` | `scripts/check-closed-gates.sh` |
| `5470c64bdecb58f64ac3b4e53bf6dc9e1a2a056b4d5947e1c934047c7e19fbc9` | `scripts/m4-outcomes.exs` |
| `cc290e60d9f9588c75f1259b25976a58d1c30713e570cd5a88c70cdf3c2159a0` | `scripts/m1-exunit-runner.exs` |
| `0a8406ca080c70624e776b01e37c7ded210b54659064cf63723a847a54debe2d` | `apps/loopex/test/m1_exunit_runner_test.exs` |
| `fad47299b27a767785d2a6a776155038054f5457ee3ce0195a37ae667f7a9999` | `.tool-versions` |

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
--before M4`. While M3 is not Closed that lane reports UNAVAILABLE. The
lookahead posture was proved once at the opening candidate by running the
Closed aggregate and the M3 opening probe separately, so neither red masks the
other; under the widened override above, later Open-lineage revisions rely on
that result and rerun only status, formatting, bootstrap, inspection and the
two opening probes. Run the inherited aggregate at the refreshed acceptance
base, every parallel-workstream rejoin, every rebind child, closure candidate
and whenever product or Closed-bound bytes invalidate its later evidence.
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
| Real workflow | Separately selected attended real-provider task through the shipped server and TypeScript consumer |
| Retained evidence | One final report line in the exact grammar below, validated by the bound support script before it is printed; the real selector's authoritative report binds provider/model/endpoint and version-aware adapter/executor build identities; save that output without relabelling its source |

The pinned Node and Python interpreters are verified immediately before each
client-backed selector (the external workflow, its real-provider file and the
schema conformance file) in checkpoint and full modes alike; absence or
mismatch is UNAVAILABLE, never RED.

The retained final report has exactly this grammar, one line, fields in this
order, each present once:

```text
LOOPEX_M4_GATE_REPORT source=<40 hex> gate=sha256:<64 hex> version=<major.minor.patch> role=full seed=3107 outcome_ids=1,2,3,4,5,6,7 selectors=<count> elapsed_seconds=<n> elixir=<exact> otp=<exact, e.g. 29.0.5> erts=<exact> platform=<system architecture> node=<pinned> python=<pinned> clients=sha256:<64 hex> schema=sha256:<64 hex> inherited=true real_workflow=true result=PASS
```

`role` names the command role that produced the line (only the full role
reports); `selectors` is the number of authoritative selector reports the
ledger accounted for; `elapsed_seconds` is the whole run's wall time;
`clients` is the digest of the bound client toolchain pins; `schema` is the
digest of `apps/loopex_protocol/priv/schema/loopex-experimental-1.json`, the
canonical schema bytes the protocol application ships, which also carry every
negotiated limit. The support script refuses a line with a missing, duplicated,
reordered or malformed field, and the bound
`apps/loopex/test/m4_gate_support_test.exs` witnesses retain that refusal for
both report kinds and the final grammar.

Real-provider tests live in the dedicated
`apps/loopex_app_server/test/external_workflow_real_test.exs`. Full mode accepts
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
| 1 | `apps/loopex_app_server/test/initialization_test.exs` | Exact generation/schema/limit negotiation before mutation; mutation-before-init and duplicate-init refusal without durable work; stdout purity and real process boundary; strict UTF-8/LF framing and the exact method inventory with unknown mutating methods refused before admission and unknown queries answered with a bounded error; every ADR 0023 connection-state row from before initialize through restart |
| 2 | `apps/loopex_app_server/test/session_mapping_test.exs` | Same corpus facade/wire; independent request and command identity with replay idempotency; admission vs completion; snapshot/live ordering; second-attach refusal or explicit replacement at the last emitted cursor; in-flight request-ID reuse refused and post-completion reuse ordinary; pre-admission pressure refusing before any durable write and post-admission pressure dropping progress first then detaching at the last emitted cursor; snapshot, event, progress and diagnostic record families kept separate with a fresh settled attachment as the final authority |
| 3 | `apps/loopex/test/interaction_lifecycle_test.exs`, `apps/loopex_app_server/test/foundation_mapping_test.exs` | Durable request/answer/policy/intent cuts journaled before publication and before any intent, fixed timestamps through uncertain commits, expiry/abort/restart races, the exact successive-round bound, old-reader refusal; answered-but-unresolved recovery without speculation, acknowledgement or dispatch; identical replay returns the historical admission while changed content, wrong-target, resolved, expired or absent interactions refuse with stable reasons; invalid answers, malformed policy output and failed or timed-out re-evaluation dispatch nothing and resolve as denial; policy-request, interaction-request and answer digests with their preimages preserved through commit_unknown and restart under the same policy identity and revision; exact resources, missing/stale trust, manual-only selection, answer admission separate from re-evaluation and grant/intent, immutable launch inputs unreplaceable from the wire |
| 4 | `apps/loopex_store_local/test/artifact_transfer_test.exs`, `apps/loopex_app_server/test/delivery_bounds_test.exs` | The attachment-owned open/read/close API refusing another attachment, session or runtime and disclosing no path; complete verification at open with one verification per transfer, distinct object/chunk digests, unsupported-store refusal; whole, first, last, empty and overrun windows and every distinct refusal reason; wrong-session use, object/use swap, corruption outside the requested window, post-open same-size rewrite never reaching a chunk; open deadline or work-budget exhaustion refusing before any snapshot bytes; per-connection and per-runtime transfer limits refusing independently; connection-work exhaustion, lifetime expiry, cancellation, descriptor and snapshot release across repeated kill/restart, streaming memory bounded well above the chunk ceiling and startup scavenging touching only owned regular files; genuine old-format artifacts readable and capability removal restoring the prior API; chunk/read-deadline budgets; at the wire, a transfer reference from another connection refused and connection loss closing every transfer it opened; malformed UTF-8, duplicate keys, nesting, fragmented/multiple/oversized frames, blocked reader, detach cursor, late progress and actual cleanup |
| 5 | `apps/loopex_app_server/test/external_workflow_test.exs` | TypeScript skill → interaction answer → policy re-evaluation → committed grant/intent → actual tool → artifact → abrupt restart from operator input with no embedded identities; clean stdin EOF performs orderly shutdown with no cancellation; abrupt death records nothing; a pending interaction survives both; `session.abort` is the only cancellation and an aborted interaction never reappears |
| 6 | `apps/loopex_protocol/test/public_schema_conformance_test.exs`, `apps/loopex/test/m4_gate_support_test.exs` | Independently executed Elixir, Python and TypeScript clients over canonical positive/negative vectors under the pinned interpreters; exact version and platform identities; retained refusal of missing, duplicated, reordered, wrong-kind, stale-version and malformed evidence fields |
| 7 | `apps/loopex/test/trace_session_test.exs`, `apps/loopex/test/telemetry_boundary_test.exs` | Session scoped to owned processes and allowed modules with a second VM tracer unaffected; documented fields per level; redaction of credential references, model content, tool arguments and artifact bytes at the `arguments` level; limits drop with a counted entry without blocking; no session command, client content, model output, project resource or wire request starts, changes or stops a session; stop releases every flag; unavailability on a release without trace sessions; every boundary emits start/stop or exception with duration and documented metadata only; crashing handler isolated; overheads measured |

Each required clause maps to a named decisive witness in `scripts/m4-outcomes.exs`.
Related clauses may share one named case only when it contains distinct observed
assertions for them. Additional ordinary-suite negatives remain required to pass
but their names and whole-file counts are not locked. Canonical fixture, harness
and result-channel bytes are digest-bound; mutable test files are protected by
witness identity and required state. No protected witness may be removed,
renamed, skipped or excluded without an accepted amendment or an explicitly
approved scoped override. The app-server adds zero external production
dependencies; the existing ReqLLM edge dependency closure remains allowed.
Exactly nine application identities and the existing role set are checked after
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
publication and compatibility acceptance retain their distinct authorities.

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
  client interpreter pins and the 0.1.0 source version; and what remains
  experimental or unavailable (no daemon, sockets, takeover or publication).
- **Developer-facing.** The observability pair as the reference for the
  trace-session contract, the telemetry event catalog and the redaction and
  limit rules; the protocol pair as the normative wire reference
  (methods, records, identities, limits, schema and vector identities); the
  ninth application, the changed client-role dependency rule and the
  dependency direction; the core interaction lifecycle and the ArtifactStore
  transfer capability as embedding contracts; the experimental labels and
  exact-generation rule in the compatibility surfaces; and the context map's
  routing for M4's ADRs, documents and gate.
- **Repository-wide.** `docs/README.md`, `README.md` and `CHANGELOG.md`
  describe the ninth application, the new operator and developer documents,
  the version transition and its non-release meaning, and the M4 outcome
  evidence, without claiming any package, tag or publication.

The status check limits the developer-facing row to `docs/developer/` paths, so
`DEVELOPMENT.md` is named here instead: it is updated at closure for the ninth
application, the refreshed floor pair, the client toolchain pins and the M4
runner commands, and its drift blocks closure exactly like a row above.
