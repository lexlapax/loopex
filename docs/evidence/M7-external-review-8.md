# Loopex M7 external planning review — round 8

## Concept

**Verdict: one small wording correction remains before exact-byte acceptance.** I found no remaining blocking defect in the examined behavior, recovery or evidence mechanisms. The sole finding is a low-severity mismatch between ADR 0046's Concept and Technical descriptions of the resident-host startup limitation.

The Technical rule correctly counts enumeration and saved-entry validation together against the fixed startup bound. The Concept says “listing alone.” A root can finish listing within the bound but spend the rest validating saved entries, so the Concept leaves out one reason a one-shot start may fail to progress.

Change the first Concept qualification to “a root whose enumeration and saved-entry validation together exceed one bound.” This states the existing design accurately and needs no maintainer decision. The development charter expressly requires this before acceptance: “A mismatch is a blocking finding until the pair agrees.” The requirement is at docs/developer/development-charter-technical.md:40–43. Its application makes this an acceptance blocker even though the implementation contract is already sound.

The four round-7 repairs are otherwise substantive:

- A pre-dispatch interruption suspends the logical pre-merge lane; indexed continuation stays on the same commit. If its prerequisite repair requires a commit, the lane is abandoned with its current head recorded and its completed rows remain historical.
- A started case without a completed pass consumes the attempt and ends the lane. The new text supplies no replacement paid attempt and does not transfer results to a different candidate.
- Refused helper registrations are removed before coverage publication, including refusals above the saved watermark. Entries beyond validated coverage are rebuilt. Unknown work stays conservative.
- Resident scan slices retain their live cursor and open-intent joins. The unmatched-intent suffix limitation and its controlled witness are now explicit. The round-6 disposition accurately describes stateless terminal emission and composition-side filtering.

**Finding count: 1 contract gap, low severity, blocking only under the paired-document acceptance rule.** No new durability, authority or paid-attempt blocker was found. Two fresh advisory readers independently identified this same wording point; they differed on whether to label it optional. The lead applied the explicit charter requirement.

No new maintainer question is needed. The three disclosed author choices remain proposals, including all-closed durable admission during classification and backup restoration after an unreadable history. Accepting the packet would accept those costs. M7 remains Open, ADRs 0041–0049 Proposed, and both labelled paired vision amendments unaccepted. This review accepts no bytes and supplies no implementation, live-provider or closure proof.

**Next step:** the repair owner aligns that one Concept phrase and retains the resulting candidate's normal documentation validation. A focused check of the changed pair and candidate identities can address this finding; the correction itself requires no new design decision or paid demonstration.

## Technical depth

### Bound candidate and retained evidence

Repository: /Users/spuri/projects/lexlapax/loopex. Branch: m7.

| Item | Verified result |
| --- | --- |
| Candidate HEAD | 9392e19d5f6a2f3bfd20a4c61dffa67adf74c75d |
| Parent / previously reviewed candidate | 6f8d4759125cca54f493c69f5263974669260ebf |
| Local origin/m7 | Same candidate |
| Working tree before and after review | Clean |
| Change from parent | Nine documentation paths |
| Manifest | All 59 listed file hashes matched before and after review |
| Retained documentation check | PASS, exit 0, 16.328 seconds; exact candidate and clean-before/after metadata inside retained log/result |
| New product/check/provider execution | None |

The receipt's remote confirmation records the author's non-force push and independent ls-remote. I verified its bound bytes and the local remote-tracking ref; I did not perform a fresh network observation. The documentation check was not rerun. Its PASS proves its stated structure, compilation, formatting and documentation-order checks, not M7 behavior.

