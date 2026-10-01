## Concept

Candidate `a234247e36428cfcd2d466bf688704182dd237c7` needs two small contract
repairs before plan acceptance. One promises guaranteed visibility where the
host deliberately uses best-effort stderr reporting. The other admits trace
flags on inspection commands that the owning scope forbids. Both are
low-severity wording conflicts, but the charter makes a pair mismatch blocking.
One optional sizing-example clarification is also recorded.

The lead verified all three findings and will repair them under the maintainer's
current instruction. None changes a recorded maintainer choice or needs a new
decision. R8-1 is repaired. The examined maintenance, thinking, artifact, helper
and evidence-campaign contracts have no other confirmed blocking gap from this
pass. Absence of their future implementation is an implementation obligation,
not a defect in this planning packet.

This report records the initial review of the named candidate. The subsequent
repair and recheck belong to `M7-round-9-disposition.md` and a separately retained
final-candidate receipt. M7 remains Open, ADRs 0041–0049 Proposed and the labelled
paired vision amendments unaccepted. Readiness advice does not accept those
bytes, authorize dependent product implementation or establish closure proof.

## Technical depth

### Identity and method

Repository: `/Users/spuri/projects/lexlapax/loopex`, branch `m7`. The previous
reviewed candidate is `9392e19d5f6a2f3bfd20a4c61dffa67adf74c75d`. The complete diff
to this candidate has 21 files, 685 insertions and 195 deletions.

The lead and both advisory readers verified the candidate and evidence
bindings. All 61 contract-manifest file hashes match. Both readers inspected
the complete 21-file diff and the changed contracts in their owning pairs, then
rechecked HEAD, branch, clean tree and bound artifact hashes before finishing.
Their initial reviews began and ended on the clean named candidate. Authorized
lead repairs began only after both had completed; this report does not confuse
that later edited tree with the initial review's identity.

The Interrogate skill supplied two model-diverse advisory readers:
`gpt-6-astra` and `gpt-6.1-sol`. The lead separately verified each finding and
inspected the state-machine and source joins. Initially selected strict
release-reviewer roles stopped before inspection because their required
enforced read-only sandbox was unavailable. They supply no review evidence.
The replacement advisory readers were read-only by procedure on a
workspace-write host; only the lead may repair repository files. No sandbox
enforcement claim is made.

The current maintainer instruction authorizes repairs and supersedes the
pasted prompt's repository-read-only restriction for the lead. It does not
supersede the advisory readers' read-only assignment. No provider calls,
credential reads, product tests, builds or release lanes ran during this initial
review. The existing documentation check was inspected, not rerun: PASS,
exit 0, 15.875 seconds, candidate and clean-before/after recorded in its log.

| Initial bound artifact | SHA-256 |
| --- | --- |
| Round-9 prompt | `3f0d8b494c0c071cbe66efa88fe95fa3342d9d8ed69d32b1289c092ce5520b0e` |
| Prompt binding | `b334b71fa9775ac183003ba683ed43d91ccb7f125b39b1d4cd2519c9a2466aec` |
| Round-8 readiness receipt | `a3c774df6b711dd8b07db12a4ecb1b9d38e2eac718aaf266b1822e4f85cb92a4` |
| Round-8 contract manifest | `9983cc8db7d06b838727b916f07047ee2ef1a18c89f70987a6ee7cf789973c3e` |
| a234247e documentation log | `650717a9885e5949134342549d76d8ad1278813173a8446a75658e1ff48c0ccc` |
| Documentation result | `aec592f346a1639a6fd3f1e61913505652637f177bc45c1a44793d63a56b8baa` |
| Remote confirmation | `7a0fbfa84646dd32b85d8f2fd42782a45183d6c85ce79daefdfeb440fd398633` |
| Retained round-8 report | `6f1b0d2511cb78cf48fcf31654c54bf31c0e8da5862ead3e2b9764810640ee50` |
| Round-8 disposition | `f0e7f9a1de74660bcd8d5505ca2c584b495bd8d1128084dcbc72cde778c0c8d7` |

The artifacts use the paths supplied by the round-9 prompt under `/tmp`.
The prompt binding separately binds the receipt and prompt; the earlier receipt
does not bind a prompt written later. The remote-confirmation bytes record an
earlier independent remote observation; no new remote request was made in this
initial review. Scratch arithmetic was not used. The fresh advisory brief is
`/tmp/loopex-m7-round9-final-readiness-brief.txt`; its digest is retained below.

### Findings at the original candidate

