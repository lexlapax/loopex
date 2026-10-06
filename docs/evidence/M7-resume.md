# M7 restart checkpoint

Part of the [evidence index](README.md). This is a resume record, not an
acceptance, milestone closure or verification waiver.

<a id="concept"></a>
## Concept

M7 implementation resumed after the maintainer restart on 2026-10-05. Continue
the existing active goal on branch `m7`; do not use `m8`. Read this file,
[AGENTS.md](../../AGENTS.md), the [plans register](../plans/README.md), the
accepted [M7 plan](../plans/M7.md#concept) and its
[technical companion](../plans/M7-technical.md#technical-depth), then the
[task ledger](M7-implementation-tasks.md). No fresh milestone, goal or alternate
checklist is needed. Original T00–T19 rows remain frozen and count separately
from added implementation subtasks.

Maintain current contracts only before 1.0. Remove superseded readers and
fallbacks; current restart/replay, durability, authority and cleanup remain
required. Decisions are asked one at a time, with plain-English consequences.
No main merge, milestone closure, tag, release, publication or paid evidence
campaign is authorized by this checkpoint. Accepted ADR 0051 permits its exact
physical restore implementation; it does not waive any full-history proof.

<a id="technical-depth"></a>
## Technical depth

### Current proof, execution and source ownership

CURRENT COMBINED RESULT: original outer handle 8713 is terminal exit 1 and
fully collected. The tested formatter child is
`0e5af3cc587b2d2409a3efd213cc38b0def86070`, isolated and frozen in
`/private/tmp/loopex-m7-current-restore-integration`. All eleven current-pair
lanes passed with zero skips: IO 94/2, Model 28/0, Composition adjacent 21/0,
Receipt 32/0, Ledger 23/0, ReadOnly 22/0, Local adjacent 21/0, Artifact 29/0,
Composition 665/3, Local 302/2 and owned IO long 2/94. Pipeline duration was
1,203.037 seconds. Floor dev compilation passed, then floor format-check exited
1 in 0.356 seconds because it wraps one captured-open binding differently.
No floor tests or subsequent gates ran. This complete attempt remains
FAIL_OR_UNAVAILABLE; no row closes from the current-only passes.

Sibling `M7/m7-restore-join-v1` retains terminal report
`3066aefbf07d1ab72773d7d99a88f3ac6cf91a7bf811da6d0ad33ba122f04c5a`, inventory
`910b871fd850ca026bb07fcc76f5708361e98351cb8a00b639116d4b231292d7` and floor
formatter raw output
`83ba0d63827679fdd8caeb1480bf3ef0c27e44596743827a6640a262d512cb02`. Root read the
complete formatter patch and independently verified 164 sealed artifacts,
43 original raw/started/terminal stages, 124 final actual/Git/kind/mode source
records, the full Git-tree projection and all original PIDs/groups absent.
The canonical `M7/current-restore-stage-attempt-registry.json` has 43 unique
consumed keys and digest
`b7039ce5dd84287a5e1e8f218bebf547c57e00beb4cfb6add398b4adcbcc27d0`; never reset.
The root audit is retained in
`M7/current-restore-join-root-audit-20261005-v1`, retention map
`8bbf591df1b10d80246cec4a32d2ecaf0a44a21e99308be409f6c548ceb3c264`.
Original handle 8713 must never be polled or retried. Its execution grant ended and its slot returned before the separate grant below.

CURRENT OBJECT SOURCE: clean
`8c9c4f924bdd7131a2fc2cce09b2c6bb85d083e5` in
`/private/tmp/loopex-m7-artifact-object-physical-capture` adds the private selected
object audit and twelve cases. Root and independent source review found no
blocker; root verified eleven writer artifacts, thirteen Git inputs, five prior
references, four independent artifacts, sixteen independent Git inputs and
seventeen external references. All 96 previous IO cases remain unchanged.
It reuses the original guardian and streaming hash, preserving locator/digest
reader relations, uint64 reference sizes, original total/work/cleanup limits
and orphan/staging bytes. The actual 64 MiB + 1 reader fixture is source only,
not proof that the writer accepts that size or that its cutoff passes.
Object hashing does not prove complete history, namespace or activation.

Immutable sibling `M7/artifact-object-physical-source-20261005-v2` preserves all
12 original packet bytes and the original inventory's historical 0644 modes;
its separate retention map records the new 0444 copies, digest
`2dd3226767e35e8b1b71ea56a4b9398bd53148ad3a317a421f5cfbbacf489534`. Writer report
`9a2b267a574bf7592f2b9af5638d4bc93eb17b75410df49635f1037540d891e4` and independent
report `89dbc2c2d569f3b6bc6d26f0db96949dd80ef0355cd7ffd6887237f75093f2c0` remain
source evidence. One added T15 row stays open.

CURRENT CORRECTION CANDIDATE: root merged reviewed object source into the frozen
formatter child through `83994da3bd2e4d64e708405048a924a8bae17e07`, then committed
`fb23ac0d75cdaa92ec2862c499b28b9bfa63e24a` in
`/private/tmp/loopex-m7-object-format-integration`, branch
`codex/m7-object-format-integration`. The correction only renames `open` to
`open_records` at the captured binding and its two uses. IO calls, data, order
and limits remain unchanged. The following attempt records its allowed formatter child and first failure; no
suite has run on those bytes. Its full delta from `3030f46a` is still the eight owned paths.
Independent source review found no blocker; root verified its seven artifacts,
forty Git/kind/mode inputs and three original floor-evidence references. Report
`fee4a0aee99de043bc782e058113e850ba8df130f8eefdf2999eeb09fc68b285` is retained in
`M7/object-format-fb23-independent-review-20261005-v1`. Current-index agent
prepared a separate disabled runner; both formatter checks precede compilation,
gates and suites. Sibling `M7/object-restore-integration-runner-20261005-v1`: run
`1deaff39e380179b21595c987f12bcf2dcc5ea5185334957d1b9c10e19804474`, disabled config
`512ee8618ff653365ec2947ce1feed33284001e75d9acd6573944bf930fd171d`, final inventory
`a0c3917b7a4989c181f88b24fbb36901419dd50663a685f928bb641fc1dbc73e`. Root verified 197 sealed artifacts, 124 actual/Git/kind/mode sources,
29 external inputs, eleven byte-identical shared functions and exact old-case
preservation. Independent runner review found no blocker; report
`03e0f3327ab17f53b736fdd41a407cd95d9484584ac0dd37b7503a1345fe0807`, inventory
`e9280b72d3b6a0eea9ffb1d7ab39acf50b17a27751810d7dd2542edf294b1c05`, retained in
`M7/object-restore-integration-runner-independent-review-20261005-v1`. Root
verified its four artifacts and 207 recorded inputs before finalization.

COLLECTED OBJECT EXECUTION: root finalized separate enabled sibling
`M7/object-restore-integration-runner-20261005-v2` and verified 218 artifacts
plus root inventory. Active code and helper bytes match the disabled packet;
its historical inventories apply only to the complete `disabled-review-packet`
copy. Enabled config
`c52a1fdc64f1117dead19452996906f55de58c1a3b6adbd516865804d9ef853c`, root inventory
`aecb08236178c9b867a0fe611fee25a994c26d231e592ec881dc52024662e378`. Fresh canonical
`M7/object-restore-stage-attempt-registry.json` was seeded at
`1a5f5f5aa0ba2c8e25a6d0994e96d5911cd7194ee78b447a194f0321f46bdbf0`; never reset.
Root granted current_index_cleanup one exclusive current/floor campaign under
original outer handle 14406; that attempt is now terminal and fully collected. Output
is `M7/m7-object-restore-join-v1`. Preserve the old 43-key registry and failure;
stop at first failure, retain original status/raw EOF/source/modes and exact
joins, then collect the original handle before returning the slot. Only the
reviewed eight-path AST-equal clean single-parent formatter child/re-pin is
permitted. No source repair, retry, second VM, full-fast, provider, release,
attended, Linux, primary source rejoin or broader restore claim is granted. Proposed IO
106/2, Composition 677/3 and long 2/106 populations include twelve new object
cases; other lane populations stay unchanged. No retry of old source is allowed.

LATEST OBJECT FAILURE: original 14406 is collected, exit 1, with its VM slot
returned. The clean permitted formatter child is
`6d9dfed9405ccb279d9abdddaa4d9b1e5c52f318`, exact single parent `fb23ac0d`.
Root read the complete two-path formatter patch; all eight whole-file non-line
AST checks passed. Immediately following current format-check failed in
0.399 seconds at `restore_io_test.exs:1810`, requiring a different multiline
argument layout from the mutating formatter's output. Pipeline duration was
85.127 seconds. No floor formatter, compilation, gate or suite ran.

Sibling `M7/m7-object-restore-join-v1`: terminal report
`750d1033d84e18fa627dda220672036a3acce3a9b918018fb97819694f1a026d`, inventory
`38693a9a73d1674e87ed886594c741f6a756df081949b2012c6885c9f09c4247`, raw failure
`0b5a1e847ef0423bde357b4347c41de51b50b7632b777ab2eb534ae6471bd77c`, formatter
patch `2df8a6c3369fd2b29d87c9fabfb1dd4ef0850e260bc6a2ba83891438ee4d9341`. Root
independently verified 55 sealed artifacts, eight original raw/started/terminal
stages and eight unique consumed keys, 124 final actual/Git/mode sources,
full tree projection and all eight PIDs/groups absent. Root audit sibling
`M7/object-restore-join-root-audit-20261005-v1`, retention map
`00336645834c6c742a6bc74e9a15f94f492d053f9bebea4e887409449cf5074c`.
The canonical object registry now has eight keys and digest
`8e428a322645e23bcd0748a13ab5cd03fb70127e5a9c85c750bc3a55b8267aaa`; never reset.
The old 43-key registry remains unchanged. Never poll or retry original 14406.
No verification VM runs and its grant has ended.

NEXT SOURCE CANDIDATE: root created isolated
`/private/tmp/loopex-m7-object-call-fixture`, branch
`codex/m7-object-call-fixture`, from frozen `6d9dfed9`, then committed and pushed
`2826b30bfc583ff943cdbe63c99041950d1c907f`. Its only change binds the unchanged
invalid artifact request tuple to `invalid_operation` before the existing
RestoreIO.run call. All arguments, probe, assertions and 1,000/100-ms fixture
limits remain exact; no test or production bound changes. This avoids the
formatter's unstable multiline call shape. Independent source review found no blocker; root verified its six
artifacts, 33 exact Git inputs and four original failure references. Report
`669295dc69e8b4f839835ec062bb0afee02e660452acd9b82255c086978c6557` and inventory
`574b76dd43b5c4f638e449cfefbf070660cfd3c115a0750a5bba43a2655f4dac` are retained in
`M7/object-call-2826-independent-review-20261005-v1`. Inlining the tuple binding
reconstructs the complete parent test bytes; no bound or assertion changes.

CURRENT OBJECT-CALL GRANT: root reviewed disabled sibling
`M7/object-call-integration-runner-20261005-v1`, verifying 198 artifacts plus
inventory, 124 actual/Git/kind/mode source inputs, 38 external references,
eleven unchanged shared functions and unchanged source populations. Run
`b17b280c2e5ec86c69f55c258feba05d318413e28b2cbb87ddaa8d67ccbd1a92`, disabled config
`7bc397c27d3215087246c050560c535b023e4caa305d2f51c3dbbb222e0255fd`, inventory
`b62ef535e9bb6c4adf2137f20153ca9e73f768cf76287933758d3f2b66d68b36`. Independent
runner review found no blocker; root verified its five artifacts and 370 hashed
inputs. Review sibling
`M7/object-call-integration-runner-independent-review-20261005-v1`, report
`0a46ea206af22a3a9cc60fad02b975fa0ddca687ca72bf3c349ac7a4515cdb41`, inventory
`5c122da774e97bb601ccc00d2bb6091c055de223abf311c451bd905d2e85582e`.

Root finalized separate enabled sibling
`M7/object-call-integration-runner-20261005-v2`, retaining exact code and a full
historical disabled copy. Root verified 220 active artifacts plus inventory.
Enabled config
`ab7f4446dd42d31099970463d5c3ce0bc1270c94bd5da6576e43f31fb313e48b`, root inventory
`e83bb109e019e49462d0cf9ef9c57065027aea424f76041c9d10f90a4eb7e0e9`. Fresh canonical
`M7/object-call-stage-attempt-registry.json` was seeded empty at
`1a5f5f5aa0ba2c8e25a6d0994e96d5911cd7194ee78b447a194f0321f46bdbf0`; never reset.
The old 43-key and eight-key registries and both failed outputs remain unchanged.
Root grants current_index_cleanup the sole verification VM for one sequential
current/floor run, new output `M7/m7-object-call-join-v1`. Original outer handle
13676 is now terminal exit 0 and fully collected by that agent. Its exclusive
VM slot is returned; never poll or rerun that original handle.
Both early formatter checks passed without a source change: current 0.398 s,
floor 0.371 s. Current dev/test compilation and all five gates passed. All
eight current focused/adjacent lanes passed with zero skips: IO 106/2 in
42.647 s, Model 28/0 in 27.430 s, Composition adjacent 21/0 in 4.721 s,
Receipt 32/0 in 24.040 s, Ledger 23/0 in 2.203 s, ReadOnly 22/0 in 19.953 s,
Local adjacent 21/0 in 19.205 s and Artifact 29/0 in 1.965 s. Ordinary
Composition passed 677/3 with zero skips in 356.395 s.
Current Local passed 302/2 with zero skips in 180.623 s and long IO passed
2/106 with zero skips in 22.740 s. All eleven current lanes/gates passed.
Floor dev/test compilation passed in 34.759/34.029 s, all five floor gates
passed. All eight floor focused/adjacent lanes passed with zero skips: IO
106/2 in 36.461 s, Model 28/0 in 27.143 s, Composition adjacent 21/0 in
4.596 s, Receipt 32/0 in 21.477 s, Ledger 23/0 in 2.074 s, ReadOnly 22/0 in
29.739 s, Local adjacent 21/0 in 17.853 s and Artifact 29/0 in 1.908 s.
Floor ordinary Composition passed 677/3 in 347.614 s, Local passed 302/2 in
191.381 s and long IO passed 2/106 in 22.703 s, all with zero skips. Both pairs
passed all eleven selected lanes. Pipeline duration was 2,213.591 seconds.
Original handle 13676 is collected and its execution grant ended.
The Darwin invalid-filename witness remains unavailable, not PASS.
Both formatter checks precede compilation, gates and suites. Preserve all
original statuses, raw EOF, source modes and exact process joins; stop at first
failure, collect the original handle, then return the slot. Only the reviewed
eight-path AST-equal clean single-parent formatter child/re-pin is permitted.
No source repair, old-source retry, second VM, full-fast/provider/release,
attended/Linux lane, primary rejoin or full restore claim is granted.

COLLECTED OBJECT-CALL PROOF: sibling `M7/m7-object-call-join-v1` retains terminal
report `da42f26dad2ad258432582a37e1fd5b647d2e9410fafecdfdb060fbc3d5535b0`,
inventory `7a67dce68d4475d36750adea3853fe41c91b2be05a2d24360171082cc7be0795`
and the 70-key consumed object-call registry at
`2d4c3ed5680489ad2911cb2ec1e14919be00ded7ebe6b7ca4c179063198e291e`.
Root independently verified 246 sealed artifacts, all 70 original
stage/started/raw EOF/wait/status records and absent PIDs/groups, 124 actual/Git
kind/mode/blob sources, exact suite and separate summary counts, and complete
NUL-delimited Git-tree bytes. Root audit sibling
`M7/object-call-join-root-audit-20261005-v1` retains result
`26bc894e352052fcafa5bf2dc0491f3d0314f53dc18318e7de9b0b7f9a33780c`, report
`89054350c00217a44dab91a4c5858c03000771857be1fd824705b8c362c22b28`
and inventory `5dd34d78bc8d32dc3905bb8f103475198fdca3f1b80b97561d4589c436b538c7`.
All three audit files and inventory are mode 0444. This proves the selected
prerequisites at `2826b30b`, not the newer workflow or cleanup corrections.
The reopened owned IO prerequisite stays open for the known observation gap.
Supplemental sibling `M7/object-call-snapshot-root-audit-20261005-v1` verifies
every one of the 17,360 recorded source-snapshot rows against Git kind, mode,
blob, size and byte digest, all three complete NUL Git trees, and both old
failure registries unchanged. Result
`f264358a949d76daedb0ad5adedd421d3d6e7f588b45b0d5c1b6947e3288f68c`, inventory
`f36b0c7800b90c8cb240ef806ca663cac9a904a6760dfae61a4528db400e405b`.

Root owns a separate source-only rejoin in
`/private/tmp/loopex-m7-restore-final-observation-integration`, branch
`codex/m7-restore-final-observation-integration`, starting at primary
`63d28d17b04d6d0d58ddad73ea2dd9ddee5daa56`. Merge `58b35af4` preserves all eight
tested prerequisite paths byte-for-byte; merge `e65abd1` adds the reviewed
`c71e8dc8` first-transition workflow and claim cleanup without conflicts.
Fifteen source/test paths are affected. Neither integration commit has run a
formatter, compiler or test. Independent cutoff review found no blocker; root
verified its five artifacts, eighty-five exact input pins and two Git patches.
Merge `91eb4ae28d4f28146ef17f0991336b0c3bea2108` then joined frozen `f30bb135`
without conflicts. Thirteen other paths match their selected source parent
exactly; removing the new witness region reconstructs the entire tested `2826`
IO file, and the IO prefix through workflow/ledger clauses matches `f30` exactly.
Remaining IO differences from `f30` are reviewed foundation formatting.
The integration is clean and source only. A separately reviewed verification
runner is still required; no VM grant exists.


CURRENT RESTORE WORKFLOW: the source-only first transition is frozen in isolated
`/private/tmp/loopex-m7-current-restore-workflow`, branch
`codex/m7-current-restore-workflow`, base `8c9c4f92`. One deliverable is the first
integrated available-source ordinal-1 path: complete current audit, copy to an
empty root, source retirement, fresh private Local generation, root commit last,
claim release and guarded actual reopen, all under the original administrative
owner and allowances. Private Workflow/Audit modules and narrow existing
Composition/Resource/Local guard paths are owned; core, wire contracts, docs and
other worktrees are excluded. Frozen predecessor `cbe7698f` carries the artifact
namespace blocker. Corrected clean child
`32417023d94628769071c60ae10969b627f356a6` removes only the two incorrect object
path components and adds actual-file deletion pre/postconditions. All ten source
paths are released. No formatter, compiler or runtime proof exists for this
workflow. Lost-source, repeated restores, full fault matrix and unfinished
helper-ledger contracts remain required. The existing bounded T15 row stays open.

Sibling `M7/current-restore-workflow-source-32417023-20261005-v2` retains writer
report `f34fe4c68026e59f0a02288d2644efa48086878b8a269fdbdc32a315da45e39b`
and inventory `6d0cc737a53e471007e623e01cd0c8dd6502326b4eb4801cedae340e9ac0a53b`.
The supplied packet has actual 0644 modes; hashes identify its reviewed bytes.
Root verified twelve writer artifacts, forty actual/Git/kind/mode sources, six
external inputs, all 87 unchanged old test files, four independent artifacts
and sixty independent hashed inputs. Independent correction/six-case report
`d515bf1968480e19f7fca6173e604fb531c6f493325164b1df7c4acae3e9c4f2` is in
`M7/current-restore-workflow-324-independent-review-20261005-v1`.

Independent IO review found a separate pre-intent cleanup blocker: a second
claim-acquisition IO failure loses the positively acquired first claim from
the worker payload, so joined unchanged-root cleanup never releases it.
Root accepted that finding and assigned CLI a separate source-only correction
from frozen `32417023`, owning only Workflow, IO and the workflow test in
`codex/m7-restore-preintent-cleanup`. Preserve original owners/cutoffs, release
only proved ownership and retain partial/unproved or foreign claims. A released
subset must not be reported as zero remaining claims. No VM or source rejoin
is granted. Private agent continues read-only IO/guard review; it owns no source.

Root's five immutable audit files are in
`M7/current-restore-workflow-root-source-audit-20261005-v1`, report
`6130bb2abb26569e8f69cbe848a96c5aaf22d245663477784bf2c442b94c42d4`, inventory
`86c04c5e70ec5c4b29db8aaf7788b96513c551ccf051f0273930e36b8be096d0`.
One new open T15 cleanup subtask is tracked. The owned raw IO prerequisite is
reopened below for its confirmed source admission gap; no row closes from
these current-only results. T01–T19 originals remain 78 done / 95 todo / 6 retired;
added subtasks are 298 done / 26 todo. Including T00, originals are
78 / 101 / 7 and added subtasks 302 / 27. T15 added is 16 / 10;
T16 added is 53 / 6.

The independent IO/guard review is sealed in
`M7/current-restore-workflow-324-io-guard-review-20261005-v1`, report
`0a6c9c78055267a66f1494dc4f4c7288c9968e2a28c010ca957d70041b122078`, inventory
`c201aa0fb45dae067bf97577749aae4533944044776cc408b316e7232b718ff7`.
Root read it and verified four artifacts, thirteen actual/Git/mode inputs and
three external pointers. The follow-up establishes the inherited cleanup
admission gap in source: early stop makes C earlier than the caller maximum O,
so an already-entered receive can consume normal DOWN after C and reach the
clean branch before expiry. Actual worker termination may be timely; late
guardian observation is the disputed proof. Root accepted correction under the
existing ADR 0051 cutoff; runtime reproduction remains unproved. The original
passing outputs remain immutable, but the owned IO prerequisite cannot remain
complete while this admission path exists.

Follow-up sibling `M7/restore-observation-cutoff-analysis-20261005-v1`, report
`6c0da3f64e194b2461a58cef27b0ac8655b605dc34fe59930d7127f69f6b0dc7`, inventory
`ee9c90415069748df01f3bee58bd5ae887c8350604b669f4dca25b4755a9ed63`.
Root verified four artifacts, six Git inputs, five supplied actual paths and two
external references. Existing IO pause points cannot isolate final observation
deterministically. CLI owns a separate source-only correction in
`codex/m7-restore-observation-cutoff`, new isolated checkout from frozen `c71e8dc8`.
Only IO and its test are owned. Admit expiry before clean/join/release, preserving
existing cutoffs/outcomes; add one real long-bound timely/late control through a
fixed-state extension of the existing private probe/pause seam. Original
monitors, genuine normal DOWN and separate termination/observation instants are
required. No fake clock/signal, shorter cleanup window, retry or VM is granted.

FINAL OBSERVATION SOURCE: clean frozen
`f30bb135d4657735183cfc1c486f8691149bc122`, direct child of `14bbbcb3`, moves expiry
before every clean result or terminal-release admission. It also repairs the
inherited workflow's `clean?` nil result used by strict Boolean `and`. The fixed
private barrier pauses an already-entered receive after closed/finished facts
and the genuine normal linked EXIT, leaving original monitor DOWN for the
admitted scan. Its continuation wait recurs against the same captured C across
timer chunks. A single new long-bound case pairs timely and delayed observation
under unchanged work 1,000 ms, grace 100 ms and cleanup window 10,000 ms.
The optional test-local sink records actual actor/monitor/timestamp joins before
the outcome assertion; a future runner must provide private physical mode-0700
TMPDIR and an empty direct-child sink, then retain both complete timeline files.
No witness, formatter, compiler or suite has run on these bytes.

Hash-pinned sibling
`M7/current-restore-observation-cutoff-source-f30bb135-20261005-v2` retains report
`a24f3115a427422399fdefb7866f49e41e66afa5ef85f09ee73647634786bcb3` and inventory
`8895f93c2cf114ab0cc42e738ff028e8561723142fbbe6014971e640dc3523d5`; actual packet
modes are 0644. Root read the source and packet and verified all seventeen
artifacts, forty-two actual/Git inputs, seven external inputs, eighty-eight
unchanged source/test records and all three exact Git patches. Removing the one
new region reconstructs the original 108-case IO file exactly. Source declares
109 IO cases, 106 ordinary and three long; these are not measured populations.
The complete nine-case workflow file remains unchanged. An additional
source-only old-order causal control preserves the Boolean repair, barrier and
chunked wait; no causal red has executed. Independent source review found no
blocker. Sibling `M7/current-restore-observation-cutoff-independent-review-f30-20261005-v1`
retains report `f172a1acca8a38394d76c61b00363bb7fc9dfea0e87e0b306c3870732a5db555`
and inventory `5e972f6fcea586f325a8aa5b996c8408bc7131930eb6d9e01db924fec39ba60c`.
Root verified its five mode-0444 artifacts and eighty-five exact input pins.
Root source/rejoin audit sibling
`M7/current-restore-observation-root-audit-20261005-v1` retains seven mode-0444
artifacts, the fifteen actual/Git source inputs, complete integration patch and
NUL Git tree. Report
`6c2798728ea8d00055b28db828bc9a9eaa1ab8b5e2068cb40a8f702a4a69b6ea`, inventory
`10de518ec009d37c08cd7012527f899ba6706820969c18d30b5f56b8987911ae`.
Current-index agent owns a separate disabled runner/collector proposal only;
it has no VM, source mutation or registry activation grant.
The planned proof sequence has three separately reviewed grants: formatting
preparation and exact terminal collection; one separately frozen old-order
causal control from the resulting clean source; corrected paired proof that
admits retained exact-source formatter evidence instead of repeating it.
No in-place source switching is permitted. The causal control must preserve
the Boolean repair, private barrier and same-C wait, retain both actual timeline
files and the original known assertion failure, and never substitute an
unrelated failure or missing record for the red. Prospective final populations
are IO 106/3, workflow nine expanded ordinary cases, Composition 686/4,
Local 302/2 and selected IO long 3/106. No population has been measured on
`91eb4ae2`; disabled proposals must be frozen and reviewed before any grant.

FORMATTING PREPARATION GRANT: the separate disabled packet is frozen in
`M7/final-observation-format-runner-20261005-v1`. Root verified its thirty-three
artifacts, 132 actual/Git inputs, twenty-one references, all eleven unchanged
lifecycle functions and complete tree/patch. Runner
`df69d6368ced2c36dfc9aad86469126d36f886ba7fcfa0f80c26b36a9fb203d7`, disabled config
`f2eb1ec8c3f3611fd766b308989f7247f99a0cdd2cf57d546faf23c4e80ff754`, inventory
`e44f6f86ad806cff25a55e5f49b4abfc1fb13eb20ba98d3d9b5be3c85af154d3`.
Independent review found no blocker; root verified its seven sealed artifacts
and 192 exact input pins. Review sibling
`M7/final-observation-format-runner-independent-review-20261005-v1`, report
`51d429fb6bdb329ecbb69c1962d1142e6fc04c223c84929e5a362c04c5020061`, inventory
`67a131c868ac6aaf0baec9bf9645818f0d77f1dcb9a958a31b11babdd244dc7f`.
The Bash entrypoint matches the original v1 and v2's historical disabled copy;
v2's active root has no `stage.sh`. The recorded metadata verifier corrections
are source-audit limitations, not product or VM failures.

Root finalized a separate enabled sibling
`M7/final-observation-format-runner-20261005-v2`, preserving the complete frozen
disabled packet under `disabled-review-packet`. All forty-nine active/historical
artifacts plus root inventory were verified. Enabled config
`9a58cbae01641e3319b4fcc487b12ca4d43f311f6e81b21297342fe0f80fab09`, root inventory
`041d96267c34b08fe4e05ef7165d6dd4803e0ceccebd9e6c89a86759a285f7c0`.
The fresh canonical `M7/final-observation-format-stage-attempt-registry.json`
was seeded empty at
`1a5f5f5aa0ba2c8e25a6d0994e96d5911cd7194ee78b447a194f0321f46bdbf0`; never reset.
New output is `M7/m7-final-observation-format-v1`. Current-index agent has the
sole VM grant for this formatting-only campaign and owns original handle
polling/collection. Preserve the clean or dirty resulting source, exact original
EOF/status and process/group joins; stop first failure and return the slot only
after terminal collection. No compiler, gate, ordinary/long or causal test,
repair, retry, second VM, source switch, primary rejoin or push is granted.

PRE-INTENT CORRECTION: clean frozen
`c71e8dc88f0a49a1fe613fbbc5940824ad296fc1` on
`codex/m7-restore-preintent-cleanup` retains acquired claims through typed IO
errors and stops, releases only proved ownership and counts partial/uncertain
claims after a subset releases. Parent `a8bf7451` retains the IO-error correction;
the child adds typed-stop/caller-loss coverage. The three new drafted cases
preserve the entire original six-case file; nine focused cases are proposed,
none executed. Sibling
`M7/current-restore-preintent-cleanup-source-c71e8dc8-20261005-v1`, report
`10f9eb7aebefcc647ef6b13ef080d63e6558451eacf2211c2ed943e27b4cca5b`, inventory
`5a894e2758993d89d560a2802861862abf302d2be4372e3923ac95545aa8ad9c`.
Root read the source/report and verified thirteen artifacts, forty actual/Git
inputs, three external inputs, 87 old test files and exact six-case file
reconstruction. Its public run preservation row incorrectly hashes zero private
clauses; root separately verified the actual unchanged 937-byte public block.
The frozen packet is not overwritten. Independent source review is complete
with no new scoped blocker. Sibling
`M7/current-restore-preintent-cleanup-independent-review-c71-20261005-v1`, report
`2fb9256c5a260b92baa744474f0d02408513b5e2dff0e20b0a5291eddc69a9cc`, inventory
`55d4615777d3bb23ac3488a1e9964b5453166a599ec7306c7b7a6d36e872f3de`.
Root read the report and verified six artifacts, 58 hashed inputs including
forty actual/Git sources, and the complete abbreviated-index patch against
Git. Runtime proof remains pending; no source rejoin or execution is granted.

Root's two immutable audit files are in
`M7/current-restore-cleanup-root-audit-20261005-v1`, result
`3272284e697df389b7439748e04433fd95faff84b8e2f1b4d7cac65671aa434a`, inventory
`7458800cc7009683a355247fca5b65dfd64cd266e228b4cb5b3034f924d26f8c`.

Primary task/resume checkpoint `82b043b0` is pushed to `m7`. Automatic approval
review rejected the separate source-topic push to origin, stating authorization
covers `m7` but not exporting `codex/m7-current-restore-workflow` to that remote.
The explicit branch-push permission question is pending. Do not bypass or retry
the rejected action without approval or new authorization evidence. Source
`32417023` remains committed and clean locally; unaffected verification and
cleanup correction continue.

Root verified the complete gap inventory's three artifacts and thirty pinned
Git records. Sibling
`M7/current-restore-orchestration-gap-inventory-015341ef-20261005-v1`, report
`5c5d3f6d56191db370d75046ff7609f566dc58679b48c17f68b1c542bafb160b`, retention map
`48ed3d8e9bb1854b194f42ae07476e0ed88982e1ff5e0cb091e5ece18491f532`, records
full-history dependency closure and the Resource import executor identity seam.
The importer must retain its checked original identity through complete current
restore lineage, rather than derive another identity from the destination path.

Root accepted the narrow ordinary-guard interpretation as implementation detail
and verified its nine exact Git inputs. Ordinary startup/revalidation keeps its
existing synchronous caller ownership and explicit record/lineage limits; it
adds no elapsed-time or cancellation promise, administrative worker, invented
lookup budget or refreshed claim deadline. Public lookup and restore retain
explicit limits and owned administrative IO. Sibling
`M7/restore-ordinary-guard-authority-20261005-v1`, report
`3f56805d49f9a59ac8bed9b540fbe83645f188d11fe94a7ad61f2cde6a679d57`, retention map
`a10f50a3c13f6bba7967cc7a2c4fc849821c67e365f20f5161289fad01115589`, specifies
required negative, physical replacement and unchanged-deadline proofs. The older
convenience reader is not claimed to prove a race-safe raw allocation ceiling.
The following execution records are historical; their grants have ended.

CURRENT EXECUTION: Ledger enumeration handle2090 is terminal exit1 and fully
collected. The original current Composition command exited2 with644/651 passed,
seven failures,3 excluded and zero skips in354.531 seconds; pipeline677.138.
Focused IO80/2 and adjacent Ledger23/0 passed in36.661/2.152 seconds. Local,
owned long and all floor lanes did not run. Source is the clean formatter-only
child `6baa7364824b5db95a9075fcbb14afba2304c6f5`. Root read the complete formatter
patch and verified93 terminal artifacts,22 original raw stages/started handles,
106 actual/Git/kind/mode source records and22 unique consumed registry attempts.
Independent read-only OS probes confirm all22 original PIDs/groups absent.
The original slot returned before the separate receipt grant below. No retry,
repair or integration occurred. Seven failures returned
`invalid_session_configuration` in unchanged ephemeral integration cases;
CLI agent diagnoses their cause read-only. The bounded enumeration row stays open.
Sibling `M7/ledger-enumeration-execution-20261005-v1`: terminal
`a6879eb5a314e76e4ab4b5b86398bf1b9b699b9c982dc54f73b77e605c3bf474`, inventory
`466cb17beb754755061bd41ecf61295b34e1a8e08c1dff4b5ba428a29a38e969`;
ordinary raw `d1ffc382d42345e094a3a6e92f8e91a8335238234c3e70c1158b45313d5906c8`.
Collection sibling `M7/ledger-enumeration-execution-20261005-v1-collection`
retains original handle/status and exact assertions; collection verification
`0be5dcbce69336a2262880889eedb2696e14cdce6967b52201cee5c6c7f9af9c`.

CURRENT RECEIPT GRANT: source `f6e731bdafd09f2abd3174ed199b36c24cfcc809` remains
clean, reviewed and isolated. Root reviewed the complete authored run/AST delta,
actual changed source/main, config/schema and finalization; verified54 sealed
artifacts plus inventory,38 external inputs,32 actual/Git/kind/mode sources,
16 source populations,11 unchanged shared runner functions and identical helpers.
Disabled sibling `M7/receipt-captured-decoding-runner-f6-20261005-v2` remains
immutable, inventory `4bbf2f6b8c753433c44e2ebc6113a84bde17463c43f774aabb93638f479006f5`.
New enabled v3 retains run
`c8867cda142a2754d4b83036f60804c728cda0cf246c4de48e03d6960f963b6a`, config
`982d5d42bb10ad7eadf1db0f1377fb20644de1a8c3f7b6d809b83489e1f51152`, finalization
`cc12cb80c7363b52c975f125a7d7d064084e39d3e4aecbcb0f5b427c5137c084` and root-grant.
New canonical `M7/receipt-captured-byte-stage-attempt-registry.json` is seeded
empty after confirming no earlier unit execution or registry; initial digest
`1a5f5f5aa0ba2c8e25a6d0994e96d5911cd7194ee78b447a194f0321f46bdbf0`.
Never reset it. Root grants private_task_causal_resume one exclusive sequential
current/floor verification: focused32/0, adjacent35/0, ordinaryLocal298/2,
zero skips. Only two owned AST-equal formatter changes and exact direct-child
re-pin are permitted. Stop and retain first failure; no retry, source repair,
second VM, full fast, paid/attended lane or integration. Exact new output is
`M7/receipt-captured-decoding-execution-20261005-v1`. Receipt execution now owns
the sole VM under original outer handle8112, polled only by
private_task_causal_resume. Current toolchain/Node and owned non-line AST checks
passed; worker reports an allowed formatter-only direct child `fdd6c0fa`.
Current32 focused and35 adjacent passed in22.605/1.775 seconds. Ordinary
returned296/298 passed with two failures,2 excluded,zero skips in174.004 seconds;
command exit2/evidence1. Pipeline364.417 seconds. Original8112 is terminal exit1,
fully collected; slot returned. Tested formatter-only direct child is
`fdd6c0fadfc363e7fecfe2bb5b9be8fda9c57163`. Root read its full formatter patch,
verified91 terminal artifacts, four collection artifacts plus inventory,
22 original raw stages/started identities,32 actual/Git/kind/mode sources and
22 unique consumed receipt attempts. Read-only OS probes confirm all22 original
PIDs/groups absent. No floor, retry, forced cleanup or integration occurred.
Terminal sibling `M7/receipt-captured-decoding-execution-20261005-v1`: report
`2292f213320d5a2bd1182ed3353608bd2a520160ed946f33deceb2bc6f930aae`, inventory
`cd1c32e72ef0faecd7c140380a7a7933a902da9369bace8a382f8e54d605902d`, ordinary raw
`de05763f2c10f1532fef1dc6b332e6dfd8e1fc592b43de2a9c8b32797eb6c761`.
Collection sibling `M7/receipt-captured-decoding-collection-20261005-v1`: report
`ce13509a5953c7f3f591a95def59aa104f3bc3ba73a896bb63373b0df48eb3f8`, inventory
`90d393a501f0a752830b3227d93ddaadfea49a202fd99ba8e284886296c0270e`.
The22-key registry digest is
`9a70086a798f91b0d7d2a48f366388b9325f5960fcbbafb7a0352f643e83c188`; never reset.
No verification VM runs. The bounded receipt row remains open. Four original
source/review packets remain unchanged. Receipt agent now independently reviews
the new artifact source read-only; it has no further execution grant.

NEXT ARTIFACT INVENTORY: root read the complete selected-use capture report and
schema; verified four listed artifacts plus inventory,11 actual/Git/kind/mode
sources and three prior reports. Immutable copy sibling
`M7/artifact-physical-capture-inventory-fe9c08cc-20261005-v1` preserves its
historical0644 source-mode inventory and records new0444 copy modes, retention
map `25727f58d32fec834d2d1ab8996bf78bf4f5f9fa29002054db8acc085bd77228`.
Report `9f52de85f2dea47c20ef4140844e631f8998736ab56ca30f29e01c21c4d4d683`
recommends reusing owned capture and the existing reference-bound facade for one
selected use. Root assigned current_index_cleanup a new source-only isolated
`/private/tmp/loopex-m7-artifact-use-physical-capture` worktree, branch
`codex/m7-artifact-use-physical-capture`. Root's initial `6baa7364` pin lacked
the proved Artifact decoder prerequisite. The worker stopped before edits;
root corrected the base through two-parent dependency rejoin
`5f7f9b08fff0d8359b294006295161819c002277` with saved m7 `f67e546e`. Root verified
both Store paths equal tested10006 bytes and all four Ledger paths unchanged.
The worker owns only restore IO and its tests; the failed Ledger source remains
frozen separately. Clean source-only child
`b5ce08de7916d15a5af05732802be729a0b47666` adds the selected-use capture and14
new cases, with82 old case bodies unchanged. Root read its full two-path patch,
report and independent review; verified108 source artifacts plus inventory,
87 actual/Git/kind/mode inputs, seven external refs and the independent review's
three artifacts,13 actual/Git/kind/mode inputs and eight refs. No source blocker.
Durable source sibling `M7/artifact-use-physical-capture-source-20261005-v1`:
patch `5ec49c23cb4e84586b1b2863504e3427f96ab9d9ada7b493de7c670998e05b57`, inventory
`3d1006df1257234a1d73c736a8092cfe3ae027ef95cef0fed7ce79f6df6d43ad`.
Independent report is retained unchanged in
`M7/artifact-use-physical-capture-b5-independent-review-20261005-v1`, digest
`e16004a3f5bc61bcb591343d5e045255a884727060b85fb34ae858af8faab519`.
Proposed IO94/2, Artifact29/0, Composition665/3, owned IO long2/94 populations
are source expectations, not runtime results.
No formatter, compiler, test or VM is granted for this source work. One new
added T15 row tracks selected-use capture. Object hashing/complete
namespace/history remain separate; the writer64MiB cap does not narrow the
current uint64 reader/reference domain, and legitimate orphan objects remain.
The repeated maintainer1,000ms diagnostic approval confirms the existing
setup-only disposition and changes no other bound or ADR acceptance.

CURRENT FIXTURE REPAIR: root read the complete source-only diagnosis and verified
six artifacts plus inventory,17 actual/Git/kind/mode sources and seven external
inputs. It establishes the long workspace capture exceeds the strict default
1,000 system ceiling in the seven failed cases; unchanged preflight180 already
proves the explicit-instructions remedy at the same long path and ceiling.
Durable sibling `M7/ephemeral-admission-diagnosis-6baa7364-20261005-v1` retains
report `eb6bbcbd73c3d4bd348ab16599e7d16fd5e6890e360c88826bad97b892e681bf`,
historical inventory `d701103e3753639814da67f80e2fe7f01d6223d7895bb46a63bad53e08490a14`
and exact copy mode map. Root grants CLI agent a new isolated source-only
`/private/tmp/loopex-m7-physical-fixture-bounds`, branch
`codex/m7-physical-fixture-bounds`, base5f7. Only Model integration test and
ReadOnly tools test are owned. Seven failed startup options get short explicit
instructions; selected tools, default ceiling, shared setup, passing cases,
all assertions and deadlines remain. Only the two real physical cases get fresh
short OS-temp workspaces, preserving real FIFO/socket/symlink and exactly
8MiB cumulative raw bytes/first-over proof. No global TMPDIR/chdir, fake, limit
change or runner workaround. No formatter, compiler, test or VM grant exists.
Clean source-only fixture child `d754e78bd892fbf02e0062f69c690fb87b42a203` is
accepted after root read the complete two-path delta/report and verified11
artifacts plus inventory, four base/candidate Git/kind/mode records, two current
actual files and14 external inputs. Both the seven affected Model startup
options and only the two tagged ReadOnly workspaces meet the authorized scope.
No source blocker; formatting/runtime remains pending. Durable sibling
`M7/physical-fixture-bounds-source-d754e78b-20261005-v1` preserves source report
`6455bed8cd2bf79be6c06be28e053503e25c28eecf218154d9de454f48a8660d` and full patch
`2b530c466948dd941acca69348ea85574fe3d4d18492a2f81ed1e4153968d4e1`.
One new added T16 row tracks this genuine fixture portability correction.
Root prepared new isolated integration candidate
`015341efde4d4c28c92aa3f65ea40da1c2623c7f` at
`/private/tmp/loopex-m7-current-restore-integration`, branch
`codex/m7-current-restore-integration`, base saved m7 `3030f46a`.
Three conflict-free merges combine reviewed Ledger6baa/artifactb5,
fixtured754 and receiptfdd6 source. Root verified the clean checkout and exactly
eight changed paths, byte-identical to the respective reviewed source commits.
Primary m7 source remains unchanged. No combined formatter/compiler/test has
run and no VM grant exists. current_index_cleanup prepares a new disabled
modern runner/source/population packet only; root owns review, new registry
audit/finalization and exclusive execution grant. Proposed ordinary Composition
665/3 and Local302/2 reflect joined source; precise focused/adjacent counts and
all macro populations must be source-pinned in that packet before execution.
Do not execute old failed candidates again or reset either22-key registry.

T01–T19 originals remain78 done/95 todo/6 retired; added299 done/23 todo.
Including T00 originals78/101/7, added303/24. T15 added17/7; T16 added53/6.

The following paragraphs retain earlier checkpoints; the current execution,
receipt grant and inventory above supersede their live-state descriptions.

LATEST STARTUP PROOF: `private_task_causal_resume` collected terminal handle
`51106`. Root reviewed and pushed corrected source
`7ca8b9161739842ecf4da4b3a37567b5f67b8464` and granted reviewed runner
`a0862eca0c9bf4944a9cf04e1f796865089c0fb132a4eb83c92c8710aa2ae461` with fresh
sibling `M7/runtime-preparation-startup-execution-20261005-v3`. Root verified
five source and eight runner artifacts, 13 actual/Git/mode records, exact source
preview and validator delta, unchanged helpers and clean source/new output.
Runner AST changes are limited to INITIAL and validate_witness. The new exact
send/reference/queue observation distinguishes send from actual insertion;
64 observations/63 yields share the original cutoff, with four traced actors,
eleven original joins and all old cases/assertions unchanged.

Authorized formatter AST equality passed; tested clean direct child is
`590b997c305697e94a2b9ae8585bbaf4e1bf4202`. Handle 51106 is terminal exit zero,
collected and sealed, with the VM slot returned. Both pairs focused18/1 excluded
and Core1314/10 excluded pass, zero failures/skips. Current focused/Core durations
are 6.902/226.110 seconds; floor 6.825/225.124. Pipeline took688.548 seconds.
Root independently verified125 terminal artifacts,129 final inventory records,
28 actual absent OS groups,13 actual/Git/mode source records and all four raw
populations and complete witness sets. Each proves exact four actors, matching
sent/enqueued reference, observation one before child spawn, eleven unique
original joins, no unjoined actors and the unchanged cutoff met. Root reviewed
the complete formatter delta, which changes only formatting. Tested source is
joined through `dfd4a76ad35e1eb5218f7a575ff4b4de7c0875e9`; root verified the
integrated file byte-for-byte against tested590b. Only the bounded T16 row closes.
Its clean merged worktree and local/remote topic branches are removed after the
m7 source/evidence push at `cd179fb9`.
The first collection script expected generic PASS instead of the runner's exact
status; the collector-only error and original verifier are retained. No test was
rerun and original execution bytes are unchanged. Terminal digest
`dcc4ad681c4549f1c7a6bc3288d6d6274395157c6a01edaee586f474453bdafd`;
collection Markdown `e1b4fb73b55b4aa7940008deea851509c2567212b984514bd1331a703b05aaa0`.
Both old failures remain immutable. Historical reports and registered-resource
semantic cleanup are not attributed or proved by this controlled witness.

LATEST LEDGER PROOF: handle21956 is terminal exit zero, collected and sealed;
exclusive VM slot returned. Tested formatter-only child
`fef3c28bece368c8ab44c9cf0f72d27c0f47a867` is pushed and joined through
`f66ede0a0107ee9ad3089548310b90faf39780ca`. Root checked exact integrated bytes,
120 terminal artifacts, 32 original waited/absent OS groups, 32 actual/Git/mode
records, eight raw populations and the complete formatter delta. Both pairs
pass IO64/2 excluded, Ledger19/0, Composition635/3 and owned IO long2/64,
zero failures/skips. Current durations25.690/1.724/334.364/21.931 seconds;
floor24.705/1.641/336.311/21.909; pipeline1,040.074. No rerun or repair.
Sibling `M7/ledger-capture-audit-execution-20261005-v1`: terminal
`9a9ac7a491dfcbf71e5807f03eadc802ade32d425b6fb33ed003affbb8b611ad`;
collection `4ce2d6545727cdde39d74a882f566aff700c9bdfcab31789b5bc797e4a63255e`.
Floor ordinary raw retains erl_child_setup error32; both ordinary logs retain
the unavailable Darwin invalid filename/Linux-required witness. These remain
visible. Only the bounded T15 capture row closes. Complete ledger/receipt/job/
Store/artifact/history/restore relations stay open. Ledger has no live verification handle. Its slot was returned before the
subsequent artifact grant recorded below.

LEDGER CLEANUP: source/evidence push `d730ee46` completed. The clean merged
`/private/tmp/loopex-m7-ledger-capture-audit` worktree and local/remote
`codex/m7-ledger-capture-audit` branches are removed. No live Git handle remains.

NEXT LEDGER SOURCE: root read the complete source-hashed enumeration inventory
`/private/tmp/loopex-m7-ledger-enumeration-inventory-v1/report.md`, digest
`e2d4eb4b3b8eee0f05d282d6465f1a669159850fd059974f752e351b16b65662`, and verified
five actual/Git/mode sources plus the prior inventory. Worker owns NEW isolated
`/private/tmp/loopex-m7-ledger-enumeration`, branch
`codex/m7-ledger-enumeration`, base `d730ee46`. Source-only complete private
marker/open/generation namespace capture is authorized; only restore IO/test
and, if actual validator reuse requires it, Local ledger/conformance paths.
One original guardian/cutoff, exact current writers/crash cuts and private
structural bounds. No synthetic authority, claim reclamation, public contract,
receipt/Store/history certification, VM, formatter, test or network work.
This develops the existing incomplete backup/restore outcome; no row closes.
Candidate `0c4b805d9269c773830ee8536a60b8560a36b528` is committed cleanly.
Root read the complete four-path delta, report, runner proposal and nonce proof;
independently verified 44 listed sealed artifacts plus their inventory,
32 actual/Git/mode sources and 85 unchanged original case bodies. Independent
review found no other blocker. The exact-size proof is held: installed OTP
`external_size` documentation promises an upper bound, while the packet proves
only the omitted nonce's 69 bytes. Root authorized a source-only replacement
with `byte_size(term_to_binary(five_member_observation, [:deterministic])) + 69`.
Live encoding retains its actual claim nonce. Worker must retain `0c` and seal a
new correction, followed by independent review before a disabled runner grant.
No VM, formatter or test has run for enumeration at this checkpoint.

ENUMERATION GRANT: exact correction `bbf5265cc1a545f0ffef2b8bede7dc447d131853`
resolves the size proof gap. Root read its complete one-expression delta and
nonce derivation and verified46 listed artifacts plus inventory and32 actual/
Git/mode sources. Independent final report
`458152f8c518f3603ccddf9268816ad3efcba07820b895d05bcb50b987e364b5`
reports no bounded source blocker; root read it and verified six listed artifacts,
15 Git and nine external inputs. Original review remains retained as a proof gap,
not a reproduced differing-size defect.
Root reviewed the entire authored run delta from Artifact v4, config/schema and
four-path formatter AST helper. Only source/main functions change; helper and
toolchain bytes remain identical. It verified130 listed packet artifacts plus
inventory,106 actual/Git/kind/mode sources,16 external inputs and every title/file
population. Disabled packet `M7/ledger-enumeration-runner-20261005-v1` remains
unchanged. Root finalized separate v2 with run
`e943313c27357d9988b7c0bc974fded90511ab4569a373aa55e0fa71cbf2f29d`, config
`e2941d5006fd7f11ac7b1afa3bc7e549168d912f4389c9f22c2227209e8c1323`
and132 independently verified finalization files. New canonical
`M7/ledger-enumeration-stage-attempt-registry.json` starts at digest
`1a5f5f5aa0ba2c8e25a6d0994e96d5911cd7194ee78b447a194f0321f46bdbf0`;
do not reset it. Fresh output `M7/ledger-enumeration-execution-20261005-v1`
is not created yet. Root grants current_index_cleanup the sole verification VM
for one sequential current/floor execution: IO80/2, Ledger23/0, Composition651/3,
Local300/2, owned IO long2/80, zero skips. Permit only owned AST-equal formatting
and exact direct-child re-pin. Stop/retain first failure; no rerun, source repair,
assertion or bound change, second VM, full fast or paid/attended lane.
Execution is active under original persistent handle2090, owned by
current_index_cleanup. Preflight confirms exact run/config, clean bbf source,
unconsumed initial registry and fresh output; initial private cache copy is
completed. Worker reports formatter/four-path AST equality and exact formatting
child `6baa7364824b5db95a9075fcbb14afba2304c6f5`, current product dev/test
compiles48.681/45.204 seconds,format/five source gates,focusedIO80/2/0 in36.661
seconds and independent summary80 passed. Dependency warnings remain raw.
Handle2090 is live; adjacent/ordinary/long and floor proof remain pending.
These interim results await root's terminal collection verification. Do not
start another VM,rerun or poll the agent-owned handle independently. Receipt
work is source-only. CLI agent now inventories the next accepted artifact
physical namespace/caps/reference gap read-only; no implementation or VM grant.

LATEST ARTIFACT PROOF: handle24595 is terminal exit zero, collected and sealed;
exclusive VM slot returned. Both pairs pass focused29/0 and Store105/0, no
failures/exclusions/skips. Current durations1.956/12.338 seconds; floor
1.945/12.171; pipeline285.189. Exact tested formatter-only child
`10006bc27618b1308e1390a834bca0652b6b1f95` is pushed and joined through
`a4a31986ed9ac1e6dd3e0bd99567ee5dde5eba93`. Only the two owned Store paths
changed; root verified exact integrated bytes. Root read complete source/
correction/formatter and runner deltas, source reports and independent reviews.
It independently verified136 sealed artifacts,35 raw stages/started groups,
35 original PIDs/groups absent,23 actual/Git/mode sources,four raw populations,
12 handoff artifacts and35 unique registry attempts. No forced cleanup/retry.
Dependency warnings and actual fault crashes remain visible; product compile
with warnings-as-errors and all source gates passed. Only bounded T15 decoder
row closes. Pure current canonical transport is distinct from unchanged Core
closed reference/use admission; physical capture/object/history stays open.

Sibling `M7/artifact-use-decoder-execution-20261005-v1`: terminal report
`b3da8169a2f25c90b6333139f836460571d3fbe20fd4bd08aaae76b5cfb0d61e`;
inventory `d6ef1c8c1ffd09c8aaa278ebfc4365cee927bce954030a2790db8e96fd13b1b0`.
Sibling `M7/artifact-use-decoder-paired-handoff-10006bc2-20261005-v1`, report
`4dd06049353f9c07d3f694dea4132fde2261e825532eaf00bff66e8e8bbef34f`;
packet `4b61611414a808ce3fd6cc4c9024083fafdff179dd2c4e95cd7ff77de2021b65`.
Exact reviewed initiald18, frozen e8 finding and disabledv1/v2/v3/finalv4 remain
retained. Final v4 runner841b83f0/config8bdad8c5 have no further grant. Canonical
artifact stage registry has35 consumed keys; do not reset it or repeat stages.
No verification VM currently runs. Source/evidence push87be37e7 completed;
the clean merged artifact worktree and local/remote topic branches are removed.
Ledger enumeration remains isolated source-only.

RECEIPT SOURCE: root read the full sealed inventory report and concrete boundary;
verified four sealed files, 22 Git/mode inputs, 21 fixed actual inputs and three
prior references. Moving resume documentation has separate retained hashes.
Report `f5e73d591faaa0adcea70643b7a411480ffcc4c6b6c7d86066bb7bd1fb570b9c`;
input inventory `8759ef5d71295426a18c749e9b80c6fc25fdf39f361e456d8e8877baaec6ea4d`.
Private agent now owns source-only extraction in isolated
`/private/tmp/loopex-m7-receipt-captured-decoding`, branch
`codex/m7-receipt-captured-decoding`, base `87be37e7`. Exactly Local executor.ex
and local_authority_contract_test.exs are authorized. Preserve native 28-field
ETF, 65536 cap, live raw-job equality, claim/finality, 17 job comparisons and
separate solicited Core recovery. Replace injected decoder proof with actual
bounded arity-only BIF trace and positive control; preserve other assertions
and deadlines. Actual-writer bytes and hostile captured-byte controls remain
pending. No VM, formatter, test, push or primary source edit is granted.
Stop after committed source/pins/report or a material decision.
Candidate `f46804354698b4c8ad65797833149d2d278f9c00` is source-only committed
and clean. Root read both full deltas/report and verified eight sealed files,
32 actual/Git/mode sources,four prior references,unchanged production prefix and
29 original case bodies. Every nonprobe line in the migrated case is retained.
Independent initial review found no production blocker but an unknown-input-atom
coverage gap. Source-only test child `f6e731bdafd09f2abd3174ed199b36c24cfcc809`
adds20 lines: manually encoded uninterned ETF atom, noncreating before/after
existing-atom checks and actual BIF entry under the same captured1,000ms matrix
cutoff. Production/helper/populations are unchanged; root read the correction
and report. Independent correction review is complete with no source blocker. Root read
initial/final reports and verified initial five listed artifacts plus inventory,
12 Git/eight external inputs,final four listed artifacts plus inventory,
12 Git/ten external inputs,nine sealed correction files and32 actual/Git/mode
sources. Final report
`ea00006cbc9676f8ba4623884085e81383dd4279715952dfb189cbb9f605e1a7`;
inputs `6d820b7cd622319511e677f0284e84fdb3de8e24b3dd611abbdb7662a960cbce`.
Private worker now prepares a new immutable execution-disabled modern runner,
source f6 frozen, only two owned formatter paths,source-derived32/35/298+2
populations,all gates/private caches/strict actual counts/one-shot registry and
original group/source/status custody. No execution grant exists; Ledger owns
sole VM. No VM, formatter, compiler, test or push ran for receipts. Initial/final source
packets remain under their separate temporary names; durable inventory copy is
`M7/receipt-captured-byte-inventory-20261005-v1`, copy inventory
`0c4e91d1d2a83ba7ddfd3021a33aba2365479078b1e65362b5e6f53640ea510f`.
Initial Ledger independent review is copied under
`M7/ledger-enumeration-independent-review-0c4b805d-20261005-v1`;
copy inventory `2ded435828fa0b68dbca3730b0ea683e5c2bbe822f553e117c65cafe15b082e6`.
Standalone receipt expectations on its base remain32 focused/35 adjacent/
Local298 ordinary+2 excluded; these do not include the isolated new Ledger cases.

PRIOR FULL-CHECK REGISTRY: root read and verified five packet artifacts,116
inputs,78 Git source/toolchain identities,17 supplemental actual logs and75
absent raw references. Retained sibling
`M7/full-fast-attempt-inventory-20261005-v1`, inventory
`451b3612ecba27148ae5610abe50e04ff37bb550a032ee0c3191132aa10748fd`.
Stable `M7/current-full-fast-attempt-registry` has78 immutable source blocking
markers, preserving reported versus verified outcomes; seeding inventory
`36efa35f7937ca558a154b584da1074e6489d97e13dd5f95cafd2c40e80cd6e9`.
Three available original executions are FAIL;44 historical PASS claims remain
unavailable as original proof. External/unrecorded CI/local attempts remain
unknown. Do not reset this registry or rerun a recorded source.

NEXT INTEGRATION: disabled draft retained byte-identically under sibling
`M7/integration-next-current-runner-draft-20261005-v1` remains unchanged. Root
reviewed and retained its disabled successor under sibling
`M7/integration-next-current-runner-draft-20261005-v2`. All eighteen v2 inputs
match bytes and modes. Root read the complete authored delta, collection review,
finalization instructions and fifteen Python parser examples. Its validator is
byte-identical to startup v4; helper AST outside population/validate_witness is
unchanged. Runner changes only explicit malformed-summary refusal. Runner digest
`c0ba6836b099ce85e66425f10acafb72cb95d3e5668ef4f7ca1c5c97e15a0402`;
helper `51d8030cd1e7cc7bc6a24c0b837585e92a76c114a7c0ab7cae1de8df51ac7843`.
Final source, populations and exact canonical attempt-registry pins remain pending.
Registry seeding is now complete as recorded above.
No execution is enabled. Batch the source-reviewed Ledger enumeration slice
before the next full integration candidate to avoid immediately repeating the
full suite for another source change. This is sequencing only: every required
check remains, no recorded source is rerun, and final populations/pins wait for
verified rejoin. Startup and the single-file Ledger capture are now joined;
expected Core1324/10 and Composition635/3 supersede the draft's initial
Composition623/3; Local296/2 and CLI635/6 remain prospective. Store is now105/0 after paired artifact proof and exact source rejoin. A read-only Docker
platform/image inventory found the daemon unavailable; no app, container or
image pull was started. The actual Linux filename witness remains unavailable. A strict read-only
SSH OS probe to configured serenity timed out before connection; no remote
files or VM changed. Do not claim either environment as a Linux witness.

SECOND STARTUP FAILURE, retained unchanged: the second execution stopped at source
`559017602d06d74e3bf73104ec5b5c068e09aac2`. Handle `25505` is terminal exit 1,
collected and sealed; the exclusive VM slot is returned. The map-only Logger
repair passed setup. The new case then failed awaiting the actual stop-enqueued
notification, with 997 ms left in its original captured cutoff. Public configure
returned session_unavailable. Current focused tests have 17/18 passed, one
failure, one excluded and zero skipped. No ordinary Core or floor run occurred.
Pipeline duration is 134.252 seconds; dev/test compilation passed in
47.679/46.497 seconds. No formatter source change occurred.

Immutable output sibling `M7/runtime-preparation-startup-execution-20261005-v2`:
terminal `a454e2cafcdb0c425b7bb3f4e3b887649a2eb682c7c2fbf858dc7809efcaa46f`;
complete focused raw
`55d6f0583f2f490481e1893f5e1ed982c967e4e3ac456bff95215a477df6275a`;
collection JSON `f0f15f597aec31ca39c93c64bba23a08e5aac52faa0af1257c435f2c084df7e2`;
collection Markdown `26f337a027cb3c028c9440a094c128d9d82fbb1a94f7d159d016c58a5c691dd0`.
Root read the report and independently verified 62 inventoried artifacts plus
the terminal digest, all 15 actual absent OS groups and 13 final actual/Git
source records. Failed cleanup stays unproved: nine original joins, one
unjoined collector and cutoff false. The empty partial trace and missing full
trace/chain are retained; group exit does not promote them to proof.

The diagnosis preceding the active corrected execution was read-only. Installed
current and floor source show actual
OwnerGroup Supervisor.stop(..., :infinity) routes through GenServer.stop and
proc_lib.stop to sys.terminate, then gen.call's local/infinity send operator.
The fixture's send/3-and-ok-return trace assumes the different finite-timeout
primitive path. No helper is spawned by this direct-PID route. The corrected
narrow dedicated send trace retained exact queue insertion before startup,
four fixed actors, eleven original joins, the 1,000 ms cutoff and unchanged
post-child two-message queue proof. The reviewed correction is the active 7ca/590b
execution above; this failed execution was not retried.
Earlier first-failure results below remain immutable.

EARLIER LEDGER SOURCE ASSIGNMENT: `current_index_cleanup` owns only restore IO source/test in
`/private/tmp/loopex-m7-ledger-capture-audit`, branch
`codex/m7-ledger-capture-audit`, base `d79d171f`. It may implement one private
physical Local ledger file capture under the accepted restore contract, using
current four-role byte decoders and existing guardian ownership. It has no VM
grant. Root read its complete proposal, verified 16 exact source/Git records
and 18 artifact records/modes. Proposal sibling
`M7/ledger-capture-slice-inventory-20261005-v1/report.md` digest
`8f21c2c78ff4b05fcda7fb9992089e7d33302c19504d584a612b530b5272adf3`.
Complete enumeration, receipt/history/artifact relations and activation stay
open; no public or persistent schema changes are authorized. The original
physical-manifest row remains open for its unavailable Linux native-name proof;
later integrated IO verification covers its supported-platform cases.

NEXT ARTIFACT SOURCE: `cli_current_fixtures` owns only Local.Artifacts source
and its artifact conformance file in `/private/tmp/loopex-m7-artifact-use-decoder`,
branch `codex/m7-artifact-use-decoder`, base991636a2. One internal captured-use
decoder and private captured-bytes adapter handle may reuse the existing facade
without a new Core/port/schema. No VM, formatter or compiler is granted. Root
read the complete prerequisite report and verified twelve actual/Git/mode inputs;
retained sibling `M7/artifact-captured-byte-inventory-20261005-v1`, report digest
`bdded140761a0ca73059c496681893795a2cd232b47f47dae12504962d6aa462`.
Physical capture, object bytes and whole-history relations remain separate.
The assignment adds one explicit T15 row. After startup integration, T01–T19
originals remain78 done/95 todo/6 retired, added297 done/21 todo; including T00
originals78/101/7, added301/22. T16 added53/5; T15 added15/6. No completed row was
reopened. No paid/provider
lane is authorized.

LATEST: Resource physical capture is proved and joined through
c137b2ce7a7656ea1d165494f69a3cac5c1b7126, tested clean source
3ecf76623ab2a47fe7edc612135b6529c66634c8. Handle54345 is terminal exit0,
collected/sealed; never poll/restart. Both pairs focused52/2 excluded,
adjacent33/0, ordinary Composition623/3 and selected owned IO long2/52 pass,
zero failures/skips. All32 stages pass; pipeline1,084.309s. Root verified117
sealed artifacts, all stage waits/OS-group absence,29 final actual/Git source
records/modes, empty formatter delta and exact bytes in both integrated paths.
Terminal siblingM7/resource-capture-audit-execution-20261005-v3 digest
54ed22415ebfa941d813ab11fc402967877933415803bb9a40450eb014e1984c;
source inventorye8e689840b9c5702b1fc2e382be8d712f6d48929ad87e72b64ca0bd940c682fb.
Both failed predecessors stay immutable. Raw error-32 and Darwin unavailable
filename-witness notices remain visible; Linux proof and complete catalog/
reference orchestration/restore remain open. Only the bounded T15 row closes.

Native tested9aa2cf82 is already joined88cd84a2, evidence9eedace0 pushed,
worktree/local/remote branches removed. Current T01–T19 originals78/95/6,
added296/20; includingT00 originals78/101/7, added300/21. Next combined full
current fast check remains pending; no full check is rerun on old bytes.

Runtime startup witness first execution has stopped. Handle `28528` is
terminal exit 1, collected and sealed; the exclusive VM slot is returned.
Tested formatter-only child `0bad1bc678d7cc2caa0d3c723f9b71e1983f23b4`
passes current dev/test compilation but focused tests have one new-case setup
failure: the primary Logger filter list is empty and the fixture requires
`:logger_translator`. This occurs before public configure dispatch. Current
focused population is 18 executed, 17 passed, one failed, one excluded and zero
skipped. Ordinary Core and the floor pair were not reached. Pipeline duration
is 136.028 seconds. Root reviewed the immutable failure and minimal filter-list repair. Only the
new fixture's required-key update may change to a map over existing entries,
enabling SASL only on existing translators. Empty lists stay empty. Observer,
complete filter restoration, captured cutoff and all causal/join assertions stay
unchanged. The worker may commit this correction and prepare a pin-only runner
revision; no new VM grant exists yet. The read-only proposal is sibling
`M7/runtime-startup-logger-filter-proposal-20261005-v1`, report digest
`ecd29909ec13809739b1624a50e5e75ded4e27283244d61eac112ccece1ad621`,
patch digest `1993e55a49ecf5107ca0799ec47a1754fa94101d99691311d95f938c0ecabb65`.
Root read the complete report and patch and verified all four packet artifacts
and 23 source/evidence inputs.

Retained output is sibling `M7/runtime-preparation-startup-execution-20261005-v1`.
Terminal digest `d94568bcec54cffcbf43f3e963fd9807abf15180a85883e8ca07ccf17626bb3c`;
complete focused raw digest
`f4a0f0e993ecfbe2deb23ca82c5a4497d86b51623112d55dad8c633e45d66a97`.
Worker `collection-report.json` digest
`8e8cde35e6351cd843fc46b2963079fe81a2c3c3a98661c298966b680eb4575e`;
`collection-report.md` digest
`6a38fa5f3190775a0acc02d67d1ec8532c7202d80bd66efbf37a04dc1ab250aa`.
Root independently verified all 65 terminal artifacts, 65 collection records,
15 recorded stage waits and actual OS-group absences, and 13 final source records
against actual bytes and Git. The witness diff from its base has only additions;
formatting retains `NON_LINE_AST_EQUAL` against its unformatted parent.
Resource worktree and merged local/remote topic branches are removed after the
source/evidence push at `90a5169a`.
The empty partial trace is retained; required full trace and chain are missing.
Cleanup records eight original joins and one unjoined collector, with status
unproved and cutoff false. Later VM/group exit does not replace that proof.
All 15 stage groups are absent; the worker rehashed 65 terminal artifacts.
The approved 1,000 ms cutoff and required eleven-actor causal witness remain
unchanged and unproved. No actual startup or historical-report attribution is
claimed. Earlier active statements below are historical snapshots superseded here.

LATEST: Native checkpoint configuration is proved and joined through
88cd84a28d84d61c7422b543e8a3d3ec4d61047a, tested clean source
9aa2cf82742b3204fe1c57206ec8d2af579aea90. Handle72477 is terminal exit0,
collected and sealed; never poll/restart. Both pairs10 focused/0 excluded,
63 adjacent/1 excluded and1,323 ordinary Core/10 excluded pass, zero skips.
All34 stages pass and OS groups are absent. Root verified98 terminal artifacts,
100 sealed records,1,098 final actual/Git source records and exact tested bytes
in all three integrated paths. Formatter delta is empty. Independent read-only
review found no concrete issue within the bounded native slice. Old failures
remain immutable; no historical schedule attribution or silence claim.

SiblingM7/configure-checkpoint-runner-9aa2cf82-v4/execution-001 terminal
digest a8437e0344bb5557df8cbd368fc0e9ef3ef44daee36e54d845e83c116ea68ee7;
seal b50aa4127dceb229455b4d4bd865a072a892906b7128a306c2d80d51ec00fbe2;
completion aabcbe88b7ed1ff7cdc7006285cc703e496f6ac6d509eb548965bb0c95e5df57.
Measured stage sums current348.044s and floor317.640s, not whole-pipeline time.
Only the bounded T08 added row closes. T01–T19 originals78/95/6,
added295/21; includingT00 originals78/101/7, added299/22. Whole host routing,
coordinated wire and next combined full current fast check remain pending.

Resource v4 now holds the sole VM grant, worker current_index_cleanup, live
handle54345. Exact clean source3ecf76623ab2a47fe7edc612135b6529c66634c8,
reviewed runnerfd8781209e017fe2973943684ab9efa0b48e4a7015a4509a486f1ba82b1875e6,
fresh siblingM7/resource-capture-audit-execution-20261005-v3. Current identity
and formatter AST checks pass, formatter delta empty. Current dev/test compile
47.474s/47.136s, focused52/2excluded/0skipped21.261s and adjacent33/0/0
32.301s pass; ordinary Composition623/3/0 passes334.240s and owned IO
long2/52/0 passes21.751s. Floor compilation35.190s/34.192s and focused52/2/0
20.893s, adjacent33/0/0 32.265s pass. Floor ordinary and long proof remain
pending. Native worktree and merged
local/remote branches are removed after the proved source/evidence push at
9eedace0. The immutable native evidence remains outside the checkout.

Actual Runtime witness source0f6abc76 and runner5ae246ec remain unexecuted.
Independent source review found three new assertion reads with default5,000ms
timeouts; root also found a default-timeout runtime children lookup. The new
explicit schedule uses a captured1,000ms cutoff, so source-only timed reads
are authorized in the added case. Preserve the existing seven live child-ID
preconditions, exact empty records/model/executor assertions, all18 old cases,
joins/trace/Logger/8,192-row bounds, and production APIs. Worker
private_task_causal_resume committed the exact17-insert/5-delete correction at
2ca493a11729b5359dc15ecd4ad4ce25b7ff90af, clean direct child of0f6abc76,
and pushed the source branch. Root read the complete delta and verified5 source
packet artifacts,7 runner artifacts,13 actual/Git source records/modes,
identical helpers and pin-only runner. Reviewed queued v2 runner digest
d95881d3f95c77a58c5953bb51bfceb5bae2434a6ad76d3026b455d1f257aa14,
completion a6ad7ae570c1ffa19318f9772631063ce38d7acdb1b007604b7b20613e5cdeea,
in siblingM7/runtime-preparation-startup-runner-2ca493a1-v2. Source packet
completion952cb5d4fff2ed0cac71cc194cb0583e9c343a810f3b05f70078e3a58aaedff2.
V1 packets remain unexecuted and immutable. Expected18 focused/1 excluded and
Core1,314/10, zero skips, are not results. Joining this one case after the
native ten would make the next combined Core population1,324/10. No VM grant.
Successful whole-case cutoff compliance is required; synchronous existing
constructor/Logger internals do not establish a universal failed-fixture
wall-time bound. No prior runner or test failure is claimed for unexecuted v1.
No other VM before Resource terminal collection. All active statements below
are historical snapshots superseded here.

LATEST: Native v4 now holds the sole verification VM grant. Worker
restore_manifest_resume owns live handle72477, exact initial
9aa2cf82742b3204fe1c57206ec8d2af579aea90 and reviewed runner
a4121a93a91f57ac5c644b12154e09ab83b4f1ce07798317d86aac22f40bb516,
in siblingM7/configure-checkpoint-runner-9aa2cf82-v4. Current focused10/0,
adjacent63/1 and ordinary Core1323/10 pass, zero skips. Measured stage durations
1.893s,6.496s and225.806s respectively. Floor identity probes pass and floor
dev compilation is underway. No other VM until terminal collection.

Resource v3 handle78954 is terminal exit1 and collected. Clean10f71808
passes current dev/test compilation47.441s/46.831s, but focused51/52 pass,
1 fail,2 excluded,0 skipped,20.739s; total pipeline164.755s. No adjacent,
ordinary, selected long or floor stage ran. Root verified59 sealed artifacts,
all15 stage outcomes and process-group absence. Retained siblingM7/
resource-capture-audit-execution-20261005-v2 terminal digest
649b752ccbd3efc768c9d6c7f1a149dfdcf648d05b80249506ccf1d02bf7c690;
focused raw55d499a0eae1bb913367c2e72abe53b01ad36409e37163f0f802648d9cf82b2a.
Never restart/poll78954. The one failure is new local manifest fixture setup:
root/review is deliberately unclassified by the existing directory contract.
It fails before audit. Source and existing negative tests establish that a
contained project skill must be root/.agents/skills/review. Frontmatter already
matches the basename. Worker current_index_cleanup is authorized only that
fixture path plus mkdir_p!, keeping workspace root, actual writer, every nil-
and missing-provenance assertion, case and bound. New direct child and pin-only
packet must be reviewed before a separate grant; old failure remains immutable.
That exact two-line fixture correction is committed at
3ecf76623ab2a47fe7edc612135b6529c66634c8. Root read the complete delta,
verified6 correction artifacts,8 runner artifacts and29 actual/Git source
records/modes, unchanged helpers and pin-only runner. Reviewed Resource v4
runner digest fd8781209e017fe2973943684ab9efa0b48e4a7015a4509a486f1ba82b1875e6,
packet inventorye2aff07f531c687fd0a1889a3dfbf9cd2a234f80e4fa028f04baf9d040a5c1fe,
in siblingM7/resource-capture-audit-runner-20261005-v4. It is queued without
VM grant, eventual fresh output resource-capture-audit-execution-20261005-v3.

The actual-runtime startup witness packet remains source-only and reviewed:
siblingM7/runtime-preparation-startup-runner-0f6abc76-v1/run.py digest
5ae246ec492334e826709d99034df5c040f254e4d4d7fdef044956afc08f58cf;
completion digest3cb0be119149f92805fa54a7d3cd6bace91e609fc01cbdd516fc8b7749543d11.
Root read all629 runner lines and both Elixir helpers, verified5 packet
artifacts and13 actual/Git source/mode records and identical isolation helpers.
Earlier source packet5 artifacts/15 live records and exact Git delta also
verify. Native TMPDIR spelling, exact trace/report chain,11 unique joins,
1,000ms cutoff and8,192-row cap remain required. No VM grant or proof yet.
All three source branches are pushed at9aa2cf82,3ecf7662 and0f6abc76.
No native,
Resource or causal bounded row closes. Counts remain originals78/95/6 and
added294/22 for T01–T19. All active statements below are superseded snapshots.

LATEST: The repeated maintainer reply "approve 1000 ms" confirms the existing
[diagnostic setup override](../developer/agent-context-map.md#disposition-m7-diagnostic-setup-cutoff-2026-10-05).
It changes no production deadline and accepts no queued ADR.

Both prior verification runs are terminal failures. The exclusive VM slot now
belongs to Resource v3, worker current_index_cleanup, live handle78954, exact
source10f71808c9b3d3fb4e9aabe222147490ede89238. Native v3 handle51888 is
collected, never restart or poll it. Formatted
source dc5797c7eeb99128fb2420f89141160376700c4b passes10 focused cases and
63 adjacent cases with1 exclusion, zero skips. Ordinary Core passes1322/1323,
10 excluded, zero skipped, and fails the new automatic-preparation cancellation
fixture at strict recovery with private_public_projection_mismatch. No floor
stage ran. Root verified66 sealed artifact records plus the seal inventory,
all20 stage outcomes and process-group absence. Terminal digest
e285df29d0bfc7f8ca741192867297c8a6ac9f11f40fc203ff8bb2b40aeac089;
ordinary raw031ed41c420e925232fe1ce61d64ac470d1746c3c2e711046287cdad6042efd6,
in siblingM7/configure-checkpoint-runner-65725768-v3/execution-001.
Focused1.902s, adjacent6.629s, ordinary223.018s are measured stage durations.

Read-only source investigation establishes two separate fixture Store reads for
records/events while cancellation may still commit. Store commits both vectors
atomically; pairing old records with new events is invalid. The raw failure
retains this call path but not the returned vectors or intervening transaction,
so its exact interleaving is unproved. Worker restore_manifest_resume is
authorized only to change the new test's recover/1 to one Store snapshot,
preserving strict recovery, all assertions, cases, joins and deadlines. Prepare
a new clean child and pin-only v4 packet, no VM grant or retry of old bytes.
That exact correction is committed at9aa2cf82742b3204fe1c57206ec8d2af579aea90.
Root read the entire7-insert/2-delete delta, verified12 packet artifacts and
all1,098 actual/Git source records, unchanged helpers and pin-only runner.
Reviewed v4 runner digest
a4121a93a91f57ac5c644b12154e09ab83b4f1ce07798317d86aac22f40bb516,
packet inventory07aa73e7a1ad955c1b7822a7775e79e82f562504e69a2909bade4f9358de8e53,
in siblingM7/configure-checkpoint-runner-9aa2cf82-v4. It is queued, unexecuted.

Resource capture v2 handle46942 is collected, never restart or poll it.
Formatted source ae9b66752f1cda812687817924d36ac2a130f918 fails current dev
compilation because resource_role/1 separates execute/1 clauses. No test or
floor stage ran. Root verified38 retained artifacts, all7 stage outcomes and
process-group absence. Pipeline63.344s, failed compile44.253s. Terminal digest
2a36b65b15e8c30e413392edff422e2135650062a91cc221705697ce2b469680;
compile raw5ef33bb000f1febed908d21c6ce1eef16f8ce4ce8526c35e35698502de029cfd,
in siblingM7/resource-capture-audit-execution-20261005-v1. Worker
current_index_cleanup is authorized only to move the unchanged resource_role/1
clauses after all execute/1 clauses, retain a clean direct child and new gated
pin-only runner. That correction is committed at10f71808c9b3d3fb4e9aabe222147490ede89238.
Root read the complete3-line move and pin-only runner change, verified6
correction artifacts,8 runner artifacts and29 actual/Git source records.
Reviewed runner siblingM7/resource-capture-audit-runner-20261005-v3/run.py
digest a5e18324f047118015fcb79ebde6ca0ee9d1d8c059e245117fda339a5a9fdf21
is now executing once in fresh siblingM7/resource-capture-audit-execution-20261005-v2.
Current preparation identities and formatter AST checks pass; formatter delta
is empty. No test result yet. No other VM may start before terminal collection.

Actual-runtime startup witness source0f6abc761f9021b14cba03b1708b6d7776047f75
is clean and source-only in its isolated worktree. Root read its complete
461-line delta in existing model_configuration_preparation_test.exs. Worker
private_task_causal_resume prepares a gated both-pair packet, no VM grant;
one captured1,000ms cutoff,8,192-row cap and exact joins remain. Expected
focused18/1 excluded and ordinary Core1314/10, zero skips, are not results.
The old four-case causal file remains unmerged. Native and Resource bounded
rows remain open. Counts remain originals78/95/6 and added294/22 for T01–T19.
All active statements below are historical snapshots superseded here.

LATEST: Native corrected source657257684edbea05079a3f17789e79c9cb00695c
has the sole verification VM grant for v3. Worker restore_manifest_resume owns
polling and terminal collection, live handle51888. Formatter direct child
dc5797c7eeb99128fb2420f89141160376700c4b is pinned after all three AST
equivalence checks; current dev/test compilation, metadata and new10focused
cases pass,0excluded/0skipped, focused1.902s. Current adjacent is underway.
Both-pair adjacent/ordinary proof remains pending; do not close the row yet.
Runner siblingM7/
configure-checkpoint-runner-65725768-v3/run.py digest
ed436c8427b8c49e47d42dc95c47b0f615a62bc245cf9295ad5e14ffa2584457,
packet inventoryaf6eed69c3256c8f7d0e0156a625ddddfa068288fa4b6a65123b428999f62cc1.
Root reviewed the complete source correction and independently verified all12
packet artifacts,1,098 actual/Git records, pin-only runner change, unchanged
helpers and exact updated three-path Core patch. The two prior failed runs
remain immutable, not reclassified. No native source is integrated.

The coverage fix authenticates original prefix/source identity before deriving
the new boundary after complete old coverage. Existing nonnil boundary and
cumulative range/digest checks remain; historical nil must match its actual
complete old lineage. Ten cases preserve prompts/time/cleanup/parent bounds,
use accepted compact-specific maintenance_active, retain exacttool_calls:[],
and explicitly prove the ordinary prelude before automatic pressure. Captured
context fixture data5000 replaces invalid4000 only for that valid prelude;
no production or time/cleanup bound is enlarged. Held real second settlement
adds forged prefix/boundary/endpoint controls inside the existing uncovered
case. Expected10/0,63/1,1323/10 per pair, zero skips; not results.

Resource capture source6ea56e83e0f5c3ec2cec3909c3ebe5fcc7e4c1f7 is clean
and root-reviewed in its isolated worktree. Root verified29 actual/Git source
records, seven packet artifacts and exact two-file patch. Packet siblingM7/
resource-capture-audit-source-20261005-v1, report digest
e150cacaaba9c958a06ad07b8243c4dfb67f15dc76c0e6d0b865587421e64e5b,
source inventoryb84357e14a374eeefdfb056be55afefec8d640ed4b05573cd154a4f6f2fdf6a9.
Eleven added cases preserve all previous tests and cuts. Runner v1 is unexecuted.
V2 is ready and independently root-reviewed, no VM grant:
siblingM7/resource-capture-audit-runner-20261005-v2/run.py digest
3d716addb15248312a95b291d353d02f14a44b1ef4cfa4e473d0f37cd19c8383,
artifact inventory9529a0253505fc3d43894d71c60ee59b9f8b941d0bb45ac11c749e2a4c248b32.
Root read all runner/helper source and the complete isolation-only v1→v2 delta,
verified eight packet artifacts and unchanged helpers, Python/Bash syntax.
Private Hex/Rebar/cache roots and broad child environment filtering now preserve
host isolation; configured/active Git hooks refuse before formatter mutation.
Worker current_index_cleanup is stopped pending native's terminal slot return.
Target focused52/2,adjacent33/0,ordinary623/3,
owned IO long2/52; zero skips. The third ordinary exclusion is real_provider,
not a third long case. No Resource capture source is integrated.

Causal worker private_task_causal_resume owns ONLY existing
model_configuration_preparation_test.exs in new isolated
/private/tmp/loopex-m7-runtime-preparation-startup-witness,
codex/m7-runtime-preparation-startup-witness, base325e750e. One source-only
actual-runtime startup owner-loss witness is authorized, retaining exact
coordinator/OwnerGroup/async-child/report binding, zero callback acquisition,
1,000ms/8,192-row bounds and exact joins. No production repair, prior-report
attribution or unsupported quiet guarantee. Old failed four-case file stays
unmerged. One new T16 row is open. Prospective separate witness Core1314/10;
if later joined with native10cases,1324/10. Actual proof is pending.
Counts T01–T19 originals78/95/6, added294/22; includingT00 originals78/101/7,
added298/23. All active statements below are superseded snapshots.

LATEST: Native checkpoint v2 handle80977 is TERMINAL exit1 and collected;
exclusive VM slot is FREE. Source remains cleand00fdaec2d87b433ae57037fbe3125d2e53fe344,
formatter unchanged, first17stages pass. Current focused2/10passed with
8failures,0excluded/0skipped; no adjacent/ordinary/floor stages ran.
Root rehashed54terminal artifacts plus terminal/seal/completion identities,
checked all18stage exits, exact unchanged source and absent process groups.
Stage-only duration130.533990291s is not total pipeline time.
SiblingM7/configure-checkpoint-runner-d00fdaec-v2/execution-001:
terminal7a4809440fb7d1405d9db8a7ce87b8d2ac31c56ac9bd80405a2ac37ad35744eb,
FIRST_FAILURE314058acc92fac721b496094a88a5665c6759d8e795e1b7f90f49b4b61fa388f,
focused rawa687968ca65cb0448ba5134b49f585023972ccca0e18d3bbdf40642ba0d8195b,
source inventoryc950d584006cc9340689f64ab5cb7158be41a57f78661a7b0d4d608c401f9aee,
seal inventoryc2532badaa9123c0b9b70c2169f800084f23620e03072cdaacad4b900998b7bd.
Keep the first failure; never poll/restart80977. No native source is merged.

Failures are three compact busy reason assertions, two omittedtool_calls:[]
history assertions, two automatic cases missingheld callback notices within
the original5,000ms, and an uncovered second-checkpoint
compact_checkpoint_failed/context_projection_invalid crash. The corrected
genesis reaches behavior; do not label all failures fixture-only. Worker
restore_manifest_resume is now READ-ONLY investigating exact causes and
accepted contracts; no assertion/source/runner/bound edits or VM grant.

Resource physical-capture source writer current_index_cleanup continues only
its isolated two owned paths, no VM. Causal worker private_task_causal_resume
is read-only investigating an actual-runtime reproduction route for the six
earlier48ca reports; its separate resource-loss explanation grants no quiet
assertion change. Root owns rejoin and next distinct corrected proof. Ledger
worktree/branch were cleanly removed after merge; all needed ancestry/evidence
and checklist were committed/pushed at8de014bf. Counts remain78/95/6 and294/21.
All active statements below are historical snapshots superseded here.

LATEST: Captured Local ledger decoder proof is complete and joined through
58bcad07f9b2721cbdfd2c127daf53b19c375a92, tested source
1e604aed7f651beaae6e2331e455282f0a5c9cda. Both pairs pass19focused/0excluded,
296ordinary/2excluded, zero skips; all32loggedstages pass, total552s.
Root verified45sealedoutputs plus inventory, all21source records and all four
actual populations. Result digest1d1c266a6c2bfcf9ea536938d713948cc4f842e6f9850903f368a9b995093716,
inventory6b9c187cd909a6714cb3bdd4410fffb395126acf0638320d68865b44703740be,
in siblingM7/ledger-captured-decoding-execution-20261005-v1. Handle42740 is
terminal and collected, never poll/restart. Whole offline ledger/restore open.

The sole active verification VM is now native checkpoint handle80977, worker
restore_manifest_resume. Its exact corrected initial source isd00fdaec,
reviewed siblingM7/configure-checkpoint-runner-d00fdaec-v2/run.py;
formatter/version probes have passed. Root confirmed the population JSON delta
only updates exact source, fixture hash and actual three-path Core patch.
No other VM. Preserve old native/causal failures; this run is not a reroll.

Source-only Resource physical-capture writer current_index_cleanup owns ONLY
restore/io.ex and restore_io_test.exs in
/private/tmp/loopex-m7-resource-capture-audit, codex/m7-resource-capture-audit,
baseb50bf885. Canonical catalog paths, identity/manifest binding, role caps
before open, descriptor/ancestor consistency and exact guardian joins are its
bounded deliverable. No setup/VM/tests, public contract, activation or whole
catalog proof. One new T15 row is open. Counts now originals78/95/6,
added294/21; includingT00 originals78/101/7, added298/22. All active statements
below are superseded snapshots. ADR0052 remains unanswered.

LATEST: The sole active verification VM is root handle42740, captured Local
ledger decoder source1e604aed7f651beaae6e2331e455282f0a5c9cda, in
/private/tmp/loopex-m7-ledger-captured-decoding. Current focused19/0excluded
and ordinary296/2excluded pass, zero skips; the floor run is underway.
Root owns polling, terminal review and rejoin. Runner siblingM7/
ledger-captured-decoding-runner-20261005-v1/stage.sh has digest
abbd0b462164398e0a9d89abedf8861b95543414e4388c3671fbc8d294ebf99d;
outputs are siblingM7/ledger-captured-decoding-execution-20261005-v1.
No other VM may start until terminal collection returns the slot. All active
statements below are historical snapshots superseded by this entry.

Native checkpoint handle99172 is TERMINAL exit1 and collected, not active.
Formatted source10d16fd5e9bf8fab07dce0b5681cb8b5019a97d2 passes setup,
format, dev/test compilation and metadata; all ten focused cases fail at
invalid_session_genesis before behavior assertions. Adjacent, ordinary and
floor stages never run. Root independently verified56 retained artifacts.
Terminal digest0bdca43e592edbc8662668ba97e938c1dec144e0f2a1e12fd69b0435bbfeaf2c;
focused rawfbc13ef2f7a952e2e5611692c14149112495a726c2c43a200d4b04ea0f293056,
in siblingM7/configure-checkpoint-runner-4168dee7-v1/execution-001.
Keep the first failure; do not poll/restart99172.

Source-only corrected direct childd00fdaec2d87b433ae57037fbe3125d2e53fe344
adds only existing scripted-fixture reasoning levels and mapping/renderer
revisions. Production, assertions, case counts and bounds are unchanged.
Root read its entire three-line diff and verified1,098 actual/Git source
records and all ten packet artifacts. V2 runner changes only the exact source
pin; Elixir helpers remain identical. SiblingM7/
configure-checkpoint-runner-d00fdaec-v2/run.py digest
6669125ce149e0b6947244b4aa765c34deb404524602426ecda6a96e0f49bec4;
packet inventorye26bb67f84da69eb6c98991099bdd769ef24dc989dde21bc9345bd358bcfe17e.
This distinct source is unexecuted, queued after the root ledger proof.
Expected per pair10new/0excluded,63adjacent/1excluded,1323ordinary/10excluded,
zero skips. Actual outputs remain authoritative. No causal file is integrated.

The read-only causal investigation is complete. Exact serial and all29
concurrent failures arise when private-supervisor removal kills registered
resources before exact cleanup acknowledgement. The guard conservatively
reports provider_cleanup_unproved, as accepted ADR0039 requires when semantic
proof is lost. This does not establish a universal quiet tree-destruction
guarantee or attribute the six earlier48ca Runtime reports. The new four-case
fixture remains unintegrated and unproved; no production/assertion/cutoff
change or suppression is authorized by this finding. Report siblingM7/
private-task-cleanup-unproved-cause-20261005-v1/report.md digest
05ca8593d5ca4d5299280aed556da7fc5078f3e335f82b93f4c888ee679f443c.
Root read the report and accepted ADR0039's explicit destruction limitation.

The repeated maintainer approval of1,000ms confirms the already recorded
diagnostic setup override and both-pair twenty-case proof. It does not accept
ADR0052. Counts stay originals78done/95todo/6retired, added293done/21todo.
Independent read-only next-step restore inventory is running; no writer or VM
grant. Continue the existing active goal, never recreate or self-close it.

LATEST: Causal v3 handle38955 is terminal exit1 and collected. Current dev/test
compile and matrix pass; focused2/4 pass, zero exclusions/skips, floor never
ran. Root independently rehashed all41 terminal-listed artifacts. Serial and
concurrent quiet assertions fail on actual provider_cleanup_unproved reports
(one and29 respectively); five structured traces are retained,63 required
artifacts missing. Controlled startup and genuine fault pass, including exact
startup joined/cutoff/empty-unjoined cleanup. Stage-only duration98.493s is
not total pipeline time. Actual Runtime attribution and quiet proof remain open.
SiblingM7/private-task-causal-runner-5fa9d9ce-v3/execution-001:
terminal cb7ca29c1cb9f83c4ba506892d5134aa3cc6ffb7e088adbf687324e898de0bbf,
raw focused a9740fccf3c44f4b3be4adca14cf5234acad93587ea44b55a0da4f5d2834ac39,
collection39e460580eef39b33665f7477e145a2137f45fa1a53215ff9f808dfe40873595.
Do not retry38955 or edit/drop quiet assertions to relabel the failure.
Causal worker now performs read-only cause investigation from retained JSON and
existing provider cleanup/OwnerGroup code, with no source writes or VM grant.
The entire1473-line four-case causal file is absent from primarym7; eventual
integration adds FOUR executed Core cases, not one. No causal source is joined.

EXCLUSIVE VM SLOT now belongs to NATIVE CHECKPOINT, live handle99172.
Reviewed gated runner4168dee7-v1 has re-pinned formatted direct child
10d16fd5e9bf8fab07dce0b5681cb8b5019a97d2 after all three AST-equivalence
checks. Current whole-tree format and byte-only population check passed
(new10, adjacent63/1excluded); dev compilation is running. Worker
restore_manifest_resume owns polling/terminal collection. Preserve exact
source and start no other VM. Both-pair proof and full ordinary Core remain
pending. All active statements below are historical snapshots.

Read-only independent review of isolated captured-ledger source205afb7a found
no concrete correctness/minimalism/contract/test-proof issue. It confirms live
and captured readers share unchanged schema/format validation and fixed caps;
physical/job/receipt/authority obligations remain distinct. No reviewer writes,
VM or tests occurred. Ledger runtime proof remains queued/unexecuted.
Counts T01–T19 originals78/95/6, added293/21; ADR0052 acceptance unanswered.

LATEST VERIFICATION: Causal v2 handle52711 is terminal exit1 and collected.
Current compile/matrix passed but focused exited2 with0/4 passed, zero
exclusions/skips, because all four retain calls rejected runner-selected
/private/tmp outside the fixture's System.tmp_dir boundary. Floor did not run;
all68 required trace artifacts are missing and fixture cleanup proof is
unavailable. All nine launched process groups are absent; source5fa9d9ce is
clean. Root independently rehashed38 report artifacts and read the exact guard
and raw failure. Retain raw provider_cleanup_unproved/shutdown:noproc reports
without attribution. SiblingM7/private-task-causal-runner-91784948-v2/execution-001;
terminal digest04354b47c9e031a554b30f305fa194b5011d7b0508e3f1597f482b1999b23176,
raw focused8e4ef3b1356f67e2494c98b12b14b24fb194756a31a354826de9170a923dad76,
collection399cca1b1bc8ec0a009a5f51458574c1e3b9472f3b5d8d362ceeb72fde810ac5.
Do not poll/restart52711 or relabel this failure.

EXCLUSIVE VM SLOT is now CAUSAL V3, live handle38955. Exact source remains
5fa9d9ce3d1f723aa31d877e096110c1d688e804. Root reviewed the complete delta,
all five packet digests and Python AST: native tempfile parent and identical
child TMPDIR replace the invalid fixed directory; fixture/assertions/bounds
stay unchanged. Runner siblingM7/private-task-causal-runner-5fa9d9ce-v3/run.py
SHA-25607fdfcae751cf0f141fbb62ac29faaccefc5fcccc678366abf34c4a7666ec571;
separate execution-001. Exact current versions passed; formatter stage began.
Worker owns polling and returns the slot only after terminal collection/sealing.
All active-run statements below are historical; no other verification VM.

Resource fully merged plain worktree/local branch are removed; complete evidence
and tested ancestry remain saved/pushed at0a857ca6. Its bounded T15 row is
closed; whole catalog, physical capture, Linux filename and restore remain open.
Counts originals78/95/6, added293/21. Native checkpoint4168dee7 runner is ready
but unexecuted: siblingM7/configure-checkpoint-runner-4168dee7-v1/run.py,
digest4357ca153f0ee99a75be1cfd9f70bd0fb92503cd02eb0d21773da37966489c86.
Root read complete runner/helpers and independently verified all8 packet
artifacts plus1,098 actual/Git source blobs, including literal symlinks.
Expected new10/0excluded, adjacent63/1excluded, ordinaryCore1323/10excluded,
zero skips; actual populations remain authoritative. Queue is causal, native
checkpoint, captured ledger; all latter proofs remain unexecuted. An independent
read-only review of ledger205afb7a is underway with no VM or write authority.

LATEST: Resource cc8ac30ff1ab6732233c3d3d53f93d0ab01000fb is terminal PASS,
joined through32cf240e40ab0ab3a807a2a6e17726d64c5cce1d. Both pairs pass
33focused/0excluded and596ordinary/3excluded, zero skips; all31 logged stages
pass, total918s. Root independently verified42 sealed output records plus
inventory, all24 source records and actual populations. Result digest
b7a2e13cebd18f0b71e5db49fd9cb43c959ae047cd951030a5af6dbae5ff7ccf;
inventory ac574688b712b2cdae6de7987b5cacd5e256428163c07854c924fb96f0a621d8
in siblingM7/resource-retained-decoding-execution-20261005-v3. Handle96931 is
terminal and collected, never poll/restart. Preserve first failures and actual
floor erl_child_setup error32 diagnostic. Whole catalog/capture/restore and
Linux witness remain open. T01–T19 originals78/95/6, added293/21.

EXCLUSIVE VM SLOT now belongs to CAUSAL, live handle52711. Reviewed v2 runner
siblingM7/private-task-causal-runner-91784948-v2/run.py is executing ONLY its
four-case both-pair proof. Formatter/non-line AST comparison passed; source
is re-pinned to direct child5fa9d9ce3d1f723aa31d877e096110c1d688e804. Current
versions and format check passed; dev compilation is running. Worker
private_task_causal_resume owns polling and returns the slot only after terminal
collection and sealing. No root/Resource/native checkpoint/ledger VM may start.
This controlled mechanism cannot attribute actual Runtime shutdown diagnostics.
Native checkpoint4168dee7 remains source-only; worker prepares a gated runner.
Captured ledger205afb7a remains source-only; its gated runner sibling
M7/ledger-captured-decoding-runner-20261005-v1/stage.sh digest
abbd0b462164398e0a9d89abedf8861b95543414e4388c3671fbc8d294ebf99d
passed native Bash syntax and five embedded Python AST checks without execution.
Root owns rejoin and one new clean combined fast check after queued proofs.
All active-run statements below are historical snapshots; this latest state governs.

Local ledger captured-byte extraction is source-only at
205afb7a598210c97937fc27238061c163ff9b5f in
/private/tmp/loopex-m7-ledger-captured-decoding,
codex/m7-ledger-captured-decoding. Root owns only ledger.ex and existing
ledger_record_conformance_test.exs. Accepted ADR0051 treats pure-validator
extraction as reversible. Existing current record schemas/caps/byte equality
are reused; no Core facade or persistent schema changes. Two added cases are
unexecuted (expected focused19/ordinary296, prior exclusions unchanged).
No VM/formatter/compiler/test ran. Retained packet sibling
M7/ledger-captured-decoding-source-20261005-v1, inventory
a7c59b6a0d2f3c349f1cb0249f34c3b59e13a4bd76b79d64f740fe73347bafe4,
patch eaed3927dc1df14a86001ced2c64371d4265936817b697a83a98f4691079c67a.
One bounded T15 subtask is added/open; T01–T19 originals78/95/6,
added292/22. Whole physical ledger audit/restore remains open. Resource
current ordinary596/3excluded/0skips passed in333.9s ExUnit (334s command);
floor is running on the same pinned source and exclusive handle96931.
Causal is next, checkpoint/configure follows after runner review; no other VM.

Latest completed proof: Ledger393d8935c26bd9a495198d79e5aa70300fcfbd12 is
terminal PASS, joined by6abf3f39a89dddd8b11ebef13e1a8b4760904378. Both pairs
pass17 focused/0excluded and294 ordinary/2excluded, zero skips; all32 logged
stages pass, total542s. Root verified all44 sealed output files and exact
pinned/final source inventories, all stage statuses and populations.
Sibling evidence M7/ledger-byte-guard-execution-20261005-v1; result digest
d9269fb21f2ad3e09123081734ec2c88d734fb40d6fe7bba1d9871e31ff694b3;
inventory1d2cdbc1856ca54f8065ebc433b44e1714531504e8f5d9865b11a43dba5878e2.
Handle86459 is terminal and collected, never poll/restart. The clean fully
merged Ledger worktree and local branch are removed; tested ancestry remains
reachable from m7 and all needed evidence is retained.
Only the bounded T15 decoder-entry row closes; whole offline ledger/restore
audit and Linux witness remain open. T01–T19 originals78/95/6, added292/21.

EXCLUSIVE VM SLOT belongs to RESOURCE, handle96931. Source remains clean
cc8ac30ff1ab6732233c3d3d53f93d0ab01000fb; formatter delta is empty.
Corrected v4 runner: sibling M7/resource-retained-decoding-runner-20261005-v4/stage.sh,
digest86aa58b503fd0f08d40646c5a13474af8fec736fe1d76e487b3aeabea34bb0a8.
Root checked its exact pin-only delta and all8 source inventory records against
Git/current bytes. Output M7/resource-retained-decoding-execution-20261005-v3.
Dependency copies, current toolchain/Node probes, dev/test compilation, format
and metadata passed. Current focused33/0excluded/0skips passed in32.3s ExUnit
(33s command); ordinary Composition is running. Worker current_index_cleanup
owns polling and returns the slot only
after terminal collection. No root/causal/checkpoint VM may start meanwhile.
Preserve both earlier Resource failures; neither is relabeled PASS.
Earlier active statements below are historical snapshots; this latest state
governs. Native checkpoint/configure remains source-only and unproved.

Native checkpoint/configure source is frozen and clean at
4168dee75eff26ff3d138f1d775a6ef0edf5e5e5 in
/private/tmp/loopex-m7-configure-checkpoint. Root read the complete three-path
patch and all411 new test lines, then verified all21 inventory files against
actual and Git bytes. The one-line production change applies the existing
surviving-history filter; owner staging, public/wire contracts and persisted
records are unchanged. Ten generated cases cover actual checkpoint capability,
summary/tail capacity and maintenance preparation, cleanup and recovery. No
formatter/compiler/test ran. External packet M7/configure-checkpoint-source-20261005-v1;
inventory dea21604326d54b33d51ed068254036b66ce24dec2de8194cc819bc4d1270f86,
patch59419778619e5a5b4e8fa4507c44094021f58bf84b88566e7ad00690479e25f2,
reportc66e1e37f17dbf9fe20a044625f4e31327f1b89622540f1f809549252ace8076.
restore_manifest_resume is preparing only a gated runner; no VM grant. Causal
91784948 remains next after Resource returns its exclusive slot. ADR0052 exact
pair remains unanswered; the 1000ms diagnostic approval does not accept it.

Latest active verification is ROOT LEDGER ONLY, handle 86459. Initial source
0b82b006 is formatted and committed as 393d8935c26bd9a495198d79e5aa70300fcfbd12
in /private/tmp/loopex-m7-ledger-byte-guard. Runner v2 digest
e6df58fc5b03bfa193aed16b1cb21c401195cbd5dbce4c6ab5415d49bc4ea114;
output sibling M7/ledger-byte-guard-execution-20261005-v1. Current compilation,
formatting and metadata passed; focused17/0excluded passed. Ordinary294/2excluded
is running, then floor follows. Keep its source pinned; root resumes the same
handle. No other verification VM may start until terminal return.

Resource handle 54425 is terminal exit 1 and collected. Its focused33 population
has32 passes/1 failure, zero exclusions/skips; no ordinary/floor stage ran.
Production refused a positive fixture whose directory basename and skill name
disagreed. Raw focused log SHA-256
67e0c471a256aeea8910380fc94e64500f0d24f8264d4e33ab6b0c6f7b0acadd is retained
in sibling M7/resource-retained-decoding-execution-20261005-v2.
The corrected clean source is cc8ac30ff1ab6732233c3d3d53f93d0ab01000fb:
add the matching review subdirectory and mark the module async:false because
the actual decoder-entry fixtures change VM-global trace patterns. Production,
assertions, population and bounds stay unchanged. Preserve first failures;
prepare a newly pinned runner and fresh output for this changed source after
root review. Resource has no VM grant while Ledger runs.

The separate native checkpoint/configure slice is source-only in
/private/tmp/loopex-m7-configure-checkpoint, codex/m7-configure-checkpoint,
initial daa67f29. restore_manifest_resume owns session_state.ex, optional
session_configuration.ex input documentation and the new
configuration_checkpoint_admission_test.exs. Use existing checkpoint coverage,
preserve exact owner staging and maintenance settledness, and prove actual
checkpoint/replay/capability plus before-resolution maintenance refusals.
ADR 0044 explicitly permits compaction covering the offending group as remedy.
No new public/persistent/wire contract or VM is authorized. T08 adds one open
bounded row; T01–T19 added counts now291 done/22 todo, originals unchanged.
Earlier active-run statements below are historical; these latest facts govern.

Store audit fb4eb53964c58679f5e16061e1a5dd56a035077f passed all 24 stages
under both pairs and is joined through 47bcedd1daeb141a4a56ab165ac09192a77cee42.
Per pair: focused 41/2 excluded, ordinary Composition 604/3 excluded, owned
long bounds 2/41 excluded, zero skips. Root verified all 1,097 source blobs,
all stage identities/logs/populations and the 63 sealed output files.
Sibling evidence: M7/store-semantic-audit-20261005-v3.
Completion digest bde265d351e1dff9187da01c580ea27bc3d6097faf7669237e7ce979e72763fc;
inventory 82c3e24f52d2ac468cca01a986b34673f144f64a16d5f9315c5e476cb37ab3ba.
Handle 89711 is terminal and collected; never restart/poll it. The clean fully
merged plain Store worktree/branch may be removed after its evidence is saved.
Only the bounded added T15 Store-audit row closes. Whole backup/restore,
real executor effects and existing diagnostic obligations remain open.
T01–T19 originals 78 done/95 todo/6 retired; added 291 done/21 todo.

Resource now holds the exclusive VM slot with live handle 54425. Its corrected
immutable v3 runner is sibling M7/resource-retained-decoding-runner-20261005-v3/stage.sh,
digest 14adbdee5e3cae3a8083a5e4fbece0b54abb4d136f1d4719a694e83f8e10b356.
Root reviewed its exact command-array correction and all four native Bash 3.2
no-VM controls. The formatted committed source is now
ca2975ffa877eec3fedec6cd85ed4b95ebb07589. Both dependency copies and current
toolchain/Node probes passed; dev compilation is running. Fresh output directory:
sibling M7/resource-retained-decoding-execution-20261005-v2. Worker owns polling;
keep source pinned and start no other verification VM until its terminal return.

The earlier Resource runner v2 handle
67651 is terminal exit 1 and collected. It failed before any formatter or VM
because Bash 3.2 rejects the empty ambient-filter array under nounset.
Its source remained clean 16b904adae7b26a034870798472634f91e920079; no tests ran.
Complete first output is preserved in sibling
M7/resource-retained-decoding-execution-20261005-v1. Preserve failed v2 evidence.
Ledger runner v2 is prepared and reviewed at sibling
M7/ledger-byte-guard-runner-20261005-v2/stage.sh, digest
e6df58fc5b03bfa193aed16b1cb21c401195cbd5dbce4c6ab5415d49bc4ea114.
It also uses the corrected nonempty command array and passes all four native
Bash no-VM controls. Ledger remains ungranted and unexecuted.

Causal runner v2 is prepared, source-only and reviewed at sibling
M7/private-task-causal-runner-91784948-v2/run.py, digest
40d0cbe649b2885322d0dde3ce9fef1695c21bc178aa3d82e4fb3adbf7ed8cf5.
It copies dependencies and Mix homes per pair, filters ambient overrides and
requires four passing cases plus all 68 nonempty traces and exact cleanup.
It remains unexecuted. Its controlled mechanism cannot attribute the actual
Core shutdown reports. Ledger source 0b82b006 is also unchanged and unproved.
The clean fully merged Store worktree/local branch is removed; all needed
evidence and tested ancestry remain saved. restore_manifest_resume is doing a
read-only source investigation of the remaining T08 prepared daemon routing;
it has no VM or write authority. ADR 0052 exact-pair acceptance is still
unanswered. Root owns integration and
one combined full check after proved slices rejoin. Earlier records below are
historical snapshots; this latest section governs.

### Earlier joined CLI proof and active Store owner

CLI proof00cf26bb31c45d6c98b29f9e132c7c6cb4d24115 is terminal PASS, all22
stages in241.366 seconds. Each pair passes cold1 plus mixed13 with0 exclusions
or skips; all56 raw/report/metadata outputs are sealed and independently rehashed.
Retained directory: sibling M7/cli-guarded-provider-00cf26bb-v2.
Terminal SHA-256e24339516558a4fedad86a8b2afad06f8b3ee9ea1a4c347268838b53e04151ab;
reportd6a81e5e86ec722e36ab39e627cd60aecd67e0f1c2757ac236f0adfb34565240;
inventorybbf80b2dd86fb49550b7fa262152480c7ca94f9c37c6c86d05d7fb843b4d589e.
Root reviewed its complete one-file patch and joined ancestry at963f17bc.
The clean fully merged CLI worktree/local branch is removed. Handle56356 is
terminal and collected, never poll/restart. Source is now in primary m7.
Whole CLI and new combined full integration remain pending; no checkbox changes.

Exclusive VM slot belongs to restore_manifest_resume. Its clean formatted source
is fb4eb53964c58679f5e16061e1a5dd56a035077f in
/private/tmp/loopex-m7-store-semantic-audit. Handle89711 remains active; the worker
owns polling. The immutable v3 runner is retained in sibling
M7/store-semantic-audit-20261005-v3, SHA-256
5c13c0e8b6d570bafb27ebdf05ad796ed2f078f6461a2a0b9749f9845fb0270b.
Current focused41/2excluded passed in18.921s and ordinary604/3excluded passed
in331.738s, both with zero skips. Ordinary raw log SHA-256
4da4523900f31f9a3fcff7c0f983145cce783b4144253d642205f5ec4dadae0c.
The owned IO long selector is running; the floor pipeline follows sequentially.
Retain isolated copied deps/per-environment builds, original deadlines and exact
joins. Root reviewed the formatter patch; complete terminal output and both-pair
proof remain pending. Actual Local Store uses scripted model/executor here and
does not prove real OS-effect cleanup. Existing fault-test diagnostics remain in
the raw output and do not close the separate diagnostic investigation.
No root/resource/ledger/causal verification VM may start meanwhile.

Resource runner v1 remains unexecuted. Source-only v2 is
/Users/spuri/projects/lexlapax/loopex-evidence/M7/resource-retained-decoding-runner-20261005-v2/stage.sh,
SHA-2560f902a0513fc236518d73ed308fd4f94d0cfda9f7aa3ca4ddb0a145aa11582e6.
It addresses root review of writable primary dependency sharing, floor Mix-home,
Node/toolchain and ambient overrides. Root has read the complete v2 script;
execution remains ungranted until Store returns the exclusive slot.
Causal91784948's startup deadlock/cleanup delta is reviewed. Its unexecuted v1
runner needs isolated per-pair dependency copies and ambient override filtering;
the worker is preparing v2 without a VM. A ledger runner is also being prepared
for clean source0b82b006, with focused17/0excluded and ordinary294/2excluded
under both pairs. No setup or verification is authorized for either runner yet.
Mechanism proof remains unexecuted and
cannot attribute the six retained actual Core shutdown diagnostics.

Primary documentation checkpoint2e136d4c passed its one docs check in16.641s,
retained at sibling M7/documentation-2e136d4c-v1, log
f7006279d40866f2ebf082675f30f681d2dd41a955c40a8ff44d70f4355002c9.
The following earlier active records are history; latest state above governs.

### Latest terminal run and next proof

Full current check48ca4ad12d8668aa664abd5d460e090bbe0f8343 is terminal FAIL,
exit1 in2320.544 seconds; handle55093 is collected, never restart/poll it.
Ten suites pass, CLI626/635 with6 exclusions. All eleven raw logs are complete
and independently rehashed with their inventory. Full log SHA-256
4c4131e4e026119c32350811c56483ec506f5ca17118b0181ad3a8e41deaa7f4;
completion2ec75ef9edfd230a22e20f579159d9f2018279f3b59b7b9cb1378670679f7fa2;
inventory77eb1ff2730b006bc71d1ce8cd4a28f394ccdf82e1805bedcd4b2dcd7f1337d1.
Retained directory is sibling M7/integration-48ca4ad1-v1. Core's six actual
shutdown reports stay open despite its passing1313 cases.

Root owns the exclusive slot next for the isolated CLI correction15fdc361
in /private/tmp/loopex-m7-cli-guarded-provider-start, branch
codex/m7-cli-guarded-provider-start. Format its sole test file, commit/re-pin,
then prove one cold real provider lifecycle and all13 mixed provider/Ask/resource
cases with seed406612 under both pairs. Prepared immutable source/runner packet:
/Users/spuri/projects/lexlapax/loopex-evidence/M7/cli-guarded-provider-15fdc361-v1.
No proof ran yet. Direct fixture ReqLLM startup exposed default dotenv enabled;
the correction uses existing serial starter configuration/provenance without
weakening a production guard or changing any required assertion.

Waiting clean source-only workers: Storedbd4a29e in
/private/tmp/loopex-m7-store-semantic-audit, v2 packet store-semantic-audit-20261005-v2;
resource16b904ad in /private/tmp/loopex-m7-resource-retained-decoding,
runner resource-retained-decoding-runner-20261005-v1;
causal91784948 in /private/tmp/loopex-m7-private-task-causal-proofs,
packet private-task-causal-proofs-91784948-v1. Root ledgerguard0b82b006 is
/private/tmp/loopex-m7-ledger-byte-guard, packet ledger-byte-guard-0b82b006-v1.
All branch names follow their worktree suffix with codex/m7-; consult git
worktree list for exact branch identity. No candidate is formatted, compiled,
tested or integrated. Root grants exactly one VM worker explicitly after CLI.
Store/root resource corrections are reviewed; causal deadlock/cleanup revision
still awaits complete source review and focused execution. Current-format
LegacyImport remains an accepted current workflow, not superseded code.

T01–T19 originals78 done/95 todo/6 retired; added290 done/22 todo after recording
three T15 audit prerequisites and one T16 CLI repair. No completion checkbox
changes. ADR0052 exact pair question remains unanswered; later queued decisions
stay separate. The goal is active.

### Current resumed work

Primary `m7` includes the proved foreground repair and Store byte decoder.
Both worker histories are joined and their clean worktrees archived. Landed
local and remote worker branches are removed. The active goal remains
authorized; this checkpoint does not pause it.

The full current fast check of exact
`4a23ce9489a2c37ba249b7fec4156d6830027def` failed in 14.128 seconds. Compilation
and formatting passed; the structure gate found a task-ledger link to this
file's missing explicit technical anchor. No suite started. The new explicit
anchors repair that link without changing product source or check behavior.
Complete output is retained at
`/Users/spuri/projects/lexlapax/loopex-evidence/M7/integration-4a23ce94-v1/current-fast-check.log`,
SHA-256 `d6ccd17adcee85092d767485d17dac278c8898aa19534e81fcf8a87d769bf3fe`;
completion SHA-256
`7c5faee504013535908df0ab0ed25a598d889b7d376f614b329bc15e393f637c`.
Final HEAD and clean tree matched the tested candidate. Run the next new clean
candidate once; never retry or relabel 4a23 or e327 PASS.

The selected `bash scripts/check-release.sh --only long_bound` is terminal PASS
on exact e327, exit 0 in 1090.005 seconds. Root collected handle 9847; do not poll
or rerun it. All20 selected cases pass: Core 10, executor 2, daemon 5, composition 2
and provider transport-drain 1. This closes only the release selection subtask;
full integration/closure/provider/attended evidence remain separate. Source
remained exact e327 and clean throughout. Complete output is retained at
`/Users/spuri/projects/lexlapax/loopex-evidence/M7/selected-long-bound-e327e46c-v1`.
Completion SHA-256
`829697a9d2a53c9d708d3dce6866aad6b8a95381970b43dfbbce02eca0305a77`;
selected-release.log SHA-256
`ccf32d1fa06d9561b1410499c42a1f07fec108e8ad9b5789d94fa3b242504ac3`.
Root rehashed all 14 retained outputs, parsed the exact NUL manifest with no
malformed/duplicate records, compared all 1,242 complete kind/mode/path records
against independent Git projection, and compared all 1,097 source blobs against
Git. Exported SOURCE_IDENTITY binds exact commit and committer date. The archive
build changes only the declared apps/loopex_cli/loopex output outside excluded
_build/deps. Initial root comparison mistakenly expected root-level escripts;
source-script inspection corrected that verifier expectation, without rerunning
the release or changing its result. Both escript inventories pass.

Exact NUL source-archive-manifest SHA-256
`c589f6439bfc99816a305a0ae91e902f20d091ef56e31d7142b3039609c6f7aa`;
composition lane log SHA-256
`2083d0b4781f56eb821ee3bce632794de6167c1d014018eede2a0d68de1832e8`.
No Linux/native invalid-byte witness or full release closure is inferred.

Foreground proof is terminal PASS at c119aa13 on both pairs, with exact 13
FoundationMapping,3 external/4 excluded and102 ordinary/5 excluded cases and no
skips. Root rehashed all 78 outputs and all 24 stage/source identities. The latest
task-ledger entry records complete report/inventory/log digests. Source joins
exactly to primary; worker history remains reachable through rejoin. Archive the
clean landed foreground worktree/branch after integrating, preserving all needed
external evidence.

Store proof is terminal PASS on both pairs at exact7dc5fe51, joined with its
ancestry. Focused10 and full100 cases run with0 exclusions/skips on each pair;
all20 stages passed. Root rehashed all63 outputs and all1097 Git source blobs.
The task ledger records exact available completion/report/inventory digests.
Both workers are stopped and their verification handles terminal; no worker owns
the VM slot. Root's next full current fast check runs once on the new clean
combined candidate. Once started, hold its exact HEAD/source frozen until its
terminal result and resume the same running handle rather than retrying.

Foreground's clean managed worktree is archived and landed local/remote branch
removed; tested c119 source remains in m7 ancestry. Store's clean landed worktree
and branch should be archived/removed too after rejoin. All needed proof outputs
are already in durable sibling storage; ignore cache removal as disposable.

Terminal full fast-check FAIL is retained in
`/Users/spuri/projects/lexlapax/loopex-evidence/M7/integration-e327e46c-v1`.
Completion SHA-256
`106174758d98d3ab54708c9ec098f2139bc40283cc61fbd881e6697dea0678b0`;
complete current-fast-check.log SHA-256
`a5f16c563ec3c17df75031fb57add5bb336a40d45bf2f926c9f61ce89cf28b83`.
Exit1, 2274.262 seconds, exact final e327 and clean tree. Ten application suites
passed; AppServer passed 100/102, with five exclusions. Its two failures expose
an incomplete revision-3 snapshot mapping and a superseded generic policy-answer
admission assertion. Complete six additional application outputs were retained;
inventory digests are in the latest task-ledger entry. Core's three actual
shutdown_error/noproc reports remain an open causal investigation.

Source checkpoints are:

1. Foreground repair c119aa131fd65263269855f9eb34161ab5f81e44 is proved and
   joined. Its three owned paths are Mapping, FoundationMapping and the single
   external restart identity oracle. The complete ten-member captured snapshot,
   exact old-cursor parity after live advancement and actual answer-admission
   ordering are proved on both pairs, along with real process/Store restart.
   c35 first ordinary failure remains immutable. No generation activation or
   ADR 0052 implementation is implied; full next-candidate integration remains.
2. Internal Store byte decoder7dc5fe51 is proved and joined. Only Log and
   existing encoding tests changed. Same current frame decoder and trusted
   schema loading, actual256MiB predecode cap and complete/torn/corrupt evidence;
   no actors/path IO/repair. Both pairs pass focused10/full100 with0 exclusions
   or skips. Full semantic Store/SessionState backup audit still needs actual
   implementation and current physical/private-format proofs.
3. Private-task causal witness `6a39e0bbc3237222207eeeed3daccdde0444a419`,
   branch `codex/m7-private-task-witness-wip`, worktree
   `/Users/spuri/.codex/worktrees/m7-pipe-deadline-witness/loopex`. Sole shutdown
   fixture source; exact unlink/return/actor/kill/stop-ack metadata, floor/current
   trace shapes, exact shutdown:noproc retained separately from ordinary noproc.
   Preserve original 1000 ms captured cutoff, 8192 cap, 32 serial/concurrent cases,
   quiet assertions and actual joins. No new proof ran; earlier v3 failures stay
   FAIL. Do not integrate as a passing regression or change production custody
   without actual causal evidence.

Run the new combined candidate full fast check once, with one exclusive VM slot.
Foreground and decoder unit proof are complete. Root reviews exact diffs/output/source identities before joining
proved changes. Keep both project dev and test compilation before no-compile
runs. New clean integration candidates get one full check; failed e327 is not a
passing baseline. Worker source-only branches and prepared runner plans grant
no test result.

The one pending human question asks acceptance of the exact ADR 0052 pair at
`ec9e8fbe6c2ed3fb427a93a5d3361e356de01795`, clean/pushed on
`codex/m7-policy-wire-decision` in
`/Users/spuri/.codex/worktrees/m7-protocol-manifests/loopex`.
Concept Proposed SHA-256
`50350c393f74002a4123031ac7f36e393371336c89ff4ae132efb552acebb8e8`;
Technical SHA-256
`2c59a51bef945000f4083360de3ceee7590d30a44597a3541cc22bcf168ad82c`.
Exact docs gate passed once in 64.538 seconds, retained at
`.../M7/policy-proposal-ec9e8fbe-v1/documentation-check.log`, SHA-256
`b55d80763de8239699c36e4c18b02da179062ed9d115031d7c0d2610c5f4683d`;
completion SHA-256
`b9a437aabfd83541d502f36eb15e1ddc4c10f8e621f517f46adcd126aa12414d`.
The proposal remains unaccepted. Do not implement dependent events, change its
Proposed bytes while acceptance is pending, or treat a default option as approval.
Queue further configure/accounting/attempts/helper decisions individually.

Current reconstructive reports, all read-only and independently rehashed by root:

- Whole restore audit report at `.../M7/restore-audit-reconstruction-20261005-v1/report.md`,
  SHA-256 `b397bd7a187b1b2aa5adea015da8b5077e268df680c9f159732e979c8ff7dd0c`;
 50-input inventory SHA-256
 `7615e7660c1b81a6349b8c69c0465a4812baabebe1da54eff53e9f79c2746dee`.
 All50 Git blobs/lengths/hashes and report/completion match. Full current
 Store/SessionState replay, Local receipt ledgers including resource-pack imports,
 artifacts/private references, catalog/owner-marker caps, current daemon format,
 complete historical restore lineage/claims/retirement/activation remain required.
 No actors, backup or restore ran for this report.
- Configure wire reconstruction at `.../M7/configure-wire-reconstruction-20261005-v1/report.md`,
 SHA-256 `5e9c9f2112db57e41fd6bb269aff56036eded0fee49eb7d621679a90dd7c0783`;
 exact28-source inventory SHA-256
 `d20bad6b7e3c645c6c806c5e500ba2c94e015fe04d0b0071e1d6f7f76cff2bbd`.
 Required closed nonempty changes wrapper is recommended for future /3-/4
 ingress; native authored changes/private v2 identity stay unchanged. Not accepted.
 Reports and sources are copied byte-exact to durable sibling storage; the old
 artifact-digests file retains temporary path labels as a historical record.


Composition's ordinary helper now excludes actual long_bound cases, matching the
accepted fast/release routing. The required release lane already proved both
unchanged IO cases at e327; no deadline/assertion/case is deleted. The next full
fast candidate must execute 588 ordinary composition cases with 3 exclusions.
This routing change awaits next-candidate integrated metadata/full-fast proof;
do not claim the older e327 suite tested that new helper.

Run-accounting source reconstruction is available at
`.../M7/run-accounting-reconstruction-20261005-v1/report.md`, SHA-256
`5b0198f4bf5b80a53e5585a0052c6d96041a1331aea5a20ffcecfc11b8c74ded`;
32-source inventory SHA-256
`55dcc32d9c9acece4a2efb0b1e1ead789b0aa3f172503381fd1496e11161d6ba`.
Worker verified all source bytes at 96c5d9b5; root independently rehashed all32
snapshots/report, but substantive report review is pending. It identifies
ordinary/run-owned maintenance settlement charge provenance and uncertainty,
with standalone compact separate. No public read API, caps or helper refund is
accepted or implemented by that report.

`LegacyImport` reads the current offline SessionDirectory marker and supports
the current promised prepare-index transfer. No old-schema decoder/fallback was
found. The earlier deletion recommendation was overbroad and is superseded:
preserve this workflow and its current proofs. A private terminology refactor
may remove the misleading name, but deleting the command or adding new semantic
Store/session admission is a separate scope decision. Pre1.0 removes superseded
contracts, not current behavior bearing an old name.

Linux invalid-byte physical filename proof remains unavailable. A read-only
BatchMode SSH uname probe to serenity returned255 Host is down; no Linux witness
ran, no source was copied and no request-refusal case replaces it. The actual
macOS EILSEQ fixture failure remains retained as FAIL.

Paths abbreviated above by ... start with
`/Users/spuri/projects/lexlapax/loopex-evidence`; they name current available
external outputs. Old missing temporary files below remain historical references,
not recovered evidence. This Git checkpoint records completed results and current worker state without
changing the source tested at e327. The checklist's latest section supplies the exact tally.

### Resume audit after restart

The maintainer explicitly resumed M7 and requested the diagnostic cutoff
question again. The goal is active. Git retains clean `m7` at
`4b839b3718cf7275df38ec45d0607b1a1acba381` and the three isolated branch
identities recorded below. The previous pause's terminal-handle statements are
historical. At resume, the live agent inventory contained only the root; new
bounded workers now own the same two isolated source assignments. Neither has
permission to run a verification VM before the root grants its exclusive slot.

The fifteen concrete temporary artifact paths named below are absent in this
resumed environment: the original full-check log; both completion JSON files;
both root runner scripts; manifest pause handoff; private-task safe handoff and
fixture assessment; backup audit report; V1–V13 inventory report; and all five
decision packets. The floor Mix cache is absent too. Their retained references
and hashes describe the historical runs, but their bytes cannot be inspected or
rehashed now. Git source, accepted contracts and the WIP commits remain available.
Do not claim current availability of missing output, reconstruct a file under its
historical digest, or relabel a new execution as the original run. Required
closure evidence must be available at its retained reference; this gap remains
open until an authentic copy is recovered or newly justified verification
supplies its own identities and complete outputs.

The diagnostic decision is presented from the committed source and this record.
Option 1 permits one captured 1,000-ms setup cutoff per `:broken` / `:killed`
disposition in the existing diagnostic fault test. Setup taking 100–1,000 ms
would pass. The real device-write handshake, injected faults, loss counts,
privacy, sealing and post-fault cleanup bounds remain required. Option 2 retains
100 ms and the unresolved failure while investigating within that bound. The maintainer subsequently replied "approve 1000 ms"; the
[recorded override](../developer/agent-context-map.md#disposition-m7-diagnostic-setup-cutoff-2026-10-05)
authorizes only that setup change. The previous temporary packet is not available; this
restatement does not claim its exact bytes were recovered.


### Saved integrated source and verification

The original paused integrated source was
`8885e0dbacfc4a37cb873080d615869587132ea4`. After explicit resume,
`83fe9300` adds the verified Store decoder and approved diagnostic setup repair;
`67d287cd` includes composition in the release long-bound group. The commit
containing the latest manifest ledger entry joins exact worker source
`0cd79e6de02d0fe9e1486dd6e9d11a7111a516a9`; find its integrated identity in
Git history. Supported IO tests pass both pairs, but native invalid-byte Linux
names and selected release-lane proof remain open. The earlier source-only
pause descriptions below are historical, not the current worker state. The commit
containing this file is the pause checkpoint, discoverable from Git history;
this file cannot name its own commit. The main checkout must be clean and
`m7` equal `origin/m7` before restart is declared ready.

- Native policy replacement atomically cancels the answered prior round before
  the fresh request. Round counters and opaque IDs use run/turn/call identity.
  Source `55a577dba7910f6e44b8fcb78abe03781fc75d12` passes all 464 ordinary
  affected Core cases on both pairs, three long-bound cases separately excluded.
  Core source has not changed since that proof. Independent review reports no
  findings. Complete outputs and hashes remain in the task ledger.
- The standalone requested-model-question codec and independent Node vectors
  are joined at `e66d8c15`. They do not activate wire generations.
- Chat retains an interrupt received during an in-flight status read and sends
  its owed abort once. Closing fixtures positively join the exact finish request
  before observing its deadline. Complete ChatDriver 41 passes both pairs at
  `4f9a0778fde90bd6b285ba72c52a4d561e2b6570`, 22.982/23.605 seconds.
  Fourteen-output completion `/private/tmp/loopex-m7-chat-finish-rejoin-v1/completion.json`,
  SHA-256 `1ebe13894a411ed705d5ab5f2a3ab8c0688b33ba78e84f587cb8feff3a41a09d`.
- ADR 0051 acceptance is recorded at `7db4e51c` against exact proposed pair
  `74aa9288f1ee9671755434d68d292ad78008696e`. The integrated private restore
  codec and owned IO are `b17a2b94`; large receive timeout repair is `8885e0db`.
  Huge accepted work/grace durations now use bounded wait chunks without
  renewing any absolute deadline, monitor or retained result. Root reproduced
  the prior timeout_value with actual IO and exact actor joins, then verified
  all 42 Local/conformance/IO cases on each pair, including the actual 10,000-ms
  cleanup case. Both format, dev/test warning-free compile and metadata pass.
  Eighteen-output completion `/private/tmp/loopex-m7-restore-timeout-rejoin-v1/completion.json`,
  SHA-256 `bb8887d25c1db92f8043af2924002219d0dd78471fd07fc39b413b529361942a`.
  Independent repair review reports no findings. This closes only the private
  prerequisite, never whole restore.

The original full fast check remains FAIL at
`6290ac472cb18ecb78bb3cb75d1abc952458d55a`, 1639.348 seconds:
`/private/tmp/loopex-m7-6290ac47-fast-check.log`, SHA-256
`786d8bd5f90107113962c0696eaef4b3d2857ca2c2864e2d97744d0c0ded80c8`.
Five current-fixture repairs and approved real pipe repair have paired proof;
the diagnostic setup assertion remains awaiting disposition. Later same-source
chat failures and initial restore environment/compiler failures stay retained.
Do not relabel retries, fakes, missing environments or source-only drafts PASS.
No new full/floor/release/attended/provider matrix ran at this checkpoint.

### Unintegrated work and first resume actions

Both workers are safely stopped. All handles are terminal and collected; the
exclusive VM slot is released. No worker verification VM or restore actor ran
for either paused source assignment.

1. Physical manifest unit: isolated writer owns only
   `apps/loopex_composition/lib/loopex_composition/restore/io.ex` and
   `apps/loopex_composition/test/restore_io_test.exs`, based at exact `8885e0db`.
   Preserve the same guardian, serial worker, permission/acknowledgement and
   captured work/cleanup lifetime. Include root, hidden files, empty directories,
   all prior metadata, modes and streamed exact hashes without exclusions.
   Reject symlink/special/regular hard-linked/unsafe paths. Bound retained
   traversal candidates and final manifest to 65536 entries/4MiB and captured
   uint64 total bytes. Native directory listing materializes a list; do not
   claim a streaming native allocator or hard transient heap ceiling.
   No manifest proof or completion is claimed for draft bytes.
   Clean worktree `/Users/spuri/.codex/worktrees/m7-trace-check/loopex`,
   branch `codex/m7-restore-manifest-wip`, commit
   `ef8be7f159269d33a5204f83b6e4430515eb9937`, direct child of `8885e0db`.
   Only IO source changed, +158/-2; test file is unchanged. Source is unformatted,
   uncompiled and unproved. Handoff
   `/private/tmp/loopex-m7-manifest-proof/pause-20261005-v1/handoff.md`, SHA-256
   `e7032fb62c650266459abd9f6071cffa0cf5d9bdbabbe3c7744fd97b4dfd1476`.
   Complete 1095-source inventory SHA-256
   `ab1051f2ccca927f27e931f1e2eb50b56fcf090e9c4ba5bef4a30087e16a1c63`;
   output inventory SHA-256
   `d89ff4f828afa532b21ce36d77e99fddc2324badfc970ea94311f4162134e3a4`.
   Root rehashed every committed source blob, exact Git tree and all pause
   artifacts. Draft has no new tests yet. Verify exact ETF framing/reservation
   costs, add early bounded listing count, use physical canonical test roots,
   and add actual boundary/fault tests before formatting or claiming proof.
   Prior verified worker source remains on
   `codex/m7-restore-io-prerequisite` at
   `1d7d370d74859605615fd5a8af36ec8fbbfdca70`.
2. Private-task causal witness: existing clean WIP
   `0a341c48bae2703b3d90c34d028e5868417acb14`, branch
   `codex/m7-private-task-witness-wip`, worktree
   `/Users/spuri/.codex/worktrees/m7-pipe-deadline-witness/loopex`.
   Sole owned file `apps/loopex/test/private_task_shutdown_test.exs`.
   Current/floor v3 both FAIL1/3. Never join as a passing regression. Latest
   source-only trace expansion assignment paused before any edit or VM.
   Next: exact unlink call/return, monitored-child exit and fixed-target exit/2
   sender plus real stop/ack metadata. Keep 8192 cap, original 1000-ms cutoff,
   actor joins, quiet assertions,32 serial/concurrent cases and real fault
   visibility. Do not require a necessarily later linked EXIT or fabricate an
   invisible dropped signal. Managed resource already uses ProviderLifetime;
   identify kill sender before selecting any custody/production repair.
   Safe handoff `/private/tmp/loopex-m7-private-task-safe-pause-handoff-20261005.md`,
   SHA-256 `fa899bb85689c1ffa51d9d8c6b17216f3e19eb702c399f4c1e822432556e800d`;
   root read and rehashed it. No new extension source was written.
3. After explicit resume, inspect both isolated checkouts/commits before assigning
   work. Each writer retains nonoverlapping ownership; root owns integration.
   One exclusive verification VM slot globally. At pause no worker may own it
   or leave active tool/child handles. Do not infer old agents survived restart.
4. Continue complete manifest, then whole Store/Local/artifact/current host-format
   audit, claims, open guards, append-only lineage, source retirement, copying
   and activation. Full helper-aware restore waits for its accepted current
   helper-ledger grammar. No copied root is activated by a hash alone.

Whole-current-format audit report
`/private/tmp/loopex-m7-backup-audit-20261005-v1/report.md`, SHA-256
`2177609053eeb71f75d28db35125f8cdb3cae68ccfcd230c7aff82978ca4aaee`;
44 exact sources match `8885e0db`, inventory SHA-256
`21c59bbb4d07f85e0f90a8336136da57537dc74f1aa08a164b15417e761ddc13`.
Store raw safe ETF decoding lacks separate compressed-payload/canonical-reencode
protection. Resource/lock readers lack separate pre-read caps. Artifact use cap
is 131072 bytes. Reuse actual pure reducers and current record validation; never
start actors, repair torn backup tails, clear unknown effects, recreate missing
metadata or import Daemon into Composition to audit.

T16 exact fixture assessment
`/private/tmp/loopex-m7-private-task-fixture-followup.md`, SHA-256
`f2d4a06b2170b76b8fc5ba26c69b7ed2d46c16d29d8092c7772ac197db3fc162`;
21-input inventory SHA-256
`de51d038caa759c8aae307e68a9fe0a8f686c49e5a714ff87370bcceceee531d`.
All report/source/evidence inputs above were reviewed and rehashed by root.

### Pending maintainer decisions

The diagnostic setup cutoff is approved by the maintainer's "approve 1000 ms"
reply and [recorded override](../developer/agent-context-map.md#disposition-m7-diagnostic-setup-cutoff-2026-10-05).
The changed complete diagnostic test file passes all twenty cases on both
supported toolchains. The previous external packet remains absent; approval
is bound to the individually presented scope recorded above. The remaining
queued contracts below are unaccepted and must be reconstructed from current
committed source before being presented, since their external packets are absent.

Queue subsequent questions individually, never implement before acceptance:

- Current policy wire events:
  `/private/tmp/loopex-m7-policy-wire-current-review-20261005-v1/decision.md`,
  SHA-256 `69e5141e8856abeb1b40f46ea641175f01d4a4b1c920bcf459a1aa9a5b3d8c56`.
  Recommend consistent numeric turn and retained answer-ID pairs across terminal
  events; native required fields/disclosure are a new amendment. Earlier hybrid
  proposal is superseded as a recommendation and remains unaccepted.
- Configure request outer member:
  `/private/tmp/loopex-m7-configure-wire-decision-20261005-v1/decision.md`,
  SHA-256 `7112840b7a315a4824e747497d9aa1aa4a93ea39013589725bf50b903d7f0dd5`.
- Retained run accounting:
  `/private/tmp/loopex-m7-retained-run-accounting-proposal-20261005-v1/proposal.md`,
  SHA-256 `585dcfe29df34dbba772fa073fb1dff5d796db71dec1a30fc60fbf064f226d86`.
  Read lifetime/caps/certainty/public facade proposed; no implementation.
- Attempt event grammar:
  `/private/tmp/loopex-m7-attempt-events-decision.md`, SHA-256
  `b00591ffb23df421a83b7e76f4ed6a352273ff561ee4ed80660a54537463e0fe`.
  Body grammar, abandonment/succession representations and authoritative
  references require acceptance. Envelope/head helpers alone grant no dispatch.

Complete V1–V13 read-only inventory: 74 numbered steps, 155 descriptive subcases,
80 supporting tests; 403 retained artifacts rehashed. Report
`/private/tmp/loopex-m7-v1-v13-executable-inventory-20261005-v1/report.md`, SHA-256
`d188cd0db4dc4cb70e5088d6c1d7b7318a23a4e3040cd1fe34945791677da8d3`;
inventory SHA-256 `2338f7375ccd991364998c6cf1055a68bb5ad76c3ee0b94469fef83ab99d8055`.
No accepted execution manifest, attempt collector, paid call, complete child
manager or full restore producer is inferred from supporting tests.

### Toolchains, evidence and resume checks

Use installed pairs current Elixir1.20.3-otp-29/OTP29.0.5 and floor
Elixir1.18.5-otp-27/OTP27.3.4. Binaries are under
`/Users/spuri/.local/share/mise/installs/{elixir,erlang}`; pinned Node22.14.0
is under the same installs root. Pair-specific caches:
`/private/tmp/loopex-m7-policy-inspection-{current,floor}-deps` and
`/private/tmp/loopex-m7-policy-inspection-{current,floor}-build/{dev,test}`;
floor `MIX_HOME=/private/tmp/loopex-m7-floor-mix`. Use `ERL_FLAGS=+S 4:4`.
Unset ambient provider/GH/SSLKEYLOG variables without printing their values.
Compile both dev and test before any --no-compile tests: an earlier stale-cache
runner failed this obligation and its output remains invalid evidence.

Root verification checkout:
`/Users/spuri/.codex/worktrees/m7-inspection-rejoin/loopex`, clean detached
`8885e0db`. Root runner files:
`/private/tmp/loopex-m7-chat-finish-rejoin-run.py` and
`/private/tmp/loopex-m7-restore-timeout-rejoin-run.py`.
Do not rerun passing bytes without new source/failure justification. Tests use
isolated temporary user state. Managed checkout/Git writes and Mix socket locks
needed authorized sandbox escalation; all attempted authorized escalations were
accepted. Raw outputs remain immutable outside the repo as required; this Git
record retains exact references/digests. WIP branches must also be pushed before
restart is declared ready.

Run `python3 scripts/m7-task-status.py` to recover exact counts. T01–T19 originals
are 78 done/95 todo/6 retired; added 284 done/19 todo. Including T00: originals
78/101/7, added 288/20. Original denominator remains 186. The enclosing goal was
still marked blocked before this explicit pause; pause/resume is user controlled.
Do not mark the implementation complete, create a duplicate goal or resume work
until the maintainer resumes after restart.
