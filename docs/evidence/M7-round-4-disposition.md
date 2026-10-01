# M7 round 4 disposition

## Concept

The external [round 4 report](M7-external-review-4.md) rejects planning candidate
`018c271c43b10baf79adacf0adb6f76e36510d0f`. This record reconciles all 55 findings
and the internal review of the repaired packet. It supersedes round 3's readiness
conclusion, without rewriting that historical evidence.

The maintainer selected A for lost post-dispatch evidence: retain the attempt,
require a reviewed causal fix and a new candidate. A new SHA alone permits no
retry. The [scope disposition](../developer/agent-context-map.md#disposition-m7-round4-evidence-loss-2026-09-30)
records the choice. The optional additional live capsule calibration remains
unselected. No provider call was made for this repair.

Planning repairs do not implement or accept M7. The plan is Open, the nine ADRs
are Proposed, and the labelled paired vision amendments await exact-byte
acceptance. Contract repairs, root review and the fresh advisory repair loop
are complete. The packet is ready for external re-audit. Exact committed-candidate
verification, remote identity and handoff artifacts are retained outside the
repository under the procedure below; they are not self-referential proof in
this record.

## Technical depth

The received report is retained byte-for-byte with SHA-256
`806c39d45bc9b1e57b3d3fe4e923fd4bbdb4b7223c03d4987bc01bebc1740573`.
Its read-only method and evidence limits remain those the report states. The
repairs below are text contracts or explicit implementation obligations, not
claims of passing product tests. The optional new command-ID namespace is not
selected; complete digest/provenance joins preserve conservative collision
handling.

| ID | Disposition | Owning contract and repair |
| --- | --- | --- |
| 1 | Repaired | [0043](../adr/0043-context-compaction-checkpoint-technical.md#technical-adr-0043-decision): Rendering-only explicit progress advances a contiguous cut toward the last offending unit; small groups may grow, hard limits remain, and completion requires rendering admission. |
| 2 | Repaired | [0044](../adr/0044-run-model-and-reasoning-configuration-technical.md#technical-adr-0044-decision): V3 replies retain validated completion classification. Maintenance rejects limit/unknown stops and v2 replies; validated usage is still charged. |
| 3 | Repaired | [0043](../adr/0043-context-compaction-checkpoint-technical.md#technical-adr-0043-decision): Summarizer startup validates known reserve capacities. Captured system preflight has numeric maintenance scope; missing recovery capture/route/renderer makes the session unavailable. |
| 4 | Repaired | [0043](../adr/0043-context-compaction-checkpoint-technical.md#technical-adr-0043-decision): Episode terminal precedes refusal, which immediately precedes run terminal in one transaction. Maintenance stage and unavailable projection disposition are explicit. |
| 5 | Repaired | [0043](../adr/0043-context-compaction-checkpoint-technical.md#technical-adr-0043-decision): Standalone candidate has no synthetic prompt. Closed completion, usage, cleanup and bound/provider/cancellation branches distinguish admission from completion; abort owns the episode. |
| 6 | Repaired | [0049](../adr/0049-explicit-host-configuration-technical.md#technical-adr-0049-decision): Status maintenance includes a closed warning slot, derived from committed mapping on open/resume. Ordinary availability is qualified by staging and reserve fit. |
| 7 | Obligation made explicit | [0041](../adr/0041-session-lineage-projection-and-context-budget-technical.md#technical-adr-0041-decision): Preparation retains deadline origin and only selected projection sources consume credit. Earlier run cutoffs retain normal bound outcomes. |
| 8 | Clarified | [0043](../adr/0043-context-compaction-checkpoint-technical.md#technical-adr-0043-decision): Protected tail is a contiguous suffix including later input-only units. Private numeric values remain integers; new public projections use exact decimal strings. |
| 9 | Repaired | [0044](../adr/0044-run-model-and-reasoning-configuration-technical.md#technical-adr-0044-decision): Every dispatchable proposed Claude row pins terminal-history capability true; deterministic proof precedes counted candidate-only live use, whose retained success gates ordinary support admission. No silent false downgrade of a failed required case. |
| 10 | Repaired | [0044](../adr/0044-run-model-and-reasoning-configuration-technical.md#technical-adr-0044-decision): Post-terminal rendering omits empty text and combines ordered results then adjacent user text in one native user content array. |
| 11 | Repaired | [0044](../adr/0044-run-model-and-reasoning-configuration-technical.md#technical-adr-0044-decision): Header explicitly amends ADR 0021 writer rule; first v3 settlement creates a monotonic session cutover. Earlier v1/v2 remain readable. |
| 12 | Obligation made explicit | [0044](../adr/0044-run-model-and-reasoning-configuration-technical.md#technical-adr-0044-decision): Exact nine-key v2 replies require provider_response_id. New requests always use v2; v3 adds completion and continuation with exact eleven/ten member counts. |
| 13 | Obligation made explicit | [0044](../adr/0044-run-model-and-reasoning-configuration-technical.md#technical-adr-0044-decision): Wrapper validates final headers/body/controls and forbids interleaved beta injection. Post-handoff validation failures retain dispatched_or_unknown classification. |
| 14 | Obligation made explicit | [0044](../adr/0044-run-model-and-reasoning-configuration-technical.md#technical-adr-0044-decision): Owner monitors a separate drain and fatal latch independently; exact pinned callback inventory and final-flush paths enter conformance. |
| 15 | Clarified | [M7](../plans/M7-technical.md#technical-plan-evidence): First real capsule observation counts as its declared case. Legal capacity refusal is product_failure for a positive case; no extra calibration selected or live proof claimed. |
| 16 | Clarified | [0044](../adr/0044-run-model-and-reasoning-configuration-technical.md#technical-adr-0044-decision): Literal response identity and native thinking_delta in a validated thinking block gate summary projection; signature/redacted events cannot qualify. |
| 17 | Clarified | [0043](../adr/0043-context-compaction-checkpoint-technical.md#technical-adr-0043-decision): Irreducible numeric failure precedes unnecessary maintenance configuration checks; eligible maintenance checks model, instructions and mapping in order. |
| 18 | Clarified | [0044](../adr/0044-run-model-and-reasoning-configuration-technical.md#technical-adr-0044-decision): Schema manifest names every closed member and includes canonicalization_revision in its digest preimage; independent Node vectors pin it. |
| 19 | Repaired | [0041](../adr/0041-session-lineage-projection-and-context-budget-technical.md#technical-adr-0041-decision): Capability table is an immutable core literal, independent of host files/registry. Create derives it and replay validates exact retained triples. |
| 20 | Repaired | [0041](../adr/0041-session-lineage-projection-and-context-budget-technical.md#technical-adr-0041-decision): Owner refinements enforce closed branches/ranges before policy. Policy identity uses authored args; only allowed job construction adds resolution. Executor lookup is ID/version/digest. |
| 21 | Repaired | [0049](../adr/0049-explicit-host-configuration-technical.md#technical-adr-0049-decision): Resume comparison is limited to retained ADR 0024 interaction identity. Settled sessions have no invented core policy identity; fixture cases reopen through their pinned wrapper. |
| 22 | Repaired | [0049](../adr/0049-explicit-host-configuration-technical.md#technical-adr-0049-decision): No task generation means delegation disabled without a binding; selected task requires matching enabled binding. Missing expected binding refuses activation. |
| 23 | Obligation made explicit | [0049](../adr/0049-explicit-host-configuration-technical.md#technical-adr-0049-decision): Every conflicting flag discovered after preparation abandons the prepared owner under ADR 0016, preserving unconfirmed failure. |
| 24 | Obligation made explicit | [0049](../adr/0049-explicit-host-configuration-technical.md#technical-adr-0049-decision): Unknown admission observes coordinator resolution within bounded cleanup grace; actual resolution or uncertain barrier is reported. Abort stays fenced and exit remains nonzero. |
| 25 | Clarified | [0041](../adr/0041-session-lineage-projection-and-context-budget-technical.md#technical-adr-0041-decision): Read is artifact-capable; grep/find/ls retain outputs. Phase 0 projection owner pins exact read version/digest and literal capability vectors. |
| 26 | Clarified | [M7](../plans/M7-technical.md#technical-plan-evidence): Remote create forbids derived tool_selection/artifact_read along with existing host metadata exclusions. |
| 27 | Clarified | [0041](../adr/0041-session-lineage-projection-and-context-budget-technical.md#technical-adr-0041-decision): Capability is attached to selected loopex.read ID/generation, never a display name or an acme.read alias. |
| 28 | Repaired | [0046](../adr/0046-child-session-tool-technical.md#technical-adr-0046-decision): Active registry reclaims slots; separate per-ID cancellation tombstones prevent delayed launch. Only tombstone overflow fences helper admission globally. |
| 29 | Repaired | [0046](../adr/0046-child-session-tool-technical.md#technical-adr-0046-decision): Bounded derived job index routes every original helper attempt and predecessor/recovered-no-child receipt without active registration; unknown cannot become Local absence. |
| 30 | Repaired | [0046](../adr/0046-child-session-tool-technical.md#technical-adr-0046-decision): Shared pure resolve/normalize helpers yield exact genesis before prepare. Host-private live exact-genesis create binds full digest and cannot substitute new defaults; recovery never creates. |
| 31 | Obligation made explicit | [0046](../adr/0046-child-session-tool-technical.md#technical-adr-0046-decision): Paged private reads use Store plain ETF size plus envelope and explicit early-stop/error rules rather than tagged Canonical size. |
| 32 | Obligation made explicit | [0046](../adr/0046-child-session-tool-technical.md#technical-adr-0046-decision): Retained-byte hash, complete safe decode and schema validation replace cross-major re-encoding equality; cross-toolchain object fixtures are required. |
| 33 | Obligation made explicit | [0046](../adr/0046-child-session-tool-technical.md#technical-adr-0046-decision): Child creation uses mandatory bounded immutable objects; frames contain only digest/reference and closing credit measures encoded JSON. |
| 34 | Obligation made explicit | [0046](../adr/0046-child-session-tool-technical.md#technical-adr-0046-decision): Cancellation reserves 250 ms for reply, forwards Local outside ledger queues, and preserves unknown when scheduling exceeds observation. |
| 35 | Obligation made explicit | [M7](../plans/M7-technical.md#technical-plan-evidence): Store callback and stable ordinal paging appear in compatibility inventory and successor obligations; unsupported callbacks are unavailable, not absent. |
| 36 | Not selected | [0046](../adr/0046-child-session-tool-technical.md#technical-adr-0046-decision): A new reserved client-ID namespace is unnecessary to the repair. Exact genesis/create-digest joins are required; ID collisions conflict/fence and confer no mutation authority. |
| 37 | Repaired; selected A | [M7](../plans/M7-technical.md#technical-plan-evidence): Runner records mechanical results; independent reviewer assigns cause. Product refusals/harness defects have routes. Post-dispatch loss requires reviewed causal fix/new candidate, without same-SHA retry. |
| 38 | Obligation made explicit | [M7](../plans/M7-technical.md#technical-plan-evidence): All paid executions register in retained attempts index before dispatch, including pre-merge lanes. Candidate scaffold includes known prior rows; no extra paid only-lane run after closure candidate declaration. |
| 39 | Obligation made explicit | [M7](../plans/M7-technical.md#technical-plan-evidence): Added policy-denial and daemon-detach owners; baseline/range subkeys, deterministic authority/late-steer/recovery/resume cases and trace-cleanup reuse have explicit ownership. |
| 40 | Obligation made explicit | [M7](../plans/M7-technical.md#technical-plan-evidence): Legacy eleven ExUnit rows remain; M7 executable wrapper family has exact identity/membership validation. Lane selectors and attended tty block/budgets are explicit. |
| 41 | Obligation made explicit | [M7](../plans/M7-technical.md#technical-plan-evidence): Planned mix loopex.m7_evidence task joins the existing fast check and validates keys, owners, classifications, profiles and oracles before demonstrations. |
| 42 | Obligation made explicit | [M7](../plans/M7-technical.md#technical-plan-evidence): Steer FIFO opens only after observer joins committed IDs; bound fixture pins one turn and cancel fixture gates the second request before real transport without fake replies. |
| 43 | Obligation made explicit | [M7](../plans/M7-technical.md#technical-plan-evidence): Historical driver executes from its own v0.3 extraction with original guards/worker bytes. Candidate uses distinct two-pair grammar and compatible isolated builds. |
| 44 | Obligation made explicit | [M7](../plans/M7-technical.md#technical-plan-evidence): Explicit release --pins FILE input validates immutable pins and logs their digest before first matrix dispatch; external selection precedes full invocation. |
| 45 | Obligation made explicit | [M7](../plans/M7-technical.md#technical-plan-evidence): Profile rows are fixed manifest keys before commit; only actual costs/identities/results remain Pending. |
| 46 | Repaired | [M7](../plans/M7-technical.md#technical-plan-evidence): Section 13.4 is prerequisite for outcomes 4/7; ADR 0044, index, context map and status-adjacent next-decision text name its authorized amendment. |
| 47 | Repaired | [0044](../adr/0044-run-model-and-reasoning-configuration-technical.md#technical-adr-0044-decision): Concept and paired vision explicitly retain host-resolved descriptor as bounded gating data; adapters alone interpret/translate native thinking controls. |
| 48 | Repaired | [0036](../adr/0036-daemon-grade-store-engine-and-migration-technical.md#technical-adr-0036-decision): Future capacity option belongs to a successor schema version or explicit ADR 0049 amendment, never an extra v1 member. |
| 49 | Repaired | [0049](../adr/0049-explicit-host-configuration-technical.md#technical-adr-0049-decision): Concept names required policy, tool profiles, question activation, opt-in helpers and harness-origin inspection; no hidden policy-module field. |
| 50 | Obligation made explicit | [0036](../adr/0036-daemon-grade-store-engine-and-migration-technical.md#technical-adr-0036-decision): Store records migrate; host ledger remains unchanged in place outside Store and joins whole-root backup. M9 Concept/technical scope agrees. |
| 51 | Obligation made explicit | [vision](../vision-technical.md#technical-vision-model-boundary): Paired continuation proposal names exact-block workflow evidence, empty legacy continuation and pre-upgrade backup rollback. |
| 52 | Clarified | [M7](../plans/M7-technical.md#technical-plan-evidence): All transitive dependencies must be accepted before dependent implementation; mutually dependent ADRs can be accepted as one coordinated packet. |
| 53 | Clarified | [vision](../vision-technical.md#technical-vision-model-boundary): Concept prompt target includes rendered environment facts/workspace paths alongside all advertised definitions. |
| 54 | Clarified | [vision](../vision-technical.md#technical-vision-model-boundary): Labelled terminology/provenance notes address interaction tools, user question data and bounded continuation; governing clauses stay visible. Punctuation conveys no new authority. |
| 55 | Clarified | [M7](../plans/M7-technical.md#technical-plan-evidence): Generated status row is preserved; adjacent indexed text explicitly adds external re-audit and both vision amendment acceptance prerequisites. |

### Internal adversarial review

The root's first pass repaired three interactions introduced or exposed by these
changes: rendering repair may need to cover earlier nonoffending units first;
maintenance numeric failures need an explicit measurement scope; and settled
fixture sessions must not invent a core policy identity. The chosen resume rule
uses ADR 0024 interaction identity and the same pinned fixture wrapper.

Two fresh advisory reviewers independently read the complete working delta,
M7/ADR/vision contracts, constraining source boundaries and the 55-finding
reconciliation. Reviewer A (`gpt-6-astra`) reported two warnings and one
formatting nit. Reviewer B (`gpt-6.1-sol`) reported three warnings. Their two
shared warnings have higher-confidence agreement; the two distinct findings
were independently adjudicated by the root. All four were acted on:

| Finding | Reviewers | Root disposition and repair |
| --- | --- | --- |
| Unknown admission resolves to active work before shutdown | A, B | Act on: one captured shutdown deadline; abort/clean before barrier; closed host-only cleanup_unknown branch and no fabricated public outcome. |
| A new mapping needs the live proof that ordinary admission would prevent | A, B | Act on: deterministic-first, trusted candidate-only use in the existing counted cases; unverified label and retained real success gate ordinary support. No calibration or reroll added. |
| Helper evidence bullets retained the old lifetime/global fence rules | B | Act on: align witnesses with active capacity reclamation, per-ID tombstones and the separate overflow fence. |
| Interrupted glossary table and physical wrapped table cells | A | Act on: move the note after the table and keep complete M7/M9 rows on one physical line. |

Both reviewers then re-read the repairs and reported every finding resolved,
with no new contract interaction found. The root checked the closed pipe outcome
union and propagated candidate-conformance ordering into the Concept companion
and plan. No unresolved contract blocker was found in this internal loop.
No finding was dismissed or deferred.

The reviewers used read-only commands by procedure; their tools were not an
enforced read-only sandbox. They made no edits, ran no tests or lanes, made no
provider calls and spawned no agents. These are internal advisory reviews, not
the independent acceptance review. Runtime behavior and live capacity remain
implementation/proof obligations, not conclusions of this document review.

### Verification and handoff

The final documentation-only check will run once on the committed clean candidate.
Its retained log will contain exact HEAD, before/after clean state, start/end
identity, complete output, exit status and measured duration. The final receipt
will bind that log, candidate/remote SHA, contract manifest and next review prompt.
No product suite, release lane, provider call or closure proof is claimed.