| Artifact | SHA-256 |
| --- | --- |
| /tmp/loopex-m7-external-review-round8-prompt.txt | 86dbdbba5d1ea79fb409fcb2e9de24495c370feb48a2d436d6b3b61af5f1815e |
| /tmp/loopex-m7-round7-readiness.json | e827aa847f10015feb8381b911be00278ee871946b7d272f7bddb2ca5039c2e1 |
| /tmp/loopex-m7-round7-contracts.json | 1045db57baeab375cd44e210dc2b33132118e68c40b0cac5f3071e4bea83a278 |
| /tmp/loopex-m7-round7-9392e19d-docs.log | efbd0c81cc1981b97c78810b42b2cfd4d77dac28e0ba5ca27ca209ab7b98f02d |
| /tmp/loopex-m7-round7-9392e19d-docs-result.json | 308c350be133af8f163973958ce962eda4985ae0391ab02e44b43bc2621ec016 |
| /tmp/loopex-m7-round7-remote-confirmation.json | 712b5d5d56938f604cd8ef8a4d232c3081f6d5eef3a0ecdffc3208fa9ae9b243 |
| docs/evidence/M7-external-review-7.md | 7d8074cc0a5379aac47b2a509d7d31dab00620e0f1ccdb86300442cc9aedc7a0 |
| docs/evidence/M7-round-7-disposition.md | 65eff8086cb01fa11cbf13fed4c3908eff81630492474add1636707497719cdd |
| /tmp/loopex-m7-round8-reviewer-brief.txt | 8115ed91a060cfd1d5baeed194fa79eaf73f39b6fdc323a61f79a4868f642e58 |

The retained round-7 report is byte-identical to /tmp/loopex-m7-external-review-7-6f8d4759.md. Historical receipts and reports are not proof of current repairs.

### R8-1 — Concept omits saved-entry validation from the resident-only startup condition

**Classification:** contract gap. **Severity:** low. **Acceptance effect:** blocking because the charter explicitly requires paired agreement.

**Current locations:**

- docs/adr/0046-child-session-tool.md:105–109.
- docs/adr/0046-child-session-tool-technical.md:597–601 and :616–621.
- docs/developer/development-charter-technical.md:40–43.

All relative paths resolve under /Users/spuri/projects/lexlapax/loopex; line numbers are one-based and belong to candidate 9392e19d.

**Mismatch:** The Concept identifies a root whose “listing alone” exceeds one bound as its first resident-only case. Technical says enumeration and entry validation consume the bound, and their combined cost exceeding a slice requires a resident host. The separate unmatched-intent suffix limitation is correctly stated in both files.

**Reachable sequence:** A root's directory enumeration fits a 60,000-ms slice, but validating its saved entries consumes the remaining time before intent scanning can progress. Every one-shot start repeats that prerequisite work. No unmatched intent is necessary. Technical correctly selects resident continuation; the Concept's qualification omits the saved-entry work that caused it.

This is a conditional consequence of the specified repeated work, not a measured assertion about any particular root size or hardware.

**Planned detection:** ADR 0046 Technical:568–570 and :835–849 require startup-duration, peak-buffer and scan-bound witnesses. They can implement and prove the correct Technical behavior while leaving the Concept sentence unchanged. Documentation structure checks do not establish semantic agreement.

**Smallest repair:** Replace the first Concept qualification with “a root whose enumeration and saved-entry validation together exceed one bound.” Preserve the fixed 60-second bound, all-closed admission and resident continuation. No schema, configuration key or recovery-policy change is needed.

**Maintainer input:** None. This aligns the paired statement with its existing Technical rule.

### Repair and regression sequence checks

