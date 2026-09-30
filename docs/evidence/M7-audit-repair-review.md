# M7 external-audit repair review

Date: 2026-09-30. This documentation revision responds to the
[round 1 external assessment](M7-external-review-1.md) of `20ff082a`.
The earlier [internal review](M7-planning-review.md) and its hashes remain a
historical checkpoint. No product code, accepted ADR, historical closure or
release claim is changed by this revision. The maintainer expressly authorized
drafting the narrow proposed amendment to both vision files.

## Disposition

M7 remains Open, ADRs 0041–0049 remain Proposed, and the labelled vision
amendment remains pending acceptance. The maintainer's reasoning compatibility
choice is still pending: a verified canonical-history subset, or bounded
provider-specific continuation in M7. The current ADR 0044 canonical-only text
is explicitly a draft. The complete packet is not ready for acceptance until
that choice is reflected, the affected contracts are reviewed, and external
audit completes. The external repository/task remains intentionally selected
during testing, then pinned before its attempt.

Three internal read-only advisory workstreams revisited context/artifacts,
architecture/authority and operator/compatibility contracts. The integrator
owned all writes. Their bounded delta reviews closed the listed contract gaps;
final repairs are identified below. This is not a formal independent acceptance
review, a product test result or evidence that the features exist.

## Findings and repairs

| External finding | Revision and remaining verification |
| --- | --- |
| 16-KiB tool output cannot safely fit compaction/request budgets | ADR 0041 uses bounded executor-result excerpts, retained artifacts and explicit read ranges; full request stays inline. Original receipts remain unchanged. Encoded byte, token and final double-representation checks remain independent. |
| Seven tools and no built-in sub-agent conflict | Both vision files carry a labelled proposed amendment for seven workspace tools plus question and opt-in serial read-only helper tools. Prompt measurements include all active definitions. No acceptance is implied. |
| Undeclared accepted-contract changes | ADRs name input algebra, context placement, first-staging deadline, genesis, defer handling, argument resolution and provider-attempt maintenance amendments explicitly. Accepted source ADRs stay historical. |
| Existing ephemeral API omitted | Preserve multi-prompt start/ask/answer/history/stop; extend the existing answer path and add only the one-shot responder wrapper. Callback failure aborts and joins cleanup. |
| Runtime-wide tools, startup order and catalog binding | ADRs 0044/0046 share v3 genesis, immutable per-session tool/defer selection, a closed-until-bound router, fixed task schema and durable prepare/create/bind ordering. |
| Child policy defer and hidden time limits | Child defer becomes a known denial. The task definition explicitly names effect/idempotency classes and its 600,000-ms wall ceiling; the recorded effective job deadline bounds children. |
| Configuration, credentials and reasoning capability | Explicit instruction renderer/version, trusted configuration authority, frozen capability metadata, protected env names and preserved credential-free ephemeral routes. Reasoning continuation scope remains pending; outgoing translation may not raise committed reply limits. |
| Piped chat unspecified | ADR 0049 gives newline framing, /wait, exact-ID answer/decline syntax, event-specific control records, bounded backpressure, fail-fast script errors and truthful EOF/signal cleanup. |
| Closure oracles and attendance unspecified | M7 names fixture manifest/oracles, exact-command fixture policy through trusted harness composition, independent immutable checks, fixed attended steps, V13 and the future exact-candidate evidence scaffold. Pending scaffold fields remain permitted before their runs. |
| Protocol, release and migration joins omitted | One integration owner covers both existing server generations, payload-schema digests/Node vectors, release selectors, multiple credential redaction and existing PTY adaptation. V13 uses quiescent copies and the exact M6 artifact, without M8 commands. |
| Successor and routing drift | Context-map M7 routing/decisions, roadmap status and Proposed ADR 0038's conditional switch-back language are reconciled. |

## Review refinements

The arithmetic issue is real and stricter than the original illustration: two
16-KiB results contribute 65,536 bytes across semantic messages and canonical
request bytes before framing. This does not itself prove the small two-prompt
fixture fails; implementation must measure the actual fixture. The existing
attended PTY helper is reusable. Existing plan prose already retained maintainer
scope choices; the new context-map entry supplies a nearer routing pointer.
Backup/restore proof needs a quiescent fixture procedure, not M8 product commands.

Delta review also required:

- distinguish receipt-content excerpt offsets from artifact-object read offsets;
- refuse required artifact reads when a frozen old tool generation lacks them;
- commit preparation deadlines/reservations before artifact retention, with
  count/byte/time caps preserved across restart;
- select compaction prefixes against the complete maintenance request as well
  as its source cap;
- preserve full bounded question answers separately from executor projections;
- define exact genesis fields and keep old-reader behavior evidence-based;
- make pipe control schemas, text-answer escaping and overflow handling explicit;
- preserve the Proved/Pending candidate procedure and use a separate pinned
  unanswered-question restart case.

## Candidate contract bytes

These hashes bind the contract files in the commit containing this record;
they do not bind future revisions or constitute acceptance. Historical hashes
in the prior review were not refreshed.

