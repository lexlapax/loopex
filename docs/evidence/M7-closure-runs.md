# M7 closure runs

This indexed scaffold reserves evidence for the M7 coding-agent proof. Every
future identity, result and retained-output digest is `Pending`. It claims no
candidate, successful run, review, acceptance or closure. Back to the
[evidence index](README.md).

The [accepted plan](../plans/M7.md#concept) and its
[evidence requirements](../plans/M7-technical.md#technical-plan-evidence)
own scope. The [milestone guide](../developer/milestones.md#concept-milestones-close)
and [verification stages](../developer/verification.md#concept-verification-stages)
own the closure procedure. Complete immutable outputs remain outside the
repository. Record measured durations and actual source identities, including
failed attempts; unavailable evidence is never PASS.

This is an initial scaffold. The committed fixture catalog still marks its
complete execution manifest pending. Before assembling the tested candidate,
replace the pending inventories below with the exact final manifest keys,
profile rows, operator step/subcase rows and known earlier-attempt rows.
That work is an ordinary implementation change, not an administrative fill.
The T00 literal-key scaffold requirement remains open until those rows exist
and their completeness is proved.

## Candidate and source identity

| Field | Value |
| --- | --- |
| Tested implementation SHA | Pending |
| Clean source and milestone-branch identity | Pending |
| `main` ancestry before matrix, packet presentation and administrative child | Pending |
| Source `VERSION` and source identity | Pending |
| Candidate inventory and digest | Pending |
| Retained-output root reference | Pending |
| Logical matrix identity and complete invocation/attempts-index references and SHA-256 | Pending |
| Pre-dispatch continuation validation and unchanged archive-manifest digest, if used | Pending |
| Run platform, architecture and complete toolchain pins | Pending |
| Maintainer closure disposition reference | Pending |
| Administrative closure identity locator | Pending |

The tested implementation commit is the source the matrix and independent
review inspect. Its administrative direct child records the maintainer's
decision and fills only predeclared values, within the
[five-path confinement rule](../developer/milestones-technical.md#technical-milestones-confinement).
The administrative identity is located through the register's Closed
transition and any separately authorized tag; this page cannot name its own
commit. This scaffold changes neither milestone status nor progress rows.

## Closure matrix

Run the matrix once from the clean tested implementation SHA. The current-pair
fast check may be its existing CI run or a retained complete local run on that
exact SHA. Do not run it again for the same bytes. The full release check
includes attendance and Linux cross-UID proof; a selection-only or
closure-incomplete result cannot satisfy it. Use the existing
[commands and build isolation](../developer/milestones-technical.md#technical-milestones-close).
No release label, provider budget or new execution command is selected here.
M7's accepted pre-dispatch continuation rule preserves one logical matrix;
it does not retry a started case. Record every invocation and its complete
attempts index under the plan's fixed disposition rules.

| Required run | Source/run identity | Platform, architecture and toolchain | Result and measured duration | Complete retained-output reference | SHA-256 |
| --- | --- | --- | --- | --- | --- |
| Current-pair `bash scripts/check.sh`, existing exact-candidate CI or local evidence | Pending | Pending | Pending | Pending | Pending |
| Floor-pair `bash scripts/check.sh`, absolute pair-specific build root and `MIX_BUILD_PATH` removed | Pending | Pending | Pending | Pending | Pending |
| Current-pair full `bash scripts/check-release.sh`, including attended and Linux cross-UID lanes | Pending | Pending | Pending | Pending | Pending |

## Fresh-source archive and build

Retain the exact NUL-delimited tested archive manifest outside its fresh
extraction, using the
[canonical archive-extraction rule](../developer/milestones-technical.md#technical-milestones-archive-extraction)
and repository-owned `scripts/source-archive-manifest.sh`. Reject malformed
or duplicate records and verify the complete unexcluded kind/mode/path
projection against the independent source tree. This is tested-source
evidence. Administrative archive comparison and other pre-tag proofs run
later under separate release authorization and belong to retained tag proof,
not a second closure matrix or an extra evidence-page commit.

| Field | Value |
| --- | --- |
| Tested archive source SHA, extraction identity and source identity | Pending |
| Exact tested manifest retained-output reference | Pending |
| Exact tested manifest SHA-256 | Pending |
| Manifest grammar, duplicate/path/mode and independent source-tree comparison result | Pending |
| Comparison report retained-output reference and SHA-256 | Pending |
| Fresh build platform/toolchain/dependency and artifact identities | Pending |
| Fresh build result and measured duration | Pending |
| Fresh build complete output reference and SHA-256 | Pending |

## Required release lanes and additional platform proof

The [verification selection contract](../developer/verification.md#concept-verification-selection)
retains the eleven existing provider cases and Node, long-bound and Linux
cross-UID lanes. M7 adds its plan-required provider and operator cases; their
complete fixed ownership map is pending below. Shared case evidence is
referenced once and is never re-executed merely to populate another row.

| Required evidence | Exact case/run/source identity and population | Platform/toolchain/provider pins | Verdict and measured duration | Retained-output reference | SHA-256 |
| --- | --- | --- | --- | --- | --- |
| Provider 1, attended pinned Git skill workflow | Pending | Pending | Pending | Pending | Pending |
| Provider 2, attended coding task | Pending | Pending | Pending | Pending | Pending |
| Provider 3, response identity and usage | Pending | Pending | Pending | Pending | Pending |
| Provider 4, app-server workflow | Pending | Pending | Pending | Pending | Pending |
| Provider 5, model boundary | Pending | Pending | Pending | Pending | Pending |
| Provider 6, killed-tree receipt recovery | Pending | Pending | Pending | Pending | Pending |
| Provider 7, canonical session request | Pending | Pending | Pending | Pending | Pending |
| Provider 8, daemon socket workflow | Pending | Pending | Pending | Pending | Pending |
| Provider 9, Node takeover | Pending | Pending | Pending | Pending | Pending |
| Provider 10, local Ollama one-shot | Pending | Pending | Pending | Pending | Pending |
| Provider 11, hosted ephemeral embedding | Pending | Pending | Pending | Pending | Pending |
| Independent Node clients and both complete current protocol manifests/vectors | Pending | Pending | Pending | Pending | Pending |
| Long-bound proofs, including provider transport drain | Pending | Pending | Pending | Pending | Pending |
| Linux cross-UID proof with actual distinct-user identity | Pending | Pending | Pending | Pending | Pending |
| M7 unattended real-provider cases, owning lane `m7-provider` | Pending | Pending | Pending | Pending | Pending |
| M7 attended cases, owning lane `m7-operator` | Pending | Pending | Pending | Pending | Pending |
| Current-format backup/restore and unknown-effect nonredispatch | Pending | Pending | Pending | Pending | Pending |
| Darwin physical progress/output ownership, both supported pairs | Pending | Pending | Pending | Pending | Pending |
| Linux physical progress/output ownership, both supported pairs | Pending | Pending | Pending | Pending | Pending |
| Linux touched executor OS-boundary cases under pinned load, thirty runs/four cores | Pending | Pending | Pending | Pending | Pending |
| Linux touched provider OS-boundary cases under pinned load, thirty runs/four cores | Pending | Pending | Pending | Pending | Pending |

Pinned-load selection must identify the actually touched cases and preserve
the existing load, run deadlines and no-failure/no-hang criteria. Record full
case populations, exclusions, skips and invalid cases with their governing
dispositions. Preserve failed originals and first-failure records. No retry,
filter, fake real-path substitute or timeout increase is authorized here.
The [pre-1.0 disposition](../developer/agent-context-map.md#disposition-pre1-current-contract-2026-10-02)
retires old-client/old-root migration and cross-version rollback evidence;
it preserves current-format restart/replay, authority, cleanup and restore.

## Outcome-to-evidence map

Each result must name the tested source, actual execution records and exact
proof. These slots do not replace the plan's final Proved progress rows.

| Outcome | Implementation/test and execution identities | Objective verdict, measurements and limits | Retained-output references | SHA-256 digests |
| --- | --- | --- | --- | --- |
| 1, continuity across prompts and restart | Pending | Pending | Pending | Pending |
| 2, staged host instructions, provenance and authority negatives | Pending | Pending | Pending | Pending |
| 3, automatic/standalone compaction, raw history and fault truth | Pending | Pending | Pending | Pending |
| 4, provider/model/reasoning, thinking continuation and A→B→A | Pending | Pending | Pending | Pending |
| 5, model questions, exact answers, recovery and ephemeral host answer | Pending | Pending | Pending | Pending |
| 6, terminal/piped conversation and explicit configuration | Pending | Pending | Pending | Pending |
| 7, serial read-only helpers, accounting, policy and recovery | Pending | Pending | Pending | Pending |
| 8, repair/feature/review/long/external coding tasks | Pending | Pending | Pending | Pending |
| 9, named operator validation and retained objective observations | Pending | Pending | Pending | Pending |

## Fixture, profile and provider pins

| Field | Value |
| --- | --- |
| Complete execution manifest path, bytes and SHA-256 | Pending |
| Literal case IDs, owning lanes, ordered prompts/actions and oracle inventory | Pending |
| Fixture/workspace source inventories and digests | Pending |
| Immutable prompt, runner, oracle and allowed-diff digests | Pending |
| Case-specific declared bounds and counted execution-record slots | Pending |
| Immutable A/B provider/model/mode and mapping/renderer pins | Pending |
| Registered thinking-cell witness inventory and owning execution slots | Pending |
| Credential-variable-name-set pin and credential-free routing metadata | Pending |
| Selected-name redaction self-test result, retained output and SHA-256 | Pending |
| External task immutable pre-attempt specification, base SHA and allowed paths | Pending |
| External pin UTC timestamp, complete bytes/reference and SHA-256 | Pending |
| Ordered pre-dispatch pin log, completion recheck, reference and SHA-256 | Pending |
| Final demonstrated profile-key inventory | Pending |

The current catalog is `test/fixtures/m7/manifest.json`; its source verifier
explicitly distinguishes four base fixtures from the pending complete
execution manifest. Before candidate commitment, enumerate every demonstrated
profile key here with exact resolved roots/catalogs, full instruction/tool/
environment/role preimages and digests, and measured system-class estimate
strictly below 1,000 tokens. All post-run values remain Pending until observed.
Generic profile placeholders cannot prove that literal inventory complete.
Never store credential values in this record.

## operator_step_evidence

| Required inventory or join | Value |
| --- | --- |
| Complete V1–V13 step/subcase key set from committed execution manifest | Pending |
| Per-key owning case, lane/test ID, oracle, profile and execution-record slot | Pending |
| Exact mandatory attended/automated classification validation | Pending |
| Per-key operator identity, attendance authority and recorded answers | Pending |
| Per-key source, session/run/child/attempt identities and pin digests | Pending |
| Per-key expected/actual result, objective assertion and cleanup result | Pending |
| Per-key complete execution record/transcript reference and SHA-256 | Pending |
| One-to-one coverage and no duplicate/conflicting attempt-reference result | Pending |

The [accepted operator evidence specification](../plans/M7-technical.md#technical-plan-operator-validation)
requires one final row per manifest step/subcase key, including trace flag/file/
JSON subcases and separately classified positive/fault paths. The exact keys
are not yet committed. Expand this section from that manifest before the
tested candidate; do not infer final keys, attendance or profiles from these
inventory slots. The mandatory attended subset remains governed by the plan.
Automated answers cannot stand in for a named person's validation. Retired
cross-version steps are not passes; preserve current-format restore coverage.

## Case results and earlier attempts

| Required inventory or observation | Value |
| --- | --- |
| Final case-key set, execution-record slots and manifest digest | Pending |
| Per-case attempt/session/run/child identities and actual provider witnesses | Pending |
| Per-case objective outcome, allowed diff and independent oracle result | Pending |
| Per-case measured duration/turns/tokens/maximum reply and maintenance/helper totals | Pending |
| Per-case verdict, failed assertion, cause classification and cleanup | Pending |
| Per-case complete record/transcript/diff/check references and SHA-256 | Pending |
| Enumerated known earlier candidate/case/attempt identities and verdicts | Pending |
| Per-earlier-attempt diagnosis, disposition, causal correction and independent review | Pending |
| Complete earlier-attempt records/reports and SHA-256 digests | Pending |

Before commitment enumerate every known prior attempt and final case in
literal rows. Preserve the plan's distinct `product_failure`,
`model_nonconformance`, `evidence_unavailable` and `environment_failure`
dispositions, separate from its mechanical results. A new candidate
alone does not authorize replacement of a dispatched case. References shared
by multiple outcomes or operator steps denote the same execution, not an
additional paid attempt. This scaffold supplies no spending authorization.

## Security, independent and documentation reviews

| Review | Exact candidate/reviewer identity and scope | Conclusion and unresolved findings | Complete retained-report reference | SHA-256 |
| --- | --- | --- | --- | --- |
| Security, authority, credential/privacy and output/cleanup boundaries | Pending | Pending | Pending | Pending |
| Independent candidate review against all M7 outcomes and failure evidence | Pending | Pending | Pending | Pending |
| Operator/developer documentation meaning, examples and current command agreement | Pending | Pending | Pending | Pending |
| Fixture/manifest/profile/operator/attempt inventory completeness | Pending | Pending | Pending | Pending |

All labels and literal row keys must be final in the tested candidate.
The administrative child fills only the designated Pending cells; it adds no
heading, prose, row or proof obligation. Blocking review findings or missing
required evidence keep closure pending. Release/tag/publication remains a
separate maintainer decision.