| Sequence | Current owning rule and judgment |
| --- | --- |
| Passed case, then pre-dispatch stop, then continuation | docs/plans/M7-technical.md:592–604 and :714–734 permit continuation of the same logical lane on the same SHA, reuse only completed null-matrix rows, and dispatch only not-dispatched cases. No new head commit is required during suspension |
| Prerequisite repair requires a commit | :723–734 abandons the suspension through a head-recording commit. Old rows remain historical and cannot satisfy the next commit's cases |
| Crash leaves a case at started | :599–604 ends the lane; :768–780 preserves the consumed attempt. Existing reviewed evidence-loss/causal-correction rules govern any later candidate |
| Multiple selected lanes | :594–602 scopes suspension to unfinished selected lanes and makes a started non-pass end lanes in that invocation. Invocation preflight and initialization of selected lanes can satisfy the new-lane guard; no required paid rerun was identified |
| SHA later declared the closure candidate | :789–794 bars additional paid pre-merge --only execution after the In-review declaration. The full matrix uses non-null matrix IDs and its own required attempts |
| Truncation during suspension | :719–723 explicitly limits protection beyond the committed head to the trusted retained single-writer procedure. It does not claim a committed anchor can detect loss of that uncommitted interval. Known missing/corrupt history retains the successor/disposition rules at :738–748 |
| Refusal below or above saved watermark | docs/adr/0046-child-session-tool-technical.md:760–784 removes every scanned registration with a committed pre-effect refusal before digest/publication, regardless of its position relative to the watermark |
| Crash during pruning/publication | :767–784 requires previous, absent or invalid coverage rather than reusable coverage beyond an unvalidated pair. Entries above validated coverage are rebuilt; the composed witness is explicit at :840–845 |
| Missing terminal instead of refusal | :654–672 and :771–772 keep the registration expected and apply conservative ledger/provenance recovery rather than infer absence |
| Late cancel or receipt lookup for a pruned ID | :404–417 and :792–808 permit uncertainty and the unknown-ID fence; they grant no launch authority, no invented cleaned result and no reconstructed allowance charge from receipt lookup |
| Long suffix behind unmatched intent | :619–626 preserves the resident's live captured-prefix cursor and join state across slices; repeated one-shot completion is expressly not promised. The controlled witness is at :846–848 |
| Existing closure verdicts/refusal classes | The cause/result matrix at docs/plans/M7-technical.md:445–542 and the closed pre-effect reasons at ADR 0046 Technical:244–269 remain intact |

The full-runner paragraph at docs/plans/M7-technical.md:605–628 scopes its ordered legacy/attended prerequisites to the full matrix. I did not promote the broad phrase “Before any paid M7 dispatch” into a pre-merge contradiction in isolation. A “During the full matrix” qualification could improve clarity, but no additional finding is counted for that contextual wording.

Existing source joins checked include:

- apps/loopex/lib/loopex/runtime/session_state.ex:1357–1364 and :1460–1467: separate effect intent and tool terminal facts.
- apps/loopex/lib/loopex/runtime/session_coordinator.ex:5638–5645: a real cancelled-before-port terminal after intent commitment.
- The same coordinator at :7147: only the exact tagged pre-effect refusal tuple supplies no-effect proof.
- Its cleanup/settlement path preserves terminal evidence and does not let a missing receipt become a conclusive absence.
- apps/loopex/lib/loopex/store.ex:1120–1131 and Runtime Control's bounded private-record worker path: boundaries the proposed queries must preserve.

Those checks corroborate the proposed distinctions. They do not prove the future helper cache, new query APIs or live providers.

### Required prior-ID reconciliation

“Repaired” means the planning contract states the obligation coherently, not that implementation proof exists.

| Prior ID | Result | Current evidence |
| --- | --- | --- |
| R7-1 | Repaired | docs/plans/M7-technical.md:592–604 and :714–748; docs/plans/M7.md:376–388: suspension, continuation, abandonment, ended-lane refusal and distinct full-matrix identity agree |
| R7-2 | Repaired | ADR 0046 Technical:760–784 and :840–845: filtered membership, pruning before coverage, reuse limited to validated prefix, and conservative crash counterpart are explicit |
| R7-3 | Partly repaired | ADR 0046 Technical:619–626 and :846–848 repairs the unmatched-intent suffix and resident cursor obligation. Concept:106–109 adds it, but its description of the separate validation-cost condition still needs R8-1 |
| R7-4 | Repaired | docs/evidence/M7-round-6-disposition.md:69 now describes every scanned terminal being emitted and composition-side filtering, matching ADR 0046 Technical:485–494 |
| Round-6 20 | Partly repaired | ADR 0046 Technical:573–631 and :760–784 fixes the bound, coverage, filtering, refusal and resident routes. Only the Concept qualification in R8-1 remains |
| Round-6 23 | Repaired | ADR 0046 Technical:466–510 plus corrected disposition:69: stateless paging, unmatched-terminal discard, null call identity and empty-page continuation agree |
| Round-6 30 | Repaired | docs/plans/M7-technical.md:699–748: handoff, greatest committed head, suspension window, abandonment and authorized successor campaign have owning rules |

