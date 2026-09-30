# M7 internal planning review

Date: 2026-09-30. Scope: implementation readiness of the M7 plan, Proposed
ADRs 0041–0049, affected Proposed ADRs 0036–0038, roadmap and successor drafts.
The starting branch commit was `3e108749`; the first integrated checkpoint was
`077c3637`, pushed to `origin/m7`. This record accompanies the final repair
checkpoint at `20ff082a`. In that historical review, accepted ADRs, vision and
historical milestone evidence were not amended. Later repair records describe
the separately authorized proposed vision amendment and expanded scenarios. No product code or implementation proof is part of this review.

The maintainer requested an internal adversarial review with repair loops and
commits/pushes. Three read-only advisory workstreams reviewed core context and
interactions, host configuration/delegation, and operator/successor consistency.
The integrator made all edits. Reviewers revisited the repairs; final bounded
wording corrections were checked against their exact requested changes.
This is internal readiness review, not formal independent acceptance review.

## Internal checkpoint disposition

At `20ff082a`, the packet was offered for external audit.
The [first external review](M7-external-review-1.md) subsequently identified
implementation and vision gaps. The packet is not ready for acceptance while
those findings and the resulting maintainer decisions remain unresolved. M7 remains Open, all nine outcome rows
remain Open, and ADRs 0041–0049 remain Proposed with empty Acceptance rows.
External audit and explicit maintainer acceptance of exact committed pairs are
still required before dependent product implementation.

| Finding family | Repair retained in the packet |
| --- | --- |
| Cross-run history and admission | Run/turn/call-scoped joins, exact normalized 65,536-byte record limit, existing staging refusal and optional withholding |
| Compaction | Complete source groups, maximal bounded prefix, preserved unsummarized middle, distinct maintenance identity, durable attempt caps, checkpoint fencing and useful explicit pre-compaction |
| Instructions/model switching | Atomic settled configuration, strict ceiling/fallback, canonical-history replay with empty continuation, explicit accepted-clause amendments |
| Questions | Producer-specific atomic closure, policy-defer state preserved, negotiated schema, one-call ephemeral responder with joined cleanup on every path |
| Read-only helpers | Frozen role catalog, operation-stable commands, known failure versus uncertainty, complete receipt reconciliation and separate visible allowance |
| Helper persistence/deadlines | Private host ledger distinct from core Store, checked frame header, reserved closing-record capacity, generic persisted absolute deadline with replay/promotion semantics |
| Configuration/tracing | Closed explicit-file schema, exact CLI grammar, tool-profile combinations, text-only chat, invocation exit semantics, bounded runtime-owned trace consumer |
| Budgets | Mandatory file run limits, existing baseline, explicit child/aggregate allowance, truthful final-call overshoot and unknown usage |
| Operator validation | V1–V12 map configuration, questions, restart, compaction, tracing, provider A→B→A, parent A/helper B and budget exhaustion to proof |
| Roadmap/successors | M8 installation, M9 store, M10 extensions; M8 retains the directed ADR 0028 per-connection and 1 GiB transfer repair |
| Compatibility/packaging | Exact binary/record matrix, pre-upgrade backup procedure, no retroactive old-reader guarantees, external archive checksum avoids self-reference |

## Audit entry points and remaining gates