| File | SHA-256 |
| --- | --- |
| [M7.md](../plans/M7.md) | `5c26c6aa1dfb4e480b351d545c2ecf96278bb12b33d232a05e13e91efe8d032a` |
| [M7-technical.md](../plans/M7-technical.md) | `fd11b8c4581cfb0d5a614a4d1b673ccea748b59c96dcb88e2c70ffc53054bbaf` |
| [vision.md](../vision.md) | `2482401ca2fddf5e205a70b3f734f78c1aad89c18c8f9804708e9cbe130b5c98` |
| [vision-technical.md](../vision-technical.md) | `ceb14c9b12bb909cb51b41f88227b56a8a9f6cc1890c7386291a236c2c6c5bff` |
| [roadmap.md](../roadmap.md) | `a36c6e36fd3d9f20161fa2d9357d249a239cfa3b53778122709aa59d924811cf` |
| [roadmap-technical.md](../roadmap-technical.md) | `7ed9ae9682cd0eeb1e4df376e784bd3411e63552f4f260cdbbdac59d1675f6de` |
| [0041-session-lineage-projection-and-context-budget-technical.md](../adr/0041-session-lineage-projection-and-context-budget-technical.md) | `9f5ccdf418250405f0046a97c80dc75505bdb2a2b726cc9a8d2c7251259a2c0a` |
| [0041-session-lineage-projection-and-context-budget.md](../adr/0041-session-lineage-projection-and-context-budget.md) | `4575f2be76f194762b9ef2566bba87ed1dcec458bda69d0849840914fd9f4d2c` |
| [0042-host-composed-instructions-technical.md](../adr/0042-host-composed-instructions-technical.md) | `7ae5025d673c8d162aac8f57b723e1dd81488273146eabd204baf219d5f77c8b` |
| [0042-host-composed-instructions.md](../adr/0042-host-composed-instructions.md) | `56b5fffe527c953a87088d1c5099546b9b36736c469452dc3d1a5f0057019db2` |
| [0043-context-compaction-checkpoint-technical.md](../adr/0043-context-compaction-checkpoint-technical.md) | `aaa17ba0f964ba6ade3931ad46567dd64428ce88ec43d118be2d1388cf451685` |
| [0043-context-compaction-checkpoint.md](../adr/0043-context-compaction-checkpoint.md) | `f04b83ba1a540202809433f88895a13726fc6e285068c48a873be42417142460` |
| [0044-run-model-and-reasoning-configuration-technical.md](../adr/0044-run-model-and-reasoning-configuration-technical.md) | `00d6f387c6616f393c4ea017a9530af8cdff73d69edf9e315deda5ffd358174a` |
| [0044-run-model-and-reasoning-configuration.md](../adr/0044-run-model-and-reasoning-configuration.md) | `99188c247623b9f56c08bb6d78e82cb97ff2d267f735008e5cd80b02e52a4994` |
| [0045-model-originated-questions-technical.md](../adr/0045-model-originated-questions-technical.md) | `be55cc9fc747dfe86069d81bb698b6bdbcb3d8e600b6ac17589c6baf2c956cba` |
| [0045-model-originated-questions.md](../adr/0045-model-originated-questions.md) | `ba150590a1d337ba591b4ed18ded6050a2d023762a0252629c34b33331e33e4a` |
| [0046-child-session-tool-technical.md](../adr/0046-child-session-tool-technical.md) | `3243be0b2ef988cdd055e6341ec5a1a83ab1f36795ca9e0d07e4cc9256deb8a6` |
| [0046-child-session-tool.md](../adr/0046-child-session-tool.md) | `94263084afed7c7d91ebcd76fcb52278c93e5acb2b861eb682a9b62868e8ab12` |
| [0047-reference-host-run-defaults-technical.md](../adr/0047-reference-host-run-defaults-technical.md) | `79bd57a7fb11077fab863b7c10450ca7675943b07627179434b3f613ab3818a0` |
| [0047-reference-host-run-defaults.md](../adr/0047-reference-host-run-defaults.md) | `4699888726ddc4ef4edd2768ac039b408e4515f0a94794211d33cab747b92b5f` |
| [0048-host-provider-routing-and-credential-bindings-technical.md](../adr/0048-host-provider-routing-and-credential-bindings-technical.md) | `7cb6d0187a75e22bbcc723aced9763f51dd965cd501b0c8f52337fa60829309e` |
| [0048-host-provider-routing-and-credential-bindings.md](../adr/0048-host-provider-routing-and-credential-bindings.md) | `61b1e639205762ad0ab55a6a273e707d43538a3b47073e2b30c735e18cd353ed` |
| [0049-explicit-host-configuration-technical.md](../adr/0049-explicit-host-configuration-technical.md) | `af3622063d76711bae31ddfa3714cf106dd5c45362ad65cfc2d56b8d8483cba9` |
| [0049-explicit-host-configuration.md](../adr/0049-explicit-host-configuration.md) | `65cfeddbeba3806f4f9e0f8df4c87da840d031a361fd4313159328282ad66137` |
| [0038-installed-distribution-and-release-artifact-technical.md](../adr/0038-installed-distribution-and-release-artifact-technical.md) | `b4d0503d93dfd912a9dbcb9726d70f0d2010fc13f96dc12cb4fc141d2dc92bba` |
| [0038-installed-distribution-and-release-artifact.md](../adr/0038-installed-distribution-and-release-artifact.md) | `7f85864dbc18ad9ba22e6befb847f8ce5ce3bbb103c3382eabf6334d7aaa5dac` |

## Validation scope

The final committed revision must pass repository bootstrap and documentation
checks; retain complete logs outside the repository with exact SHA and digests
and report them at handoff. A focused structure check passed during revision.
No provider calls, product test suite or release check ran for these planning
changes. Runnable fixture assets, operator commands and product evidence remain
implementation obligations after exact-byte acceptance.