The round-7 disposition and current audit pointers accurately identify the repaired candidate and current round. Its claim that the last internal fix pass was not independently reread is honest. Governance rows remain empty; no document changes M7's Open or the ADRs' Proposed status.

### Advisory synthesis

The two fresh readers received the same standalone brief with no inherited conversation and created no files. Both independently found R8-1 and found the repaired lane/cache sequences implementable. One classified the wording as an optional nit; the other as a warning contract gap and cited the charter. The lead verified the explicit pairing rule and retains one low-severity acceptance blocker.

- **Act on:** R8-1; both readers raised the same factual omission. One Concept phrase repairs it.
- **Consider:** none requiring a maintainer decision.
- **Noted:** full-matrix ordering could be labelled more explicitly; current context already supplies its scope.
- **Dismissed:** no new paid-rerun, authority or cache-charge contradiction survived the concrete sequence checks. Absence of live product proof is an existing implementation/closure obligation, not a claim those runs already passed.

No edits were auto-applied. The repair owner remains responsible for the new exact candidate.

### Method and limits

The lead reviewed round 7 and had prior involvement in earlier planning candidates; this is not a claim of complete prior uninvolvement. Fresh readers supplied independent advisory judgments. Root verified identities and owns all findings and this retained report.

Coverage comprised the complete nine-file repair diff, all seven required prior-ID reconciliations, owning lane/index/cache/query contracts and their neighbors, selected source joins, governing pairing/status rules, and a regression sweep of the prior packet. Unchanged vision, ADR and successor context was carried from the preceding whole-packet review and checked against current changes; neither reader claims an independent line-by-line reread of every unchanged page. The 59-file manifest is a selected documentation cone. Other source reads are bound by the exact clean Git candidate.

Read-only restrictions were procedural, not an enforced filesystem sandbox. No repository file or Git state was changed. No builds, tests, check invocations, release lanes, providers, network operations or credential inspection occurred. The only new files were the fresh standalone brief and this report under /tmp. Advisory readers wrote no scratch. No sizing simulation or provider calibration was run.

Provider facts remain documented intent from the packet's retained references, not current service observations or live verification of installed ReqLLM behavior. The documentation-only PASS supplies no product-behavior evidence.

New scratch artifacts:
- /tmp/loopex-m7-round8-reviewer-brief.txt, SHA-256 8115ed91a060cfd1d5baeed194fa79eaf73f39b6fdc323a61f79a4868f642e58.
- This fresh report, created exclusively under the requested /tmp name or a fresh suffix. Its delivery message supplies its SHA-256 outside its own bytes.

Final verification rechecked the receipt-bound prompt, manifest, check log/result, remote confirmation, received report and disposition hashes, all 59 file hashes, parent identity and received-report byte equality. HEAD and local origin/m7 remained 9392e19d5f6a2f3bfd20a4c61dffa67adf74c75d, branch m7, clean.

Checklist: candidate binding done; repaired sequences and regression joins reviewed; seven prior IDs reconciled; one low-severity pairing correction retained; report saved. Remaining: the one phrase correction and its focused candidate validation, then the maintainer's exact-byte acceptance decision. No repair or acceptance was performed by this reviewer.
