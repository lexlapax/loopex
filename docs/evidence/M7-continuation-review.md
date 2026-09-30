# M7 thinking continuation and helper recovery review

Date: 2026-09-30. Source checkpoint:
`4c2d1c9ff93accc4161697f83f87487d14266dd7`.
This follow-up addresses the remaining choice and a new recovery finding after
[the round 1 repairs](M7-audit-repair-review.md). Earlier reports and their
contract hashes remain historical evidence of the revisions they name.

## Concept

The maintainer selected [bounded thinking continuation](../developer/agent-context-map.md#disposition-m7-thinking-continuation-2026-09-30)
for selected Claude modes in M7, and [stop-only helper recovery](../developer/agent-context-map.md#disposition-m7-helper-recovery-2026-09-30)
after the helper manager crashes. Both choices are now proposed contracts.
M7 remains Open, ADRs 0041–0049 remain Proposed, and the narrow vision amendment
remains unaccepted. No product implementation or milestone acceptance follows
from this review.

The thinking contract preserves native provider blocks during the current tool
exchange, freezes its earlier conversation rendering, and refuses a request
that cannot fit. Later runs retain canonical conversation facts without old
thinking state. Private data uses existing session-store protection and retention.
The helper contract recovers completed evidence and stops unfinished work after
manager failure; it does not resume a child merely because a parent snapshot
looks active.

Three internal advisory delta reviews completed. Their actionable findings
were repaired: explicit native-to-canonical message positions, cancellation
before job registration, helper classification before activation, and at-most-one
rather than exactly-one creation/prompt proof after stop-only recovery. The
focused continuation follow-up found its mapping issue closed. External
re-audit remains required.

## Technical depth

### Contract changes and reasons

| Finding or decision | Proposed repair and required proof |
| --- | --- |
| Canonical history loses required Claude thinking blocks | ADR 0044 amends ADRs 0010/0017/0018 with bounded private reply/request forms, atomic settlement, charged context and deterministic native rendering. Prove several real tool rounds plus exact block/ID vectors. |
| ReqLLM ordinary conversion drops or rearranges blocks | Capture complete native content before lossy conversion within the existing transport/custody path. Buffered and streaming vectors include redacted blocks and completed signatures. No second provider client is introduced. |
| Signatures can bind to the whole earlier prefix | Freeze the complete rendering while the exchange is open; ADRs 0041/0043 prohibit rewriting earlier projections or compacting it. Bound failure ends reuse; a new run may compact canonical history. |
| Thinking budget can enlarge effective reply limit | Commit a verified mapping and reject conflicting reply limits before staging. Compaction records a same-model thinking-off override and keeps its 1,024-token reserve. |
| Recovery could submit an unadmitted child prompt after its parent stopped | ADR 0046 adds a durable stop fence, stop-only manager recovery, prepared abort without activation, and observational receipt lookup. Unknown-job cancellation closes helper admission for the incarnation without an unbound durable tombstone; replacement requires full composition fencing. Fault cuts prove no recovered prompt/provider dispatch and truthful cleanup. |
| Private data could leak or survive with invented lifetime guarantees | Retain it with private raw recovery history, exclude it from public/progress/diagnostic/tool/summary planes, and test canaries. Durable plaintext protection and ephemeral teardown retain their existing limits. |

This is a documentation-only change. The integrator owns all writes. Advisory
read-only reviews are internal checks, not a formal independent acceptance
review or the external audit. The implementation must still supply the fixtures,
wire versions, operator commands, live-provider demonstrations and closure evidence
specified by the plan.

### Prompt-cost planning measurement

A read-only source probe at the checkpoint above used Elixir 1.20.3 / OTP 29
and the existing estimator: sum each block's ceiling of canonical byte size
by three. The current coding profile is read/write/edit/bash; its tools cost
710 estimated tokens plus 89 for the current system block, totaling 799.
The read-only profile totals 602. All seven tools would total 1,176, but that
is not either current reference profile.

An arithmetic-only probe shortened descriptions to one character, removed
optional property descriptions and added skeletal artifact/question/helper
schemas. It totaled 825 with the old system block. This establishes neither
usable instructions nor a complete M7 prompt. The under-1,000 reference target
still requires measurement of meaningful final instructions, active definitions
and role facts, plus successful task evidence. No cap increase is authorized.

Retained probe files, outside the repository:

| Reference | SHA-256 |
| --- | --- |
| `/tmp/loopex-m7-system-cost-4c2d1c9f/measure.exs` | `bfe53e6d4fbfbb9ff0291b30e9c31c3bd7263e01f838de4ec3a7141f5aca420c` |
| `/tmp/loopex-m7-system-cost-4c2d1c9f/inputs.exs` | `73c04b4e6fae05e6af62defe71ba042207e686f772a6e24737687cf7146f28ee` |
| `/tmp/loopex-m7-system-cost-4c2d1c9f/results.exs` | `833f46134122e3f2e26e18baa9150359ac27c2663af2eedd8f75588559f827cc` |

### External re-audit scope

Review the complete M7 plan pair, Proposed ADRs 0041–0049 and the labelled
paired vision amendment together. Start from the retained round 1 assessment
and its repair record; then challenge this revision's changed contracts:

- atomic private reply settlement, exact prefix replay and source identity;
- bounded record/token accounting without artifact or truncation shortcuts;
- compatibility, private-data audience, retention and legacy decoding;
- compaction and model switching without old-signature resurrection;
- stop-only helper recovery, launch/cancel races and receipt lookup;
- outcome-to-proof mapping, attended steps and the existing closure procedure.

Report actionable contradictions or missing implementation decisions with a
concrete counterexample and affected paths. Distinguish plan readiness from
product proof and maintainer acceptance. Keep settled scope decisions intact;
identify any proposed change to one explicitly. No reviewer may accept or close
the milestone on the maintainer's behalf.

### Candidate identity and validation

The contract digest table below binds the files in this record's containing
commit, not future edits. Exact commit identity, clean-tree bootstrap/docs-check
outputs and their digests are retained outside the repository and reported at
handoff. No provider call, product suite or release check is claimed here.

| Contract | SHA-256 |
| --- | --- |
| [M7.md](../plans/M7.md) | `87521f259c9834f52dc36e559a6b4f52db74698eae22f8beca3f2c3e9e519258` |
| [M7-technical.md](../plans/M7-technical.md) | `b4e99dd760eaa6e75fb8be14cb851447a05e938d9ff48b72ff06925f5620a09c` |
| [vision.md](../vision.md) | `2482401ca2fddf5e205a70b3f734f78c1aad89c18c8f9804708e9cbe130b5c98` |
| [vision-technical.md](../vision-technical.md) | `ceb14c9b12bb909cb51b41f88227b56a8a9f6cc1890c7386291a236c2c6c5bff` |
| [roadmap.md](../roadmap.md) | `a36c6e36fd3d9f20161fa2d9357d249a239cfa3b53778122709aa59d924811cf` |
| [roadmap-technical.md](../roadmap-technical.md) | `7ed9ae9682cd0eeb1e4df376e784bd3411e63552f4f260cdbbdac59d1675f6de` |
| [0041-session-lineage-projection-and-context-budget-technical.md](../adr/0041-session-lineage-projection-and-context-budget-technical.md) | `090c69ef9f79f1baa7e75d12dcf19fad4805b180033f3ef8cfe7f25cae05fdc6` |
| [0041-session-lineage-projection-and-context-budget.md](../adr/0041-session-lineage-projection-and-context-budget.md) | `e071cf972b8700abc976b57fe04e5bd8e47ac7bd0c7b62ef0a856be123559e61` |
| [0042-host-composed-instructions-technical.md](../adr/0042-host-composed-instructions-technical.md) | `7ae5025d673c8d162aac8f57b723e1dd81488273146eabd204baf219d5f77c8b` |
| [0042-host-composed-instructions.md](../adr/0042-host-composed-instructions.md) | `56b5fffe527c953a87088d1c5099546b9b36736c469452dc3d1a5f0057019db2` |
| [0043-context-compaction-checkpoint-technical.md](../adr/0043-context-compaction-checkpoint-technical.md) | `b074c632d1a45fd4a9ae06dad8600534e008b5a0b5aa14f03264e44c3fe9360d` |
| [0043-context-compaction-checkpoint.md](../adr/0043-context-compaction-checkpoint.md) | `8dadedfb89f0ce35306082f275da6d66fc9b6c30a638a4894835349972470705` |
| [0044-run-model-and-reasoning-configuration-technical.md](../adr/0044-run-model-and-reasoning-configuration-technical.md) | `bf772baa8c7b0f86210823d308c422ee00876e08cee9e7e7dee3b49802ab1508` |
| [0044-run-model-and-reasoning-configuration.md](../adr/0044-run-model-and-reasoning-configuration.md) | `79793a8082356db992f30e4a9d92ffeae62cc2a13ed827efa800c2c241052ea0` |
| [0045-model-originated-questions-technical.md](../adr/0045-model-originated-questions-technical.md) | `be55cc9fc747dfe86069d81bb698b6bdbcb3d8e600b6ac17589c6baf2c956cba` |
| [0045-model-originated-questions.md](../adr/0045-model-originated-questions.md) | `ba150590a1d337ba591b4ed18ded6050a2d023762a0252629c34b33331e33e4a` |
| [0046-child-session-tool-technical.md](../adr/0046-child-session-tool-technical.md) | `ca08217399f994e3a18809878c116320019ded00225f04335dd8bfd1fe128980` |
| [0046-child-session-tool.md](../adr/0046-child-session-tool.md) | `8e8954d147a05b32576f6c439ebd3ed4056c7edd31eb239f050602d0f6606f2e` |
| [0047-reference-host-run-defaults-technical.md](../adr/0047-reference-host-run-defaults-technical.md) | `79bd57a7fb11077fab863b7c10450ca7675943b07627179434b3f613ab3818a0` |
| [0047-reference-host-run-defaults.md](../adr/0047-reference-host-run-defaults.md) | `4699888726ddc4ef4edd2768ac039b408e4515f0a94794211d33cab747b92b5f` |
| [0048-host-provider-routing-and-credential-bindings-technical.md](../adr/0048-host-provider-routing-and-credential-bindings-technical.md) | `7cb6d0187a75e22bbcc723aced9763f51dd965cd501b0c8f52337fa60829309e` |
| [0048-host-provider-routing-and-credential-bindings.md](../adr/0048-host-provider-routing-and-credential-bindings.md) | `61b1e639205762ad0ab55a6a273e707d43538a3b47073e2b30c735e18cd353ed` |
| [0049-explicit-host-configuration-technical.md](../adr/0049-explicit-host-configuration-technical.md) | `af3622063d76711bae31ddfa3714cf106dd5c45362ad65cfc2d56b8d8483cba9` |
| [0049-explicit-host-configuration.md](../adr/0049-explicit-host-configuration.md) | `65cfeddbeba3806f4f9e0f8df4c87da840d031a361fd4313159328282ad66137` |
| [0038-installed-distribution-and-release-artifact-technical.md](../adr/0038-installed-distribution-and-release-artifact-technical.md) | `b4d0503d93dfd912a9dbcb9726d70f0d2010fc13f96dc12cb4fc141d2dc92bba` |
| [0038-installed-distribution-and-release-artifact.md](../adr/0038-installed-distribution-and-release-artifact.md) | `7f85864dbc18ad9ba22e6befb847f8ce5ce3bbb103c3382eabf6334d7aaa5dac` |
| [agent-context-map.md](../developer/agent-context-map.md) | `dfde27b6935542d2c8058ee6839bc1e7ba15bffe781d2b910f5648f5c215ef3d` |
