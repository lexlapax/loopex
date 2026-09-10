# M3 Gate

Candidate acceptance specification for extensible local foundations. This
revision changes documentation only. The existing runner is retained unchanged
and implements the superseded debt-only opening probes; it is not evidence that
the redesigned gate is complete. **M3 stays Open and is not acceptance-ready
until the executable readiness work below is finished and reviewed.**

The intended ordinary command remains:

```text
bash scripts/check-m3-gate.sh
```

The [Concept plan](M3.md#concept) owns outcomes; the
[technical plan](M3-technical.md#technical-depth) owns the contracts and evidence.
Acceptance must bind their final envelopes and this gate to one exact candidate.
The maintainer's request to revise and push these documents is not acceptance.

<a id="amendment-transaction-v1"></a>

After acceptance, changes use the ordinary direct proposal/rebind transaction.
Floor settlement precedes acceptance, so the floor change creates no planned M3
self-amendment. Closed M0–M2 generations retain their separate authority.

## Readiness Work Before Acceptance

1. Replace the old probe with an actual foundation-boundary workflow: resolve
   a bounded compatible skill, admit its exact manifest, observe catalog and
   selected instruction bytes in staged model input, and suspend a real session
   on policy defer. The response path must show answer admission separately
   from host authorization and actual tool execution. Use a real local Store
   and executor with a deterministic model for this opening proof.
2. Missing or refused capability is a behavioral red. Compilation failure,
   missing fixture/helper, dependency failure or inability to allocate an
   isolated root is unavailable evidence. Acceptance status, a filename,
   exported-function check, source text or test count cannot make the probe green.
3. Implement all required runner lanes before acceptance: inspection, isolated
   compile and opening probe, inherited gates, protected selectors, whole suite,
   real-provider workflow and retained-evidence validation. No unconditional
   “lane not yet written” remains in the accepted runner.
4. Construct every protected test/vector while Open. It must reach the intended
   product boundary and fail for declared missing behavior on the unchanged
   product base. The accepted candidate still has a distinct red; no milestone
   product implementation is needed to finish its test harness.
5. Refresh and bind the M2 repair inventory at exact integrated source
   `b637873ddc39542ec27add71015b46a4f7c7f80e`, using `6345ded` as the repair-range
   starting revision. Expand generated ExUnit names, preserve every inherited
   protected identity and record exact names/states/minima in one executable
   manifest. The former 79-case/18-selector table is obsolete. Do not freeze
   whole test files that this milestone must extend.
6. Validate the complete call graph and the synthetic transition where M3
   becomes Closed. The outer aggregate reads the register and runs required
   predecessor gates. Bootstrap remains a leaf dependency and never calls the
   aggregate. A closed milestone's inherited call is limited to its predecessor
   prefix, excluding itself; no skip flag or environment bypass suppresses a
   required gate. The active-runner invocation is structurally checked and
   execution is separately tested.
7. Settle prerequisite ADRs and floor/Closed-gate transactions before binding
   M3. Re-run inherited gates, the complete readiness packet and fresh
   independent review on that exact source. A stale pre-refresh red does not
   qualify the new candidate.

## Planned Opening Observation

The future opening observation records separately: acquisition/manifest identity,
trust result, catalog metadata, selected instruction digest, staged request
identity, durable pending interaction and absence of executor dispatch before
allow. It reports each boundary it reached. The declared missing behavior is:

```text
M3 gate RED: an operator cannot use an admitted compatible skill and complete a durable policy interaction through the local session workflow
```

That is the replacement to implement during gate construction. The retained
old runner currently emits its old debt-probe red and cannot supply this proof.
This document does not relabel that output or claim either a new red or PASS.

## Bound Artifacts

These are the existing scaffold bytes retained by this documentation revision.
The Open candidate refreshes this table when executable readiness is performed;
acceptance binds the final runner, harness, canonical fixtures, manifests,
configuration and authoritative result channel. Existing Closed locks remain
unchanged.

| SHA-256 | Path |
| --- | --- |
| `36fa5a17b764638ffea72aa87da4903e1e0f28f6fe5338c7c46a756184dbe6df` | `scripts/check-m3-gate.sh` |
| `cc290e60d9f9588c75f1259b25976a58d1c30713e570cd5a88c70cdf3c2159a0` | `scripts/m1-exunit-runner.exs` |
| `0a8406ca080c70624e776b01e37c7ded210b54659064cf63723a847a54debe2d` | `apps/loopex/test/m1_exunit_runner_test.exs` |
| `fad47299b27a767785d2a6a776155038054f5457ee3ce0195a37ae667f7a9999` | `.tool-versions` |

## Required Lanes

| Lane | Complete executable obligation |
| --- | --- |
| Inspection | Plan pairing/status, exact artifact identity, doc topology, dependency and invocation structure; no claim about product behavior |
| Opening | Isolated clean build and the deterministic real-Store/real-executor foundation probe; credential-free |
| Inherited | Bootstrap and every required Closed gate's exact command, full required credential lanes and truthful failure propagation |
| Protected outcomes | Existing standalone ExUnit runner, seed 3107, exact per-selector case identities/states and minima; no skipped or excluded protected case |
| Whole suite | Complete credential-free suite, formatting, warnings-as-errors compilation and documentation/dependency checks |
| Real workflow | Attended public-source import and real-provider coding task using admitted skill content, durable approval, actual tool result and artifact inspection |
| Retained evidence | Exact source/gate/command/seed/limits/toolchain/platform and non-secret build identities; artifact digests and all required outcome classes |

Reuse M1/M2's existing authoritative result and isolated provider machinery.
Ordinary mode's provider input is a bounded non-exported stdin frame, translated
only at the inherited or explicitly tagged real-provider lane. Inspection and
opening require no credential. Do not make “no credential lane” coexist with a
mandatory real workflow, or substitute the inherited M2 task for the new skill
workflow. Every required command is present before the gate is accepted.

## Protected Outcome Obligations

| Outcome | Protected selector family | Required clauses |
| --- | --- | --- |
| 1 | `apps/loopex_composition/test/skill_acquisition_test.exs` | Pinned Git and explicit HTTPS; complete file identity; no ambient traversal or script execution; cap/timeout/cancel/containment failures; atomic install cuts and previous-pack preservation |
| 2 | `apps/loopex/test/skill_context_test.exs` | Catalog before instructions; requested resources only; manual-only and duplicate-name rules; trust invalidation; complete staged request/digest capture; all four admission dimensions; no refetch or ambiguous provider redispatch |
| 3 | `apps/loopex/test/interaction_lifecycle_test.exs` | Pending/answered/allowed distinctions; request/answer/grant/intent transaction cuts; uncertain commit with fixed time; idempotency; expiry/abort/deadline and repeated defer; matching policy after restart; no effect from answer alone |
| 4 | `apps/loopex_cli/test/foundation_workflow_test.exs`, `apps/loopex_store_local/test/artifact_range_test.exs` | Same embedded/CLI behavior; trusted launch/recovery consistency; built CLI and provider companion; full-object/use/range integrity; bounded allocation; descriptor and process cleanup |
| 5 | Context admission, dispatcher availability and provider-attempt protocol selectors | Required-only property through cardinality 1,024; maximal receipt shape; old refusal replay; held-Store multi-session latency; asynchronous publication fences; bounded retention plus stale/retired permit refusal and succession |
| 6 | `apps/loopex/test/closed_gate_aggregate_test.exs`, integrated repair inventory | Register-derived commands; missing/unreadable/red/omitted invocation; bootstrap back-edge; synthetic M3 closure; exact repair identities; real test-honesty mutations and cross-VM scratch allocation |
| 7 | All above plus closure evidence | Genuine prior-format positive controls, new-format refusal before effects, early and final platform/build proof, complete self-audit and documentation |

The final executable manifest expands these families into exact case names,
state, minimum, application owner and permitted compiled dependency closure.
Selection is claim-proportional: properties for reducers, conformance for
boundaries, real process/Store faults for durability, negative authority cases
for trust and real packages/paths where claimed. The table is not a substitute
for executable tests and does not freeze hypothetical counts.

## Test Honesty and Review

The M2 failure pattern is addressed by early integrated proof and explicit
obligation ownership. Every negative first proves it reached its intended
boundary. Mutations attack the actual clause and sibling transition, not an
adjacent setup check. Preserve legacy assertions when repairing a case.
Re-audit repeated finding classes across all entrypoints before handing the
candidate back. The implementer completes the integrated self-audit before
independent review; neither actor accepts its own result.

Freeze clean source S for final evidence. Record result identity at S; changes to
shared contracts/launch/configuration invalidate all affected evidence, with
unknown impact defaulting to the full gate. Evidence-only descendants do not
relabel an earlier result as a later run. Required real paths, rollback controls,
platforms and operator demonstrations cannot be inferred from synthetic tests.
A red check or unresolved blocking finding blocks closure. A disappearing
same-source failure is a blocking flake, not a successful retry.

## Documentation Obligations

| Category | Required closure disposition |
| --- | --- |
| Operator-facing documentation | `docs/operator/coding-sessions.md`, `docs/operator/tools-and-policy.md`, `docs/operator/how-a-run-works.md`, `docs/operator/how-a-run-works-technical.md` |
| Operator README | `docs/operator/README.md` |
| Developer-facing documentation | `docs/developer/runtime-and-embedding.md`, `docs/developer/agent-loop-and-tools.md`, `docs/developer/architecture.md`, `docs/developer/architecture-technical.md`, `docs/developer/compatibility-surfaces.md`, `docs/developer/agent-context-map.md` |
| Developer README | `docs/developer/README.md` |
| Documentation README | `docs/README.md` |
| Root README | `README.md` |
| Changelog | `CHANGELOG.md` |
