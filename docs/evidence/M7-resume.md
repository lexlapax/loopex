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

### Current work and restart order

Continue the existing ACTIVE unlimited goal on `m7`. Do not create another goal.
Primary last pushed source/decision checkpoint is `bdc88a05`; this file's commit
will supersede its resume record. The full earlier checkpoint is retained in Git
at `bdc88a05:docs/evidence/M7-resume.md`; consult it selectively for historical
proof pointers. The task ledger retains outcome mappings and the frozen checklist.

Root verification VM is FREE. Every original handle below is fully collected;
never poll it again. The next eligible campaign is generation native v3, after
its independent source review and root admission. Native v1/v2 were never run.

Current isolated source ownership:

- `current_index_cleanup`: accepted0053 configure decoder/vector prerequisite,
  separate writer `/private/tmp/loopex-m7-configure-current-grammar`, branch
  `codex/m7-configure-current-grammar` fromd995ed35. Owned shared pure configure
  request codec/tests/schema/vectors/Node consumer plus Mapping, Request and new
  focused ingress tests. No old-generation route registration or complete wire
  activation; whole manifest rejoin remains separate.
- `cli_current_fixtures`: Core abort/deadline recovery correction, separate
  writer `/private/tmp/loopex-m7-authored-abort-cutoff`, branch
  `codex/m7-authored-abort-cutoff` fromf6b791ab. Own Coordinator and
  authored_run_deadline_test only. Preserve committed abort precedence and make
  model:nil/prepared successors progress the existing abort cleanup rather than
  selecting a new deadline ending or remaining stuck. Source-only native proofs
  and a clean sole child are required before independent review.
- `authored_bounds_review`: sealed Core9f2 P2 missing-model timer finding;
  subsequent f6b791ab correction fixes that but introduces a durable-abort timer
  recovery blocker. Correction audit report
  `380cd1ea823899f54d2519527796e138fec62fc9f7a687b711c6a7ff6dbc25c2`,
  SHA256SUMS `2b70210f919c738bbe232a07531262a9afd5691ede7899100564a1ea0f24d187`
  at `/private/tmp/loopex-m7-authored-run-bounds-correction-source-audit-f6b791ab-20261006-v1`.
  Both are source findings, never runtime failures or passes. Re-review the next
  actual child before formatting/compilation/testing.
- `restore_prefix_source_audit`: independent source admission of disabled
  generation nativev3 for clean9d744079 at
  `/private/tmp/loopex-m7-generation-native-focused-runtime-runner-20261006-v3`.
  V3 consumes both original18466 formatting proofs and selects22 fresh stages,
 141 cases per pair. Report01c8eeab, inventoryabe6676d,109 artifacts,59 actual/Git
  rows,29 refs; root enable script
  `/private/tmp/m7-enable-generation-native-runtime-v3.py` is authored but
  unexecuted, seed724. V2 duplicate-key blocker remains retained in report
  `2511eee207fa1b05f2ebb6d535b53d8cb2c14ea29352e17f535e9821d64ceb9c`.
  Neither v1 nor v2 nor v3 has made a native attempt. No source report grants execution.

One integrator owns rejoin. Core9f2 and protocol c364 both change SessionState;
compose the approved policy provenance/cursor changes with authored command v4
and digest v2, preserving both before verification. The protocol projection
fixture's four missing-run-timer failures are corrected in Core source through
real pending/recovered-question timer arming; they still need composed runtime
proof. Do not inject a timer, soften assertions, increase bounds or retry old bytes.

### Decisions

ADR0053 option1 is accepted and pushed at `f27f50ee`: exact historical Proposed
pair candidate `838cf0e3a9faa0fe13a8824465115a3372bad15b`, field `changes`.
Acceptance changes only Concept Status/Governance, index annotations and the
context-map disposition. Dependent configure ingress/client work is authorized;
complete generation activation still needs its coordinated proofs.

ADR0054 is the sole asked pending question: exact pair candidate
`3c33a2ca875f94c0b41ea7ca92900d4c9084e90a`, one transient compaction activity
observation versus a revised phase stream. No answer is inferred. ADR0055 remote
creation remains Proposed at reviewed `f1f0fb3a`; ADR0056 remains Proposed at
`f3fc594becea5fe659ecb7a4af383286aa407824`. Ask one at a time. Proposed0056's
literal pair is copied and indexed in primary at bdc88a05 after independent
proposal review49c17036 and docs proof below; no acceptance follows.

### Latest complete evidence and attempt union

Evidence base is `/Users/spuri/projects/lexlapax/loopex-evidence/M7`.
Latest complete registry has724 keys:
`helper-ledger-recipe-docs-v1-stage-attempt-registry.json`, SHA
`318bd4516c40a72f982d23be005ddade04b7387f6f8faca367b44f1078bc4d08`.
Reconcile every retained registry into the same unique exact(source,pair,stage)
union before any fresh grant. A source child is not permission to reroll a case.