**R9-1 — Guaranteed limit visibility conflicts with best-effort delivery.**
Classification: contract gap. Severity: low, blocking plan acceptance under
`docs/developer/development-charter-technical.md:40–43`.

ADR 0047 Concept lines 29 and 39–40 promise every effective limit is visible
before a run and the operator sees the bounds before submitting work. Its
Technical lines 23–25 require echoing values and origins. ADR 0049 Concept
lines 19–23 and Technical lines 90–94 instead make chat's startup report a
best-effort stderr diagnostic that never gates startup.

Reachable case: stdin and stdout work while stderr stalls. The bounded writer
cannot deliver the report, yet chat accepts a prompt. No mandatory inspection
step supplies the promised unconditional delivery. Planned stalled-stderr tests
can correctly pass ADR 0049 while falsifying ADR 0047; the documentation gate
does not test this semantic guarantee.

Smallest repair: qualify both ADR 0047 files to distinguish effective inspection
from the best-effort startup report, preserve startup behavior and spending
bounds, and respect `/status`'s closed record. Add the owning ADR 0049 dependency
and retain the corresponding inspection/stalled-reader evidence obligation.
Maintainer input: none; this preserves the disclosed best-effort author choice.

**R9-2 — Inspection grammar both accepts and rejects trace flags.**
Classification: contract gap. Severity: low, blocking under the same pair rule.

ADR 0049 Technical lines 80–88 include trace flags in chat overrides and then
allow inspection commands the same overrides. Technical lines 367–369 and
Concept lines 29–31 expose tracing on chat, ask and daemon startup only, with
non-owning commands rejecting it.

Reachable case: `loopex config show --config FILE --effective --trace` must be
accepted under one grammar paragraph and rejected under the tracing rule.
Accepting a flag without starting a trace does not satisfy the exposure rule.
The planned negatives name offline run/resume/cancel but omit inspection, so
an implementer can choose either interpretation without that vector detecting
it. The documentation gate cannot decide the semantic conflict.

Smallest repair: inspection accepts the same non-trace overrides and rejects
all trace flags. It may display file-derived trace values without starting a
trace. Add explicit show/validate grammar negatives to the evidence list.
Maintainer input: none; tracing retains its already disclosed command scope.

**R9-3 — Duplicate-representation arithmetic needs an inline qualifier.**
Classification: optional improvement. Severity: low, non-blocking by itself.

ADR 0041 Technical lines 313–318 say two 16-KiB raw outputs consume 65,536 bytes
in the two request representations. New-generation results in an
artifact-capable session are excerpted under lines 122–164, so that arithmetic
applies to full inline results rather than every result of that raw size.

Reachable case: a session has a non-null artifact-capable read selection and
two new 16-KiB executor outputs; their projected request contains references and
bounded excerpts. Exact-record measurement and spill/replay tests should still
follow the correct earlier projection rules, despite the misleading example.
Smallest repair: scope the example to full inline outputs in a session with no
artifact-capable read tool. Maintainer input: none.

### R8-1 and recorded choices

R8-1 is repaired. ADR 0046 Concept lines 117–125 now covers enumeration and
saved-entry validation together exceeding one startup bound, matching the
Technical classification rules at lines 635–652. The separate unmatched-intent
suffix limitation remains disclosed. The round-8 disposition records the
correct wording and claims a proposal repair, not an executed startup proof.

All ten author-choice entries in the round-8 disposition have a Concept
statement. The trace entry has the neighbouring R9-2 conflict above.

| Author choice | Concept evidence at a234247e |
| --- | --- |
| Pre-run history only | ADR 0043:81–83: compaction covers only history from before that run. |
| Abort/deadline beats pending checkpoint | ADR 0043:90–93: no checkpoint commits and the summary remains evidence only. |
| Trace command scope | ADR 0049:28–31: chat, ask and daemon startup only. |
| Legacy resume and inspection | ADR 0049:51–52 requires an explicit model flag; :19–23 says file inspection never supplies committed session values. |
| Registered levels only | ADR 0044:181–183 refuses unlisted levels, including default. |
| Late helper settlement | ADR 0046:67–70 settles conclusive child evidence while the parent call stays unknown. |
| Helper refusal precedence | ADR 0046:101–103 returns the first refusal in one fixed order. |
| Direct-core summarizer admission | ADR 0043:47–48 admits a well-formed map but refuses new episodes when the required setting is absent. |
| Beyond-size offset | ADR 0041:47–49 refuses before policy; offset equal to size permits empty EOF. |
| Null artifact-read selection | ADR 0041:59–62 preserves every saved inline receipt when the complete request fits. |

