# Loopex M7 external planning review — round 7

## Concept

**Verdict: not ready for acceptance. One blocking contradiction remains in the evidence procedure.** The packet is much closer: the selected provider witnesses, refusal routes, amendment boundaries and recovery policies now have owning contracts. I found four issues: one contract gap, two implementation obligations and one optional record correction. None requires reopening a recorded maintainer choice.

The blocker is the pre-merge continuation rule. A paid lane may stop before its next case dispatches and resume on the same commit, reusing completed cases. Another clause requires a new documentation commit after a paid lane stops and bars a later paid lane until that commit records the new index head. When one case passes and the next lacks a prerequisite, both instructions cannot be followed. Define this pre-dispatch stop as suspension of the same logical lane, permit its indexed continuation on the original commit, and record the head when that lane completes or becomes non-resumable. This preserves every completed result and the prohibition on repeating started cases.

Two implementation safeguards should be explicit before work begins. First, the persisted helper cache must remove registrations that have a committed pre-effect refusal before publishing coverage beyond that refusal. Otherwise the next restart loses the fact that this operation consumed no allowance. Second, an unmatched intent can prevent the saved scan watermark from advancing through a long suffix. Repeated one-shot starts cannot necessarily finish that suffix; a resident host can. State this additional resident-host limitation and test the composed sequence.

The round-6 disposition also describes an intermediate repair for ID 23. The final intent query emits every scanned tool terminal; composition discards unmatched terminals. The owning ADR is correct. Correct the record so it describes those final bytes.

**Minimum repair:** resolve the lane suspension/head-commit join; state cache filtering before coverage publication; qualify the one-shot progress promise; correct disposition ID 23. Review the resulting candidate. No provider call, paid retry, dropped check, new persistent recovery policy or further maintainer answer is needed for these repairs.

The three disclosed author choices are honestly labelled proposals. Stopping after a started failure preserves the strict demonstration procedure. Excerpting a small prefix with its oversized successor addresses the prior selection failure, with the remaining protected-tail limitation stated. Keeping all durable admission closed during classification preserves the proposed provenance boundary, at a substantial availability cost: one unreadable history closes the durable host until backup restoration. That cost is already visible in both the Concept and Technical records; acceptance of the packet would accept it. Per-session quarantine would be a separate design choice, not a repair required by this review.

**Round-6 reconciliation:** 34 of the 37 findings are repaired; three are partly repaired, IDs 20, 23 and 30. ID 20 has the startup qualifications above, ID 23 has a stale disposition sentence despite its repaired owning contract, and ID 30 has the new continuation/head-commit interaction. No finding was rejected or left without an owning disposition. “Repaired” describes the planning text, not implemented or demonstrated behavior.

M7 remains Open, ADRs 0041–0049 Proposed, and both paired vision amendments unaccepted. This review supplies advice about implementation readiness; it accepts no bytes and supplies no product or closure proof.

## Technical depth

### Identity and evidence boundary

Repository: /Users/spuri/projects/lexlapax/loopex. Branch: m7.

| Item | Verified identity |
| --- | --- |
| Candidate HEAD | 6f8d4759125cca54f493c69f5263974669260ebf |
| Parent / previously reviewed candidate | 07b1a19cb7fdcab3155778f1119c043d23ba0d72 |
| Local origin/m7 | Same candidate; fresh network confirmation was not performed by this review |
| Working tree | Clean at entry and final verification |
| Change from parent | 23 documentation files |
| Contract manifest | 57 listed file hashes all matched at entry and final verification |
| Retained documentation result | PASS, exit 0, 16.359 seconds; candidate SHA and clean before/after are inside the bound log/result |
| Product evidence | No M7 implementation, product test, provider call, release lane or closure proof performed in this review |

The readiness receipt binds the retained remote confirmation from the author's successful non-force push and subsequent independent ls-remote. I verified that artifact and the local remote-tracking ref; I did not claim a new remote observation. The documentation-only PASS proves its stated structure, compilation, formatting and documentation-order checks. I did not rerun it.

