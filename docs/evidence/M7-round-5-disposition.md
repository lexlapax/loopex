# M7 round 5 disposition

## Concept

The external [round 5 report](M7-external-review-5.md) rejects planning candidate
`a2ce04c2862d2d15e58eed317379a3b6684c4286`. This record reconciles all 50 findings
and the internal adversarial review of the repairs. It supersedes round 4's
readiness conclusion without rewriting that historical report or disposition.

The maintainer selected A for fully recorded provider/network outages: retain
the failed attempt, require independent causal classification and permit the
affected case on a new candidate. The earlier evidence-loss correction rule
continues. The maintainer also selected ordinary thinking availability at M7
closure: register the cells in the tested bytes, then require their counted live
witnesses before closure. The [outage choice](../developer/agent-context-map.md#disposition-m7-round5-outage-2026-09-30)
and [thinking choice](../developer/agent-context-map.md#disposition-m7-round5-thinking-support-2026-09-30)
record these decisions. Optional extra live calibration remains unselected.

M7 remains Open, ADRs 0041–0049 Proposed, and both labelled vision amendments
unaccepted. These are planning repairs and implementation obligations, not
product tests, successful demonstrations or formal acceptance. The root repair
and fresh advisory review/fix/recheck loop are complete. Neither reviewer found
a remaining contradiction in the final focused recheck. The documentation
check of the exact committed candidate and verified push remain before handoff.

## Technical depth

The received report is retained byte-for-byte with SHA-256
`4a6567f11620eb3a09e8a0a7ccead61cade8e7a120c375bf3401eaa715bff74e`.
Its read-only method and provider/toolchain evidence limits remain those stated
in that report. No provider call, product suite or release lane ran for these
text repairs. Literal schema/vector/fixture pins remain phase-0 implementation
obligations before affected code is integrated; naming one does not prove it.

| ID | Disposition | Owning contract and repair |
| --- | --- | --- |
| 1 | Proposal repaired | [0043](../adr/0043-context-compaction-checkpoint-technical.md#technical-adr-0043-decision): Pending-summary progress and applicable limit checks precede checkpoint commit; rejection retains settlement evidence only. |
| 2 | Proposal repaired | [0043](../adr/0043-context-compaction-checkpoint-technical.md#technical-adr-0043-decision): Minimum-tail release covers every terminal-run unit oldest-first, including later failed/cancelled input-only units. |
| 3 | Proposal repaired | [0043](../adr/0043-context-compaction-checkpoint-technical.md#technical-adr-0043-decision): Command origin and trigger are separate; only canonical_rendering continues for rendering, standalone never captures thinking_headroom. |
| 4 | Proposal repaired | [0043](../adr/0043-context-compaction-checkpoint-technical.md#technical-adr-0043-decision): Standalone command refusal/abort rules, a completion event and last_compact snapshot make every terminal result discoverable. |
| 5 | Proposal repaired | [0043](../adr/0043-context-compaction-checkpoint-technical.md#technical-adr-0043-decision): Closed failure v2 carries measurement_scope through public/run/compact views; nonnumeric measured scope is ordinary. |
| 6 | Obligation explicit | [0043](../adr/0043-context-compaction-checkpoint-technical.md#technical-adr-0043-decision): Maintenance admission needs a deterministic natural-completion v3 vector; v2/unknown-only adapters refuse before paid dispatch. |
| 7 | Obligation explicit | [0043](../adr/0043-context-compaction-checkpoint-technical.md#technical-adr-0043-decision): Missing captured route/renderer changes no durable fact; restoring it and restarting resumes the same episode. |
| 8 | Obligation explicit | [0043](../adr/0043-context-compaction-checkpoint-technical.md#technical-adr-0043-decision): Maintenance stage/substates are literal, and one closed terminal result serves run-owned and standalone episodes. |
| 9 | Clarified | [0043](../adr/0043-context-compaction-checkpoint-technical.md#technical-adr-0043-decision): Explicit origin releases eligible terminal tail; automatic preference remains. Unprepared inline sources stay fixed until selected preparation. |
| 10 | Proposal repaired | [0041](../adr/0041-session-lineage-projection-and-context-budget-technical.md#technical-adr-0041-decision): Resolve committed use membership before policy; unknown/orphan/foreign/forged uses share invalid_tool_arguments. |
| 11 | Proposal repaired | [0041](../adr/0041-session-lineage-projection-and-context-budget-technical.md#technical-adr-0041-decision): Exact ID/version lookup plus loader-enforced immutable capability-table digest match supplies the promised identity; no imaginary job digest field. |
| 12 | Obligation explicit | [0041](../adr/0041-session-lineage-projection-and-context-budget-technical.md#technical-adr-0041-decision): Names the core capability module; resolve derives artifact_read and normalize compares its complete binding. |
| 13 | Proposal repaired | [0049](../adr/0049-explicit-host-configuration-technical.md#technical-adr-0049-decision): Owner retains and re-presents the original transaction on a bounded timer; observational command_disposition has producing committed/non-commit/pending paths. |
| 14 | Obligation explicit | [0049](../adr/0049-explicit-host-configuration-technical.md#technical-adr-0049-decision): Six-row shutdown table pins error/wait/closing sequence, original input sequence, committed IDs and the single cli_backstop deadline. |
| 15 | Obligation explicit | [0049](../adr/0049-explicit-host-configuration-technical.md#technical-adr-0049-decision): Every post-preparation refusal abandons the prepared owner, including binding/policy/workspace/route failures. |
| 16 | Clarified | [0041](../adr/0041-session-lineage-projection-and-context-budget-technical.md#technical-adr-0041-decision): Phase-0 owner pins retaining grep/find/ls generations and allowances at least to capture ceilings; offset is unsigned 64-bit. |
| 17 | Maintainer choice recorded | [0044](../adr/0044-run-model-and-reasoning-configuration-technical.md#technical-adr-0044-decision): A selects ordinary registration in tested bytes after deterministic conformance; nine cells name counted continuation/post-terminal/summary witnesses, with no candidate-only state or later source edit. |
| 18 | Proposal repaired | [0044](../adr/0044-run-model-and-reasoning-configuration-technical.md#technical-adr-0044-decision): Host resolves generic thinking_disabled; core gates on that Boolean, while host/adapter own manual-budget relations. |
| 19 | Obligation explicit | [0044](../adr/0044-run-model-and-reasoning-configuration-technical.md#technical-adr-0044-decision): Literal stop classification and four relation rows distinguish nil/open/closed capsules and bounded started-call failure. |
| 20 | Obligation explicit | [0044](../adr/0044-run-model-and-reasoning-configuration-technical.md#technical-adr-0044-decision): Exact v2/v3 key sets, mandatory provider_response_id, named eight-key rejection and Model-port fixture/type migration are explicit. |
| 21 | Obligation explicit | [0044](../adr/0044-run-model-and-reasoning-configuration-technical.md#technical-adr-0044-decision): Names both Finch mutation hooks, final header/beta allowlist, fixed safe refusal and buffered validation immediately before HTTP. |
| 22 | Proposal repaired | [0044](../adr/0044-run-model-and-reasoning-configuration-technical.md#technical-adr-0044-decision): A native response-model mismatch fails the attempt before reply settlement; suppression alone cannot count as success. |
| 23 | Obligation explicit | [0044](../adr/0044-run-model-and-reasoning-configuration-technical.md#technical-adr-0044-decision): Callback inventory covers ReqLLM.Streaming and StreamServer plus typed protocol final flush. |
| 24 | Clarified | [M7](../plans/M7-technical.md#technical-plan-evidence): Post-terminal witnesses require actual native thinking classification for continuation-required cells; empty assistant messages are omitted. |
| 25 | Proposal repaired | [0046](../adr/0046-child-session-tool-technical.md#technical-adr-0046-decision): Complete intent/terminal query join excludes committed pre-effect refusals from expected operations/count reconstruction; restart witnesses cover exhausted allowance and unknown role. |
| 26 | Proposal repaired | [0046](../adr/0046-child-session-tool-technical.md#technical-adr-0046-decision): Removes stale global-fence wording; active row reclamation, per-ID tombstones and overflow-only helper fence agree. |
| 27 | Proposal repaired | [0046](../adr/0046-child-session-tool-technical.md#technical-adr-0046-decision): Tombstoned registration returns tagged cancelled_before_registration refusal; conclusive Local receipt is checked before tombstone allocation. |
| 28 | Obligation explicit | [0046](../adr/0046-child-session-tool-technical.md#technical-adr-0046-decision): Helper reply margin does not apply to Local forwarding; direct/routed boundary answers have conformance. |
| 29 | Obligation explicit | [0046](../adr/0046-child-session-tool-technical.md#technical-adr-0046-decision): Only unresolved helper jobs re-register; historical local jobs use conclusive receipt or the unknown-ID path. |
| 30 | Obligation explicit | [0046](../adr/0046-child-session-tool-technical.md#technical-adr-0046-decision): Versioned disposable derived index has a null-before-frame state, exact binding projection and separate before/after-effect write-failure routes; compatibility inventory includes it. |
| 31 | Obligation explicit | [0046](../adr/0046-child-session-tool-technical.md#technical-adr-0046-decision): Exact-genesis live create result union and ADR 0008/0016 amendment scope are stated in the plan and Concept. |
| 32 | Obligation explicit | [0046](../adr/0046-child-session-tool-technical.md#technical-adr-0046-decision): Correct deterministic external_size recipe; cross-toolchain exact-create/provenance fixtures and unsupported Store callback outcome are required. |
| 33 | Obligation explicit | [0046](../adr/0046-child-session-tool-technical.md#technical-adr-0046-decision): Durable hosts classify retained helpers even with new delegation disabled; ephemeral Local-only path is separate. Startup cost/pages/buffers/deadline exhaustion are measured, without a service-time promise. |
| 34 | Maintainer choice recorded | [M7](../plans/M7-technical.md#technical-plan-evidence): A adds reviewed environment_failure with complete outage evidence, retained attempt and affected-case execution on a new candidate only; no model-miss exemption. |
| 35 | Proposal repaired | [M7](../plans/M7-technical.md#technical-plan-evidence): not_dispatched and index-keyed same-logical-matrix resume preserve completed cases/results and never replace consumed incomplete attempts. |
| 36 | Proposal repaired | [M7](../plans/M7-technical.md#technical-plan-evidence): A reviewed committed attendance/runner procedure correction qualifies only if it would have prevented evidence loss; otherwise seek explicit amendment. |
| 37 | Obligation explicit | [M7](../plans/M7-technical.md#technical-plan-evidence): Mandatory campaign index path, serial writer, bounded JSONL/hash-chain/fsync, known head/count and cross-machine complete-history transfer prevent hidden pre-merge failures. |
| 38 | Proposal repaired | [M7](../plans/M7-technical.md#technical-plan-evidence): A lane with unresolved prior failure refuses before dispatch; the tested SHA In-review transition declares closure and bars extra paid --only work. |
| 39 | Obligation explicit | [M7](../plans/M7-technical.md#technical-plan-evidence): Fixed finite case budget ceilings/sums, breach result and not_dispatched later cases; credential-free and legacy unattended gates precede paid M7 cases. |
| 40 | Obligation explicit | [M7](../plans/M7-technical.md#technical-plan-evidence): m7.restore owns attended V13.1/4–6 and joins credential-free m7.rollback evidence without provider or rollback re-execution. |
| 41 | Obligation explicit | [M7](../plans/M7-technical.md#technical-plan-evidence): Interrupt/detach reuse FIFO barriers; driver connection observations join the independent same-run active snapshot/cursor, with a named trusted daemon policy-injection join. |
| 42 | Proposal repaired | [M7](../plans/M7-technical.md#technical-plan-evidence): Coverage is described as lanes, not case selectors; m7-rollback depends on and reuses the historical rollback execution. |
| 43 | Proposal disclosed | [M7](../plans/M7-technical.md#technical-plan-evidence): Plan/Context map explicitly name retired v0.2-to-candidate claim and new two-pair proof; acceptance and implementation update the procedure/verification guide. |
| 44 | Obligation explicit | [M7](../plans/M7-technical.md#technical-plan-evidence): Evidence task runs unconditionally before --docs exit and release preflight; external pin precedes full invocation, trace subkeys/observer channel and both trusted overrides are named. |
| 45 | Proposal repaired | [0043](../adr/0043-context-compaction-checkpoint-technical.md#technical-adr-0043-decision): First run-owned maintenance request commits the absolute run deadline; captured pre-staging preparation bound cannot renew across recovery. |
| 46 | Proposal repaired | [0041](../adr/0041-session-lineage-projection-and-context-budget-technical.md#technical-adr-0041-decision): Header explicitly extends ADR 0028 transfer ownership; runtime capacity and finite accepted per-job verification/work/deadline ceilings are accounted. |
| 47 | Proposal repaired | [M7](../plans/M7-technical.md#technical-plan-evidence): Both plan files bind all nine ADRs and both amendments as one exact-byte acceptance packet; headers name direct dependencies and no subset grants authority. |
| 48 | Proposal repaired | [M7](../plans/M7-technical.md#technical-plan-evidence): Prerequisite rows/ADR headers name exact-create, standalone admission/abort, abandonment, scoped failures, completion and v3-only writer amendments. |
| 49 | Proposal repaired | [0049](../adr/0049-explicit-host-configuration-technical.md#technical-adr-0049-decision): Concept owns pipe control lines, exit/refusal behavior and unknown-admission observation; ADR 0043 Concept owns unavailable-session recovery. |
| 50 | Clarified | [routing](../developer/agent-context-map.md#area-routing): Context-map amendment pointer, complete prompt-cost statement, evidence table continuity, labelled risk note and successor config/ledger scope agree. |

### Root adversarial pass

The root traced the refusal and unknown-admission paths in the current
coordinator/reducer, the real create result type, accepted deadline/cancellation
and artifact-transfer contracts, and the pinned adapter grammar. This corrected
several interactions in the first repair draft before advisory review:

- Index genesis cannot bind a manifest digest that itself contains the genesis
  digest. Genesis binds the campaign/codec; case records bind current manifest
  and specification digests.
- A helper-disabled durable host still classifies prior helper-owned sessions.
  A current file flag cannot establish that old state is ordinary.
- Exact create returns a session ID, and the job index stores the bounded router
  binding rather than duplicating raw canonical request bytes.
- Whole-packet acceptance applies to both vision amendments and all nine ADRs;
  a direct outcome table cannot imply partial implementation authority.

These are repaired text joins. No claim of runtime or live-provider feasibility
is substituted for the required implementation witnesses.

### Advisory review

The panel used the interrogate skill with the same standalone brief and rubric
for both reviewers, read-only by procedure rather than an enforced sandbox.
The intent was to make the selected M7 scope internally implementable and
reviewable while preserving acceptance authority and required proof.

| Reviewer | Model | Findings |
| --- | --- | --- |
| A | gpt-6-astra, high | 3 |
| B | gpt-6.1-sol, high | 3 |

The lead independently checked all six reports and merged the common bound
finding, leaving five distinct findings. All were Act on; no finding was left
in Consider, Noted or Dismissed.

| Finding | Models | Lead judgment and repair |
| --- | --- | --- |
| Run-owned episode cannot encode turn exhaustion | A, B | Act on: a partial checkpoint can exhaust the parent's last turn. Shared container now has owner-specific bound domains, exact parent measurements/accounting, standalone rejection and a one-turn exhaustion vector. |
| Post-terminal oracle demands thinking in disabled cells | A | Act on: valid Haiku default/none would fail. V7.7 now requires native thinking only for continuation-required cells and exact nil/no-thinking behavior for the other two. |
| Daemon observer waits for another client's connection facts | A | Act on: detach/reattach are not committed session events. V9.4 joins driver-recorded closure/reattach responses to the observer's same-run active snapshot and cursor. |
| Local index locks permit split campaign writers after transfer | B | Act on: one lock per copied file cannot establish cross-host exclusion. Designated writer, relinquishment/revocation, verified complete transfer and destination acceptance form a retained procedure, with handoff recovery/refusal tests. No distributed-lock claim remains. |
| Concept checklist calls round 4 current | B | Act on: cheap correction keeps the readiness pointer honest. It now names round 5 and this disposition. |

Both models independently found the bound-union mismatch. The other four were
raised by one reviewer each; neither reviewer contradicted the other. The root
also aligned the Concept verdict list with environment_failure, required index
entries for credential-free matrix cases so resume can retain them, and made
handoff records refer to the preceding head to avoid another self-hash cycle.
The first focused recheck by A resolved its original three findings and found
two follow-on joins. Both were Act on. Run-owned episode attempt exhaustion now
keeps the measured staging/headroom failure in both terminals, with attempt count
as episode evidence, while standalone retains its own max_attempts branch. A
four-progressing-summary vector fixes that distinction. Credential-free index
cases now become started before actual check execution; their missing completion
cannot be relabelled not_dispatched because no model was called. Both reviewers
resolved the credential-free boundary in their final rechecks.
A also resolved the attempt-exhaustion repair; B independently confirmed it.
Seven distinct advisory findings were repaired across the two passes, five
raised by A and four by B, with two shared findings. No remaining internal
blocking finding is claimed. External audit still decides whether this packet
is ready for acceptance. No reviewer ran code, checks or providers.

### Verification and handoff

The final documentation-only check runs once on the committed clean candidate.
Its complete immutable log names exact HEAD, branch, toolchain, before/after
clean state, start/end time, exit and measured duration. A separate retained
receipt binds that log, candidate/remote SHA, contract manifest and next review
prompt. The document cannot name its own resulting commit. No acceptance,
closure, product behavior or live capacity is proved by this documentation check.
