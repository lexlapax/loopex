## Concept

The maintainer requested one final implementation-readiness review and repairs
before accepting M7. The [initial round-9 report](M7-readiness-review-9.md) reviews
candidate `a234247e36428cfcd2d466bf688704182dd237c7` and its whole 21-file change
since the candidate reviewed in round 8. Two model-diverse advisory readers found
two small contract
mismatches and one optional clarification. The lead verified and repaired all
three. No recorded maintainer choice changes and no new decision is required.

The repairs preserve best-effort startup reporting, the existing trace-command
scope and both artifact projection branches. Recheck and documentation-only
validation must bind the final repaired bytes before the lead recommends them
for exact-byte acceptance. The retained final-candidate receipt records those
results; this page does not claim product behavior or closure proof.

M7 remains Open, ADRs 0041–0049 Proposed and the labelled paired vision amendments
unaccepted. The maintainer's instruction is to update the roadmap and project
README when accepting the final bytes, alongside the coordinated plan, ADR and
vision acceptance records. This request does not make that acceptance now.

## Technical depth

### Finding dispositions

| ID | Classification | Disposition and owning repair |
| --- | --- | --- |
| R9-1 | Contract gap; low severity, blocking under the pair rule | [ADR 0047 Concept](../adr/0047-reference-host-run-defaults.md#concept) and [Technical](../adr/0047-reference-host-run-defaults-technical.md#technical-depth) distinguish inspection from ADR 0049's best-effort startup report. Stalled stderr does not block work; delivery before submission is not guaranteed. The Technical rule respects `/status`'s closed record and retains the inspection/stalled-reader evidence obligation. Spending declarations and limits are unchanged. |
| R9-2 | Contract gap; low severity, blocking under the pair rule | [ADR 0049 Technical](../adr/0049-explicit-host-configuration-technical.md#technical-adr-0049-decision) admits only non-trace inspection overrides. Both `config show` and `config validate` reject every trace flag, while inspection may show file-derived trace values without starting a trace. Explicit grammar negatives are retained. |
| R9-3 | Optional improvement; low severity | [ADR 0041 Technical](../adr/0041-session-lineage-projection-and-context-budget-technical.md#technical-adr-0041-decision) scopes the two-output arithmetic example to full inline results in a session with no artifact-capable read tool. The projection rules and exact record ceiling are unchanged. |

R8-1 is repaired in the initial report's candidate. The historical round-8 report
and disposition remain unchanged; their claims apply to the revisions they name.
The current report corrects the earlier assessment of ADR 0047 visibility and
ADR 0049 trace-grammar agreement.

### Recheck and evidence binding

The same two advisory readers rechecked the integrated repair diff, complete new
evidence records and changed index/plan pointers against their owning contracts.
They remain read-only by procedure, with no enforced sandbox claim. The lead
adjudicates any new finding and repairs it before finalizing the candidate.
This bounded recheck does not claim an independent reread of every unchanged
line in the full planning cone. The initial report states the coverage limits.
Both readers confirmed all three repairs and found zero remaining contract
gaps in this bounded reread. They also caught the same low-severity comparison-base
label error in this page: "since round 7" was corrected to "since the candidate
reviewed in round 8". Final confirmation of the corrected record is retained
with the receipt.

The final receipt outside the repository binds the exact committed candidate,
contract manifest, retained advisory recheck results, this disposition and the
byte-identical initial report. It also binds the complete output of one
`bash scripts/check.sh --docs` invocation on that clean candidate and a fresh
non-force push/remote observation. The earlier a234247e documentation check is
not rerun or presented as proof of changed bytes. Check results and timings are
recorded only after execution; no paid lane or product test is claimed here.

The initial retained report is
`/tmp/loopex-m7-external-review-9-a234247e.md`, SHA-256
`4cbef758d032f1e937ed0d2d7af69024d500c743d8120a9255d35c71cb757f17`.
It is byte-identical to the indexed `M7-readiness-review-9.md`. The initial
readers began and ended on the clean a234247e candidate. Only the authorized
lead then wrote repairs; the final receipt binds that later candidate separately.

Checklist: initial identity and bindings verified; whole changed-file review
and R8-1 reconciliation complete; all three findings repaired. Recheck and
candidate validation results belong to the final receipt. Exact-byte acceptance
and the requested roadmap/README update remain the maintainer's next step.