| Bound artifact | SHA-256 |
| --- | --- |
| /tmp/loopex-m7-external-review-round7-prompt.txt | 574cca1be561266735697911ece9bdf8adb88f0a2b3e8281d9ca7f6d0ff4779f |
| /tmp/loopex-m7-round6-readiness.json | fed0006030f8781dab4c727f76bccf073a71e3205b11d6af9c6eee305ceac4fc |
| /tmp/loopex-m7-round6-contracts.json | 55c30f605ddf2332d7f44df6a6819823fd299bb6c8eb7a2c0f9240c8eddaa9a1 |
| /tmp/loopex-m7-round6-6f8d4759-docs.log | 837cc7e40461e9fafa9d00aa81ef07c556d8fa62cb09cfafce6736a695e3ccc1 |
| /tmp/loopex-m7-round6-6f8d4759-docs-result.json | e0a5eea5baa6a07aca46d7ccf67f6ac7fc338b80d75247c480fc6e5d29332387 |
| /tmp/loopex-m7-round6-remote-confirmation.json | 2290b1c51425681b1b184e1d772382ca37e5715066787c5ddbfedae94891807e |
| docs/evidence/M7-external-review-6.md | 0bb596b8cbf651b23ae697b297c38f6930af687b8115460cb1504104a10babfd |
| docs/evidence/M7-round-6-disposition.md | 1403a8be0dd1c08b76a82dfa969339215ccdf089385f941841856b4835fd352b |
| /tmp/loopex-m7-round7-reviewer-brief.txt | e3673a8ed84ebb11c6c1639bcf0840db32a37f5c42c86630144e05333e991e7d |

The retained round-6 report is byte-identical to /tmp/loopex-m7-external-review-6-07b1a19c.md. Historical reports and receipts are not proof of current repairs.

### Findings

Paths and one-based lines refer to this exact candidate. Relative paths below resolve under /Users/spuri/projects/lexlapax/loopex. P means docs/plans/M7-technical.md; PC means docs/plans/M7.md. ADR abbreviations identify the exact Concept/Technical filename in the path key below.

**R7-1 — Contract gap; medium severity; blocks acceptance: pre-merge continuation conflicts with the mandatory documentation child.**

- **Locations:** P:592–594, P:704–713; PC:376–386.
- **Conflicting instructions:** P:592–594 permits a pre-merge --only lane stopped pre-dispatch to continue on the same commit, reusing completed null-matrix rows. P:704–708 requires a documentation-only next commit after a paid pre-merge lane ends, “whether it passed or stopped,” and refuses a later paid lane until its new index-head line exists.
- **Reachable sequence:** On candidate A, the first paid case passes and advances the index. The next case discovers a missing prerequisite before dispatch. After repairing that prerequisite, continuation on A lacks the newly required committed head. Recording that head produces commit B, so the execution is no longer the promised same-commit continuation. An older head line cannot anchor the newly advanced head; treating any old line as sufficient would weaken the added head-commit obligation.
- **Planned detection:** Resume/index validators must choose incompatible expectations for this sequence. The documentation gate cannot decide the semantics. Phase-0 vectors need this composition, including proof that no completed case dispatches again.
- **Smallest repair:** Define a pre-dispatch stop as suspension of one logical pre-merge lane; exempt only its indexed continuation from the follow-up-commit prerequisite; require the documentation head when that logical lane completes or stops after a started non-pass. Distinguish that continuation from a new paid lane. Update the Concept wording consistently.
- **Maintainer input:** No new decision is required for that repair. Removing same-SHA continuation or transferring partial results to a documentation child instead would alter the proposed procedure and would need its consequence stated before acceptance.

**R7-2 — Implementation obligation; medium severity: filter refused registrations before installing reusable coverage.**

