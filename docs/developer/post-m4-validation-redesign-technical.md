# Post-M4 validation redesign: technical depth

<a id="technical-depth"></a>
## Technical depth

Concept: [Post-M4 validation redesign](post-m4-validation-redesign.md#concept).

<a id="technical-post-m4-profiles"></a>
### 6. What runs, and when

Keep Mix, ExUnit, Elixir standard-library, Git, and shell tools. Use a small
explicit entrypoint and a few named profiles, not a scheduler, workflow language,
receipt database, or trusted pass cache.

| Profile | What it proves | Trigger and separation |
| --- | --- | --- |
| Local | Current-tree hygiene and contracts, dependency direction, warning-free builds, and the ordinary credential-free regression corpus. Small checker tests run here once. | Every product integration candidate; focused subsets while editing. Applying a repository check must not launch its own test suite again. |
| Client qualification | Independent-language agreement, wire refusals, and actual client/server behavior. | Before closure and when protocol/client behavior is affected. Pinned Node is a client-test prerequisite, not a dependency of the repository checker. Local-only results do not imply this ran. |
| Live integration | Each distinct required real-provider or real-system workflow and its failure/recovery claim. | Before closure and when the relevant integration changes. Keep credentials out of ordinary test processes. Do not replace a required real path with a fake. |
| Source qualification | A fresh archive build and operator workflow against extracted source, with actual source/artifact identities. | Before closure or release that claims source delivery, and when affected. Put extraction tests here rather than building the same archive again locally. |

The required runtime/platform matrix is an outer set of environments, not another
nested gate. It runs the necessary profiles once per distinct tuple. Floor,
platform-sensitive, and dependency changes trigger affected matrix checks earlier.
Unknown cross-cutting impact selects the current local profile and plausibly
affected qualification environments, not historical runners. Keep actual profile
requirements explicit in the short guide.

Do not silently drop slow durability or security tests from the local corpus to
reach a timing target. Moving a test to a less frequent profile needs an explicit
schedule and the proposed approval treatment in section 4.

Useful distinctions survive deduplication. Core-only proof already runs through
an isolated child-VM test; do not invoke the same command again beside the suite.
Its build remains separate. Old-reader fixtures must not share writable build
roots with current code. Crash-after-receipt recovery and restart-during-interaction
are different live claims; keep both unless a replacement proves both.
Fresh-source compilation proves something an incremental build cannot.

Concept: [One progression and one evidence-reuse rule](post-m4-validation-redesign.md#concept-post-m4-progression).

<a id="technical-post-m4-history"></a>
### 7. Current checks without a permanent history engine

The integrator supplies the approved baseline and candidate. Validate current
records, referenced approved source identities, and changes from that baseline.
Review and disposition records supply authority; Git supplies identity and
ancestry, not proof that a human approved or that tests ran.

Reject a missing required checkpoint, mismatched candidate, or unexplained change
to a protected current contract. Assess a merge by its resulting candidate and
relevant changes. Do not reject it solely because a corrected work commit violated
the old transaction sequence. Preserve historical approvals and evidence at their
recorded revisions.

The old status command is not git fsck. It audits records, bindings, ancestry,
and amendment semantics across reachable history. Remove that complete semantic
walk from routine validation. Small synthetic and real Git fixtures test the
replacement. Forensic use of old tooling can use its historical source; do not
maintain a second live history validator by default.

Concept: [Decision and purpose](post-m4-validation-redesign.md#concept-post-m4-decision).

<a id="technical-post-m4-tests"></a>
### 8. Test design and concurrency serve the same contract

Follow behavior and boundaries. Reuse conformance suites for new adapters, retain
unit/property checks near their logic, and use a smaller set of integrated
workflows to prove composition. Do not multiply every workflow by every internal
option without an identified interaction risk.

When replacing a design, delete exclusive fixtures and shape assertions after
preserving continuing behavioral evidence. Assess important witnesses against
the failures they claim to detect. Mutation testing is one technique, not a new
mandatory ceremony for every test edit.

Two examples show why assertions need review. The transfer memory witness measures
chunk size rather than retained memory; the normal implementation streams by
inspection, so this is an evidence-improvement opportunity, not a demonstrated
product bug. The reference-client test fixes three private struct fields, although
the lasting boundary is that the client owns neither durable truth nor policy.

Measure the flattened suite before sharding. If execution still dominates, use
a few separate BEAM processes with disjoint writable builds, temporary directories,
homes, and workspaces. Existing tests change global environment, registered names,
tracing, telemetry handlers, and signal handling. Blanket async settings would
create interference. Reuse only immutable outputs workers cannot overwrite.
Bound total CPU and I/O concurrency, compare a small number of worker counts,
and retain only measured improvements without new flakes.

Failure followed by success is not silently clean evidence. Diagnose it or use
an explicit failure disposition. Do not inflate retries or shorten meaningful
time/fault boundaries to improve the timing report.

Concept: [Evolving architecture and proportionate approval](post-m4-validation-redesign.md#concept-post-m4-changes).

<a id="technical-post-m4-transition"></a>
### 9. One transition, five implementation steps

The enduring artifacts are tests and commands, one short verification guide, and
concise AGENTS rules routing to them. A one-time coverage reconciliation supports
migration; it must not become another manually maintained test manifest. Existing
plans and ADRs retain product decisions and source-bound acceptance. No new family
of milestone runners or duplicated test inventories.

| Step | Scope and completion evidence |
| --- | --- |
| 1. Settle the forward policy | Resolve sections 4 and 5. Approve replacing historical holder transactions, intermediate-commit validity, recursive gates, and elaborate opening-red preparation. Record necessary prospective ADR supersession without changing historical accepted records. |
| 2. Reconcile and implement | On the settled M4 baseline, map continuing claims to section 6. Write the short guide, flatten execution, and replace routine history validation. Use existing tests first; do not require a wholesale quality rewrite before obtaining savings. |
| 3. Qualify and switch defaults | Run the replacement on an exact candidate in required environments. Use final M4 evidence as historical reference, without rerunning the old aggregate solely to start this project. Review omissions, source/evidence identity, failure propagation, and command counts. Switch CI, hooks, and developer commands together. |
| 4. Delete the obsolete system | Remove predecessor aggregates, superseded runners, exclusive helpers and tests after migrating callers. Reproduce old checks from original Git revisions, not another maintained archive tree. Shorten AGENTS and keep the context map as routing rather than an approval transcript. |
| 5. Reduce remaining measured cost | Target dominant setup, repeated scenarios, brittle fixtures, and concurrency bottlenecks. Use subsequent work to measure the milestone-level share and verify affordability as architecture changes. |

Step 1 must explicitly replace conflicting requirements. The vision does not
prescribe every-commit semantic validation or perpetual Closed-gate execution.
ADR 0026's completed floor migration remains historical fact; its future
restoration clause and ADR 0002's locked-matrix language need prospective treatment
if they conflict. An AGENTS edit alone cannot silently supersede them. The forward
decision replaces the procedure rather than requiring each old holder to adopt
the replacement separately.

Completion means one ordinary suite and one application of current repository
checks for matching candidate inputs and environment, no predecessor recursion,
and coverage of continuing guarantees. Closure reuses matching integration results.
An internal refactor must not require historical rebindings; a new adapter must
not require copying a gate. Review those scenarios against the guide rather than
implementing throwaway features to prove them.

The approved forward policy authorizes focused replacement checks and retained
product tests on the transition branch. Obsolete holder transactions and semantic
history failures must not block their own removal there. They are superseded
requirements, not results to misreport as passing. Old defaults remain elsewhere
until the replacement qualifies and the default commands switch.

Do not double-run both systems on every edit. Newly authored feature tests may
be red during development; inherited regressions still require repair before
integration. If qualification misses a required guarantee, fix it before switching.
If a defect appears afterward, repair it or revert the cutover to the recorded
baseline. Do not restore permanent parallel maintenance of both systems.

Concept: [Decision and purpose](post-m4-validation-redesign.md#concept-post-m4-decision).

<a id="technical-post-m4-evidence"></a>
### 10. Evidence supporting the proposal

The audit used frozen source 357c36be93c4705415d62c899592367ec879bbb2. That is a
pending M3 generation proposal in the M4 lineage, not a green closure candidate. No expensive gates,
provider calls, or product suites ran for this analysis. Counts describe the
statically traced success path, not execution measured at that revision.

| Evidence | Frozen-source location or retained record |
| --- | --- |
| Milestone capabilities in section 2 | Outcome tables in docs/plans/M0.md:18, M1.md:29, M2.md:40, M3.md:33, M4.md:31. |
| M4 runs a suite and predecessors; M3 repeats the pattern | scripts/check-m4-gate.sh:292 and :311; scripts/check-m3-gate.sh:312 and :330; local aggregate ledger at scripts/check-closed-gates.sh:47. |
| Eight suites, eight bootstraps, twelve full status applications, 168 selectors including 14 real selectors | Expanded script graph. Selector invocations are not test-case counts. Seventeen explicit compile commands are not necessarily seventeen cold builds. |
| Status application launches its own tests | scripts/check-status.sh:16; bootstrap calls it at scripts/check-bootstrap.sh:32. |
| Avoidable real-repository read in a checker test | apps/loopex/test/status_check_test.exs:2260; replace the reader fixture with a tiny real repository. |
| Refactor-sensitive and incomplete property evidence | apps/loopex_reference_client/test/reference_client_test.exs:118; apps/loopex_store_local/test/artifact_transfer_test.exs:600 and :829. |
| Shared-state barriers to parallelism | session_directory_test.exs:10, runtime_test.exs:8, provider_build_test.exs:62, prepared_recovery_contract_test.exs:1981, telemetry_boundary_test.exs:395. |
| Core-only evidence already in the suite | apps/loopex/test/core_only_test.exs:8 invokes its isolated build. |
| Historical cost | M1 matrix: 8,125/8,332/5,553 seconds at 16f6502. M4 bootstrap: 2,342 seconds at 08782a0, with status/history tests taking 37.1 seconds. These predate later caching. |
| Improvements already delivered | a822c63 records status 2,531 to 1,340 seconds; 9b7a9a2 records 1,340 to 353. Preserve those fixes and progress output; do not present them as missing work. |

Other delivered repairs include build-root isolation at 007ef56, dependency source
correction at ec018d2, Node cases separated from ordinary suites at 16f6502, and
artifact fixture isolation at d4d6699.

Before claiming a speedup, record source, environment, warm/cold conditions, profile
wall time, duplicate invocations, and provider calls. Compare like with like.
Source inspection establishes repeated invocations; the replacement and subsequent
work must establish the actual time reduction and verification share.

Concept: [The problem is accumulated procedure, not capability progression](post-m4-validation-redesign.md#concept-post-m4-diagnosis).

Concept: [The 15-20% target must include the work we remove](post-m4-validation-redesign.md#concept-post-m4-cost).
