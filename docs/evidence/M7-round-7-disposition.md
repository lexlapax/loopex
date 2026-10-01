# M7 round 7 disposition

## Concept

The external [round 7 report](M7-external-review-7.md) finds planning candidate
`6f8d4759125cca54f493c69f5263974669260ebf` not yet ready for acceptance, with
one blocking contradiction and three smaller items. This record reconciles all
four findings and the internal adversarial review of their repairs. It
supersedes round 6's readiness conclusion without rewriting that report.

The blocker was a join in the evidence procedure: a paid pre-merge lane that
stopped before a case's dispatch could continue on the same commit, yet every
stopped lane also required a new documentation commit before any later paid
lane. The repair treats that stop as suspension of one logical lane. Its
continuation stays on the original commit; the index head is committed once the
lane has ended.

The other repairs state two helper-recovery safeguards and correct one record.
A refused registration is removed from the saved helper cache before coverage
beyond it is published. The scan of a session with many records behind a call
whose outcome has not been found completes only under a resident host. The
round 6 disposition row
for finding 23 now describes the final text.

No maintainer decision was needed. The three author choices recorded in round 6
are unchanged and remain reversible proposals. M7 remains Open, ADRs 0041–0049
Proposed, and both labelled vision amendments unaccepted. These are planning
repairs, not product tests, demonstrations or acceptance.

## Technical depth

The received report is retained byte-for-byte with SHA-256
`7d8074cc0a5379aac47b2a509d7d31dab00620e0f1ccdb86300442cc9aedc7a0`. Its method
and evidence limits remain those it states. No provider call, product suite or
release lane ran for these repairs.

| ID | Disposition | Owning contract and repair |
| --- | --- | --- |
| R7-1 | Proposal repaired | [M7](../plans/M7-technical.md#technical-plan-evidence): a paid pre-merge lane is one logical lane per commit SHA and lane ID. A pre-dispatch result suspends it; its continuation on the same commit reuses completed rows and needs no new head line. A lane ends when all its cases pass or a case of that invocation reached `started` without a completed pass, and the next commit then records the head. A suspended lane whose prerequisite repair needs a commit is abandoned by a head-recording commit and its rows are not reused. Phase 0 pins both composed vectors. The [Concept](../plans/M7.md#concept-plan-decisions) says the same. |
| R7-2 | Obligation explicit | [0046](../adr/0046-child-session-tool-technical.md#technical-adr-0046-decision): job entries at or below a watermark are exactly the original attempts of the filtered expected operations. The host removes the entry of each scanned registration with a committed pre-effect refusal before computing the digest and installing coverage; an interrupted step leaves no validated coverage beyond the pair. The composed witness and its conservative counterpart are named. |
| R7-3 | Obligation explicit | [0046](../adr/0046-child-session-tool-technical.md#technical-adr-0046-decision): a suffix behind an unmatched intent that exceeds one bound is a second recorded resident-host limitation; a resident host keeps its cursor and open-intent rows between slices. The [Concept](../adr/0046-child-session-tool.md#concept) qualifies its progress promise, and a controlled scan-bound fixture is named. |
| R7-4 | Record corrected | [Round 6 disposition](M7-round-6-disposition.md), row 23: stateless emission of every scanned tool terminal with composition-side filtering. |

The report's reconciliation marks round 6 findings 20, 23 and 30 partly
repaired. R7-2 and R7-3 address the remainder of 20, R7-4 that of 23 and R7-1
that of 30.

### Advisory review

Two fresh readers reviewed the uncommitted repair diff, one on the lane and
head-commit join and one on the helper cache, scan limit and records. Each
walked the external reviewer's sequence against current text and then attacked
the new text. They were read-only by procedure, not an enforced sandbox, and
ran no code, check or provider. The lead verified each report and acted on
every finding; none was left as Consider, Noted or Dismissed.

| Area | Blocking | Should fix | Lead judgment and repair |
| --- | --- | --- | --- |
| Lane suspension and committed heads | 1 | 3 | Act on all. The reviewer's sequence was repaired, but a suspended lane whose prerequisite repair needs a commit could neither continue nor end. Such a lane is now abandoned by a head-recording commit, its rows are never reused elsewhere, and a new paid lane refuses while started rows lie beyond the greatest committed head. The text no longer claims a committed anchor for a suspended lane. "Ended" covers a case left started and a failure in another lane of the same invocation. The rule is scoped to lanes that use the attempts index and never bars the full matrix. |
| Helper cache, scan limit, records | 1 | 5 | Act on all. The blocking item was this record's own placeholder. Removal now covers every scanned refused registration, wherever it lies relative to the watermark, and only job entries at or below a validated watermark are reused. The interrupted-step outcome is described as resumption from the previous watermark, which agrees with the no-rescan rule. The resident-host sentence names what happens to a task intent and to an intent of another kind. |

No further recheck of these last edits was run. The external audit of the
committed bytes is the next independent review.
