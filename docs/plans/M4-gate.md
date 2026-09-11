# M4 Gate

Open planning-lookahead candidate for the headless external consumer. No plan
or ADR is accepted by this revision, and M3 remains the sole implementation
authority. The runner binds a real behavioral opening probe, executable closure
lanes and exact future witness identities. Under the same preparation rule M3
recorded, future test bodies are written during implementation; every named
witness must pass before closure. The
[Concept plan](M4.md#concept) owns the six outcomes and the
[technical plan](M4-technical.md#technical-depth) owns the contracts and evidence.

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
Compile/tool failure is UNAVAILABLE (exit 2); a failed positive control is a
named WITNESS ERROR (exit 2); the observed defect is RED (exit 1). Inspection can
pass without a behavior claim. Full mode continues into its closure lanes only
after this probe becomes green. Checkpoint mode retains the observed red while
running the selected diagnostics. A missing future selector or unavailable
dependency is UNAVAILABLE, never a full-gate PASS.

## Readiness Work Before Acceptance

1. Settle ADRs 0023/0024/0026/0028 and their complete core/port contracts, then
   reconcile DTO/schema/vector bytes with the actual M3 resource facade. Before
   acceptance construct executable interaction/range witnesses and prove their
   declared reds on the unchanged base. After acceptance, require local core/port
   greens before wire implementation/rejoin. Advertise only implemented
   semantic capabilities; unknown input rules and every limit are exact.
2. Rebuild the independent raw-process probe to the full foundation
   workflow: initialize, create, attach, select an admitted skill, submit prompt,
   observe durable admission, answer the exact interaction, observe policy-
   authorized tool receipt, verify actual artifact bytes and a settled snapshot.
3. Add the TypeScript workflow and independent Elixir/Python conformance clients.
   Lock their execution versions and positive/negative vectors before acceptance.
   A missing interpreter is unavailable evidence, not PASS.
4. Complete all runner lanes before implementation: isolated compile and probe,
   inherited gates, authoritative protected selectors, whole suite, independent
   clients, attended real-provider workflow and retained-evidence validation.
   Use the existing standalone result channel. Do not build a second
   result/evidence framework.
5. Settle all floor/inventory/version holder transactions or an explicitly
   approved development-time procedural replacement, including M3, before M4
   binds replacement bytes. Name every holder and complete its own replacement
   commit, status check and exact-SHA review in sequence.
6. After M3 closes and integrates, absorb that exact base, re-prove every
   inherited gate green and this gate's own distinct red, and present the
   refreshed candidate for fresh exact-SHA review and explicit acceptance.

Neither document presence nor acceptance state can satisfy the opening. The
opening probe is proof of one missing core behavior, not of skills,
interactions, the TypeScript workflow or artifact integrity.

## Required Raw-Process Conjunction

A separate program, without loading the product codec, observes:

- exact `loopex.experimental/1`, schema digest, capabilities and bounded limits;
- no durable mutation before initialization and snapshot/cursor before live work;
- distinct transport request, durable command and interaction identities;
- command-bound admission before correlated asynchronous delivery;
- unchanged M3 catalog/selection identity and actual staged skill-use evidence;
- pending interaction, committed response, host-policy resolution and completed
  tool receipt for the exact tool call;
- bounded artifact reconstruction with distinct full-object and range hashes;
- gap-free committed events, truthful progress fallback, run.finished and
  session.settled, and a fresh authoritative settled attachment;
- protocol records only on stdout and bounded diagnostics on stderr.

A fake echo or auto-approval server fails this conjunction. Shape extraction is
not a general JSON conformance claim; independent decoding/vector tests prove
order-independent semantics and duplicate-key refusal.

Abrupt process death and fresh-process resume use actual Store data and prove no
duplicate effect. Graceful EOF/cancellation is a separate case; a cancelled
interaction does not become pending on restart.

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
| `30c7b39fcc837849302c240d029aab7c7983737af3711bd4d007549631cc107e` | `scripts/check-m4-gate.sh` |
| `775b7a9ae9b6e77621712ad6bb79aed731beee5c9f7fd19ee0ae6f1c6151b9cb` | `scripts/m4-opening-probe.exs` |
| `a34423e38152ba23e2ec7c637262641a65b87b187c523b387103ff04b2e70a85` | `scripts/m4-gate-support.exs` |
| `65d0de9dcd1218af542f00e32c2177d2612a2f1232f22db37b9942200c84cf66` | `scripts/m3-gate-support.exs` |
| `c4d485ca3229441c678abe1e8733f90216e89e0dfb9e81786f58f525619aec29` | `scripts/check-closed-gates.sh` |
| `f2e0915aa01db5bdc12c8d8f1c3b4aca177d3a5a52d44e5e5c88a4b57bc7ed0c` | `scripts/m4-outcomes.exs` |
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
--before M4`. While M3 is not Closed that lane reports UNAVAILABLE; the lookahead
posture is proved instead by running the Closed aggregate and the M3 opening
probe separately, so neither red masks the other. Run the inherited aggregate
at the acceptance base, every parallel-workstream rejoin, every rebind child,
closure candidate and whenever changed bytes invalidate its later evidence.
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
| Retained evidence | Execution output binds source/gate/commands/seed, toolchains/platforms and non-secret build/artifact identities; save that output without relabelling its source |

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
| 1 | `apps/loopex_app_server/test/initialization_test.exs` | Exact generation/schema/limit negotiation before mutation; mutation-before-init and duplicate-init refusal without durable work; stdout purity and real process boundary |
| 2 | `apps/loopex_app_server/test/session_mapping_test.exs` | Same corpus facade/wire; independent request and command identity with replay idempotency; admission vs completion; snapshot/live ordering |
| 3 | `apps/loopex/test/interaction_lifecycle_test.exs`, `apps/loopex_app_server/test/foundation_mapping_test.exs` | Durable request/answer/policy/intent cuts, fixed timestamps through uncertain commits, expiry/abort/restart races, old-reader refusal; exact resources, missing/stale trust, manual-only selection, interaction/policy separation, wire cannot select roots/modules/profiles or grant |
| 4 | `apps/loopex_store_local/test/artifact_range_test.exs`, `apps/loopex_app_server/test/delivery_bounds_test.exs` | Full-object verification before a range, distinct object/range digests, unsupported-store refusal, byte/deadline budgets; malformed UTF-8, duplicate keys, nesting, fragmented/multiple/oversized frames, blocked reader, detach cursor, late progress and actual cleanup |
| 5 | `apps/loopex_app_server/test/external_workflow_test.exs` | TypeScript skill → approval → actual tool → artifact → abrupt restart, plus separate graceful EOF behavior |
| 6 | `apps/loopex_protocol/test/public_schema_conformance_test.exs` | Independently executed Elixir, Python and TypeScript clients over canonical positive/negative vectors; exact version and platform identities |

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
| Operator-facing documentation | `docs/operator/app-server.md`, `docs/operator/coding-sessions.md`, `docs/operator/tools-and-policy.md` |
| Operator README | `docs/operator/README.md` |
| Developer-facing documentation | `docs/developer/app-server-protocol.md`, `docs/developer/app-server-protocol-technical.md`, `docs/developer/runtime-and-embedding.md`, `docs/developer/compatibility-surfaces.md` |
| Developer README | `docs/developer/README.md` |
| Documentation README | `docs/README.md` |
| Root README | `README.md` |
| Changelog | `CHANGELOG.md` |