- **Locations:** docs/adr/0046-child-session-tool-technical.md:589–603, :646–654, :743–762, :805–826.
- **Owning constraints:** A committed pre-effect refusal must be excluded from expected operations, cost no slot and never fence its parent. Live registration installs a job entry before exposing work. A coverage digest includes every retained job entry below its watermark, while the closed job-entry fields carry no terminal disposition. A validated prefix must not be rescanned.
- **Reachable sequence:** A helper registration installs its job entry, then cancellation wins before reservation. Core commits the pre-effect terminal. Startup scans the pair and saves coverage beyond it. On another startup, the validated prefix is skipped. If the registration remains a member of that covered cache, its null ledger offset cannot distinguish refusal from an expected operation whose reservation was lost. Conservative reconstruction would then charge a refused operation.
- **Source join:** apps/loopex/lib/loopex/runtime/session_state.ex:1357–1364 stores effect intent; :1460–1467 stores the separate tool terminal. apps/loopex/lib/loopex/runtime/session_coordinator.ex:5638–5645 demonstrates a real committed cancelled-before-port terminal; :7147 recognizes the executor's tagged pre-effect refusal. The proposed cache has no equivalent terminal member.
- **Planned detection:** The existing refusal-recovery and coverage-resume witnesses are required separately. Compose them as registration → committed pre-effect refusal → persisted watermark beyond the pair → second startup using that watermark. Assert zero ledger reservation, zero reconstructed charge and an activatable parent. Pair this with the same registration without a committed terminal, which must remain conservative.
- **Smallest repair:** State that covered job entries contain exactly the filtered expected operations and all original attempts belonging to those operations. Prune validated pre-effect-refused registrations before computing and publishing the coverage digest/watermark. State the safe failure behavior if pruning/publication is interrupted; invalid coverage must cause rescan, never falsely complete classification.
- **Classification judgment:** The expected-set rule already forbids the wrong result. Correct filtering is achievable without changing recovery policy. This is a missing explicit implementation ordering join, not a second fundamental contradiction or a demand for a new durable schema.
- **Maintainer input:** None.

**R7-3 — Implementation obligation; low-to-medium severity: state and test the open-intent suffix limit on one-shot progress.**

- **Locations:** docs/adr/0046-child-session-tool-technical.md:589–593, :613–623, :812–817; docs/adr/0046-child-session-tool.md:102–109.
- **Owning constraints:** A safe coverage watermark stays below the first unmatched intent. The Concept says long history finishes over later starts or resident background work. The explicit resident-only limitation currently mentions enumeration and entry validation exceeding one slice, not a suffix held back by an open intent.
- **Reachable sequence:** A host fails after an effect intent while later admitted records remain behind it. If scanning that suffix does not fit one 60,000-ms slice, the safe watermark cannot move through the unmatched intent. Repeated one-shot starts revisit the same suffix. A resident host can finish by retaining the live cursor and open-intent joins across slices, then classify the uncertain operation under the existing policy.
- **Evidence limit:** This is a consequence of the stated watermark rule, conditional on the suffix exceeding a slice; it is not a measured claim about a particular root size, storage speed or installed implementation.
- **Planned detection:** The current next-start resume witness can pass when a safe page boundary advances or a later terminal closes the intent. It does not establish progress when a large suffix remains behind a permanently unmatched intent. Add a controlled scan-bound fixture for repeated one-shot starts followed by resident-host completion; it need not be a throughput benchmark or provider call.
- **Smallest repair:** Add unmatched-intent suffixes to the recorded resident-host limitation and qualify the Concept progress promise. The resident path must preserve its cursor/joins between slices rather than beginning each slice from the persisted safe watermark.
- **Maintainer input:** None to state the limitation within this proposed design. Guaranteeing eventual completion through one-shot starts alone would require a stronger resumability design and is not implied by this review.

**R7-4 — Optional improvement; low severity: disposition ID 23 describes an intermediate repair.**