Read [M7 Concept](../plans/M7.md#concept) and
[Technical depth](../plans/M7-technical.md#technical-depth), then the nine
linked prerequisite ADR pairs. The technical plan's evidence matrix and V1–V12
scenario specification define implementation obligations, not passing results.

- Confirm the narrow accepted-contract amendments and the two stated vision
  readings for interaction tools and opt-in host helpers.
- Challenge durability and authority at configure, compaction, responder and
  delegation-ledger boundaries; assess whether the bounded host ledger is
  proportionate to the selected saved-role/budget/recovery outcome.
- During implementation, assign concrete protocol/schema IDs and vectors before
  exposing new shapes; pin fixtures, commands and pass criteria before proof runs.
- The maintainer chooses the external repository/task during testing. Pin its
  base and objective criteria before the attempt; retain failures and diffs.
- M8–M10 remain unaccepted future drafts. Engine selection, installed version,
  platform build recipes, exact rollback artifacts and later extension decisions
  are future gates, not hidden M7 prerequisites.

## Reviewed contract bytes

SHA-256 values identify the final plan/ADR contract bytes after the bounded
wording repairs. Commit `20ff082a` was the first audit handoff; these historical candidate
hashes do not constitute maintainer acceptance or bind subsequent repairs.

| File | SHA-256 |
| --- | --- |
| [M7.md](../plans/M7.md) | `fd029122758b2c5ad2c33fec3a3ccb431df2c74a7698ca662515b552294d3bf4` |
| [M7-technical.md](../plans/M7-technical.md) | `f61f7d50c9b715f62b0e9516e03fcb58c929de5c886c0622eac94492bb9249d1` |
| [0041-session-lineage-projection-and-context-budget-technical.md](../adr/0041-session-lineage-projection-and-context-budget-technical.md) | `88eded74c5a5b1c3b381ea2b24cae1409b3a6cc4f742c4f1dac1039bee472069` |
| [0041-session-lineage-projection-and-context-budget.md](../adr/0041-session-lineage-projection-and-context-budget.md) | `04c52f3b9d5bcf7274512b17df913ed6984cfce58ffea746d6669d8446515c92` |
| [0042-host-composed-instructions-technical.md](../adr/0042-host-composed-instructions-technical.md) | `ed58efa5ba69ca8c8b7541d191aea01e38e8dbbc406dbd5c2a3638b78beb3fa3` |
| [0042-host-composed-instructions.md](../adr/0042-host-composed-instructions.md) | `0183d2e6816e0b9f5933062a3d2a25f187279474551856011a3683d5c88b7292` |
| [0043-context-compaction-checkpoint-technical.md](../adr/0043-context-compaction-checkpoint-technical.md) | `eab1730e2416dcaaee3d09b539888a2b31881b483fd892f841600743db310d28` |
| [0043-context-compaction-checkpoint.md](../adr/0043-context-compaction-checkpoint.md) | `f1cb14a075f09d0c3db1554b99d116bb7681bda857ff6b29ae2278272e4a3939` |
| [0044-run-model-and-reasoning-configuration-technical.md](../adr/0044-run-model-and-reasoning-configuration-technical.md) | `e7f43bf080eebd94d74eb72f0defff3fa6d8e30313280ae1a1c8e005cda0be30` |
| [0044-run-model-and-reasoning-configuration.md](../adr/0044-run-model-and-reasoning-configuration.md) | `d64f8f84232191653b2fdc6ee69656ccde9ccc779ac4aca89e36296da5ab5907` |
| [0045-model-originated-questions-technical.md](../adr/0045-model-originated-questions-technical.md) | `07e751a73282242a5eff59bb811465b8ba46954ba6d6521db4be7bacb93364c6` |
| [0045-model-originated-questions.md](../adr/0045-model-originated-questions.md) | `b767752b80a67fdaabef6083a18d3b4c1e880e23eb7f59aaa6f444134962e018` |
| [0046-child-session-tool-technical.md](../adr/0046-child-session-tool-technical.md) | `bd8a61312733a60008424f9dc1e18be05995238372f6de6800803a0602a9c102` |
| [0046-child-session-tool.md](../adr/0046-child-session-tool.md) | `09a827342183692dfd94efc9df8e56963b343fec1abb03818731621e4992cd4a` |
| [0047-reference-host-run-defaults-technical.md](../adr/0047-reference-host-run-defaults-technical.md) | `79bd57a7fb11077fab863b7c10450ca7675943b07627179434b3f613ab3818a0` |
| [0047-reference-host-run-defaults.md](../adr/0047-reference-host-run-defaults.md) | `4699888726ddc4ef4edd2768ac039b408e4515f0a94794211d33cab747b92b5f` |
| [0048-host-provider-routing-and-credential-bindings-technical.md](../adr/0048-host-provider-routing-and-credential-bindings-technical.md) | `a57dfd6b756c802c813e107b49c4ef05f338d94fa52cedffe1770ee86bb531bb` |
| [0048-host-provider-routing-and-credential-bindings.md](../adr/0048-host-provider-routing-and-credential-bindings.md) | `e63a23bbd0249597c9effae91c0cae8657dd39ff388bd6ff37757668d7ff421d` |
| [0049-explicit-host-configuration-technical.md](../adr/0049-explicit-host-configuration-technical.md) | `de08939d6f9de3780ff81f754831ab9561028d496ece6a48ddbe00e228a9947e` |
| [0049-explicit-host-configuration.md](../adr/0049-explicit-host-configuration.md) | `618fbd19256215626858d9ae85b8f61dfc918a7c51103846d66222b50be8d482` |

## Validation scope

`mix loopex.status` and `git diff --check` passed during repair. A bootstrap
checkpoint passed after rerunning outside the sandbox because Mix's local TCP
lock was denied inside it. The final committed candidate must pass
`bash scripts/check-bootstrap.sh` and `bash scripts/check.sh --docs`; retain
complete outputs with its exact SHA outside the repository and report results
at handoff. Product and release suites are not substitutes for a planning audit
and were not run for this documentation-only change.
