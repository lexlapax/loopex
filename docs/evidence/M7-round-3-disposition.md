# M7 round 3 repair and internal review

## Concept

The external review of `a4c9061ee86a7442942207aa61ec022388bd7ac9` reopened
implementation-readiness. This record supersedes the earlier internal readiness
assessment for that candidate. M7 remains Open, ADRs 0041–0049 remain Proposed,
and the vision amendment remains unaccepted. This work repairs planning
contracts; it proves no product outcome.

The [received report](M7-external-review-3.md) is retained byte-for-byte with
SHA-256 `cbb9cd861bad099d215d0c5a2299e3d84840e8501a513435153a9afa9824b055`.
Its actual supplied file was `/tmp/loopex-m7-external-review-3.md`.

The maintainer approved option A extending the proposed vision amendment to
section 13.4. The [decision record](../developer/agent-context-map.md#disposition-m7-continuation-vision-amendment-2026-09-30)
names the scope. Other recorded choices remain: strict required model actions,
no reroll, bounded continuation, live durable streaming, verified summaries,
4-KiB requested artifact ranges, exact legacy inline compatibility, updated
wire clients and one helper per parent conversation across runs.

The optional proposal to exclude workspace paths from the prompt target was
not selected. Paths still count; demonstrations pin their actual roots and
repeat the profile gate before provider dispatch. Users may explicitly configure
a larger system ceiling within the input budget. This does not waive the
reference under-1,000 target.

## Technical depth

### Finding disposition

“Repair” means a proposed contract or implementation obligation changed; it does
not mean code exists or a live case passed. All numbered rows refer to the
external report. Source-backed subreviews checked helper ownership, provider
mapping/transport, and operator/closure mechanics. The lead checked context
selection, refusal schemas, governance and successor joins, then reviewed the
integrated result again.

| # | Disposition and contract |
| --- | --- |
| 1 | Repair in ADR 0043: terminal newest group can leave the protected tail when it blocks size or canonical-rendering admission; current-run inputs and open exchanges remain protected. |
| 2 | Repair in ADRs 0042–0044: versioned closed failure/refusal objects preserve old 1,000-limit decoding and bind new limits/targets to captured configuration. |
| 3 | Obligation in ADR 0043: optional tail growth respects the complete target; size maximal summary/profile/header combinations and pin the real fixture ceiling before dispatch. No synthetic estimate is a universal capacity promise. |
| 4 | Disclosure in ADR 0044: a large first prompt may fail initial reserve without any history to compact. |
| 5 | Repair in ADR 0043: unconfigured maintenance permits only work which still fits; startup/status warning and explicit restart remedy. |
| 6 | Repair in ADR 0043: output byte caps are ceilings; incomplete/invalid summary causes are closed and consume the attempted call without hidden repair. |
| 7 | Obligation in ADR 0042: path/catalog costs remain counted; actual demonstration roots must re-pass the reference profile gate. |
| 8 | Repair in M7: the real thinking case requires at least two continuation requests and retains exact input/record measurements. |
| 9 | Repair in ADR 0041: exact immutable read-generation capability registration selects the artifact or legacy branch; names/version prefixes do not. |
| 10 | Simplify ADR 0043: remove unreachable 8,192-byte per-end quota; four local candidates, bounded 4,099-byte buffers. Historical probe results retain their original revision. |
| 11 | Repair in ADR 0044: retained canonical-terminal-history capability, exact grouping, pre-dispatch refusal and explicit compaction/configuration remedy. |
| 12 | Repair in ADR 0044: literal Haiku manual summary eligibility, grounded in the provider's display contract and still subject to exact native conformance. |
| 13 | Repair in ADR 0043: maintenance requires normalized explicit disabled thinking; omitted/default cannot establish it. |
| 14 | Obligation, not a proved real-size failure: retained compact/expanded/settlement measurements under the selected bounds; no silent cap/display change. |
| 15 | Repair in ADR 0044: named transport handoff, exact native request installation and fatal-latch ownership; actual HTTP bridge integration required. Direct parser probes are insufficient. |
| 16 | Repair in ADR 0044: all new settlement writer paths use v3; validated non-continuation v2 adapter replies normalize with nil continuation; old settlements remain read-only. |
| 17 | Obligation: complete native field-set conformance; unknown fields fail, and new support requires a versioned renderer. Report supplies no live instance proving a required row fails. |
| 18 | Repair: eligible unsafe summary fragments retain the existing attempt-failure behavior; private ineligible text is suppressed before projection. |
| 19 | Repair: wire inventory includes instructions/create selections; digest recipe and ordered manifest preimages are pinned. |
| 20 | Repair in ADR 0046: register every routed job before forwarding; local and delayed cancellation retain classification. Only a true classification gap fences all helper admission. |
| 21 | Repair in ADR 0046: bounded journal-coverage query and stopped recovery for intent-before-reservation; absent creation is not evidence of unused allowance. Missing historical child evidence refuses. |
| 22 | Repair in ADR 0046: reverse creating-command provenance is derived from committed mappings, with a read-only Store callback and conformance. Missing logs cannot reclassify a helper as ordinary. |
| 23 | Repair in ADR 0046: retained-genesis lookup preserves exact v2/v3 input and original cleanup grace; current-default `/3` remains unchanged. |
| 24 | Preserve selected uncertainty. Child cleanup may finish after the parent's observation window; disclose that outcome in the operator steps. No new grace/admission restriction is selected. |
| 25 | Disclose the selected adapter mutation-domain fence across parents; best-effort cleanup still runs. Narrowing the fence is not part of this repair. |
| 26 | Clarify direct child abort refusal and parent-cancel/stop-only restart remedy. |
| 27 | Repair the follow-up promotion join: own authored absolute ceiling is separate from inherited ordinary bounds. |
| 28 | Reject as a required repair: 128 was already a ceiling, not promised capacity. Closing-frame credit and byte refusal remain mandatory; no artificial guaranteed count is added. |
| 29 | Repair by retaining delegation declarations with the immutable parent binding. Reject the suggested fresh invocation allowances because they would contradict committed resume settings. |
| 30 | Repair ADR 0049 pipe admission with `unknown`, uncertain barrier, stopped input and bounded cleanup; no false refusal or retry authority. |
| 31 | Repair ADR 0048: one private binding resolver, value-credential exclusion and chat-before-discard routing. |
| 32 | Repair M7: numbered bidirectional pipe case, owner and exact answer/decline oracle. Unexpected questions still fail the static pipe case. |
| 33 | Own provider-B mapping/pin work. Different admitted provider route is required; reject a new model-vendor exclusion. OpenRouter proves a different route, not necessarily a different model vendor. |
| 34 | Repair M7: three isolated source/build trees, preserved historical driver bytes and a separate M7 rollback pair; no reliance on VERSION alone. |
| 35 | Repair M7: trusted fixture-policy wrapper uses existing composition; effective origin is harness, restart preserves it, built-escript cases exercise the real command entry. |
| 36 | Repair final closed ephemeral options and exact trace defaults `loopex` plus `loopex_protocol`. “Extends” versus “supersedes” alone is not a defect. |
| 37 | Clarify: preserve the historical rollback pair; upgrade candidate-server consumers and independent Node vectors without dropping assertions. |
| 38 | Repair strict verdict/disposition mechanics and prior-failure records. No model miss becomes a pass or accepted limitation; unrelated new SHA is not reroll authority. |
| 39 | Repair the full-matrix join. Reject the categorical claim attendance is impossible: the full release runner already preserves human stdin. Attended `--only` remains refused; PTY auto answers are not attendance. |
| 40 | Repair manifest/receipt separation: committed static case keys and predeclared Pending slots; post-run identities belong to immutable retained execution records. |
| 41 | Repair case ownership/oracles for thinking, interrupted exchange, range-read inspection and old-baseline inspection. |
| 42 | Repair the approved fixture barrier invocation and exact release observations/deadline. Missing required call remains model nonconformance. |
| 43 | Repair pin chronology: runner logs the pin digest before dispatch; changed pins require the strict disposition path and retain previous failures. |
| 44 | Repair evidence slots for profiles, review hashes, failures, pins, renderer revisions, redaction and platform completeness. Darwin alone does not establish Linux-only obligations. |
| 45 | No ordering workaround: the local-cancel classification repair in row 20 applies regardless of scenario order. |
| 46 | Restore governing vision clauses beside labelled proposals, including diagram and founding decisions. |
| 47 | Approved drafting scope A: paired section 13.4 amendment and section 27 disposition. Existing private-store protection already permitted plaintext; the amendment names generic core validation and the retained lifetime. |
| 48 | Repair ADRs 0042/0044's explicit ADR 0039 amendments and the closed startup union; add ephemeral instruction/reasoning evidence. |
| 49 | Align all three outcome-prerequisite inventories to their union. |
| 50 | M9 and ADR 0036 reference M7's complete compatibility inventory; host ledger remains unchanged outside the Store migration and is included in whole-root backup/restore. |
| 51 | Complete ADR 0044's named ADR 0011/0025 amendments. |
| 52 | Repair successor links/dependencies and roadmap milestone projection; release versions remain unselected. |

### Internal adversarial repair loop

The lead reviewed the integrated contracts and used the Interrogate review
workflow with two fresh advisory reviewers: GPT-6 Astra and GPT-6.1 Sol. Both
received the same whole-packet intent/rubric. The panel was bounded to the live
concurrency available alongside integration. Three earlier scoped source readers
supplied proposals; those proposals were inspected before application.
These are advisory read-only assignments, not formal independent acceptance.
The formal `release_reviewer` role declined before inspection because its role
requires an enforced read-only sandbox and this session permits workspace writes.
It produced no findings and is not counted as a completed review.

| Finding | Source and lead judgment | Repair |
| --- | --- | --- |
| Artifact capability had no field in closed genesis | Astra and lead; act on, replay could not retain the required fact | Exact nullable `artifact_read` binding in v3 selection, fixed revision/table triples and legacy derivation |
| Recovery job could not be JSON encoded | Astra; act on, JobRequest includes binary canonical bytes | Immutable intent reference, field-specific binary encoding, private bounded retained-payload codec and post-encoding size/credit checks |
| Complete helper classification lacked a complete parent-session source | Sol and lead; act on, reverse hashed child identity cannot enumerate parents | Paged authoritative create mapping enumeration with fixed watermark, complete intent scans and live-create catchup |
| Small-model configuration could be stuck behind the only terminal group | Sol; act on, old window fits but configure target does not | Explicit compact may release the terminal newest group regardless of current fit; no provider call inside configure |
| Artifact preparation causes did not join the new closed failure union | Sol and lead; act on, preprojection error had no valid failure object | Enumerated causes and explicit unavailable projection with null measurements rather than invented zero observations |
| Canonical ETF decode does not directly return a genesis map | Astra and Sol repair rereads; act on, protocol Canonical maps use tagged trees | Separate private deterministic plain-ETF codec, safe bounded schema validation and exact re-encoding |
| Live conformance alleged bootstrap cycle | Considered by lead; dismissed after Astra reread | Deterministic mapping conformance precedes admission; owning live cases prove actual behavior, without a claim that a sample guarantees future capacity |

The lead also repaired the pipe uncertainty join: unresolved command admission
has an explicit host `commit_unknown` barrier with its command ID, not a fabricated
public terminal outcome. Governing vision clauses, prerequisite unions,
compatibility inventories and source-to-runbook joins were reread together.

### Internal review and verification

- Done: source checks and all 52 finding dispositions; selected-scope repairs;
  integrated lead review and two fresh advisory review/repair passes.
- Candidate checks: run `bash scripts/check.sh --docs` once from the clean final
  candidate. Its complete output and exact SHA belong in the external readiness
  receipt, with hashes of the contract manifest and next review prompt.
- Remaining after this planning pass: external audit and explicit exact-byte
  acceptance. Implementation, product checks and milestone closure are not done.

No provider request, full check or release lane has run for this planning repair.
Required product tests and demonstrations remain implementation obligations.