- **Locations:** docs/evidence/M7-round-6-disposition.md:69 versus docs/adr/0046-child-session-tool-technical.md:485–494.
- **Mismatch:** The disposition says the query emits terminal rows only when an earlier intent exists. The final owning ADR deliberately makes the paged query stateless: it emits every scanned terminal and composition discards unmatched rows.
- **Reachable consequence:** An implementer following the disposition rather than its owning link could introduce cross-page filtering state or omit a needed terminal. The normative owning contract itself is decidable and correctly handles policy-denial and invalid-argument terminals.
- **Planned detection:** Query/composition conformance should expose a divergent implementation. Structure and documentation checks do not prove this description matches the final repair.
- **Smallest repair:** Describe stateless terminal emission plus composition-side filtering in ID 23; retain the existing null call identity and exact run join.
- **Maintainer input:** None.

### Advisory judgments and issues not promoted to blockers

Two fresh advisory readers received the same standalone brief, with no inherited conversation. They read the packet and all 37 owning repairs under the same procedural read-only restrictions. The lead owns every classification in this report.

| Candidate issue | Judgment | Reason |
| --- | --- | --- |
| Lane resume versus documentation head | Include as R7-1 | Lead verified the literal conflict; both readers confirmed it after a focused follow-up |
| Cache exclusion after coverage reuse | Include as R7-2, implementation obligation | Readers differed on severity; the owning expected-set rule is sufficient authority for pruning, but the durable ordering and composed witness should be explicit |
| Open-intent suffix across one-shot starts | Include as R7-3, implementation obligation | The watermark rule establishes the limitation; resident continuation is already an allowed route |
| Disposition ID 23 | Include as R7-4 | Current owning text and the recorded description differ |
| Unreadable summary versus generic same-projection wording | Do not report a contract blocker | ADR 0043 technical:381–385 expressly preserves unreadable_model_answer on the run and model_call_failed on the episode; :507–508 preserves existing schemas. This specific branch resolves the later general sentence |
| Episode pending marker versus Store transaction visibility | Keep as the existing implementation/recovery obligation | Store private records do not expose transaction IDs; the writer proves atomicity and the reducer validates the ordered record sequence and complete durable head. Do not invent a new Store field merely to reinterpret “same transaction” |
| Final ReqLLM hook refusal path | Keep as the existing conformance obligation | Pinned hook ordering supports final validation; the implementation still must prove refusal before HTTP launch without a request-bearing exception |
| Whole-host classification lockout | Disclosed proposal, not an unrecorded approval | Both the Concept and Technical text state all-closed admission and backup restoration; per-session quarantine would change that selected proposal |
| Names inside the received prior report | Retain as received evidence | Tool names and scratch paths describe its method; the prompt explicitly preserves those received bytes. No content-origin attribution was introduced by this review |

This review did not repair the repository. “Include” means retain the actionable finding for the repair owner, not perform the edit.

### Per-ID reconciliation of round 6

Path key:

- 0041-T: docs/adr/0041-session-lineage-projection-and-context-budget-technical.md; 0041-C is its Concept companion.
- 0042-T: docs/adr/0042-host-composed-instructions-technical.md; 0042-C is its Concept companion.
- 0043-T: docs/adr/0043-context-compaction-checkpoint-technical.md; 0043-C is its Concept companion.
- 0044-T: docs/adr/0044-run-model-and-reasoning-configuration-technical.md; 0044-C is its Concept companion.
- 0046-T: docs/adr/0046-child-session-tool-technical.md; 0046-C is its Concept companion.
- 0047-C: docs/adr/0047-reference-host-run-defaults.md.
- 0049-T: docs/adr/0049-explicit-host-configuration-technical.md.
- CM: docs/developer/agent-context-map.md.

Repaired includes a future implementation obligation made explicit in the planning contract. Partly repaired identifies the precise remaining qualification or record mismatch. These are exact candidate line references, not historical line numbers.