| Original handle | Exact source | Collected result and scope |
| --- | --- | --- |
| 93010 | a4b14867951a31fbab7f820fc4380493b216456e | PASS retirement99/pair,198 total,187.704s,18 stages; both format/compile;85 artifacts,53 Git/live rows,18 joins |
| 95286 | c36433ec6ed152c9dd329ddbf401a756abda1a5f | FAIL112.905s/seven stages; Core25 and Protocol14 pass including3 Node; foreground18/22; four missing original run timers; daemon/floor unexecuted;50 artifacts,59 rows,7 joins |
| 18466 | initial9f17c0264e89ff0020c0bd9c92ec9fbf80bedf5c; final9d74407937897b9298d8228cff6d317c29bf9b48 | PASS formatting only59.879s/11 stages; all5 whole-file non-line ASTs, both formatters;73 artifacts,59 rows,11 joins |
| 72925 | f3fc594becea5fe659ecb7a4af383286aa407824 | PASS docs only68.034s/one stage; all4 command steps;29 artifacts,complete1121 Git/live rows,one join; Proposed0056 unaccepted |

Exact collection references and hashes:

- `retained-source-retirement-focused-runtime-original-collection-20261006-v5.json`:
  `6f57267dd76d817a41ad9cb860ce56d67482d542a662e9c5ea634502a1a60e06`.
  Root copied all3 literal tested paths into primary7621cb08 after verifying the
  original primary owned files matched ed550 baseline. Only the added T15
  retirement row closed; full/public restore, generation, receipt/release and
  long proofs remain open.
- `protocol-cleanup-native-runtime-original-collection-20261006-v4.json`:
  `15b03659fa7ed37b6073c6ac49a6790bd0f27de6efc4bf74a53df37f02b6f9f9`.
  Current c364 is failed and cannot be retried. Its terminal report is
  `13b9b8af6194ddf98b89174c83e90050a1eeb8828c2eda024978d9254ce3bbc0`;
  inventory `0b0713321e304eadad9b9793831ee63f5b5064c3ab983d6e9136d3683ddceba7`.
- `generation-native-format-original-collection-20261006-v1.json`:
  `bcdc6aaf3758269bc523ed054b68529bd7e8a6130114b5db8826f8a0e4d6cb26`.
  Terminal report `40e34dedb2712273af0f755d5d59abc90170cf55b7bc46ebe38fb37c5fb243b9`;
  inventory `c594fd9fe3313dd2dac3d67cbccd87edd4b0f8bed8b34e54b0b5f6a1c0fdf414`.
  Five source paths differ from ed550; no native generation result exists yet.
- `helper-ledger-recipe-docs-original-collection-20261006-v1.json`:
  `4b0b66eb97680c34807716c782af47f0a595f79c53f4057d3619933b9e91f71d`.
  Terminal report `7c76b64ca7281aad54e60483d669b777b5aa4bb1bb658706a48cb40edaac8656`;
  inventory `2b0d5ecedca7f6a358357ccec323f590ecff07cb63a510b85bede17feaeec08b`.
  Independent docs-runner report498f673b/index3990e622 is scoped to the runner;
  that reviewer authored the proposal correction, whose independent review is
  separately49c17036.

Prior original full fast77114 at58fb remains FAILED, despite1158 documentation
checks passing. Focused cleanup34176 passes43/pair at f9 with original cutoffs;
its two literal paths are integrated at d4a9b637. The broad T16 cleanup/integration
row remains open until a new full integration candidate passes. Earlier failed
originals63288,35594,38095,90817,67819,12820 and every older failed campaign remain
retained at their named bytes, never replaced by a later pass. Their complete
references are in the historical checkpoint and task ledger.

### Execution and review rules

Root alone owns product VMs, helper imports, formatter/compiler/test execution,
grants, mutable attempt registries, original collection and rejoin/push. Agents
are source-only and use separate worktrees for writes. Source review under
workspace-write is not sandbox-enforced read-only isolation or release approval;
release_reviewer must not run without its effective read-only prerequisite.

Supported pairs: current Elixir1.20.3/OTP29.0.5; floor1.18.5/OTP27.3.4; pinned
Node22.14.0, +S4:4. Runner environments inherit only HOME/USER/LOGNAME/TERM and
use private deps/build/cache/tmp/LOOPEX_HOME. Never inject credentials into tests.

Read actual inventory schemas before admission: packet lists/dicts, review
files lists and SHA256SUMS vary. Hash the actual indexed bytes, kinds and modes;
never invent inventory.json or assume a field. Metadata-author errors remain
retained, but are not product attempts. Disabled generationv1 had incorrect
population/outcome constants; v2 corrected only those, then root detected the
fresh duplicate formatting stages. No native attempt occurred in either packet.

Every run streams complete raw output and retains exact source, command/evidence
exit, original PID/PGID, EOF, wait, closed stdout and group absence. Collect the
original tool handle once before a new VM grant. Do not repoll terminal handles,
signal reused groups or relabel failures. Full fast/release checks and closure
follow AGENTS at an actually complete exact candidate; focused PASS does not
waive any outcome or required lane.

### Checklist

Original T01–T19:78 done /95 todo /6 retired. Added:300 done /39 todo.
Including T00: originals78/101/7; added304/40. Run
`python3 scripts/m7-task-status.py` for the grouped tally; do not infer closure
from partial implementation. The last completed added row is T15 retained source
retirement. Original tasks and added implementation rows remain distinct.

Remaining major work includes composed Core/transport proofs, complete served
wire generations, helper execution/accounting/ledger, attempts ownership/events,
full current-format physical restore, integrated checks and the separately
approved closure/release stages. No main merge, closure, tag or publication is
currently authorized.