The three round-6 author choices remain disclosed proposals: started non-pass
stops a campaign, marked compaction excerpts preserve the short-prefix rule,
and helper-history classification closes durable host admission until complete.
No different preference is reported as an unresolved decision.

### Per-file verdicts for the 21-file diff

Paths below are relative to the repository. Clear means no additional confirmed
gap in the changed text and inspected joins, not execution proof. ADR 0047 is an
unchanged neighbour of this original diff and is included through R9-1.

| Changed file | Initial verdict |
| --- | --- |
| docs/adr/0041-session-lineage-projection-and-context-budget-technical.md | Clear contracts; optional R9-3 qualifier. |
| docs/adr/0041-session-lineage-projection-and-context-budget.md | Clear; agrees with null-capability and range behavior. |
| docs/adr/0042-host-composed-instructions-technical.md | Clear; version grammar, ephemeral options and system limits agree. |
| docs/adr/0042-host-composed-instructions.md | Clear; host composition and role facts are disclosed. |
| docs/adr/0043-context-compaction-checkpoint-technical.md | Clear in examined maintenance identity, terminal ordering, clock failure, receipt and checkpoint rules. |
| docs/adr/0043-context-compaction-checkpoint.md | Clear; current-run protection, abort precedence and rendering refusal agree. |
| docs/adr/0044-run-model-and-reasoning-configuration-technical.md | Clear; registered levels, response identity, maintenance settlement and cutover agree. |
| docs/adr/0044-run-model-and-reasoning-configuration.md | Clear; thinking witnesses and failure consequences agree. |
| docs/adr/0045-model-originated-questions-technical.md | Clear; effective deadline owns question expiry. |
| docs/adr/0045-model-originated-questions.md | Clear; header names the added tool definition. |
| docs/adr/0046-child-session-tool-technical.md | Clear in examined refusal, settlement, registry and startup rules. |
| docs/adr/0046-child-session-tool.md | Clear; R8-1 repaired and resident limitations disclosed. |
| docs/adr/0049-explicit-host-configuration-technical.md | R9-2; reporting also exposes R9-1 in ADR 0047. |
| docs/adr/0049-explicit-host-configuration.md | Internally clear scope/reporting, contradicted by R9-2 and neighbouring R9-1. |
| docs/adr/README.md | Clear; statuses remain Proposed. |
| docs/evidence/M7-external-review-8.md | Historical report retained byte-for-byte; hash verified. |
| docs/evidence/M7-round-8-disposition.md | R8-1 and author choices recorded; its clean/agreement assessments miss R9-1/R9-2. |
| docs/evidence/README.md | Clear indexing. |
| docs/plans/M7-technical.md | Clear in examined campaign, resume, ordering, rollback and closure-scaffold joins. |
| docs/plans/M7.md | Clear; limitations and proposals disclosed, no acceptance claimed. |
| docs/plans/README.md | Clear; coordinated acceptance requirement and Open status remain. |

### Source joins and limits

The existing reducer in `apps/loopex/lib/loopex/runtime/session_state.ex`,
including lines 2601–2634, 2788–2840 and 3507–3536, establishes the integration
points for deferred terminal application and version ordering. The new
maintenance kinds and their validators remain explicit implementation work.
The current `scripts/check-release.sh` lanes at lines 165–277 and 331–377 are
integration points for attempts indexing, fresh-source resume, rollback roots
and evidence-task placement. Their absence today does not disprove a future plan.

The regression sweep found no confirmed disturbance in the inspected
maintenance settlement pairs, unknown-commit barriers, compaction/refusal
precedence, helper cache pruning/classification, campaign heads, lane suspension
or counted thinking witnesses. This is reasoning about the stated contracts.

Both advisory readers covered the full changed-file diff with owning sections
and selected broader accepted-contract, verification, milestone and source
context. One read the full Concept vision; neither independently reread every
unchanged line of the entire 61-file cone or full Technical vision. The lead
also focused on changed contracts and boundary joins. Large outputs sometimes
truncated; hidden portions are not counted as read. Byte identity does not
establish exhaustive semantic coverage.

Provider facts remain pinned documentary intent; no current provider support,
installed ReqLLM behavior, capsule sizing or live witness was proved. This pass
does not certify product implementation, durable faults, model behavior or
milestone closure. The final repaired bytes need their own bounded recheck and
one documentation-only validation, retained separately.

Advisory brief SHA-256: `04178bb90d38002fe34369cfe4de380b262fef11a7f2052797dcc06a60c3092d`.