| Round-6 ID | Result | Current evidence and remaining qualification |
| --- | --- | --- |
| 1 | Repaired | 0043-T:39–59, :471–478: preparation cutoff, its closed cause and deadline-staging route |
| 2 | Repaired | 0043-T:129–134, :407–410: ordinary explicit compact stops after one committed checkpoint |
| 3 | Repaired | 0043-T:103–121, :140–151: small prefix plus oversized successor uses excerpts; insufficient quota refuses; sole protected-tail limitation remains stated |
| 4 | Repaired | 0043-T:167–172: natural-completion evidence gates host registration; core guarantees post-dispatch validation |
| 5 | Repaired | 0043-T:46–59, :381–388, :487–511, :527–539, :555–570: clock owner, active-run code, deadline mapping, terminal adjacency and unreadable reply routes |
| 6 | Repaired | 0049-T:206–220, :324–341: wait/closing outcomes name runs; standalone compact uses transcript, last_compact and exit code |
| 7 | Repaired | 0049-T:269–286: identical pending proposal retained; competing internal proposals deferred, resolver timers progress and commands are not queued |
| 8 | Repaired | 0049-T:291–300, :313–319: missing preimage/fact remains pending; interactive resolver expiry permits exit only |
| 9 | Repaired | 0049-T:198; P:1122–1129: original disposition codes admitted; workspace, policy and missing-route abandonment cases owned |
| 10 | Repaired | 0041-T:127–133; 0049-T:25: bash/write/edit keep legacy generations and preparation; validation accepts both binding forms |
| 11 | Repaired | 0044-T:233–245; P:510–516, :992–1013: maintainer-selected post-terminal acceptance plus subsequent-thinking witness; uncorrectable positive refusal has a scope-amendment route |
| 12 | Repaired | 0044-T:136–151: literal generic default descriptor and native-thinking failure under a non-continuation mapping |
| 13 | Repaired | 0044-T:166–177; 0044-C:177–178: literal legacy alias and dated new reference default without rewriting old bytes |
| 14 | Repaired | 0044-T:272–276: buffered transport-owned accept-encoding identity admitted |
| 15 | Repaired | P:631–633, :647–653, :958–975: seven rounds subcases, nine bound subcases and auxiliary baseline/switch/maintenance witness ownership |
| 16 | Repaired | 0044-T:419–428, :734–736: closed stop/call relation; omitted empty completion counts as absent |
| 17 | Repaired | 0044-T:282–290, :598–618: wrapper installs manual native controls; per-request final validation follows the global hook |
| 18 | Repaired | 0044-T:120, :208–212, :1011: registration/proposal wording and three-flag condition aligned |
| 19 | Repaired | 0046-T:479–493, :646–651, :683–693: pre-effect cancellation excluded; excess uncertain operation denies helpers while ordinary parent work continues. R7-2 is the new cache-composition obligation |
| 20 | Partly repaired | 0046-T:573–623; 0046-C:102–109: fixed bound, resumable entries, all-closed refusal and resident route are specified. R7-2 and R7-3 qualify reusable membership and one-shot progress |
| 21 | Repaired | 0046-T:244–269: closed tagged pre-effect reasons and first reserve-append boundary |
| 22 | Repaired | 0046-T:378–389, :763–766: cancellation before reserve writes nothing; both coordinator orderings and post-reserve cache failure have routes |
| 23 | Partly repaired | 0046-T:466–494 repairs the owning query/composition contract, including run-level unknown with null call ID. Disposition:69 describes the older repair; R7-4 |
| 24 | Repaired | 0046-T:365–367, :743–780: ledger owns receipts; cache pending differs from final unresolved effect |
| 25 | Repaired | P:494–499, :520–529: every new candidate has its complete matrix; a reviewed pre-merge case event carries authorization |
| 26 | Repaired | P:584–594: consumed non-pass stops matrix/lane; later subcases are not dispatched and cannot resume |
| 27 | Repaired | P:447–460, :602–606: mechanical precedence separated from independently reviewed cause and ceiling assertions |
| 28 | Repaired | P:479–492: maintainer-selected provider-side outage class; rate/quota/runner-network failures use the evidence-loss route |
| 29 | Repaired | PC:376–386; CM:6417–6429: logical-matrix/check-procedure change expressly proposed, not silently accepted |
| 30 | Partly repaired | P:676–721: committed heads, handoff supersession and authorized successor campaign are specified. R7-1 leaves the pre-dispatch continuation/head-commit join inconsistent |
| 31 | Repaired | P:447–460, :723–758: result precedence, closed event union, matrix ID and separate fixed/Pending digest slots |
| 32 | Repaired | P:613, :647–649, :1065–1067, :1227–1233: trace lane, legacy attendance position, daemon observer connection and canonical-file introduction owned |
| 33 | Repaired | CM:6325–6337: descriptor drafting scope bound to the maintainer-issued brief; authorization remains distinct from acceptance |
| 34 | Repaired | 0041-C:9; 0041-T:231–236; P:47: owner refinement before policy explicitly names the ADR 0009 amendment |
| 35 | Repaired | 0043-C:92–104; 0044-C:9, :170–178; 0046-C:102–112: cutoff, maintenance behavior, mandatory reply keys, default/alias and durable startup appear in Concept |
| 36 | Repaired | docs/vision.md:12–19 and docs/vision-technical.md:12–19 both list the linked section-25 risk note |
| 37 | Repaired | 0042-C:12; 0044-C:11; 0047-C:10; docs/adr/README.md:257–261; docs/plans/README.md:39–40; CM:368: dependencies, annotation set, rollback routing and coordinated acceptance align |

### Method, limits and retained scratch

The lead had prior involvement in preparing earlier M7 planning candidates. That history is a possible source of bias; this is not a claim that the lead was wholly uninvolved. Two fresh standalone readers supplied independent advisory judgments, and the lead rechecked every reported finding against current bytes. Their initial cache classifications differed; the report records the narrower implementation-obligation judgment and explains why. One reader initially did not identify the lane conflict, then confirmed it on a focused literal-clause check. Agreement is evidence of review coverage, not an acceptance vote.

Review coverage comprised the active plan pair and nine ADR pairs, the current repairs against all 37 round-6 IDs, applicable governance/verification/milestone rules, paired proposed vision clauses and their retained governing text, roadmap/successor assumptions and selected real source joins. The lead used prior full-vision context and current diff/constraint reads; this report does not claim each reader independently reread every unchanged line of the full vision or all accepted ADRs. The 57-file manifest is the selected documentation cone. Source and other accepted-contract reads were bound by the exact clean candidate, not claimed to be in that manifest.

The tools were not an enforced read-only sandbox. The review was performed with read-only commands by procedure, with no repository edits, branch switches, commits, builds, tests, check invocations, release lanes, provider calls, network access or credential inspection. The only new files were the standalone advisory brief and this report under /tmp. Advisory readers created no files. No sizing simulation or scratch executable was run; consequently no synthetic result is presented as live capacity evidence.

Provider behavior remains documented API intent from the packet's retained reference, retrieved 2026-09-30, not a live observation or verification of current provider service behavior. Pinned dependency source confirms hook ordering, not successful end-to-end provider operation. Relevant source joins also included the Model reply shape, session reducer intent/terminal records, executor refusal handling, Store private record fields and journal-page recovery. Compilation and documentation evidence do not prove the proposed M7 protocol, maintenance, cache, or provider implementation.

New retained scratch:
- /tmp/loopex-m7-round7-reviewer-brief.txt, SHA-256 e3673a8ed84ebb11c6c1639bcf0840db32a37f5c42c86630144e05333e991e7d.
- This fresh report, created exclusively under the requested /tmp report name or a fresh suffix. Its SHA-256 is supplied outside its bytes in the delivery message.

Final verification rechecked the bound receipt, prompt, manifest, log, result, remote-confirmation and disposition hashes, all 57 file hashes, parent identity and the received report's byte equality. HEAD and local origin/m7 remained 6f8d4759125cca54f493c69f5263974669260ebf, branch m7, clean.

Checklist: identity binding done; whole-packet advisory review and selected source joins done; all 37 prior findings reconciled; four current findings retained; report saved. Remaining work belongs to the repair owner: the four text/witness clarifications, review of the resulting exact candidate, and then the maintainer's acceptance decision. No repository repair or acceptance was performed by this reviewer.
